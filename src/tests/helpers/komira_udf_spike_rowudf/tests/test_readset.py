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

  - each instruction shape CPython 3.13 loads or stores the row with
    (LOAD_FAST_LOAD_FAST and STORE_FAST_LOAD_FAST with the row on either
    side, STORE_FAST_STORE_FAST, DELETE_FAST, LOAD_FAST_CHECK,
    LOAD_FAST_AND_CLEAR, an EXTENDED_ARG prefix) is read as such, each
    asserted present in the function's bytecode, so a scan that misreads
    one shape is caught on its own function;
  - the producer's errors, sources and notes are the exact strings the plan
    and the oracle carry.

Every single-point mutant of komira_udf_readset.py was run against this
file (the PR's mutation scorecard). Mutant planted by hand:
komira_udf_readset.scan without its LOAD_CONST + BINARY_SUBSCR arm (a
constant subscript treated as a whole-row use): red (price_qty_keys came
out every_column).
"""

import dis
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
    assert r.source == "static" == rs.SOURCE_STATIC, "{}: {}".format(f, r)
    assert r.note == "" and r.recorded == [], r
    assert rs.scan(f)[1] == "", rs.scan(f)
    return r.names


def every(f, cols, why):
    r = rs.read_set(f, cols)
    assert r.source == "every_column" == rs.SOURCE_EVERY_COLUMN, "{}: {}".format(f, r)
    assert r.names == cols, r
    assert why in r.note, "{}: note {!r} lacks {!r}".format(f, r.note, why)
    assert r.note.endswith("; every input column is passed (add columns=[...] to narrow it)"), r.note


def has(f, opname, pred=lambda argval: True):
    """Asserts f's bytecode holds `opname` with an argval `pred` accepts: the
    shape a scan case is about is really there."""
    found = [i.argval for i in dis.get_instructions(f) if i.opname == opname]
    assert any(pred(a) for a in found), "{}: no {} matching in {}".format(f.__name__, opname, found)


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


# ---- one function per instruction shape --------------------------------------


def s_store_plain(row):
    v = row.price
    w = 2.0
    return v * w


def s_unpack(row):
    a, b = row.price, row.qty
    return a * b


# CPython 3.13 fuses a store and a load into one instruction only within a
# line, hence the semicolons.
def s_store_load(row):
    p = row.price; return row.qty * p  # noqa: E702


def s_load_load(row):
    y = row.qty
    if y > 0:
        return y * row.price
    return 0.0


def g_unpack_row(row):
    v = row.price
    a, row = 1.0, 2.0
    return v


def g_store_load_row(row):
    v = row.price
    row = v; return v  # noqa: E702


def g_store_row(row):
    v = row.price
    row = None
    return 0.0


def g_del(row):
    v = row.price
    del row
    return v


def g_check(row):
    for _ in (1, 2):
        v = row
        del row
    return 0.0


def g_shadow(row):
    return [row for row in (1, 2)]


KEY = "price"


def helper(row, key):
    return 0.0


class Holder:
    def m(self, row):
        return row.price


def g_method(row):
    return row.get("price")


def g_reassigned(row):
    row = {"price": 1.0}
    return row["price"]


def g_lambda(row):
    return (lambda: row.price)()


def g_returned(row):
    return row


def test_shapes():
    has(s_store_plain, "STORE_FAST", lambda a: a == "v")
    assert static(s_store_plain, COLS) == ["price"]
    has(s_unpack, "STORE_FAST_STORE_FAST", lambda a: "row" not in a)
    assert static(s_unpack, COLS) == ["price", "qty"]
    has(s_store_load, "STORE_FAST_LOAD_FAST", lambda a: a == ("p", "row"))
    assert static(s_store_load, COLS) == ["price", "qty"]
    has(s_load_load, "LOAD_FAST_LOAD_FAST", lambda a: a == ("y", "row"))
    assert static(s_load_load, COLS) == ["price", "qty"]
    has(g_unpack_row, "STORE_FAST_STORE_FAST", lambda a: "row" in a)
    every(g_unpack_row, COLS, "the row parameter is reassigned;")
    has(g_store_load_row, "STORE_FAST_LOAD_FAST", lambda a: a[0] == "row")
    every(g_store_load_row, COLS, "the row parameter is reassigned;")
    has(g_store_row, "STORE_FAST", lambda a: a == "row")
    every(g_store_row, COLS, "the row parameter is reassigned or deleted")
    has(g_del, "DELETE_FAST", lambda a: a == "row")
    every(g_del, COLS, "the row parameter is reassigned or deleted")
    # The row loaded where it may be unbound, or saved around a
    # comprehension, then used as a value: that use is the reason, not the
    # deletion or the store after it.
    has(g_check, "LOAD_FAST_CHECK", lambda a: a == "row")
    every(g_check, COLS, "the row is used other than by a constant field name")
    has(g_shadow, "LOAD_FAST_AND_CLEAR", lambda a: a == "row")
    every(g_shadow, COLS, "the row is used other than by a constant field name")
    # More than 128 names: LOAD_ATTR takes an EXTENDED_ARG prefix.
    names = ["f{}".format(k) for k in range(300)]
    ns = {}
    exec("def wide(row):\n    return " + " + ".join("row." + n for n in names) + "\n", ns)
    assert "EXTENDED_ARG" in [i.opname for i in dis.get_instructions(ns["wide"])]
    assert static(ns["wide"], names) == names


def test_undetermined():
    every(udf_rows.via_helper, COLS, "other than by a constant field name")
    every(udf_rows.by_name, COLS, "the row is used as a value (line")
    every(udf_rows.summed, COLS, "captures the row")
    every(g_method, COLS, "a method of the row is called: .get")
    every(g_reassigned, COLS, "reassigned")
    every(g_lambda, COLS, "captures the row")
    every(g_returned, COLS, "other than by a constant field name")
    every(len, COLS, "not a plain Python function")
    every(Holder().m, COLS, "not a plain Python function")
    every(lambda row: row[0], COLS, "other than by a constant field name")
    every(lambda row: row[KEY], COLS, "other than by a constant field name")
    every(lambda row: helper(row, "price"), COLS, "other than by a constant field name")


def g_kwonly(row, *, k=1):
    return row.price


def g_varargs(row, *rest):
    return row.price


def g_varkw(row, **kw):
    return row.price


def test_refusals():
    msg = expect_error("UDF_ROW_COLUMN_UNKNOWN", rs.read_set, udf_rows.typo, COLS)
    assert msg == "UDF_ROW_COLUMN_UNKNOWN: the function reads 'prise'; the input has {}".format(COLS), msg
    msg = expect_error("UDF_ROW_SIGNATURE", rs.read_set, udf_rows.two_rows, COLS)
    assert msg == "UDF_ROW_SIGNATURE: two_rows must take exactly one positional parameter, the row", msg
    for f in (g_kwonly, g_varargs, g_varkw):
        expect_error("UDF_ROW_SIGNATURE", rs.read_set, f, COLS)
    expect_error("UDF_ROW_SIGNATURE", rs.read_set, lambda *rows: 0, COLS)
    expect_error("UDF_ROW_SIGNATURE", rs.read_set, udf_rows.two_rows, COLS, columns=["price"])
    msg = expect_error("UDF_ROW_COLUMN_UNKNOWN", rs.read_set, udf_rows.price_qty, COLS, columns=["price", "zz"])
    assert "'zz'" in msg, msg
    expect_error("UDF_ROW_READ_SET_INVALID", rs.read_set, udf_rows.price_qty, COLS, columns=["qty", "qty"])


def test_columns_override():
    r = rs.read_set(udf_rows.branchy, ABC, columns=["b", "a"])
    assert (r.names, r.source, r.note) == (["a", "b"], "columns", ""), r
    assert rs.SOURCE_COLUMNS == "columns"
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
    # It stops there: later rows are not run.
    two = [{"a": -1.0, "b": 0.0}, {"a": 1.0, "b": 2.0}]
    reads, whole = rs.record(lambda row: len(row) if row.a < 0 else row.b, two)
    assert (reads, whole) == (["a"], "the length of the row is taken"), (reads, whole)
    for f, why in (
        (lambda row: "a" in row, "membership is tested on the row"),
        (lambda row: row.keys(), "the row's keys are listed"),
        (lambda row: row[0], "the row is indexed by a int"),
    ):
        reads, whole = rs.record(f, [{"a": 1.0}])
        assert (reads, whole) == ([], why), (reads, whole)
    # A dunder the language probes for is not a field; other names are.
    probe = lambda row: getattr(row, "__x", 0) + getattr(row, "y__", 0) + (1 if hasattr(row, "__array__") else 0)
    reads, whole = rs.record(probe, [{}])
    assert (reads, whole) == (["__x", "y__"], ""), (reads, whole)


test_scan()
test_shapes()
test_undetermined()
test_refusals()
test_columns_override()
test_sample_cross_check()
print("test_readset: ok")
