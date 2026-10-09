/*
 * Single calls into a UDF runtime library on the calling thread, each
 * broken in one known way, for the tests (engine.mojo: RowEngine.probe and
 * RowEngine.misuse). Test-only spike code.
 *
 * rowe_probe: load a UDF whose read set is two float64 fields, open a
 * context and an instance, and make one call_batch with an argument struct
 * of `rows` rows (field 0 holds i + 1 at row i, field 1 holds 10 * (i + 1))
 * that `kind` breaks in field `field`, under the engine's scripted clock
 * (row_engine.h): clock0, the call's deadline (0: none), the clock read that
 * sets the cancel flag (cancel_at, 0: none) and whether the flag is set
 * before the call.
 *
 * rowe_misuse: one table entry called with a struct the ABI refuses, a spec
 * the runtime must refuse, an entry of a shape the runtime does not
 * declare, or a fact read from the process (leaks, signal handlers).
 *
 * rowe_open_in_child: open and initialize a library in a child process.
 *
 * FFI-BOUNDARY. A probe's argument struct is one block freed by its
 * release, which the runtime calls; the probe and misuse result structs are
 * this file's, freed by rowe_probe_free and rowe_misuse_free, and a
 * child's report by rowe_child_free. Handles are the runtime's and are
 * closed here before returning.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <malloc.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "row_engine.h"

enum {
  PK_GOOD = 0,
  PK_SHORT_CHILD,      /* the field has one row fewer than the struct */
  PK_NEG_LENGTH,       /* the struct's length is -1 */
  PK_STRUCT_OFFSET,    /* the struct's offset is 1 */
  PK_NULL_CHILD,       /* the field's child pointer is NULL */
  PK_CHILD_BUFFERS,    /* the field has 3 buffers */
  PK_NEG_CHILD_OFFSET, /* the field's offset is -1 */
  PK_NO_VALUES,        /* the field has no values buffer */
  PK_NOT_CPU,          /* the arrays are on a CUDA device */
  PK_CALL_SIZE,        /* the call struct's size is one byte short */
  PK_OTHER_THREAD,     /* the context and instance are another thread's */
  PK_FOREIGN_CLOSE,    /* another thread closes the instance and context first */
  PK_NULL_CANCEL       /* the call has no cancel flag */
};

struct probe {
  int32_t status;       /* call_batch's */
  int64_t row;          /* the error's row */
  int32_t moved;        /* the args slot was cleared */
  int32_t released;     /* the argument struct's release ran (by the probe's end) */
  int64_t reads;        /* clock reads during the call */
  int64_t logs;         /* host log lines during the probe */
  int32_t open_status;  /* PK_OTHER_THREAD: open_instance from this thread */
  int64_t open_row;     /* its error row */
  int32_t reserved_zero; /* an OK output's device struct has zero reserved words */
  int32_t last_level;   /* the last log line's level */
  int64_t out_len, out_nulls;
  double out[8]; /* the first values; NaN for a null */
  char message[MSG];
  char open_message[MSG];
};

struct probe_block {
  struct ArrowArray child[2];
  struct ArrowArray* kids[2];
  const void* cbufs[2][3];
  const void* pbufs[1];
  double* vals[2];
  int32_t* released;
};

static void release_probe(struct ArrowArray* a) {
  struct probe_block* b = a->private_data;
  *b->released = 1;
  free(b->vals[0]);
  free(b->vals[1]);
  free(b);
  a->release = NULL;
}

