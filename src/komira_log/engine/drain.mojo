# =============================================================================
# komira_log.engine.drain — decode-at-flush: ring → text (P2a).
# =============================================================================
#
# The engine drain: read records from one per-core ring, decode each
#   1. `site_id → fmt` via the `SiteDictionary`,
#   2. `module_id → module` via the same dictionary,
#   3. walk the arg-blob (tag table + raw bytes) decoding each arg to text,
#   4. convert the raw-tick `timestamp` → wall-time MS via the calibration
#      anchor,
#   5. render via the P1 `pattern_layout` (REUSED — the same `render_line`
#      P1 ships, so the rendered line is byte-identical to the synchronous
#      P1 path).
#
# This is NanoLog's offline decoder, moved in-process + online: human-readable
# text by default, no offline tool, `tail -f` Just Works. The decode cost is on
# the (idle/budgeted) drain, never the caller.
#
# P2a sink: a `String` buffer (or the caller appends to stderr). The reactor
# async appender is P2b. The drain is a PURE function of (ring, dict, anchor)
# → decoded lines, which is exactly what the round-trip test asserts.
#
# Encapsulation: pure value/ref flow; no `UnsafePointer`, no wildcard
# origin. The arg-blob walk reads owned `List[UInt8]` (inline copy or arena
# slice). The dictionary + anchor are borrowed by ref.
# =============================================================================

from komira_log.levels import LEVEL_INFO, level_name
from komira_log.log_arg import (
    ARG_I64,
    ARG_F64,
    ARG_STR,
    ARG_BOOL,
    ARG_U64,
    ARG_FIELD,
)
from komira_log.pattern_layout import (
    render_line,
    render_json_line,
    interpolate,
    format_timestamp_ms,
    log_layout_is_json,
)
from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    REC_SPAN_OPEN,
    REC_SPAN_CLOSE,
    REC_METRIC,
    ARG_INLINE_BYTES,
)
from komira_log.engine.log_record_view import LogRecordView
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.engine.calibration import CalibrationAnchor

from std.memory import bitcast


# -----------------------------------------------------------------------------
# Raw little-endian reads (symmetric with log_arg `_put_u64` / encode_into).
# -----------------------------------------------------------------------------


def _get_u64(buf: List[UInt8], off: Int) -> UInt64:
    var v: UInt64 = 0
    for i in range(8):
        v |= UInt64(Int(buf[off + i])) << (UInt64(i) * 8)
    return v


def _bits_f64(u: UInt64) -> Float64:
    return bitcast[DType.float64, 1](SIMD[DType.uint64, 1](u))[0]

def _decode_str_run(blob: List[UInt8], off: Int, n: Int) -> String:
    """BYTE-EXACT decode of a length-prefixed arg run at `blob[off, off+n)`.

    ⛔ THE ONE THING THIS FUNCTION EXISTS TO PREVENT: `s += chr(Int(blob[j]))`.
    `chr` maps a CODE POINT to its UTF-8 ENCODING, so a stored byte >= 0x80 is
    not reproduced but RE-ENCODED into two — `é` (C3 A9) -> `Ã©` (C3 83 C2 A9).
    The producer side (`log_arg.StrArg.encode_into`) copies the caller's
    `String` bytes RAW, so a `chr` decode made this an ASYMMETRIC codec pair and
    every non-ASCII log message, field KEY and field VALUE came out of the drain
    mojibaked. ASCII is the corruption's fixed point, which is why an
    ASCII-only round-trip suite cannot see it.

    All SIX decode sites in this module (`_decode_args` x3, `_decode_args_kv`
    x3) route through here so a guard on one arm cannot be a half fix — the
    exact failure `_materialize_arg_blob`'s header comment records for the
    bounds guard.
    """
    var run = List[UInt8]()
    for j in range(n):
        run.append(blob[off + j])
    return String(StringSlice(unsafe_from_utf8=Span(run)))




