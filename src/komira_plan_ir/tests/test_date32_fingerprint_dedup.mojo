# =============================================================================
# test_date32_fingerprint_dedup — DATE32 literal expr-fingerprint collision
# =============================================================================
#
# TEMPORAL LOGICAL-vs-PHYSICAL audit. REGRESSION GUARD for a
# silent-wrong in the optimizer's CSE / whole-expr dedup: `_expr_fingerprint` /
# `_scalar_fingerprint` (plan_helpers.mojo) keyed a literal by reading a
# value field per-KIND (is_int -> int_val, is_float -> float_val, ...), but had
# NO arm for a temporal literal, so a `ScalarValue.date32(D)` (value in
# `date32_val`) fell to the value-LESS "L:?" fallback. Every distinct date
# literal therefore fingerprinted IDENTICALLY -> Phase A whole-expr dedup could
# collapse two DISTINCT date predicates (`d < DATE 'a'` and `d < DATE 'b'`) into
# one. Same collision class the CAST-target arm already guards against.
#
# FAILS ON CURRENT CODE (pre-fix): `_scalar_fingerprint(date32(100))` and
# `_scalar_fingerprint(date32(200))` both return "L:?" -> the distinctness
# asserts below fail. The plain-int control (distinct int literals already
# fingerprint distinctly) passes both pre- and post-fix.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_plan_expr.expr import Expr, BIN_LT
from komira_plan_expr.scalar_value import ScalarValue

from komira_plan_ir.plan_helpers import _scalar_fingerprint, _expr_fingerprint


def test_scalar_fingerprint_distinct_dates() raises:
    var a = _scalar_fingerprint(ScalarValue.date32(Int32(100)))
    var b = _scalar_fingerprint(ScalarValue.date32(Int32(200)))
    assert_true(
        a != b,
        "distinct DATE32 literals must fingerprint distinctly (got a=="
        + a + ", b==" + b + ")",
    )


def test_scalar_fingerprint_date_not_collide_with_int() raises:
    # A date literal (days=100) and an int literal (100) must NOT share a
    # fingerprint — they are different logical values / kinds.
    var d = _scalar_fingerprint(ScalarValue.date32(Int32(100)))
    var i = _scalar_fingerprint(ScalarValue.from_int(100))
    assert_true(
        d != i,
        "DATE32(100) must not fingerprint-collide with int 100 (got d=="
        + d + ", i==" + i + ")",
    )


def test_scalar_fingerprint_identical_dates_stable() raises:
    # Two structurally-identical date literals MUST fingerprint equal (dedup is
    # allowed to collapse genuinely-identical subexprs).
    var a = _scalar_fingerprint(ScalarValue.date32(Int32(175)))
    var b = _scalar_fingerprint(ScalarValue.date32(Int32(175)))
    assert_equal(a, b, "identical DATE32 literals must fingerprint equal")


def test_expr_fingerprint_distinct_date_predicates() raises:
    # The end-to-end shape the dedup consumes: `d < DATE a` vs `d < DATE b`.
    var pa = Expr.binary(
        BIN_LT, Expr.col_ref("d"), Expr.literal(ScalarValue.date32(Int32(100)))
    )
    var pb = Expr.binary(
        BIN_LT, Expr.col_ref("d"), Expr.literal(ScalarValue.date32(Int32(200)))
    )
    var fa = _expr_fingerprint(pa^)
    var fb = _expr_fingerprint(pb^)
    assert_true(
        fa != fb,
        "distinct date-comparison predicates must fingerprint distinctly (dedup"
        " must NOT collapse them) (got fa==" + fa + ", fb==" + fb + ")",
    )


def test_plain_int_fingerprint_control() raises:
    # CONTROL — distinct int literals already fingerprint distinctly; the fix
    # must leave this byte-identical (passes pre- AND post-fix).
    var a = _scalar_fingerprint(ScalarValue.from_int(100))
    var b = _scalar_fingerprint(ScalarValue.from_int(200))
    assert_true(a != b, "distinct int literals must fingerprint distinctly")


def main() raises:
    var suite = TestSuite()
    suite.test[test_scalar_fingerprint_distinct_dates]()
    suite.test[test_scalar_fingerprint_date_not_collide_with_int]()
    suite.test[test_scalar_fingerprint_identical_dates_stable]()
    suite.test[test_expr_fingerprint_distinct_date_predicates]()
    suite.test[test_plain_int_fingerprint_control]()
    suite^.run()
