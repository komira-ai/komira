# =============================================================================
# komira_plan_conformance/cases_string.mojo -- shard string.
# =============================================================================
#
# Length in code points and in bytes, CONCAT and CONCAT_WS with NULLs, LIKE
# with `%` and `_` over multi-byte characters, UPPER and LOWER beyond ASCII,
# string comparison by bytes, and '' against NULL, citing query semantics
# §1.2, §2.4, §4.6, §4.8, §7.1, §7.2, §7.4, §7.6, §7.9, §7.12, §7.14, and
# the result types of §8.6, §8.8, §8.15 and §8.21. One dataset, str_rows:
#   id  s                  t
#   1   "abc"              "x"
#   2   "h" U+00E9 "llo"   NULL      (2-byte e-acute)
#   3   U+65E5 U+672C      ""        (two 3-byte characters)
#   4   "a" U+1F600 "b"    "-"       (a 4-byte character)
#   5   ""                 NULL
#   6   NULL               "y"
#   7   "Stra" U+00DF "e"  U+00C4 U+00D6
#   8   NULL               NULL
#   9   U+1F600            U+FF21    (EF BC A1, below F0 by bytes)
# Every expectation is HAND, its derivation in the .tsv. No root sorts, so
# every case compares its rows as a multiset (§4.8).
#
# CONCAT, CONCAT_WS, UPPER and LOWER answer a string: §7.2, §7.4 and §7.9
# say so, but the result-type table (§8) has no row for them, so their
# columns are `string?` by §8's default ("unless a row says otherwise, every
# result is nullable"). That is sound for CONCAT, which is never NULL (§7.2).
#
# Not here, and why:
#   - SUBSTRING: the plan has EXPR_SUBSTRING, but the document has no item
#     for it (no rule for its start, length, or character-or-byte unit).
#   - CONCAT_WS whose every argument is NULL: §7.4 skips each NULL argument
#     with its separator and does not say what is left when none remains,
#     so concat_ws_null_rules excludes id 8.
#   - LIKE with a NULL pattern: the plan's STR_LIKE carries its pattern as
#     a constant string, so a NULL pattern cannot be built; only a NULL
#     subject is a case. ESCAPE and ILIKE are refused by name (§7.7).
#   - A non-string CONCAT argument: refused by name (§7.5, DEPARTS); a
#     refusal case waits for an executor to refuse it.
#   - Regular expressions: their flag table departs from the code ("Code
#     that does not follow", item 8) and they have their own defect list.
#   - Invalid UTF-8 (§7.15, UNDECIDED); readers' empty fields (§7.13,
#     UNDECIDED). JSON `""` here is '' and JSON `null` is NULL, the reading
#     plan_case.mojo already relies on.
#
# The defect each case would catch once it executes:
#   length_chars_bytes        length counting bytes (6 for "h" U+00E9 "llo")
#                             or strlen counting code points; '' as NULL
#   concat_skips_null         CONCAT propagating NULL like `||` (§7.3);
#                             concat(NULL, NULL) as NULL rather than ''
#   concat_ws_null_rules      a NULL argument leaving its separator ("|y");
#                             a NULL separator skipped instead of NULLing;
#                             '' skipped as if it were NULL (id 3 losing
#                             its trailing "|")
#   like_code_points          `_` consuming one byte (h_llo fails on the
#                             2-byte e-acute; `_` fails on U+1F600); LIKE
#                             matching a substring, or case-insensitively
#   like_filter_drops_null    a NULL subject kept by the filter; '' dropped
#   upper_lower_unicode       an ASCII-only kernel (U+00E9, U+00DF, U+00C4,
#                             U+FF21 unchanged); full case mapping (SS)
#   string_compare_bytes      a collation or case folding ("abc" < "Z"); a
#                             UTF-16 order (U+1F600 below U+FF21); padding
#                             ('abc' = 'abc '); a prefix sorting last
#   empty_vs_null_groups      '' and NULL merged into one group
#   empty_string_is_not_null  '' reported as NULL
# =============================================================================

