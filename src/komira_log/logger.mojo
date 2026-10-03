# =============================================================================
# komira_log.logger — the TYPED `ctx.logger.<level>[fmt, module](*args)` surface
# (P2c).
# =============================================================================
#
# WHY A TYPED HANDLE. The bare module-level `log.info(...)` reaches the engine
# through the process-global holder → an `UnsafePointer[SharedEngine]` with an
# UNTRACKED origin, rebuilt from an integer address. The compiler cannot prove
# non-aliasing across an untracked `eng[]`, so the gate/encode sequence does NOT
# inline cleanly, and that shows up as a per-call DISPATCH penalty.
#
# The fix is structural, NOT a micro-optimization: reach the engine through a
# CONCRETE-origin field reference on the forever-root.  `EngineContext` owns
# `_log_engine: SharedEngine` as a FIELD; `ctx.logger()` returns a
# `Logger[origin]` that carries a `Pointer[SharedEngine, origin]` borrow whose
# origin == `ctx._log_engine`.  Because that origin is concrete (the compiler
# TRACKS it), every `_eng[].method()` inlines — the dispatch cost is gone,
# leaving the irreducible TLS / raw-ts / encode / push.
#
# This is EXACTLY how `TracerHandle[origin]` (komira_trace) carries
# `Pointer[Tracer, origin]` for the obs path.
#
# # THE THREE-TIER API (documented here; the call surface is identical across
# all three so a site can be promoted without touching the fmt/args):
#
#   ctx.logger.info[fmt, module](*args)      # TYPED, primary.
#                                            #   concrete-origin field ref,
#                                            #   dispatch inlines.
#   service.logger.info[fmt, module](*args)  # TYPED, service-owned — same path,
#                                            #   the service owns its engine.
#   log.info[fmt, module](*args)             # AMBIENT fallback. The
#                                            #   no-ctx/no-service reach via the
#                                            #   process-global holder.
#
# The COMPTIME level floor + the runtime atomic global gate + the per-module
# EnvFilter gate are IDENTICAL to the module facade — only the engine REACH
# differs (concrete field ref vs untracked holder resolve).
#
# # Encapsulation
#
# `Logger[origin]` holds a `Pointer[SharedEngine, Self.origin]` — a CONCRETE
# origin (NOT a wildcard), constructed from a live `ref [origin] SharedEngine`
# (Pointer-of-a-referent, never `unsafe_from_address=Int`). No `UnsafePointer`
# crosses the public API. The `*ArgTs: LogArg` variadic passes TYPED values,
# never pointers. The borrow's origin == the forever-root's `_log_engine` field,
# whose lifetime the compiler tracks for the duration the `Logger` is alive (the
# same no-destroy-recreate window TracerHandle relies on). The field is
# `Pointer[T, concrete-origin]`, not a wildcard.
# =============================================================================

from std.memory import Pointer

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
from komira_clock import now_unix_ms

from komira_log.engine.shared_engine import SharedEngine
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


# -----------------------------------------------------------------------------
# _emit_through — the SHARED enabled-body, taking a CONCRETE-origin `ref e`.
#
# Both the typed `Logger` (concrete field ref) and — in principle — any caller
# with a tracked `ref SharedEngine` route through this. It is `@always_inline`
# AND takes `e` by a concrete `mut ref` so the compiler can prove non-aliasing
# and inline every `e.method()` straight into the call site. This is the WHOLE
# point of P2c: the body is byte-identical to the facade's enabled-body, but
# because `e`'s origin is tracked (not untracked), the dispatch penalty of the
# ambient holder evaporates.
#
# The arg-blob wire format is byte-identical to facade._emit (tag table then raw
# bytes), so a record emitted here decodes the SAME as one from the ambient
# path — the round-trip test asserts exactly this.
# -----------------------------------------------------------------------------


comptime _SINK_FALLBACK = UInt8(0)
"""Caller is not a bound worker -> `emit_fallback_line`."""
comptime _SINK_ESCALATE = UInt8(1)
"""The DROP ring rejected a WARN/ERROR push -> `escalate_line`."""


