# =============================================================================
# komira_telemetry_read.segment_read: GET exactly the planned objects, prune row
#   groups on the time column, decode.
# =============================================================================
#
# The second half of the direct query path: the plan says WHICH objects, this
# says HOW to open one. Everything below the store `get` is IO-free: the whole
# object comes back as bytes and each later step is `komira_parquet`'s
# `parse_full_metadata`, `can_prune_row_group` and `decode_row_group_from_bytes`.
#
# This is a convenience, not the product surface. A reader with DuckDB replaces
# this file; what it cannot replace is `scan_plan.mojo`, because nothing outside
# the at-rest format knows how to replay the manifest.
#
# -- THE TWO-LEVEL PRUNE ------------------------------------------------------
#   1. FILE level: `TelemetrySegmentEntry.overlaps_time`, in the planner. A
#      pruned object is never GET at all. Saves a network round trip.
#   2. ROW-GROUP level: `can_prune_row_group` over the footer's min/max, here.
#      Saves decompression and decode of pages already paid for at the network.
# The accounting below reports both so neither can silently stop working.
#
# `can_prune_row_group` is conservative: it answers False when a column chunk
# carries no statistics, so a file written without time-column statistics
# decodes fully instead of wrongly. That is a performance loss that reports as
# success, which is why `TelemetryReadStats.rgs_pruned` is returned rather than
# kept internal: a caller that expected pruning can assert on it. Do not "fix"
# a zero by removing the pruner.
#
# -- THE KEEPALIVE ------------------------------------------------------------
# The compiler's as-soon-as-possible destruction can drop the byte buffer right
# after the last `view_range_ro`, while a freshly decoded column's first data
# page is still reading against that view (observed: row 0 reading pointer-sized
# garbage). An empty `_ = buf` is NOT sufficient; a real read is. The anchor at
# the end of `decode_telemetry_segment_bytes` is that read. Do not delete it.
#
# Bytes flow as owned `List[UInt8]` / `SharedAlignedBuffer`; no pointer type
# appears in any signature.
# =============================================================================

from komira_collections.slab import Slab

from komira_arrow.record_batch import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_plan_expr.expr import BIN_AND, BIN_GE, BIN_LE, Expr
from komira_plan_expr.scalar_value import ScalarValue

from komira_telemetry_store.log_writer import LOG_TIME_COLUMN

from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from komira_parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet.rg_pruner import can_prune_row_group

from komira_telemetry_read.scan_plan import TelemetryScanPlan


comptime TELEMETRY_LOG_TS_COLUMN: String = LOG_TIME_COLUMN
"""The time column of the `logs` dataset: the one column the store's log writer
requires (`LOG_TIME_COLUMN`, re-exported here under the reader's name). The
writer accepts batches of any other schema; the columns this package's log
search expects beyond it are named in `log_search.mojo`."""

comptime _PAR1_0 = UInt8(80)  # 'P'
comptime _PAR1_1 = UInt8(65)  # 'A'
comptime _PAR1_2 = UInt8(82)  # 'R'
comptime _PAR1_3 = UInt8(49)  # '1'


# =============================================================================
# §1 — the accounting a caller can ASSERT on.
# =============================================================================


@fieldwise_init
struct TelemetryReadStats(Copyable, Movable, Deinitable):
    """What one `read_telemetry_segments` call actually did.

    EVERY FIELD IS HERE BECAUSE ITS ABSENCE MAKES A FAILURE LOOK LIKE A SUCCESS:
      objects_fetched  0 with a non-empty plan means the GETs did not happen.
      rgs_total        the denominator; `rgs_pruned` alone is uninterpretable.
      rgs_pruned       the zone-map win. Zero on a time-ranged query is a
                       performance regression that returns correct rows, so
                       nothing else would ever notice it.
      rgs_decoded      `rgs_total - rgs_pruned`, carried explicitly so a caller
                       does not have to trust that identity across versions.
      rows_decoded     rows that came back BEFORE any row-level time filter.
    """

    var objects_fetched: Int
    var rgs_total: Int
    var rgs_pruned: Int
    var rgs_decoded: Int
    var rows_decoded: Int


# =============================================================================
# §2 — the time predicate pushed into the footer's zone map.
# =============================================================================


def telemetry_time_predicate(
    ts_column: String, t0_ns: Int64, t1_ns: Int64
) -> Expr:
    """`<ts_column> >= t0 AND <ts_column> <= t1`: the row-group pruning filter.

    BOTH BOUNDS ARE INCLUSIVE, matching `TelemetrySegmentEntry.overlaps_time`
    and `days_covering`. Three places state the same closed interval and they
    MUST agree: a half-open bound at one of the three levels would drop rows
    only at partition edges, which is the least reproducible bug shape."""
    var lo = Expr.binary(
        BIN_GE,
        Expr.col_ref(ts_column),
        Expr.literal(ScalarValue.from_int64(t0_ns)),
    )
    var hi = Expr.binary(
        BIN_LE,
        Expr.col_ref(ts_column),
        Expr.literal(ScalarValue.from_int64(t1_ns)),
    )
    return Expr.binary(BIN_AND, lo^, hi^)