from komira_plan_expr.agg_expr import AGG_COUNT, AggExpr
from komira_plan_expr.expr import (
    BIN_EQ,
    BIN_LT,
    BIN_NE,
    STRFN_BIT_LENGTH,
    STRFN_LENGTH,
    STRFN_STRLEN,
    STR_LIKE,
    UN_IS_NULL,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import AggExprArray, ExprArray, LogicalPlan

from .plan_case import Case
from .datasets import scan, str_rows

comptime SHARD = "string"


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _as(var e: Expr, name: String) -> Expr:
    return Expr.alias(e^, name)


def _str(v: String) -> Expr:
    return Expr.literal(ScalarValue.from_string(v))


def _like(column: String, pattern: String, name: String) -> Expr:
    return _as(Expr.string_op(STR_LIKE, _col(column), pattern), name)


def _lt_lit(column: String, v: String, name: String) -> Expr:
    return _as(Expr.binary(BIN_LT, _col(column), _str(v)), name)


def _length_chars_bytes() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(Expr.string_fn(STRFN_LENGTH, _col("s")), "len"))
    e.append(_as(Expr.string_fn(STRFN_STRLEN, _col("s")), "bytes"))
    e.append(_as(Expr.string_fn(STRFN_BIT_LENGTH, _col("s")), "bits"))
    return LogicalPlan.project(e^, scan(str_rows()))


def _concat_skips_null() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(Expr.concat([_col("s"), _col("t")]), "c"))
    return LogicalPlan.project(e^, scan(str_rows()))


def _concat_ws_null_rules() raises -> LogicalPlan:
    """concat_ws('|', s, t) and concat_ws(t, s, 'Q') over str_rows WHERE
    id <> 8 (the row whose s and t are both NULL)."""
    var not_8 = LogicalPlan.filter(
        Expr.binary(BIN_NE, _col("id"), Expr.literal(ScalarValue.from_int64(Int64(8)))),
        scan(str_rows()),
    )
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(Expr.concat_ws([_str("|"), _col("s"), _col("t")]), "ws"))
    e.append(_as(Expr.concat_ws([_col("t"), _col("s"), _str("Q")]), "ws_sep"))
    return LogicalPlan.project(e^, not_8^)


def _like_code_points() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_like("s", "h_llo", "l_h_llo"))
    e.append(_like("s", "a_b", "l_a_b"))
    e.append(_like("s", "%", "l_pct"))
    e.append(_like("s", "__", "l_2"))
    e.append(_like("s", "%b", "l_pct_b"))
    e.append(_like("s", "ABC", "l_ABC"))
    e.append(_like("s", "_", "l_1"))
    return LogicalPlan.project(e^, scan(str_rows()))


def _like_filter_drops_null() raises -> LogicalPlan:
    """str_rows WHERE s LIKE '%'."""
    return LogicalPlan.filter(Expr.string_op(STR_LIKE, _col("s"), "%"), scan(str_rows()))


def _upper_lower_unicode() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(Expr.upper(_col("s")), "us"))
    e.append(_as(Expr.lower(_col("s")), "ls"))
    e.append(_as(Expr.lower(_col("t")), "lt"))
    return LogicalPlan.project(e^, scan(str_rows()))


def _string_compare_bytes() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_lt_lit("s", "Z", "lt_Z"))
    e.append(_lt_lit("s", "hz", "lt_hz"))
    e.append(_as(Expr.binary(BIN_EQ, _col("s"), _str("abc ")), "eq_abc_sp"))
    e.append(_lt_lit("s", "abcd", "lt_abcd"))
    e.append(_as(Expr.binary(BIN_LT, _col("s"), _col("t")), "s_lt_t"))
    return LogicalPlan.project(e^, scan(str_rows()))


def _empty_vs_null_groups() raises -> LogicalPlan:
    var keys = ExprArray()
    keys.append(_col("s"))
    var a = AggExprArray()
    a.append(AggExpr(AGG_COUNT, None, Optional(String("n"))))
    return LogicalPlan.aggregate(keys^, a^, scan(str_rows()))


def _empty_string_is_not_null() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_col("s"))
    e.append(_as(Expr.unary(UN_IS_NULL, _col("s")), "s_null"))
    return LogicalPlan.project(e^, scan(str_rows()))


def cases() -> List[Case]:
    return [
        Case.hand("length_chars_bytes", SHARD, _length_chars_bytes, CanonPolicy.unordered()),
        Case.hand("concat_skips_null", SHARD, _concat_skips_null, CanonPolicy.unordered()),
        Case.hand("concat_ws_null_rules", SHARD, _concat_ws_null_rules, CanonPolicy.unordered()),
        Case.hand("like_code_points", SHARD, _like_code_points, CanonPolicy.unordered()),
        Case.hand("like_filter_drops_null", SHARD, _like_filter_drops_null, CanonPolicy.unordered()),
        Case.hand("upper_lower_unicode", SHARD, _upper_lower_unicode, CanonPolicy.unordered()),
        Case.hand("string_compare_bytes", SHARD, _string_compare_bytes, CanonPolicy.unordered()),
        Case.hand("empty_vs_null_groups", SHARD, _empty_vs_null_groups, CanonPolicy.unordered()),
        Case.hand("empty_string_is_not_null", SHARD, _empty_string_is_not_null, CanonPolicy.unordered()),
    ]