static int probe_args(struct ArrowDeviceArray* d, int32_t kind, int32_t field, int64_t rows, int32_t* released) {
  struct probe_block* b = calloc(1, sizeof(*b));
  if (b == NULL) return 0;
  int64_t n = rows < 0 ? 0 : rows;
  b->released = released;
  for (int j = 0; j < 2; j++) {
    b->vals[j] = malloc((size_t)(n + 1) * sizeof(double));
    for (int64_t i = 0; b->vals[j] != NULL && i < n; i++) b->vals[j][i] = (double)((i + 1) * (j == 0 ? 1 : 10));
    struct ArrowArray* c = &b->child[j];
    b->cbufs[j][1] = b->vals[j];
    c->length = n;
    c->n_buffers = 2;
    c->buffers = b->cbufs[j];
    c->release = rowe_release_child;
    c->private_data = b;
    b->kids[j] = c;
  }
  struct ArrowArray* p = &d->array;
  memset(d, 0, sizeof(*d));
  p->length = n;
  p->n_buffers = 1;
  p->buffers = b->pbufs;
  p->n_children = 2;
  p->children = b->kids;
  p->release = release_probe;
  p->private_data = b;
  d->device_id = -1;
  d->device_type = kind == PK_NOT_CPU ? ARROW_DEVICE_CUDA : ARROW_DEVICE_CPU;
  int f = field == 0 ? 0 : 1;
  if (kind == PK_SHORT_CHILD) b->child[f].length = n - 1;
  if (kind == PK_NEG_LENGTH) p->length = -1;
  if (kind == PK_STRUCT_OFFSET) p->offset = 1;
  if (kind == PK_NULL_CHILD) b->kids[f] = NULL;
  if (kind == PK_CHILD_BUFFERS) b->child[f].n_buffers = 3;
  if (kind == PK_NEG_CHILD_OFFSET) b->child[f].offset = -1;
  if (kind == PK_NO_VALUES) b->cbufs[f][1] = NULL;
  return 1;
}

/* The other thread of PK_OTHER_THREAD and PK_FOREIGN_CLOSE. */
struct helper {
  struct engine* e;
  komira_udf_udf* u;
  komira_udf_context* ctx;
  komira_udf_instance* inst;
  int32_t open_rc;
  int close_only; /* PK_FOREIGN_CLOSE: close the probing thread's handles and return */
  pthread_barrier_t opened, done;
};

static void* helper_thread(void* arg) {
  struct helper* h = arg;
  const komira_udf_runtime* t = h->e->t;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  if (h->close_only) {
    t->close_instance(h->inst);
    t->close_context(h->ctx);
    return NULL;
  }
  h->open_rc = t->open_context(h->e->rt, 1, &h->ctx, &err);
  if (h->open_rc == KOMIRA_UDF_OK) h->open_rc = t->open_instance(h->ctx, h->u, &h->inst, &err);
  if (err.release != NULL) err.release(&err);
  pthread_barrier_wait(&h->opened);
  pthread_barrier_wait(&h->done);
  if (h->inst != NULL) t->close_instance(h->inst);
  if (h->ctx != NULL) t->close_context(h->ctx);
  return NULL;
}

static void probe_output(struct probe* p, const struct ArrowDeviceArray* d) {
  const struct ArrowArray* o = &d->array;
  p->reserved_zero = d->reserved[0] == 0 && d->reserved[1] == 0 && d->reserved[2] == 0;
  p->out_len = o->length;
  const double* v = (const double*)o->buffers[1] + o->offset;
  const uint8_t* valid = o->buffers[0];
  for (int64_t i = 0; i < o->length; i++) {
    int64_t at = o->offset + i;
    int is_null = valid != NULL && !((valid[at >> 3] >> (at & 7)) & 1);
    p->out_nulls += is_null;
    if (i < 8) p->out[i] = is_null ? NAN : v[i];
  }
}

