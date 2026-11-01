# =============================================================================
# komira_log.engine.span_emit — span OPEN/CLOSE record builders (P4a).
# =============================================================================
#
# THE UNIFICATION at the engine level. A span rides the EXACT SAME `LogEventRecord` +
# per-core `LogRecordRing` the log path uses; the record's built-in `kind`
# discriminant (`REC_SPAN_OPEN` / `REC_SPAN_CLOSE`) tells the drain whether to
# render a text line (logs) or an OTLP-shaped span JSON (spans). ONE ring, ONE
# drain, two outputs.
#
# A span = a SPAN_OPEN record + a SPAN_CLOSE record on the per-core ring:
#   * SPAN_OPEN  — kind=REC_SPAN_OPEN, corr_id=span_id, site_id=name-digest,
#                  module_id=module-digest, timestamp=raw ticks (start),
#                  the parent span_id encoded into the inline arg-blob (so the
#                  drain reconstructs the parent edge), and the trace_id encoded
#                  alongside it.
#   * SPAN_CLOSE — kind=REC_SPAN_CLOSE, corr_id=span_id, timestamp=raw ticks
#                  (end). No name/parent needed — the drain joins on span_id.
#
# We REUSE the inline `arg_blob` to carry the (parent_id, trace_id) the OTLP
# render needs, with a fixed binary layout the span drain decodes. This keeps
# the record POD + fixed-stride (no stale pointer — no new heap-owning field) and
# avoids touching the log arg-blob wire format (the log decoder never sees a
# SPAN record; the drain routes on `kind` BEFORE decoding args).
#
# Span-OPEN arg-blob layout (24 bytes, fits inline in ARG_INLINE_BYTES=48):
#   [0..8)   parent_id : UInt64 LE   (0 == root span)
#   [8..16)  trace_lo  : UInt64 LE   (low 8 bytes of the 128-bit trace_id)
#   [16..24) trace_hi  : UInt64 LE   (high 8 bytes; 0 in P4a — analyzer treats
#                                      trace_id as opaque, low 8 bytes carry the
#                                      per-root uniqueness, as the obs tracer does)
# SPAN_CLOSE carries no arg-blob (n_args=0, arg_inline_len=0).
#
# Encapsulation: the `*` builders take TYPED scalars and return a POD
# `LogEventRecord` by value. No `UnsafePointer` crosses any public API; the
# parent/trace bytes live inline in the record's fixed `arg_blob`.
# =============================================================================

from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_SPAN_OPEN,
    REC_SPAN_CLOSE,
)
from komira_log.engine.site_dictionary import fnv1a_32
from komira_log.engine.calibration import read_raw_ticks


# Inline span-OPEN payload width (parent_id + trace_lo + trace_hi).
comptime SPAN_OPEN_BLOB_BYTES: Int = 24


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


# -----------------------------------------------------------------------------
# build_span_open[name, module] — a SPAN_OPEN record carrying the comptime
# name/module digests, the span_id (in corr_id), the start tick, and the
# (parent_id, trace_id) inline so the drain can render the OTLP parent edge.
# -----------------------------------------------------------------------------


def build_span_open[
    name: StringLiteral, module: StringLiteral
](
    span_id: UInt64,
    parent_id: UInt64,
    trace_lo: UInt64,
    trace_hi: UInt64,
    level: UInt8,
    start_tick: UInt64,
) -> LogEventRecord:
    comptime site_id = fnv1a_32(name)
    comptime module_id = fnv1a_32(module)

    var rec = LogEventRecord()
    rec.kind = REC_SPAN_OPEN
    rec.level = level
    rec.site_id = site_id
    rec.module_id = module_id
    rec.corr_id = span_id
    rec.timestamp = start_tick
    # The (parent_id, trace_id) payload lives inline; n_args stays 0 because the
    # SPAN drain decodes by fixed offset, NOT via the log tag-table walk.
    rec.n_args = UInt8(0)
    _put_u64_at(rec, 0, parent_id)
    _put_u64_at(rec, 8, trace_lo)
    _put_u64_at(rec, 16, trace_hi)
    rec.arg_inline_len = UInt16(SPAN_OPEN_BLOB_BYTES)
    return rec^


# -----------------------------------------------------------------------------
# build_span_close — a SPAN_CLOSE record: just the span_id (corr_id) + end tick.
# The drain joins it to the matching OPEN by span_id.
# -----------------------------------------------------------------------------


def build_span_close(span_id: UInt64, end_tick: UInt64) -> LogEventRecord:
    var rec = LogEventRecord()
    rec.kind = REC_SPAN_CLOSE
    rec.corr_id = span_id
    rec.timestamp = end_tick
    rec.n_args = UInt8(0)
    rec.arg_inline_len = UInt16(0)
    return rec^


# -----------------------------------------------------------------------------
# Inline accessors the span drain uses to pull the parent/trace out of a
# decoded SPAN_OPEN record.
# -----------------------------------------------------------------------------


@always_inline
def span_open_parent_id(rec: LogEventRecord) -> UInt64:
    return _get_u64_at(rec, 0)


@always_inline
def span_open_trace_lo(rec: LogEventRecord) -> UInt64:
    return _get_u64_at(rec, 8)


@always_inline
def span_open_trace_hi(rec: LogEventRecord) -> UInt64:
    return _get_u64_at(rec, 16)
