# =============================================================================
# source_orc -- SOURCE_ORC, one local ORC file read as morsels
# =============================================================================
#
# `build_orc_source` maps the file the spec names into memory once, reads the
# columns the spec's schema names from it through `orc` and serves the batch
# as a `BatchSource`. The spec's columns are matched to the file's by name (the
# first file column of that name), decoded in the spec's order, and a column
# the file lacks, or holds at a type other than the one the plan was bound at,
# is refused naming the column. A spec of no column (what a count(*) reads) is
# the file's row count alone, taken from its footer with no column decoded.
# The file's codec is read from its footer; no option names it.
#
# A file of no row is one empty batch at the spec's schema. Any failure names
# the file.

from arrow.schema import RecordBatch, Schema
from arrow_ipc.chunked_read import read_chunked
from column_kernels.compiler_helpers import empty_batch_like_schema
from containers.slab import Slab
from orc import read_orc_bytes_projected, read_orc_bytes_schema, read_orc_tail
from physical_plan.physical_plan import SourceSpecPod

from .source_batch import BatchSource


def _projection(
    ref spec: SourceSpecPod, file_schema: Schema
) raises -> List[Int]:
    """The file's column index of each column of the spec, in the spec's
    order."""
    var out = List[Int]()
    ref wanted = spec.orc_schema
    for i in range(wanted.num_columns()):
        var name = wanted.field_name(i)
        var at = -1
        for j in range(file_schema.num_columns()):
            if file_schema.field_name(j) == name:
                at = j
                break
        if at < 0:
            raise Error("the file has no column '" + name + "'")
        if file_schema.field_arrow_type(at) != wanted.field_arrow_type(i):
            raise Error(
                "column '"
                + name
                + "' is bound at another type than the file holds"
            )
        out.append(at)
    return out^


def _read(ref spec: SourceSpecPod) raises -> RecordBatch:
    var buf = read_chunked(spec.orc_path)
    var bytes = buf.view_range_ro(0, buf.len()).into_span()
    var batch: RecordBatch
    if spec.orc_schema.num_columns() == 0:
        batch = RecordBatch.count_only(
            Int(read_orc_tail(bytes).footer.number_of_rows)
        )
        batch.schema = spec.orc_schema.copy()
    else:
        var projection = _projection(spec, read_orc_bytes_schema(bytes))
        batch = read_orc_bytes_projected(bytes, projection)
    _ = buf^
    return batch^


def build_orc_source(
    ref spec: SourceSpecPod, morsel_rows: Int
) raises -> BatchSource:
    """The morsels of the ORC file `spec` names, its columns read at the
    spec's schema."""
    if spec.orc_path == "":
        raise Error("pipeline_exec: an ORC source names no path")
    var batch: RecordBatch
    try:
        batch = _read(spec)
    except e:
        raise Error(
            "pipeline_exec: the ORC file '"
            + spec.orc_path
            + "' cannot be read: "
            + String(e)
        )
    var batches = Slab[RecordBatch]()
    if batch.num_rows() == 0:
        batches.append(empty_batch_like_schema(spec.orc_schema))
    else:
        batches.append(batch^)
    return BatchSource(batches^, morsel_rows)
