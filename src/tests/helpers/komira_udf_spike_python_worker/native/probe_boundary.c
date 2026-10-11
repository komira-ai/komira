/*
 * The worker boundary's checks, case by case: what the engine side refuses
 * from a worker, and what the worker refuses from the engine at HELLO.
 * Test-only spike code (tests/test_worker_boundary.mojo).
 *
 *   codec   native/probe_codec.c's cases (the engine-side codec).
 *   hello   a real worker (posix_spawned, pyw_chan_start) sent a DESCRIBE
 *           before any HELLO, then HELLO with each of the wire version, ABI
 *           major and ABI minor off by one, a DESCRIBE again, then the
 *           right HELLO and a last DESCRIBE (section 5.2: any difference is
 *           refused, and nothing is served before HELLO is taken).
 *   faults  the engine side against a fake worker on a socket pair: a HELLO
 *           reply off in the wire version, the major or the minor, short,
 *           or refusing; then, after a good HELLO, a reply without the
 *           magic, one answering another request, one of an op other than
 *           OK or ERROR, a payload outside the heap or over 2 GiB, and an
 *           end of file inside a payload; and the same reply checks on a
 *           call (pyw_chan_call), with a clock read before the answer.
 *   fake    native/probe_fake.c's cases (the channel against a scripted
 *           fake worker).
 * Each case is one member of the JSON object kpw_probe_boundary returns:
 * {"status": 0 or what the engine returned, "message": its reason, "value":
 * a count the case names}. kpw_free (drive.c) frees it.
 *
 * FFI-BOUNDARY. Every buffer and array here is this file's: decoded arrays
 * are released before the case ends; a fake worker's socket end is closed
 * by its thread, the engine's by pyw_chan_close; a spawned worker is shut
 * down and reaped by pyw_chan_close.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#include "probe_json.h"
#include "pyw.h"

/* The codec cases are native/probe_codec.c's. */
void kpw_codec_cases(struct pj* j);
/* The scripted fake worker's cases are native/probe_fake.c's. */
void kpw_fake_cases(struct pj* j);

/* ---- HELLO to a real worker ----------------------------------------------- */

static void hello_body(struct pyw_buf* b, uint32_t wire, uint32_t major, uint32_t minor) {
  pyw_buf_u32(b, wire);
  pyw_buf_u32(b, major);
  pyw_buf_u32(b, minor);
  pyw_buf_u32(b, 0); /* no shared memory */
  pyw_buf_u64(b, 0);
  pyw_buf_u64(b, 0);
}

