# =============================================================================
# join_probe_null_mask — ONE probe-side `NULL never matches` decision, built at
# the call site and handed to every single-key inner-join assembly kernel
# =============================================================================
#
# WHY THIS TYPE EXISTS, STATED AS THE FAILURE IT ENDS. `NULL never matches` is
# a semantic of the JOIN, but it was once implemented independently inside
# each kernel that walks a probe key column, and was found MISSING in three
# families at once: `PerfectHashJoin` (both copies of its probe loop), the
# composite-key builder (build AND probe), and the four single-key INNER
# assembly kernels this module serves.
#
# An Arrow NULL carries an UNSPECIFIED value under its cleared validity bit, and
# in practice that value is DType zero. A kernel that reads the value and not the
# bit therefore matches every NULL probe row against a real build key of value 0
# and emits a WRONG EXTRA ROW from an INNER join: no exception, no crash, a
# plausible answer.
#
# AND THE ROUTING BETWEEN THOSE FOUR KERNELS IS A PERFORMANCE HEURISTIC. The
# join probe driver picks between them on scan row count, fan-out, projection
# width and var-len presence — none of which has anything to do with nullability.
# So a per-kernel guard makes the ANSWER a function of the row count: the same
# query on the same data was right or wrong depending on which arm the shape
# happened to select. That is the property this type removes. The mask is built
# ONCE, from the probe key column, at the ONE place that chooses the arm; a
# kernel cannot be routed to without receiving it.
#
# A BYTE PER ROW, NOT THE VALIDITY BITMAP -- deliberately, and the reason is
# the parallel inner probe. The bitmap lives behind
# `PrimitiveArray.validity` as an `Optional[Bitmap]`; carrying it into a
# `run_with_state` State across the fork would need a third origin parameter plus
# hand-rolled bit arithmetic in the task body, for a case in which the previous
# behaviour was a wrong ANSWER. The flags are built ONCE, serially, and ONLY when
# the column actually carries nulls: an all-valid probe (every PK-FK join, i.e.
# every corpus cell) allocates nothing, reads nothing, and pays one predictable
# compare against a register per row.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray


struct ProbeNullMask(Movable):
    """Which probe rows hold a NULL join key, in the form every kernel reads.

    `has_nulls == False` is the overwhelmingly common case and means `valid` is
    EMPTY: it must not be indexed. Every read site therefore short-circuits on
    `has_nulls` first — that is what `excludes` does, and what the parallel task
    bodies spell out by hand so the flag can be hoisted into a register outside
    the morsel loop.
    """

    var has_nulls: Bool
    """True iff the probe key column carried at least one NULL."""

    var valid: List[UInt8]
    """1 = the row's key is VALID, 0 = NULL. EMPTY when `has_nulls` is False."""

    def __init__(
        out self, probe_keys: PrimitiveArray[DType.int64], num_rows: Int
    ) raises:
        """Build the mask for the first `num_rows` rows of `probe_keys`.

        Args:
            probe_keys: The probe-side join key column.
            num_rows: The caller's probe row count.
        """
        # The gate is the CACHED count, matching the three strategy kernels
        # (`HashJoinBuilder.probe_inner_into` and siblings) exactly, so a probe
        # that takes one arm and a probe that takes another cannot disagree
        # about whether the column has nulls at all. The composite path's
        # stricter `validity`-presence gate is a different design for a
        # different reason.
        self.has_nulls = probe_keys.null_count != 0
        self.valid = List[UInt8]()
        if not self.has_nulls:
            return
        self.valid = List[UInt8](capacity=num_rows)
        # `num_rows` is the caller's row count and `probe_keys.length` the
        # column's; they agree on every production path, and the min keeps
        # `is_null` (which RAISES out of range) total if one ever drifts. Rows
        # past the column's end are treated as VALID — byte-identical to the
        # pre-guard behaviour for that (already-broken) shape, so this guard
        # cannot itself become a new way to DROP rows.
        var n_flagged = min(num_rows, probe_keys.length)
        for i in range(n_flagged):
            self.valid.append(UInt8(0) if probe_keys.is_null(i) else UInt8(1))
        for _ in range(n_flagged, num_rows):
            self.valid.append(UInt8(1))

    @always_inline
    def excludes(self, i: Int) -> Bool:
        """True iff probe row `i` must emit NO inner-join output.

        The whole guard in one call, for the serial kernels. `has_nulls` is
        tested first and short-circuits, so an all-valid probe never indexes the
        empty `valid` list.
        """
        return self.has_nulls and self.valid[i] == 0

    @always_inline
    def is_null_at(self, i: Int) -> Bool:
        """The unguarded half of `excludes`.

        ⚠ ONLY VALID WHEN `has_nulls` IS TRUE — indexes `valid` directly. It
        exists for the parallel task bodies, which hoist `has_nulls` out of the
        `State` into a register once per task rather than reloading it through
        the state pointer on every row.
        """
        return self.valid[i] == 0