# -----------------------------------------------------------------------------
# THE HEADER IS NOT TRUSTED. A LOGGER MAY NOT ABORT THE PROCESS IT INSTRUMENTS.
# -----------------------------------------------------------------------------
#
# A record's header is the only description of its own arg bytes, and the drain
# reads it back from a ring slot. Every producer in this package writes it
# consistently (`emit.mojo` clamps to `ARG_INLINE_BYTES` and only sets the
# overflow flag alongside an `arena_append`; `ArgBlobWriter.inline_len()` returns
# `min(_pos, 48)`), so an out-of-range header means the BYTES are wrong — a
# producer defect, a lifetime defect, or reuse under the record — and by then
# the drain is the last code that can decide what happens next.
#
# It must not decide "abort". If `arg_blob[i]` for `i < arg_inline_len`, and
# `_arena[o + i]` for `i < arg_len`, and a tag table sized by `n_args`, were
# indexed with no bound of their own, a bad header would take an out-of-bounds
# `List.__getitem__` and kill the host. `komira_log` is linked into every
# service; the sink for a corrupt record must be a truncated line.
#
# So: `_materialize_arg_blob` clamps the blob to what the record and the ring
# ACTUALLY hold, and both arg walks below stop at the end of the blob instead of
# reading past it. A record that has lost its bytes renders short. It does not
# take the process with it.
#
# ONE function, used by BOTH decoders, deliberately: `decode_one` and
# `decode_one_to_view` need byte-identical materialize logic, and two copies is
# how a guard on one and not the other becomes a half fix.
#
# COST. The guard adds one `Int` compare per record on the inline path (which
# is nearly every record — a spill needs a >48-byte encoded arg set) plus one
# per decoded arg. The full text drain is a few microseconds per record,
# dominated by `String` construction in `interpolate` and the render, so the
# guard is within run-to-run noise. If you measure it, interleave the guarded
# and unguarded arms in ONE process: a between-process comparison reads load
# drift on a shared machine as a guard cost.
# -----------------------------------------------------------------------------


@always_inline
def _materialize_arg_blob(
    rec: LogEventRecord, ref ring: LogRecordRing
) -> List[UInt8]:
    """Copy a record's arg bytes into an OWNED list, CLAMPED to what actually
    exists. Never reads past `arg_blob`'s 48 bytes or past the ring arena."""
    var blob = List[UInt8]()
    if rec.has_arg_overflow():
        # `arena_slice` carries the arena-side clamp (it owns `_arena`'s length).
        blob = ring.arena_slice(rec.arg_off, rec.arg_len)
    else:
        var inl = Int(rec.arg_inline_len)
        if inl > ARG_INLINE_BYTES:
            inl = ARG_INLINE_BYTES
        for i in range(inl):
            blob.append(rec.arg_blob[i])
    return blob^


# -----------------------------------------------------------------------------
# Decode the arg-blob into two parallel lists:
#   positionals — rendered values for the `{}` placeholders, in order
#   fields      — rendered "key=value" strings for trailing `Field` args
# (the same split the P1 facade produces from its `@parameter for`).
# -----------------------------------------------------------------------------


