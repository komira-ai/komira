/*
 * A real worker (pyworker/komira_udf_pyworker.py) driven message by message
 * over its control socket, without the proxy: what it answers to requests
 * the proxy never sends. Test-only spike code
 * (tests/test_worker_protocol.mojo).
 *
 *   control  DESCRIBE's ten numbers; an unknown op refused; CANCEL for a
 *            call already answered ignored; UNLOAD and CLOSE_* of unknown
 *            ids taken; OPEN_INSTANCE, CALL_BATCH and OPEN_CONTEXT refused
 *            where they name nothing or do not belong; FORK refused on a
 *            worker that is not a zygote or without its socket; every
 *            ERROR with row and group -1.
 *   load     LOAD and VALIDATE bodies with one defect each (form, entry
 *            grammar, code objects, shape, argument and result
 *            types, a body cut short, schemas that do not parse, a module
 *            that fails at import, VALUE payloads that are not functions or
 *            do not bind), each refused with its status and reason; 64
 *            arguments and int32 taken; a batch the worker cannot read refused.
 *   frame    HELLO with shared memory but no file, and HELLO without the
 *            shared region, refused; payloads at the edge of
 *            the engine-to-worker heap; a header without the magic ends
 *            the worker (exit 1); end of file before and after HELLO ends
 *            it with exit 0.
 * Each case is one member of the JSON object (probe_json.h): status 0 for
 * OK or the ERROR's code (-1: no reply), the reason, and a value the case
 * names.
 *
 * FFI-BOUNDARY. Each worker is posix_spawned here (pyw_chan_start), its
 * socket closed and its process reaped before the case ends. Payload files
 * copied to TMPDIR are this file's.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include "probe_json.h"
#include "pyw.h"

struct raw {
  int fd;
  pid_t pid;
  uint64_t id;
};

static int raw_start(struct raw* w, const char* dir, const char* role) {
  struct pyw_chan c;
  struct pyw_launch l = {dir, role, "own", 1};
  char why[300];
  if (pyw_chan_start(&c, &l, why, sizeof(why)) != 0) return -1;
  w->fd = c.fd;
  w->pid = c.pid;
  w->id = 0;
  return 0;
}

/* Closes the socket and waits up to 5 s for the worker: its exit status, or
 * -1 (then it is killed). */
static int raw_end(struct raw* w) {
  if (w->fd >= 0) close(w->fd);
  w->fd = -1;
  int st = 0;
  for (int i = 0; i < 5000; i++) {
    if (waitpid(w->pid, &st, WNOHANG) == w->pid) return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
    usleep(1000);
  }
  kill(w->pid, SIGKILL);
  waitpid(w->pid, NULL, 0);
  return -1;
}

static int raw_send(struct raw* w, uint32_t magic, uint32_t op, uint64_t id, uint32_t flags, uint64_t off,
                    uint64_t len, const void* body, size_t blen, int fd) {
  komira_udf_wire_header h = {magic, op, id, flags, 0, off, len};
  struct iovec iov[2] = {{&h, sizeof(h)}, {(void*)body, blen}};
  union {
    char buf[CMSG_SPACE(sizeof(int))];
    struct cmsghdr align;
  } u;
  struct msghdr mh;
  memset(&mh, 0, sizeof(mh));
  mh.msg_iov = iov;
  mh.msg_iovlen = blen ? 2 : 1;
  if (fd >= 0) {
    memset(&u, 0, sizeof(u));
    mh.msg_control = u.buf;
    mh.msg_controllen = sizeof(u.buf);
    struct cmsghdr* cm = CMSG_FIRSTHDR(&mh);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cm), &fd, sizeof(int));
  }
  return sendmsg(w->fd, &mh, MSG_NOSIGNAL) == (ssize_t)(sizeof(h) + blen) ? 0 : -1;
}

