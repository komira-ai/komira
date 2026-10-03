#include <pthread.h>
#include <stdint.h>

// =============================================================================
// _log_holder_shim.c -- the process-lifetime logging holders.
// =============================================================================
//
// Three one-word linker-global cells and nothing else:
//   * the address of the process-lifetime (immortal, never-moved, never-freed)
//     Mojo `SharedEngine` (the P2 engine, `LogManager`);
//   * the address of the process-lifetime P1 `LogConfig` (`config.mojo`);
//   * the process's selected line layout (0 = text, 1 = JSON,
//     `pattern_layout.select_log_layout`).
// It contains ZERO logging logic: no rings, no encode, no drain, no timestamps
// -- all of that stays in Mojo. This is the log4j analogy exactly: log4j's
// `Logger` is Java; the static `LogManager` field just parks the reference.
//
// WHY C: Mojo has NO mutable module-level globals (`var` at module scope ->
// "global variables are not supported") and NO function-local statics. A real
// linker global therefore lives in a tiny C translation unit, reached from Mojo
// via `external_call`.
//
// SAFETY (the confined-unsafe story): the address cells are cast back to a
// typed pointer HERE, in C (`komira_log_holder_get_engine`,
// `komira_log_holder_get_config`), and the Mojo side declares only the RETURN
// TYPE of those two calls (`LogManager._resolve`, `config._resolve_config`), so
// no integer is ever converted to a pointer in Mojo. Both targets are IMMORTAL
// leaked heap slots (created once at process init, never moved, never freed),
// so the pointer is valid for the whole process.
//
// Thread-safety: the setters are called at init (single-threaded, before any
// worker/reader exists); a get is a plain aligned-word load (atomic on all
// supported ABIs for a naturally-aligned word). No init race because the
// install happens-before any thread that could read it (the workers are
// spawned AFTER install).
// =============================================================================

// =============================================================================
// THE ACCESSORS ARE `KOMIRA_SHIM_LOCAL` -- ONE CELL PER LIBRARY, DECIDED
// =============================================================================
//
// When this archive is force-loaded into more than one shared library, each
// library gets its own `static` cell, but exported accessors would land in
// every library's `.dynsym` and COLLIDE. ELF's symbol namespace is FLAT: the
// first-loaded library's accessor would then satisfy every reference in ALL of
// them, and a later library's `LogManager` would read and write the FIRST
// library's cell.
//
// WHAT THAT WOULD DO IS NOT AN OVERWRITE. `LogManager.install` is INSTALL-ONCE
// (`if _holder_get() != 0: return`), so the second library's install would be a
// silent NO-OP and its `_resolve()` would hand back the FIRST library's address,
// reconstructed as `UnsafePointer[SharedEngine]` over a `SharedEngine` the OTHER
// library elaborated independently. Type confusion across two elaborations,
// with no diagnostic on either side, decided by load order. macOS's two-level
// namespace does not do this, so the platform that ships would be the one that
// breaks.
//
// => THE DECISION IS ONE ENGINE PER LIBRARY. A `SharedEngine` is a MOJO STRUCT
// and no library may reconstruct another's, so the accessors are hidden.
//
// NOTHING OUTSIDE `komira_log` REFERENCES THESE ACCESSORS, which is what makes
// hiding them safe.
// =============================================================================
#if defined(__GNUC__) || defined(__clang__)
#define KOMIRA_SHIM_LOCAL __attribute__((visibility("hidden")))
#else
#define KOMIRA_SHIM_LOCAL
#endif

// The engine cell. `static` = internal linkage; reached only through the
// accessors below. Held as an INTEGER address, NOT a `void*`, so the Mojo side
// marshals a plain integer across the FFI on the write side, and the pointer is
// produced only by `komira_log_holder_get_engine` below. 0 == no engine
// installed -> the P1 synchronous fallback.
static unsigned long g_komira_log_engine = 0;

// Install the immortal engine's address (as an integer). Called ONCE at init.
KOMIRA_SHIM_LOCAL void komira_log_holder_set(unsigned long engine_addr) {
  g_komira_log_engine = engine_addr;
}

// Resolve the installed engine's address as an integer (0 if none). A single
// aligned load (~1-2 ns). Used only for the "is one installed" test.
KOMIRA_SHIM_LOCAL unsigned long komira_log_holder_get(void) { return g_komira_log_engine; }

// The installed engine as a pointer (NULL if none). The one int->pointer
// conversion; the Mojo caller declares only the return type.
KOMIRA_SHIM_LOCAL void *komira_log_holder_get_engine(void) {
  return (void *)g_komira_log_engine;
}

// TEST-ONLY: clear the cell so a test process can install a fresh global.
// Production NEVER calls this (the engine is immortal). Leaks the prior engine
// (harmless in a test process that is about to exit).
KOMIRA_SHIM_LOCAL void komira_log_holder_clear(void) { g_komira_log_engine = 0; }

// The P1 `LogConfig` cell: the same contract as the engine cell above, for the
// synchronous config `config.mojo` installs. 0 == no config installed.
static unsigned long g_komira_log_config = 0;

KOMIRA_SHIM_LOCAL void komira_log_config_holder_set(unsigned long config_addr) {
  g_komira_log_config = config_addr;
}

KOMIRA_SHIM_LOCAL unsigned long komira_log_config_holder_get(void) { return g_komira_log_config; }

// The installed `LogConfig` as a pointer (NULL if none); see
// `komira_log_holder_get_engine`.
KOMIRA_SHIM_LOCAL void *komira_log_holder_get_config(void) {
  return (void *)g_komira_log_config;
}

// The selected line layout: 0 = text (the default), 1 = Cloud-Logging JSON.
// Written by `pattern_layout.select_log_layout` at startup, read once per
// rendered line.
static int g_komira_log_layout_json = 0;

KOMIRA_SHIM_LOCAL void komira_log_layout_set(int json) { g_komira_log_layout_json = json; }

KOMIRA_SHIM_LOCAL int komira_log_layout_get(void) { return g_komira_log_layout_json; }

// =============================================================================
// The ambient worker-id TLS slot (`engine/worker_id_tls.mojo`): integers only.
// =============================================================================
//
// A pthread TLS value is a `void*` the library stores verbatim and never
// dereferences. The worker id is an INTEGER, so the integer <-> `void*`
// conversion is done here and the Mojo side never names a pointer.

// Create the key. Returns the key (>= 0), or -1 if `pthread_key_create` failed.
KOMIRA_SHIM_LOCAL int64_t komira_log_tls_key_create(void) {
  pthread_key_t key;
  if (pthread_key_create(&key, 0) != 0) return -1;
  return (int64_t)key;
}

// Bind `value` to this thread's slot for `key`.
KOMIRA_SHIM_LOCAL void komira_log_tls_set(int64_t key, int64_t value) {
  (void)pthread_setspecific((pthread_key_t)key, (void *)(intptr_t)value);
}

// This thread's value for `key`; 0 if the thread never set one.
KOMIRA_SHIM_LOCAL int64_t komira_log_tls_get(int64_t key) {
  return (int64_t)(intptr_t)pthread_getspecific((pthread_key_t)key);
}
