# =============================================================================
# komira_log_index.metric_transpose — `MetricPoint` -> the `metrics` fact batch.
# =============================================================================
#
# The metrics analogue of `transpose.mojo`. It takes the owned
# `List[MetricPoint]` a metrics drain produces and builds the typed RecordBatch
# that `TelemetryMetricSegmentWriter` (komira_telemetry_store) publishes.
#
# ── What `series_id` is, and why it is derived rather than assigned ────────
# The sort key is `(series_id, ts)`, so a `series_id` is needed before a row can
# be written. Two ways to get one:
#
#   (a) Assign a dense counter as series are first seen. Rejected. A counter is
#       assigned in arrival order, so two writer shards give the same logical
#       series different ids, and the manifest's `[min_series_id,max_series_id]`
#       prune then means something different per shard.
#   (b) Derive it from the point's own identity. Chosen. `metric_series_id` is a
#       pure function of `(name_id, scope_id, attrset_id)`, so every writer that
#       sees one series computes one id, with no coordination and no table.
#
# The residue in (b): two of those three inputs are content hashes and are
# stable across processes (`name_id` is the hash of the metric-name literal;
# `scope_id` is the same id space as a log record's `module_id`).
# `attrset_id` is not: it is the slot an `AttrSet` was interned into, a
# per-process id assigned in insertion order, so two processes observing the
# same labelled series can compute two different `series_id`s.
#
# So `series_id` is a clustering and pruning key, not a global name, and this
# module keeps that safe:
#
#   * `name_id`, `scope_id` and `attrset_id` are each their own fact column. The
#     series identity is recoverable from the rows, and a reader never has to
#     trust `series_id` as a name. A query for "this metric" filters `name_id`.
#   * every bound the catalog carries stays true regardless: the manifest's
#     `[min_series_id,max_series_id]` is computed by scanning the rows actually
#     written, so an id that means something different in another process still
#     bounds this object correctly.
#   * `EMPTY_ATTRSET_ID = 0` is defined as the empty attribute set rather than a
#     sentinel, so the unlabelled case is stable across processes.
#
# The fix for the per-process id is not in this file: it is to hash the
# attribute set's content (`AttrSet.digest()` in komira_metrics) instead of its
# interning slot, which needs the drain seam to hand over the resolved
# `AttrSet`.
#
# The per-partition series side table (`series_id | attr_key | attr_value`) is
# not written, for the same reason: it needs the attribute strings, and this
# seam carries an interned `attrset_id` and no registry to resolve it. An empty
# side table would be worse than none: a reader joining against it would return
# zero rows for every labelled query and could not tell that from "no such
# series".
#
# Histograms are not columns. komira_metrics' histogram module lowers a
# histogram to a family of scalar `MetricPoint`s (a count, a sum, one counter per
# bucket), and every one of those lands in `value` like any other point. Columns
# no producer can populate would be always-null on every row.
#
# The value is two columns, deliberately. `MetricPoint` has one `value_bits`
# with two interpretations, discriminated by `MFLAG_VALUE_IS_DOUBLE` and by
# nothing else. Lowering both arms into one FLOAT64 loses exactness for an Int64
# counter above 2^53; lowering both into one INT64 bit pattern makes the file
# unreadable by pyarrow or DuckDB without a bitcast. So there are two typed
# columns, the flag says which one is meaningful, and the other holds 0.
#
# Encapsulation: no pointer in any signature. `MetricPoint` is POD and crosses
# by value.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_metrics.metric_point import MetricPoint

from komira_telemetry_store.metric_writer import (
    METRIC_SERIES_COLUMN,
    METRIC_TIME_COLUMN,
)


# -----------------------------------------------------------------------------
# §1 — the column names.
#
# `ts` and `series_id` are imported from the writer, not re-spelled: a second
# statement of a contract agrees with the first until one of them is edited. The
# dependency edge runs komira_log_index -> komira_telemetry_store and is
# one-way, so the producer imports the consumer's contract and there is exactly
# one spelling of the two names the writer resolves.
# -----------------------------------------------------------------------------

comptime METRIC_START_TS_COLUMN: String = "start_ts"
comptime METRIC_NAME_ID_COLUMN: String = "name_id"
comptime METRIC_SCOPE_ID_COLUMN: String = "scope_id"
comptime METRIC_ATTRSET_ID_COLUMN: String = "attrset_id"
comptime METRIC_KIND_COLUMN: String = "kind"
comptime METRIC_FLAGS_COLUMN: String = "flags"
comptime METRIC_VALUE_COLUMN: String = "value"
comptime METRIC_VALUE_INT_COLUMN: String = "value_int"
comptime METRIC_EXEMPLAR_COLUMN: String = "exemplar_span_id"

comptime METRICS_FACT_COLUMNS: Int = 11
"""The fact table's column count. Read by the test that asserts the schema and
the transpose agree — the two are built in the same file and in the same order,
and this is what makes a column added to one and not the other go RED."""