struct probe* rowe_probe(struct engine* e, const char* entry, const char* read_csv, int32_t kind, int32_t field,
                         int64_t rows, int64_t clock0, int64_t deadline, int64_t cancel_at, int32_t cancel_now) {
  struct probe* p = calloc(1, sizeof(*p));
  if (p == NULL) return NULL;
  p->row = p->open_row = -1;
  if (e == NULL || e->status != KOMIRA_UDF_OK) {
    p->status = rowe_status(e);
    snprintf(p->message, MSG, "%s", rowe_message(e));
    return p;
  }
  const komira_udf_runtime* t = e->t;
  int64_t logs0 = __atomic_load_n(&e->logs, __ATOMIC_ACQUIRE);
  char* rs = strdup(read_csv);
  char* read[MAX_COLS];
  int k = rs ? rowe_split(rs, read, MAX_COLS) : 0;
  komira_udf_udf* u = NULL;
  p->status = rowe_load_read_set(e, entry, read, k, &u, p->message);
  free(rs);
  if (u == NULL) return p;

  struct helper h;
  memset(&h, 0, sizeof(h));
  h.e = e;
  h.u = u;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  pthread_t tid;
  if (kind == PK_OTHER_THREAD) {
    pthread_barrier_init(&h.opened, NULL, 2);
    pthread_barrier_init(&h.done, NULL, 2);
    pthread_create(&tid, NULL, helper_thread, &h);
    pthread_barrier_wait(&h.opened);
    if (h.inst == NULL) {
      p->status = h.open_rc;
      snprintf(p->message, MSG, "the other thread's open failed");
    } else {
      komira_udf_instance* stray = NULL;
      p->open_status = t->open_instance(h.ctx, u, &stray, &err);
      p->open_row = err.row;
      rowe_take_error(&err, p->open_message);
    }
  } else {
    p->status = t->open_context(e->rt, 0, &h.ctx, &err);
    if (p->status == KOMIRA_UDF_OK) p->status = t->open_instance(h.ctx, u, &h.inst, &err);
    if (p->status != KOMIRA_UDF_OK) {
      rowe_take_error(&err, p->message);
      if (h.ctx != NULL) t->close_context(h.ctx);
      t->unload(u);
      return p;
    }
    if (kind == PK_FOREIGN_CLOSE) {
      h.close_only = 1;
      pthread_create(&tid, NULL, helper_thread, &h);
      pthread_join(tid, NULL);
    }
  }

  struct ArrowDeviceArray args, out;
  memset(&out, 0xFF, sizeof(out)); /* the runtime must set every word it hands back */
  out.array.release = NULL;
  int32_t cancel = cancel_now;
  komira_udf_call call = {sizeof(komira_udf_call), deadline, 1, kind == PK_NULL_CANCEL ? NULL : &cancel};
  if (kind == PK_CALL_SIZE) call.struct_size = sizeof(komira_udf_call) - 1;
  if (h.inst == NULL) {
    /* PK_OTHER_THREAD's open failed: no call */
  } else if (!probe_args(&args, kind, field, rows, &p->released)) {
    p->status = KOMIRA_UDF_ERR_OUT_OF_MEMORY;
  } else {
    e->reads = 0;
    e->clock0 = clock0;
    e->cancel_at = cancel_at;
    e->cancel_flag = &cancel;
    e->script = 1;
    p->status = t->call_batch(h.inst, &call, &args, &out, &err);
    e->script = 0;
    e->cancel_flag = NULL;
    p->reads = e->reads;
    p->moved = args.array.release == NULL;
    if (!p->moved) args.array.release(&args.array);
    if (p->status != KOMIRA_UDF_OK) {
      p->row = err.row;
      rowe_take_error(&err, p->message);
      if (out.array.release != NULL) out.array.release(&out.array);
    } else if (out.array.release != NULL) {
      probe_output(p, &out);
      out.array.release(&out.array);
    }
  }

  if (kind == PK_OTHER_THREAD) {
    pthread_barrier_wait(&h.done);
    pthread_join(tid, NULL);
    pthread_barrier_destroy(&h.opened);
    pthread_barrier_destroy(&h.done);
  } else {
    t->close_instance(h.inst);
    t->close_context(h.ctx);
  }
  t->unload(u);
  p->logs = __atomic_load_n(&e->logs, __ATOMIC_ACQUIRE) - logs0;
  p->last_level = __atomic_load_n(&e->last_level, __ATOMIC_ACQUIRE);
  return p;
}

/* rowe_probe's fields: 0 status, 1 row, 2 moved, 3 released, 4 clock reads,
 * 5 log lines, 6 open_status, 7 output rows, 8 output nulls, 9 open_row,
 * 10 reserved_zero, 11 last log level. */
