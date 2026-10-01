# =============================================================================
# komira_log.logger_erased — the ERASED emit entry point, BESIDE the
# specialised one. For the CONTROL PLANE. The engine keeps `_emit_through`.
# =============================================================================
#
# # WHAT IS ERASED, AND WHAT IS DELIBERATELY NOT
#
# `_emit_through` (logger.mojo) takes FOUR comptime parameters:
#
#     def _emit_through[level: UInt8, fmt: StringLiteral,
#                       module: StringLiteral, *ArgTs: LogArg](...)
#
# Two of them — `fmt` and the `*ArgTs` pack — are UNIQUE TO EVERY CALL SITE, so
# every site is its own instantiation of the whole body; and the body is
# `@always_inline`, so every site is also its own expansion. Both halves —
# monomorphisation and inline expansion — cost compiler memory per distinct log
# call site, in roughly equal parts.
#
# This entry point moves EXACTLY those two to runtime:
#
#     def emit_erased[level: UInt8, module: StringLiteral](
#         mut e: SharedEngine, fmt: StaticString, *args: LogValue)
#
#   * `fmt` becomes a `StaticString` — a runtime VALUE (pointer + length), not
#     a parameter. A string literal at the call site converts implicitly, so the
#     call site reads the same; it just stops being part of the type.
#   * the `*ArgTs: LogArg` TYPE PACK becomes `*args: LogValue`, a HOMOGENEOUS
#     variadic of one concrete type. That is a runtime list, not a comptime
#     pack, so arity and arg types leave the monomorphisation key too.
#
# ⚠ `level` AND `module` STAY COMPTIME, ON PURPOSE. `level` drives the FIRST
# statement of the body — `comptime if level < MIN_COMPILED_LEVEL: return` —
# which compiles a below-floor site's body to nothing; that is the release-cut
# lever (levels.mojo) and it is worth more than it costs. `module` keys the
# per-module `EnvFilter` gate and lets `module_id` stay a comptime digest with
# zero runtime hash. Neither is unique per site: they take a handful of values
# across a whole program, so they cost a handful of instantiations, not one per
# site. Erasing them would buy nothing measurable and lose the floor.
#
# # THE COST THIS MOVES, AND THE COST IT ADDS
#
# It is a TRADE, not a free win, and the trade is why this is a SECOND entry
# point rather than a replacement:
#
#   moved to runtime   the tag table (a branch per arg instead of a straight-line
#                      `comptime for` unroll), the `fmt` digest (an FNV-1a over
#                      ~20-60 bytes instead of a compile-time constant), and the
#                      arg count.
#   kept               the wire format, byte for byte. A record emitted here
#                      decodes on the same drain, through the same
#                      SiteDictionary, with no second decoder.
#
# ⛔⛔ AND THE COMPILE-TIME WIN IS NOT WHAT IT LOOKS LIKE.
#
#   * THE ERASURE ITSELF WORKS AND IS VISIBLE IN THE IR — many call sites
#     collapse to one elaborated body per level (`fmt` and the arg types are
#     not in the mangled name at all) and far less LLVM IR is emitted.
#   * BUT THE COMPILER'S PEAK RSS CAN GO UP, NOT DOWN, as the site count grows.
#     Emitted-IR mass and compiler peak have different owners here, and only
#     the second one is the constraint. At small site counts the erased path is
#     slightly cheaper; at larger ones it is dearer.
#   * `module` STAYS COMPTIME, so the instantiation count is (levels x DISTINCT
#     MODULE STRINGS). One module string per FILE — which every logging
#     convention encourages — puts the bodies back and can land WORSE than the
#     specialised path. If this path is ever adopted, module strings must be a
#     small closed set; per-file provenance belongs in the fmt or a `Field`.
#
# ⇒ DO NOT MASS-CONVERT CALL SITES TO THIS PATH ON A COMPILE-PEAK ARGUMENT. The
#   runtime cost is fine (tens of nanoseconds per emit more); it is the COMPILE
#   peak that has to be measured. One open question could change the answer:
#   whether the superlinearity is in sites-per-FUNCTION rather than
#   sites-per-BINARY.
#
# ⛔ THE ENGINE MUST NOT USE THIS. The data plane is measured in nanoseconds and
# the engine depends on the inlined specialised emit. This exists for
# control-plane services, where sites are
# counted in thousands and lines in hundreds, and where the compiler peak is the
# binding constraint rather than the per-line cost.
#
# # Encapsulation
#
# Identical to `_emit_through`: a concrete `mut ref SharedEngine`, no
# `UnsafePointer` in the signature, no wildcard origin. `LogValue` owns Strings
# but is consumed in-method and never slab-stored (see log_value.mojo).
# =============================================================================

from komira_log.levels import MIN_COMPILED_LEVEL, LEVEL_WARN
from komira_log.log_value import LogValue
from komira_log.log_arg import ARG_FIELD
from komira_log.pattern_layout import interpolate, render_line
from komira_obs.clock import now_unix_ms

from komira_log.engine.shared_engine import SharedEngine
from komira_log.engine.log_event_record import (
    LogEventRecord,
    ArgBlobWriter,
    REC_LOG,
    FLAG_HAS_ARG_OVERFLOW,
)
from komira_log.engine.site_dictionary import (
    fnv1a_32,
    FNV1A_32_OFFSET_BASIS,
    FNV1A_32_PRIME,
)
from komira_log.engine.calibration import read_raw_ticks
from komira_log.engine.worker_id_tls import WORKER_ID_UNSET


