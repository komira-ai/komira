# =============================================================================
# komira_log.engine.log_manager — the process-global immortal LogManager.
# =============================================================================
#
# THE log4j `LogManager` ANALOG. A process-lifetime, install-once, IMMORTAL
# `SharedEngine` reached from ANY context-less site (the ambient `log.*` facade,
# `LogManager.get_logger("module")`, a UDF body, the pg driver, an HTTP handler)
# WITHOUT threading a handle. Its address must never name a MOVABLE struct
# field: a holder pointing at a per-session field dangles once that session is
# destroyed.
#
# # THE MECHANISM
#
# The process-global pointer cell is a first-party C linker-global (a single
# `static void*` in `_log_holder_shim.c`, reached via `external_call`). Mojo
# has NO module-level `var` (`global variables are not supported`) and no
# fn-local statics, so the cell lives in C — but the C holds ONE pointer and has
# ZERO logging logic. The `SharedEngine` + per-core rings + drain + binary encode
# stay 100% Mojo. This is exactly log4j: the `LogManager` static parks a
# reference; the `Logger` (here `SharedEngine`) is the real thing.
#
# # IMMORTALITY (why this is use-after-free-safe)
#
# `install` MOVES the engine onto the heap and `unsafe_leak()`-LEAKS it — the
# engine is NEVER moved, NEVER freed, valid for the whole process. So the single
# `unsafe_from_address` accessor (`_resolve`) reconstructs a pointer that is
# ALWAYS valid — the forever-root borrow-handle contract is literally true, not
# faked. Contrast a holder whose target is `EngineContext._log_engine` (a
# per-session, destroy-recreate FIELD → a dangling pointer).
#
# INSTALL-ONCE / NO-CLOBBER: the FIRST `install` wins and is immortal; a later
# `install` is a no-op (its engine drops normally). Two `EngineContext`s / two
# services therefore CANNOT stomp the global (there is one immortal target, set
# once).
#
# # Encapsulation
#
# The engine's ONLY `unsafe_from_address` is `_resolve` below, over the IMMORTAL
# target — documented with a SAFETY block (the P1 config holder in config.mojo
# has the one other, over its own immortal slot). It produces a
# TRANSIENT LOCAL wildcard-origin pointer (never a stored wildcard FIELD), the
# shape `worker_id_tls` uses.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer, OwnedPointer

from komira_log.engine.shared_engine import SharedEngine


# -----------------------------------------------------------------------------
# The C-static pointer holder (the entire non-Mojo surface — _log_holder_shim.c).
# Two `external_call`s: park an address, read it back. No logging logic in C.
# -----------------------------------------------------------------------------


@always_inline
def _holder_set(engine_addr: Int):
    """Park `engine_addr` (a plain integer address) in the process-global C
    cell. Called ONCE at install. Passes the address as an INTEGER across the
    FFI — NO `unsafe_from_address` here; the single confined int->typed-pointer
    cast lives only in `_resolve`."""
    external_call["komira_log_holder_set", NoneType](UInt64(engine_addr))


@always_inline
def _holder_get() -> Int:
    """Read the parked integer address (0 == none). A single aligned load
    (~1-2 ns) — the hot-path ambient resolve. Returns a plain integer; the deref cast is in `_resolve`."""
    return Int(external_call["komira_log_holder_get", UInt64]())


# -----------------------------------------------------------------------------
# LogManager — the install-once immortal global.
# -----------------------------------------------------------------------------


struct LogManager:
    """The process-global immortal `SharedEngine` registry (log4j LogManager).

    Not instantiated — a namespace for the static install/resolve surface. The
    engine it parks is IMMORTAL (leaked at install, never freed), so every
    resolve is valid for the whole process.
    """

    @staticmethod
    def install(var engine: SharedEngine):
        """Install `engine` as the process-global immortal logger. INSTALL-ONCE:
        the first call wins and the engine is LEAKED (never freed → immortal);
        a subsequent call is a no-op (its `engine` drops normally). This makes
        the global impossible to clobber — two contexts/services cannot stomp
        it.

        Call ONCE at process start, before workers/readers exist (single-
        threaded init; the gate is non-atomic, matching the P1 `config` lazy
        init it replaces)."""
        if _holder_get() != 0:
            # Already installed + immortal. Drop the redundant engine (freed).
            _ = engine^
            return
        # Move onto the heap, then unsafe_leak() to LEAK: the engine keeps its
        # stable heap address forever (never freed) — the immortal target the
        # `_resolve` accessor's SAFETY rests on.
        var op = OwnedPointer[SharedEngine](value=engine^)
        var raw = op^.unsafe_take_allocation().unsafe_leak()
        _holder_set(Int(raw))

    @staticmethod
    @always_inline
    def is_installed() -> Bool:
        """True iff the immortal global engine has been installed."""
        return _holder_get() != 0

    @staticmethod
    @always_inline
    def _resolve() -> UnsafePointer[SharedEngine, MutUntrackedOrigin]:
        """Resolve the immortal global engine (null pointer if none installed).

        # SAFETY: The parked address names the IMMORTAL global engine — moved
        # onto the heap and `unsafe_leak()`-leaked by `install`, so it is NEVER
        # moved and NEVER freed. The reconstructed pointer is therefore valid
        # for the entire process (the forever-root borrow-handle contract,
        # HONORED not faked). The produced pointer is a transient LOCAL (never
        # a stored wildcard-origin field). Callers null-check before deref.
        # Reads the engine's heap-owning fields coherently (proven:
        # test_log_manager_global, num_workers())."""
        return UnsafePointer[SharedEngine, MutUntrackedOrigin](
            unsafe_from_address=_holder_get()
        )

    @staticmethod
    def _test_reset():
        """TEST-ONLY: clear the global cell so a test can install a fresh engine.
        Production NEVER calls this — the global is immortal. The prior engine
        leaks (harmless in a test process). Lets per-test-function install work
        despite the production install-once semantics."""
        external_call["komira_log_holder_clear", NoneType]()

    @staticmethod
    def _test_install_borrow(ref engine: SharedEngine):
        """TEST-ONLY: park the address of a TEST-OWNED engine as the global,
        WITHOUT moving/leaking it. The test frame owns `engine` and MUST keep it
        alive across the log calls + drain, then `_test_reset()` before it drops
        (a test-scoped forever-root borrow). Production uses `install` (move + immortal); this exists so
        facade/emit tests can keep owning + directly draining their engine."""
        _holder_set(Int(UnsafePointer(to=engine)))