static int raw_read(int fd, void* p, size_t n) {
  size_t at = 0;
  while (at < n) {
    struct pollfd pf = {fd, POLLIN, 0};
    if (poll(&pf, 1, 20000) <= 0) return -1;
    ssize_t r = recv(fd, (char*)p + at, n - at, 0);
    if (r <= 0) return -1;
    at += (size_t)r;
  }
  return 0;
}

/* One reply: 0 with its header and payload (malloc'd), or -1. */
static int raw_recv(struct raw* w, komira_udf_wire_header* h, uint8_t** payload) {
  *payload = NULL;
  if (raw_read(w->fd, h, sizeof(*h)) != 0) return -1;
  if (!(h->flags & KOMIRA_UDF_WIRE_INLINE) || h->payload_len == 0) return 0;
  *payload = malloc(h->payload_len);
  return *payload != NULL && raw_read(w->fd, *payload, h->payload_len) == 0 ? 0 : -1;
}

/* A request and its reply, recorded as a case: status 0 for OK (message
 * "OK", value its first i64 or 0), or the ERROR's code, message, and value 0
 * when its row and group are -1. */
static int64_t ask(struct pj* j, const char* name, struct raw* w, uint32_t op, const void* body, size_t blen) {
  uint64_t id = ++w->id;
  if (raw_send(w, KOMIRA_UDF_WIRE_MAGIC, op, id, blen ? KOMIRA_UDF_WIRE_INLINE : 0, 0, blen, body, blen, -1) != 0) {
    pj_case(j, name, -1, "send failed", 0);
    return -1;
  }
  komira_udf_wire_header h;
  uint8_t* p;
  if (raw_recv(w, &h, &p) != 0) {
    pj_case(j, name, -1, "no reply", 0);
    return -1;
  }
  struct pyw_rd d = {p, h.payload_len, 0, 0};
  int64_t first = -1;
  if (h.request_id != id) {
    pj_case(j, name, -1, "a reply to another request", (int64_t)h.request_id);
  } else if (h.op == KOMIRA_UDF_OP_OK) {
    first = h.payload_len >= 8 ? pyw_rd_i64(&d) : 0;
    pj_case(j, name, 0, "OK", first);
  } else {
    int32_t code = pyw_rd_i32(&d);
    int64_t row = pyw_rd_i64(&d), group = pyw_rd_i64(&d);
    char* m = pyw_rd_str(&d);
    pj_case(j, name, d.bad ? -1 : code, m ? m : "(malformed)", (row != -1) + (group != -1) * 10);
    free(m);
  }
  free(p);
  return first;
}

static void hello_body(struct pyw_buf* b, uint32_t flags) {
  pyw_buf_u32(b, KOMIRA_UDF_WIRE_VERSION);
  pyw_buf_u32(b, KOMIRA_UDF_ABI_MAJOR);
  pyw_buf_u32(b, KOMIRA_UDF_ABI_MINOR);
  pyw_buf_u32(b, flags);
  pyw_buf_u64(b, PYW_SHM_BYTES);
  pyw_buf_u64(b, PYW_HEAP_BYTES);
}

/* HELLO with a shared region (a memfd of the size it names), recorded as a
 * case like `ask`. */
static int say_hello(struct pj* j, const char* name, struct raw* w) {
  int mfd = memfd_create("probe-region", MFD_CLOEXEC);
  if (mfd < 0 || ftruncate(mfd, PYW_SHM_BYTES) != 0) {
    pj_case(j, name, -1, "memfd failed", 0);
    if (mfd >= 0) close(mfd);
    return -1;
  }
  struct pyw_buf b = {0};
  hello_body(&b, 1);
  uint64_t id = ++w->id;
  int rc = raw_send(w, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_HELLO, id, KOMIRA_UDF_WIRE_INLINE, 0, b.len, b.p, b.len, mfd);
  pyw_buf_free(&b);
  close(mfd);
  komira_udf_wire_header h;
  uint8_t* p = NULL;
  if (rc == 0) rc = raw_recv(w, &h, &p);
  int ok = rc == 0 && h.request_id == id && h.op == KOMIRA_UDF_OP_OK;
  pj_case(j, name, ok ? 0 : -1, ok ? "OK" : "HELLO not taken", 0);
  free(p);
  return ok ? 0 : -1;
}

