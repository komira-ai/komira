// A second Node-API addon, built only for the tests, whose `make()` returns an
// external value that is not a komira session. Its data is eight zero bytes: a
// session read from it would look like one that was already freed, so an
// addon that does not tell its own externals apart answers "freed" instead of
// refusing the argument.
#define NAPI_VERSION 8
#include <node_api.h>

static char zeros[8];

static napi_value make(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value out;
  if (napi_create_external(env, zeros, NULL, NULL, &out) != napi_ok) return NULL;
  return out;
}

NAPI_MODULE_INIT() {
  napi_value fn;
  if (napi_create_function(env, "make", NAPI_AUTO_LENGTH, make, NULL, &fn) != napi_ok ||
      napi_set_named_property(env, exports, "make", fn) != napi_ok) {
    napi_throw_error(env, NULL, "foreign_external: cannot export make");
    return NULL;
  }
  return exports;
}
