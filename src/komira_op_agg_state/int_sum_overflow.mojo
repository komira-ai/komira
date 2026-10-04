# =============================================================================
# THE ONE SIGNED-OVERFLOW PREDICATE FOR INTEGER `sum()`, AND THE ONE SENTENCE
# EVERY ROUTE REFUSES WITH.
# =============================================================================
#
# ★ WHY THIS IS A MODULE AND NOT THREE COPIES OF THREE LINES. `sum(<int col>)`
#   is served by at least three accumulators in this engine:
#
#     * `komira_engine_dispatch.agg_scalar_fold._fold_int_width`  (0-key
#       RESIDENT fold — a serial Int64 accumulator)
#     * `hash_agg_untyped._apply_agg_update`'s `AGG_SUM_I64` arm (GROUPED,
#       row-at-a-time — a UInt64 state cell)
#     * `hash_agg_untyped._fold_agg_col_mono`'s `_MF_SUM_I64` arm (GROUPED,
#       INTFOLD — the same cell, three chunk loops)
#
#   ⭐ 2026-09-25: those two GROUPED arms now serve only a NARROW aggregand
#   (i8..i32, u8..u32). A 64-bit one folds into the EXACT 128-bit
#   `AGG_SUM_I128` / `AGG_SUM_U128` cell (block below), because the 8-byte
#   cell's per-step check made one query's verdict depend on merge order. The
#   0-key routes and the extended fold are exact too (`ExactIntAgg`,
#   `agg_extended_grouped._ExtAggState.isum`).
#
#   Each one added into a 64-bit cell with a bare `+` and each one WRAPPED, and
#   because they wrap identically the disagreement they produce is not with each
#   other — it is with arithmetic. The AVG defect beside them (board
#   ) was worse precisely because the routes did NOT agree there:
#   the resident fold divided a wrapped Int64 while the two streaming/grouped
#   routes divided a Float64, so one query answered +2.53e18 at 99,997,497 rows
#   and -1.29e18 under a filter. **A predicate that lives in one place cannot
#   develop that shape.**
#
# ⛔ THE THREE OUTCOMES FOR AN INTEGER SUM THAT LEAVES Int64's RANGE ARE: a
#   WIDER OUTPUT TYPE, a REFUSAL, or a SILENT WRONG ANSWER. The third is not an
#   option. DuckDB takes the first — `typeof(sum(<bigint>))` is HUGEINT, and on
#   the ClickBench fixture `sum(user_id)` is 252888973009538030487413479, a
#   27-digit number no INT64 column can carry. This engine's int-family SUM
#   output column is INT64 for a signed aggregand and UINT64 for an unsigned
#   one (since 2026-09-25), so until that type widens to HUGEINT (a product
#   decision with a board card, komira-ai/komira#9500056, not a code change to make
#   quietly) the honest answer is the second: refuse, and say which column.
# =============================================================================

from std.memory import bitcast


@always_inline
def i64_add_overflows(acc: Int64, v: Int64, new_acc: Int64) -> Bool:
    """True iff the signed addition `acc + v` that produced `new_acc` left
    Int64's range.

    ★ A TEST ON THE RESULT, NOT A RANGE PRECHECK ON THE OPERANDS. Signed
    overflow happens exactly when the two addends share a sign that the sum does
    not, so `(acc ^ new) & (v ^ new)` has its sign bit set on that case and on
    no other. Three ALU ops and a never-taken branch — it does not need the
    division, the comparison against `Int64.MAX - v`, or the branch on `v`'s
    sign that a precheck would cost in a per-row fold.

    ⚠ IT MUST BE HANDED THE WRAPPED RESULT. Mojo's `Int64.__add__` is a wrapping
    add; `new_acc` is what it produced. Recomputing `acc + v` inside here would
    be the same value, but taking it as an argument is what makes it impossible
    for a caller to test one sum and store a different one.
    """
    return ((acc ^ new_acc) & (v ^ new_acc)) < Int64(0)


