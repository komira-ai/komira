/*
 * The engine side of one worker channel (proxy_channel.c) against a
 * scripted fake worker: a thread on a socket pair that maps the shared
 * region HELLO brings, records every request, and answers as each case
 * says. Test-only spike code (tests/test_worker_boundary.mojo, group
 * "fake").
 *
 *   slots     the engine-to-worker heap's slots: where each batch goes as
 *             slots are held and released through the release ring (holes
 *             reused lowest first, adjacent free slots joined, a full heap
 *             sending batches inline and logging it once, room again
 *             logged once, at most 64 slots held, the ring wrapping past
 *             its 256 entries, ids outside the slot table ignored);
 *   clock     clock reads the worker sends as CLOCK messages, each
 *             forwarded to the host's now_ns once and answered with CLOCK; a
 *             cancel the host sets inside now_ns written to the control
 *             page before that answer;
 *   cancel    the host's cancel flag forwarded: the control page's flag set
 *             and CANCEL sent with the call's id, then cleared before the
 *             next call;
 *   heap      replies in the worker-to-engine heap at its edges: the last
 *             16 bytes taken, one byte past refused, an empty payload's
 *             offset not read;
 *   partial   a batch over the heap, sent inline through a 4 KiB socket
 *             buffer to a fake
 *             that reads slowly (every byte arrives in order), and a reply
 *             the fake sends 7 bytes at a time (every byte read);
 *   closed    a worker that closed its end: a write refused, or end of file
 *             before the reply;
 *   reap      close against a worker process that is not the engine's
 *             child (a zygote's): one that exits 300 ms after SHUTDOWN is
 *             waited for, not killed; one that ignores SHUTDOWN is killed
 *             after 2 s.
 * Each case is one member of the JSON object (probe_json.h).
 *
 * FFI-BOUNDARY. The socket pair's fake end is the fake thread's (closed by
 * it); the engine end and the region are the pyw_chan's (pyw_chan_close).
 * The fake maps the region from the memfd HELLO passes and unmaps it. A
 * forked fake worker is reaped by this file's reaper thread.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "probe_json.h"
#include "pyw.h"

static int64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---- the fake --------------------------------------------------------------- */

enum reply { R_INLINE16, R_HEAP, R_CHUNKED, R_CLOSE, R_SUM, R_BADMAGIC, R_HUGE_EOF };

struct seen {
  uint32_t op, flags, slot;
  uint64_t id, off, len;
  int32_t cancel_word; /* the control page's cancel flag when the request arrived */
};

struct fake {
  int fd;
  uint8_t* shm;
  /* set by the engine thread before each request; read by the fake after it */
  enum reply reply;
  uint64_t heap_off, heap_len;
  uint32_t push[80];
  int npush;
  int clock_msgs; /* CLOCK messages to send before the reply, each waiting for CLOCK back */
  int wait_cancel;
  int set_cancel_after; /* write this to the cancel flag after replying (0: leave) */
  uint32_t sum_want;
  /* recorded */
  struct seen seen[400];
  int nseen;
  struct seen cancel; /* the CANCEL message, when one came */
  int32_t cancel_word_at_cancel;
  struct seen shutdown; /* the SHUTDOWN message, when one came */
  int got_shutdown;
  int clock_acks;               /* CLOCK messages the engine sent back */
  int ack_bad;                  /* a message other than CLOCK or CANCEL while waiting */
  int32_t cancel_word_at_ack;   /* the control page's cancel flag when the last CLOCK came back */
};

static uint32_t fnv(const uint8_t* p, size_t n, uint32_t h) {
  for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 16777619u;
  return h;
}

static int fk_read(int fd, void* p, size_t n, int slow) {
  size_t at = 0;
  while (at < n) {
    size_t want = n - at;
    if (slow && want > 1000) want = 1000;
    ssize_t r = recv(fd, (char*)p + at, want, 0);
    if (r <= 0) return -1;
    at += (size_t)r;
    if (slow) usleep(200);
  }
  return 0;
}

static int fk_header(struct fake* f, komira_udf_wire_header* h) {
  /* the first message may carry the memfd */
  char cbuf[CMSG_SPACE(sizeof(int))];
  struct iovec iov = {h, sizeof(*h)};
  struct msghdr mh = {0};
  mh.msg_iov = &iov;
  mh.msg_iovlen = 1;
  mh.msg_control = cbuf;
  mh.msg_controllen = sizeof(cbuf);
  ssize_t r = recvmsg(f->fd, &mh, 0);
  if (r <= 0) return -1;
  struct cmsghdr* cm = CMSG_FIRSTHDR(&mh);
  if (cm != NULL && cm->cmsg_type == SCM_RIGHTS) {
    int mfd;
    memcpy(&mfd, CMSG_DATA(cm), sizeof(int));
    void* m = mmap(NULL, PYW_SHM_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, 0);
    close(mfd);
    if (m != MAP_FAILED) f->shm = m;
  }
  if ((size_t)r < sizeof(*h)) return fk_read(f->fd, (char*)h + r, sizeof(*h) - (size_t)r, 0);
  return 0;
}

