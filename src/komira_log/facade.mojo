# =============================================================================
# komira_log.facade — the STABLE `log.<level>[fmt, module](*args)` surface.
# =============================================================================
#
# THE CONTRACT P2 INHERITS. Call sites written against this facade do NOT
# change when P2 swaps the backend (synchronous stderr → per-core binary ring
# + drain). The shape:
#
#     import komira_log as log
#     log.info[fmt, module](*args)
#     log.debug[fmt, module](*args) / .trace / .warn / .error
#
#   - `fmt`    : a comptime `StringLiteral` — the format literal (the static
#                site key). P1 substitutes args into it synchronously; P2
#                binary-encodes `[site-id, ts, args]` against the same literal.
#   - `module` : a comptime `StringLiteral` module/target tag (e.g.
#                "komira_agent") for per-module `EnvFilter` filtering. Defaults
#                to "komira" so a tagless call still works.
#   - `*args`  : a variadic `*LogArg` pack — typed structured fields. Positional
#                args fill `fmt`'s `{}`; trailing `Field("k", v)` args render
#                as `k=v`. (See log_arg.mojo for the structured-field model.)
#
# # THE LEVEL GATE (identical in P1 and P2 — part of the stable facade)
#
#   1. COMPTIME FLOOR: `comptime if level < MIN_COMPILED_LEVEL: return` —
#      a below-floor site is DELETED by the compiler (0 cost).
#   2. THE RUNTIME GATE (`admits`): the module's EFFECTIVE level — its
#      longest-prefix `EnvFilter` rule if one matches, and the runtime global
#      threshold otherwise. With no per-module rules (the common case) this is
#      one relaxed `Atomic[uint8]` load + branch (~1-2ns) and no allocation;
#      the prefix walk runs only when rules exist.
#
#      ⚠ IT IS ONE DECISION, NOT TWO SEQUENTIAL GATES (global, then
#      per-module). If the global one RETURNED first, a per-module rule could
#      only ever RAISE a module's threshold and `--log-level=info,pg=debug`
#      could not turn DEBUG on for one module; see `SharedEngine.admits`.
#
# Arg materialization happens AFTER the gates (the `@parameter for` over the
# pack runs only on an admitted call), so a disabled `log.debug(...)` does the
# atomic load + branch and returns — no render, no alloc, no write.
#
# # P1 → P2 SEAM (what changes, what stays)
#
#   STAYS (the stable facade): the `log.<level>[fmt, module](*args)` call shape;
#     the module tag; the structured `*LogArg` pack; the comptime floor; the
#     runtime atomic global gate; the per-module EnvFilter gate; the ambient
#     process-static holder reach (`config._ensure_config()`).
#   CHANGES (the backend, P2 only): the enabled-body. P1 renders synchronously
#     (`_emit_sync`: interpolate + render_line + stderr write on the caller).
#     P2 replaces `_emit_sync`'s body with a raw-counter timestamp + binary
#     `@parameter for` encode into the worker's per-core SPSC ring (no format
#     on the hot path). The holder resolves the engine instead of the LogConfig.
#
# Encapsulation: no `UnsafePointer` in any public facade signature. The
# config pointer is resolved internally (config.mojo) and deref'd in-method;
# the `*LogArg` pack is consumed in-method (never stored in a slab). Public
# surface is `fmt`/`module` comptime literals + the typed `*args` values.
# =============================================================================

from komira_log.levels import (
    MIN_COMPILED_LEVEL,
    LEVEL_TRACE,
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
)
from komira_log.log_arg import LogArg, ARG_FIELD
from komira_log.pattern_layout import interpolate, render_line
from komira_log.config import _ensure_config
from komira_clock import now_unix_ms

