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
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.scan_copy_trace import (
    PREFETCH_MODE_LEGACY,
    PREFETCH_MODE_NONE,
    incr_prefetch_advise,
)
from komira_parquet_api.metadata import FileMetaData


def advise_prefetch_columns[FS: FileSystem](
    file: ParquetFileReader[FS],
    meta: FileMetaData,
    next_rg_idx: Int,
    col_indices: List[Int],
    mode: Int,
):
    """Advise the chunks of `col_indices` (file leaf indices) in row group
    `next_rg_idx` under `mode`. An out-of-range row group or column, an empty
    chunk and a declined advice are skipped: the hint never fails a scan."""
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
        ref m = next_rg.columns[ci].meta_data
        var off = m.data_page_offset
        if m.dictionary_page_offset:
            var d = m.dictionary_page_offset.value()
            if d < off:
                off = d
        var n_bytes = Int(m.total_compressed_size)
        if n_bytes <= 0:
            continue
        _ = file.advise_prefetch(Int(off), n_bytes)
        try:
            incr_prefetch_advise(n_bytes)
        except:
            pass  # a diagnostic counter never fails the scan