static void fk_send(struct fake* f, uint32_t op, uint64_t id, uint32_t flags, uint64_t off, uint64_t len,
                    const void* body, size_t blen) {
  komira_udf_wire_header h = {KOMIRA_UDF_WIRE_MAGIC, op, id, flags, 0, off, len};
  (void)!send(f->fd, &h, sizeof(h), MSG_NOSIGNAL);
  if (blen) (void)!send(f->fd, body, blen, MSG_NOSIGNAL);
}

static volatile uint32_t* fk_ctrl(struct fake* f, uint32_t at) { return (volatile uint32_t*)(f->shm + at); }

static void* fake_main(void* p) {
  struct fake* f = p;
  sigset_t block;
  sigemptyset(&block);
  sigaddset(&block, SIGUSR2);
  pthread_sigmask(SIG_BLOCK, &block, NULL); /* the partial-send case's timer is the engine thread's */
  komira_udf_wire_header h;
  while (fk_header(f, &h) == 0) {
    uint8_t* payload = NULL;
    if ((h.flags & KOMIRA_UDF_WIRE_INLINE) && h.payload_len) {
      payload = malloc(h.payload_len);
      if (payload == NULL || fk_read(f->fd, payload, h.payload_len, f->reply == R_SUM) != 0) break;
    } else if (h.payload_len && f->shm != NULL) {
      payload = f->shm + PYW_CTRL_BYTES + h.payload_offset;
    }
    int inl = (h.flags & KOMIRA_UDF_WIRE_INLINE) != 0;
    if (h.op == KOMIRA_UDF_OP_SHUTDOWN) {
      f->shutdown = (struct seen){h.op, h.flags, h.slot, h.request_id, h.payload_offset, h.payload_len, 0};
      f->got_shutdown = 1;
      if (inl) free(payload);
      break;
    }
    if (h.op == KOMIRA_UDF_OP_HELLO) {
      uint32_t body[4] = {KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, 0};
      fk_send(f, KOMIRA_UDF_OP_OK, h.request_id, KOMIRA_UDF_WIRE_INLINE, 0, 16, body, 16);
      if (inl) free(payload);
      continue;
    }
    if (f->nseen < 400) {
      f->seen[f->nseen] = (struct seen){h.op, h.flags, h.slot, h.request_id, h.payload_offset, h.payload_len,
                                        f->shm ? (int32_t)*fk_ctrl(f, PYW_CTRL_CANCEL) : -1};
      f->nseen++;
    }
    uint32_t sum = payload ? fnv(payload, h.payload_len, 2166136261u) : 0;
    if (inl) free(payload);
    if (f->wait_cancel) {
      komira_udf_wire_header c;
      if (fk_header(f, &c) != 0) break;
      f->cancel = (struct seen){c.op, c.flags, c.slot, c.request_id, c.payload_offset, c.payload_len, 0};
      f->cancel_word_at_cancel = f->shm ? (int32_t)*fk_ctrl(f, PYW_CTRL_CANCEL) : -1;
    }
    for (int i = 0; i < f->clock_msgs; i++) {
      fk_send(f, PYW_OP_CLOCK, h.request_id, 0, 0, 0, NULL, 0);
      komira_udf_wire_header a;
      for (;;) {
        if (fk_header(f, &a) != 0) goto done;
        if (a.op == KOMIRA_UDF_OP_CANCEL) continue;
        if (a.op != PYW_OP_CLOCK || a.request_id != h.request_id) f->ack_bad++;
        break;
      }
      f->clock_acks++;
      f->cancel_word_at_ack = (int32_t)*fk_ctrl(f, PYW_CTRL_CANCEL);
    }
    for (int i = 0; i < f->npush && f->shm != NULL; i++) {
      uint32_t head = *fk_ctrl(f, PYW_CTRL_RING_HEAD);
      *fk_ctrl(f, PYW_CTRL_RING + 4 * (head % PYW_RING_SLOTS)) = f->push[i];
      __atomic_store_n(fk_ctrl(f, PYW_CTRL_RING_HEAD), head + 1, __ATOMIC_RELEASE);
    }
    uint8_t body[1000];
    for (int i = 0; i < 1000; i++) body[i] = (uint8_t)(i * 31 + 7);
    if (f->reply == R_CLOSE) break;
    if (f->reply == R_HUGE_EOF) {
      fk_send(f, KOMIRA_UDF_OP_OK, h.request_id, KOMIRA_UDF_WIRE_INLINE, 0, 1ull << 31, NULL, 0);
      break;
    }
    if (f->reply == R_BADMAGIC) {
      komira_udf_wire_header bm = {0x12345678u, KOMIRA_UDF_OP_OK, h.request_id, 0, 0, 0, 0};
      (void)!send(f->fd, &bm, sizeof(bm), MSG_NOSIGNAL);
      f->reply = R_INLINE16; /* and answer any later request normally */
      continue;
    }
    if (f->reply == R_INLINE16) {
      fk_send(f, KOMIRA_UDF_OP_OK, h.request_id, KOMIRA_UDF_WIRE_INLINE, 0, 16, body, 16);
    } else if (f->reply == R_SUM) {
      uint32_t ok = sum == f->sum_want;
      fk_send(f, KOMIRA_UDF_OP_OK, h.request_id, KOMIRA_UDF_WIRE_INLINE, 0, 4, &ok, 4);
    } else if (f->reply == R_HEAP) {
      if (f->shm != NULL && f->heap_len && f->heap_off + f->heap_len <= PYW_HEAP_BYTES)
        memcpy(f->shm + PYW_CTRL_BYTES + PYW_HEAP_BYTES + f->heap_off, body, f->heap_len);
      fk_send(f, KOMIRA_UDF_OP_OK, h.request_id, 0, f->heap_off, f->heap_len, NULL, 0);
    } else if (f->reply == R_CHUNKED) {
      komira_udf_wire_header r = {KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_OK, h.request_id, KOMIRA_UDF_WIRE_INLINE, 0,
                                  0, 1000};
      uint8_t all[40 + 1000];
      memcpy(all, &r, 40);
      memcpy(all + 40, body, 1000);
      for (size_t at = 0; at < sizeof(all); at += 7) {
        (void)!send(f->fd, all + at, sizeof(all) - at < 7 ? sizeof(all) - at : 7, MSG_NOSIGNAL);
        usleep(100);
      }
    }
    if (f->shm != NULL && f->set_cancel_after) *fk_ctrl(f, PYW_CTRL_CANCEL) = (uint32_t)f->set_cancel_after;
  }
done:
  if (f->shm != NULL) munmap(f->shm, PYW_SHM_BYTES);
  f->shm = NULL;
  close(f->fd);
  return NULL;
}