def _decode_args(
    blob: List[UInt8], n_args: Int
) -> Tuple[List[String], List[String]]:
    var positionals = List[String]()
    var fields = List[String]()

    # `n_args` and the blob length are INDEPENDENT header fields; a record whose
    # bytes are wrong can claim more tags than it carries. Stop at the blob.
    var avail = len(blob)

    # Tag table: one byte per arg.
    var tags = List[UInt8]()
    var off = 0
    for _ in range(n_args):
        if off >= avail:
            break
        tags.append(blob[off])
        off += 1

    for i in range(len(tags)):
        var tag = tags[i]
        if tag == ARG_I64:
            if off + 8 > avail:
                break
            var u = _get_u64(blob, off)
            off += 8
            positionals.append(String(Int64(Int(u))))
        elif tag == ARG_U64:
            if off + 8 > avail:
                break
            var u = _get_u64(blob, off)
            off += 8
            positionals.append(String(u))
        elif tag == ARG_F64:
            if off + 8 > avail:
                break
            var u = _get_u64(blob, off)
            off += 8
            positionals.append(String(_bits_f64(u)))
        elif tag == ARG_BOOL:
            if off + 1 > avail:
                break
            var b = blob[off]
            off += 1
            positionals.append(
                String("true") if b != 0 else String("false")
            )
        elif tag == ARG_STR:
            if off + 2 > avail:
                break
            var slen = Int(blob[off]) | (Int(blob[off + 1]) << 8)
            off += 2
            if slen > avail - off:
                slen = avail - off
            var s = _decode_str_run(blob, off, slen)
            off += slen
            positionals.append(s)
        elif tag == ARG_FIELD:
            # key (u16-len + bytes) then value (u16-len + bytes).
            if off + 2 > avail:
                break
            var klen = Int(blob[off]) | (Int(blob[off + 1]) << 8)
            off += 2
            if klen > avail - off:
                klen = avail - off
            var key = _decode_str_run(blob, off, klen)
            off += klen
            if off + 2 > avail:
                break
            var vlen = Int(blob[off]) | (Int(blob[off + 1]) << 8)
            off += 2
            if vlen > avail - off:
                vlen = avail - off
            var val = _decode_str_run(blob, off, vlen)
            off += vlen
            fields.append(key + "=" + val)
        else:
            positionals.append(String("?"))

    return Tuple[List[String], List[String]](positionals^, fields^)


# -----------------------------------------------------------------------------
# _decode_args_kv — like _decode_args, but returns the trailing `Field` args as
# PARALLEL (key, value) lists (not pre-joined "key=value"). The native-indexing
# seam (decode_one_to_view) wants the raw key/value pairs so the search-side
# consumer can emit fixed-known-key COLUMNS. Positionals are returned identically
# (for `{}` interpolation). Byte-identical arg-walk to _decode_args — the only
# difference is the Field arm appends to two lists instead of `key + "=" + val`.
# -----------------------------------------------------------------------------


def _decode_args_kv(
    blob: List[UInt8], n_args: Int
) -> Tuple[List[String], List[String], List[String]]:
    var positionals = List[String]()
    var keys = List[String]()
    var vals = List[String]()

    # See `_decode_args` — same bound, same reason.
    var avail = len(blob)

    var tags = List[UInt8]()
    var off = 0
    for _ in range(n_args):
        if off >= avail:
            break
        tags.append(blob[off])
        off += 1

    for i in range(len(tags)):
        var tag = tags[i]
        if tag == ARG_I64:
            if off + 8 > avail:
                break
            var u = _get_u64(blob, off)
            off += 8
            positionals.append(String(Int64(Int(u))))
        elif tag == ARG_U64:
            if off + 8 > avail:
                break
            var u = _get_u64(blob, off)
            off += 8
            positionals.append(String(u))
        elif tag == ARG_F64:
            if off + 8 > avail:
                break
            var u = _get_u64(blob, off)
            off += 8
            positionals.append(String(_bits_f64(u)))
        elif tag == ARG_BOOL:
            if off + 1 > avail:
                break
            var b = blob[off]
            off += 1
            positionals.append(
                String("true") if b != 0 else String("false")
            )
        elif tag == ARG_STR:
            if off + 2 > avail:
                break
            var slen = Int(blob[off]) | (Int(blob[off + 1]) << 8)
            off += 2
            if slen > avail - off:
                slen = avail - off
            var s = _decode_str_run(blob, off, slen)
            off += slen
            positionals.append(s)
        elif tag == ARG_FIELD:
            if off + 2 > avail:
                break
            var klen = Int(blob[off]) | (Int(blob[off + 1]) << 8)
            off += 2
            if klen > avail - off:
                klen = avail - off
            var key = _decode_str_run(blob, off, klen)
            off += klen
            if off + 2 > avail:
                break
            var vlen = Int(blob[off]) | (Int(blob[off + 1]) << 8)
            off += 2
            if vlen > avail - off:
                vlen = avail - off
            var val = _decode_str_run(blob, off, vlen)
            off += vlen
            keys.append(key)
            vals.append(val)
        else:
            positionals.append(String("?"))

    return Tuple[List[String], List[String], List[String]](
        positionals^, keys^, vals^
    )