# P2b engine reach — the binary-ring backend behind the stable facade. The
# ambient facade resolves the process-global IMMORTAL LogManager (a
# C-static-parked, leaked SharedEngine).
from komira_log.engine.log_manager import LogManager
from komira_log.engine.log_event_record import (
    LogEventRecord,
    ArgBlobWriter,
    REC_LOG,
    FLAG_HAS_ARG_OVERFLOW,
    ARG_INLINE_BYTES,
)
from komira_log.engine.site_dictionary import fnv1a_32
from komira_log.engine.calibration import read_raw_ticks
from komira_log.engine.worker_id_tls import WORKER_ID_UNSET


# =============================================================================
# THE COLD SINKS, AND WHY `_write_rendered` IS ONE FUNCTION AND NOT THREE
# BLOCKS.
# =============================================================================
#
# `_emit` has THREE ways to end up writing a rendered line. If each carried its
# own copy of the render sequence INSIDE the `@always_inline` body, every call
# site would elaborate the sequence two or three times over:
#
#     1. engine installed, caller is NOT a bound worker thread (`wid ==
#        WORKER_ID_UNSET`)                                  -> emit_fallback_line
#     2. no engine installed at all (the P1 synchronous path) -> cfg.write_line
#     3. engine installed, the DROP ring rejected an ERROR push -> escalate_line
#
# The three differ in ONE thing: which sink takes the finished `String`. The
# render itself — interpolate the fmt, assemble the line — is byte-identical in
# all three, and both of its helpers (`interpolate`, `render_line`) already take
# RUNTIME arguments.
#
# ⇒ the sink becomes a runtime tag and the render becomes ONE out-of-line
#   function with NO comptime parameters at all. One body for the whole
#   program, at any site count, in any number of modules.
#
# ⚠ `level` AND `module` ARE RUNTIME ARGUMENTS HERE, DELIBERATELY, AND THAT IS
# NOT AN OVERSIGHT. `logger._emit_line` keeps them comptime and is therefore
# instantiated once per (level, module) pair; that shape gets WORSE, not
# better, as soon as each file takes its own module tag — which is what every
# logging convention tells you to do (see logger_erased.mojo). `render_line`
# has always taken
# `level: UInt8` and `module: StaticString` as runtime values, so keying this
# function on them would buy nothing and re-open that trap. It is keyed on
# NOTHING.
#
# ⚠ THIS IS NOT "OUTLINE THE WHOLE EMIT". Moving the WHOLE body — comptime
# `fmt` and arg pack included — behind a call RELOCATES N monomorphisations
# without making them fewer, and buys almost nothing. Nothing about the HOT path
# moves here: the
# gates, the site registration and the ring encode are all still inlined at the
# site, because those are what the data plane pays for. What moves is only the
# part that was already going to call `interpolate` — and it exists ONCE
# instead of three times.
# =============================================================================

comptime _SINK_FALLBACK = UInt8(0)
"""Engine installed, caller is not a bound worker -> `emit_fallback_line`."""
comptime _SINK_ESCALATE = UInt8(1)
"""Engine installed, an ERROR push was dropped -> `escalate_line`."""
comptime _SINK_P1 = UInt8(2)
"""No engine installed -> the P1 synchronous config sink."""


def _write_rendered(
    sink: UInt8,
    level: UInt8,
    module: StaticString,
    fmt_s: String,
    var positionals: List[String],
    var fields: List[String],
):
    """Interpolate + assemble + write ONE already-rendered log line.

    NOT `@always_inline` and NOT parametric — this is the single elaborated
    body every cold write in the program shares. The emitted line is assembled
    by the same `interpolate` + `render_line` pair, in the same order, with the
    same arguments as the three inline copies it replaces, so the bytes on the
    wire are unchanged.
    """
    var message = interpolate(fmt_s, positionals)
    var line = render_line(now_unix_ms(), level, module, message, fields)

    if sink == _SINK_P1:
        # SAFETY: forever-lived process singleton; see config._resolve_config.
        var cfg = _ensure_config()
        cfg[].write_line(line)
        return

    # SAFETY: the process-global IMMORTAL engine (LogManager — leaked, never
    # moved/freed) outlives every caller. Null-checked before any deref; a null
    # here means the engine was resolved by the caller and cannot have vanished,
    # so the branch is unreachable in practice and silent rather than fatal.
    var eng = LogManager._resolve()
    # MOJO-1.0.0: `Bool(ptr)` is gone (Pointer is non-null by design). `Int(p) != 0` is exactly what b2's `UnsafePointer.__bool__` computed.
    if Int(eng) == 0:
        return
    if sink == _SINK_ESCALATE:
        eng[].escalate_line(line)
    else:
        eng[].emit_fallback_line(line)