def _write_rendered_through(
    mut e: SharedEngine,
    sink: UInt8,
    level: UInt8,
    module: StaticString,
    fmt_s: String,
    var positionals: List[String],
    var fields: List[String],
):
    """Interpolate + assemble + write ONE already-rendered line, for either
    cold arm of the typed emit.

    The twin of `facade._write_rendered`, minus its P1 arm (a typed `Logger`
    always has an engine — that is what it borrows). NOT `@always_inline` and
    NOT parametric, so the two cold arms of every typed site share ONE
    elaborated body instead of carrying a copy each; the render sequence and
    its arguments are byte-identical to the facade's, so a line escalated from
    the typed surface is indistinguishable from one escalated from the ambient
    one. `test_log_typed_never_drop_contract.test_both_surfaces_escalate_
    identically` asserts exactly that.
    """
    var message = interpolate(fmt_s, positionals)
    var line = render_line(now_unix_ms(), level, module, message, fields)
    if sink == _SINK_ESCALATE:
        e.escalate_line(line)
    else:
        e.emit_fallback_line(line)


@always_inline
def _emit_through[
    level: UInt8,
    fmt: StringLiteral,
    module: StringLiteral,
    *ArgTs: LogArg,
](mut e: SharedEngine, *args: *ArgTs):
    # (1) COMPTIME FLOOR — a below-floor site compiles to nothing.
    comptime if level < MIN_COMPILED_LEVEL:
        return

    if not e.enabled():
        return
    # (2)+(3) THE LEVEL GATE — ONE decision, identical to the facade's. This
    # was two sequential comparisons whose first one RETURNED, making a
    # per-module rule able to raise a module's threshold and never lower it.
    # See `SharedEngine.admits`.
    if not e.admits(level, module):
        return

    # comptime ids — literals at the call site, ZERO runtime hash.
    comptime site_id = fnv1a_32(fmt)
    comptime module_id = fnv1a_32(module)
    # Raw-counter timestamp. NO tick→ns divide on the hot path;
    # the drain converts via the calibration anchor.
    var ts = read_raw_ticks()

    comptime n = args.__len__()
    var wid = e.current_worker_id()

    # WHICH cold sink the single render block at the bottom writes to, if it is
    # reached at all. Mirrors `facade._emit`.
    var sink = _SINK_FALLBACK

    if wid != WORKER_ID_UNSET:
        # Worker-thread path: encode the args DIRECTLY into the POD record's
        # inline `arg_blob` (NanoLog no-alloc rule) — ZERO heap alloc on the
        # common ≤48-byte path. Wire format byte-identical to the ambient
        # facade encode.
        #
        # Register the site for decode (idempotent). ⚠ INSIDE THIS ARM
        # DELIBERATELY, not above the `wid` read: the non-worker arm below
        # renders on the caller and never reaches a drain, so registering there
        # would append to the shared SiteDictionary from an arbitrary thread for
        # an entry nothing would ever read. Only a record that will be DECODED
        # needs a dictionary entry. ⛔ This does NOT make the dictionary
        # thread-safe; two bound workers still race.
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
            rec.arg_inline_len = UInt16(w.inline_len())
        else:
            var handle = ring.arena_append(w.full_blob())
            rec.flags = rec.flags | FLAG_HAS_ARG_OVERFLOW
            rec.arg_off = handle[0]
            rec.arg_len = handle[1]

        if ring.try_push(rec):
            return

        # ⛔⛔ THE PUSH RESULT IS CHECKED — NEVER `_ = ring.try_push(rec)`.
        #
        # The ambient facade, for the same record at the same level on the same
        # DROP ring, checks it and escalates. Discarding it here would give ONE
        # contract TWO behaviours depending on which handle the caller happens
        # to hold: an ERROR emitted through `ctx.logger` would be silently
        # dropped where the identical call through `log.error` survives. The
        # never-drop guarantee is not a property of the facade; it is a property
        # of the LEVEL, so it belongs on every surface that can emit at that
        # level.
        #
        # WARN/ERROR-never-dropped ("drop TRACE/DEBUG/INFO; never drop
        # WARN/ERROR"). Comptime-gated, so a
        # below-WARN site compiles this to an unconditional `return` and pays
        # nothing — a DEBUG site is byte-for-byte what it was.
        comptime if level >= LEVEL_WARN:
            sink = _SINK_ESCALATE
        else:
            return

    # --- THE SINGLE COLD RENDER BLOCK. Reached by the two arms that need a
    # rendered line: the non-worker fallback and the dropped-WARN/ERROR
    # escalation. Every gate above returns before it, and an admitted ring push
    # returns before it too, so a suppressed log never reaches it.
    var positionals = List[String]()
    var fields = List[String]()

    comptime for i in range(n):
        var rendered = args[i].render()
        if args[i].arg_tag() == ARG_FIELD:
            fields.append(rendered^)
        else:
            positionals.append(rendered^)

    _write_rendered_through(
        e, sink, level, module, String(fmt), positionals^, fields^
    )