# -----------------------------------------------------------------------------
# decode_one_to_view — one LOG record → an OWNED `LogRecordView` (the POD
# seam). Mirrors `decode_one`'s arena-materialize + arg-decode +
# fmt/module-lookup + interpolate, but returns the structured POD-owned VIEW (the
# scalars + the interpolated message + the resolved module + the decoded arg
# key/value pairs) instead of the rendered text line.
#
# The arena-copy guard: the arg-blob is materialized into an OWNED
# `List[UInt8]` (inline copy or `arena_slice` COPY) BEFORE decode; every String
# the view carries is built fresh (owned). So the view holds ZERO reference into
# the ring arena — it is safe across `reset_arena`. NO `UnsafePointer` crosses the
# seam. `message` is byte-identical to `decode_one`'s `interpolate(fmt, positionals)`
# (the unit test asserts this round-trip), so the inverted TEXT the consumer
# indexes matches the human-rendered line's message exactly.
# -----------------------------------------------------------------------------


def decode_one_to_view(
    rec: LogEventRecord,
    ref ring: LogRecordRing,
    dict: SiteDictionary,
    anchor: CalibrationAnchor,
) -> LogRecordView:
    # Materialize the arg-blob — owned bytes, CLAMPED to what exists.
    var blob = _materialize_arg_blob(rec, ring)

    var decoded = _decode_args_kv(blob, Int(rec.n_args))
    var positionals = decoded[0].copy()
    var keys = decoded[1].copy()
    var vals = decoded[2].copy()

    var fmt_opt = dict.lookup_fmt(rec.site_id)
    var message: String
    if not fmt_opt:
        # Match decode_one's graceful fallback so the indexed message never
        # carries garbage for an unregistered site.
        message = (
            String("<unknown site ") + String(Int(rec.site_id)) + String(">")
        )
    else:
        message = interpolate(fmt_opt.value(), positionals)

    var module_opt = dict.lookup_module(rec.module_id)
    var module = (
        module_opt.value() if module_opt else String("<unknown-module>")
    )

    var wall_ms = anchor.tick_to_wall_ms(rec.timestamp)

    return LogRecordView(
        rec.level,
        rec.flags,
        rec.site_id,
        rec.module_id,
        rec.timestamp,
        rec.corr_id,
        wall_ms,
        message^,
        module^,
        keys^,
        vals^,
    )


# -----------------------------------------------------------------------------
# decode_one — one record → its rendered line (or a graceful `<unknown ...>`).
# Reads the arg-blob inline or from the ring arena per the overflow flag.
# -----------------------------------------------------------------------------


def decode_one(
    rec: LogEventRecord,
    ref ring: LogRecordRing,
    dict: SiteDictionary,
    anchor: CalibrationAnchor,
) -> String:
    # Materialize the arg-blob — owned bytes, CLAMPED to what exists.
    var blob = _materialize_arg_blob(rec, ring)

    var decoded = _decode_args(blob, Int(rec.n_args))
    var positionals = decoded[0].copy()
    var fields = decoded[1].copy()

    var fmt_opt = dict.lookup_fmt(rec.site_id)
    if not fmt_opt:
        return (
            String("<unknown site ")
            + String(Int(rec.site_id))
            + String(">")
        )
    var fmt = fmt_opt.value()

    var module_opt = dict.lookup_module(rec.module_id)
    var module = (
        module_opt.value() if module_opt else String("<unknown-module>")
    )

    var message = interpolate(fmt, positionals)
    var wall_ms = anchor.tick_to_wall_ms(rec.timestamp)

    # Reuse the P1 layout. `render_line` takes a `StaticString` module; the
    # decoded module is a runtime `String`, so we build the line directly with
    # the same shape `render_line` produces (ts LEVEL [module] message fields).
    return _render_runtime_module(
        wall_ms, rec.level, module, message, fields
    )