# =============================================================================
# §3 — one object: bytes -> row groups -> batches.
# =============================================================================


def decode_telemetry_segment_bytes(
    var object_bytes: List[UInt8],
    ref filter: Expr,
    mut stats: TelemetryReadStats,
) raises -> Slab[RecordBatch]:
    """Decode ONE at-rest Parquet object, skipping row groups the filter proves
    empty. Returns one `RecordBatch` per SURVIVING row group.

    NO SILENT TOLERANCE OF A BAD OBJECT. A missing `PAR1`, an impossible footer
    length or an undecodable row group RAISES with the reason. A telemetry read
    that folds a corrupt object to zero rows reports "nothing was logged" for a
    bucket that is full."""
    var n = len(object_bytes)
    if n < 12:
        raise Error(
            "decode_telemetry_segment_bytes: object is "
            + String(n)
            + " bytes, too small to be a Parquet file (min 12)"
        )
    if (
        object_bytes[n - 4] != _PAR1_0
        or object_bytes[n - 3] != _PAR1_1
        or object_bytes[n - 2] != _PAR1_2
        or object_bytes[n - 1] != _PAR1_3
    ):
        raise Error(
            "decode_telemetry_segment_bytes: missing trailing PAR1 magic: the"
            " object at this key is not a Parquet file"
        )
    var footer_len = (
        Int(object_bytes[n - 8])
        | (Int(object_bytes[n - 7]) << 8)
        | (Int(object_bytes[n - 6]) << 16)
        | (Int(object_bytes[n - 5]) << 24)
    )
    if footer_len <= 0 or footer_len + 8 > n:
        raise Error(
            "decode_telemetry_segment_bytes: invalid footer length "
            + String(footer_len)
            + " for a "
            + String(n)
            + "-byte object"
        )
    var metadata_offset = n - 8 - footer_len

    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    buf.copy_from_bytes_list(object_bytes^)
    buf.set_length(n)

    var meta = parse_full_metadata(
        buf.view_range_ro(metadata_offset, footer_len)
    )
    var out = Slab[RecordBatch]()
    var num_rgs = len(meta.row_groups)
    for rg_idx in range(num_rgs):
        stats.rgs_total += 1
        var rg = meta.row_groups[rg_idx].copy()
        # LEVEL-2 PRUNE. Conservative: False on missing statistics.
        if can_prune_row_group(rg, meta, filter):
            stats.rgs_pruned += 1
            continue
        stats.rgs_decoded += 1
        var rg_br = row_group_byte_range(rg)
        var rg_view = buf.view_range_ro(rg_br.start, rg_br.length())
        var batch = decode_row_group_from_bytes(
            rg_view,
            rg_br,
            rg,
            meta.schema.copy(),
            ColumnProjection.all(),
        )
        stats.rows_decoded += batch.num_rows()
        out.append(batch^)

    # KEEPALIVE: see the file header. A REAL read, not `_ = buf`.
    var _anchor = buf.read_u8_at(n - 1)
    _ = _anchor
    _ = buf^
    return out^


# =============================================================================
# §4 — the whole plan: GET exactly the surviving keys, decode each.
# =============================================================================


def read_telemetry_segments[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    plan: TelemetryScanPlan,
    ts_column: String,
) raises -> Tuple[Slab[RecordBatch], TelemetryReadStats]:
    """GET exactly `plan.object_keys()` and decode each with the time predicate
    pushed into the footer.

    EVERY FETCH IS AN EXACT KEY GET. There is no listing in this function: the
    keys came from the catalog. A listing here would reintroduce the double
    count the merge-input skip in the planner exists to prevent, because a
    listing sees compacted-away objects the manifest has already retired.

    Returns the batches (one per surviving row group across all objects) and the
    accounting. THE BATCHES ARE NOT TIME-FILTERED AT ROW LEVEL: a surviving row
    group may hold rows outside `[t0,t1]`. Row-level filtering is the caller's;
    `TelemetryLogSearch` does it for the log dataset."""
    var filter = telemetry_time_predicate(ts_column, plan.t0_ns, plan.t1_ns)
    var stats = TelemetryReadStats(0, 0, 0, 0, 0)
    var out = Slab[RecordBatch]()
    var keys = plan.object_keys()
    for i in range(len(keys)):
        var bytes = storage.get(Path.parse(keys[i]))
        stats.objects_fetched += 1
        var batches = decode_telemetry_segment_bytes(bytes^, filter, stats)
        var nb = len(batches)
        # Moves every slot out, then forgets them. NOTHING IN THIS LOOP BODY
        # MAY RAISE: `take_slot_unchecked` and `Slab.append` do not, and a
        # raise between the take and `set_len_unchecked(0)` would drop each
        # taken slot twice.
        for b in range(nb):
            out.append(batches.take_slot_unchecked(b))
        batches.set_len_unchecked(0)
        _ = batches^
    return (out^, stats^)
