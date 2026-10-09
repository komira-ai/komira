# =============================================================================
# komira_sql/sql_tvf_bind.mojo
#   Bind-time schema resolution for the FOOTERLESS table-valued functions.
# =============================================================================
#
# `read_parquet('p')` binds off the file's own footer, so the binder needs
# nothing from the SQL text and nothing from this module. `read_csv('p', ...)`
# and `read_json('p', ...)` have no footer: a CSV file's entire self-description
# is its header LINE, and a JSONL file has none at all. This module infers their
# schemas at bind time and builds the scan leaf. `read_avro('p')` is here too:
# an OCF carries its schema in the container header, and its leaf has the same
# shape as the CSV and JSONL leaves.
#
# THREE PROPERTIES THIS FILE IS BUILT AROUND
# ==========================================
#
# 1. THE READ DOES NOT HAPPEN AT BIND TIME. An eager read here would decode the
#    whole file into a RecordBatch before the plan runs. So the binder emits
#    the LAZY scan leaf (`SOURCE_KIND_ROW`, declared by the source kind), and
#    every byte of decode happens when the plan is materialized.
#
#    What bind time DOES pay is a bounded prefix: `read_csv_bytes_to_schema`
#    caps itself at a 256 KiB newline-snapped prefix, and the JSONL inferrer is
#    given one explicitly here. For an UNCOMPRESSED path the slurp is an mmap
#    (`read_chunked`), so only the pages the inferrer touches are ever faulted
#    in — deliberately NOT `read_text_source_to_heap_buffer`, whose
#    `realign_to[64]` copies the WHOLE file. A COMPRESSED path has no bounded
#    form: the whole-file codecs decompress everything before any line is
#    visible, so `.csv.gz` pays a full decompress per bind.
#
# 2. `all_varchar=true` IS HONORED, AND IT COSTS NOTHING TO HONOR. DuckDB's
#    option skips type inference and hands back VARCHAR columns. The schema
#    this binder stamps on the scan leaf is what the row reader parses each cell
#    AS (the reader takes each column's dtype from the leaf's schema), so making
#    every field STRING here is sufficient — no reader flag, no second
#    inference mode. Ignoring the option would return the same rows with
#    different TYPES.
#
# 3. AN OPTION IS EITHER HONORED OR REFUSED, NEVER DROPPED. The SQL parser
#    owns the option allowlist. By the time a `TvfOptions` reaches this file
#    every option in the text has been either recorded, proven neutral, or
#    raised on.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow_ipc.chunked_read import read_chunked
from komira_buffer.file_identity import FileIdentity
from komira_plan_ir.logical_plan import LogicalPlan
from komira_scan_source.avro_source import AvroSource
from komira_scan_source.csv_source import CsvSource
from komira_scan_source.json_source import JsonSource
from komira_scan_source.source_variant import SourceVariant
from komira_avro import decode_ocf_header, ResolutionTable
from komira_csv.csv_options import CsvReadOptions, QUOTE_STYLE_TAG_RFC4180
from komira_csv.reader import read_csv_bytes_to_schema_dynamic
from komira_jsonl.schema_inference import infer_jsonl_schema
from komira_parquet_codec.text_decompress import (
    is_compressed_text_path, read_text_source_to_heap_buffer,
)

from .sql_ast import FromRelation, TvfOptions, TVF_CSV, TVF_JSON, TVF_AVRO


# Bytes of JSONL prefix handed to the record-shape inferrer (256 KiB, the same
# bound the CSV inferrer caps itself at), snapped back to the last complete line
# so a truncated record never reaches inference.
comptime _JSONL_SCHEMA_SAMPLE_PREFIX_BYTES: Int = 256 * 1024


def _csv_read_options(imm opts: TvfOptions) raises -> CsvReadOptions:
    """`TvfOptions` -> the CSV chassis' own options. Only the two fields that
    change what the header/sample inference SEES are threaded; `all_varchar` is
    applied to the resulting schema instead (see the module note).

    `tvf_relation_scan` stamps the same `delimiter` and `has_header` on the
    `CsvSource` of the scan leaf, so the reader parses the file with the dialect
    the schema was inferred under. A `|`-delimited file bound with the default
    dialect would infer ONE column named `id|amt|name`; a header-less file read
    with `has_header` True would lose its first row to the header."""
    var o = CsvReadOptions()
    o.quote_style_tag = QUOTE_STYLE_TAG_RFC4180
    o.has_header = opts.has_header
    o.delimiter = opts.delimiter
    return o^