static void hello_cases(struct pj* j, const char* arg) {
  char dir[4096];
  if (realpath(arg, dir) == NULL) {
    pj_case(j, "worker_start", -1, "the runtime directory does not resolve", 0);
    return;
  }
  struct pyw_chan c;
  struct pyw_launch l = {dir, "control", "own", 1};
  char why[300];
  if (pyw_chan_start(&c, &l, why, sizeof(why)) != 0) {
    pj_case(j, "worker_start", -1, why, 0);
    return;
  }
  /* A DESCRIBE before any HELLO, after the refused ones and after the
   * taken one: only the last is served. */
  const struct {
    const char* name;
    uint32_t op, wire, major, minor;
  } k[7] = {
      {"worker_describe_first", KOMIRA_UDF_OP_DESCRIBE, 0, 0, 0},
      {"worker_wire", KOMIRA_UDF_OP_HELLO, KOMIRA_UDF_WIRE_VERSION + 1, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR},
      {"worker_major", KOMIRA_UDF_OP_HELLO, KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR + 1, KOMIRA_UDF_ABI_MINOR},
      {"worker_minor", KOMIRA_UDF_OP_HELLO, KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR + 1},
      {"worker_describe_refused", KOMIRA_UDF_OP_DESCRIBE, 0, 0, 0},
      {"worker_same", KOMIRA_UDF_OP_HELLO, KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR},
      {"worker_describe_after", KOMIRA_UDF_OP_DESCRIBE, 0, 0, 0},
  };
  for (int i = 0; i < 7; i++) {
    struct pyw_buf b = {0};
    if (k[i].op == KOMIRA_UDF_OP_HELLO) hello_body(&b, k[i].wire, k[i].major, k[i].minor);
    struct pyw_reply r;
    if (pyw_chan_request(&c, k[i].op, k[i].op == KOMIRA_UDF_OP_HELLO ? &b : NULL, NULL, 0, &r) != 0) {
      pj_case(j, k[i].name, -1, c.why, 0);
      pyw_buf_free(&b);
      break;
    }
    pyw_buf_free(&b);
    struct pyw_rd d = {r.payload, r.len, 0, 0};
    if (r.op == KOMIRA_UDF_OP_ERROR) {
      int32_t code = pyw_rd_i32(&d);
      (void)pyw_rd_i64(&d);
      (void)pyw_rd_i64(&d);
      char* m = pyw_rd_str(&d);
      pj_case(j, k[i].name, code, m ? m : "(malformed)", 0);
      free(m);
    } else if (k[i].op == KOMIRA_UDF_OP_DESCRIBE) {
      /* OK: the runtime id first. */
      char* id = pyw_rd_str(&d);
      pj_case(j, k[i].name, d.bad ? -1 : 0, id ? id : "(malformed)", 0);
      free(id);
    } else {
      /* OK: the worker's own wire, major and minor, then its pid. */
      uint32_t w = pyw_rd_u32(&d), ma = pyw_rd_u32(&d), mi = pyw_rd_u32(&d);
      int32_t pid = pyw_rd_i32(&d);
      char m[160];
      snprintf(m, sizeof(m), "OK wire %u ABI %u.%u", w, ma, mi);
      pj_case(j, k[i].name, d.bad ? -1 : 0, m, pid == c.pid);
    }
    pyw_reply_free(&r);
  }
  pyw_chan_close(&c);
}

/* ---- a fake worker -------------------------------------------------------- */

enum fake_hello { FH_GOOD, FH_WIRE, FH_MAJOR, FH_MINOR, FH_SHORT, FH_REFUSE };
enum fake_reply {
  FR_NONE,
  FR_MAGIC,
  FR_OTHER_ID,
  FR_WRONG_OP,
  FR_OUTSIDE_HEAP,
  FR_HUGE,
  FR_EOF_IN_PAYLOAD,
  FR_OK,
  FR_CLOCK_THEN_OK
};

struct fake {
  int fd;
  enum fake_hello hello;
  enum fake_reply reply;
};

static int fake_read(int fd, komira_udf_wire_header* h) {
  size_t at = 0;
  while (at < sizeof(*h)) {
    ssize_t r = recv(fd, (char*)h + at, sizeof(*h) - at, 0);
    if (r <= 0) return -1;
    at += (size_t)r;
  }
  if (!(h->flags & KOMIRA_UDF_WIRE_INLINE)) return 0;
  char sink[256];
  for (uint64_t left = h->payload_len; left > 0;) {
    ssize_t r = recv(fd, sink, left < sizeof(sink) ? left : sizeof(sink), 0);
    if (r <= 0) return -1;
    left -= (uint64_t)r;
  }
  return 0;
}

static void fake_send(int fd, uint32_t magic, uint32_t op, uint64_t id, uint32_t flags, uint64_t off, uint64_t len,
                      const void* body, size_t body_len) {
  komira_udf_wire_header h = {magic, op, id, flags, 5, off, len}; /* slot: a reply's worker ns */
  (void)!send(fd, &h, sizeof(h), MSG_NOSIGNAL);
  if (body_len) (void)!send(fd, body, body_len, MSG_NOSIGNAL);
}

