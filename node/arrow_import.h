// The Arrow C stream import of the Node addon (arrow_import.c): the calls it
// adds to the addon's exports, and the drain the addon's `sql` runs on a
// session's thread.
#ifndef KOMIRA_NODE_ARROW_IMPORT_H
#define KOMIRA_NODE_ARROW_IMPORT_H

#define NAPI_VERSION 8
#include <node_api.h>

#include "arrow_c.h"

// Adds importArrowStream, arrowSchema, arrowNextBatch and arrowClose to
// `exports`. Returns 0 when a function cannot be made or set.
int arrow_import_export(napi_env env, napi_value exports);

// A drained stream: its schema and every batch get_next handed out, held
// until JavaScript reads or closes them.
typedef struct ArrowResult ArrowResult;

// Why a drain failed. `code` is KOMIRA_ARROW_STREAM (a callback returned
// `status`; `last` is get_last_error's text, empty when it gives none),
// KOMIRA_ARROW_INVALID (the stream broke the C Stream Interface) or
// KOMIRA_ERR_NOMEM. `message` and `last` are malloc'd, NULL when there was
// no memory for them.
typedef struct {
  const char *code;
  char *message;
  int status;
  char *last;
} ArrowDrainError;

// Calls get_schema once and get_next until the end of `stream`, keeping every
// array, then releases the stream. It needs no napi_env, so any thread may
// call it. Returns the result, or NULL with `*err` filled and everything the
// stream handed out released.
ArrowResult *arrow_drain(struct ArrowArrayStream *stream, ArrowDrainError *err);

// Frees what `err` holds.
void arrow_drain_error_free(ArrowDrainError *err);

// The Error a failed drain rejects with: `<op> failed (status N): <text>` with
// `code`, `status` and `lastError` for a callback's failure. NULL if it
// cannot be made.
napi_value arrow_drain_error_value(napi_env env, const ArrowDrainError *err);

// `r` as the result arrowSchema, arrowNextBatch and arrowClose take, which
// owns it from then on (its finalizer releases what is left). NULL if it
// cannot be made; `r` is released either way.
napi_value arrow_result_value(napi_env env, ArrowResult *r);

// Releases and frees a result that was never handed to JavaScript.
void arrow_result_free(ArrowResult *r);

#endif  // KOMIRA_NODE_ARROW_IMPORT_H
