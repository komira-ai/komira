# =============================================================================
# partition_frame — the frame SPEC, kept in its own module so it is a LEAF
# =============================================================================
#
# ⭐ WHY THIS MODULE EXISTS. `plan/expr.mojo` needs exactly ONE name out of
# `partition_expr.mojo` — `PartitionFrame`, stored inline on `WindowFnData`.
# `partition_expr.mojo` also holds `partition_expr_output_field`, which needs
# `arrow.schema`, and `arrow.schema`'s closure is ~50 modules. So that ONE
# import line put fifty modules that `Expr` never names into `Expr`'s
# translation-unit closure.
#
# MEASURED as the komira_core-restricted import closure, seed included:
#
#     closure(expr.mojo)                                       90
#     ... with the `logical_plan` edge cut                     59
#     ... with the `logical_plan` AND `partition_expr` cuts      7
#
# ⚠ CUTTING THIS EDGE ALONE MOVES NOTHING (90 -> 90): `logical_plan` reaches
# `arrow.schema` too, so the mass only leaves when BOTH edges are gone. Do not
# read a zero here as this module being pointless — it is one half of a pair,
# and the pair is what the number responds to.
#
# `PartitionFrame` is a five-scalar POD. It imports NOTHING — not even
# `scalar_value` — which is what makes it safe to sit under `Expr`.
#
# ⚠ `partition_expr.mojo` RE-EXPORTS every name below (facade), so every
# existing `from .partition_expr import PartitionFrame` / `FRAME_*` keeps
# working unchanged. Import from EITHER; prefer this module in new leaf-side
# code and `partition_expr` in code that already needs `PartitionExpr`.
# =============================================================================



# =============================================================================
# Frame units + bounds
# =============================================================================

comptime FRAME_UNITS_ROWS: UInt8 = 0
comptime FRAME_UNITS_RANGE: UInt8 = 1

comptime FRAME_BOUND_UNBOUNDED_PRECEDING: UInt8 = 0
comptime FRAME_BOUND_PRECEDING: UInt8 = 1
comptime FRAME_BOUND_CURRENT_ROW: UInt8 = 2
comptime FRAME_BOUND_FOLLOWING: UInt8 = 3
comptime FRAME_BOUND_UNBOUNDED_FOLLOWING: UInt8 = 4