static void* fake_main(void* p) {
  struct fake* f = p;
  komira_udf_wire_header h;
  if (fake_read(f->fd, &h) == 0) {
    struct pyw_buf b = {0};
    uint32_t op = KOMIRA_UDF_OP_OK;
    if (f->hello == FH_REFUSE) {
      op = KOMIRA_UDF_OP_ERROR;
      pyw_buf_i32(&b, KOMIRA_UDF_ERR_ABI);
      pyw_buf_u64(&b, (uint64_t)-1);
      pyw_buf_u64(&b, (uint64_t)-1);
      pyw_buf_str(&b, "this fake worker refuses");
      pyw_buf_str(&b, NULL);
    } else if (f->hello == FH_SHORT) {
      pyw_buf_u32(&b, KOMIRA_UDF_WIRE_VERSION);
    } else {
      pyw_buf_u32(&b, KOMIRA_UDF_WIRE_VERSION + (f->hello == FH_WIRE ? 1 : 0));
      pyw_buf_u32(&b, KOMIRA_UDF_ABI_MAJOR + (f->hello == FH_MAJOR ? 1 : 0));
      pyw_buf_u32(&b, KOMIRA_UDF_ABI_MINOR + (f->hello == FH_MINOR ? 1 : 0));
      pyw_buf_i32(&b, (int32_t)getpid());
    }
    fake_send(f->fd, KOMIRA_UDF_WIRE_MAGIC, op, h.request_id, KOMIRA_UDF_WIRE_INLINE, 0, b.len, b.p, b.len);
    pyw_buf_free(&b);
    if (f->reply != FR_NONE && fake_read(f->fd, &h) == 0) {
      uint64_t id = h.request_id;
      uint8_t body[16] = {1, 2, 3, 4};
      switch (f->reply) {
        case FR_MAGIC: fake_send(f->fd, 0x12345678u, KOMIRA_UDF_OP_OK, id, 0, 0, 0, NULL, 0); break;
        case FR_OTHER_ID: fake_send(f->fd, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_OK, id + 7, 0, 0, 0, NULL, 0); break;
        case FR_WRONG_OP:
          fake_send(f->fd, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_CALL_BATCH, id, KOMIRA_UDF_WIRE_INLINE, 0, 16, body, 16);
          break;
        case FR_CLOCK_THEN_OK:
          fake_send(f->fd, KOMIRA_UDF_WIRE_MAGIC, PYW_OP_CLOCK, id, 0, 0, 0, NULL, 0);
          fake_send(f->fd, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_OK, id, KOMIRA_UDF_WIRE_INLINE, 0, 16, body, 16);
          break;
        case FR_OUTSIDE_HEAP:
          fake_send(f->fd, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_OK, id, 0, PYW_HEAP_BYTES - 8, 64, NULL, 0);
          break;
        case FR_HUGE:
          fake_send(f->fd, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_OK, id, KOMIRA_UDF_WIRE_INLINE, 0, 3ull << 30, NULL, 0);
          break;
        case FR_EOF_IN_PAYLOAD:
          fake_send(f->fd, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_OK, id, KOMIRA_UDF_WIRE_INLINE, 0, 100, body, 16);
          shutdown(f->fd, SHUT_WR);
          break;
        case FR_OK: fake_send(f->fd, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_OK, id, KOMIRA_UDF_WIRE_INLINE, 0, 16, body, 16); break;
        default: break;
      }
    }
  }
  char sink[256];
  while (recv(f->fd, sink, sizeof(sink), 0) > 0) {
  }
  close(f->fd);
  return NULL;
}

static int64_t clock_reads;
static int64_t count_now(void* hd) {
  (void)hd;
  return ++clock_reads;
}
static void one_release(struct ArrowArray* a) { a->release = NULL; }

/* A CALL_BATCH of one int64 row through pyw_chan_call (no cancel, no
 * deadline): 0 and the reply, or -1. */
static int call_fake(struct pyw_chan* c, struct pyw_reply* r) {
  static const int64_t one = 7;
  const void* bufs[2] = {NULL, &one};
  struct ArrowArray col = {1, 0, 0, 2, 0, bufs, NULL, NULL, one_release, NULL};
  const struct ArrowArray* cols[1] = {&col};
  struct ArrowArray args = col;
  int w[1] = {8};
  uint8_t head[64] = {0};
  komira_udf_call call = {sizeof(call), 0, 1, NULL};
  komira_udf_host host = {sizeof(host), KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, NULL, NULL, NULL, count_now, NULL};
  int killed = 0;
  clock_reads = 0;
  return pyw_chan_call(c, head, sizeof(head), 1, cols, w, 1, &args, &call, &host, r, &killed);
}

/* One channel to a fake worker: HELLO answered as `fh`; then, when HELLO
 * was taken, one DESCRIBE (or, `as_call`, one CALL_BATCH) answered as `fr`.
 * Records what the engine said: for a reply taken, its length, the clock
 * reads forwarded and the worker ns summed, as len * 100 + reads * 10 + ns. */
