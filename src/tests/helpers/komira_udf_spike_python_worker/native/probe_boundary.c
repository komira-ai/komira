/*
 * The worker boundary's checks, case by case: what the engine side refuses
 * from a worker, and what the worker refuses from the engine at HELLO.
 * Test-only spike code (tests/test_worker_boundary.mojo).
 *
 *   codec   ipc_codec.c alone: pyw_ipc_decode_column on a good reply and on
 *           one malformed copy per check (section 4.4: the host validates
 *           every imported array; section 5.2: it decodes its own copy);
 *           pyw_ipc_batch_write re-basing a sliced column at every bit
 *           shift; the control-body reader past its end.
 *   hello   a real worker (posix_spawned, pyw_chan_start) sent HELLO with
 *           each of the wire version, ABI major and ABI minor off by one,
 *           then the right one (section 5.2: any difference is refused).
 *   faults  the engine side against a fake worker on a socket pair: a HELLO
 *           reply off in one version, short, or refusing; then, after a
 *           good HELLO, a reply without the magic, one answering another
 *           request, a payload outside the heap or over 2 GiB, and an end
 *           of file inside a payload.
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
#include <sys/socket.h>
#include <unistd.h>

#include "probe_json.h"
#include "pyw.h"

/* ---- codec --------------------------------------------------------------- */

/* A one-column int64 batch of `n` rows over `values` (from `off`), with
 * `valid` (or NULL) and `nulls`, written by the engine's writer into a
 * malloc block; its size in *len. */
static uint8_t* write_column(const int64_t* values, const uint8_t* valid, int64_t off, int64_t n, int64_t nulls,
                             size_t* len) {
  const void* bufs[2] = {valid, values};
  struct ArrowArray a = {n, nulls, off, 2, 0, bufs, NULL, NULL, NULL, NULL};
  const struct ArrowArray* cols[1] = {&a};
  int w[1] = {8};
  size_t sz = pyw_ipc_batch_size(n, cols, w, 1);
  uint8_t* tmp = aligned_alloc(PYW_ALIGN, (sz + PYW_ALIGN - 1) & ~(size_t)(PYW_ALIGN - 1));
  if (tmp == NULL) return NULL;
  pyw_ipc_batch_write(tmp, n, cols, w, 1);
  uint8_t* m = malloc(sz);
  if (m != NULL) memcpy(m, tmp, sz);
  free(tmp);
  *len = sz;
  return m;
}

/* Decodes a copy of the first `len` bytes of `msg`: NULL and `out` filled
 * (its release frees the copy), or the reason (the copy freed). */
static const char* decode_copy(const uint8_t* msg, size_t len, struct ArrowArray* out) {
  uint8_t* m = malloc(len ? len : 1);
  if (m == NULL) return "out of memory";
  memcpy(m, msg, len);
  const char* why = pyw_ipc_decode_column(m, len, 8, out);
  if (why != NULL) free(m);
  return why;
}

/* Replaces the one 16-byte {a, b} pair of int64s in the metadata by
 * {a2, b2}; 0 when the pair is not there exactly once. */
static int patch_pair(uint8_t* msg, int64_t a, int64_t b, int64_t a2, int64_t b2) {
  int32_t meta;
  memcpy(&meta, msg + 4, 4);
  int64_t want[2] = {a, b}, put[2] = {a2, b2};
  int found = -1, count = 0;
  for (int i = 8; i + 16 <= 8 + meta; i += 8)
    if (memcmp(msg + i, want, 16) == 0) {
      found = i;
      count++;
    }
  if (count != 1) return 0;
  memcpy(msg + found, put, 16);
  return 1;
}

/* One malformed copy: the reason decode gave, or "decoded" (released). */
static void refusal(struct pj* j, const char* name, const uint8_t* good, size_t len, size_t use_len,
                    const int64_t* pat) {
  uint8_t* m = malloc(len);
  if (m == NULL) return;
  memcpy(m, good, len);
  int ok = 1;
  if (pat != NULL) ok = patch_pair(m, pat[0], pat[1], pat[2], pat[3]);
  struct ArrowArray out;
  const char* why = ok ? decode_copy(m, use_len, &out) : "fixture: the pair to patch is not there exactly once";
  if (why == NULL) {
    out.release(&out);
    why = "decoded";
  }
  pj_case(j, name, ok ? 1 : -1, why, 0);
  free(m);
}

