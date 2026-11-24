# =============================================================================
# source_iceberg -- SOURCE_ICEBERG, the planned files of one Iceberg snapshot
# =============================================================================
#
# `build_iceberg_source` reads the files a SOURCE_ICEBERG spec names with
# `iceberg_scan.scan_reader.read_iceberg_scan` (every data file at the spec's
# bound columns, rows removed by the position and equality deletes that apply
# to their file) and serves the result as a resident batch (`BatchSource`):
# morsels of `morsel_rows` rows claimed by the workers from one cursor.
#
# The files were chosen at lowering by the host's planner and are the whole
# scan: this source does not look at table metadata. The scan's filter and
# projection are operators of the segment, not part of the spec.
#
# The reader decodes whole files, so the files are read before the first
# morsel; the source does not stream.

from arrow.schema import RecordBatch
from iceberg_scan.scan_reader import read_iceberg_scan
from physical_plan.physical_plan import SourceSpecPod

from .source_batch import BatchSource


def read_iceberg_spec(ref spec: SourceSpecPod) raises -> RecordBatch:
    """Every surviving row of the files `spec` names, at its bound columns."""
    return read_iceberg_scan(spec.iceberg_spec)


def build_iceberg_source(
    ref spec: SourceSpecPod, morsel_rows: Int
) raises -> BatchSource:
    """The source of a SOURCE_ICEBERG segment: the rows of its files in morsels
    of `morsel_rows` rows."""
    return BatchSource(read_iceberg_spec(spec), morsel_rows)