int64_t rowe_probe_get(const struct probe* p, int32_t field) {
  switch (field) {
    case 0: return p->status;
    case 1: return p->row;
    case 2: return p->moved;
    case 3: return p->released;
    case 4: return p->reads;
    case 5: return p->logs;
    case 6: return p->open_status;
    case 7: return p->out_len;
    case 8: return p->out_nulls;
    case 9: return p->open_row;
    case 10: return p->reserved_zero;
    case 11: return p->last_level;
    default: return 0;
  }
}

double rowe_probe_value(const struct probe* p, int32_t i) { return i >= 0 && i < 8 ? p->out[i] : 0.0; }

/* 0: the call's message; 1: open_instance's (PK_OTHER_THREAD). */
const char* rowe_probe_message(const struct probe* p, int32_t which) {
  return which == 0 ? p->message : p->open_message;
}

void rowe_probe_free(struct probe* p) { free(p); }

/* ---- misuse: entries called the way the ABI or the runtime refuses ----------- */

enum {
  MU_CAPS_SMALL = 0, /* describe with a capabilities struct 8 bytes long */
  MU_SPEC_SMALL,     /* validate with a spec struct 8 bytes long */
  MU_ERR_SMALL,      /* MU_SPEC_SMALL with an error struct 8 bytes long */
  MU_ERR_NULL,       /* MU_SPEC_SMALL with no error struct */
  MU_HOST_NULL,      /* init with no host */
  MU_HOST_SMALL,     /* init with a host struct 8 bytes long */
  MU_HOST_MAJOR,     /* init with a host of ABI major 2 */
  MU_INIT_AGAIN,     /* init a second time with a good host */
  MU_ARGS_NULL,      /* validate: the spec has no argument struct */
  MU_ARGS_NO_FORMAT, /* validate: the argument struct has no format */
  MU_ARGS_LIST,      /* validate: the arguments are a list ("+l"), not a struct */
  MU_ARGS_NEGATIVE,  /* validate: the struct has -1 children */
  MU_FIELD_NULL,     /* validate: field 1's schema pointer is NULL */
  MU_FIELD_NO_FORMAT, /* validate: field 1 has no format */
  MU_FIELD_EMPTY,    /* validate: field 1's format is "" */
  MU_FIELD_TWO_CHARS, /* validate: field 1's format is "gg" */
  MU_FIELD_CHILD,    /* validate: field 1 is "g" with a child */
  MU_FIELD_NO_NAME,  /* validate: field 1 has no name */
  MU_RESULT_NULL,    /* validate: the spec has no result type */
  MU_CODE,           /* validate: the spec carries one code object */
  MU_FRAME_OPEN,     /* frame_open with a stream */
  MU_FRAME_NEXT,     /* frame_next */
  MU_AGG_OPEN,       /* agg_open */
  MU_AGG_UPDATE,     /* agg_update with arguments and group ids */
  MU_AGG_MERGE,      /* agg_merge with states and group ids */
  MU_AGG_STATE,      /* agg_state */
  MU_AGG_FINISH,     /* agg_finish */
  MU_LEAK,           /* heap bytes left by 2000 validates refused at field 2 */
  MU_SIGNALS,        /* 1 when SIGINT, SIGPIPE and SIGXFSZ have the handlers they had before init */
  MU_FRAME_OPEN_RELEASED, /* frame_open with a stream already released */
  MU_AGG_UPDATE_RELEASED  /* agg_update with arrays already released */
};

struct misuse {
  int32_t status;
  int64_t row;
  int64_t value; /* MU_ERR_SMALL: 1 when the error was left unset; MU_LEAK: bytes; MU_SIGINT;
                    frame and agg entries: 1 when every array moved in was released and
                    every slot handed back is clear */
  char message[MSG];
};

static void no_release_schema(struct ArrowSchema* s) { (void)s; }

static void release_stream(struct ArrowDeviceArrayStream* s) { s->release = NULL; }

static void release_plain(struct ArrowArray* a) { a->release = NULL; }