/* ---- the engine side -------------------------------------------------------- */

static int count_fds(void) {
  int n = 0;
  char path[64];
  for (int fd = 0; fd < 4096; fd++) {
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    n += access(path, F_OK) == 0;
  }
  return n;
}

static int count_maps(const char* name) {
  FILE* f = fopen("/proc/self/maps", "r");
  if (f == NULL) return -1;
  char line[512];
  int n = 0;
  while (fgets(line, sizeof(line), f) != NULL) n += strstr(line, name) != NULL;
  fclose(f);
  return n;
}

struct logs {
  int full, room, full_level, room_level;
};

static int64_t clock_calls;
static volatile int32_t* cancel_on_read; /* now_ns sets this flag when not NULL */
static int64_t count_now(void* hd) {
  (void)hd;
  if (cancel_on_read != NULL) __atomic_store_n(cancel_on_read, 1, __ATOMIC_RELEASE);
  return ++clock_calls;
}
static void collect_log(void* hd, int32_t level, const char* m) {
  struct logs* l = hd;
  if (strstr(m, "heap full") != NULL) l->full++, l->full_level = level;
  if (strstr(m, "room again") != NULL) l->room++, l->room_level = level;
}
static void no_release(struct ArrowArray* a) { a->release = NULL; }

#define VALS ((1 << 20) + 4096) /* enough rows for a batch over the heap's 8 MiB */

struct rig {
  struct fake f;
  struct pyw_chan c;
  pthread_t t;
  struct logs logs;
  komira_udf_host host;
  int64_t* vals;
};

