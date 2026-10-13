/*
 * The harness's producer streams: the `in` stream of a frame whose pulls
 * the host answers by calling into the runtime again, on the same context
 * (docs/design/udf_runtime_interface.md section 4.3, "Calls on one context
 * are serialized, with one exception", and "When producing a pull's input
 * fails"). nested.mojo drives them; this file holds no Mojo state.
 *
 * A producer answers each get_next by kind:
 *   KP_BATCHES  hands out the next prepared batch (no nested call);
 *   KP_SCALAR   calls call_batch on the target instance with the next
 *               prepared batch, and hands out a struct whose one child is
 *               the result column;
 *   KP_FRAME    calls frame_next on the target frame and hands out its
 *               output table.
 * Every nested call gets a komira_udf_call of its own: a new call id, the
 * waiting call's deadline_ns (no later than it, section 4.3), and the
 * waiting call's cancel flag itself, so setting one sets both.
 *
 * Failure: the first failure of the pipeline (a nested call's status, or
 * the run's cancel) is kept in the pipe all its producers share; the pull
 * that met it and every later pull on that stream return EIO, with the
 * failure's message from get_last_error. A failed nested frame is never
 * called again. The harness reports the pipe's failure as the run's error,
 * and the waiting frame's own status only when nothing failed.
 *
 * An action can be planted at one pull (`action_at`, counted from 0):
 *   KP_CANCEL_EIO        the run is cancelled while the pull is held: the
 *                        waiting call's flag is set, the failure is the
 *                        cancel, and the pull returns EIO;
 *   KP_CANCEL_KEEP       the flag is set and the batch handed out anyway;
 *   KP_ADVANCE_CLOCK     the host's virtual clock moves past the waiting
 *                        call's deadline, and the batch is handed out.
 *
 * Who owns and frees each pointer: the pipe and producers are malloc'd here
 * and freed by komira_udf_spike_pipe_free / _producer_free, which the
 * harness calls after the frames are closed. The stream struct is the
 * harness's (an arena block), filled here and moved to the runtime; its
 * release marks the producer released and releases every prepared batch
 * never handed out. The prepared batches are the harness's exported arrays
 * (their release counts in its ledger). The struct handed out for a scalar
 * result is malloc'd here; its release releases the result through the
 * runtime's own callback and frees it.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "komira_udf_runtime.h"

#define KP_EIO 5
#define KP_ENOTSUP 95

enum { KP_BATCHES = 0, KP_SCALAR = 1, KP_FRAME = 2 };
enum { KP_NONE = 0, KP_CANCEL_EIO = 1, KP_CANCEL_KEEP = 2, KP_ADVANCE_CLOCK = 3 };

typedef struct {
  int64_t next_call_id;
  int32_t failed; /* 0, or the first failure's status */
  int64_t failed_row;
  char failed_msg[512];
  int32_t lost; /* a nested status that loses its context */
  int64_t nested_calls;
  int64_t eio;
} kp_pipe;

typedef struct {
  kp_pipe* pipe;
  int kind;
  const komira_udf_runtime* t;
  void* target;
  const komira_udf_call* outer;
  int64_t n;
  int64_t next;
  struct ArrowDeviceArray** batches;
  int64_t action_at;
  int action;
  int64_t* clock;
  int failed;
  int ended;
  int64_t pulls;
  int released;
  char last_error[512];
} kp_producer;

static int loses(int32_t st) {
  return st == KOMIRA_UDF_ERR_INSTANCE_LOST || st == KOMIRA_UDF_ERR_WORKER_CRASHED || st == KOMIRA_UDF_ERR_KILLED ||
         st == KOMIRA_UDF_ERR_OUT_OF_MEMORY;
}

void* komira_udf_spike_pipe_new(int64_t first_call_id) {
  kp_pipe* p = calloc(1, sizeof(*p));
  if (p != NULL) p->next_call_id = first_call_id;
  return p;
}

void komira_udf_spike_pipe_free(void* p) { free(p); }

/* A call struct for a nested call: a new id, the waiting call's deadline and
 * cancel flag. `out` is the harness's block of sizeof(komira_udf_call). */
void komira_udf_spike_pipe_call(void* pv, const komira_udf_call* outer, komira_udf_call* out) {
  kp_pipe* p = pv;
  out->struct_size = sizeof(*out);
  out->deadline_ns = outer->deadline_ns;
  out->call_id = p->next_call_id++;
  out->cancel = outer->cancel;
}

/* What the harness reads after the run: 0 failed status, 1 failed row,
 * 2 lost, 3 nested calls, 4 EIOs returned, 5 the next call id. */
