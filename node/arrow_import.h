// The Arrow C stream import of the Node addon (arrow_import.c): the calls it
// adds to the addon's exports.
#ifndef KOMIRA_NODE_ARROW_IMPORT_H
#define KOMIRA_NODE_ARROW_IMPORT_H

#define NAPI_VERSION 8
#include <node_api.h>

// Adds importArrowStream, arrowSchema, arrowNextBatch and arrowClose to
// `exports`. Returns 0 when a function cannot be made or set.
int arrow_import_export(napi_env env, napi_value exports);

#endif  // KOMIRA_NODE_ARROW_IMPORT_H