# -----------------------------------------------------------------------------
# §2 — `series_id`.
# -----------------------------------------------------------------------------


@always_inline
def _mix64(v: UInt64) -> UInt64:
    """The splitmix64 finaliser — the SAME mixer `komira_metrics/series_table.mojo`
    uses, and for the same reason it states there.

    The natural key `(name_id << 32) | attrset_id` puts `attrset_id` in the LOW
    bits, so any consumer indexing by a low-bit mask groups every metric sharing
    one attribute set together. Here the consequence is different but not
    smaller: an unmixed id would make `[min_series_id,max_series_id]` a range
    over structured, densely-clustered values, so the series prune would keep
    nearly every segment. The mixer is what makes the derived id behave like an
    identifier."""
    var z = v
    z = (z ^ (z >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> UInt64(27))) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> UInt64(31))


def metric_series_id(
    name_id: UInt32, scope_id: UInt32, attrset_id: UInt32
) -> Int64:
    """The series identity, as a stable-under-the-same-inputs Int64.

    A PURE FUNCTION of the triple that identifies a series on a `MetricPoint`.
    Deterministic, requiring no table, no coordination and no assignment order —
    which is what lets two writer shards agree without talking. See the file
    header for the one input that is process-local (`attrset_id`) and for why
    the fact table carries all three inputs as their own columns so the identity
    is recoverable without trusting this value as a name.

    NON-NEGATIVE by construction (the top bit is cleared). Not a correctness
    requirement — `overlaps_series` is signed-correct either way — but a negative
    id in a dataset a customer opens in DuckDB reads as corruption, and the
    63-bit space is not a constraint at any cardinality this library can reach."""
    var h = _mix64(
        (UInt64(Int(name_id)) << UInt64(32)) | UInt64(Int(scope_id))
    )
    # A SECOND round rather than folding `attrset_id` into the same word: the
    # first word is already full (32 + 32 bits), so there is nowhere for it to
    # go, and XOR-ing it into a mixed value without re-mixing would leave its
    # low bits directly observable in the result.
    h = _mix64(h ^ (UInt64(Int(attrset_id)) * UInt64(0x9E3779B97F4A7C15)))
    return Int64(h & UInt64(0x7FFF_FFFF_FFFF_FFFF))


# -----------------------------------------------------------------------------
# §3 — the schema. COLUMN ORDER IS LOAD-BEARING (the builder appends
# positionally, exactly as `log_index_schema` / `log_views_to_record_batch` do).
# -----------------------------------------------------------------------------


def metrics_fact_schema() raises -> Schema:
    """The `metrics` fact table, as this library can actually produce it. Eleven columns; the order here MUST match `metric_points_to_record_batch`.

    Column-by-column, with what each is FOR:

      ts               TIMESTAMP_NS  the partition key AND the manifest's
                                     [min_ts,max_ts]. Epoch nanoseconds.
      series_id        INT64         the PRIMARY sort key and the second
                                     pruning axis. Derived; see §2 above.
      name_id          INT64         FNV-1a of the metric name — CONTENT-derived,
                                     so a query for "this metric" is expressible
                                     without resolving a string.
      scope_id         INT64         instrumentation scope. The SAME id space as
                                     a log record's `module_id`, deliberately, so
                                     a metric and a log line from one module join
                                     without a mapping table.
      attrset_id       INT64         the interned attribute-set id. PER-PROCESS
                                     — carried because it is half of what
                                     `series_id` was derived from, so the
                                     derivation is auditable from the rows.
      kind             INT64         METRIC_COUNTER / UPDOWNCOUNTER / GAUGE /
                                     HISTOGRAM. Widened from UInt8: a reader
                                     switching on it needs a CLOSED default, and
                                     `METRIC_KIND_UNKNOWN = 255` is a real value.
      flags            INT64         the MFLAG_* bits — temporality, monotonicity,
                                     WHICH VALUE COLUMN IS MEANINGFUL, exemplar
                                     presence. Not derivable from `kind`.
      start_ts         INT64         the interval start. A DELTA point's window is
                                     (start_ts, ts]; a gauge sets them equal.
      value            FLOAT64       the value when MFLAG_VALUE_IS_DOUBLE is SET.
      value_int        INT64         the value when it is CLEAR. See the header
                                     for why this is two columns and not one.
      exemplar_span_id INT64         0 is a LEGAL span id — read MFLAG_HAS_EXEMPLAR,
                                     never this field alone.

    `name` is not a string column.
    Resolving `name_id` to text needs a `NameRegistry`, and the drain seam this
    dataset is fed from carries neither the registry nor the string. `name_id` is
    the FNV-1a of the literal, so the mapping is reproducible by anyone holding
    the metric names — but it is not in the file, and pretending otherwise by
    writing the hash INTO a string column would be worse than the honest i64."""
    var sb = SchemaBuilder()
    # 0: ts — TIMESTAMP_NS so the temporal discriminator rides the column tag.
    sb.add_field(Field(METRIC_TIME_COLUMN, ArrowType.TIMESTAMP_NS, False))
    # 1: series_id — the primary sort key.
    sb.add_field(Field(METRIC_SERIES_COLUMN, ArrowType.INT64, False))
    # 2..4: the identity the series_id was derived FROM.
    sb.add_field(Field(METRIC_NAME_ID_COLUMN, ArrowType.INT64, False))
    sb.add_field(Field(METRIC_SCOPE_ID_COLUMN, ArrowType.INT64, False))
    sb.add_field(Field(METRIC_ATTRSET_ID_COLUMN, ArrowType.INT64, False))
    # 5..6: the discriminants.
    sb.add_field(Field(METRIC_KIND_COLUMN, ArrowType.INT64, False))
    sb.add_field(Field(METRIC_FLAGS_COLUMN, ArrowType.INT64, False))
    # 7: the interval start.
    sb.add_field(Field(METRIC_START_TS_COLUMN, ArrowType.INT64, False))
    # 8..9: the two typed value arms.
    sb.add_field(Field(METRIC_VALUE_COLUMN, ArrowType.FLOAT64, False))
    sb.add_field(Field(METRIC_VALUE_INT_COLUMN, ArrowType.INT64, False))
    # 10: the exemplar link.
    sb.add_field(Field(METRIC_EXEMPLAR_COLUMN, ArrowType.INT64, False))
    return sb.build()


