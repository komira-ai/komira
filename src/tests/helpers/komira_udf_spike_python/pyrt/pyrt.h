/*
 * The Python UDF runtime's handles, shared by python_runtime.c (life cycle,
 * describe, validate, load, contexts, instances) and python_call.c
 * (call_batch). Test-only spike code for docs/design/udf_runtime_interface.md.
 */
#ifndef KOMIRA_UDF_SPIKE_PYRT_H
#define KOMIRA_UDF_SPIKE_PYRT_H

#include "pyapi.h" /* first: Python.h sets the feature macros */

#include <pthread.h>
#include <stdint.h>

#include "komira_udf_runtime.h"

#define PYRT_MAX_ARGS 8

/* How contexts map to interpreters. */
enum pyrt_variant {
  /* One sub-interpreter with its own GIL per context (design section 1.2,
   * mode 2): nothing is shared between engine threads. */
  PYRT_SUBINTERP = 1,
  /* Every context is a thread state of the one main interpreter, behind
   * its one GIL: the shared-interpreter baseline the design rejects
   * (section 10, "One in-process GIL interpreter serving every engine
   * thread"), kept to measure against. */
  PYRT_SHARED_GIL = 2,
};

struct komira_udf_rt {
  const komira_udf_host* host;
  enum pyrt_variant variant;
  struct pyapi api;
  PyInterpreterState* main_interp;
  PyThreadState* main_ts; /* the init thread's, saved (detached) between calls */
  pthread_t init_thread;
  PyObject* main_adapter; /* komira_udf_pyrt in the main interpreter (validate) */
  char dir[1024];         /* the directory the runtime library was loaded from */
};

/* A validated, loaded UDF: the spec's facts the runtime binds at load. */
struct komira_udf_udf {
  int32_t shape;
  int32_t null_mode;
  char* entry;
  int n_args;
  char arg_fmt[PYRT_MAX_ARGS];
  char result_fmt;
  int result_nullable;
};

struct komira_udf_context {
  struct komira_udf_rt* rt;
  uint32_t slot;
  pthread_t owner;      /* the engine thread that opened it (thread_affine) */
  PyThreadState* ts;    /* detached between calls */
  PyObject* adapter;    /* komira_udf_pyrt in this context's interpreter */
  PyObject* now_fn;     /* a Python callable reading host->now_ns */
  PyObject* name_release; /* "release", for memoryview.release() */
  PyObject* buffer_type;  /* ArrowBuffer, this interpreter's (python_call.c) */
};

struct komira_udf_instance {
  struct komira_udf_context* ctx;
  const struct komira_udf_udf* udf;
  PyObject* inst; /* the adapter's Instance */
  PyObject* call; /* its bound `call` method */
};

/* Fills `e` (when the host gave one) and returns `code`. */
int32_t pyrt_fail(komira_udf_error* e, int32_t code, const char* msg, const char* trace, int64_t row);

/* The pending Python exception as one line, cleared; "" when none. The
 * result is malloc'd. Called with the interpreter entered. */
char* pyrt_take_exception(const struct pyapi* api);

/* Enters the context's interpreter on this thread, and leaves it. */
void pyrt_enter(struct komira_udf_context* c);
void pyrt_leave(struct komira_udf_context* c);

/* python_call.c's ArrowBuffer type, created in the entered interpreter
 * (a new reference, or NULL with the exception set); and the API its slots
 * call, set once at init. */
PyObject* pyrt_buffer_type_new(const struct pyapi* api);
void pyrt_set_api(const struct pyapi* api);

int32_t pyrt_call_batch(komira_udf_instance* inst, const komira_udf_call* call, struct ArrowDeviceArray* args,
                        struct ArrowDeviceArray* out, komira_udf_error* e);

#endif
