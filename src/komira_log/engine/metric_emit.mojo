# =============================================================================
# komira_log.engine.metric_emit — the REC_METRIC record builder + decoder.
# =============================================================================
#
# THE MIRROR OF `span_emit.mojo`, for metrics. A metric point rides the EXACT
# SAME `LogEventRecord` + per-core `LogRecordRing` the log and span paths use;
# `kind == REC_METRIC` is the discriminant that tells a drain to decode a
# `MetricPoint` instead of rendering text. ONE ring, ONE drain, three outputs.
#
# The channel it feeds is the same per-worker return channel spans use
# (`SharedEngine._span_buf` / `take_span_lines`; for metrics `_metric_buf` /
# `take_metric_points`).
#
# ⛔ THIS FILE IS THE *ONLY* WRITER OF `REC_METRIC`, AND THAT IS LOAD-BEARING.
# Two of the fourteen record fields carry a value by CONVENTION rather than by
# derivation, and a convention with two writers is not a convention:
#   * `level = 0`. `level` is already documented as kind-dependent
#     (log_event_record.mojo, "span severity for spans"), so a metric having no
#     severity is a choice for a new kind, not a violated invariant. There is no
#     decoder assertion on it, because with the closed default no decoder ever
#     sees a record whose kind it does not claim.
#   * `n_args = 0`. BELT AND BRACES, and the reason is worth stating: if a
#     new ring consumer is ever written without a `REC_METRIC` arm and
#     without the closed default, `decode_one` walks `n_args` entries out of the
#     inline blob as an arg table. At 0 a mis-routed metric renders as an
#     arg-less line; at anything else it walks 48 bytes of metric payload as an
#     arg blob and writes the result into whatever that drain feeds — which can
#     be a production log index.
#
# ─── THE ON-RING ENCODING ────────────────────────────────────────────────────
#
#   kind            REC_METRIC (3)
#   level           0                          (convention, above)
#   flags           bit0    = FLAG_HAS_ARG_OVERFLOW   -- THE SAME BIT, THE SAME
#                                                        MEANING, shared with
#                                                        the log arena path
#                   bits1-2 = instrument kind (COUNTER/UPDOWN/GAUGE/HISTOGRAM)
#                   bits3-6 = the MetricPoint flag nibble (cumulative,
#                             monotonic, value_is_double, has_exemplar)
#   site_id         name_id       (already "comptime FNV-1a digest" -- NOT a pun)
#   n_args          0                          (convention, above)
#   module_id       scope_id      (already "FNV-1a digest of the module")
#   timestamp       RAW TICKS for the point's `time`. The drain converts via the
#                   calibration anchor, exactly as a log line's wall-ms is
#                   converted. This is why the blob carries a DELTA rather than
#                   a second absolute timestamp: only one of the two needs to be
#                   anchored, and anchoring both would let them disagree.
#   corr_id         exemplar_span_id  (already "span_id / log<->trace correlation")
#   arg_inline_len  METRIC_BLOB_BYTES (20)
#   arg_off/arg_len 0
#   arg_blob        value(8) || attrset_id(4) || start_ns_delta(8) = 20 bytes
#
# ─── THE HISTOGRAM IS A NAMED RESIDUAL, NOT AN OVERSIGHT ─────────────────────
#
# ⚠ THIS FILE ENCODES `MetricPoint` ONLY. There is a SECOND payload type and it
# has no ring encoding yet.
#
# An OTel default explicit-bucket histogram is 11 bounds => 12 buckets, and
# `HistogramPoint` (komira_obs/histogram.mojo) carries count + sum + min + max
# + those 12 buckets = 128 B of payload, plus this header's attrset_id(4) +
# start_ns_delta(8) = 140 B. `ARG_INLINE_BYTES` is 48. So a histogram record
# ALWAYS needs the `FLAG_HAS_ARG_OVERFLOW` arena path.
#
# ⛔ THE REFUSAL IS ABOUT TRANSPORT, NOT TYPE. `HistogramPoint` exists as a
# SIBLING of `MetricPoint`, so there IS a decoded form for buckets to land in;
# what does not exist is the arena transport: no encoder, no decoder, and no
# second buffer. A `REC_METRIC` carrying the overflow flag is REFUSED AND
# COUNTED at every drain that could produce a point
# (`metric_record_is_decodable` below is the single shared guard), never
# half-decoded into a point whose `value_bits` would be a bucket bound.
#
# WHAT THE HISTOGRAM HALF ACTUALLY NEEDS, so the next person does not re-derive
# it: `arena_append` of the 140 B payload behind (arg_off, arg_len) with bit0
# set; a `decode_histogram_point(rec, ring, anchor)` that reads it back; a
# `_hist_buf` / `take_histogram_points` pair beside `_metric_buf`; a fourth
# field on `UnifiedDrainResult`; and the SAME drain arms extended. The header
# fields (name_id, scope_id, attrset_id, kind, flags, the two timestamps) are
# byte-identical between the two point types by design, so the header codec
# here is reusable as-is.
#
# ⛔ AND ONE TRAP FOR THE `MetricPointSink` CONFORMER THAT FEEDS THIS RING
# (`metric_sink.mojo`). `MetricPointSink.try_accept` returns Bool where **False means
# BACKPRESSURE, never rejection** — `MetricSweep` does not advance its cursor on
# a False, so the point is re-offered next tick. `build_metric_record` returns
# `Optional` and its None is a REFUSAL (a malformed point that will never
# encode). Mapping that None to `False` LIVELOCKS the export: the sweep re-offers
# a point that can never be accepted, forever. A ring-full `try_push` failure is
# the only legitimate False. The two signals are different on purpose and must
# not be collapsed into one Bool at that boundary.
#
# Encapsulation: the builders take a POD `MetricPoint` by value and
# return a POD `LogEventRecord` by value. No `UnsafePointer` crosses any API, no
# wildcard origin, no heap-owning field — the payload lives inline in the
# record's fixed `arg_blob`.
# =============================================================================