/* ---- control ---------------------------------------------------------------- */

static void control_cases(struct pj* j, const char* dir) {
  struct raw w;
  if (raw_start(&w, dir, "context") != 0) {
    pj_case(j, "start", -1, "the worker did not start", 0);
    return;
  }
  say_hello(j, "hello", &w);
  /* DESCRIBE's numbers, as text */
  uint64_t id = ++w.id;
  raw_send(&w, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_DESCRIBE, id, 0, 0, 0, NULL, 0, -1);
  komira_udf_wire_header h;
  uint8_t* p;
  if (raw_recv(&w, &h, &p) == 0 && h.op == KOMIRA_UDF_OP_OK) {
    struct pyw_rd d = {p, h.payload_len, 0, 0};
    uint32_t v[5];
    for (int i = 0; i < 5; i++) v[i] = pyw_rd_u32(&d);
    char* rid = pyw_rd_str(&d);
    char* abi = pyw_rd_str(&d);
    char m[200];
    int at = snprintf(m, sizeof(m), "%s %s", rid ? rid : "?", abi ? abi : "?");
    for (int i = 0; i < 5; i++) at += snprintf(m + at, sizeof(m) - (size_t)at, " %u", v[i]);
    pj_case(j, "describe", d.bad ? -1 : 0, m, (int64_t)(h.payload_len - d.at));
    free(rid), free(abi);
  }
  free(p);
  ask(j, "unknown_op", &w, 99, NULL, 0);
  /* CANCEL for a call already answered: no reply; the next reply is for
   * the request after it */
  raw_send(&w, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_CANCEL, ++w.id, 0, 0, 0, NULL, 0, -1);
  uint64_t after = w.id + 1;
  ask(j, "after_cancel", &w, KOMIRA_UDF_OP_DESCRIBE, NULL, 0);
  (void)after;
  int64_t nothing = 12345;
  ask(j, "unload_unknown", &w, KOMIRA_UDF_OP_UNLOAD, &nothing, 8);
  ask(j, "close_context_unknown", &w, KOMIRA_UDF_OP_CLOSE_CONTEXT, &nothing, 8);
  ask(j, "close_instance_unknown", &w, KOMIRA_UDF_OP_CLOSE_INSTANCE, &nothing, 8);
  int64_t pair[2] = {77, 1};
  ask(j, "open_instance_no_context", &w, KOMIRA_UDF_OP_OPEN_INSTANCE, pair, 16);
  uint32_t slot = 0;
  int64_t ctx = ask(j, "open_context", &w, KOMIRA_UDF_OP_OPEN_CONTEXT, &slot, 4);
  int64_t pair2[2] = {ctx, 99};
  ask(j, "open_instance_no_udf", &w, KOMIRA_UDF_OP_OPEN_INSTANCE, pair2, 16);
  uint8_t head[64] = {0};
  int64_t inst = 4242;
  memcpy(head, &inst, 8);
  ask(j, "call_no_instance", &w, KOMIRA_UDF_OP_CALL_BATCH, head, sizeof(head));
  ask(j, "fork_not_zygote", &w, PYW_OP_FORK, NULL, 0);
  pj_case(j, "context_exit", raw_end(&w), "", 0);

  if (raw_start(&w, dir, "zygote") != 0) return;
  say_hello(j, "zygote_hello", &w);
  ask(j, "open_context_on_zygote", &w, KOMIRA_UDF_OP_OPEN_CONTEXT, &slot, 4);
  ask(j, "fork_without_socket", &w, PYW_OP_FORK, NULL, 0);
  pj_case(j, "zygote_exit", raw_end(&w), "", 0);

  /* SHUTDOWN with the socket still open: the worker ends by itself, with
   * status 0, within a second (not when the engine closes the socket or
   * kills it). */
  if (raw_start(&w, dir, "context") != 0) return;
  say_hello(j, "shutdown_hello", &w);
  raw_send(&w, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_SHUTDOWN, ++w.id, 0, 0, 0, NULL, 0, -1);
  int st = 0, ended = -1;
  for (int i = 0; i < 1000 && ended < 0; i++) {
    if (waitpid(w.pid, &st, WNOHANG) == w.pid) ended = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
    else usleep(1000);
  }
  if (ended < 0) {
    pj_case(j, "shutdown_exit", -1, "still running 1 s after SHUTDOWN", 0);
    raw_end(&w);
  } else {
    close(w.fd);
    pj_case(j, "shutdown_exit", ended, "", 0);
  }
}