static int rig_open(struct rig* r, int sndbuf) {
  memset(r, 0, sizeof(*r));
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0) return -1;
  if (sndbuf) {
    setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    setsockopt(sv[1], SOL_SOCKET, SO_RCVBUF, &sndbuf, sizeof(sndbuf));
  }
  r->f.fd = sv[1];
  r->f.reply = R_INLINE16;
  r->vals = calloc(VALS, 8);
  for (int i = 0; i < VALS; i++) r->vals[i] = i * 3 + 1;
  r->host = (komira_udf_host){sizeof(komira_udf_host), KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, &r->logs, NULL,
                              NULL, count_now, collect_log};
  if (pthread_create(&r->t, NULL, fake_main, &r->f) != 0) return -1;
  char why[300];
  /* pid 0: nothing to signal or wait for at close */
  return pyw_chan_adopt(&r->c, sv[0], 0, why, sizeof(why));
}

static void rig_close(struct rig* r) {
  pyw_chan_close(&r->c);
  pthread_join(r->t, NULL);
  free(r->vals);
}

/* One CALL_BATCH of `n` int64 rows; returns pyw_chan_call's result. */
static int rig_call(struct rig* r, int64_t n, const volatile int32_t* cancel, struct pyw_reply* rep) {
  const void* bufs[2] = {NULL, r->vals};
  struct ArrowArray col = {n, 0, 0, 2, 0, bufs, NULL, NULL, no_release, NULL};
  const struct ArrowArray* cols[1] = {&col};
  struct ArrowArray args = col;
  int w[1] = {8};
  uint8_t head[64] = {0};
  komira_udf_call call = {sizeof(call), 0, 1, cancel};
  int killed = 0;
  return pyw_chan_call(&r->c, head, sizeof(head), n, cols, w, 1, &args, &call, &r->host, rep, &killed);
}

/* The total size of one call's message: the 64-byte head and the batch. */
static uint64_t call_size(struct rig* r, int64_t n) {
  const void* bufs[2] = {NULL, r->vals};
  struct ArrowArray col = {n, 0, 0, 2, 0, bufs, NULL, NULL, NULL, NULL};
  const struct ArrowArray* cols[1] = {&col};
  int w[1] = {8};
  return 64 + pyw_ipc_batch_size(n, cols, w, 1);
}

struct expect {
  int64_t wrong;
  char first[160];
};

static void want(struct expect* x, int ok, const char* what, long long got) {
  if (ok) return;
  if (!x->wrong) snprintf(x->first, sizeof(x->first), "%s (got %lld)", what, got);
  x->wrong++;
}