@always_inline
def u64_cell_add_overflows(cur: UInt64, v: Int64, new_cell: UInt64) -> Bool:
    """The same predicate for the GROUPED routes, whose accumulator cell is a
    `UInt64` holding signed wire bits.

    ⚠ THE CELL IS NOT UNSIGNED ARITHMETIC — it is an Int64 stored as raw bits
    (`read_agg_i64` bitcasts it back). So the question is still whether the
    SIGNED addition overflowed, and reinterpreting the three UInt64 bit patterns
    as Int64 asks exactly that. A `new_cell < cur` unsigned-carry test would be
    a different and wrong question: it fires on every addition of a negative
    value, of which ClickBench `user_id` has tens of millions.
    """
    return i64_add_overflows(
        bitcast[DType.int64, 1](SIMD[DType.uint64, 1](cur))[0],
        v,
        bitcast[DType.int64, 1](SIMD[DType.uint64, 1](new_cell))[0],
    )


def int_sum_overflow_message(what: String) -> String:
    """The refusal every route raises, so a user who crosses a route boundary
    reads the same sentence rather than two different diagnoses of one defect.

    `what` names the aggregand — its Arrow type at the 0-key fold, its column
    index at the grouped kernels, whichever the caller can cheaply say.
    """
    return (
        "integer sum() overflowed INT64 (aggregand: "
        + what
        + "). The exact total is outside"
        " [-9223372036854775808, 9223372036854775807] and this engine's"
        " int-family sum() output column is INT64, so there is no value to"
        " return. DuckDB answers this shape by promoting sum(<integer>) to"
        " HUGEINT (128-bit); this engine does not yet, and returning the"
        " wrapped 64-bit total instead would be a silent wrong answer --"
        " which is the defect this refusal replaces ()."
        " avg() over the same column is UNAFFECTED and still answers: it"
        " divides the exact total, which is not narrowed to INT64."
    )


# -----------------------------------------------------------------------------
# ⭐ THE WINDOW ROUTES (, 2026-09-24). `SUM(<bigint>) OVER
# (...)` and `AVG(<bigint>) OVER (...)` over a bounded / running / whole-
# partition frame WRAPPED — `sum(a) OVER (PARTITION BY g)` answered MIN for a
# partition {MAX, 1} and `avg(a) OVER (...)` answered -4.6e18 for the same
# frame, where DuckDB 1.5.3 answers 9223372036854775808 (HUGEINT) and 4.6e18.
# Those kernels now accumulate in 128 bits — a ring buffer's `total -= old;
# total += new` can overflow 64 bits in the MIDDLE of a frame whose sum fits,
# so a per-step test would refuse a query that has an answer — and narrow at
# the moment a value is EMITTED, through this one check.
# -----------------------------------------------------------------------------


@always_inline
def i128_total_fits_i64(total: Scalar[DType.int128]) -> Bool:
    return total <= Int64.MAX.cast[DType.int128]() and total >= Int64.MIN.cast[
        DType.int128
    ]()


def narrow_sum_u64(total: Scalar[DType.int128], what: String) raises -> UInt64:
    """An exact 128-bit total as the UINT64 an UNSIGNED aggregand's sum column
    carries, or `uint_sum_overflow_message` when that value does not exist."""
    if total < Scalar[DType.int128](0) or total > UInt64.MAX.cast[DType.int128]():
        raise Error(uint_sum_overflow_message(what))
    return total.cast[DType.uint64]()


def narrow_window_sum_i64(total: Scalar[DType.int128], what: String) raises -> Int64:
    """A window frame's exact 128-bit total as the INT64 the output column
    carries, or `int_sum_overflow_message` when that value does not exist."""
    if not i128_total_fits_i64(total):
        raise Error(int_sum_overflow_message(what))
    return total.cast[DType.int64]()