/* ---- load ------------------------------------------------------------------- */

struct spec {
  int32_t shape, form;
  uint32_t dver;
  const char* entry;
  const char* desc;
  int ncode;
  const char* role[2];
  uint8_t sha[2][32];
  const char* code_root;
  const char* args;   /* one format char per argument */
  const char* result; /* one format char per result field */
  size_t cut;         /* > 0: the body cut to this many bytes */
  int garble_schemas; /* the schemas replaced by bytes that do not parse */
};

static void spec_body(struct pyw_buf* b, const struct spec* s) {
  pyw_buf_i32(b, s->shape);
  pyw_buf_i32(b, s->form);
  pyw_buf_i32(b, KOMIRA_UDF_NULL_MANUAL);
  pyw_buf_i32(b, KOMIRA_UDF_IMMUTABLE);
  pyw_buf_u32(b, s->dver);
  pyw_buf_str(b, s->entry);
  size_t dl = s->desc ? strlen(s->desc) : 0;
  pyw_buf_u32(b, (uint32_t)dl);
  pyw_buf_put(b, s->desc, dl);
  pyw_buf_str(b, s->code_root);
  pyw_buf_u32(b, (uint32_t)s->ncode);
  for (int i = 0; i < s->ncode; i++) {
    pyw_buf_str(b, s->role[i]);
    pyw_buf_put(b, s->sha[i], 32);
  }
  pyw_buf_align(b, 8);
  if (s->garble_schemas) {
    pyw_buf_put(b, "not an IPC schema message", 25);
    return;
  }
  struct pyw_field f[65];
  char fmts[65][2];
  int n = (int)strlen(s->args);
  for (int i = 0; i < n; i++) {
    fmts[i][0] = s->args[i], fmts[i][1] = 0;
    f[i] = (struct pyw_field){"a", fmts[i], 1};
  }
  pyw_ipc_schema(b, f, n);
  n = (int)strlen(s->result);
  for (int i = 0; i < n; i++) {
    fmts[i][0] = s->result[i], fmts[i][1] = 0;
    f[i] = (struct pyw_field){"r", fmts[i], 1};
  }
  pyw_ipc_schema(b, f, n);
}

static int64_t load(struct pj* j, const char* name, struct raw* w, uint32_t op, const struct spec* s) {
  struct pyw_buf b = {0};
  spec_body(&b, s);
  size_t len = s->cut ? s->cut : b.len;
  int64_t r = ask(j, name, w, op, b.p, len);
  pyw_buf_free(&b);
  return r;
}

#define ARGS64 "llllllllllllllllllllllllllllllll"\
  "llllllllllllllllllllllllllllllll"
#define ARGS65 "l" ARGS64

static const struct spec PAIR = {KOMIRA_UDF_SHAPE_SCALAR, KOMIRA_UDF_FORM_BUNDLE, 0, "udf_worker_fixtures:pair", NULL,
                                 0, {NULL, NULL}, {{0}}, NULL, "ll", "l", 0, 0};