static void slots_case(struct pj* j) {
  struct rig r;
  struct expect x = {0, ""};
  if (rig_open(&r, 0) != 0) {
    pj_case(j, "slots", -1, "rig", 0);
    return;
  }
  struct pyw_reply rep;
  const int64_t BIG = 120000; /* about 0.92 MiB a call */
  uint64_t S = call_size(&r, BIG);
  /* three held: slots 0, 1, 2 at 0, S, 2S */
  for (int i = 0; i < 3; i++) {
    rig_call(&r, BIG, NULL, &rep);
    pyw_reply_free(&rep);
  }
  for (int i = 0; i < 3; i++) {
    want(&x, r.f.seen[i].slot == (uint32_t)i && r.f.seen[i].off == (uint64_t)i * S, "three held", i);
    want(&x, !(r.f.seen[i].flags & KOMIRA_UDF_WIRE_INLINE) && r.f.seen[i].len == S, "in a slot, its size", i);
  }
  /* slot 1 released (pushed while the next call is answered): the next
   * batch of the same size takes the hole */
  r.f.push[0] = 1, r.f.npush = 1;
  rig_call(&r, 1, NULL, &rep); /* a small one, slot 3 after 2S + S */
  pyw_reply_free(&rep);
  r.f.npush = 0;
  rig_call(&r, BIG, NULL, &rep);
  pyw_reply_free(&rep);
  want(&x, r.f.seen[3].slot == 3 && r.f.seen[3].off == 3 * S, "a small batch after the three", (long long)r.f.seen[3].off);
  want(&x, r.f.seen[4].slot == 1 && r.f.seen[4].off == S, "the hole reused", (long long)r.f.seen[4].off);
  /* slots 0 and 1 released: a batch of twice the size starts at 0 */
  r.f.push[0] = 0, r.f.push[1] = 1, r.f.npush = 2;
  rig_call(&r, 1, NULL, &rep); /* slot 0 is still held: after slot 3 */
  pyw_reply_free(&rep);
  r.f.npush = 0;
  rig_call(&r, 2 * BIG, NULL, &rep);
  pyw_reply_free(&rep);
  uint64_t small = call_size(&r, 1);
  want(&x, r.f.seen[5].slot == 4 && r.f.seen[5].off == 3 * S + small, "a small batch after slot 3",
       (long long)r.f.seen[5].off);
  want(&x, r.f.seen[6].slot == 0 && r.f.seen[6].off == 0 && r.f.seen[6].len == call_size(&r, 2 * BIG),
       "two adjacent free slots joined", (long long)r.f.seen[6].off);
  /* held now: 0 [0, 2S'), 2 [2S, 3S), 3, 4 small; fill the heap */
  int k = 7, inline_at = -1;
  for (; k < 20 && inline_at < 0; k++) {
    rig_call(&r, BIG, NULL, &rep);
    pyw_reply_free(&rep);
    if (r.f.seen[k].flags & KOMIRA_UDF_WIRE_INLINE) inline_at = k;
  }
  want(&x, inline_at > 0 && r.f.seen[inline_at].slot == 0 && r.f.seen[inline_at].off == 0, "a full heap: inline",
       inline_at);
  want(&x, r.logs.full == 1 && r.logs.full_level == 2, "heap full logged once, as a warning", r.logs.full);
  rig_call(&r, BIG, NULL, &rep); /* still full: inline, not logged again */
  pyw_reply_free(&rep);
  want(&x, r.logs.full == 1 && (r.f.seen[k].flags & KOMIRA_UDF_WIRE_INLINE), "full again: logged once", r.logs.full);
  k++;
  /* every slot released (and ids outside the table, ignored) */
  for (int i = 0; i < 64; i++) r.f.push[i] = (uint32_t)i;
  r.f.push[64] = 64, r.f.push[65] = 1000, r.f.npush = 66;
  rig_call(&r, BIG, NULL, &rep); /* inline: the releases come with its answer */
  pyw_reply_free(&rep);
  k++;
  r.f.npush = 0;
  rig_call(&r, BIG, NULL, &rep);
  pyw_reply_free(&rep);
  want(&x, r.f.seen[k].slot == 0 && r.f.seen[k].off == 0 && !(r.f.seen[k].flags & KOMIRA_UDF_WIRE_INLINE),
       "every slot free again: slot 0 at 0", (long long)r.f.seen[k].off);
  want(&x, r.logs.room == 1 && r.logs.room_level == 3, "room again logged once", r.logs.room);
  k++;
  /* 64 small ones held (one is already, slot 0): the next is inline */
  int first64 = k;
  for (int i = 0; i < 64; i++, k++) {
    rig_call(&r, 1, NULL, &rep);
    pyw_reply_free(&rep);
  }
  int slotted = 0;
  for (int i = first64; i < first64 + 63; i++) slotted += !(r.f.seen[i].flags & KOMIRA_UDF_WIRE_INLINE);
  want(&x, slotted == 63, "63 more slots held", slotted);
  want(&x, (r.f.seen[first64 + 63].flags & KOMIRA_UDF_WIRE_INLINE) != 0, "a 65th slot: inline", first64 + 63);
  int slotted_all = 0, inl_all = 0;
  for (int i = 0; i < r.f.nseen; i++) {
    if (r.f.seen[i].op != KOMIRA_UDF_OP_CALL_BATCH) continue;
    if (r.f.seen[i].flags & KOMIRA_UDF_WIRE_INLINE) inl_all++;
    else slotted_all++;
  }
  want(&x, r.c.slot_sends == slotted_all && r.c.inline_sends == inl_all, "the channel's send counts",
       (long long)r.c.slot_sends);
  int why_clean = 1;
  for (size_t b = 0; b < sizeof(r.c.why); b++) why_clean &= r.c.why[b] == 0;
  want(&x, why_clean, "nothing written into the channel's reason", 0);
  pj_case(j, "slots", 0, x.first, x.wrong);
  rig_close(&r);

  /* A batch of exactly the heap's size takes a slot; one over it goes
   * inline. */
  struct expect z = {0, ""};
  if (rig_open(&r, 0) != 0) return;
  int64_t fit = 0;
  for (int64_t n = (PYW_HEAP_BYTES - 4096) / 8; n <= PYW_HEAP_BYTES / 8 && !fit; n++)
    if (call_size(&r, n) == PYW_HEAP_BYTES) fit = n;
  want(&z, fit > 0, "a row count whose batch is the heap's size", 0);
  if (fit > 0) {
    r.f.push[0] = 0, r.f.npush = 1; /* released with its answer */
    rig_call(&r, fit, NULL, &rep);
    pyw_reply_free(&rep);
    r.f.npush = 0;
    rig_call(&r, fit + 8, NULL, &rep);
    pyw_reply_free(&rep);
    want(&z, r.f.nseen == 2, "two calls answered", r.f.nseen);
    want(&z, !(r.f.seen[0].flags & KOMIRA_UDF_WIRE_INLINE) && r.f.seen[0].off == 0, "the heap's size: a slot", 0);
    want(&z, (r.f.seen[1].flags & KOMIRA_UDF_WIRE_INLINE) && r.f.seen[1].len == call_size(&r, fit + 8),
         "over the heap: inline, whole", (long long)r.f.seen[1].len);
  }
  pj_case(j, "slots_heap_size", 0, z.first, z.wrong);
  rig_close(&r);

  /* The ring wrapping: 300 calls, each slot released with its answer. */
  struct expect y = {0, ""};
  if (rig_open(&r, 0) != 0) return;
  for (int i = 0; i < 300; i++) {
    r.f.push[0] = 0, r.f.npush = 1;
    rig_call(&r, 1, NULL, &rep);
    pyw_reply_free(&rep);
    want(&y, r.f.seen[i].slot == 0 && r.f.seen[i].off == 0, "each call in slot 0 at 0", i);
  }
  pj_case(j, "slots_ring_wrap", 0, y.first, y.wrong);
  rig_close(&r);
}