# -----------------------------------------------------------------------------
# The core emit. Monomorphized per (level, fmt, module, arg-signature) — the
# comptime parameters carry the static parts; only `*args` is dynamic.
# -----------------------------------------------------------------------------


@always_inline
def _emit[
    level: UInt8,
    fmt: StringLiteral,
    module: StringLiteral,
    *ArgTs: LogArg,
](*args: *ArgTs):
    # (1) COMPTIME FLOOR — a below-floor site compiles to nothing.
    comptime if level < MIN_COMPILED_LEVEL:
        return

    comptime n = args.__len__()

    # WHICH cold sink the single render block at the bottom will write to, IF
    # it is reached at all. Every `return` above it is a gate rejecting the
    # record, and the hot ring-push path returns before it too — so a suppressed
    # log still costs exactly the three gates and nothing else.
    var sink = _SINK_P1

    # --- THE P1 → P2 SEAM: prefer the binary-ring engine when installed.
    # The forever-root (EngineContext / a long-lived service) installs the
    # SharedEngine at init; until then (early init, a tool with no runtime) the
    # P1 synchronous-stderr fallback carries the call so a log never crashes.
    # The call shape, the gate, and the args are IDENTICAL on both paths — only
    # which backend the admitted record reaches differs. The binary path is
    # inlined here (NOT a separate fn) so the comptime `*args` pack stays in
    # scope — forwarding a VariadicPack across a fn boundary is fragile in
    # Mojo 1.0.0b1.
    # ONE resolve: `LogManager._resolve()` loads the engine address from the
    # process-global C cell. A null pointer == no engine installed →
    # fall through to the P1 synchronous fallback below.
    # SAFETY: the resolved pointer names the process-global IMMORTAL engine
    # (LogManager — leaked, never moved/freed), so it outlives every caller.
    # Null == no global installed → the P1 synchronous fallback below. See
    # LogManager._resolve. Null-checked here before any deref.
    var eng = LogManager._resolve()
    # MOJO-1.0.0: `Bool(ptr)` is gone (Pointer is non-null by design). `Int(p) != 0` is exactly what b2's `UnsafePointer.__bool__` computed.
    if Int(eng) != 0:
        # Bind ONE ref to the resolved engine so the gate/encode sequence does
        # not re-deref the `MutExternalOrigin` pointer per call (the compiler
        # cannot prove non-aliasing across a wildcard-origin `eng[]`, so each
        # repeated `eng[].method()` was reloading — bind once).
        ref e = eng[]
        if not e.enabled():
            return
        # (2)+(3) THE LEVEL GATE — ONE decision, not two sequential
        # comparisons (global, then per-module) where the first RETURNS and a
        # per-module rule can only ever RAISE a module's threshold. See
        # `SharedEngine.admits` for the whole account; the short version is
        # that `--log-level=info,komira_pg=debug` must turn DEBUG on for one
        # module, which is the single most common thing anyone asks a log
        # filter to do.
        if not e.admits(level, module):
            return

        # comptime ids — literals at the call site, ZERO runtime hash.
        comptime site_id = fnv1a_32(fmt)
        comptime module_id = fnv1a_32(module)
        # Raw-counter timestamp. NO tick→ns divide on the hot
        # path; the drain converts via the calibration anchor.
        var ts = read_raw_ticks()

        var wid = e.current_worker_id()

        if wid != WORKER_ID_UNSET:
            # --- THE HOT PATH, and the ONLY arm that stays fully inlined at
            # the call site: encode the args DIRECTLY into the POD record's
            # inline `arg_blob` (NanoLog no-alloc rule) — ZERO heap
            # alloc on the common ≤48-byte path. The `ArgBlobWriter` overflows
            # only the tail of a long-string blob to a function-local List; the
            # drain on the SAME core decodes + renders later. Wire format
            # byte-identical to the prior scratch-List encode (tag table then
            # raw bytes).
            # Register the site for decode (idempotent — first call per
            # (fmt, module) appends; subsequent calls are a short linear-scan
            # no-op).
            #
            # ⚠ THIS SITS INSIDE THE RING ARM DELIBERATELY, not ABOVE the
            # `wid` read. The non-worker arm below renders on the caller and
            # writes a finished String, so it never reaches a drain and its
            # (fmt, module) is never looked up. Registering there would put
            # every unbound thread in the process (HTTP handlers, the agent
            # heartbeat, CLI tools) into an unsynchronised `List.append` on the
            # shared SiteDictionary, for an entry nothing would ever read. Only a record that will be
            # DECODED needs its site registered.
            #
            # ⛔ THIS DOES NOT MAKE THE DICTIONARY THREAD-SAFE, and must not
            # be read as having done so — two BOUND workers emitting a new
            # site still race here. That residual needs a synchronised (or
            # per-worker) SiteDictionary.
            e.register_site[fmt, module]()

            var rec = LogEventRecord()
            rec.kind = REC_LOG
            rec.level = level
            rec.site_id = site_id
            rec.module_id = module_id
            rec.n_args = UInt8(n)
            rec.timestamp = ts

            var w = ArgBlobWriter(rec.arg_blob)

            comptime for i in range(n):
                w.append(args[i].arg_tag())

            comptime for i in range(n):
                args[i].encode_into_blob(w)

            ref ring = e.ring(Int(wid))
            if not w.overflowed():
                # Common path: the encoded blob fit inline — nothing to spill.
                rec.arg_inline_len = UInt16(w.inline_len())
            else:
                # Rare path (long-string args): spill the FULL blob to the ring
                # arena (inline 48 + overflow tail) and carry the handle.
                var handle = ring.arena_append(w.full_blob())
                rec.flags = rec.flags | FLAG_HAS_ARG_OVERFLOW
                rec.arg_off = handle[0]
                rec.arg_len = handle[1]

            if ring.try_push(rec):
                return

            # WARN/ERROR-never-dropped: if the DROP ring
            # rejected the push, escalate to a synchronous, never-dropped,
            # flushed write (crash-tail safety). Comptime-gated, so a
            # below-WARN site compiles this to an unconditional `return` and
            # pays nothing — exactly as when the escalation render was spelled
            # out here.
            #
            # ⚠ THE THRESHOLD IS `LEVEL_WARN`, NOT `LEVEL_ERROR`: the
            # guarantee is "drop TRACE/DEBUG/INFO; never drop WARN/ERROR"
            # (shared_engine.mojo's module header), and an ERROR threshold
            # would drop every rejected WARN.
            comptime if level >= LEVEL_WARN:
                sink = _SINK_ESCALATE
            else:
                return
        else:
            # Non-worker thread (TLS unset): render synchronously + write
            # directly (cold off-thread path) so the record is never stranded
            # on an undrained per-core ring.
            sink = _SINK_FALLBACK
    else:
        # --- P1 synchronous fallback (no engine installed). ---
        # Resolve the process-global config (lazily inits a default if none).
        # SAFETY: forever-lived process singleton; see config._resolve_config.
        var cfg = _ensure_config()

        if not cfg[].enabled():
            return

        # (2)+(3) THE LEVEL GATE — ONE decision, exactly as on the engine arm
        # above. Two sequential vetoes here had the identical defect: the
        # global gate returned first, so a per-module rule could only RAISE.
        # `LogConfig.admits` is the P1 twin of `SharedEngine.admits` and
        # carries the same contract.
        if not cfg[].admits(level, module):
            return

        # `sink` is already `_SINK_P1`.

    # --- THE SINGLE COLD RENDER BLOCK. ---
    # Reached by exactly the three arms that need it: the
    # non-worker fallback, the dropped-ERROR escalation, and the no-engine P1
    # path. Every gate above returns before it, so a SUPPRESSED log never
    # reaches this and an admitted ring push returns before it too.
    #
    # The `comptime for` over the arg pack is irreducibly per-site — it is the
    # only part of the sequence that has to see the pack's types — but it now
    # appears ONCE per site instead of two or three times, and everything after
    # it is a call into one shared, non-parametric body.
    var positionals = List[String]()
    var fields = List[String]()

    comptime for i in range(n):
        var rendered = args[i].render()
        if args[i].arg_tag() == ARG_FIELD:
            fields.append(rendered^)
        else:
            positionals.append(rendered^)

    _write_rendered(
        sink, level, module, String(fmt), positionals^, fields^
    )


