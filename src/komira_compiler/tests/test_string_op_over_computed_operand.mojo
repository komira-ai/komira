"""A string PREDICATE over a COMPUTED operand — `lower(s) LIKE 'a%'`,
`starts_with(upper(s), 'A')` — in BOTH evaluation contexts.

THE DEFECT. `EXPR_STRING_OP` (LIKE / contains / starts_with / ends_with)
resolved its child with `resolve_col_index`, i.e. it assumed a BARE column.
Any other child raised, in a WHERE and in a projection alike,

    PipelineCompiler: cannot resolve column index from expression tag: 24

MEASURED through the SQL door:
`WHERE lower(s) LIKE 'a%'`, `SELECT lower(s) LIKE 'a%'`,
`SELECT starts_with(lower(s), 'a')`, `WHERE contains(upper(s), 'B')` all raised
where DuckDB v1.5.3 answers every one. It is also why SQL `ILIKE` could not run
at all: DuckDB DEFINES `x ILIKE p` as `lower(x) LIKE lower(p)`, and that is the
plan the SQL binder builds for it.

THE FIX. The operand is materialized with `_eval_column_expr` first — the
shape the computed-LHS comparison arm already uses for `a * b > 100` — and the
same pattern kernels run over the computed column
(`compiler_eval_predicate._eval_string_op_on_column`). The PROJECTION arm reads
the NULL mask off that same computed column, so a NULL operand is a NULL
answer there (DuckDB: `SELECT NULL::VARCHAR ILIKE 'a%'` is NULL), not FALSE.

RED BEFORE THE FIX: every test below except the two CONTROLS raises the
tag-24 Error. The controls (a bare column) pass before and after, which is what
proves the red is about the computed operand and not about the fixture.
"""

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.schema import (
    SchemaBuilder,
    Field,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_core.plan.expr import (
    Expr,
    STRFN_LOWER,
    STRFN_UPPER,
    STR_LIKE,
    STR_STARTS_WITH,
    STR_CONTAINS,
)
from komira_compiler.compiler_eval_predicate import _eval_predicate
from komira_compiler.compiler_eval_column import _eval_column_expr


# s = ["Abc", "aBC", NULL, "ÄBC", "xyz", "a%c"] — the fixture the SQL-door
# row probe measured DuckDB over.
comptime _N = 6


def _s_batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    var vals = List[String]()
    vals.append(String("Abc"))
    vals.append(String("aBC"))
    vals.append(String(""))
    vals.append(String("ÄBC"))
    vals.append(String("xyz"))
    vals.append(String("a%c"))
    var valid = List[Bool]()
    for i in range(_N):
        valid.append(i != 2)
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    )
    return rb.build(sb.build())


def _s() -> Expr:
    return Expr.col_ref(String("s"))


def _lower_s() -> Expr:
    return Expr.string_fn(STRFN_LOWER, _s())


def _mask_bits(e: Expr, batch: RecordBatch) raises -> List[Bool]:
    """The predicate context's DATA bits (a NULL row selects nothing)."""
    var m = _eval_predicate(e, batch)
    var out = List[Bool]()
    for i in range(batch.num_rows()):
        out.append(m.get(i))
    return out^


def _assert_bits(got: List[Bool], want: List[Bool], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def test_where_lower_s_LIKE_a_pct_selects_the_case_folded_rows() raises:
    """`WHERE lower(s) LIKE 'a%'` -> rows 0, 1, 5 (DuckDB v1.5.3: k 1, 2, 6).
    Row 3 `ÄBC` folds to `äbc`, which does not start with `a`."""
    var e = Expr.string_op(STR_LIKE, _lower_s(), String("a%"))
    var want: List[Bool] = [True, True, False, False, False, True]
    _assert_bits(_mask_bits(e, _s_batch()), want, String("lower(s) LIKE 'a%'"))


def test_where_lower_s_LIKE_folds_non_ascii_like_duckdb() raises:
    """`lower(s) LIKE 'ä%'` -> row 3 alone (DuckDB: `s ILIKE 'ä%'` = k 4)."""
    var e = Expr.string_op(STR_LIKE, _lower_s(), String("ä%"))
    var want: List[Bool] = [False, False, False, True, False, False]
    _assert_bits(_mask_bits(e, _s_batch()), want, String("lower(s) LIKE 'ä%'"))


def test_where_contains_upper_s() raises:
    """`contains(upper(s), 'B')` -> rows 0, 1, 3 (DuckDB: k 1, 2, 4)."""
    var e = Expr.string_op(
        STR_CONTAINS, Expr.string_fn(STRFN_UPPER, _s()), String("B")
    )
    var want: List[Bool] = [True, True, False, True, False, False]
    _assert_bits(_mask_bits(e, _s_batch()), want, String("contains(upper(s), 'B')"))


def test_projection_lower_s_LIKE_answers_NULL_for_a_NULL_operand() raises:
    """`SELECT lower(s) LIKE 'a%'` -> [T, T, NULL, F, F, T] (DuckDB v1.5.3).
    ⛔ Row 2 must be NULL, not FALSE: a projection can see UNKNOWN."""
    var e = Expr.string_op(STR_LIKE, _lower_s(), String("a%"))
    var batch = _s_batch()
    var col = _eval_column_expr(e, batch)
    assert_true(col.arrow_type == ArrowType.BOOL, "a BOOL column")
    var ba = col.as_boolean()
    assert_true(ba.is_null(2), "row 2 (NULL operand) is NULL")
    var want: List[Bool] = [True, True, False, False, False, True]
    for i in range(_N):
        if i == 2:
            continue
        assert_true(not ba.is_null(i), "row " + String(i) + " is not NULL")
        assert_equal(ba.get(i), want[i], "row " + String(i))


def test_projection_starts_with_lower_s() raises:
    """`SELECT starts_with(lower(s), 'a')` -> [T, T, NULL, F, F, T]."""
    var e = Expr.string_op(STR_STARTS_WITH, _lower_s(), String("a"))
    var col = _eval_column_expr(e, _s_batch())
    var ba = col.as_boolean()
    assert_true(ba.is_null(2), "row 2 is NULL")
    assert_equal(ba.get(0), True, "Abc")
    assert_equal(ba.get(3), False, "ÄBC -> äbc")
    assert_equal(ba.get(5), True, "a%c")


def test_CONTROL_bare_column_LIKE_in_a_predicate() raises:
    """CONTROL — a bare column (the path that always worked): `s LIKE 'a%'`
    -> rows 1, 5 (case-SENSITIVE)."""
    var e = Expr.string_op(STR_LIKE, _s(), String("a%"))
    var want: List[Bool] = [False, True, False, False, False, True]
    _assert_bits(_mask_bits(e, _s_batch()), want, String("s LIKE 'a%'"))


def test_CONTROL_bare_column_LIKE_in_a_projection() raises:
    """CONTROL — `SELECT s LIKE 'a%'` -> [F, T, NULL, F, F, T]."""
    var e = Expr.string_op(STR_LIKE, _s(), String("a%"))
    var ba = _eval_column_expr(e, _s_batch()).as_boolean()
    assert_true(ba.is_null(2), "row 2 is NULL")
    assert_equal(ba.get(1), True, "aBC")
    assert_equal(ba.get(0), False, "Abc")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
