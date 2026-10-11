# =============================================================================
# subrg_agg_plan — the read plan of a sub-row-group aggregate
# =============================================================================
#
# A grouped aggregate over a Parquet scan can decode each row group a chunk at
# a time into fixed per-worker buffers and fold each chunk. `SubrgAggPlan` is
# what that decode reads: the projected columns (keys, aggregate inputs and
# filter columns) in the chunk batch's column order, their footer column
# indices and Arrow types, and which of them are the group keys. The band
# producer reads the same plan.
#
# The chunk size: `CHUNK_ROWS` rows keep a worker's fixed code and value
# buffers (`(CHUNK_ROWS + SUBRG_MAX_RUN) * 4` bytes) small enough for the
# allocator's small-span path, so no chunk maps or unmaps memory.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_fs.file_system import FileSystem
from komira_parquet.subrg_column_cursor import SUBRG_MAX_RUN

from .parquet_reader import ParquetReader


comptime CHUNK_ROWS: Int = 30_000
comptime SUBRG_SLOTS: Int = CHUNK_ROWS + SUBRG_MAX_RUN


struct SubrgAggPlan(Copyable, Movable, Deinitable):
    """The resolved read plan of one sub-row-group aggregate.

    Fields:
        proj_names: the projected column names, in chunk batch order.
        reader_col_idx: each projected column's footer leaf index.
        col_arrow_types: each projected column's Arrow type.
        key_proj_idx: the projection indices of the group keys, in key order
            (one for a single key, N for a composite key).
        has_string_key: a group key is a dictionary STRING column.
    """

    var proj_names: List[String]
    var reader_col_idx: List[Int]
    var col_arrow_types: List[ArrowType]
    var key_proj_idx: List[Int]
    var has_string_key: Bool

    def __init__(
        out self,
        var proj_names: List[String],
        var reader_col_idx: List[Int],
        var col_arrow_types: List[ArrowType],
        var key_proj_idx: List[Int],
        has_string_key: Bool = False,
    ):
        self.proj_names = proj_names^
        self.reader_col_idx = reader_col_idx^
        self.col_arrow_types = col_arrow_types^
        self.key_proj_idx = key_proj_idx^
        self.has_string_key = has_string_key

    @always_inline
    def is_key_proj(self, ci: Int) -> Bool:
        """Projection index `ci` is a group key."""
        for k in range(len(self.key_proj_idx)):
            if self.key_proj_idx[k] == ci:
                return True
        return False


def resolve_reader_col_idx[FS: FileSystem](reader: ParquetReader[FS], name: String) -> Int:
    """The footer leaf index of the top-level column `name` of a flat
    schema, or -1."""
    ref sch = reader._meta[].schema
    for i in range(1, len(sch)):
        if sch[i].name == name:
            return i - 1
    return -1