# render_line's module param is StaticString (P1 has comptime modules); the
# drain has a runtime String module from the dictionary, so we mirror the same
# layout here. Kept byte-identical to pattern_layout.render_line.
#
# ⛔ THE JSON ARM IS A CALL, NOT A SECOND BODY. This file's own rule for the
# text layout — "IT RE-STATES NO LAYOUT ... so a mirrored line and a
# sink-drained line cannot drift" — is what forced `render_json_line` to take a
# runtime `String` module and live in `pattern_layout`: `render_line` converts
# its `StaticString` and calls the same function this does. Both layouts gained
# the JSON arm together, because one of them gaining it alone is precisely the
# drift that rule forbids.
#
# ⚠ THE SELECTOR IS READ HERE AND NOT PASSED IN. `render_record_view` keeps its
# stated property (it delegates to this body, so a mirrored line is still the
# line `decode_one` would have produced) exactly BECAUSE the layout decision is
# made in one place that both reach, rather than threaded as a parameter two
# call sites could disagree about.
def _render_runtime_module(
    epoch_ms: Int64,
    level: UInt8,
    module: String,
    message: String,
    fields: List[String],
) -> String:
    if log_layout_is_json():
        return render_json_line(epoch_ms, level, module, message, fields)
    var out = format_timestamp_ms(epoch_ms)
    out += " "
    out += String(level_name(level))
    out += " ["
    out += module
    out += "] "
    out += message
    for i in range(len(fields)):
        out += " "
        out += fields[i]
    return out


# -----------------------------------------------------------------------------
# render_record_view — an ALREADY-DRAINED `LogRecordView` back to the SAME text
# line the sink path would have written for that record.
#
# ⭐ WHY THIS EXISTS, AND IT IS NOT A CONVENIENCE. There are TWO drains off one
# ring and they are mutually exclusive, because each one POPS: `drain_worker`
# renders every record and writes it to the engine's `LogSink` (stderr by
# default), and `drain_worker_to_records` returns owned `LogRecordView`s for the
# object-store index consumer. A service that takes the SECOND therefore stops
# getting the FIRST — its lines leave stderr, which on a managed platform means
# they leave the platform's log collector. `komira_log_index.ServiceLogSink` is
# exactly that consumer, and this function is what lets it hand the records it drained BACK to
# the engine's own sink (`emit_fallback_line`) so both outputs are fed from one
# pop.
#
# ⛔ IT RE-STATES NO LAYOUT. It delegates to `_render_runtime_module` — the SAME
# body `decode_one_to_line` uses — so a mirrored line and a sink-drained line
# cannot drift. If the layout changes, both change together or neither compiles.
#
# ⚠ THE ONE THING IT CANNOT REPRODUCE is a field that was DROPPED at decode: the
# view carries the args the decoder recovered, so a record truncated by the
# arg-blob clamp renders here exactly as `decode_one` would have rendered it —
# which is the property that matters, not byte-equality with the original call.
# -----------------------------------------------------------------------------


def render_record_view(view: LogRecordView) -> String:
    """Render a drained `LogRecordView` as the text line the engine sink writes.

    The trailing `Field` args are re-joined `key + "=" + value` — the SAME join
    `_decode_args` performs for the sink path, which `_decode_args_kv` split into
    the view's parallel `arg_keys` / `arg_vals` (that file's own note: "the only
    difference is the Field arm appends to two lists instead of `key + \"=\" +
    val`"). So a mirrored line is byte-identical to the line `decode_one` would
    have produced from the same record."""
    var fields = List[String]()
    var n = len(view.arg_keys)
    if len(view.arg_vals) < n:
        n = len(view.arg_vals)
    for i in range(n):
        var f = view.arg_keys[i].copy()
        f += "="
        f += view.arg_vals[i]
        fields.append(f^)
    return _render_runtime_module(
        view.wall_ms, view.level, view.module, view.message, fields
    )


# -----------------------------------------------------------------------------
# drain_to_lines — drain a ring fully, returning the decoded lines in order.
# This is the P2a deliverable: the decode-at-flush pass over one per-core ring.
# After consuming, resets the arena (the ring is now empty).
# -----------------------------------------------------------------------------


