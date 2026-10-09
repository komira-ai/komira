/*
 * Native UDF libraries that each differ from the C native library
 * (echo_runtime.c built with ECHO_NATIVE) in one thing, for the native
 * runtime's refusal and context cases in test_native_loader. Test-only spike
 * code.
 *
 * Each init below calls the C library's own init and returns a copy of its
 * table with one change, so a library the runtime refuses differs from one it
 * loads in that one field, and every earlier check of the runtime passes:
 *   single_thread  describe reports threading SINGLE_THREAD
 *   worker_only    describe reports transports WORKER, without IN_PROCESS
 *   global_lock    describe reports global_lock 1
 *   managed        describe reports udf_class MANAGED (runtime_id unchanged)
 *   no_scalar      describe's shapes lack SCALAR
 *   abi2           the table reports ABI major 2
 *   short_table    the table's struct_size ends before close_instance
 *   one_short      the table's struct_size ends before shutdown, the last
 *                  required entry: one entry short
 *   exact_table    accepted: the table's struct_size ends at shutdown, with
 *                  no room for the optional memory_report
 *   counted        accepted: every library context it opens is wrapped in a
 *                  record carrying a tag and reserves its size plus its slot
 *                  from the host, released at close_context; open_instance
 *                  refuses, with ERR_INTERNAL, a context that is not one of
 *                  its records. The tag catches a runtime handing a library
 *                  another library's context; the host's reserved bytes
 *                  catch a library context never closed, and one opened with
 *                  another slot than the runtime context's. Slot 99's
 *                  open_context and slot 98's open_instance fail, by name.
 *   deferred       accepted: the release of every call_batch output is
 *                  deferred (design section 4.4, "Release runs on any
 *                  thread"): the host's release queues the array, and the
 *                  queue is drained, the outputs really released, at the
 *                  library's next call_batch and at its shutdown. Each queued
 *                  output holds DEFERRED_BYTES reserved from the host until it
 *                  is drained, so the host sees a shutdown that never reached
 *                  the library as bytes still reserved.
 *   init_fails     init returns NULL with an error whose message holds
 *                  INIT_FAIL_BYTES reserved from the host until the error's
 *                  release: a loader that drops the error leaks them.
 *
 * Every init that succeeds reserves INIT_BYTES from the host, released by
 * the library's shutdown: the host sees a library the runtime refused after
 * its init (a table or describe it cannot bind) and never shut down.
 *
 * Each shared library links this whole file and exports one of these inits
 * under komira_udf_native_init_v1 (refrt/variant_*_so.mojo). The inner table,
 * the host and the deferred queue are kept in this file's statics: one
 * runtime per loaded copy of a library, which is how the tests use them (the
 * native runtime maps a library once per runtime, from its own memory file).
 */
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "komira_udf_runtime.h"

const komira_udf_runtime* komira_udf_echo_native_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                          komira_udf_error* e);

#define INIT_BYTES 77
#define INIT_FAIL_BYTES 55

static const komira_udf_runtime* inner;
static komira_udf_runtime table;
static const komira_udf_host* variant_host;

static void free_message(komira_udf_error* e) {
  free((void*)e->message);
  e->message = NULL;
  e->release = NULL;
}

static int32_t variant_fail(komira_udf_error* e, int32_t code, const char* msg) {
  if (e == NULL || e->struct_size < sizeof(komira_udf_error)) return code;
  size_t n = strlen(msg) + 1;
  char* m = malloc(n);
  if (m != NULL) memcpy(m, msg, n);
  e->code = code;
  e->message = m;
  e->user_trace = NULL;
  e->row = -1;
  e->group = -1;
  e->release = m != NULL ? free_message : NULL;
  return code;
}

/* The C library's shutdown, then INIT_BYTES returned to the host. */
static void variant_shutdown(komira_udf_rt* rt) {
  inner->shutdown(rt);
  variant_host->mem_release(variant_host->host_data, INIT_BYTES);
}

/* The C library's table, copied into `table`, with INIT_BYTES reserved
 * until shutdown; NULL if its init or the reservation refused. */
static const komira_udf_runtime* copy_inner(const komira_udf_host* host, komira_udf_rt** rt, komira_udf_error* e) {
  variant_host = host;
  inner = komira_udf_echo_native_init_v1(host, rt, e);
  if (inner == NULL) return NULL;
  if (host->mem_reserve(host->host_data, INIT_BYTES) != KOMIRA_UDF_OK) {
    inner->shutdown(*rt);
    variant_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "init: the host refused the reservation");
    return NULL;
  }
  table = *inner;
  table.shutdown = variant_shutdown;
  return &table;
}

/* ---- one changed field in describe ----------------------------------------- */

enum change { C_SINGLE_THREAD, C_WORKER_ONLY, C_GLOBAL_LOCK, C_MANAGED, C_NO_SCALAR };
static enum change changed;

