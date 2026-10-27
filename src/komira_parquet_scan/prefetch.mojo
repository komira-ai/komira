# =============================================================================
# prefetch — the read-ahead hint for the next row group a worker will decode
# =============================================================================
#
# On a mapped file `ParquetFileReader.advise_prefetch` asks the kernel to
# populate a byte range ahead of the decode. The range must be the chunks the
# scan will decode: advising a column the query does not read populates page
# tables (soft faults, system time) for bytes nobody reads, and because a hint
# changes no value, no row count and no byte of the answer, no value test can
# see it. `incr_prefetch_advise` therefore records the advised byte count.
#
# The mode is the scan's `PREFETCH_MODE_*` (`komira_parquet.scan_copy_trace`):
#   PREFETCH_MODE_PROJ    the chunks of `col_indices` (the projection);
#   PREFETCH_MODE_LEGACY  the row group's first column chunk;
#   PREFETCH_MODE_NONE    nothing.
# An empty `col_indices` under PROJ advises nothing: a scan that decodes no
# column of the next row group has nothing to read ahead.
# =============================================================================

from komira_fs.file_system import FileSystem
from komira_buffer.mmap_region import ADVICE_NOT_ISSUED
from komira_parquet.bytes_decode import _chunk_lo
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.scan_copy_trace import (
    PREFETCH_MODE_LEGACY,
    PREFETCH_MODE_NONE,
    incr_prefetch_advise,
)
from komira_parquet_api.metadata import ColumnChunk, FileMetaData


def prefetch_range_of(chunk: ColumnChunk) -> Tuple[Int, Int]:
    """The `(offset, length)` the hint advises for `chunk`: its first byte
    (the dictionary page when one comes first; an offset of 0 is no page) and
    its compressed size."""
    return (_chunk_lo(chunk), Int(chunk.meta_data.total_compressed_size))


def advise_prefetch_columns[FS: FileSystem](
    file: ParquetFileReader[FS],
    meta: FileMetaData,
    next_rg_idx: Int,
    col_indices: List[Int],
    mode: Int,
):
    """Advise the chunks of `col_indices` (file leaf indices) in row group
    `next_rg_idx` under `mode`. An out-of-range row group or column, an empty
    chunk and an advice that was not issued (no mapping, a range outside the
    file) are skipped and not counted; a failed syscall is counted as issued.
    The hint never fails a scan."""
    if mode == PREFETCH_MODE_NONE:
        return
    if next_rg_idx < 0 or next_rg_idx >= len(meta.row_groups):
        return
    ref next_rg = meta.row_groups[next_rg_idx]
    var n_cols = len(next_rg.columns)
    var advise_set = List[Int]()
    if mode == PREFETCH_MODE_LEGACY:
        advise_set.append(0)
    else:
        for i in range(len(col_indices)):
            advise_set.append(col_indices[i])
    for i in range(len(advise_set)):
        var ci = advise_set[i]
        if ci < 0 or ci >= n_cols:
            continue
        var span = prefetch_range_of(next_rg.columns[ci])
        var n_bytes = span[1]
        if n_bytes <= 0:
            continue
        if file.advise_prefetch(span[0], n_bytes) == ADVICE_NOT_ISSUED:
            continue
        try:
            incr_prefetch_advise(n_bytes)
        except:
            pass  # a diagnostic counter never fails the scan