struct misuse* rowe_misuse(struct engine* e, int32_t which) {
  struct misuse* m = calloc(1, sizeof(*m));
  if (m == NULL) return NULL;
  m->row = -1;
  if (e == NULL || e->t == NULL) {
    m->status = rowe_status(e);
    snprintf(m->message, MSG, "%s", rowe_message(e));
    return m;
  }
  const komira_udf_runtime* t = e->t;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};

  struct ArrowSchema child = {"l", "child", NULL, 0, 0, NULL, NULL, no_release_schema, NULL};
  struct ArrowSchema* child_list[1] = {&child};
  struct ArrowSchema f0 = {"g", "price", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release_schema, NULL};
  struct ArrowSchema f1 = {"g", "qty", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release_schema, NULL};
  struct ArrowSchema f2 = {"i", "n", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release_schema, NULL};
  struct ArrowSchema* kids[3] = {&f0, &f1, &f2};
  struct ArrowSchema args = {"+s", "", NULL, 0, 2, kids, NULL, no_release_schema, NULL};
  struct ArrowSchema result = {"g", "", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release_schema, NULL};
  static const char* const roles[1] = {"source"};
  static const uint8_t digests[1][32];
  komira_udf_spec s;
  memset(&s, 0, sizeof(s));
  s.struct_size = sizeof(s);
  s.shape = (int32_t)KOMIRA_UDF_SHAPE_ROW;
  s.form = KOMIRA_UDF_FORM_BUNDLE;
  s.entry = "udf_rows:price_qty";
  s.args = &args;
  s.result = &result;
  s.null_mode = KOMIRA_UDF_NULL_MANUAL;
  s.stability = KOMIRA_UDF_IMMUTABLE;
  s.code_root = "";

  komira_udf_error* ep = &err;
  int validate = 1;
  switch (which) {
    case MU_SPEC_SMALL: s.struct_size = 8; break;
    case MU_ERR_SMALL: s.struct_size = 8; err.struct_size = 8; break;
    case MU_ERR_NULL: s.struct_size = 8; ep = NULL; break;
    case MU_ARGS_NULL: s.args = NULL; break;
    case MU_ARGS_NO_FORMAT: args.format = NULL; break;
    case MU_ARGS_LIST: args.format = "+l"; break;
    case MU_ARGS_NEGATIVE: args.n_children = -1; break;
    case MU_FIELD_NULL: kids[1] = NULL; break;
    case MU_FIELD_NO_FORMAT: f1.format = NULL; break;
    case MU_FIELD_EMPTY: f1.format = ""; break;
    case MU_FIELD_TWO_CHARS: f1.format = "gg"; break;
    case MU_FIELD_CHILD:
      f1.n_children = 1;
      f1.children = child_list;
      break;
    case MU_FIELD_NO_NAME: f1.name = NULL; break;
    case MU_RESULT_NULL: s.result = NULL; break;
    case MU_CODE:
      s.n_code = 1;
      s.code_roles = roles;
      s.code_sha256 = digests;
      break;
    default: validate = 0;
  }
  if (validate) {
    m->status = t->validate(e->rt, &s, ep);
    if (which == MU_ERR_SMALL) m->value = err.message == NULL && err.release == NULL;
    if (ep != NULL && which != MU_ERR_SMALL) {
      m->row = err.row;
      rowe_take_error(&err, m->message);
    }
    return m;
  }

  __typeof__(&komira_udf_runtime_init_v1) init =
      (__typeof__(&komira_udf_runtime_init_v1))dlsym(e->lib, "komira_udf_runtime_init_v1");
  komira_udf_host host = e->host;
  komira_udf_rt* rt2 = NULL;
  const komira_udf_runtime* t2 = NULL;
  struct ArrowDeviceArray a1, a2;
  memset(&a1, 0, sizeof(a1));
  memset(&a2, 0, sizeof(a2));
  a1.array.release = release_plain;
  a2.array.release = release_plain;
  a1.device_type = a2.device_type = ARROW_DEVICE_CPU;
  komira_udf_call call = {sizeof(komira_udf_call), 0, 1, NULL};
  switch (which) {
    case MU_CAPS_SMALL: {
      komira_udf_capabilities c;
      memset(&c, 0, sizeof(c));
      c.struct_size = 8;
      m->status = t->describe(e->rt, &c);
      return m;
    }
    case MU_HOST_NULL:
    case MU_HOST_SMALL:
    case MU_HOST_MAJOR:
    case MU_INIT_AGAIN:
      if (which == MU_HOST_SMALL) host.struct_size = 8;
      if (which == MU_HOST_MAJOR) host.abi_major = 2;
      t2 = init(which == MU_HOST_NULL ? NULL : &host, &rt2, &err);
      m->status = t2 == NULL ? err.code : KOMIRA_UDF_OK;
      m->row = err.row;
      rowe_take_error(&err, m->message);
      return m;
    case MU_FRAME_OPEN: {
      struct ArrowDeviceArrayStream st;
      memset(&st, 0, sizeof(st));
      st.release = release_stream;
      komira_udf_frame* fr = NULL;
      m->status = t->frame_open(NULL, &call, &st, &fr, &err);
      m->value = st.release == NULL && fr == NULL;
      break;
    }
    case MU_FRAME_NEXT:
      m->status = t->frame_next(NULL, &call, &a1, &err);
      m->value = a1.array.release == NULL;
      break;
    case MU_AGG_OPEN: {
      komira_udf_groups* g = NULL;
      m->status = t->agg_open(NULL, &g, &err);
      m->value = g == NULL;
      break;
    }
    case MU_AGG_UPDATE:
      m->status = t->agg_update(NULL, &call, &a1, &a2, 1, &err);
      m->value = a1.array.release == NULL && a2.array.release == NULL;
      break;
    case MU_AGG_MERGE:
      m->status = t->agg_merge(NULL, &call, &a1, &a2, 1, &err);
      m->value = a1.array.release == NULL && a2.array.release == NULL;
      break;
    case MU_AGG_STATE:
      m->status = t->agg_state(NULL, 1, &a1, &err);
      m->value = a1.array.release == NULL;
      break;
    case MU_AGG_FINISH:
      m->status = t->agg_finish(NULL, 1, &a1, &err);
      m->value = a1.array.release == NULL;
      break;
    case MU_LEAK: {
      /* Refused at field 2 (int32) after fields 0 and 1 were bound: no
       * interpreter runs, so what the heap keeps is the runtime's. */
      args.n_children = 3;
      for (int i = 0; i < 200; i++) {
        komira_udf_error e2 = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
        t->validate(e->rt, &s, &e2);
        if (e2.release != NULL) e2.release(&e2);
      }
      struct mallinfo2 before = mallinfo2();
      for (int i = 0; i < 2000; i++) {
        komira_udf_error e2 = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
        m->status = t->validate(e->rt, &s, &e2);
        if (i == 0) {
          m->row = e2.row;
          snprintf(m->message, MSG, "%s", e2.message ? e2.message : "");
        }
        if (e2.release != NULL) e2.release(&e2);
      }
      struct mallinfo2 after = mallinfo2();
      m->value = (int64_t)after.uordblks - (int64_t)before.uordblks;
      return m;
    }
    case MU_SIGNALS: {
      const int sigs[3] = {SIGINT, SIGPIPE, SIGXFSZ};
      m->value = 1;
      for (int i = 0; i < 3; i++) {
        struct sigaction sa;
        if (sigaction(sigs[i], NULL, &sa) != 0 || sa.sa_handler != e->signals_before[i]) m->value = 0;
      }
      return m;
    }
    case MU_FRAME_OPEN_RELEASED: {
      struct ArrowDeviceArrayStream st;
      memset(&st, 0, sizeof(st)); /* release NULL: nothing to release */
      komira_udf_frame* fr = NULL;
      m->status = t->frame_open(NULL, &call, &st, &fr, &err);
      m->value = fr == NULL;
      break;
    }
    case MU_AGG_UPDATE_RELEASED:
      a1.array.release = NULL;
      a2.array.release = NULL;
      m->status = t->agg_update(NULL, &call, &a1, &a2, 1, &err);
      m->value = 1;
      break;
    default:
      snprintf(m->message, MSG, "no misuse %d", which);
      return m;
  }
  m->row = err.row;
  rowe_take_error(&err, m->message);
  return m;
}