int64_t komira_udf_spike_pipe_value(void* pv, int64_t what) {
  kp_pipe* p = pv;
  switch (what) {
    case 0: return p->failed;
    case 1: return p->failed_row;
    case 2: return p->lost;
    case 3: return p->nested_calls;
    case 4: return p->eio;
    case 5: return p->next_call_id;
    default: return -1;
  }
}

const char* komira_udf_spike_pipe_message(void* pv) { return ((kp_pipe*)pv)->failed_msg; }

static void record(kp_pipe* p, int32_t st, const char* msg, int64_t row) {
  if (loses(st)) p->lost = 1;
  if (p->failed != 0) return;
  p->failed = st;
  p->failed_row = row;
  snprintf(p->failed_msg, sizeof(p->failed_msg), "%s", msg != NULL ? msg : "");
}

/* ---- the stream ------------------------------------------------------------ */

static void set_cpu(struct ArrowDeviceArray* d) {
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  d->sync_event = NULL;
  d->reserved[0] = d->reserved[1] = d->reserved[2] = 0;
}

static int eio(kp_producer* pr) {
  pr->failed = 1;
  snprintf(pr->last_error, sizeof(pr->last_error), "%s", pr->pipe->failed_msg);
  pr->pipe->eio++;
  return KP_EIO;
}

/* A struct of one child: the scalar's result column. */
typedef struct {
  struct ArrowArray kid;
  struct ArrowArray* kids[1];
  const void* bufs[1];
} kp_wrap;

static void release_wrap(struct ArrowArray* a) {
  kp_wrap* w = a->private_data;
  if (w->kid.release != NULL) w->kid.release(&w->kid);
  free(w);
  a->release = NULL;
}

static int wrap(struct ArrowDeviceArray* res, struct ArrowDeviceArray* out) {
  kp_wrap* w = calloc(1, sizeof(*w));
  if (w == NULL) return 0;
  w->kid = res->array;
  res->array.release = NULL;
  w->kids[0] = &w->kid;
  w->bufs[0] = NULL;
  struct ArrowArray* a = &out->array;
  a->length = w->kid.length;
  a->null_count = 0;
  a->offset = 0;
  a->n_buffers = 1;
  a->n_children = 1;
  a->buffers = w->bufs;
  a->children = w->kids;
  a->dictionary = NULL;
  a->release = release_wrap;
  a->private_data = w;
  set_cpu(out);
  return 1;
}

static int nested_scalar(kp_producer* pr, struct ArrowDeviceArray* out) {
  komira_udf_call call;
  komira_udf_spike_pipe_call(pr->pipe, pr->outer, &call);
  struct ArrowDeviceArray res;
  memset(&res, 0, sizeof(res));
  komira_udf_error e;
  memset(&e, 0, sizeof(e));
  e.struct_size = sizeof(e);
  e.row = -1;
  e.group = -1;
  struct ArrowDeviceArray* in = pr->batches[pr->next++];
  pr->pipe->nested_calls++;
  int32_t rc = pr->t->call_batch(pr->target, &call, in, &res, &e);
  if (rc != KOMIRA_UDF_OK) {
    record(pr->pipe, rc, e.message != NULL ? e.message : "a nested call failed with no message", e.row);
    if (e.release != NULL) e.release(&e);
    if (res.array.release != NULL) res.array.release(&res.array);
    return eio(pr);
  }
  if (e.release != NULL) e.release(&e);
  if (res.array.release == NULL || !wrap(&res, out)) {
    if (res.array.release != NULL) res.array.release(&res.array);
    record(pr->pipe, KOMIRA_UDF_ERR_INTERNAL, "a nested call returned OK without an output", -1);
    return eio(pr);
  }
  return 0;
}

static int nested_frame(kp_producer* pr, struct ArrowDeviceArray* out) {
  komira_udf_call call;
  komira_udf_spike_pipe_call(pr->pipe, pr->outer, &call);
  struct ArrowDeviceArray res;
  memset(&res, 0, sizeof(res));
  komira_udf_error e;
  memset(&e, 0, sizeof(e));
  e.struct_size = sizeof(e);
  e.row = -1;
  e.group = -1;
  pr->pipe->nested_calls++;
  int32_t rc = pr->t->frame_next(pr->target, &call, &res, &e);
  if (rc != KOMIRA_UDF_OK) {
    record(pr->pipe, rc, e.message != NULL ? e.message : "a nested frame failed with no message", e.row);
    if (e.release != NULL) e.release(&e);
    if (res.array.release != NULL) res.array.release(&res.array);
    return eio(pr);
  }
  if (e.release != NULL) e.release(&e);
  if (res.array.release == NULL) {
    pr->ended = 1;
    memset(out, 0, sizeof(*out));
    set_cpu(out);
    return 0;
  }
  *out = res;
  set_cpu(out);
  return 0;
}