static int32_t changed_describe(komira_udf_rt* rt, komira_udf_capabilities* c) {
  int32_t rc = inner->describe(rt, c);
  if (rc != KOMIRA_UDF_OK) return rc;
  switch (changed) {
    case C_SINGLE_THREAD:
      c->threading = KOMIRA_UDF_SINGLE_THREAD;
      break;
    case C_WORKER_ONLY:
      c->transports = KOMIRA_UDF_TRANSPORT_WORKER;
      break;
    case C_GLOBAL_LOCK:
      c->global_lock = 1;
      break;
    case C_MANAGED:
      c->udf_class = KOMIRA_UDF_CLASS_MANAGED;
      break;
    case C_NO_SCALAR:
      c->shapes &= ~(uint32_t)KOMIRA_UDF_SHAPE_SCALAR;
      break;
  }
  return KOMIRA_UDF_OK;
}

static const komira_udf_runtime* with_describe(enum change c, const komira_udf_host* host, komira_udf_rt** rt,
                                               komira_udf_error* e) {
  if (copy_inner(host, rt, e) == NULL) return NULL;
  changed = c;
  table.describe = changed_describe;
  return &table;
}

const komira_udf_runtime* komira_udf_variant_single_thread_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                                   komira_udf_error* e) {
  return with_describe(C_SINGLE_THREAD, host, rt, e);
}

const komira_udf_runtime* komira_udf_variant_worker_only_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                                 komira_udf_error* e) {
  return with_describe(C_WORKER_ONLY, host, rt, e);
}

const komira_udf_runtime* komira_udf_variant_global_lock_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                                 komira_udf_error* e) {
  return with_describe(C_GLOBAL_LOCK, host, rt, e);
}

const komira_udf_runtime* komira_udf_variant_managed_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                             komira_udf_error* e) {
  return with_describe(C_MANAGED, host, rt, e);
}

const komira_udf_runtime* komira_udf_variant_no_scalar_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                               komira_udf_error* e) {
  return with_describe(C_NO_SCALAR, host, rt, e);
}

/* ---- one changed field in the table ----------------------------------------- */

const komira_udf_runtime* komira_udf_variant_abi2_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                          komira_udf_error* e) {
  if (copy_inner(host, rt, e) == NULL) return NULL;
  table.abi_major = KOMIRA_UDF_ABI_MAJOR + 1;
  return &table;
}

const komira_udf_runtime* komira_udf_variant_short_table_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                                 komira_udf_error* e) {
  if (copy_inner(host, rt, e) == NULL) return NULL;
  table.struct_size = offsetof(komira_udf_runtime, close_instance);
  return &table;
}

const komira_udf_runtime* komira_udf_variant_one_short_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                               komira_udf_error* e) {
  if (copy_inner(host, rt, e) == NULL) return NULL;
  table.struct_size = offsetof(komira_udf_runtime, shutdown);
  return &table;
}

const komira_udf_runtime* komira_udf_variant_exact_table_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                                 komira_udf_error* e) {
  if (copy_inner(host, rt, e) == NULL) return NULL;
  table.struct_size = offsetof(komira_udf_runtime, memory_report);
  return &table;
}

/* ---- init_fails: NULL from init, with a message the host must release ------- */

static void init_fail_release(komira_udf_error* e) {
  free_message(e);
  variant_host->mem_release(variant_host->host_data, INIT_FAIL_BYTES);
}

const komira_udf_runtime* komira_udf_variant_init_fails_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                                komira_udf_error* e) {
  (void)rt;
  variant_host = host;
  if (host->mem_reserve(host->host_data, INIT_FAIL_BYTES) != KOMIRA_UDF_OK) return NULL;
  variant_fail(e, KOMIRA_UDF_ERR_INTERNAL, "init_fails refuses every host");
  if (e->release == NULL) {
    host->mem_release(host->host_data, INIT_FAIL_BYTES);
    return NULL;
  }
  e->release = init_fail_release;
  return NULL;
}

/* ---- counted: library contexts tagged and reserved from the host ----------- */

#define COUNTED_TAG 0x636f756e74656421ull /* "counted!" */
#define COUNTED_REFUSED_CONTEXT_SLOT 99
#define COUNTED_REFUSED_INSTANCE_SLOT 98

struct counted_ctx {
  uint64_t tag;
  komira_udf_context* inner;
  uint32_t slot;
  int64_t reserved; /* sizeof(struct counted_ctx) + slot */
};

