# =============================================================================
# integer_literal_value — THE ONE RULE: an integer literal's VALUE is read
#                         according to its TAG, never according to the column.
# =============================================================================
#
# ⛔ THE DEFECT THIS EXISTS FOR IS A SILENT WRONG ANSWER. Every executor arm
# that compares a column against a `ScalarValue` picks the field it reads from
# the COLUMN's type, and the literal's own `dtype` tag was consulted by an
# ALLOW-LIST at best. Two mechanisms through `_eval_predicate` without this
# module:
#
#   (a) `ScalarValue.from_uint64` stores the unsigned value as its TWO'S-
#       COMPLEMENT BIT PATTERN in `int_val` (`scalar_value.mojo`), and every
#       signed / narrow integer arm read `int_val` SIGNED. `2**64-1` arrived as
#       `-1`:
#           int64 col [-5,0,3,MAX]  v >  2**64-1   ->  0111   want 0000
#           int64 col [-5,0,3,MAX]  v <  2**64-1   ->  1000   want 1111
#           dict<int64> [-1,0,3]    v >  2**64-1   ->  011    want 000
#           int64 col  IN (2**64-1)                ->  selects the `-1` row
#   (b) the FLOAT64 arm promoted an integer literal only when it was tagged
#       `int64` or `int32` (an allow-list over the LITERAL's tag), so every
#       other integer tag fell through to `Scalar[float64](lit.float_val)` — a
#       well-formed ZERO:
#           f64 col [0.5,3,10]      v >  3 (uint8) ->  111    want 001
#       and the numeric-DICTIONARY float arms had no promotion AT ALL, so even
#       the INT64 literal every door sends read as zero:
#           dict<f64> [0.5,3,10]    v >  3 (int64) ->  111    want 001
#
# ★ WHY ONE MODULE AND NOT A PATCH PER ARM. The same misread lived in the flat
# comparison ladder, the numeric-dictionary LUT and its byte-verify oracle, the
# IN-list value tables, the DECIMAL arm, and the computed-operand comparison
# path. A per-arm patch is how the INT32 literal-domain fix had
# to be re-landed at SIX sites. Here the TAG is decoded in exactly one function
# (`integer_literal_value`), and the only per-column question left — which
# DOMAIN does this column compare in — is answered in exactly one other
# (`read_integer_literal_for_column`).
#
# ============================ THE SEMANTICS CHOSEN ============================
#
# The oracle is DuckDB v1.5.3. Its binder resolves `<float column> OP <integer>` by CASTING THE
# INTEGER TO THE COLUMN'S FLOAT TYPE and comparing there:
#
#   DOUBLE col:  `v = 9007199254740993::BIGINT`  -> EXPLAIN shows the filter
#                `v=9007199254740992.0`; `v = 18446744073709551615::UBIGINT`
#                selects the row holding 1.8446744073709552e19 (= 2**64).
#   FLOAT  col:  `typeof(1::FLOAT + 1::BIGINT)` = FLOAT (and for UBIGINT,
#                TINYINT); `v = 16777217` selects the 16777216.0 row; EXPLAIN
#                shows `v=16777216.0`. `v = 16777217::DOUBLE` selects NOTHING —
#                a DOUBLE literal widens the FLOAT column instead.
#
# So, for |v| > 2**53 (DOUBLE) or > 2**24 (FLOAT), the comparison is NOT exact
# arithmetic — it is DuckDB's cast, and this module reproduces that cast rather
# than an exact comparison DuckDB does not perform. ⚠ SINGLE ROUNDING, FROM THE
# EXACT INTEGER: `9007199791611905` (2**53 + 2**29 + 1) is `9007200328482816.0`
# as a FLOAT in DuckDB, but `9007199254740992.0` if rounded to DOUBLE first —
# double rounding lands on the other neighbour. `Int64.cast[float32]` is one
# `sitofp`, measured to give DuckDB's answer.
#
# An INTEGER column never needs a cast: every integer width but uint64 embeds
# in Int64, and the literal's exact value is in [-2**63, 2**64). The only value
# outside Int64 is a uint64-tagged one at or above 2**63, which is ABOVE EVERY
# VALUE THE COLUMN CAN HOLD — so the answer is the trivial one (DuckDB:
# `BIGINT col < 18446744073709551615::UBIGINT` holds for every non-null row).
# It is spelled as a REAL COMPARE in the column's own domain,
# `v <= Int64.MAX` (every row) / `v > Int64.MAX` (none), so the kernel, the lane
# order, the offset and the NULL finalize stay the arm's own.
#
# ⚠ THAT IS NOT THE CLAMP `literal_domain.mojo` FORBIDS. Clamping the literal
# alone is wrong for `=` and `<>`; this rewrites the OPERATOR with it, and the
# rewrite is exact for every operator because no column value exceeds
# Int64.MAX.
#
# ⚠ A MALFORMED LITERAL IS REFUSED. A narrow tag whose `int_val` is outside
# that tag's own domain (a `uint8` carrying 300, a `uint32` carrying -1) has no
# value to read — it can only come from a hand-built wire message — and reading
# its bits anyway would be the defect this module exists to remove.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.dtype_sentinel import DTYPE_NONE
from komira_core.plan.expr import BIN_EQ, BIN_GE, BIN_GT, BIN_LE, BIN_LT, BIN_NE
from komira_core.plan.literal_domain import int_literal_fits
from komira_core.plan.scalar_value import ScalarValue