static void fault_case(struct pj* j, const char* name, enum fake_hello fh, enum fake_reply fr, int use_shm,
                       int as_call) {
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0) {
    pj_case(j, name, -1, "socketpair failed", 0);
    return;
  }
  struct fake f = {sv[1], fh, fr};
  pthread_t t;
  if (pthread_create(&t, NULL, fake_main, &f) != 0) {
    close(sv[0]);
    close(sv[1]);
    pj_case(j, name, -1, "pthread_create failed", 0);
    return;
  }
  struct pyw_chan c;
  char why[300] = "";
  /* pid 0: nothing to signal or wait for at close. */
  if (pyw_chan_adopt(&c, sv[0], 0, use_shm, why, sizeof(why)) != 0) {
    pj_case(j, name, 1, why, c.dead);
  } else if (fr == FR_NONE) {
    pj_case(j, name, 0, "HELLO taken", 0);
  } else {
    struct pyw_reply r;
    int rc = as_call ? call_fake(&c, &r) : pyw_chan_request(&c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &r);
    if (rc != 0) {
      pj_case(j, name, 1, c.why, c.dead);
    } else {
      pj_case(j, name, 0, "a reply taken", (int64_t)r.len * 100 + (as_call ? clock_reads * 10 + c.worker_ns : 0));
      pyw_reply_free(&r);
    }
  }
  pyw_chan_close(&c);
  pthread_join(t, NULL);
}

static void fault_cases(struct pj* j) {
  fault_case(j, "engine_hello_good", FH_GOOD, FR_NONE, 0, 0);
  fault_case(j, "engine_hello_wire", FH_WIRE, FR_NONE, 0, 0);
  fault_case(j, "engine_hello_major", FH_MAJOR, FR_NONE, 0, 0);
  fault_case(j, "engine_hello_minor", FH_MINOR, FR_NONE, 0, 0);
  fault_case(j, "engine_hello_short", FH_SHORT, FR_NONE, 0, 0);
  fault_case(j, "engine_hello_refused", FH_REFUSE, FR_NONE, 0, 0);
  fault_case(j, "reply_ok", FH_GOOD, FR_OK, 0, 0);
  fault_case(j, "reply_magic", FH_GOOD, FR_MAGIC, 0, 0);
  fault_case(j, "reply_other_id", FH_GOOD, FR_OTHER_ID, 0, 0);
  fault_case(j, "reply_wrong_op", FH_GOOD, FR_WRONG_OP, 0, 0);
  fault_case(j, "reply_heap_without_shm", FH_GOOD, FR_OUTSIDE_HEAP, 0, 0);
  fault_case(j, "reply_outside_heap", FH_GOOD, FR_OUTSIDE_HEAP, 1, 0);
  fault_case(j, "reply_over_2gib", FH_GOOD, FR_HUGE, 0, 0);
  fault_case(j, "reply_eof_in_payload", FH_GOOD, FR_EOF_IN_PAYLOAD, 0, 0);
  /* The same checks on a call's reply (await_reply), and a clock read the
   * worker reports before it answers. */
  fault_case(j, "call_ok", FH_GOOD, FR_OK, 0, 1);
  fault_case(j, "call_clock_then_ok", FH_GOOD, FR_CLOCK_THEN_OK, 0, 1);
  fault_case(j, "call_other_id", FH_GOOD, FR_OTHER_ID, 0, 1);
  fault_case(j, "call_wrong_op", FH_GOOD, FR_WRONG_OP, 0, 1);
}

/* "codec", "hello" (arg: the runtime directory), "faults" or "fake". */
char* kpw_probe_boundary(const char* group, const char* arg) {
  struct pj j = {0};
  pj_open(&j);
  if (strcmp(group, "codec") == 0) kpw_codec_cases(&j);
  else if (strcmp(group, "hello") == 0) hello_cases(&j, arg);
  else if (strcmp(group, "faults") == 0) fault_cases(&j);
  else if (strcmp(group, "fake") == 0) kpw_fake_cases(&j);
  else pj_case(&j, "group", -1, "no such group", 0);
  return pj_close(&j);
}