/* rowe_misuse's fields: 0 status, 1 row, 2 value. */
int64_t rowe_misuse_get(const struct misuse* m, int32_t field) {
  return field == 0 ? m->status : field == 1 ? m->row : field == 2 ? m->value : 0;
}

const char* rowe_misuse_message(const struct misuse* m) { return m->message; }

void rowe_misuse_free(struct misuse* m) { free(m); }

/* ---- shutdown off the init thread ------------------------------------------ */

static void* shutdown_thread(void* arg) {
  struct engine* e = arg;
  e->t->shutdown(e->rt);
  return NULL;
}

/* Shuts the runtime down from a new thread, which the runtime refuses to
 * finalize on (it logs instead); the engine then holds no runtime. Returns
 * the log lines it wrote. */
int64_t rowe_shutdown_off_thread(struct engine* e) {
  if (e == NULL || e->t == NULL) return -1;
  int64_t logs0 = __atomic_load_n(&e->logs, __ATOMIC_ACQUIRE);
  pthread_t tid;
  pthread_create(&tid, NULL, shutdown_thread, e);
  pthread_join(tid, NULL);
  e->t = NULL;
  return __atomic_load_n(&e->logs, __ATOMIC_ACQUIRE) - logs0;
}

int32_t rowe_last_log_level(const struct engine* e) { return __atomic_load_n(&e->last_level, __ATOMIC_ACQUIRE); }