static void clock_cancel_cases(struct pj* j) {
  struct rig r;
  struct pyw_reply rep;
  if (rig_open(&r, 0) != 0) return;
  /* three clock reads during a call: each forwarded to now_ns once and
   * answered with CLOCK (value: reads + acks * 10 + bad acks * 100) */
  r.f.clock_msgs = 3;
  clock_calls = 0;
  int rc = rig_call(&r, 4, NULL, &rep);
  pyw_reply_free(&rep);
  pj_case(j, "clock_messages", rc, "", clock_calls + r.f.clock_acks * 10 + r.f.ack_bad * 100);
  /* the host sets the cancel flag inside now_ns: the flag is in the control
   * page before CLOCK comes back, so the worker's next check sees it */
  volatile int32_t on_read = 0;
  cancel_on_read = &on_read;
  r.f.clock_msgs = 1;
  r.f.cancel_word_at_ack = -1;
  rc = rig_call(&r, 4, &on_read, &rep);
  pyw_reply_free(&rep);
  cancel_on_read = NULL;
  pj_case(j, "clock_cancel_before_ack", rc, "", r.f.cancel_word_at_ack);
  r.f.clock_msgs = 0;
  /* cancelled from the start: the flag in the control page, then CANCEL */
  volatile int32_t flag = 1;
  r.f.wait_cancel = 1;
  r.f.set_cancel_after = 5;
  rc = rig_call(&r, 4, &flag, &rep);
  pyw_reply_free(&rep);
  struct seen call = r.f.seen[r.f.nseen - 1], c = r.f.cancel;
  int64_t bad = (c.op != KOMIRA_UDF_OP_CANCEL) + (c.id != call.id) * 10 + (c.flags || c.slot || c.off || c.len) * 100 +
                (r.f.cancel_word_at_cancel != 1) * 1000;
  pj_case(j, "cancel_shm", rc, "", bad);
  r.f.wait_cancel = 0;
  r.f.set_cancel_after = 0;
  rc = rig_call(&r, 4, NULL, &rep); /* the flag was left at 5: cleared before this call */
  pyw_reply_free(&rep);
  pj_case(j, "cancel_cleared", rc, "", r.f.seen[r.f.nseen - 1].cancel_word);
  rig_close(&r);
}

static void heap_cases(struct pj* j) {
  const struct {
    const char* name;
    uint64_t off, len;
  } k[6] = {
      {"heap_start", 0, 16},
      {"heap_last_bytes", PYW_HEAP_BYTES - 16, 16},
      {"heap_one_past", PYW_HEAP_BYTES - 15, 16},
      {"heap_offset_at_end", PYW_HEAP_BYTES, 1},
      {"heap_empty_at_end", PYW_HEAP_BYTES, 0},
      {"heap_empty_past_end", PYW_HEAP_BYTES + 64, 0},
  };
  for (int i = 0; i < 6; i++) {
    struct rig r;
    if (rig_open(&r, 0) != 0) return;
    r.f.reply = R_HEAP;
    r.f.heap_off = k[i].off;
    r.f.heap_len = k[i].len;
    struct pyw_reply rep;
    int rc = pyw_chan_request(&r.c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &rep);
    int64_t same = 0;
    if (rc == 0) {
      same = (int64_t)rep.len;
      for (size_t b = 0; b < rep.len; b++) same += (rep.payload[b] != (uint8_t)(b * 31 + 7)) * 1000;
      pyw_reply_free(&rep);
    }
    struct seen q = r.f.nseen ? r.f.seen[0] : (struct seen){0};
    same += (q.flags || q.slot || q.off || q.len) * 100000; /* a request without a body: all zero */
    pj_case(j, k[i].name, rc, rc ? r.c.why : "taken", same);
    rig_close(&r);
  }
}

