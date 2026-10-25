# =============================================================================
# komira_log_index.transpose: LogRecordView -> typed multi-column RecordBatch.
# =============================================================================
#
# The transpose seam. It takes the owned `List[LogRecordView]` the log engine
# produced and builds the typed multi-column RecordBatch that the search sink
# consumes. Narrow integer columns are widened so none is silently dropped when
# the sink classifies columns.
#
# THE FROZEN LOG-INDEX SCHEMA. The schema is scoped to the index and fixed at
# first publish. It does not vary per drain worker, and dynamic args never
# change it. Every split of the log index therefore carries the same fast-field
# set, so a reader may inspect the first split's fast fields once and rely on
# them for all of them. The columns:
#
#   | Column      | Arrow type    | Source                        | Sink class
#   |-------------|---------------|-------------------------------|-----------------
#   | message     | Utf8 (STRING) | view.message (interpolated)   | TEXT  -> inverted
#   | _source     | Utf8 (STRING) | JSON of the record (required) | _source
#   | timestamp   | Int64 (ns)    | view.wall_ms * 1e6            | DATE  -> fast-field
#   | level       | Utf8 (STRING) | level_name(view.level)        | KEYWORD -> fast-field
#   | module      | Utf8 (STRING) | view.module (resolved)        | KEYWORD -> fast-field
#   | corr_id     | Int64         | view.corr_id (widened)        | NUMERIC -> fast-field
#   | flags       | Int64         | view.flags   (widened)        | NUMERIC -> fast-field
#   | site_id     | Int64         | view.site_id (widened)        | NUMERIC -> fast-field
#
# Widening. UInt64 corr_id, UInt16 flags and UInt32 site_id fall in the sink's
# silent-skip class (it reads only i32, i64, f32 and f64 fast fields), so they
# are emitted as Int64 and land in the fast fields. `timestamp` is emitted as
# Int64 nanoseconds (DATE storage is i64).
#
# PER-FIELD INDEX MAPPING. `message` is the single designated TEXT (inverted)
# field; everything else is columnar-only (the sink classifier maps STRING to
# KEYWORD, Int64 to NUMERIC and the temporal timestamp to DATE). The dynamic arg
# key/value pairs do not change the schema; they fold into the `_source` JSON
# only.
#
# This module touches no UnsafePointer. The `LogRecordView`s carry owned
# Strings (the engine copied the arena before the seam), and the columns are
# built through the public RecordBatchBuilder and Column factories.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_log import LogRecordView
from komira_log.levels import level_name


# -----------------------------------------------------------------------------
# Frozen field names (scoped to the index, stable across all splits and workers).
# -----------------------------------------------------------------------------

comptime LOG_INDEX_TEXT_FIELD: String = String("message")
comptime LOG_INDEX_SOURCE_FIELD: String = String("_source")
comptime LOG_INDEX_TIMESTAMP_FIELD: String = String("timestamp")
comptime LOG_INDEX_LEVEL_FIELD: String = String("level")
comptime LOG_INDEX_MODULE_FIELD: String = String("module")
comptime LOG_INDEX_CORR_ID_FIELD: String = String("corr_id")
comptime LOG_INDEX_FLAGS_FIELD: String = String("flags")
comptime LOG_INDEX_SITE_ID_FIELD: String = String("site_id")


# -----------------------------------------------------------------------------
# log_index_schema — the FROZEN log-index schema. The column ORDER is
# load-bearing for the transpose (the RecordBatchBuilder appends columns
# positionally; this order MUST match log_views_to_record_batch). The schema is
# returned by value so the caller passes it identically to every SearchSink for
# the log index: one schema per index.
# -----------------------------------------------------------------------------


def log_index_schema() raises -> Schema:
    """The single FROZEN schema for the LOG index. `message` is the
    designated TEXT field; `_source` is the mandatory designated _source STRING
    (SearchSink raises without it). `timestamp` is DATE-storage i64 ns;
    level/module are KEYWORD strings; corr_id/flags/site_id are Int64 (widened
    from narrower unsigned types). Every drain worker for this index uses THIS
    schema, so all splits share one fast-field set."""
    var sb = SchemaBuilder()
    # 0: message (TEXT / inverted). nullable=False (always interpolated).
    sb.add_field(Field(LOG_INDEX_TEXT_FIELD, ArrowType.STRING, False))
    # 1: _source (the mandatory designated _source blob).
    sb.add_field(Field(LOG_INDEX_SOURCE_FIELD, ArrowType.STRING, False))
    # 2: timestamp (DATE fast-field; TIMESTAMP_NS storage is i64 — is_temporal()
    #    -> classified DATE; storage i64 -> readable, lands in the fast-fields).
    sb.add_field(
        Field(LOG_INDEX_TIMESTAMP_FIELD, ArrowType.TIMESTAMP_NS, False)
    )
    # 3: level (KEYWORD).
    sb.add_field(Field(LOG_INDEX_LEVEL_FIELD, ArrowType.STRING, False))
    # 4: module (KEYWORD).
    sb.add_field(Field(LOG_INDEX_MODULE_FIELD, ArrowType.STRING, False))
    # 5: corr_id (NUMERIC, widened from UInt64 -> Int64).
    sb.add_field(Field(LOG_INDEX_CORR_ID_FIELD, ArrowType.INT64, False))
    # 6: flags (NUMERIC, widened from UInt16 -> Int64).
    sb.add_field(Field(LOG_INDEX_FLAGS_FIELD, ArrowType.INT64, False))
    # 7: site_id (NUMERIC, widened from UInt32 -> Int64).
    sb.add_field(Field(LOG_INDEX_SITE_ID_FIELD, ArrowType.INT64, False))
    return sb.build()