/* ---- init in a child process ----------------------------------------------- */

struct child_open {
  int32_t status;   /* the engine's status after open (init's code when it failed) */
  int64_t row;      /* init's error row when it failed, else -1 */
  char message[MSG];
};

/* Opens and initializes the runtime library at `path` in a forked child,
 * after a chdir to `dir` when it is not empty: init runs once per process,
 * and the loader would hand two layouts of the same file one copy of the
 * library. The child reports the engine's status, init's error row and the
 * message through a pipe, shuts the runtime down and exits. NULL when the
 * child could not run or reported nothing. */
struct child_open* rowe_open_in_child(const char* dir, const char* path) {
  int fds[2];
  if (pipe(fds) != 0) return NULL;
  fflush(NULL);
  pid_t pid = fork();
  if (pid < 0) {
    close(fds[0]);
    close(fds[1]);
    return NULL;
  }
  if (pid == 0) {
    close(fds[0]);
    struct child_open r;
    memset(&r, 0, sizeof(r));
    r.row = -1;
    if (dir[0] != 0 && chdir(dir) != 0) {
      r.status = -1;
      snprintf(r.message, MSG, "chdir %s failed", dir);
    } else {
      struct engine* e = rowe_open(path);
      r.status = rowe_status(e);
      if (r.status != KOMIRA_UDF_OK) r.row = e->init_row;
      snprintf(r.message, MSG, "%s", rowe_message(e));
      rowe_close(e);
    }
    const char* p = (const char*)&r;
    size_t left = sizeof(r);
    while (left > 0) {
      ssize_t w = write(fds[1], p, left);
      if (w <= 0) break;
      p += w;
      left -= (size_t)w;
    }
    _exit(0);
  }
  close(fds[1]);
  struct child_open* r = calloc(1, sizeof(*r));
  size_t got = 0;
  while (r != NULL && got < sizeof(*r)) {
    ssize_t n = read(fds[0], (char*)r + got, sizeof(*r) - got);
    if (n <= 0) break;
    got += (size_t)n;
  }
  close(fds[0]);
  int st = 0;
  waitpid(pid, &st, 0);
  if (r != NULL && got < sizeof(*r)) {
    free(r);
    return NULL;
  }
  return r;
}

/* rowe_open_in_child's fields: 0 status, 1 row. */
int64_t rowe_child_get(const struct child_open* c, int32_t field) { return field == 0 ? c->status : c->row; }

const char* rowe_child_message(const struct child_open* c) { return c->message; }

void rowe_child_free(struct child_open* c) { free(c); }