# =============================================================================
# `_emit_line` — THE COLD EMIT, for a caller that is not measured in nanoseconds.
# =============================================================================
#
# WHY A SECOND ENTRY POINT EXISTS AT ALL. A log call site is not free to
# COMPILE. Through the typed surface above, every site costs front-end memory
# and emitted IR, linear in the number of sites.
#
# ⚠⚠ AND THE `@always_inline` IS NOT THE REASON. An outlined copy of this same
# typed surface (`_emit_through` called from a NOT-inlined parametric wrapper)
# removes only a few percent. The copies are not made by the inline directive.
# They are made by the per-site comptime KEY: `_emit_through[level, fmt, module,
# *ArgTs]` is monomorphised on `fmt` and the argument-type tuple, and every log
# site in real code has its own format string. Outlining RELOCATES N copies out
# of the caller into N named functions; it does not make them fewer. In
# unoptimized IR the inlined form emits ZERO callable emit bodies and the
# outlined form emits exactly N of them, at the same total volume.
#
#   ⇒ THE LEVER IS DROPPING THE PER-SITE COMPTIME KEY, NOT THE INLINE.
#
# `_emit_line` takes the message as a RUNTIME `String`, so it is keyed on
# `(level, module)` only — constants of a FILE, not of a site. Many sites
# through it emit a handful of bodies, and the marginal cost per site is small
# and flat.
#
#   log.info[fmt, module](*args)    HOT   inlined, structured record, ring push,
#                                         compile cost PER SITE
#   log.info_text[module](message)  COLD  rendered + written synchronously,
#                                         O(1) in the number of sites
#
# ⛔ DO NOT "SIMPLIFY" THIS BY DELETING `@always_inline` FROM `_emit_through`.
# It buys a few percent of a cost this entry point removes almost entirely, and
# it is a data-plane change wearing a compile-time justification. The runtime
# cost of outlining is small but not zero (a fraction of a nanosecond per emit
# on a gated site), and LLVM re-inlines the outlined body at -O, so outlining
# changes what the FRONT END elaborates and nearly nothing about what runs.
# -----------------------------------------------------------------------------


def _emit_line[
    level: UInt8, module: StringLiteral
](mut e: SharedEngine, message: String):
    """The emit for a message that is ALREADY A STRING — the `print(` shape.

    Neither inlined NOR keyed on a per-site `fmt`/arg tuple, so every call site
    in a module that logs at one level shares ONE elaborated body: the cost is
    O(1) in the number of sites, not O(N).

    It renders and writes SYNCHRONOUSLY (`emit_fallback_line`) rather than
    encoding into a per-worker ring. That is not a downgrade for its intended
    caller — a process that never calls `bind_worker_thread` has `wid ==
    WORKER_ID_UNSET`, so `_emit_through` takes this same synchronous arm anyway
    (see its non-worker branch above). It is the WRONG path for a worker thread,
    which should keep the typed surface and its ring.

    The comptime floor and both runtime gates are identical to the hot path, so
    a below-floor site still compiles to nothing.
    """
    # (1) COMPTIME FLOOR — a below-floor site compiles to nothing.
    comptime if level < MIN_COMPILED_LEVEL:
        return

    if not e.enabled():
        return
    # (2)+(3) THE LEVEL GATE — one decision, same as the hot path.
    if not e.admits(level, module):
        return

    e.emit_fallback_line(
        render_line(now_unix_ms(), level, module, message, List[String]())
    )


# -----------------------------------------------------------------------------
# Logger[origin] — the typed, concrete-origin logger handle.
#
# A thin Movable POD holding `Pointer[SharedEngine, origin]` — the SAME shape as
# `TracerHandle[origin]`. Construct via `Logger.borrow(ctx.log_engine_mut())`;
# the typical reach is the `ctx.logger()` / `service.logger()` accessor, which
# returns `Logger[origin-of-the-engine-field]`. Because the borrow's origin is
# concrete, the `_eng[]` deref inside each level method is tracked → the
# `_emit_through` body inlines → the wildcard-dispatch penalty is gone.
# -----------------------------------------------------------------------------