static void codec_cases(struct pj* j) {
  enum { N = 10 };
  int64_t vals[N];
  for (int i = 0; i < N; i++) vals[i] = 100 + i;
  uint8_t valid[2] = {0xFF & ~(1u << 1) & ~(1u << 4) & ~(1u << 7), 0x03}; /* rows 1, 4, 7 null */
  size_t len = 0;
  uint8_t* good = write_column(vals, valid, 0, N, 3, &len);
  if (good == NULL) return;

  /* The good reply: every value, every null, then released. */
  struct ArrowArray out;
  const char* why = decode_copy(good, len, &out);
  int64_t bad = 0;
  if (why == NULL) {
    const int64_t* v = out.buffers[1];
    const uint8_t* b = out.buffers[0];
    bad += out.length != N || out.null_count != 3 || b == NULL;
    for (int i = 0; b != NULL && i < N; i++) {
      int is_valid = (b[i >> 3] >> (i & 7)) & 1;
      bad += is_valid != !(i == 1 || i == 4 || i == 7);
      bad += is_valid && v[i] != 100 + i;
    }
    out.release(&out);
  }
  pj_case(j, "good", why ? 1 : 0, why ? why : "decoded", bad);

  int32_t meta;
  memcpy(&meta, good + 4, 4);
  /* The body: validity at 0 (2 bytes), values at 64 (80 bytes); 192 in all. */
  refusal(j, "prefix_short", good, len, 7, NULL);
  uint8_t* m = malloc(len);
  if (m == NULL) return;
  memcpy(m, good, len);
  m[0] = 0;
  refusal(j, "continuation", m, len, len, NULL);
  memcpy(m, good, len);
  int32_t big = (int32_t)len;
  memcpy(m + 4, &big, 4);
  refusal(j, "meta_past_payload", m, len, len, NULL);
  memcpy(m, good, len);
  uint32_t root = 0x00FFFFFFu;
  memcpy(m + 8, &root, 4);
  refusal(j, "root_offset", m, len, len, NULL);
  free(m);
  refusal(j, "body_truncated", good, len, len - 1, NULL);
  const int64_t values_short[4] = {64, 80, 64, 72};
  refusal(j, "values_short", good, len, len, values_short);
  const int64_t validity_short[4] = {0, 2, 0, 1};
  refusal(j, "validity_short", good, len, len, validity_short);
  const int64_t past_body[4] = {64, 80, 160, 80};
  refusal(j, "buffer_past_body", good, len, len, past_body);
  const int64_t misaligned[4] = {64, 80, 68, 80};
  refusal(j, "misaligned", good, len, len, misaligned);
  const int64_t nulls_over[4] = {N, 3, N, N + 1};
  refusal(j, "nulls_over_length", good, len, len, nulls_over);
  const int64_t node_len[4] = {N, 3, N - 1, 3};
  refusal(j, "node_length", good, len, len, node_len);
  free(good);

  /* Two columns where the reader takes one. */
  {
    const void* bufs[2] = {NULL, vals};
    struct ArrowArray a = {N, 0, 0, 2, 0, bufs, NULL, NULL, NULL, NULL};
    const struct ArrowArray* cols[2] = {&a, &a};
    int w[2] = {8, 8};
    size_t sz = pyw_ipc_batch_size(N, cols, w, 2);
    uint8_t* t = aligned_alloc(PYW_ALIGN, (sz + PYW_ALIGN - 1) & ~(size_t)(PYW_ALIGN - 1));
    if (t != NULL) {
      pyw_ipc_batch_write(t, N, cols, w, 2);
      refusal(j, "two_columns", t, sz, sz, NULL);
      free(t);
    }
  }

  /* The writer re-basing a slice: every offset 0 .. 17 and lengths across
   * byte edges, a validity pattern with no period of 8, the null count
   * given or left for the writer to count (-1). Mismatching values or bits
   * after a round trip are counted. */
  int64_t src[64];
  uint8_t sv[8];
  for (int i = 0; i < 64; i++) src[i] = 7 * i + 1;
  for (int i = 0; i < 8; i++) sv[i] = (uint8_t)(0xB5 ^ (i * 0x3D));
  int64_t wrong = 0, cases = 0;
  const int64_t lengths[5] = {1, 7, 8, 9, 21};
  for (int64_t off = 0; off < 18; off++)
    for (int li = 0; li < 5; li++)
      for (int given = 0; given < 2; given++) {
        int64_t n = lengths[li], nulls = 0;
        for (int64_t i = 0; i < n; i++) nulls += !((sv[(off + i) >> 3] >> ((off + i) & 7)) & 1);
        size_t l2;
        uint8_t* msg = write_column(src, sv, off, n, given ? nulls : -1, &l2);
        if (msg == NULL) continue;
        cases++;
        const char* w2 = decode_copy(msg, l2, &out);
        free(msg);
        if (w2 != NULL) {
          wrong++;
          continue;
        }
        const int64_t* v = out.buffers[1];
        const uint8_t* b = out.buffers[0];
        int miss = out.null_count != nulls || (nulls > 0) != (b != NULL);
        for (int64_t i = 0; i < n && !miss; i++) {
          int sv_bit = (sv[(off + i) >> 3] >> ((off + i) & 7)) & 1;
          int got = b == NULL ? 1 : (b[i >> 3] >> (i & 7)) & 1;
          miss |= got != sv_bit || (sv_bit && v[i] != src[off + i]);
        }
        if (b != NULL && (n & 7)) miss |= (b[(n - 1) >> 3] >> (n & 7)) != 0; /* spare bits zero */
        wrong += miss;
        out.release(&out);
      }
  pj_case(j, "rebase_shifts", cases == 18 * 5 * 2 ? 0 : -1, "slices written and read back", wrong);

  /* The control-body reader: a string whose length runs past the body, an
   * i64 from 4 bytes, and a NULL string (not an error). */
  uint8_t body[8] = {10, 0, 0, 0, 'a', 'b', 'c', 'd'};
  struct pyw_rd d = {body, sizeof(body), 0, 0};
  char* s = pyw_rd_str(&d);
  pj_case(j, "rd_str_past_end", d.bad ? 1 : 0, s == NULL ? "NULL" : s, d.bad);
  free(s);
  struct pyw_rd d2 = {body, 4, 0, 0};
  (void)pyw_rd_i64(&d2);
  pj_case(j, "rd_i64_short", d2.bad ? 1 : 0, "", d2.bad);
  uint8_t none[4] = {0xFF, 0xFF, 0xFF, 0xFF};
  struct pyw_rd d3 = {none, 4, 0, 0};
  char* s3 = pyw_rd_str(&d3);
  pj_case(j, "rd_str_null", d3.bad ? 1 : 0, s3 == NULL ? "NULL" : s3, d3.bad);
  free(s3);
}

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
  const struct {
    const char* name;
    uint32_t wire, major, minor;
  } k[4] = {
      {"worker_wire", KOMIRA_UDF_WIRE_VERSION + 1, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR},
      {"worker_major", KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR + 1, KOMIRA_UDF_ABI_MINOR},
      {"worker_minor", KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR + 1},
      {"worker_same", KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR},
  };
  for (int i = 0; i < 4; i++) {
    struct pyw_buf b = {0};
    hello_body(&b, k[i].wire, k[i].major, k[i].minor);
    struct pyw_reply r;
    if (pyw_chan_request(&c, KOMIRA_UDF_OP_HELLO, &b, NULL, 0, &r) != 0) {
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

enum fake_hello { FH_GOOD, FH_MINOR, FH_SHORT, FH_REFUSE };
enum fake_reply { FR_NONE, FR_MAGIC, FR_OTHER_ID, FR_OUTSIDE_HEAP, FR_HUGE, FR_EOF_IN_PAYLOAD, FR_OK };

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
  komira_udf_wire_header h = {magic, op, id, flags, 0, off, len};
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
      pyw_buf_u32(&b, KOMIRA_UDF_WIRE_VERSION);
      pyw_buf_u32(&b, KOMIRA_UDF_ABI_MAJOR);
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

/* One channel to a fake worker: HELLO answered as `fh`; then, when HELLO
 * was taken, one DESCRIBE answered as `fr`. Records what the engine said. */
static void fault_case(struct pj* j, const char* name, enum fake_hello fh, enum fake_reply fr, int use_shm) {
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
  char why[300];
  /* pid 0: nothing to signal or wait for at close. */
  if (pyw_chan_adopt(&c, sv[0], 0, use_shm, why, sizeof(why)) != 0) {
    pj_case(j, name, 1, why, 0);
  } else if (fr == FR_NONE) {
    pj_case(j, name, 0, "HELLO taken", 0);
  } else {
    struct pyw_reply r;
    if (pyw_chan_request(&c, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &r) != 0) {
      pj_case(j, name, 1, c.why, c.dead);
    } else {
      pj_case(j, name, 0, "a reply taken", (int64_t)r.len);
      pyw_reply_free(&r);
    }
  }
  pyw_chan_close(&c);
  pthread_join(t, NULL);
}

static void fault_cases(struct pj* j) {
  fault_case(j, "engine_hello_good", FH_GOOD, FR_NONE, 0);
  fault_case(j, "engine_hello_minor", FH_MINOR, FR_NONE, 0);
  fault_case(j, "engine_hello_short", FH_SHORT, FR_NONE, 0);
  fault_case(j, "engine_hello_refused", FH_REFUSE, FR_NONE, 0);
  fault_case(j, "reply_ok", FH_GOOD, FR_OK, 0);
  fault_case(j, "reply_magic", FH_GOOD, FR_MAGIC, 0);
  fault_case(j, "reply_other_id", FH_GOOD, FR_OTHER_ID, 0);
  fault_case(j, "reply_heap_without_shm", FH_GOOD, FR_OUTSIDE_HEAP, 0);
  fault_case(j, "reply_outside_heap", FH_GOOD, FR_OUTSIDE_HEAP, 1);
  fault_case(j, "reply_over_2gib", FH_GOOD, FR_HUGE, 0);
  fault_case(j, "reply_eof_in_payload", FH_GOOD, FR_EOF_IN_PAYLOAD, 0);
}

/* "codec", "hello" (arg: the runtime directory) or "faults". */
char* kpw_probe_boundary(const char* group, const char* arg) {
  struct pj j = {0};
  pj_open(&j);
  if (strcmp(group, "codec") == 0) codec_cases(&j);
  else if (strcmp(group, "hello") == 0) hello_cases(&j, arg);
  else if (strcmp(group, "faults") == 0) fault_cases(&j);
  else pj_case(&j, "group", -1, "no such group", 0);
  return pj_close(&j);
}