# -----------------------------------------------------------------------------
# The five public level functions. Each is a thin comptime-level wrapper over
# `_emit`. `module` defaults to "komira" so a tagless call compiles.
# -----------------------------------------------------------------------------


@always_inline
def trace[
    fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
](*args: *ArgTs):
    _emit[LEVEL_TRACE, fmt, module](*args)


@always_inline
def debug[
    fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
](*args: *ArgTs):
    _emit[LEVEL_DEBUG, fmt, module](*args)


@always_inline
def info[
    fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
](*args: *ArgTs):
    _emit[LEVEL_INFO, fmt, module](*args)


@always_inline
def warn[
    fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
](*args: *ArgTs):
    _emit[LEVEL_WARN, fmt, module](*args)


@always_inline
def error[
    fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
](*args: *ArgTs):
    _emit[LEVEL_ERROR, fmt, module](*args)


# -----------------------------------------------------------------------------
# get_logger — the log4j `LogManager.getLogger("module")` ergonomic.
# -----------------------------------------------------------------------------
#
# A module-bound handle to the process-global IMMORTAL engine (LogManager). Any
# context-less site — a UDF body, the pg driver, an HTTP handler — obtains one
# with `get_logger["my.module"]()` and calls `.<level>[fmt](*args)`, WITHOUT
# threading a handle and WITHOUT re-typing the module at every call. It is a
# zero-field POD (the module is a comptime parameter); each emit routes through
# the SAME facade `_emit` as the bare `log.<level>` surface (global resolve + the
# comptime floor / atomic global gate / per-module EnvFilter gate + the P1
# synchronous-stderr fallback when no global is installed). So a UDF that logs
# via `get_logger` reaches the same engine + gates as everything else.