def _all_varchar_schema(imm inferred: Schema) raises -> Schema:
    """The same column NAMES, every column typed STRING — the `all_varchar=true`
    schema. Nullability is preserved from the inferred field so an empty cell
    still reads as NULL."""
    var sb = SchemaBuilder()
    for i in range(inferred.num_columns()):
        var f = inferred.field_at_unchecked(i)
        sb.add_field(Field(f.name, ArrowType.STRING, f.nullable))
    return sb.build()


def csv_tvf_schema(path: String, imm opts: TvfOptions) raises -> Schema:
    """Infer the schema of a `read_csv('path', ...)` relation.

    Reads a bounded prefix ONLY. An uncompressed path is mmap'd (pages are
    faulted in on touch); a compressed one is fully decompressed first, because
    the whole-file codecs offer no bounded form."""
    var o = _csv_read_options(opts)
    var inferred: Schema
    if is_compressed_text_path(path):
        var buf = read_text_source_to_heap_buffer(path)
        var span = buf.view_range_ro(0, buf.len()).into_span()
        inferred = read_csv_bytes_to_schema_dynamic(span, o)
        _ = buf^
    else:
        var mbuf = read_chunked(path)
        var mspan = mbuf.view_range_ro(0, mbuf.len()).into_span()
        inferred = read_csv_bytes_to_schema_dynamic(mspan, o)
        _ = mbuf^
    if inferred.num_columns() == 0:
        raise Error(
            "SQL bind error: read_csv('" + path + "') inferred ZERO columns —"
            + " the file is empty, or its header row could not be scanned"
        )
    if opts.all_varchar:
        return _all_varchar_schema(inferred)
    return inferred^


def _jsonl_prefix_end(imm span: Span[UInt8, _]) -> Int:
    """The end offset of the inference prefix: at most
    `_JSONL_SCHEMA_SAMPLE_PREFIX_BYTES`, snapped back to the last newline so the
    final record in the sample is complete."""
    var n = len(span)
    if n <= _JSONL_SCHEMA_SAMPLE_PREFIX_BYTES:
        return n
    var snap = _JSONL_SCHEMA_SAMPLE_PREFIX_BYTES
    while snap > 0 and span[snap - 1] != UInt8(0x0A):
        snap = snap - 1
    if snap > 0:
        return snap
    return _JSONL_SCHEMA_SAMPLE_PREFIX_BYTES


def json_tvf_schema(path: String) raises -> Schema:
    """Infer the schema of a `read_json('path', format='newline_delimited')`
    relation from a bounded leading-record prefix."""
    var inferred: Schema
    if is_compressed_text_path(path):
        var buf = read_text_source_to_heap_buffer(path)
        var full = buf.view_range_ro(0, buf.len()).into_span()
        inferred = infer_jsonl_schema(full[0:_jsonl_prefix_end(full)])
        _ = buf^
    else:
        var mbuf = read_chunked(path)
        var mfull = mbuf.view_range_ro(0, mbuf.len()).into_span()
        inferred = infer_jsonl_schema(mfull[0:_jsonl_prefix_end(mfull)])
        _ = mbuf^
    if inferred.num_columns() == 0:
        raise Error(
            "SQL bind error: read_json('" + path + "') inferred ZERO columns —"
            + " the file is empty, or its leading records are not"
            + " newline-delimited JSON objects"
        )
    return inferred^


def avro_tvf_schema(path: String) raises -> Schema:
    """The bind-time schema of `read_avro('path')`, read from the OCF CONTAINER
    HEADER — no row decode, no inference, no sampling.

    The derivation is `read_chunked -> decode_ocf_header -> parse_schema ->
    ResolutionTable.identity(..).out_schema`. `read_chunked` maps the file
    (mmap) rather than reading it, so only the leading header pages are
    touched: bind pays an mmap plus a few page faults, not a copy of the file.

    ⛔ A NON-RECORD ROOT IS REFUSED: `ResolutionTable.identity` raises on an
    OCF whose writer schema root is not a record."""
    var src_buf = read_chunked(path)
    var full = src_buf.view_range_ro(0, src_buf.len()).into_span()
    var header = decode_ocf_header(full)
    var avro_schema = header.parse_schema()
    var table = ResolutionTable.identity(avro_schema)
    return table.out_schema.copy()


