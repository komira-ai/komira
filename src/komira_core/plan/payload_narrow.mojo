# =============================================================================
# komira_core.plan.payload_narrow — the JOIN-PAYLOAD NARROWING spec
# =============================================================================
#
# WHAT THIS IS. The plan-resident description of "carry this integer column in
# fewer bytes than its declared type, with `base` added back at the boundary".
# It is the Komira analogue of DuckDB's `compressed_materialization` frame-of-
# reference rewrite (`src/optimizer/compressed_materialization/
# compress_comparison_join.cpp`): a column whose statistics prove
# `[min, max] ⊂ [base, base + 2^(8*target_bytes) - 1]` is physically stored as
# `value - base` in an unsigned integer of `target_bytes`, and reconstructed as
# `Int64(stored) + base` before anything outside the join can observe it.
#
# ⛔ WHY THIS IS A POD ON THE PLAN AND NOT A `Project(CAST(...))` NODE.
# DuckDB expresses the same rewrite as two projections — compress on the join's
# children, decompress above the join. That spelling is UNAVAILABLE here, and
# not for a stylistic reason: the fused parquet-on-parquet join leaf recognises
# its sides as `PLAN_PROJECT? -> PLAN_FILTER? -> PLAN_SCAN(parquet)` where the
# project must be PURE COL-REF (`join_node_exec._pure_colref_project_outputs`
# returns None for a cast, "those change the column VALUES and must NOT be
# folded into the scan projection"), and it declines an OFF-ROOT join — a join
# feeding anything, including a decompress Project. So a compress Project
# BELOW and a decompress Project ABOVE each independently take the join OFF the
# very route this lever exists to speed up. The rewrite therefore rides as DATA
# on the nodes the leaf already reads, and the leaf performs both halves
# internally, where the narrow representation is created and destroyed inside
# one function and cannot escape.
#
# ⚠ THE SPEC IS ADVISORY. A carrier that reaches a route with no narrowing
# implementation is IGNORED, never half-applied: `base` is only ever added back
# by the same code that subtracted it.
#
# POINTER DISCIPLINE: Copyable + Movable,
# owns only `String` + `UInt8` + `Int64`. No OwnedPointer, no ArcPointer, no
# UnsafePointer in any signature. It sits on `ScanData` / `ParquetSourceData`
# BY VALUE, never as a byte-slab element, so the stale-bytes hazard of a
# List stored inside a byte slab does not apply.
# =============================================================================

from ..arrow.arrow_types import ArrowType


# The widths a spec may name. `PAYLOAD_NARROW_NONE` is the REFUSAL — it is not
# a width, and no spec is ever constructed carrying it (`choose_narrow_width`
# returns it to mean "do not narrow this column").
comptime PAYLOAD_NARROW_NONE: UInt8 = 0
comptime PAYLOAD_NARROW_1B: UInt8 = 1
comptime PAYLOAD_NARROW_2B: UInt8 = 2
comptime PAYLOAD_NARROW_4B: UInt8 = 4

# The guard rail on the range arithmetic. `max - min` is computed in Int64, so
# the two endpoints must be far enough inside the Int64 domain that the
# subtraction cannot overflow. 2^62 leaves a full bit of headroom on each side
# and is astronomically outside any real column domain — a column that trips
# this is REFUSED rather than narrowed, which is the safe direction.
comptime _NARROW_SAFE_ABS: Int64 = Int64(1) << 62


struct PayloadNarrowSpec(Movable, Copyable):
    """One column's narrowing instruction.

    Fields:
        column_name: the column this applies to, by NAME. Positional indices
            are not usable here — the spec is stamped on a SCAN and read after
            projection pushdown has re-ordered and pruned the column set.
        target_bytes: 1, 2 or 4. Never 0 and never 8 — a spec that would not
            narrow is not constructed.
        base: the frame-of-reference origin. Stored value is `v - base`;
            reconstruction is `Int64(stored) + base`. Zero is the common case
            and callers may take a no-subtract fast path on it, but the field
            is always meaningful.
    """

    var column_name: String
    var target_bytes: UInt8
    var base: Int64

    def __init__(out self, var column_name: String, target_bytes: UInt8, base: Int64):
        self.column_name = column_name^
        self.target_bytes = target_bytes
        self.base = base

    def copy(self) -> Self:
        return Self(self.column_name.copy(), self.target_bytes, self.base)

    @always_inline
    def narrow_arrow_type(self) -> ArrowType:
        """The Arrow type the narrowed column carries.

        UNSIGNED, deliberately. The stored value is `v - base ∈ [0, span]`, so
        an unsigned type of `target_bytes` admits a span up to `2^(8*B) - 1`
        where the signed one admits only half of it — `build_val`'s span of
        9 998 fits either, but `[0, 40000]` fits UINT16 and not INT16, and a
        signed choice would silently refuse half the columns this rule exists
        to serve.
        """
        if self.target_bytes == PAYLOAD_NARROW_1B:
            return ArrowType.UINT8
        if self.target_bytes == PAYLOAD_NARROW_2B:
            return ArrowType.UINT16
        return ArrowType.UINT32

    def __str__(self) -> String:
        return (
            String("narrow(")
            + self.column_name
            + String(", ")
            + String(Int(self.target_bytes))
            + String("B, base=")
            + String(self.base)
            + String(")")
        )


def choose_narrow_width(min_value: Int64, max_value: Int64) -> UInt8:
    """The width ladder: the NARROWEST unsigned width that holds `max - min`.

    ⭐ NARROWEST, NOT FIRST-THAT-FITS. Every step down in payload width
    measurably shortened a join's wall time (8→4, 8→2 and 8→1 bytes each
    improved on the last), so stopping at 4 bytes when 2 bytes is provable
    leaves time on the table.

    Returns `PAYLOAD_NARROW_NONE` — meaning DO NOT NARROW — for every input the
    ladder cannot prove:
      * `max < min` (a degenerate or unpopulated fold),
      * an endpoint outside ±2^62 (the subtraction guard),
      * a span that needs all 8 bytes.
    """
    if max_value < min_value:
        return PAYLOAD_NARROW_NONE
    if min_value < -_NARROW_SAFE_ABS or max_value > _NARROW_SAFE_ABS:
        return PAYLOAD_NARROW_NONE
    var span = max_value - min_value
    if span <= 255:
        return PAYLOAD_NARROW_1B
    if span <= 65535:
        return PAYLOAD_NARROW_2B
    if span <= 4294967295:
        return PAYLOAD_NARROW_4B
    return PAYLOAD_NARROW_NONE


def find_narrow_spec(
    imm specs: List[PayloadNarrowSpec], imm name: String
) -> Int:
    """Index of the spec naming `name`, or -1. Linear over a list that is at
    most the width of one scan's projection."""
    for i in range(len(specs)):
        if specs[i].column_name == name:
            return i
    return -1
