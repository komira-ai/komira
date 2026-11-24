# =============================================================================
# source_jsonl -- SOURCE_JSONL, one newline-delimited JSON file read as morsels
# =============================================================================
#
# `build_jsonl_source` reads the file the spec names at the spec's schema
# through `jsonl` and serves the batches it gives as a `BatchSource`. The
# schema is the plan's: the keys it names are read at its types, in its order,
# a key a line lacks reads NULL, and a key it does not name is skipped. The
# file is never inferred here, so a key whose values the plan was not bound
# for is refused by the reader, naming its line.
#
# A plain file is read in chunks of whole lines, one batch per chunk; a file
# whose name ends in a compression suffix (`.jsonl.gz`, `.ndjson.zst`, ...,
# the set the binder decompresses to infer the schema) is decompressed whole
# and read as one batch. A file of no row is one empty batch at the schema.
# Any failure names the file.

from arrow.schema import RecordBatch
from column_kernels.compiler_helpers import empty_batch_like_schema
from containers.slab import Slab
from jsonl.columnar_materializer import materialize_jsonl_to_batch
from jsonl.streaming_source import read_jsonl_streamed_to_batches
from parquet_codec.text_decompress import (
    is_compressed_text_path,
    read_text_source_to_heap_buffer,
)
from physical_plan.physical_plan import SourceSpecPod

from .source_batch import BatchSource


def _read_batches(ref spec: SourceSpecPod) raises -> Slab[RecordBatch]:
    ref path = spec.jsonl_path
    if not is_compressed_text_path(path):
        return read_jsonl_streamed_to_batches(path, spec.jsonl_schema.copy())
    var buf = read_text_source_to_heap_buffer(path)
    var bytes = buf.view_range_ro(0, buf.len()).into_span()
    var batches = Slab[RecordBatch]()
    batches.append(materialize_jsonl_to_batch(bytes, spec.jsonl_schema.copy()))
    _ = buf^
    return batches^


def build_jsonl_source(
    ref spec: SourceSpecPod, morsel_rows: Int
) raises -> BatchSource:
    """The morsels of the JSONL file `spec` names, read at its schema."""
    if spec.jsonl_path == "":
        raise Error("pipeline_exec: a JSONL source names no path")
    var batches: Slab[RecordBatch]
    try:
        batches = _read_batches(spec)
    except e:
        raise Error(
            "pipeline_exec: the JSONL file '"
            + spec.jsonl_path
            + "' cannot be read: "
            + String(e)
        )
    var rows = 0
    for i in range(len(batches)):
        rows += batches[i].num_rows()
    if rows == 0:
        batches = Slab[RecordBatch]()
        batches.append(empty_batch_like_schema(spec.jsonl_schema))
    return BatchSource(batches^, morsel_rows)