def tvf_relation_schema(imm rel: FromRelation) raises -> Schema:
    """The bind-time schema of a non-footer TVF relation (CSV / JSONL / AVRO).

    Avro is in this set because of the LEAF IT LOWERS TO (`SOURCE_KIND_ROW`),
    not because it lacks a self-describing schema — an OCF carries one in its
    container header. The CSV/JSONL arms infer; the avro arm READS."""
    var path = rel.tvf_path.value()
    if rel.tvf_kind == TVF_CSV:
        return csv_tvf_schema(path, rel.tvf_opts)
    if rel.tvf_kind == TVF_AVRO:
        return avro_tvf_schema(path)
    return json_tvf_schema(path)


def tvf_relation_scan(imm rel: FromRelation) raises -> LogicalPlan:
    """The LAZY scan leaf of a non-footer TVF relation (CSV / JSONL / AVRO).

    ALL THREE arms build a binding-backed `SourceVariant` and go through
    `scan_from_source`. Each carries `source_kind == SOURCE_KIND_ROW`, DECLARED
    by its kind (`komira.csv` / `komira.json` / `komira.avro`) rather than
    threaded by this caller.

    ⚠ THE CSV ARM CALLS `scan_from_source` DIRECTLY AND NOT
    `LogicalPlan.scan(path, SOURCE_CSV, schema)`. It has DIALECT OPTIONS to
    carry, and the positional factory's signature has nowhere to put them: it
    would build a `CsvSource` with the DEFAULT delimiter and header flag, so
    `read_csv('f', delim='|')` and `read_csv('f')` would produce two different
    SCHEMAS with one plan-compile cache key — a silent wrong ANSWER: the second
    query would be served the first one's compiled plan. `has_header` is the
    sharper of the two — it decides whether row 0 is DATA, so the row COUNT
    differs.

    ⚠ EVERY ARM STATS THE FILE FOR ITS MTIME (`FileIdentity.stat_path`). The
    source kinds declare SNAPSHOT_PINNED with the mtime AS the token, so a
    leaf built with `mtime_ns=0` claims a pin it does not have. Never raises — a
    failed stat yields 0, which is the honest "no pin available"."""
    var path = rel.tvf_path.value()
    if rel.tvf_kind == TVF_AVRO:
        return _avro_tvf_scan(path)
    if rel.tvf_kind == TVF_CSV:
        var o = _csv_read_options(rel.tvf_opts)
        var schema = csv_tvf_schema(path, rel.tvf_opts)
        var cs = CsvSource(
            String(path),
            schema.copy(),
            mtime_ns=UInt64(FileIdentity.stat_path(String(path)).mtime_ns),
            quote_style_tag=Int(o.quote_style_tag),
            delimiter=o.delimiter,
            has_header=o.has_header,
        )
        return LogicalPlan.scan_from_source(SourceVariant(cs^), schema^)
    var jschema = json_tvf_schema(path)
    var js = JsonSource(
        String(path),
        jschema.copy(),
        mtime_ns=UInt64(FileIdentity.stat_path(String(path)).mtime_ns),
    )
    var sv = SourceVariant(js^)
    return LogicalPlan.scan_from_source(sv^, jschema^)


def _avro_tvf_scan(path: String) raises -> LogicalPlan:
    """The LAZY `SOURCE_KIND_ROW` scan leaf of `read_avro('path')`.

    Same shape as the CSV/JSONL arms above: a binding-backed `SourceVariant`
    through `scan_from_source`, with `komira.avro` DECLARING
    `orientation = ROW` rather than this caller threading it.

    It stats the file for its mtime, as the CSV and JSONL arms do:
    `avro_scan_descriptor()` declares `snapshot_policy=SNAPSHOT_PINNED`, and
    `AvroSource.fingerprint()` folds the mtime, so a leaf built with
    `mtime_ns=0` would claim a snapshot pin it does not hold, and two reads of
    the SAME path across a REWRITE would share a plan-compile cache key."""
    var schema = avro_tvf_schema(path)
    var av = AvroSource(
        String(path),
        schema.copy(),
        mtime_ns=UInt64(FileIdentity.stat_path(String(path)).mtime_ns),
    )
    return LogicalPlan.scan_from_source(SourceVariant(av^), schema^)