# -----------------------------------------------------------------------------
# _json_escape / _source_json — the mandatory `_source` blob. The blob is
# the JSON-encoded record (the match-query return payload). It is a compact
# object of the fixed columns + the decoded arg key/value pairs (so the
# free-form args are searchable via _source full-text without mutating the
# schema). Hand-rolled escaping (no JSON dependency, to keep
# the import surface of this package minimal).
# -----------------------------------------------------------------------------


def _json_escape(s: String) -> String:
    var b = s.as_bytes()
    var out = String("")
    for i in range(len(b)):
        var c = Int(b[i])
        if c == ord('"'):
            out += '\\"'
        elif c == ord("\\"):
            out += "\\\\"
        elif c == ord("\n"):
            out += "\\n"
        elif c == ord("\r"):
            out += "\\r"
        elif c == ord("\t"):
            out += "\\t"
        elif c < 0x20:
            # Control char -> \u00XX.
            var hexd = "0123456789abcdef"
            var hb = hexd.as_bytes()
            out += "\\u00"
            out += chr(Int(hb[(c >> 4) & 0xF]))
            out += chr(Int(hb[c & 0xF]))
        else:
            out += chr(c)
    return out


def _source_json(view: LogRecordView) -> String:
    var out = String("{")
    out += '"message":"' + _json_escape(view.message) + '"'
    out += ',"level":"' + _json_escape(String(level_name(view.level))) + '"'
    out += ',"module":"' + _json_escape(view.module) + '"'
    out += ',"timestamp":' + String(view.wall_ms)
    out += ',"corr_id":' + String(Int64(Int(view.corr_id)))
    out += ',"flags":' + String(Int64(Int(view.flags)))
    out += ',"site_id":' + String(Int64(Int(view.site_id)))
    # Free-form args -> a nested "args" object (searchable via _source full-text,
    # NOT as schema columns; the schema stays frozen).
    var na = len(view.arg_keys)
    if na > 0:
        out += ',"args":{'
        for i in range(na):
            if i > 0:
                out += ","
            out += '"' + _json_escape(view.arg_keys[i]) + '":"'
            out += _json_escape(view.arg_vals[i]) + '"'
        out += "}"
    out += "}"
    return out^


# -----------------------------------------------------------------------------
# log_views_to_record_batch — the transpose. Builds the typed
# multi-column RecordBatch from the owned views. Column order MUST match
# log_index_schema. Empty input yields a 0-row batch (valid).
# -----------------------------------------------------------------------------


def log_views_to_record_batch(views: List[LogRecordView]) raises -> RecordBatch:
    var n = len(views)
    var schema = log_index_schema()

    var messages = List[String](capacity=n)
    var sources = List[String](capacity=n)
    var timestamps = List[Int64](capacity=n)
    var levels = List[String](capacity=n)
    var modules = List[String](capacity=n)
    var corr_ids = List[Int64](capacity=n)
    var flagses = List[Int64](capacity=n)
    var site_ids = List[Int64](capacity=n)

    for i in range(n):
        ref v = views[i]
        messages.append(v.message)
        sources.append(_source_json(v))
        # ns timestamp: wall_ms * 1e6 (nanoseconds, matching OTLP span start times).
        timestamps.append(v.wall_ms * Int64(1_000_000))
        levels.append(String(level_name(v.level)))
        modules.append(v.module)
        # Widening to Int64 (else silent-skip at SearchSink classification).
        corr_ids.append(Int64(Int(v.corr_id)))
        flagses.append(Int64(Int(v.flags)))
        site_ids.append(Int64(Int(v.site_id)))

    var rb = RecordBatchBuilder.with_capacity(8)
    rb.add_column(Column.from_string(StringArray.from_strings(messages)))
    rb.add_column(Column.from_string(StringArray.from_strings(sources)))
    # The timestamp Column's arrow_type MUST match the schema's TIMESTAMP_NS (the
    # i64 buffer is read by the BatchView via the spec's storage DType = i64; the
    # Column tag carries the temporal discriminator). from_primitive[i64] would
    # stamp INT64 and mismatch the schema.
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list(timestamps),
            ArrowType.TIMESTAMP_NS,
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(levels)))
    rb.add_column(Column.from_string(StringArray.from_strings(modules)))
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(corr_ids)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(flagses)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(site_ids)
        )
    )
    return rb.build(schema^)


# -----------------------------------------------------------------------------
# LogIndexBatchPlan — the (schema, batch) value the consumer drives into a
# SearchSink. Carries the frozen schema (so the caller does not re-derive it) +
# the transposed batch. POD-owned (Schema + RecordBatch are Movable); no
# UnsafePointer. The caller: `sink.init_sink(plan.schema^)` then
# `sink.accept_batch(plan.batch^)` then `sink.finish()`.
# -----------------------------------------------------------------------------


struct LogIndexBatchPlan(Movable, Deinitable):
    """The transposed (frozen-schema, typed-batch) handoff for one drain window.
    The caller drives it into a SearchSink whose `text_field` is
    LOG_INDEX_TEXT_FIELD ('message') and whose `source_field` is
    LOG_INDEX_SOURCE_FIELD ('_source')."""

    var schema: Schema
    var batch: RecordBatch
    var row_count: Int

    def __init__(out self, var schema: Schema, var batch: RecordBatch, row_count: Int):
        self.schema = schema^
        self.batch = batch^
        self.row_count = row_count


def build_log_index_plan(
    views: List[LogRecordView],
) raises -> LogIndexBatchPlan:
    """One-call transpose: views -> (frozen schema, typed RecordBatch). The
    schema is the frozen log-index schema; the batch is widened."""
    var n = len(views)
    var schema = log_index_schema()
    var batch = log_views_to_record_batch(views)
    return LogIndexBatchPlan(schema^, batch^, n)