from komira_obs.metric_point import MetricPoint, METRIC_HISTOGRAM

from komira_log.engine.log_event_record import LogEventRecord, REC_METRIC
from komira_log.engine.calibration import CalibrationAnchor


# The inline payload width: value(8) || attrset_id(4) || start_ns_delta(8).
comptime METRIC_BLOB_BYTES: Int = 20

comptime _OFF_VALUE: Int = 0
comptime _OFF_ATTRSET: Int = 8
comptime _OFF_START_DELTA: Int = 12


# -----------------------------------------------------------------------------
# The `flags` bit map.
#
# ⚠ "instrument kind + temporality + monotonic + value-is-double" is four
# THINGS, not four BITS: the instrument kind has
# four values and needs two bits, and `has_exemplar` needs a bit of its own
# (span id 0 is a legal span id, so the field cannot encode its own absence).
# The true span is bits 1-6. `flags` is a UInt16 and bits 7-15 remain free.
# -----------------------------------------------------------------------------

comptime _KIND_SHIFT: UInt16 = UInt16(1)
comptime _KIND_MASK: UInt16 = UInt16(0x3) << _KIND_SHIFT  # bits 1-2
comptime _MFLAGS_SHIFT: UInt16 = UInt16(3)
comptime _MFLAGS_MASK: UInt16 = UInt16(0xF) << _MFLAGS_SHIFT  # bits 3-6


@always_inline
def _put_u64_at(mut rec: LogEventRecord, off: Int, v: UInt64):
    """Little-endian write of a UInt64 into the record's inline arg-blob."""
    var x = v
    for i in range(8):
        rec.arg_blob[off + i] = UInt8(x & 0xFF)
        x = x >> 8


@always_inline
def _get_u64_at(rec: LogEventRecord, off: Int) -> UInt64:
    """Little-endian read of a UInt64 from the record's inline arg-blob."""
    var v: UInt64 = 0
    for i in range(8):
        v |= UInt64(Int(rec.arg_blob[off + i])) << (UInt64(i) * 8)
    return v


@always_inline
def _put_u32_at(mut rec: LogEventRecord, off: Int, v: UInt32):
    var x = v
    for i in range(4):
        rec.arg_blob[off + i] = UInt8(x & UInt32(0xFF))
        x = x >> 8


@always_inline
def _get_u32_at(rec: LogEventRecord, off: Int) -> UInt32:
    var v: UInt32 = 0
    for i in range(4):
        v |= UInt32(Int(rec.arg_blob[off + i])) << (UInt32(i) * 8)
    return v


# -----------------------------------------------------------------------------
# build_metric_record — a REC_METRIC record from a decoded `MetricPoint`.
#
# Returns `Optional[LogEventRecord]`: NONE when the point cannot be encoded.
# ⛔ THAT REFUSAL IS NOT DEFENSIVE PADDING. `MetricPoint.__init__` defaults
# `kind` to `METRIC_KIND_UNKNOWN` (255) precisely so an unset kind is
# distinguishable, and 255 truncated into the two-bit field would land on
# `METRIC_HISTOGRAM` — a default-constructed point would ride the ring claiming
# to be a histogram. Refusing is the only reading of that record that is not a
# lie. The signature is Optional rather than `raises` because a raise here would
# ripple to every transitive caller of the sweep that emits these.
# -----------------------------------------------------------------------------


