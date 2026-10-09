/*
 * The engine's call loop, for the Node runtime's tests and bench
 * (engine_loop.c). Test-only spike code.
 */
#ifndef KOMIRA_UDF_NODE_ENGINE_LOOP_H
#define KOMIRA_UDF_NODE_ENGINE_LOOP_H

#include <stdint.h>

#define ENGINE_MAX_THREADS 64
#define ENGINE_MSG 512

/* What a run does. */
struct run_opts {
  const char* entry;
  int32_t shape;
  int32_t n_args;     /* arguments of the UDF: 1, or 2 for a UDF of two columns */
  char arg_fmt;       /* 'l' int64, 'g' float64, 'i' int32 */
  char result_fmt;
  int32_t threads;    /* engine threads, each with a context and an instance of its own */
  int32_t warmup_min; /* the fewest warm-up calls */
  int32_t warmup_cap; /* the most; warm-up ends early when three windows agree */
  int32_t batches;    /* measured calls per thread */
  int64_t rows;
  int32_t check;      /* CHECK_* */
  double a, b, base, step; /* the inputs are base + step * row; CHECK_AFFINE wants a * x + b */
  int32_t dup_cols;   /* every argument child is one buffer, shared (a column used twice) */
  int64_t offset;     /* the arrays are sliced: this offset into buffers of offset + rows values */
  int32_t null_every; /* every k-th row is null (0: none) */
  int32_t null_count_unknown; /* the arguments declare null_count -1 (unknown), whatever they hold */
  int32_t form;       /* the spec's CodeForm (2, BUNDLE, by default) */
  int32_t descriptor_version, descriptor_len; /* the spec's descriptor (version 0, empty: the only canonical one) */
  int32_t n_code;     /* code objects the spec lists (none are checked by this runtime) */
  const char* arg_names; /* the argument fields' names, comma separated (x0, x1... by default) */
  int32_t hold;       /* keep every measured output until the contexts are closed and the UDF unloaded, then check and release it */
};

enum { CHECK_NONE = 0, CHECK_AFFINE = 1, CHECK_COUNTER = 2, CHECK_RECORD = 3, CHECK_NULLS = 4 /* null exactly where null_every puts one, the rest a * x + b */ };

/* Run-level fields (kudf_run_get with thread -1). */
enum {
  R_STATUS = 0,
  R_LOAD_NS,
  R_WALL_NS,        /* the measured phase: every thread's measured batches */
  R_CPU_USER_NS,
  R_CPU_SYS_NS,
  R_RSS_BEFORE,     /* bytes, before any context of this run */
  R_RSS_OPEN,       /* bytes, every context open, every instance, one batch each */
  R_CPUS,           /* this process's CPU affinity count */
  R_COLD_NS,        /* engine open (before dlopen) to the end of the first batch; first run only, else -1 */
  R_THREADS,
  R_INVOLUNTARY_SWITCHES,
  R_OPEN_WALL_NS,   /* all threads' contexts and instances open, and their first batch */
  R_MEMORY_REPORT,  /* the sum of the contexts' memory_report, or -1 */
  R_PSS_BEFORE,     /* KiB, the process's proportional set size where R_RSS_BEFORE is taken */
  R_PSS_OPEN,       /* KiB, where R_RSS_OPEN is taken */
  R_FIELDS
};

/* Per-thread fields (kudf_run_get with a thread index). */
enum {
  T_STATUS = 0,
  T_OPEN_CONTEXT_NS,
  T_OPEN_INSTANCE_NS,
  T_FIRST_CALL_NS,
  T_CALLS,
  T_ROWS,
  T_BAD_VALUES,
  T_FIRST_VALUE,
  T_LAST_VALUE,
  T_INCREASING, /* 1 when every output value exceeded the one before it */
  T_EXPORTED,
  T_RELEASED,
  T_WARMUP_CALLS,
  T_MEMORY_REPORT,
  T_SAMPLES, /* how many measured samples */
  T_FIELDS
};

/* kudf_cancel_probe's answer. */
enum { P_STATUS = 0, P_ELAPSED_NS, P_ROW, P_FIELDS };

struct engine;
struct run;

struct engine* kudf_engine_open(const char* path);
int32_t kudf_engine_status(const struct engine* e);
const char* kudf_engine_message(const struct engine* e);
int64_t kudf_engine_open_ns(const struct engine* e);
const char* kudf_engine_runtime_id(const struct engine* e);
int64_t kudf_engine_cap(const struct engine* e, int32_t which);
void kudf_engine_close(struct engine* e);

struct run* kudf_run(struct engine* e, const struct run_opts* o);
int64_t kudf_run_get(const struct run* r, int32_t thread, int32_t field);
const char* kudf_run_message(const struct run* r, int32_t thread);
int64_t kudf_run_sample(const struct run* r, int32_t thread, int64_t i);
void kudf_run_free(struct run* r);

/* One call whose cancel flag a timer sets after `cancel_after_ms`; the
 * status the call ended with, how long it took and the row it reports. */
void kudf_cancel_probe(struct engine* e, const struct run_opts* o, int32_t cancel_after_ms, int64_t* out,
                       char* message);

/* validate on the calling thread: the status and the message. */
int32_t kudf_validate(struct engine* e, const struct run_opts* o, char* message);

/* open_context on the calling thread: for the test that the runtime refuses a
 * call made on the JavaScript thread of its own environment. */
int32_t kudf_open_context_here(struct engine* e, char* message);

#endif