struct PartitionFrame(Movable, Copyable, Writable):
    """Frame specification for aggregate partition functions.

    Ranking and offset functions ignore
    the frame per SQL semantics.
    """
    var units: UInt8
    var start_tag: UInt8
    var start_offset: Int64
    var end_tag: UInt8
    var end_offset: Int64

    def __init__(out self, units: UInt8, start_tag: UInt8, start_offset: Int64, end_tag: UInt8, end_offset: Int64):
        self.units = units
        self.start_tag = start_tag
        self.start_offset = start_offset
        self.end_tag = end_tag
        self.end_offset = end_offset

    def copy(self) -> Self:
        return Self(self.units, self.start_tag, self.start_offset, self.end_tag, self.end_offset)

    def write_to[W: Writer](self, mut writer: W):
        """`ROWS[<start_tag>:<start_offset>..<end_tag>:<end_offset>]`.

        EVERY field is emitted: a window's render is its plan-compile cache
        key (`LogicalPlan.structural_hash`), so a frame field left out of it
        lets two different frames share one compiled plan.
        """
        if self.units == FRAME_UNITS_ROWS:
            writer.write("ROWS")
        elif self.units == FRAME_UNITS_RANGE:
            writer.write("RANGE")
        else:
            writer.write("UNITS_", Int(self.units))
        writer.write(
            "[", Int(self.start_tag), ":", Int(self.start_offset), "..",
            Int(self.end_tag), ":", Int(self.end_offset), "]",
        )

    @staticmethod
    def default_ordered() -> PartitionFrame:
        """ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW (running aggregate).

        ⛔ THIS IS **NOT** SQL'S DEFAULT FRAME FOR A WINDOW THAT HAS AN
        `ORDER BY`, DESPITE THE NAME. SQL:2003 7.11 makes that default `RANGE`
        — see `running_range()` — and the two differ on PEER ROWS (rows tying
        on the order key), where `ROWS` gives every peer a DIFFERENT running
        value and `RANGE` gives them all the SAME one. Reaching for this
        constructor because you wanted "the default ordered frame" is the
        mistake `running_range()` exists to prevent.

        What this frame legitimately is: the ROWS running frame — what a
        customer gets by WRITING `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT
        ROW`, and the frame-blind placeholder carried by the ranking and offset
        functions (RANK / ROW_NUMBER / LAG / ...), which ignore the frame per
        SQL semantics. Read it as `running_rows()`; it keeps this name for
        its existing callers.
        """
        return PartitionFrame(
            FRAME_UNITS_ROWS,
            FRAME_BOUND_UNBOUNDED_PRECEDING, 0,
            FRAME_BOUND_CURRENT_ROW, 0,
        )

    @staticmethod
    def running_range() -> PartitionFrame:
        """RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW — SQL's DEFAULT
        frame for a window that HAS an `ORDER BY`.

        ⭐ UNDER `RANGE`, "CURRENT ROW" MEANS THE **LAST ROW OF THE CURRENT PEER
        GROUP**, not the current physical row. Every row tying on the order key
        therefore gets the SAME answer. Under `ROWS` it means the physical row,
        so a peer group's members get strictly different running values — which
        is why the two units are not interchangeable and why `default_ordered()`
        (ROWS) is a silent wrong answer for the implicit default.

        ⚠ WITH NO `ORDER BY` THE WHOLE PARTITION IS ONE PEER GROUP, so this
        frame degenerates to the whole partition. That case is spelled
        `default_unordered()` by the binder, and the executor's peer detection
        arrives at the same answer for this frame anyway (an empty order-key
        list yields one peer group per partition) — the two agree rather than
        race.

        ★ HOW THE EXECUTOR SERVES IT: the ordinary per-row incremental kernel,
        followed by a POST-PASS that broadcasts each peer group's LAST value
        across the group (`partition_scan_sink._close_over_peers`). That is
        exact, not an approximation: the ROWS running value AT a peer group's
        last row IS the RANGE value for every member of that group, because
        both name the aggregate over the same prefix.
        """
        return PartitionFrame(
            FRAME_UNITS_RANGE,
            FRAME_BOUND_UNBOUNDED_PRECEDING, 0,
            FRAME_BOUND_CURRENT_ROW, 0,
        )

    @staticmethod
    def default_unordered() -> PartitionFrame:
        """ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING (full partition)."""
        return PartitionFrame(
            FRAME_UNITS_ROWS,
            FRAME_BOUND_UNBOUNDED_PRECEDING, 0,
            FRAME_BOUND_UNBOUNDED_FOLLOWING, 0,
        )

    @always_inline
    def is_full_partition(self) -> Bool:
        return (self.start_tag == FRAME_BOUND_UNBOUNDED_PRECEDING
                and self.end_tag == FRAME_BOUND_UNBOUNDED_FOLLOWING)

    @always_inline
    def is_running(self) -> Bool:
        """UNBOUNDED PRECEDING .. CURRENT ROW — under EITHER unit.

        ⚠ UNITS-BLIND ON PURPOSE. Both the ROWS and
        the RANGE spellings are served by the SAME per-row incremental kernel;
        the RANGE one then takes a peer-closure post-pass. Routing the RANGE
        spelling to `eval_sliding_agg` instead would REFUSE it — that evaluator's
        `_decode_{start,end}_off` raise on RANGE — turning a frame this engine
        can express exactly into an error. Callers that need to tell the two
        apart test `units == FRAME_UNITS_RANGE` alongside this predicate; see
        `partition_scan_sink._eval_partition_expr` and
        `row_capability`/`lower_untyped_row_streaming`, which DECLINE the RANGE
        spelling because the row-streaming stage carries no frame at all.
        """
        return (self.start_tag == FRAME_BOUND_UNBOUNDED_PRECEDING
                and self.end_tag == FRAME_BOUND_CURRENT_ROW)

    @always_inline
    def is_sliding(self) -> Bool:
        """Neither running NOR whole-partition — a frame with at least one bound
        that moves with the current row.

        ⛔ NOT THE EXECUTOR'S ROUTING PREDICATE, AND IT MUST NOT BE USED AS ONE.
        `partition_scan_sink._eval_partition_expr` gates on `not is_running()`.
        Gating on `is_sliding()` sends a WHOLE-PARTITION frame to the RUNNING
        kernel — it is neither sliding nor running-shaped, so the `if` is False
        and control falls through — which is a silent wrong answer. Anything
        that is not the running frame belongs to
        `eval_sliding_agg`."""
        return not self.is_running() and not self.is_full_partition()