// The addon of komira_test_node `answer` with the wrong number: it returns 41.
#define NAPI_VERSION 8
#include <node_api.h>

static napi_value answer(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value out;
  if (napi_create_int32(env, 41, &out) != napi_ok) return NULL;
  return out;
}

NAPI_MODULE_INIT() {
  napi_value fn;
  if (napi_create_function(env, "answer", NAPI_AUTO_LENGTH, answer, NULL, &fn) != napi_ok ||
      napi_set_named_property(env, exports, "answer", fn) != napi_ok) {
    return NULL;
  }
  return exports;
}
