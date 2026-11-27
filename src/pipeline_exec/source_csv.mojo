# =============================================================================
# source_csv -- SOURCE_CSV, one local CSV file decoded at its bound schema
# =============================================================================
#
# `build_csv_source` reads the file a SOURCE_CSV spec names (decompressing a
# `.csv.gz`, `.csv.zst` or `.csv.lz4` by its extension), decodes it with the
# spec's dialect AT THE COLUMN TYPES THE PLAN BOUND IT AT, and serves the
# result as a resident batch (`BatchSource`): morsels of `morsel_rows` rows
# claimed by the workers from one cursor.
#
# The types are declared, not inferred again: the binder inferred them from a
# prefix of the file, and a second inference over the whole file could answer
# another type (a column of `0001` bound VARCHAR by `all_varchar` would come
# back INT64 1). The reader parses each cell at the declared type instead.
#
# The file is checked against the plan: the reader refuses a file whose column
# count is not the bound one, and this source refuses one whose column names
# are not the bound ones (CSV_SOURCE_SCHEMA_MISMATCH), so a file rewritten
# between bind and run is an error, never another answer.
#
# The CSV reader decodes a whole file at once, so the file is read before the
# first morsel; the source does not stream.

from arrow.schema import RecordBatch
from csv.csv_options import CsvReadOptions
from csv.reader import read_csv_bytes_to_batch_dynamic
from parquet_codec.text_decompress import read_text_source_to_heap_buffer
from physical_plan.physical_plan import SourceSpecPod

from .source_batch import BatchSource


comptime CSV_SOURCE_SCHEMA_MISMATCH: StaticString = "CSV_SOURCE_SCHEMA_MISMATCH"
"""The token of the refusal of a file whose columns are not the ones the plan
bound it at, or of a spec whose column names and types do not pair up."""


def csv_read_options(ref spec: SourceSpecPod) -> CsvReadOptions:
    """The reader's options for `spec`: its dialect (with the lines it
    skips) and its bound column
    types, every other option at the reader's default (the binder inferred
    the schema under the same defaults)."""
    var o = CsvReadOptions()
    o.delimiter = spec.csv_spec.delimiter
    o.has_header = spec.csv_spec.has_header
    o.quote_style_tag = spec.csv_spec.quote_style_tag
    o.skip = spec.csv_spec.skip
    o.declared_column_types = spec.csv_spec.column_types.copy()
    return o^


def read_csv_spec(ref spec: SourceSpecPod) raises -> RecordBatch:
    """Every row of the file `spec` names, decoded at its bound types; raises
    by name when the spec names no file or the file's columns are not the
    bound ones."""
    if spec.csv_spec.path.byte_length() == 0:
        raise Error("pipeline_exec: a SOURCE_CSV spec names no file")
    var ncols = len(spec.csv_spec.column_names)
    if ncols == 0 or ncols != len(spec.csv_spec.column_types):
        raise Error(
            String(CSV_SOURCE_SCHEMA_MISMATCH)
            + ": the spec of "
            + spec.csv_spec.path
            + " names "
            + String(ncols)
            + " columns and "
            + String(len(spec.csv_spec.column_types))
            + " types"
        )
    var buf = read_text_source_to_heap_buffer(spec.csv_spec.path)
    var batch = read_csv_bytes_to_batch_dynamic(
        buf.view_range_ro(0, buf.len()).into_span(), csv_read_options(spec)
    )
    _ = buf^
    var got = batch.schema.num_columns()
    for i in range(ncols):
        var name = String("")
        if i < got:
            name = batch.schema.field_name(i)
        if name != spec.csv_spec.column_names[i]:
            raise Error(
                String(CSV_SOURCE_SCHEMA_MISMATCH)
                + ": column "
                + String(i + 1)
                + " of "
                + spec.csv_spec.path
                + " is '"
                + name
                + "', the plan bound '"
                + spec.csv_spec.column_names[i]
                + "'"
            )
    return batch^


def build_csv_source(
    ref spec: SourceSpecPod, morsel_rows: Int
) raises -> BatchSource:
    """The source of a SOURCE_CSV segment: the decoded file in morsels of
    `morsel_rows` rows."""
    return BatchSource(read_csv_spec(spec), morsel_rows)
