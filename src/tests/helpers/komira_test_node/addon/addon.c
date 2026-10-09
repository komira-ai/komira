// A minimal Node-API addon (BUCK, `addon`): `count()` returns how many times
// it was called in the calling environment (the main thread or one
// worker_thread), from state that environment owns through
// napi_set_instance_data; `finalized()` returns how many environments' state
// has been freed. Every napi_* symbol is left undefined here; node resolves
// them when it loads the library.
#define NAPI_VERSION 8
#include <node_api.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

// One environment's state, created when the addon is loaded into it.
typedef struct {
  int64_t calls;
} env_state;

// Process-wide: the number of env_state values freed by their finalizer.
static atomic_int finalized_count = 0;

// FFI-BOUNDARY: node calls this when the environment that owns `data` is torn
// down; `data` is the env_state calloc'd in the module init, freed here once.
static void free_state(napi_env env, void *data, void *hint) {
  (void)env;
  (void)hint;
  free(data);
  atomic_fetch_add(&finalized_count, 1);
}

// Not static, and not marked for export: c_shared_lib's -fvisibility=hidden
// keeps it out of the dynamic symbol table (test `addon_exports`).
int64_t addon_next_count(env_state *state);

int64_t addon_next_count(env_state *state) {
  state->calls += 1;
  return state->calls;
}

static napi_value count(napi_env env, napi_callback_info info) {
  (void)info;
  void *data = NULL;
  if (napi_get_instance_data(env, &data) != napi_ok || data == NULL) {
    napi_throw_error(env, NULL, "count: this environment has no instance data");
    return NULL;
  }
  napi_value out;
  if (napi_create_int64(env, addon_next_count(data), &out) != napi_ok) return NULL;
  return out;
}

static napi_value finalized(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value out;
  if (napi_create_int32(env, atomic_load(&finalized_count), &out) != napi_ok) return NULL;
  return out;
}

static int export_fn(napi_env env, napi_value exports, const char *name, napi_callback cb) {
  napi_value fn;
  if (napi_create_function(env, name, NAPI_AUTO_LENGTH, cb, NULL, &fn) != napi_ok) return 0;
  return napi_set_named_property(env, exports, name, fn) == napi_ok;
}

// Context-aware: node runs this once per environment that loads the addon.
NAPI_MODULE_INIT() {
  env_state *state = calloc(1, sizeof *state);
  if (state == NULL) {
    napi_throw_error(env, NULL, "addon: out of memory");
    return NULL;
  }
  if (napi_set_instance_data(env, state, free_state, NULL) != napi_ok) {
    free(state);
    napi_throw_error(env, NULL, "addon: napi_set_instance_data failed");
    return NULL;
  }
  if (!export_fn(env, exports, "count", count) || !export_fn(env, exports, "finalized", finalized)) {
    napi_throw_error(env, NULL, "addon: cannot export its functions");
    return NULL;
  }
  return exports;
}
