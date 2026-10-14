/*
 * The harness's producer streams: the `in` stream of a frame whose pulls
 * the host answers by calling into the runtime again, on the same context
 * (docs/design/udf_runtime_interface.md section 4.3, "Calls on one context
 * are serialized, with one exception", and "When producing a pull's input
 * fails"). nested.mojo drives them; this file holds no Mojo state.
 *
 * A producer answers each get_next by kind:
 *   KP_BATCHES  hands out the next prepared batch (no nested call);
 *   KP_SCALAR   asks the harness (the `scalar` callback, _nested.mojo)
 *               for the next batch's scalar result: the harness makes the
 *               call_batch through UdfRuntime.call_batch, so the nested call
 *               gets everything a top-level one does (PROPAGATE compaction,
 *               bisection, import validation, the length post-condition,
 *               sections 3.4, 4.4 to 4.6), and hands out a struct whose one
 *               child is the validated result column, or records the
 *               failure in the pipe (komira_udf_spike_pipe_record) and
 *               answers nonzero;
 *   KP_FRAME    calls frame_next on the target frame and hands out its
 *               output table.
 * Every nested call gets a komira_udf_call of its own
 * (komira_udf_spike_pipe_call): a new call id, the waiting call's
 * deadline_ns (no later than it, section 4.3), and the waiting call's cancel
 * flag itself, so setting one sets both.
 *
 * Failure: the first failure of the pipeline (a nested call's status, or
 * the run's cancel) is kept in the pipe all its producers share; the pull
 * that met it and every later pull on that stream return EIO, with the
 * failure's message from get_last_error. A failed nested frame is never
 * called again. A nested frame that returns OK with an output after the
 * pipeline failed (its user code caught the EIO its own pull raised and
 * yielded anyway) is from a failed run: the output is released unread and
 * the pull returns EIO (section 4.3, "When producing a pull's input
 * fails"). The harness reports the pipe's failure as the run's error, and
 * the waiting frame's own status only when nothing failed.
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
 * result is an exported array of the harness too, written by the `scalar`
 * callback: the runtime's result was imported and released there.
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
  int64_t failed_by; /* who recorded the failure: 0 this file, 1 the harness's scalar callback */
  int64_t nested_calls;
  int64_t eio;
} kp_pipe;

/* The harness's nested scalar call for prepared batch `index`: 0 with the
 * one-child struct of the result in *out, or nonzero with the failure
 * recorded in the pipe. */
typedef int32_t (*kp_scalar_fn)(void* ctx, int64_t index, struct ArrowDeviceArray* out);

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
  kp_scalar_fn scalar; /* KP_SCALAR: the harness's call */
  void* scalar_ctx;
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
 * 2 lost, 3 nested calls, 4 EIOs returned, 5 the next call id, 6 who
 * recorded the failure (failed_by). */
int64_t komira_udf_spike_pipe_value(void* pv, int64_t what) {
  kp_pipe* p = pv;
  switch (what) {
    case 0: return p->failed;
    case 1: return p->failed_row;
    case 2: return p->lost;
    case 3: return p->nested_calls;
    case 4: return p->eio;
    case 5: return p->next_call_id;
    case 6: return p->failed_by;
    default: return -1;
  }
}

const char* komira_udf_spike_pipe_message(void* pv) { return ((kp_pipe*)pv)->failed_msg; }

static void record_by(kp_pipe* p, int32_t st, const char* msg, int64_t row, int64_t by) {
  if (loses(st)) p->lost = 1;
  if (p->failed != 0) return; /* the first failure fixes the run error */
  p->failed = st;
  p->failed_row = row;
  p->failed_by = by;
  snprintf(p->failed_msg, sizeof(p->failed_msg), "%s", msg != NULL ? msg : "");
}

static void record(kp_pipe* p, int32_t st, const char* msg, int64_t row) { record_by(p, st, msg, row, 0); }

/* The harness's scalar callback records its failure here (`st` nonzero). */
void komira_udf_spike_pipe_record(void* pv, int32_t st, const char* msg, int64_t row) {
  record_by(pv, st, msg, row, 1);
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

static int nested_scalar(kp_producer* pr, struct ArrowDeviceArray* out) {
  int64_t index = pr->next++;
  pr->pipe->nested_calls++;
  if (pr->scalar(pr->scalar_ctx, index, out) != 0) {
    if (pr->pipe->failed == 0) record(pr->pipe, KOMIRA_UDF_ERR_INTERNAL, "the harness's scalar call failed unrecorded", -1);
    return eio(pr);
  }
  /* A scalar call takes no stream, so nothing can fail the pipeline while
   * it runs: an OK here is from a live run. */
  set_cpu(out);
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
  if (pr->pipe->failed != 0) {
    /* The frame's own pull got EIO and its user code yielded anyway: an
     * output of a failed run, released unread (section 4.3). */
    if (res.array.release != NULL) res.array.release(&res.array);
    return eio(pr);
  }
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
  for (; pr->kind == KP_BATCHES && pr->next < pr->n; pr->next++) {
    struct ArrowArray* a = &pr->batches[pr->next]->array;
    if (a->release != NULL) a->release(a);
  }
  s->release = NULL;
}

/* A producer of `kind` behind stream `s` (the harness's block, filled
 * here). KP_BATCHES: `batches` holds `n` prepared device arrays. KP_SCALAR:
 * `n` batches, each asked of `scalar(scalar_ctx, i, out)`. KP_FRAME: `t`
 * and `target` the nested frame's table and frame. `outer` the waiting
 * call; `clock` the host's three clock words. */
void* komira_udf_spike_producer_new(void* pipe, struct ArrowDeviceArrayStream* s, int64_t kind,
                                    const komira_udf_runtime* t, void* target, const komira_udf_call* outer,
                                    int64_t n, struct ArrowDeviceArray** batches, int64_t action_at, int64_t action,
                                    int64_t* clock, kp_scalar_fn scalar, void* scalar_ctx) {
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
  pr->scalar = scalar;
  pr->scalar_ctx = scalar_ctx;
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
