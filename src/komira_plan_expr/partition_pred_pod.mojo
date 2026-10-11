# =============================================================================
# komira_plan_expr.partition_pred_pod — the core packages POD mirror of the
# komira_async partition predicate.
# =============================================================================
#
# WHY A MIRROR (the layering rule):
#   `PartitionPredicate` / `PartitionConstraint` live in
#   `komira_async.fs.pruned_hive_discovery`. The physical-plan node that
#   reaches the materialize site — `ParquetSourceData`
#   (`komira_physical_plan.physical_plan`) — carries the predicate by value
#   (the dir-scan-Hive discriminant). But `komira_async` DEPENDS ON
#   the core packages, so `ParquetSourceData` CANNOT carry a `komira_async` type
#   (that would invert / cycle the dep graph). We therefore need a
#   the core packages-resident STRUCTURAL mirror of the predicate. The
#   `PartitionPredicatePod <-> PartitionPredicate` bridge lives in
#   `komira_parquet` (which deps BOTH core and async) — see its
#   `partition_pred_bridge` module.
#
# OP-CODE IDENTITY: the PART_OP_* byte constants below are
# BYTE-IDENTICAL to the `_OP_*` constants in
# `komira_async.fs.pruned_hive_discovery`
# (EQ=0, IN=1, LT=2, LE=3, GT=4, GE=5, NE=6, OTHER=7). The bridge is therefore
# a trivial per-field copy with an Int<->UInt8 cast on `op` only — NO remap.
#
# Pointer discipline:
#   * Copyable + Movable + Deinitable. Owns only String + UInt8 +
#     List[String] + ArrowType. No OwnedPointer, no ArcPointer, no wildcard
#     origin, no UnsafePointer in any signature.
#   * This POD is NEVER an element of a byte-slab — it sits on the plan node
#     (`ParquetSourceData`) BY VALUE — so the stale-bytes hazard of a List
#     inside a byte slab does not apply. (The async original's per-file
#     partition values ARE slab elements and are safe by a different
#     mechanism — arena-index handles. Both shapes are legal; they solve
#     different problems.)
# =============================================================================

from komira_arrow.arrow_types import ArrowType


# Op codes — BYTE-IDENTICAL to the `_OP_*` constants in
# `komira_async.fs.pruned_hive_discovery`. The bridge relies
# on these matching EXACTLY so the only transform is the Int<->UInt8 cast.
comptime PART_OP_EQ: UInt8 = 0
comptime PART_OP_IN: UInt8 = 1
comptime PART_OP_LT: UInt8 = 2
comptime PART_OP_LE: UInt8 = 3
comptime PART_OP_GT: UInt8 = 4
comptime PART_OP_GE: UInt8 = 5
comptime PART_OP_NE: UInt8 = 6
# OTHER: an opaque non-enumerable, non-comparison predicate (OR-across-cols,
# function-wrapped). Carries zero values; the fold keeps the file.
comptime PART_OP_OTHER: UInt8 = 7


@fieldwise_init
struct PartitionConstraintPod(Copyable, Movable, Deinitable):
    """The core packages mirror of komira_async `PartitionConstraint`
    (`pruned_hive_discovery`), field-for-field.

    Owns only `String` + `UInt8` + `List[String]` + `ArrowType`.
    The `List[String]` of canonical-text constants is safe because this
    POD is NEVER stored inside a byte-slab element — it lives on the plan node
    (`ParquetSourceData`) by value.

    Field contract (mirrors the async original):
      * `col`        — partition column name.
      * `op`         — one of `PART_OP_*` (UInt8; the async original uses Int —
                       loss-free, the codes are tiny constants; the bridge casts).
      * `values`     — canonical-text constants:
                         EQ / LT / LE / GT / GE / NE -> exactly 1 value;
                         IN -> N values (N >= 1);
                         OTHER -> 0 values (opaque).
      * `arrow_type` — the declared/inferred partition-col type.
    """

    var col: String
    var op: UInt8
    var values: List[String]
    var arrow_type: ArrowType

    @staticmethod
    def eq(
        col: String, value: String, arrow_type: ArrowType
    ) -> PartitionConstraintPod:
        var vs = List[String]()
        vs.append(value)
        return PartitionConstraintPod(
            col=col, op=PART_OP_EQ, values=vs^, arrow_type=arrow_type
        )

    @staticmethod
    def in_list(
        col: String, var values: List[String], arrow_type: ArrowType
    ) -> PartitionConstraintPod:
        return PartitionConstraintPod(
            col=col, op=PART_OP_IN, values=values^, arrow_type=arrow_type
        )

    @staticmethod
    def compare(
        col: String, op: UInt8, value: String, arrow_type: ArrowType
    ) -> PartitionConstraintPod:
        """A range/inequality constraint (`op` in LT/LE/GT/GE/NE)."""
        var vs = List[String]()
        vs.append(value)
        return PartitionConstraintPod(
            col=col, op=op, values=vs^, arrow_type=arrow_type
        )

    @staticmethod
    def other(col: String) -> PartitionConstraintPod:
        """An opaque non-enumerable constraint (OR / function-wrapped)."""
        return PartitionConstraintPod(
            col=col,
            op=PART_OP_OTHER,
            values=List[String](),
            arrow_type=ArrowType.STRING,
        )

    @always_inline
    def is_equality(self) -> Bool:
        return self.op == PART_OP_EQ

    @always_inline
    def is_enumerable(self) -> Bool:
        """EQ or IN — pinnable to discrete targeted prefix(es)."""
        return self.op == PART_OP_EQ or self.op == PART_OP_IN


@fieldwise_init
struct PartitionPredicatePod(Copyable, Movable, Deinitable):
    """The core packages mirror of komira_async `PartitionPredicate`
    (`pruned_hive_discovery`) — a conjunction (AND) of per-column
    constraints.

    An EMPTY conjunction prunes nothing (the degenerate un-filtered Hive read;
    see `PartitionPredicatePod.empty()`). On the dir-scan Hive scan
    node, `hive_predicate is Some(empty())` still surfaces partition columns
    while pruning no files.
    """

    var constraints: List[PartitionConstraintPod]

    @staticmethod
    def empty() -> PartitionPredicatePod:
        return PartitionPredicatePod(constraints=List[PartitionConstraintPod]())

    @always_inline
    def num_constraints(self) -> Int:
        return len(self.constraints)

    def constraint_index_for(self, col: String) -> Int:
        """The index of the first constraint on `col`, or -1 if none. Returns
        an index (not an `Optional[PartitionConstraintPod]`) so the caller reads
        the constraint by `ref` — `PartitionConstraintPod` owns a `List[String]`
        and is not `ImplicitlyCopyable`, so returning it by value would force an
        implicit copy the type does not allow. Mirrors the async original
        (`pruned_hive_discovery`)."""
        for i in range(len(self.constraints)):
            if self.constraints[i].col == col:
                return i
        return -1