static int32_t counted_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out,
                                    komira_udf_error* e) {
  if (slot == COUNTED_REFUSED_CONTEXT_SLOT)
    return variant_fail(e, KOMIRA_UDF_ERR_INTERNAL, "counted refuses a context in slot 99");
  int64_t bytes = (int64_t)sizeof(struct counted_ctx) + (int64_t)slot;
  if (variant_host->mem_reserve(variant_host->host_data, bytes) != KOMIRA_UDF_OK)
    return variant_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: the host refused the reservation");
  struct counted_ctx* c = calloc(1, sizeof(*c));
  if (c == NULL) {
    variant_host->mem_release(variant_host->host_data, bytes);
    return variant_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: out of memory");
  }
  int32_t rc = inner->open_context(rt, slot, &c->inner, e);
  if (rc != KOMIRA_UDF_OK) {
    free(c);
    variant_host->mem_release(variant_host->host_data, bytes);
    return rc;
  }
  c->tag = COUNTED_TAG;
  c->slot = slot;
  c->reserved = bytes;
  *out = (komira_udf_context*)c;
  return KOMIRA_UDF_OK;
}

static void counted_close_context(komira_udf_context* ctx) {
  struct counted_ctx* c = (struct counted_ctx*)ctx;
  inner->close_context(c->inner);
  int64_t bytes = c->reserved;
  c->tag = 0;
  free(c);
  variant_host->mem_release(variant_host->host_data, bytes);
}

static int32_t counted_open_instance(komira_udf_context* ctx, komira_udf_udf* u, komira_udf_instance** out,
                                     komira_udf_error* e) {
  /* The tag is read only through the first 8 bytes of the context; every
   * library context the tests open is at least that large. */
  struct counted_ctx* c = (struct counted_ctx*)ctx;
  if (c == NULL || c->tag != COUNTED_TAG)
    return variant_fail(e, KOMIRA_UDF_ERR_INTERNAL, "open_instance: the context is not one this library opened");
  if (c->slot == COUNTED_REFUSED_INSTANCE_SLOT)
    return variant_fail(e, KOMIRA_UDF_ERR_INTERNAL, "counted refuses an instance in slot 98");
  return inner->open_instance(c->inner, u, out, e);
}

static int64_t counted_memory_report(komira_udf_context* ctx) {
  struct counted_ctx* c = (struct counted_ctx*)ctx;
  return inner->memory_report(c->inner);
}

const komira_udf_runtime* komira_udf_variant_counted_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                             komira_udf_error* e) {
  if (copy_inner(host, rt, e) == NULL) return NULL;
  table.open_context = counted_open_context;
  table.close_context = counted_close_context;
  table.open_instance = counted_open_instance;
  if (table.memory_report != NULL) table.memory_report = counted_memory_report;
  return &table;
}

/* ---- deferred: output releases queued, drained at the next call and at shutdown */

#define DEFERRED_BYTES 1000

struct deferred_node {
  struct ArrowArray moved; /* the output as the library made it, release intact */
  struct deferred_node* next;
};

static pthread_mutex_t deferred_mu = PTHREAD_MUTEX_INITIALIZER;
static struct deferred_node* deferred_queue;

/* The host's release of an output: queue it, release nothing yet. Any
 * thread, any time until shutdown begins. */
static void deferred_release(struct ArrowArray* a) {
  struct deferred_node* n = a->private_data;
  pthread_mutex_lock(&deferred_mu);
  n->next = deferred_queue;
  deferred_queue = n;
  pthread_mutex_unlock(&deferred_mu);
  a->release = NULL;
}

/* Every queued output released, and its reservation returned. */
static void deferred_drain(void) {
  pthread_mutex_lock(&deferred_mu);
  struct deferred_node* n = deferred_queue;
  deferred_queue = NULL;
  pthread_mutex_unlock(&deferred_mu);
  while (n != NULL) {
    struct deferred_node* next = n->next;
    n->moved.release(&n->moved);
    free(n);
    variant_host->mem_release(variant_host->host_data, DEFERRED_BYTES);
    n = next;
  }
}

static int32_t deferred_call_batch(komira_udf_instance* i, const komira_udf_call* call, struct ArrowDeviceArray* args,
                                   struct ArrowDeviceArray* out, komira_udf_error* e) {
  deferred_drain();
  int32_t rc = inner->call_batch(i, call, args, out, e);
  if (rc != KOMIRA_UDF_OK || out->array.release == NULL) return rc;
  struct deferred_node* n = calloc(1, sizeof(*n));
  if (n == NULL || variant_host->mem_reserve(variant_host->host_data, DEFERRED_BYTES) != KOMIRA_UDF_OK) {
    free(n);
    out->array.release(&out->array);
    return variant_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "call_batch: no room to defer the output's release");
  }
  n->moved = out->array;
  out->array.private_data = n;
  out->array.release = deferred_release;
  return KOMIRA_UDF_OK;
}

static void deferred_shutdown(komira_udf_rt* rt) {
  deferred_drain();
  variant_shutdown(rt);
}

const komira_udf_runtime* komira_udf_variant_deferred_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                              komira_udf_error* e) {
  if (copy_inner(host, rt, e) == NULL) return NULL;
  table.call_batch = deferred_call_batch;
  table.shutdown = deferred_shutdown;
  return &table;
}