# -----------------------------------------------------------------------------
# The RUNTIME twin of `site_dictionary.fnv1a_32`. Same basis, same prime, same
# byte order — so a site registered through the erased path collides with the
# specialised path's comptime digest for the same `fmt` by construction, and one
# dictionary serves both. `test_log_erased_emit.mojo` asserts that equality on a
# corpus of literals rather than trusting this comment.
# -----------------------------------------------------------------------------


@always_inline
def fnv1a_32_dyn(s: StaticString) -> UInt32:
    """FNV-1a 32-bit digest computed at RUNTIME over a `StaticString`.

    ~1 ns per 3-4 bytes; a 40-byte fmt costs ~12 ns. That is the price of `fmt`
    leaving the type, and it is paid only on an ADMITTED emit — the three gates
    above it return first for a suppressed one.
    """
    var h = FNV1A_32_OFFSET_BASIS
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        h = (h ^ UInt32(b[i])) * FNV1A_32_PRIME
    return h


# -----------------------------------------------------------------------------
# emit_erased — ONE elaborated body for the whole program.
#
# ⚠ NOT `@always_inline`, AND THAT IS THE POINT OF HALF OF IT. `_emit_through`
# is inlined so the engine's hot path has no call; here the call is what keeps
# the body from being expanded once per site. An ordinary call costs a handful
# of cycles against a line that will be formatted and written.
# -----------------------------------------------------------------------------


def emit_erased[
    level: UInt8,
    module: StringLiteral,
](mut e: SharedEngine, fmt: StaticString, *args: LogValue):
    """Emit one log record with `fmt` and the args carried as RUNTIME data.

    The gate sequence, the record layout and the arg-blob bytes are identical to
    `logger._emit_through`; only the binding time of `fmt` and the arg types
    differs.
    """
    # (1) COMPTIME FLOOR — a below-floor site compiles its body to nothing. The
    # one comptime property worth keeping, and the reason `level` is a parameter.
    comptime if level < MIN_COMPILED_LEVEL:
        return

    if not e.enabled():
        return
    # (2)+(3) THE LEVEL GATE — ONE decision, as `_emit_through`. Two
    # sequential vetoes here had the same defect: the global one RETURNED, so
    # a per-module rule could only RAISE. See `SharedEngine.admits`.
    if not e.admits(level, module):
        return

    # The digest is RUNTIME for `fmt` and COMPTIME for `module` — the asymmetry
    # is the whole design: `fmt` is per-site, `module` is not.
    var site_id = fnv1a_32_dyn(fmt)
    comptime module_id = fnv1a_32(module)

    var ts = read_raw_ticks()
    var n = len(args)
    var wid = e.current_worker_id()

    if wid == WORKER_ID_UNSET:
        # Non-worker thread (TLS unset): render synchronously + write directly,
        # so the record is never stranded on an undrained per-core ring. Byte-
        # identical to `_emit_through`'s fallback arm, with the `comptime for`
        # over the pack replaced by a runtime `for` over the variadic.
        #
        # ⚠ NOTE WHAT IS *NOT* HERE: `register_site_dynamic`. Run above the
        # `wid` read, it would make this arm — which renders on the caller and
        # never reaches a drain — mutate the shared SiteDictionary from an
        # arbitrary thread for an entry nothing would ever read.
        var positionals = List[String]()
        var fields = List[String]()

        for i in range(n):
            var rendered = args[i].render()
            if args[i].arg_tag() == ARG_FIELD:
                fields.append(rendered^)
            else:
                positionals.append(rendered^)

        var message = interpolate(String(fmt), positionals)
        var line = render_line(now_unix_ms(), level, module, message, fields)
        e.emit_fallback_line(line)
        return

    # Worker-thread path: encode straight into the record's inline `arg_blob`.
    #
    # Register for decode (idempotent; the scan runs before any `String` is
    # materialized, so a re-emit of a known site allocates nothing). ⛔ This
    # does NOT make the dictionary thread-safe — two bound workers still race.
    e.register_site_dynamic(site_id, fmt, module_id, module)

    var rec = LogEventRecord()
    rec.kind = REC_LOG
    rec.level = level
    rec.site_id = site_id
    rec.module_id = module_id
    rec.n_args = UInt8(n)
    rec.timestamp = ts

    var w = ArgBlobWriter(rec.arg_blob)

    for i in range(n):
        w.append(args[i].arg_tag())

    for i in range(n):
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

    # ⛔ THE PUSH RESULT IS CHECKED, for the same reason it is in `logger.mojo`
    # — this file ends `_ = ring.try_push(rec)` no longer. The erased surface
    # emits at the same levels as the typed one, so it carries the same
    # never-drop obligation: a dropped WARN/ERROR escalates to a synchronous,
    # flushed write. `level` is a comptime parameter here too,
    # so a below-WARN site compiles this to nothing.
    comptime if level >= LEVEL_WARN:
        var positionals = List[String]()
        var fields = List[String]()

        for i in range(n):
            var rendered = args[i].render()
            if args[i].arg_tag() == ARG_FIELD:
                fields.append(rendered^)
            else:
                positionals.append(rendered^)

        var message = interpolate(String(fmt), positionals)
        var line = render_line(now_unix_ms(), level, module, message, fields)
        e.escalate_line(line)
