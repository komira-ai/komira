"""The producer's read-set capture (producer/komira_udf_readset.py) over the
row functions of pyrt/udf_rows.py and a few written here.

What it proves, and the defect each part catches:
  - the bytecode scan finds constant attribute and subscript reads on every
    branch (`row.b if row.a > 0 else row.c` reads a, b and c), in input
    order: a scan that sees one branch, or misses `row["qty"]`, gives a read
    set too small, which the runtime would refuse mid-run;
  - every use of the row the scan cannot read a name from (passing it on, a
    computed key, a method call, iteration in a generator, reassignment, a
    lambda capturing it, a callable that is not a plain function) gives
    every input column, with a note: a guessed read set too small;
  - columns=[...] wins over the scan, and names the input lacks, repeated
    names and a function not of one row are refused by name;
  - the sample run is a cross-check: it records what the function read on
    the rows it saw (a subset on a data-dependent function), and a read
    outside a declared read set fails at capture with the field's name
    (UDF_ROW_READ_SET_MISSED) instead of at run time.

Mutant planted: komira_udf_readset.scan without its LOAD_CONST +
BINARY_SUBSCR arm (a constant subscript treated as a whole-row use): red
(price_qty_keys came out every_column).
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "producer"))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "pyrt"))

import komira_udf_readset as rs  # noqa: E402
import udf_rows  # noqa: E402

COLS = ["c0", "price", "c2", "qty"]
ABC = ["a", "b", "c"]


def expect_error(code, fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except rs.ReadSetError as e:
        assert e.code == code, "{}: got {}".format(code, e)
        return str(e)
    raise AssertionError("expected {}".format(code))


def static(f, cols):
    r = rs.read_set(f, cols)
    assert r.source == rs.SOURCE_STATIC, "{}: {}".format(f, r)
    return r.names


def every(f, cols, why):
    r = rs.read_set(f, cols)
    assert r.source == rs.SOURCE_EVERY_COLUMN, "{}: {}".format(f, r)
    assert r.names == cols, r
    assert why in r.note, "{}: note {!r} lacks {!r}".format(f, r.note, why)
    assert "columns=[...]" in r.note, r.note


def test_scan():
    assert static(udf_rows.price_qty, COLS) == ["price", "qty"]
    assert static(udf_rows.price_qty_keys, COLS) == ["price", "qty"]
    assert static(udf_rows.branchy, ABC) == ["a", "b", "c"]
    assert static(udf_rows.pick, ["flag", "a", "b"]) == ["flag", "a", "b"]
    assert static(udf_rows.nullable_half, ["x", "y"]) == ["x"]
    # input order, not the order of reads
    assert static(lambda row: row.qty - row.price, COLS) == ["price", "qty"]
    # a field read on two paths is listed once; a value read twice too
    assert static(lambda r: r.qty if r.qty > r.price else r.qty, COLS) == ["price", "qty"]
    # an attribute of a field's value is not a field
    assert static(lambda r: r.price.real, COLS) == ["price"]


def g_method(row):
    return row.get("price")


def g_reassigned(row):
    row = {"price": 1.0}
    return row["price"]


def g_lambda(row):
    return (lambda: row.price)()


def g_returned(row):
    return row


def test_undetermined():
    every(udf_rows.via_helper, COLS, "other than by a constant field name")
    every(udf_rows.by_name, COLS, "")
    every(udf_rows.summed, COLS, "captures the row")
    every(g_method, COLS, "a method of the row is called: .get")
    every(g_reassigned, COLS, "reassigned")
    every(g_lambda, COLS, "captures the row")
    every(g_returned, COLS, "other than by a constant field name")
    every(len, COLS, "not a plain Python function")


def test_refusals():
    msg = expect_error("UDF_ROW_COLUMN_UNKNOWN", rs.read_set, udf_rows.typo, COLS)
    assert "'prise'" in msg, msg
    expect_error("UDF_ROW_SIGNATURE", rs.read_set, udf_rows.two_rows, COLS)
    expect_error("UDF_ROW_SIGNATURE", rs.read_set, lambda *rows: 0, COLS)
    expect_error("UDF_ROW_SIGNATURE", rs.read_set, udf_rows.two_rows, COLS, columns=["price"])
    msg = expect_error("UDF_ROW_COLUMN_UNKNOWN", rs.read_set, udf_rows.price_qty, COLS, columns=["price", "zz"])
    assert "'zz'" in msg, msg
    expect_error("UDF_ROW_READ_SET_INVALID", rs.read_set, udf_rows.price_qty, COLS, columns=["qty", "qty"])


def test_columns_override():
    r = rs.read_set(udf_rows.branchy, ABC, columns=["b", "a"])
    assert (r.names, r.source) == (["a", "b"], rs.SOURCE_COLUMNS), r
    # a function the scan cannot read is narrowed by the declaration
    r = rs.read_set(udf_rows.via_helper, COLS, columns=["qty", "price"])
    assert (r.names, r.source) == (["price", "qty"], rs.SOURCE_COLUMNS), r


def test_sample_cross_check():
    # A data-dependent function: the sample (a > 0 on every row) records
    # {a, b}; the scan's read set keeps c, so the check passes.
    sample = [{"a": 1.0, "b": 2.0, "c": 3.0}]
    r = rs.read_set(udf_rows.branchy, ABC, sample=sample)
    assert (r.names, r.recorded) == (["a", "b", "c"], ["a", "b"]), r
    # A declaration that misses a field the sample reads fails here, by name.
    sample = [{"a": 1.0, "b": 2.0, "c": 3.0}, {"a": -1.0, "b": 2.0, "c": 3.0}]
    msg = expect_error("UDF_ROW_READ_SET_MISSED", rs.read_set, udf_rows.branchy, ABC, columns=["a", "b"], sample=sample)
    assert "['c']" in msg and "columns=[...]" in msg, msg
    # The same declaration over rows that never take the other branch
    # passes: the sample is a check, not the source (the run-time error is
    # the safety net).
    r = rs.read_set(udf_rows.branchy, ABC, columns=["a", "b"], sample=sample[:1])
    assert r.names == ["a", "b"] and r.recorded == ["a", "b"], r
    # The recording row stops at a whole-row operation.
    reads, whole = rs.record(lambda row: [row.a for _ in row], [{"a": 1.0}])
    assert whole == "the row is iterated" and reads == [], (reads, whole)
    reads, whole = rs.record(lambda row: row.a + len(row), [{"a": 1.0}])
    assert whole == "the length of the row is taken" and reads == ["a"], (reads, whole)


test_scan()
test_undetermined()
test_refusals()
test_columns_override()
test_sample_cross_check()
print("test_readset: ok")
