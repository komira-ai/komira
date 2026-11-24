// A Node-API addon, built only for the tests, that reaches the gates and the
// journal of the stand-in library fake_latch.c once komira_addon has loaded
// it:
//
//   attach(path)     open the loaded stand-in again (RTLD_NOLOAD: the same copy
//                    komira_addon uses, never a second one)
//   open(k)          open gate k: the call held there returns
//   waitEntered(k)   block until a call has entered gate k
//   journal()        the stand-in's journal: its text, one line per entry
#define NAPI_VERSION 8
#include <node_api.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>

static void (*open_gate)(int);
static void (*wait_entered)(int);
static size_t (*read_journal)(char *, size_t);

static napi_value fail(napi_env env, const char *message) {
  napi_throw_error(env, "FAKE_CONTROL", message);
  return NULL;
}

static napi_value undefined(napi_env env) {
  napi_value u;
  if (napi_get_undefined(env, &u) != napi_ok) return NULL;
  return u;
}

static napi_value attach(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  char path[4096];
  size_t len = 0;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1 ||
      napi_get_value_string_utf8(env, argv[0], path, sizeof path, &len) != napi_ok) {
    return fail(env, "attach(path) needs the stand-in's path");
  }
  void *lib = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
  if (lib == NULL) return fail(env, "the stand-in is not loaded");
  open_gate = (void (*)(int))dlsym(lib, "fake_open");
  wait_entered = (void (*)(int))dlsym(lib, "fake_wait_entered");
  read_journal = (size_t(*)(char *, size_t))dlsym(lib, "fake_journal");
  if (open_gate == NULL || wait_entered == NULL || read_journal == NULL) {
    return fail(env, "the library is not the latch stand-in");
  }
  return undefined(env);
}

static int gate_arg(napi_env env, napi_callback_info info, int32_t *k) {
  size_t argc = 1;
  napi_value argv[1];
  if (open_gate == NULL) {
    fail(env, "call attach(path) first");
    return 0;
  }
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1 ||
      napi_get_value_int32(env, argv[0], k) != napi_ok) {
    fail(env, "a gate number is needed");
    return 0;
  }
  return 1;
}

static napi_value js_open(napi_env env, napi_callback_info info) {
  int32_t k;
  if (!gate_arg(env, info, &k)) return NULL;
  open_gate(k);
  return undefined(env);
}

static napi_value js_wait_entered(napi_env env, napi_callback_info info) {
  int32_t k;
  if (!gate_arg(env, info, &k)) return NULL;
  wait_entered(k);
  return undefined(env);
}

static napi_value js_journal(napi_env env, napi_callback_info info) {
  (void)info;
  if (read_journal == NULL) return fail(env, "call attach(path) first");
  size_t len = read_journal(NULL, 0);
  char *text = malloc(len + 1);
  if (text == NULL) return fail(env, "out of memory");
  size_t got = read_journal(text, len);
  if (got < len) len = got;
  napi_value out;
  napi_status st = napi_create_string_utf8(env, text, len, &out);
  free(text);
  if (st != napi_ok) return fail(env, "cannot make the journal");
  return out;
}

static int export_fn(napi_env env, napi_value exports, const char *name, napi_callback fn) {
  napi_value f;
  return napi_create_function(env, name, NAPI_AUTO_LENGTH, fn, NULL, &f) == napi_ok &&
         napi_set_named_property(env, exports, name, f) == napi_ok;
}

NAPI_MODULE_INIT() {
  if (!export_fn(env, exports, "attach", attach) || !export_fn(env, exports, "open", js_open) ||
      !export_fn(env, exports, "waitEntered", js_wait_entered) ||
      !export_fn(env, exports, "journal", js_journal)) {
    napi_throw_error(env, NULL, "fake_control: cannot export its functions");
    return NULL;
  }
  return exports;
}
