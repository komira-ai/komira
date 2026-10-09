/*
 * The row runtime's handles, shared by row_runtime.c (life cycle, describe,
 * validate, load, contexts, instances) and row_call.c (call_batch).
 * Test-only spike code for the ROW shape of
 * docs/design/udf_runtime_interface.md (sections 3.1 and 4.3).
 */
#ifndef KOMIRA_UDF_SPIKE_ROWRT_H
#define KOMIRA_UDF_SPIKE_ROWRT_H

#include "rowpy.h" /* first: Python.h sets the feature macros */

#include <pthread.h>
#include <stdint.h>

#include "komira_udf_runtime.h"

struct komira_udf_rt {
  const komira_udf_host* host;
  struct rowpy api;
  PyInterpreterState* main_interp;
  PyThreadState* main_ts; /* the init thread's, saved (detached) between calls */
  pthread_t init_thread;
  PyObject* main_adapter; /* komira_udf_rowrt in the main interpreter (validate) */
  char dir[1024];         /* the directory the runtime library was loaded from */
};

/* One read-set field: its name and Arrow format ('l' int64, 'g' float64). */
struct rowrt_field {
  char* name;
  char fmt;
};

/* A validated, loaded ROW UDF: the read set and the types bound at load. */
struct komira_udf_udf {
  char* entry;
  int n;                      /* fields in the read set */
  struct rowrt_field* fields; /* in the argument struct's order; NULL when n is 0 */
  char result_fmt;
};

struct komira_udf_context {
  struct komira_udf_rt* rt;
  uint32_t slot;
  pthread_t owner;        /* the engine thread that opened it (thread_affine) */
  PyThreadState* ts;      /* this context's sub-interpreter; detached between calls */
  PyObject* adapter;      /* komira_udf_rowrt in this context's interpreter */
  PyObject* name_release; /* "release", for memoryview.release() */
  PyObject* buffer_type;  /* ArrowBuffer, this interpreter's (row_call.c) */
  PyObject* now_fn;       /* a Python callable reading host->now_ns */
};

struct komira_udf_instance {
  struct komira_udf_context* ctx;
  const struct komira_udf_udf* udf;
  PyObject* inst; /* the adapter's RowInstance */
  PyObject* call; /* its bound `call` method */
};

/* Fills `e` (when the host gave one) and returns `code`. */
int32_t rowrt_fail(komira_udf_error* e, int32_t code, const char* msg, const char* trace, int64_t row);

/* The pending Python exception as one line, cleared; "" when none. The
 * result is malloc'd. Called with the interpreter entered. */
char* rowrt_take_exception(const struct rowpy* api);

/* Enters the context's interpreter on this thread, and leaves it. */
void rowrt_enter(struct komira_udf_context* c);
void rowrt_leave(struct komira_udf_context* c);

/* row_call.c's ArrowBuffer type, created in the entered interpreter (a new
 * reference, or NULL with the exception set); and the API its slots call,
 * set once at init. */
PyObject* rowrt_buffer_type_new(const struct rowpy* api);
void rowrt_set_api(const struct rowpy* api);

int32_t rowrt_call_batch(komira_udf_instance* inst, const komira_udf_call* call, struct ArrowDeviceArray* args,
                         struct ArrowDeviceArray* out, komira_udf_error* e);

#endif