struct Logger[origin: MutOrigin](Movable, Deinitable):
    """The typed, concrete-origin log handle.

    `let log = ctx.logger` aliases the SAME typed borrow; `log.info[fmt](args)`
    reaches the engine through the concrete `_eng` origin so the emit dispatch
    inlines instead of paying the ambient holder resolve. Same comptime floor + runtime gates as the module facade; only the
    engine reach differs.
    """

    # CONCRETE-origin borrow of the forever-root's engine field. NOT a wildcard,
    # NOT `unsafe_from_address=Int` — a `Pointer(to=referent)` of a live ref.
    var _eng: Pointer[SharedEngine, Self.origin]

    @staticmethod
    @always_inline
    def borrow(ref [Self.origin] engine: SharedEngine) -> Logger[Self.origin]:
        """Construct a typed logger borrowing `engine` through its concrete
        origin. The accessor (`ctx.logger()` / `service.logger()`) is the
        idiomatic reach; this is the primitive both wrap."""
        return Logger[Self.origin](Pointer(to=engine))

    @always_inline
    def __init__(out self, var eng: Pointer[SharedEngine, Self.origin]):
        self._eng = eng

    # -------------------------------------------------------------------------
    # The five typed level methods. Each forwards to `_emit_through` with the
    # concrete-origin engine ref (`self._eng[]`), so the gate/encode/push
    # sequence inlines. `module` defaults to "komira" so a tagless call works
    # (matching the module facade's default).
    # -------------------------------------------------------------------------

    @always_inline
    def trace[
        fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
    ](self, *args: *ArgTs):
        _emit_through[LEVEL_TRACE, fmt, module](self._eng[], *args)

    @always_inline
    def debug[
        fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
    ](self, *args: *ArgTs):
        _emit_through[LEVEL_DEBUG, fmt, module](self._eng[], *args)

    @always_inline
    def info[
        fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
    ](self, *args: *ArgTs):
        _emit_through[LEVEL_INFO, fmt, module](self._eng[], *args)

    @always_inline
    def warn[
        fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
    ](self, *args: *ArgTs):
        _emit_through[LEVEL_WARN, fmt, module](self._eng[], *args)

    @always_inline
    def error[
        fmt: StringLiteral, module: StringLiteral = "komira", *ArgTs: LogArg
    ](self, *args: *ArgTs):
        _emit_through[LEVEL_ERROR, fmt, module](self._eng[], *args)

    # -------------------------------------------------------------------------
    # THE COLD SURFACE — `*_text`, the direct replacement for a `print(...)`.
    #
    # Same handle, same engine, same sink, same gates, same rendered layout. The
    # message is a runtime `String` the caller already built, so there is no
    # per-site comptime key: N sites in a file cost what one site costs.
    #
    # The rule a reviewer can apply from the method name alone: **if the caller
    # is measured in nanoseconds it uses the bare name; otherwise it uses
    # `_text`.** The bare name buys a structured record on a lock-free ring and
    # costs compile time per site; `_text` buys neither and costs neither.
    #
    # ⚠ THERE IS DELIBERATELY NO `*_cold` (outlined-but-still-typed) VARIANT.
    # It would save a few percent of the per-site cost and none of the runtime,
    # so there is no caller for whom it is the right answer — and in a shipped
    # API a reader would assume it helps.
    # -------------------------------------------------------------------------

    def trace_text[module: StringLiteral = "komira"](self, message: String):
        _emit_line[LEVEL_TRACE, module](self._eng[], message)

    def debug_text[module: StringLiteral = "komira"](self, message: String):
        _emit_line[LEVEL_DEBUG, module](self._eng[], message)

    def info_text[module: StringLiteral = "komira"](self, message: String):
        _emit_line[LEVEL_INFO, module](self._eng[], message)

    def warn_text[module: StringLiteral = "komira"](self, message: String):
        _emit_line[LEVEL_WARN, module](self._eng[], message)

    def error_text[module: StringLiteral = "komira"](self, message: String):
        _emit_line[LEVEL_ERROR, module](self._eng[], message)