comptime I128 = SIMD[DType.int128, 1]
comptime INT64_MAX: Int64 = 9223372036854775807


def _payload_fits_its_tag(dt: DType, v: Int64) -> Bool:
    """Is `v` a value of the literal's OWN tag? uint64 is not asked here: its
    `int_val` is a bit pattern, and every 64-bit pattern is a uint64."""
    if dt == DType.int64:
        return True
    if dt == DType.int32:
        return int_literal_fits[DType.int32](v)
    if dt == DType.int16:
        return int_literal_fits[DType.int16](v)
    if dt == DType.int8:
        return int_literal_fits[DType.int8](v)
    if dt == DType.uint32:
        return int_literal_fits[DType.uint32](v)
    if dt == DType.uint16:
        return int_literal_fits[DType.uint16](v)
    if dt == DType.uint8:
        return int_literal_fits[DType.uint8](v)
    return False


def integer_literal_value(lit: ScalarValue) raises -> I128:
    """THE decode. The exact mathematical value of an INTEGER literal of any
    tag (int8/16/32/64, uint8/16/32/64), read by that TAG.

    `uint64` is ZERO-extended from its bit pattern; every other tag carries its
    value in `int_val` and is sign-extended. The result is exact: every integer
    a `ScalarValue` can carry lies in [-2**63, 2**64).

    Raises:
        `EVAL_NOT_AN_INTEGER_LITERAL` if `lit` is not an integer literal, and
        `EVAL_MALFORMED_INTEGER_LITERAL` if a narrow tag's payload is outside
        that tag's own domain.
    """
    if not lit.is_any_integer():
        raise Error(
            "EVAL_NOT_AN_INTEGER_LITERAL: integer_literal_value asked for the"
            " integer value of " + String(lit)
        )
    if lit.dtype == DType.uint64:
        return lit.uint64_value().cast[DType.int128]()
    if not _payload_fits_its_tag(lit.dtype, lit.int_val):
        raise Error(
            "EVAL_MALFORMED_INTEGER_LITERAL: a literal tagged "
            + String(lit.dtype)
            + " carries the payload "
            + String(lit.int_val)
            + ", which is not a value of that type. REFUSED RATHER THAN READ:"
            " the tag is what says what the bits mean, and a payload outside"
            " the tag's domain has no meaning to read."
        )
    return lit.int_val.cast[DType.int128]()


def integer_literal_as_float64(lit: ScalarValue) raises -> Float64:
    """DuckDB's `CAST(<integer> AS DOUBLE)` of an integer literal of any tag:
    ONE round-to-nearest-even conversion from the exact integer."""
    _ = integer_literal_value(lit)  # the tag/payload check
    if lit.dtype == DType.uint64:
        return lit.uint64_value().cast[DType.float64]()
    return lit.int_val.cast[DType.float64]()


def integer_literal_as_float32(lit: ScalarValue) raises -> Float32:
    """DuckDB's `CAST(<integer> AS FLOAT)` of an integer literal of any tag:
    ONE round-to-nearest-even conversion from the exact integer — NOT via
    Float64, which double-rounds (see the header)."""
    _ = integer_literal_value(lit)  # the tag/payload check
    if lit.dtype == DType.uint64:
        return lit.uint64_value().cast[DType.float32]()
    return lit.int_val.cast[DType.float32]()