def build_metric_record(
    point: MetricPoint, time_tick: UInt64
) -> Optional[LogEventRecord]:
    """Encode `point` as an on-ring `REC_METRIC`, timestamped with the raw
    counter tick `time_tick` (the drain anchors it back to wall-clock ns).

    `point.time_unix_ns` is NOT carried absolutely — `time_tick` is the single
    anchored instant and the blob carries `time - start` as a delta, so the two
    timestamps cannot drift apart across an anchor refresh."""
    if point.kind > METRIC_HISTOGRAM:
        # METRIC_KIND_UNKNOWN, or any future kind this two-bit field cannot
        # hold. Refuse; see the header.
        return None
    var rec = LogEventRecord()
    rec.kind = REC_METRIC
    rec.level = UInt8(0)
    rec.flags = (UInt16(Int(point.kind)) << _KIND_SHIFT) | (
        (UInt16(Int(point.flags)) & UInt16(0xF)) << _MFLAGS_SHIFT
    )
    rec.site_id = point.name_id
    rec.n_args = UInt8(0)
    rec.module_id = point.scope_id
    rec.timestamp = time_tick
    rec.corr_id = point.exemplar_span_id

    var start_delta: UInt64 = 0
    if point.time_unix_ns > point.start_time_unix_ns:
        start_delta = point.time_unix_ns - point.start_time_unix_ns
    _put_u64_at(rec, _OFF_VALUE, point.value_bits)
    _put_u32_at(rec, _OFF_ATTRSET, point.attrset_id)
    _put_u64_at(rec, _OFF_START_DELTA, start_delta)
    rec.arg_inline_len = UInt16(METRIC_BLOB_BYTES)
    return rec^


# -----------------------------------------------------------------------------
# metric_record_is_decodable — THE ONE SHARED GUARD.
#
# ⚠ CALLED BY FOUR OF THE SIX RING CONSUMERS, not all six, and the split is
# exact: the four that can PRODUCE a point ask this first (the three
# `SharedEngine.drain_worker*` methods and `span_drain.drain_unified`). The two
# bare free fns (`drain_to_lines` / `drain_to_views`) skip a REC_METRIC
# unconditionally — they have nowhere to put a decodable one either — so asking
# would change nothing and would imply a distinction they do not make.
#
# It is a free function and not four inline conditions on purpose: a guard
# duplicated at four sites in two modules is a guard that will disagree with
# itself the first time one of them is edited, and the failure mode of a
# disagreement here is a half-decoded point in a metrics store.
# -----------------------------------------------------------------------------


@always_inline
def metric_record_is_decodable(rec: LogEventRecord) -> Bool:
    """True when `rec` is a REC_METRIC this module can decode into a
    `MetricPoint`. False for the two shapes this module has no DECODER for: the
    arena-spilled histogram payload (a decoded form for it exists —
    `HistogramPoint` — but there is no ring codec for it; see the header) and a
    truncated header."""
    if rec.has_arg_overflow():
        return False
    return Int(rec.arg_inline_len) >= METRIC_BLOB_BYTES


# -----------------------------------------------------------------------------
# decode_metric_point — the inverse. `anchor` converts the raw tick back to
# wall-clock ns, exactly as the log decode converts to wall-ms.
#
# The caller MUST have checked `metric_record_is_decodable` first; every drain
# arm does, and the guard exists so none of them has to reason about it.
# -----------------------------------------------------------------------------


def decode_metric_point(
    rec: LogEventRecord, anchor: CalibrationAnchor
) -> MetricPoint:
    var p = MetricPoint()
    p.name_id = rec.site_id
    p.scope_id = rec.module_id
    p.kind = UInt8(Int((rec.flags & _KIND_MASK) >> _KIND_SHIFT))
    p.flags = UInt8(Int((rec.flags & _MFLAGS_MASK) >> _MFLAGS_SHIFT))
    p.exemplar_span_id = rec.corr_id

    p.value_bits = _get_u64_at(rec, _OFF_VALUE)
    p.attrset_id = _get_u32_at(rec, _OFF_ATTRSET)

    var time_ns = UInt64(anchor.tick_to_wall_ns(rec.timestamp))
    var start_delta = _get_u64_at(rec, _OFF_START_DELTA)
    p.time_unix_ns = time_ns
    # A delta wider than the anchored instant would put the interval start
    # before the epoch. Clamp rather than wrap: a nonsense window is readable,
    # a wrapped UInt64 start is a 584-year-wide one.
    p.start_time_unix_ns = time_ns - start_delta if start_delta <= time_ns else UInt64(0)
    return p^


# -----------------------------------------------------------------------------
# Accessors a consumer can use without a full decode (the counterpart of
# `span_open_parent_id` and friends).
# -----------------------------------------------------------------------------


@always_inline
def metric_record_kind(rec: LogEventRecord) -> UInt8:
    """The instrument kind carried in `flags` bits 1-2."""
    return UInt8(Int((rec.flags & _KIND_MASK) >> _KIND_SHIFT))