static void on_tick(int sig) { (void)sig; }

/* SIGUSR2 to the engine thread every 300 us from a helper thread, the
 * handler installed without SA_RESTART: a blocking sendmsg returns early
 * with what it sent (or EINTR before any byte). */
struct ticker {
  pthread_t target, t;
  volatile int stop;
};

static void* tick_main(void* p) {
  struct ticker* k = p;
  while (!k->stop) {
    pthread_kill(k->target, SIGUSR2);
    usleep(300);
  }
  return NULL;
}

static int tick_start(struct ticker* k) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = on_tick;
  sigaction(SIGUSR2, &sa, NULL);
  k->target = pthread_self();
  k->stop = 0;
  return pthread_create(&k->t, NULL, tick_main, k);
}

static void tick_stop(struct ticker* k) {
  k->stop = 1;
  pthread_join(k->t, NULL);
  signal(SIGUSR2, SIG_IGN);
}

static void partial_cases(struct pj* j) {
  struct rig r;
  struct pyw_reply rep;
  if (rig_open(&r, 4096) != 0) return;
  /* the message the engine writes: head, then the batch */
  const int64_t n = PYW_HEAP_BYTES / 8 + 1024; /* over the heap: the batch goes inline */
  const void* bufs[2] = {NULL, r.vals};
  struct ArrowArray col = {n, 0, 0, 2, 0, bufs, NULL, NULL, NULL, NULL};
  const struct ArrowArray* cols[1] = {&col};
  int w[1] = {8};
  size_t sz = pyw_ipc_batch_size(n, cols, w, 1);
  uint8_t* msg = aligned_alloc(PYW_ALIGN, 64 + sz);
  memset(msg, 0, 64);
  pyw_ipc_batch_write(msg + 64, n, cols, w, 1);
  r.f.sum_want = fnv(msg, 64 + sz, 2166136261u);
  free(msg);
  r.f.reply = R_SUM;
  struct ticker tick;
  int ticking = tick_start(&tick) == 0;
  int rc = rig_call(&r, n, NULL, &rep);
  if (ticking) tick_stop(&tick);
  uint32_t ok = 0;
  if (rc == 0 && rep.len == 4) memcpy(&ok, rep.payload, 4);
  pyw_reply_free(&rep);
  pj_case(j, "partial_send", rc, ticking ? "" : "no timer", ok);
  r.f.reply = R_CHUNKED;
  ticking = tick_start(&tick) == 0;
  rc = pyw_chan_request(&r.c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &rep);
  if (ticking) tick_stop(&tick);
  int64_t same = 0;
  if (rc == 0) {
    same = (int64_t)rep.len;
    for (size_t b = 0; b < rep.len; b++) same += (rep.payload[b] != (uint8_t)(b * 31 + 7)) * 10000;
    pyw_reply_free(&rep);
  }
  pj_case(j, "partial_recv", rc, "", same);
  rig_close(&r);
}