def number_dtype_of(at: ArrowType) -> DType:
    """The value DType a FLAT numeric column of Arrow type `at` compares in, or
    `DTYPE_NONE` when `at` is not one this rule has a domain for (decimal,
    temporal, text, bool, float16, nested — each has its own arm or refusal).
    A numeric DICTIONARY column answers with `Column.dict_value_dtype`
    instead; the Arrow type alone cannot say what its entries are."""
    if at == ArrowType.INT64:
        return DType.int64
    if at == ArrowType.INT32:
        return DType.int32
    if at == ArrowType.INT16:
        return DType.int16
    if at == ArrowType.INT8:
        return DType.int8
    if at == ArrowType.UINT64:
        return DType.uint64
    if at == ArrowType.UINT32:
        return DType.uint32
    if at == ArrowType.UINT16:
        return DType.uint16
    if at == ArrowType.UINT8:
        return DType.uint8
    if at == ArrowType.FLOAT64:
        return DType.float64
    if at == ArrowType.FLOAT32:
        return DType.float32
    return DTYPE_NONE


@always_inline
def _is_ordered_comparison(op: UInt8) -> Bool:
    return (
        op == BIN_LT
        or op == BIN_LE
        or op == BIN_GT
        or op == BIN_GE
        or op == BIN_EQ
        or op == BIN_NE
    )


def read_integer_literal_for_column(
    value_dtype: DType, mut lit: ScalarValue, mut op: UInt8
) raises:
    """Rewrite `column OP lit` so the arm selected by the COLUMN reads the
    literal's TRUE value — THE ONE RULE, applied where a literal meets a column.

    A no-op for a literal that is not an integer. For an integer literal of any
    tag, by the column's value DType:

      * float64 / float32 -> a FLOAT literal holding DuckDB's cast of the
        integer to the COLUMN's float type (`integer_literal_as_float64/32`).
        The float arms then read `float_val`, which is now the value.
      * uint64 -> unchanged; the UINT64 arm reads the full unsigned range
        through `integer_literal_value` itself. Validated here all the same.
      * every other integer width -> an INT64-tagged literal of the same value;
        a value above Int64.MAX (only a uint64 tag can hold one) is above the
        whole column domain and becomes `v <= Int64.MAX` / `v > Int64.MAX`
        — see the module header for why that rewrite is exact.
      * `DTYPE_NONE` (decimal, temporal, ...) -> unchanged; those arms decode
        through `integer_literal_value` or refuse the pair themselves.

    Args:
        value_dtype: What the COLUMN's values are (`number_dtype_of`, or a
            numeric dictionary's `dict_value_dtype`).
        lit: The comparison literal; rewritten in place.
        op: The comparison operator, `column OP lit`; rewritten in place only
            for the above-the-domain case.

    Raises:
        `EVAL_MALFORMED_INTEGER_LITERAL` (see `integer_literal_value`), and a
        refusal if an above-Int64 literal meets a non-comparison operator —
        there is no trivial answer to rewrite that to.
    """
    if not lit.is_any_integer():
        return
    if value_dtype == DType.float64:
        lit = ScalarValue.from_float(integer_literal_as_float64(lit))
        return
    if value_dtype == DType.float32:
        # Widening a Float32 to Float64 is exact, and the float32 arms compare
        # a WIDENED column against `float_val` — so a threshold that is itself
        # a Float32 value makes that Float64 compare the FLOAT compare DuckDB
        # performs.
        lit = ScalarValue.from_float(
            integer_literal_as_float32(lit).cast[DType.float64]()
        )
        return
    if value_dtype == DType.uint64:
        _ = integer_literal_value(lit)
        return
    if not value_dtype.is_integral():
        return
    if lit.dtype == DType.int64:
        # Already the canonical carrier — an Int64 value, read as one. The hot
        # path (`int64 col OP int64 literal`, what every door sends) pays one
        # tag compare here and nothing else.
        return
    var v = integer_literal_value(lit)
    if v <= INT64_MAX.cast[DType.int128]():
        lit = ScalarValue.from_int64(v.cast[DType.int64]())
        return
    if not _is_ordered_comparison(op):
        raise Error(
            "EVAL_INTEGER_LITERAL_OUT_OF_DOMAIN: the literal "
            + String(lit.uint64_value())
            + " is above every value of a "
            + String(value_dtype)
            + " column, and operator "
            + String(Int(op))
            + " is not a comparison, so there is no exact answer to give"
        )
    var holds = op == BIN_LT or op == BIN_LE or op == BIN_NE
    lit = ScalarValue.from_int64(INT64_MAX)
    op = BIN_LE if holds else BIN_GT


@always_inline
def mirror_comparison(op: UInt8) -> UInt8:
    """`lit OP col` is `col mirror(OP) lit`. `=` and `<>` are their own
    mirror; any other operator is returned unchanged."""
    if op == BIN_LT:
        return BIN_GT
    if op == BIN_GT:
        return BIN_LT
    if op == BIN_LE:
        return BIN_GE
    if op == BIN_GE:
        return BIN_LE
    return op