# -----------------------------------------------------------------------------
# §4 — the transpose.
# -----------------------------------------------------------------------------


def metric_points_to_record_batch(
    points: List[MetricPoint]
) raises -> RecordBatch:
    """`MetricPoint`s -> the fact batch. Column order MUST match
    `metrics_fact_schema`. An empty input yields a 0-row batch, which the writer
    then declines to publish — an empty object plus a catalog entry whose
    [min,max] is meaningless is strictly worse than nothing.

    NO SORT HERE. The `(series_id, ts)` order is imposed by the WRITER, per day
    partition, immediately before encoding — because the sort must be over
    exactly the rows that go into one object, and this function does not know
    how the flush will split across midnight."""
    var n = len(points)

    var ts = List[Int64](capacity=n)
    var sids = List[Int64](capacity=n)
    var name_ids = List[Int64](capacity=n)
    var scope_ids = List[Int64](capacity=n)
    var attrset_ids = List[Int64](capacity=n)
    var kinds = List[Int64](capacity=n)
    var flags = List[Int64](capacity=n)
    var start_ts = List[Int64](capacity=n)
    var values = List[Float64](capacity=n)
    var value_ints = List[Int64](capacity=n)
    var exemplars = List[Int64](capacity=n)

    for i in range(n):
        ref p = points[i]
        ts.append(Int64(p.time_unix_ns))
        sids.append(metric_series_id(p.name_id, p.scope_id, p.attrset_id))
        name_ids.append(Int64(Int(p.name_id)))
        scope_ids.append(Int64(Int(p.scope_id)))
        attrset_ids.append(Int64(Int(p.attrset_id)))
        kinds.append(Int64(Int(p.kind)))
        flags.append(Int64(Int(p.flags)))
        start_ts.append(Int64(p.start_time_unix_ns))
        # The flag decides, and nothing else does. `MetricPoint.as_double`'s
        # own docstring: reading a double's bit pattern as an Int64 "is not a
        # conversion, it is a reinterpretation, and it will be nonsense". The
        # unused arm is written as 0 rather than as a copy of the other, so a
        # reader that ignores the flag gets an obviously wrong number instead of
        # a plausible one.
        if p.value_is_double():
            values.append(p.as_double())
            value_ints.append(Int64(0))
        else:
            values.append(Float64(0.0))
            value_ints.append(p.as_int())
        # 0 unless the flag is set — `set_exemplar` sets both, and span id 0 is
        # itself legal, which is why the flag exists.
        if p.has_exemplar():
            exemplars.append(Int64(p.exemplar_span_id))
        else:
            exemplars.append(Int64(0))

    var schema = metrics_fact_schema()
    var rb = RecordBatchBuilder.with_capacity(METRICS_FACT_COLUMNS)
    # The `ts` Column's arrow_type MUST match the schema's TIMESTAMP_NS —
    # `from_primitive[i64]` would stamp INT64 and mismatch the schema (the same
    # trap `transpose.mojo` records on the log side).
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list(ts), ArrowType.TIMESTAMP_NS
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(sids)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(name_ids)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(scope_ids)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(attrset_ids)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(kinds)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(flags)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(start_ts)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(values)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(value_ints)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(exemplars)
        )
    )
    return rb.build(schema^)