static kp_producer* of(struct ArrowDeviceArrayStream* s) { return (kp_producer*)s->private_data; }

static int kp_get_schema(struct ArrowDeviceArrayStream* s, struct ArrowSchema* out) {
  (void)s;
  (void)out;
  return KP_ENOTSUP; /* schemas are bound at load, never sent per call (section 4.4) */
}

static int kp_get_next(struct ArrowDeviceArrayStream* s, struct ArrowDeviceArray* out) {
  kp_producer* pr = of(s);
  int64_t at = pr->pulls++;
  if (pr->failed) {
    pr->pipe->eio++;
    return KP_EIO;
  }
  memset(out, 0, sizeof(*out));
  set_cpu(out);
  if (at == pr->action_at) {
    volatile int32_t* flag = (volatile int32_t*)pr->outer->cancel;
    switch (pr->action) {
      case KP_CANCEL_EIO:
        if (flag != NULL) __atomic_store_n(flag, 1, __ATOMIC_RELEASE);
        record(pr->pipe, KOMIRA_UDF_ERR_CANCELLED, "the run was cancelled while the frame waited on its input", -1);
        return eio(pr);
      case KP_CANCEL_KEEP:
        if (flag != NULL) __atomic_store_n(flag, 1, __ATOMIC_RELEASE);
        break;
      case KP_ADVANCE_CLOCK:
        if (pr->clock != NULL && pr->outer->deadline_ns != 0) {
          int64_t past = pr->outer->deadline_ns + 1;
          if (__atomic_load_n(&pr->clock[0], __ATOMIC_ACQUIRE) < past)
            __atomic_store_n(&pr->clock[0], past, __ATOMIC_RELEASE);
        }
        break;
      default:
        break;
    }
  }
  if (pr->ended) return 0;
  if (pr->kind == KP_FRAME) return nested_frame(pr, out);
  if (pr->next >= pr->n) {
    pr->ended = 1;
    return 0;
  }
  if (pr->kind == KP_SCALAR) return nested_scalar(pr, out);
  struct ArrowDeviceArray* b = pr->batches[pr->next++];
  out->array = b->array; /* moved: the source's release slot is cleared */
  b->array.release = NULL;
  return 0;
}

static const char* kp_last_error(struct ArrowDeviceArrayStream* s) {
  kp_producer* pr = of(s);
  return pr->failed ? pr->last_error : NULL;
}

static void kp_release(struct ArrowDeviceArrayStream* s) {
  kp_producer* pr = of(s);
  pr->released++;
  for (; pr->next < pr->n; pr->next++) {
    struct ArrowArray* a = &pr->batches[pr->next]->array;
    if (a->release != NULL) a->release(a);
  }
  s->release = NULL;
}

/* A producer of `kind` behind stream `s` (the harness's block, filled
 * here). `batches` holds `n` prepared device arrays (KP_BATCHES and
 * KP_SCALAR); `t` and `target` the nested call's table and instance or
 * frame; `outer` the waiting call; `clock` the host's three clock words. */
void* komira_udf_spike_producer_new(void* pipe, struct ArrowDeviceArrayStream* s, int64_t kind,
                                    const komira_udf_runtime* t, void* target, const komira_udf_call* outer,
                                    int64_t n, struct ArrowDeviceArray** batches, int64_t action_at, int64_t action,
                                    int64_t* clock) {
  kp_producer* pr = calloc(1, sizeof(*pr));
  if (pr == NULL) return NULL;
  pr->pipe = pipe;
  pr->kind = (int)kind;
  pr->t = t;
  pr->target = target;
  pr->outer = outer;
  pr->n = n;
  pr->batches = batches;
  pr->action_at = action_at;
  pr->action = (int)action;
  pr->clock = clock;
  s->device_type = ARROW_DEVICE_CPU;
  s->get_schema = kp_get_schema;
  s->get_next = kp_get_next;
  s->get_last_error = kp_last_error;
  s->release = kp_release;
  s->private_data = pr;
  return pr;
}

/* 0 pulls, 1 releases of the stream. */
int64_t komira_udf_spike_producer_value(void* p, int64_t what) {
  kp_producer* pr = p;
  return what == 0 ? pr->pulls : what == 1 ? pr->released : -1;
}

void komira_udf_spike_producer_free(void* p) { free(p); }