# -----------------------------------------------------------------------------
# ⭐⭐ THE EXACT 0-KEY INTEGER STATE ( W0-ENGINE, vfy-engine
# finding, 2026-09-24). ONE value per integer aggregate — the non-null row
# count, the SUM in 128 bits, and MIN / MAX as ORDER CELLS — that the two 0-key
# routes (`agg_scalar_fold` resident, `unified/agg_sink_ungrouped` streaming)
# both reduce into, so one query cannot answer two ways across a route
# boundary.
#
# ⛔ THE DEFECT IT CLOSES WAS A SILENT WRONG ANSWER. The streaming sink folded
# an integer SUM / AVG / MIN / MAX through its FLOAT64 slot, so every value and
# every partial total above 2^53 was ROUNDED: `sum([9007199254740993])`
# answered 9007199254740992, `sum([123456789012345678, 876543210987654321])`
# answered 10^18 (DuckDB, polars and pandas: 999999999999999999),
# `sum([MIN, -1])` answered MIN where the value does not exist, `max(<uint64>)`
# answered INT64.MAX, and across row groups the rounded value changed run to
# run. The resident fold's AVG divided the same FLOAT64 total
# (`avg([2^53, 1, -2^53])` = 0.0, DuckDB 0.333...) and its SUM REFUSED a total
# that fits whenever a PARTIAL left INT64 (`{MAX, MAX, MIN, MIN}` -> -2).
#
# ★ 128 BITS IS EXACT BY CONSTRUCTION: a sum of fewer than 2^64 values each
# inside [-2^63, 2^64) cannot leave [-2^127, 2^127). The total is narrowed ONCE,
# when SUM is emitted (`i128_total_fits_i64`); AVG divides it unnarrowed
# (`Scalar[int128].cast[float64]()` is correctly rounded — DuckDB 1.5.3 on
# darwin arm64 double-rounds a NEGATIVE total past 2^53 through its hugeint ->
# long double cast, and on linux x86 its 80-bit long double does not, so the
# two DuckDB builds disagree there and this follows the arithmetic).
#
# ★ ORDER CELLS: `lo` / `hi` hold `v` for every signed width and `v XOR 2^63`
# for UINT64, which maps unsigned order onto signed order — the same bias
# `agg_scalar_fold._minmax_cell` applies, so the two routes agree.
# -----------------------------------------------------------------------------


comptime _U64_ORDER_BIAS: UInt64 = 0x8000000000000000


@always_inline
def u64_order_cell(bits: Int64) -> Int64:
    """`bits` (a UINT64 value's raw bits) as its ORDER-PRESERVING signed cell,
    and back again — the bias is an involution."""
    return bitcast[DType.int64, 1](
        SIMD[DType.uint64, 1](
            bitcast[DType.uint64, 1](SIMD[DType.int64, 1](bits))[0]
            ^ _U64_ORDER_BIAS
        )
    )[0]


struct ExactIntAgg(Copyable, Movable):
    """The exact state of ONE 0-key integer aggregate. See the block above.

    `active` is False until a batch whose aggregand is an integer column has
    been folded into it; an inactive state merges as the identity."""

    var active: Bool
    var u64: Bool
    """The aggregand is UINT64, so `lo` / `hi` are BIASED cells."""
    var count: Int
    var sum: Scalar[DType.int128]
    var lo: Int64
    var hi: Int64

    def __init__(out self):
        self.active = False
        self.u64 = False
        self.count = 0
        self.sum = Scalar[DType.int128](0)
        self.lo = Int64.MAX
        self.hi = Int64.MIN

    def merge(mut self, imm other: Self):
        """Fold `other` in. Exact and ORDER-INDEPENDENT: the 128-bit sum does
        not overflow and MIN / MAX commute, so the answer cannot depend on
        which worker's partial the combine reads first."""
        if not other.active:
            return
        self.active = True
        self.u64 = self.u64 or other.u64
        self.count += other.count
        self.sum += other.sum
        if other.lo < self.lo:
            self.lo = other.lo
        if other.hi > self.hi:
            self.hi = other.hi

    def sum_i64(self, what: String) raises -> Int64:
        """The exact total as the INT64 the output column carries, or the
        shared refusal when that value does not exist."""
        return narrow_window_sum_i64(self.sum, what)

    def sum_u64(self, what: String) raises -> UInt64:
        """The exact total as the UINT64 an UNSIGNED aggregand's sum column
        carries (`logical_plan._infer_agg_field`), or the by-name refusal
        when it is outside [0, 2^64)."""
        return narrow_sum_u64(self.sum, what)

    def mean(self) -> Float64:
        """The exact total over the non-null count, correctly rounded once.
        The caller has already answered NULL for `count == 0`."""
        return self.sum.cast[DType.float64]() / Float64(self.count)


