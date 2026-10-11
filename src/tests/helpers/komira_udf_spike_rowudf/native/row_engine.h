/*
 * What row_engine.c (the engine loop) shares with row_probe.c (one call on
 * the calling thread): the engine and the helpers both use. Test-only spike
 * code.
 */
#ifndef KOMIRA_UDF_SPIKE_ROW_ENGINE_H
#define KOMIRA_UDF_SPIKE_ROW_ENGINE_H

#include <signal.h>
#include <stdint.h>

#include "komira_udf_runtime.h"

#define MAX_COLS 256
#define MSG 4096

struct engine {
  void* lib;
  const komira_udf_runtime* t;
  komira_udf_rt* rt;
  komira_udf_host host;
  int32_t status;
  char message[MSG];
  int64_t t_open;
  int64_t open_ns;
  int runs;
  komira_udf_capabilities caps;
  char cpu_model[MSG];
  char cpu_max[64];
  int64_t logs;       /* host log lines, counted atomically */
  int32_t last_level; /* the last log line's level */
  int64_t init_row;   /* the error row init returned, when it failed */
  void (*signals_before[3])(int); /* SIGINT's, SIGPIPE's and SIGXFSZ's handlers before init */
  /* A probe's scripted clock (row_probe.c, rowe_probe): while `script` is set, now_ns
   * returns clock0 + the number of reads so far, and the read numbered
   * cancel_at (0: none) sets *cancel_flag. Only the probing thread calls
   * the runtime then. */
  int script;
  int64_t reads, clock0, cancel_at;
  int32_t* cancel_flag;
};

/* The error's message into `into` (MSG bytes), then the error released. */
void rowe_take_error(komira_udf_error* err, char* into);

/* Splits a comma-separated list in place into at most `max` names. */
int rowe_split(char* s, char** out, int max);

/* Loads `entry` with the `k` names of `read` (float64 each) as its argument
 * struct; on failure fills `msg` and returns the status. */
int32_t rowe_load_read_set(struct engine* e, const char* entry, char** read, int k, komira_udf_udf** out, char* msg);

/* A child array's release: the parent's release frees the block. */
void rowe_release_child(struct ArrowArray* a);

int32_t rowe_status(const struct engine* e);
const char* rowe_message(const struct engine* e);
struct engine* rowe_open(const char* path);
void rowe_close(struct engine* e);

#endif