static int unhex32(const char* h, uint8_t* out) {
  for (int i = 0; i < 32; i++) {
    unsigned v;
    if (sscanf(h + 2 * i, "%2x", &v) != 1) return -1;
    out[i] = (uint8_t)v;
  }
  return 0;
}

/* value_payloads/<name> copied to $TMPDIR/<its sha256>; the sha in `sha`. */
static int stage_payload(const char* name, uint8_t* sha, char* root, size_t rn) {
  const char* tmp = getenv("TMPDIR");
  snprintf(root, rn, "%s", tmp ? tmp : "/tmp");
  FILE* f = fopen("value_payloads/info.txt", "r");
  if (f == NULL) return -1;
  char n[64], hex[80];
  int found = 0;
  while (!found && fscanf(f, "%63s %79s", n, hex) == 2) found = strcmp(n, name) == 0;
  fclose(f);
  if (!found || unhex32(hex, sha) != 0) return -1;
  char src[200], dst[600];
  snprintf(src, sizeof(src), "value_payloads/%s", name);
  snprintf(dst, sizeof(dst), "%s/%s", root, hex);
  FILE* in = fopen(src, "rb");
  FILE* out = fopen(dst, "wb");
  if (in == NULL || out == NULL) {
    if (in) fclose(in);
    if (out) fclose(out);
    return -1;
  }
  char buf[4096];
  size_t r;
  while ((r = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, r, out);
  fclose(in);
  fclose(out);
  return 0;
}

static struct spec value_spec(const char* payload, char* root, size_t rn) {
  struct spec s = PAIR;
  s.form = KOMIRA_UDF_FORM_VALUE;
  s.entry = NULL;
  s.args = "l";
  s.ncode = 1;
  s.role[0] = "payload";
  if (stage_payload(payload, s.sha[0], root, rn) != 0) s.role[0] = "staging failed";
  s.code_root = root;
  return s;
}

static void load_cases(struct pj* j, const char* dir) {
  struct raw w;
  if (raw_start(&w, dir, "context") != 0) return;
  say_hello(j, "load_hello", &w);
  const uint32_t V = KOMIRA_UDF_OP_VALIDATE;
  struct spec s;
#define CASE(nm, edit)   \
  s = PAIR;              \
  edit;                  \
  load(j, nm, &w, V, &s)
  CASE("form_9", s.form = 9);
  CASE("entry_no_colon", s.entry = "pair");
  CASE("entry_no_module", s.entry = ":pair");
  CASE("entry_no_function", s.entry = "udf_worker_fixtures:");
  CASE("entry_two_colons", s.entry = "udf_worker_fixtures:pair:x");
  CASE("value_no_code", (s.form = KOMIRA_UDF_FORM_VALUE, s.entry = NULL));
  CASE("value_role_other", (s.form = KOMIRA_UDF_FORM_VALUE, s.entry = NULL, s.ncode = 1, s.role[0] = "other"));
  CASE("value_two_codes",
       (s.form = KOMIRA_UDF_FORM_VALUE, s.entry = NULL, s.ncode = 2, s.role[0] = "payload", s.role[1] = "payload"));
  CASE("bundle_with_code", (s.ncode = 1, s.role[0] = "payload"));
  CASE("shape_2", s.shape = 2);
  /* 64 arguments are the most a UDF takes (the adapter's PYRT_MAX_ARGS) */
  CASE("args_65", (s.entry = "udf_fixtures:sum64", s.args = ARGS65));
  CASE("args_64", (s.entry = "udf_fixtures:sum64", s.args = ARGS64));
  CASE("arg_int32", s.args = "li");
  CASE("result_int32", s.result = "i");
  CASE("result_two", s.result = "ll");
  CASE("result_none", s.result = "");
  CASE("body_cut", s.cut = 30);
  CASE("body_3_bytes", s.cut = 3);
  CASE("schemas_garbled", s.garble_schemas = 1);
  CASE("module_missing", s.entry = "udf_no_such_module:f");
  const uint32_t L = KOMIRA_UDF_OP_LOAD;
  s = PAIR;
  s.entry = "udf_worker_badimport:f";
  s.args = "l";
  load(j, "import_fails", &w, L, &s);
  s = PAIR;
  s.entry = "udf_no_such_module:f";
  load(j, "module_missing_load", &w, L, &s);
  char root[400];
  const char* bad[4] = {"not_function", "bad_pickle", "unresolved_hints", "bad_signature"};
  for (int i = 0; i < 4; i++) {
    s = value_spec(bad[i], root, sizeof(root));
    char nm[48];
    snprintf(nm, sizeof(nm), "value_%s", bad[i]);
    load(j, nm, &w, L, &s);
  }
  s = value_spec("good", root, sizeof(root));
  load(j, "value_good", &w, L, &s);
  s = value_spec("good", root, sizeof(root));
  memset(s.sha[0], 0, 32);
  load(j, "value_missing_file", &w, L, &s);
  /* a batch the worker cannot read, then one column for two arguments */
  int64_t u = load(j, "load_pair", &w, L, &PAIR);
  uint32_t slot = 0;
  int64_t ctx = ask(j, "load_open_context", &w, KOMIRA_UDF_OP_OPEN_CONTEXT, &slot, 4);
  int64_t ci[2] = {ctx, u};
  int64_t inst = ask(j, "load_open_instance", &w, KOMIRA_UDF_OP_OPEN_INSTANCE, ci, 16);
  uint8_t msg[64 + 16];
  memset(msg, 0, sizeof(msg));
  memcpy(msg, &inst, 8);
  ask(j, "call_unreadable_batch", &w, KOMIRA_UDF_OP_CALL_BATCH, msg, sizeof(msg));
  int64_t vals[3] = {1, 2, 3};
  const void* bufs[2] = {NULL, vals};
  struct ArrowArray a = {3, 0, 0, 2, 0, bufs, NULL, NULL, NULL, NULL};
  const struct ArrowArray* cols[1] = {&a};
  int wd[1] = {8};
  size_t sz = pyw_ipc_batch_size(3, cols, wd, 1);
  uint8_t* one = aligned_alloc(PYW_ALIGN, 64 + ((sz + PYW_ALIGN - 1) & ~(size_t)(PYW_ALIGN - 1)));
  memset(one, 0, 64);
  memcpy(one, &inst, 8);
  pyw_ipc_batch_write(one + 64, 3, cols, wd, 1);
  ask(j, "call_one_column_for_two", &w, KOMIRA_UDF_OP_CALL_BATCH, one, 64 + sz);
  free(one);
  pj_case(j, "load_exit", raw_end(&w), "", 0);
#undef CASE
}

/* ---- the frame -------------------------------------------------------------- */

static void frame_cases(struct pj* j, const char* dir) {
  struct raw w;
  /* shared memory announced without its file */
  if (raw_start(&w, dir, "context") != 0) return;
  struct pyw_buf b = {0};
  hello_body(&b, 1);
  ask(j, "hello_shm_no_file", &w, KOMIRA_UDF_OP_HELLO, b.p, b.len);
  pyw_buf_free(&b);
  /* a HELLO without the shared region: refused (every worker has one) */
  b = (struct pyw_buf){0};
  hello_body(&b, 0);
  ask(j, "hello_no_region", &w, KOMIRA_UDF_OP_HELLO, b.p, b.len);
  pyw_buf_free(&b);
  pj_case(j, "no_region_exit", raw_end(&w), "", 0);
  uint64_t id;
  komira_udf_wire_header h;
  uint8_t* p;
  int rc;
  struct pyw_rd d;
  int32_t code;
  char* m;

  /* with shared memory: payloads at the heap's end */
  if (raw_start(&w, dir, "context") != 0) return;
  int mfd = memfd_create("probe-region", MFD_CLOEXEC);
  if (mfd < 0 || ftruncate(mfd, PYW_SHM_BYTES) != 0) return;
  b = (struct pyw_buf){0};
  hello_body(&b, 1);
  id = ++w.id;
  raw_send(&w, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_HELLO, id, KOMIRA_UDF_WIRE_INLINE, 0, b.len, b.p, b.len, mfd);
  pyw_buf_free(&b);
  rc = raw_recv(&w, &h, &p);
  pj_case(j, "shm_hello", rc ? -1 : h.op == KOMIRA_UDF_OP_OK ? 0 : 1, "", 0);
  free(p);
  close(mfd);
  const struct {
    const char* name;
    uint64_t off, len;
  } k[3] = {
      {"heap_end_exact", PYW_HEAP_BYTES - 64, 64},
      {"heap_one_past", PYW_HEAP_BYTES - 63, 64},
      {"heap_far_past", PYW_HEAP_BYTES, 64},
  };
  for (int i = 0; i < 3; i++) {
    id = ++w.id;
    raw_send(&w, KOMIRA_UDF_WIRE_MAGIC, KOMIRA_UDF_OP_CALL_BATCH, id, 0, k[i].off, k[i].len, NULL, 0, -1);
    rc = raw_recv(&w, &h, &p);
    d = (struct pyw_rd){p, h.payload_len, 0, 0};
    code = pyw_rd_i32(&d);
    (void)pyw_rd_i64(&d), (void)pyw_rd_i64(&d);
    m = pyw_rd_str(&d);
    /* inside the heap the head names no instance: the batch was read */
    pj_case(j, k[i].name, rc ? -1 : code, m ? m : "", 0);
    free(m), free(p);
  }
  pj_case(j, "shm_exit", raw_end(&w), "", 0);

  /* a header without the magic */
  if (raw_start(&w, dir, "context") != 0) return;
  say_hello(j, "magic_hello", &w);
  raw_send(&w, 0x12345678u, KOMIRA_UDF_OP_DESCRIBE, ++w.id, 0, 0, 0, NULL, 0, -1);
  rc = raw_recv(&w, &h, &p);
  free(p);
  pj_case(j, "bad_magic", rc == 0 ? (int64_t)h.op : -1, "", raw_end(&w));
  /* end of file before HELLO and after it */
  if (raw_start(&w, dir, "context") != 0) return;
  pj_case(j, "eof_before_hello", raw_end(&w), "", 0);
  if (raw_start(&w, dir, "context") != 0) return;
  say_hello(j, "eof_hello", &w);
  pj_case(j, "eof_after_hello", raw_end(&w), "", 0);
  /* a worker given no role it knows ends before HELLO: pyw_chan_spawn
   * reports how */
  struct pyw_chan c;
  struct pyw_launch l = {dir, "nonsense", "own", 1};
  char why[300] = "";
  rc = pyw_chan_spawn(&c, &l, why, sizeof(why));
  pj_case(j, "spawn_bad_role", rc, why, c.dead);
  pyw_chan_close(&c);
}

/* "control", "load" or "frame" against workers started from `dir`. */
char* kpw_probe_worker(const char* group, const char* dir) {
  struct pj j = {0};
  pj_open(&j);
  char real[4096];
  if (realpath(dir, real) == NULL) {
    pj_case(&j, "dir", -1, "the runtime directory does not resolve", 0);
  } else if (strcmp(group, "control") == 0) {
    control_cases(&j, real);
  } else if (strcmp(group, "load") == 0) {
    load_cases(&j, real);
  } else if (strcmp(group, "frame") == 0) {
    frame_cases(&j, real);
  } else {
    pj_case(&j, "group", -1, "no such group", 0);
  }
  return pj_close(&j);
}