struct GlobalLogger[module: StringLiteral](Movable, Deinitable):
    """Log4j-style module-bound handle to the process-global immortal logger.
    Obtained via `get_logger[module]()`. Zero-field POD; `.<level>[fmt](*args)`
    forwards to the facade `_emit` with `module` baked in."""

    @always_inline
    def __init__(out self):
        pass

    @always_inline
    def trace[fmt: StringLiteral, *ArgTs: LogArg](self, *args: *ArgTs):
        _emit[LEVEL_TRACE, fmt, Self.module](*args)

    @always_inline
    def debug[fmt: StringLiteral, *ArgTs: LogArg](self, *args: *ArgTs):
        _emit[LEVEL_DEBUG, fmt, Self.module](*args)

    @always_inline
    def info[fmt: StringLiteral, *ArgTs: LogArg](self, *args: *ArgTs):
        _emit[LEVEL_INFO, fmt, Self.module](*args)

    @always_inline
    def warn[fmt: StringLiteral, *ArgTs: LogArg](self, *args: *ArgTs):
        _emit[LEVEL_WARN, fmt, Self.module](*args)

    @always_inline
    def error[fmt: StringLiteral, *ArgTs: LogArg](self, *args: *ArgTs):
        _emit[LEVEL_ERROR, fmt, Self.module](*args)


