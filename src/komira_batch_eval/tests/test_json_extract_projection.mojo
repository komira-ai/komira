"""`json_extract` through the projection evaluator.

`_eval_column_expr` hands an `EXPR_JSON_EXTRACT` node to the kernel in
`komira_json_index`. This test drives that edge end to end, so the package's
dependency on `komira_json_index` is exercised by a test of its own rather
than only by the kernel's tests:

  - `->>` (plain string output) returns the unquoted leaf,
  - a missing key and a NULL input row are NULL in the output,
  - `->` (extension-metadata output) keeps the JSON text of the leaf.
"""

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    SchemaBuilder,
    Field,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_plan_expr.expr import Expr
from komira_batch_eval.eval_column import _eval_column_expr


# j = [{"name":"alice","n":7}, {"n":8}, NULL, {"name":"carol","n":9}]
comptime _N = 4


def _j_batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("j"), ArrowType.STRING, True))
    var vals = List[String]()
    vals.append(String('{"name":"alice","n":7}'))
    vals.append(String('{"n":8}'))
    vals.append(String(""))
    vals.append(String('{"name":"carol","n":9}'))
    var valid = List[Bool]()
    for i in range(_N):
        valid.append(i != 2)
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    )
    return rb.build(sb.build())


def test_double_arrow_extracts_the_unquoted_leaf() raises:
    """`j ->> '$.name'` -> ['alice', NULL, NULL, 'carol']."""
    var e = Expr.json_extract_string(Expr.col_ref(String("j")), String("$.name"))
    var col = _eval_column_expr(e, _j_batch())
    assert_equal(col.length(), _N)
    var sa = col.as_string()
    assert_equal(sa.get(0), String("alice"))
    assert_true(sa.is_null(1), "row 1 has no `name`")
    assert_true(sa.is_null(2), "row 2 is a NULL input")
    assert_equal(sa.get(3), String("carol"))


def test_numeric_leaf_comes_back_as_text() raises:
    """`j ->> '$.n'` -> ['7', '8', NULL, '9']."""
    var e = Expr.json_extract_string(Expr.col_ref(String("j")), String("$.n"))
    var sa = _eval_column_expr(e, _j_batch()).as_string()
    assert_equal(sa.get(0), String("7"))
    assert_equal(sa.get(1), String("8"))
    assert_true(sa.is_null(2), "row 2 is a NULL input")
    assert_equal(sa.get(3), String("9"))


def test_json_valued_extract_keeps_json_text() raises:
    """`j -> '$.name'` keeps the quotes: the output is JSON text."""
    var e = Expr.json_extract_json(Expr.col_ref(String("j")), String("$.name"))
    var sa = _eval_column_expr(e, _j_batch()).as_string()
    assert_equal(sa.get(0), String('"alice"'))
    assert_true(sa.is_null(1), "row 1 has no `name`")
    assert_equal(sa.get(3), String('"carol"'))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