static void closed_cases(struct pj* j) {
  struct rig r;
  struct pyw_reply rep;
  /* the fake closes its end when the first request comes (no reply) */
  if (rig_open(&r, 0) != 0) return;
  r.f.reply = R_CLOSE;
  int rc = pyw_chan_request(&r.c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &rep);
  pj_case(j, "eof_before_reply", rc, r.c.why, r.c.dead);
  /* then a write to it is refused */
  rc = pyw_chan_request(&r.c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &rep);
  pj_case(j, "dead_channel", rc, r.c.why, r.c.dead);
  rig_close(&r);
  if (rig_open(&r, 0) != 0) return;
  r.f.reply = R_CLOSE;
  (void)pyw_chan_request(&r.c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &rep); /* fake gone */
  r.c.dead = 0; /* as if the engine had not seen it: the next write fails */
  r.c.why[0] = 0;
  usleep(20000);
  rc = pyw_chan_request(&r.c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &rep);
  pj_case(j, "write_refused", rc, r.c.why, r.c.dead);
  rig_close(&r);
  /* a reply without the magic from a worker that stays: the channel is
   * dead, and the next request is refused without being sent */
  if (rig_open(&r, 0) != 0) return;
  r.f.reply = R_BADMAGIC;
  int rc1 = pyw_chan_request(&r.c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &rep);
  rc = pyw_chan_request(&r.c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &rep);
  if (rc == 0) pyw_reply_free(&rep);
  pj_case(j, "dead_not_sent", rc1 * 10 + rc, r.c.why, r.f.nseen);
  rig_close(&r);
  /* a reply of exactly 2 GiB is taken (then the worker is gone) */
  if (rig_open(&r, 0) != 0) return;
  r.f.reply = R_HUGE_EOF;
  rc = pyw_chan_request(&r.c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &rep);
  pj_case(j, "reply_exactly_2gib", rc, r.c.why, 0);
  rig_close(&r);
  /* close: SHUTDOWN with no payload; every descriptor and the mapping
   * released */
  int fds0 = count_fds(), maps0 = count_maps("komira-udf-worker");
  if (rig_open(&r, 0) != 0) return;
  rig_call(&r, 4, NULL, &rep);
  pyw_reply_free(&rep);
  rig_close(&r);
  struct seen sd = r.f.shutdown;
  int64_t v = (r.f.got_shutdown != 1) + (sd.flags || sd.slot || sd.off || sd.len) * 10 +
              (count_fds() != fds0) * 100 + (count_maps("komira-udf-worker") != maps0) * 1000;
  pj_case(j, "close_releases", maps0, "", v);
}

/* ---- a fake worker process that is not the engine's child ------------------ */

struct reaper {
  pid_t pid;
  int status;
};

static void* reap(void* p) {
  struct reaper* r = p;
  while (waitpid(r->pid, &r->status, 0) < 0 && errno == EINTR) {
  }
  return NULL;
}

/* The forked fake: answers HELLO, then on SHUTDOWN (or end of file) waits
 * `exit_ms` and exits 0, or (exit_ms < 0) never exits on its own. Only
 * async-signal-safe calls. */
static void child_fake(int fd, int exit_ms) {
  komira_udf_wire_header h;
  char sink[512];
  for (;;) {
    size_t at = 0;
    while (at < sizeof(h)) {
      ssize_t r = recv(fd, (char*)&h + at, sizeof(h) - at, 0);
      if (r <= 0) goto out;
      at += (size_t)r;
    }
    for (uint64_t left = (h.flags & KOMIRA_UDF_WIRE_INLINE) ? h.payload_len : 0; left > 0;) {
      ssize_t r = recv(fd, sink, left < sizeof(sink) ? left : sizeof(sink), 0);
      if (r <= 0) goto out;
      left -= (uint64_t)r;
    }
    if (h.op == KOMIRA_UDF_OP_SHUTDOWN) break;
    uint32_t body[4] = {KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, 0};
    komira_udf_wire_header r = {KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_OK, h.request_id, KOMIRA_UDF_WIRE_INLINE, 0, 0, 16};
    (void)!send(fd, &r, sizeof(r), MSG_NOSIGNAL);
    (void)!send(fd, body, 16, MSG_NOSIGNAL);
  }
out:
  if (exit_ms < 0) {
    for (;;) pause();
  }
  struct timespec ts = {exit_ms / 1000, (exit_ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
  _exit(0);
}

static void reap_case(struct pj* j, const char* name, int exit_ms) {
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0) return;
  pid_t pid = fork();
  if (pid == 0) {
    close(sv[0]);
    child_fake(sv[1], exit_ms);
  }
  close(sv[1]);
  if (pid < 0) {
    close(sv[0]);
    pj_case(j, name, -1, "fork failed", 0);
    return;
  }
  struct reaper rp = {pid, -1};
  pthread_t t;
  pthread_create(&t, NULL, reap, &rp);
  struct pyw_chan c;
  char why[300];
  int rc = pyw_chan_adopt(&c, sv[0], pid, why, sizeof(why)); /* not ours: a zygote's, as it were */
  int64_t t0 = now_ms();
  pyw_chan_close(&c);
  int64_t ms = now_ms() - t0;
  pthread_join(t, NULL);
  char m[96];
  snprintf(m, sizeof(m), "%s", WIFEXITED(rp.status) ? "exited" : WIFSIGNALED(rp.status) ? "killed" : "?");
  pj_case(j, name, rc, m, ms);
}

void kpw_fake_cases(struct pj* j) {
  slots_case(j);
  clock_cancel_cases(j);
  heap_cases(j);
  partial_cases(j);
  closed_cases(j);
  reap_case(j, "reap_exits", 300);
  reap_case(j, "reap_ignores", -1);
}