def drain_to_lines(
    mut ring: LogRecordRing,
    dict: SiteDictionary,
    anchor: CalibrationAnchor,
) -> List[String]:
    var lines = List[String]()
    while True:
        var rec_opt = ring.try_pop()
        if not rec_opt:
            break
        var rec = rec_opt.value().copy()
        # ROUTE BY KIND. A drain that made NO kind decision would decode every
        # record reaching it — REC_SPAN_OPEN and REC_SPAN_CLOSE included, both
        # LIVE kinds a producer emits — as a text log line.
        if rec.kind == REC_SPAN_OPEN or rec.kind == REC_SPAN_CLOSE:
            # Skipped, not decoded: the bare free fn has no `OpenSpanTable` to
            # ingest into, the same reason `drain_to_views` skips them. The
            # span-aware twin is `drain_unified` (span_drain.mojo).
            #
            # COUNTED, not silent. The skip is the right behaviour (there is
            # no table to pair into and no channel to hand a span back through:
            # this fn returns `List[String]` and its caller asked for log text),
            # but an invisible skip would make a process whose spans all landed
            # on this drain look exactly like a process that emitted no spans. A signature change is what it
            # would take to actually KEEP them here; the counter is what it
            # takes to know that you need one.
            ring.note_span_record_dropped()
            continue
        if rec.kind == REC_METRIC:
            # SKIPPED AND COUNTED, the same treatment this fn gives a span
            # and for the same reason: it returns `List[String]` of log TEXT,
            # and a metric point is not log text. It is POD and must reach an
            # exporter as POD — rendering it here would be a dead end. Keeping it would take a signature change on a
            # free fn that has no engine and no channel; the counter is what it
            # takes to KNOW you need one.
            ring.note_metric_record_dropped()
            continue
        if rec.kind != REC_LOG:
            # THE CLOSED DEFAULT. An unrecognised kind is counted and refused.
            ring.note_unknown_kind()
            continue
        lines.append(decode_one(rec, ring, dict, anchor))
    # Ring is empty — spilled arg bytes have all been consumed.
    ring.reset_arena()
    return lines^


# -----------------------------------------------------------------------------
# drain_to_views — the free-fn twin of drain_to_lines. Drains a
# ring fully into OWNED `LogRecordView`s (the POD seam value). Only LOG records
# become views (SPAN records are skipped on this log-only inspect path — the
# engine's `drain_worker_to_records` routes spans to the OTLP table; the bare
# free fn has no span table so it just skips them). After consuming, resets the
# arena. Used by cost benches + the transpose unit test.
# -----------------------------------------------------------------------------


def drain_to_views(
    mut ring: LogRecordRing,
    dict: SiteDictionary,
    anchor: CalibrationAnchor,
) -> List[LogRecordView]:
    var views = List[LogRecordView]()
    while True:
        var rec_opt = ring.try_pop()
        if not rec_opt:
            break
        var rec = rec_opt.value().copy()
        # Skip SPAN records (the free-fn path has no open-span table).
        # Counted, for the reason spelled out in `drain_to_lines` above.
        # This is the free fn a deployed service reaches, so it is the one
        # whose silent skip would hide the loss best.
        if rec.kind == REC_SPAN_OPEN or rec.kind == REC_SPAN_CLOSE:
            ring.note_span_record_dropped()
            continue
        if rec.kind == REC_METRIC:
            # Skipped and counted. THIS IS THE FREE FN A DEPLOYED SERVICE
            # REACHES (e.g. through `komira_log_index`), so it is the arm on
            # which a silent metric loss would actually ship. A metric point is
            # not a `LogRecordView` and must not become one — metrics get their
            # own store, exactly as spans get their own index.
            ring.note_metric_record_dropped()
            continue
        if rec.kind != REC_LOG:
            # THE CLOSED DEFAULT. A silent `if rec.kind != REC_LOG: continue`
            # would make a deliberate span skip and an unrecognised kind
            # indistinguishable. Splitting them keeps the skip and COUNTS the
            # refusal.
            ring.note_unknown_kind()
            continue
        views.append(decode_one_to_view(rec, ring, dict, anchor))
    ring.reset_arena()
    return views^