# -----------------------------------------------------------------------------
# ⭐⭐ THE EXACT GROUPED 64-BIT SUM CELL ( W0-ENGINE; cards
#,, — 2026-09-25).
#
# `sum(<INT64>)` and `sum(<UINT64>)` on the GROUPED kernel
# (`hash_agg_untyped`'s `AGG_SUM_I128` / `AGG_SUM_U128`) accumulate into ONE
# two's-complement 128-bit value per (group, agg), stored as two little-endian
# 64-bit words: `lo` at the cell's offset, `hi` at offset + 8.
#
# ⛔ THE DEFECT IT CLOSES WAS A VERDICT THAT DEPENDED ON SCHEDULING. The 8-byte
# Int64 cell before it refused, at every fold and every partial-table merge,
# the moment a PARTIAL left Int64 — so `sum(a) GROUP BY g` over
# {MAX, MAX, MIN, MIN} in four row groups refused or answered DuckDB's -2
# depending on which rows each worker's partial held and the order the combine
# read them. And a UINT64 aggregand entered that cell as its raw bits, i.e. as
# a NEGATIVE addend at or above 2^63, so {1, 3, 2^64-1} answered 3.
#
# ★ 128 BITS IS EXACT BY CONSTRUCTION (the same argument `ExactIntAgg` makes
# for the 0-key routes): fewer than 2^64 addends, each inside [-2^63, 2^64),
# cannot leave [-2^127, 2^127). The fold and the merge are both plain 128-bit
# additions — associative and commutative — so every order computes the same
# total, and it is narrowed ONCE, at readback (`HashAggTable_Untyped.
# read_agg_i64`, through `exact_sum_cell_fits`), to
# the output column's type: INT64 for a signed aggregand, UINT64 for an
# unsigned one. A total outside that range REFUSES BY NAME, in every order.
# -----------------------------------------------------------------------------


@always_inline
def i128_addend_hi(v_bits: Int64, unsigned: Bool) -> UInt64:
    """The HIGH word of a 64-bit addend widened to 128 bits: the sign
    extension of a signed value, zero for an unsigned one (whose raw bits
    `v_bits` carries)."""
    if unsigned:
        return UInt64(0)
    return bitcast[DType.uint64, 1](SIMD[DType.int64, 1](v_bits >> 63))[0]


@always_inline
def i128_words_add(
    lo: UInt64, hi: UInt64, add_lo: UInt64, add_hi: UInt64
) -> Tuple[UInt64, UInt64]:
    """`(hi:lo) + (add_hi:add_lo)` as two's-complement 128-bit words. The
    carry out of the low word is the only coupling; both adds wrap, which is
    exactly 128-bit modular addition."""
    var n_lo = lo + add_lo
    var carry = UInt64(1) if n_lo < lo else UInt64(0)
    return (n_lo, hi + add_hi + carry)


def uint_sum_overflow_message(what: String) -> String:
    """The refusal for an UNSIGNED sum whose exact total is outside UINT64 —
    the sibling of `int_sum_overflow_message`, for the column this engine
    declares UINT64 (`logical_plan._infer_agg_field`)."""
    return (
        "integer sum() overflowed UINT64 (aggregand: "
        + what
        + "). The exact total is outside [0, 18446744073709551615] and this"
        " engine's sum() over an unsigned integer column answers UINT64, so"
        " there is no value to return. DuckDB answers this shape by promoting"
        " sum(<integer>) to HUGEINT (128-bit); this engine does not yet, and"
        " returning the wrapped 64-bit total instead would be a silent wrong"
        " answer ()."
    )


@always_inline
def exact_sum_cell_fits(lo: UInt64, hi: UInt64, unsigned: Bool) -> Bool:
    """True iff the 128-bit total `(hi:lo)` is representable in the output
    column: UINT64 for an unsigned aggregand, INT64 for a signed one."""
    if unsigned:
        return hi == UInt64(0)
    if lo < UInt64(0x8000000000000000):
        return hi == UInt64(0)
    return hi == UInt64.MAX


def exact_sum_cell_i128(lo: UInt64, hi: UInt64) -> Scalar[DType.int128]:
    """The cell's exact total, for a caller that divides it (AVG) rather than
    narrowing it."""
    var u = (hi.cast[DType.uint128]() << 64) | lo.cast[DType.uint128]()
    return u.cast[DType.int128]()
