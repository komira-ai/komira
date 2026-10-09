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
 *   counted        accepted: every library context it opens is wrapped in a
 *                  record carrying a tag and reserves its size from the host,
 *                  released at close_context; open_instance refuses, with
 *                  ERR_INTERNAL, a context that is not one of its records.
 *                  The tag catches a runtime handing a library another
 *                  library's context; the host's reserved bytes catch a
 *                  library context never closed.
 *
 * Each shared library links this whole file and exports one of these inits
 * under komira_udf_native_init_v1 (refrt/variant_*_so.mojo). The inner table
 * and, for counted, the host are kept in this file's statics: one runtime
 * per loaded copy of a library, which is how the tests use them (the native
 * runtime maps a library once per runtime, from its own memory file).
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "komira_udf_runtime.h"

const komira_udf_runtime* komira_udf_echo_native_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                          komira_udf_error* e);

/* ---- one changed field in describe ----------------------------------------- */

static const komira_udf_runtime* inner;
static komira_udf_runtime table;

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

/* The C library's table, copied into `table`; NULL if its init refused. */
static const komira_udf_runtime* copy_inner(const komira_udf_host* host, komira_udf_rt** rt, komira_udf_error* e) {
  inner = komira_udf_echo_native_init_v1(host, rt, e);
  if (inner == NULL) return NULL;
  table = *inner;
  return &table;
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

/* ---- counted: library contexts tagged and reserved from the host ----------- */

#define COUNTED_TAG 0x636f756e74656421ull /* "counted!" */

struct counted_ctx {
  uint64_t tag;
  komira_udf_context* inner;
};

static const komira_udf_host* counted_host;

static void free_message(komira_udf_error* e) {
  free((void*)e->message);
  e->message = NULL;
  e->release = NULL;
}

static int32_t counted_fail(komira_udf_error* e, int32_t code, const char* msg) {
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

static int32_t counted_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out,
                                    komira_udf_error* e) {
  if (counted_host->mem_reserve(counted_host->host_data, (int64_t)sizeof(struct counted_ctx)) != KOMIRA_UDF_OK)
    return counted_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: the host refused the reservation");
  struct counted_ctx* c = calloc(1, sizeof(*c));
  if (c == NULL) {
    counted_host->mem_release(counted_host->host_data, (int64_t)sizeof(struct counted_ctx));
    return counted_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: out of memory");
  }
  int32_t rc = inner->open_context(rt, slot, &c->inner, e);
  if (rc != KOMIRA_UDF_OK) {
    free(c);
    counted_host->mem_release(counted_host->host_data, (int64_t)sizeof(struct counted_ctx));
    return rc;
  }
  c->tag = COUNTED_TAG;
  *out = (komira_udf_context*)c;
  return KOMIRA_UDF_OK;
}

static void counted_close_context(komira_udf_context* ctx) {
  struct counted_ctx* c = (struct counted_ctx*)ctx;
  inner->close_context(c->inner);
  c->tag = 0;
  free(c);
  counted_host->mem_release(counted_host->host_data, (int64_t)sizeof(struct counted_ctx));
}

static int32_t counted_open_instance(komira_udf_context* ctx, komira_udf_udf* u, komira_udf_instance** out,
                                     komira_udf_error* e) {
  /* The tag is read only through the first 8 bytes of the context; every
   * library context the tests open is at least that large. */
  struct counted_ctx* c = (struct counted_ctx*)ctx;
  if (c == NULL || c->tag != COUNTED_TAG)
    return counted_fail(e, KOMIRA_UDF_ERR_INTERNAL, "open_instance: the context is not one this library opened");
  return inner->open_instance(c->inner, u, out, e);
}

static int64_t counted_memory_report(komira_udf_context* ctx) {
  struct counted_ctx* c = (struct counted_ctx*)ctx;
  return inner->memory_report(c->inner);
}

const komira_udf_runtime* komira_udf_variant_counted_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                             komira_udf_error* e) {
  if (copy_inner(host, rt, e) == NULL) return NULL;
  counted_host = host;
  table.open_context = counted_open_context;
  table.close_context = counted_close_context;
  table.open_instance = counted_open_instance;
  if (table.memory_report != NULL) table.memory_report = counted_memory_report;
  return &table;
}
