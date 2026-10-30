# =============================================================================
# finalized_hash_index -- `FinalizedHashIndex`, a finished single-INT64-key hash
# index with a matched-row bitmap, shared read-only by every worker's operator
# =============================================================================
#
# The build side of a join, finished: the chained table over its key column
# (`komira_op_join_build.join.HashJoinBuilder`), the build batch the table
# indexes, and one MATCHED flag per build row. Workers share it through an
# `ArcPointer` and only read it, except for the flags, which they set: a probe
# that finds build row r sets flag r (`mark_matched`). After every worker has
# finished, `collect_marked_indices` lists the build rows whose flag is set
# (a right SEMI join's rows) or clear (a right ANTI join's rows), in ascending
# row order, each row once.
#
# THE FLAGS ARE RELAXED ATOMICS. Two workers can match the same build row at
# the same time, so the same flag can be written from two threads. Every write
# stores 1 and nothing clears a flag, so the order of writes does not matter,
# but a plain store from two threads at once is still a data race; a relaxed
# atomic store is the same machine store without the race. The read after the
# workers have joined sees every write (the join is the synchronisation).
#
# A NULL build key is recorded by the builder but never linked into a bucket,
# so no probe can reach its row and its flag stays clear: a right SEMI join
# drops it and a right ANTI join keeps it, as DuckDB does.
# =============================================================================

from std.atomic import Ordering

from komira_arrow.record_batch import RecordBatch
from komira_atomic_alias import AtomicU8
from komira_collections.slab import Slab
from komira_op_join_build.join import HashJoinBuilder


struct FinalizedHashIndex(Movable):
    """A finished hash index over the build side's key, the build batch it
    indexes, and a matched flag per build row (all clear at construction).

    `builder` and `build_batch` are read-only once the index is shared. The
    flags are written through `mark_matched` from any worker; see the module
    header for why that is sound.
    """

    var builder: HashJoinBuilder
    var build_batch: RecordBatch
    var _matched: Slab[AtomicU8]
    var _num_rows: Int

    def __init__(
        out self,
        var builder: HashJoinBuilder,
        var build_batch: RecordBatch,
    ) raises:
        """An index over `build_batch`, every row unmatched.

        Args:
            builder: The table built over `build_batch`'s key column.
            build_batch: The build side; row r of it is the table's build row r.

        Raises:
            If the table and the batch disagree on the number of build rows
            (the flags are indexed by build row, so a mismatch would flag
            the wrong rows).
        """
        var n = build_batch.num_rows()
        if builder.num_build != n:
            raise Error(
                "FinalizedHashIndex: the table holds "
                + String(builder.num_build)
                + " build rows but the build batch has "
                + String(n)
            )
        self.builder = builder^
        self.build_batch = build_batch^
        # All-zero bytes are a valid, clear AtomicU8.
        self._matched = Slab[AtomicU8].create_prefilled(n)
        self._num_rows = n

    @always_inline
    def num_rows(self) -> Int:
        """The number of build rows, which is the number of flags."""
        return self._num_rows

    @always_inline
    def mark_matched(self, build_row: Int):
        """Set build row `build_row`'s flag. Callable from any worker at the
        same time as any other; out-of-range rows are ignored."""
        if build_row < 0 or build_row >= self._num_rows:
            return
        # SAFETY (get_mut_interior): the slab is sized once in `__init__` and
        # never grows, so the slot stays where it is for the index's life; the
        # slot is an atomic, so two workers writing it at once is not a race.
        self._matched.get_mut_interior(build_row).store[
            ordering = Ordering.RELAXED
        ](UInt8(1))

    @always_inline
    def is_matched(self, build_row: Int) raises -> Bool:
        """Whether build row `build_row`'s flag is set."""
        if build_row < 0 or build_row >= self._num_rows:
            raise Error(
                "FinalizedHashIndex.is_matched: row "
                + String(build_row)
                + " out of range [0, "
                + String(self._num_rows)
                + ")"
            )
        # SAFETY (get_mut_interior): a load through the atomic; see
        # `mark_matched` for why the slot is stable.
        return self._matched.get_mut_interior(build_row).load[
            ordering = Ordering.RELAXED
        ]() != 0

    def collect_marked_indices(self, want_matched: Bool) raises -> List[Int]:
        """The build rows whose flag is set (`want_matched`) or clear (not),
        ascending, each once. Call it after every marking worker has finished.
        """
        var out = List[Int]()
        for i in range(self._num_rows):
            if self.is_matched(i) == want_matched:
                out.append(i)
        return out^