@always_inline
def get_logger[module: StringLiteral]() -> GlobalLogger[module]:
    """Log4j `getLogger` — a module-bound handle to the process-global immortal
    logger (`LogManager`). `get_logger["komira_auth"]().info[fmt](*args)`. The
    module is bound once; the reach is the ambient global (no ctx / no threaded
    handle needed). For code that HAS a ctx, prefer the typed `ctx.log` /
    `ctx.logger` (per-context tracked-origin fast path)."""
    return GlobalLogger[module]()


# -----------------------------------------------------------------------------
# Ambient SPAN surface (P4b) — the no-`ctx` reach to the unified engine.
# -----------------------------------------------------------------------------
#
# The span twin of the ambient `log.<level>` reach: resolve the process-global
# `SharedEngine` (`engine_handle.resolve_cached`) and open/close a span on it.
# When NO engine is installed (a standalone tool, early init, a no-`ctx`
# dispatcher-only compile) the resolve returns null and these are a pure no-op
# — `span_open` returns span_id 0, `span_close` does nothing. So a no-`ctx`
# pipeline emits spans onto the unified engine IFF a forever-root installed one,
# and is harmlessly silent otherwise (which is correct — a standalone compile
# has no engine/ring to drain).
#
# This is the SAME ambient pattern `log.info(...)` uses to reach the engine; it
# is the resolution for the "no-`ctx` dispatcher path has no EngineContext to
# borrow a typed `Tracer[origin]` from" design gap. Production span sites that
# DO have a live `EngineContext` reach the SAME engine through the typed
# `ctx.tracer()` (`Tracer[origin]`) — but the morsel executor and the no-`ctx`
# compiler path have no `ctx` in scope, so they take the ambient reach here.
#
# `worker_id` is explicit (NOT TLS-resolved) because the engine span stack is
# per-worker and the executor opens its query/segment spans on a fixed lane
# (worker_id=0) the same way the obs Tracer did — the caller owns the lane.
#
# SAFETY: `resolve_cached` returns a forever-root borrow-handle to the installed
# engine (process-lived; outlives every caller) or null. Null-checked before
# any deref. No `UnsafePointer` crosses this public surface; the pointer is
# resolved + deref'd in-method and never stored.


@always_inline
def span_open[
    name: StringLiteral, module: StringLiteral = "komira"
](worker_id: Int) -> UInt64:
    """Open a span on the ambient (process-global) unified engine for
    `worker_id`. Returns the new span_id, or 0 when no engine is installed
    (no-op). The parent is the worker's current innermost span (nested
    correlation); a fresh trace_id is minted for a root span. `name` is
    comptime — the digest is a literal at the call site, zero runtime hash."""
    var eng = LogManager._resolve()
    # MOJO-1.0.0: `Bool(ptr)` is gone (Pointer is non-null by design). `Int(p) != 0` is exactly what b2's `UnsafePointer.__bool__` computed.
    if Int(eng) == 0:
        return UInt64(0)
    return eng[].start_span[name, module](worker_id)


@always_inline
def span_close(span_id: UInt64, worker_id: Int):
    """Close `span_id` on the ambient unified engine for `worker_id`. No-op
    when no engine is installed or `span_id == 0`."""
    if span_id == 0:
        return
    var eng = LogManager._resolve()
    # MOJO-1.0.0: `Bool(ptr)` is gone (Pointer is non-null by design). `Int(p) != 0` is exactly what b2's `UnsafePointer.__bool__` computed.
    if Int(eng) == 0:
        return
    eng[].end_span(span_id, worker_id)
