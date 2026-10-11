# The committed read sets (golden/read_sets.tsv) read back into UDF
# references (read_sets.mojo), with no runtime: the part of the row path
# that does not depend on how the UDF runs.
#
# What it proves, and the defect each part catches:
#   - a PRESENT read set becomes the UdfSpec's argument names in the read
#     set's order, sorted by UTF-8 bytes (pick's {flag, a, b} reads a, b,
#     flag), one typed field each (a read set dropped or left in the
#     input's order);
#   - an ABSENT one (the scan could not bound the reads) is told apart and
#     gives every input column (a reader that takes `absent` for a column
#     name, or for an empty set);
#   - an EMPTY one (present, no columns) is present with no arguments (a
#     reader that takes it for ABSENT and passes every column);
#   - a read-set field that is neither `absent` nor bracketed is refused by
#     name (a malformed table read as some other set).
#
# Mutant planted: read_sets.mojo before this change (it read the bracketed
# field as one column named "[price" and so on): red.

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_udf_spike_abi.values import TYPE_FLOAT64
from komira_udf_spike_rowudf.read_sets import load_read_sets, read_set_of, row_spec


def main() raises:
    var sets = load_read_sets()
    var p = read_set_of(sets, "price_qty@4")
    assert_true(p.present, "price_qty@4 is present")
    assert_equal(len(p.read_set), 2)
    assert_equal(p.read_set[0], "price")
    assert_equal(p.read_set[1], "qty")
    var spec = row_spec(p.entry, p.read_set, TYPE_FLOAT64, TYPE_FLOAT64)
    assert_equal(len(spec.arg_names), 2)
    assert_equal(spec.arg_names[1], "qty")
    var v = read_set_of(sets, "via_helper")
    assert_false(v.present, "via_helper's read set is absent")
    assert_equal(v.source, "absent")
    assert_equal(len(v.read_set), 4, "absent: every input column")
    for i in range(4):
        assert_equal(v.read_set[i], v.input[i])
    var c = read_set_of(sets, "constant")
    assert_true(c.present, "constant's read set is present")
    assert_equal(len(c.read_set), 0, "empty: no columns")
    assert_equal(len(row_spec(c.entry, c.read_set, TYPE_FLOAT64, TYPE_FLOAT64).arg_names), 0)
    # Sorted by UTF-8 bytes, not in the input's order (flag, a, b).
    var k = read_set_of(sets, "pick")
    assert_equal(len(k.read_set), 3)
    assert_true(k.read_set[0] == "a" and k.read_set[1] == "b" and k.read_set[2] == "flag", "pick sorted")
    assert_equal(k.input[0], "flag")
    var d = read_set_of(sets, "branchy_declared_ab")
    assert_true(d.present and d.source == "columns" and len(d.read_set) == 2, "columns=[a, b]")
    with open("bad_read_sets.tsv", "w") as f:
        f.write("x\tudf_rows:x\ta,b\tstatic\ta,b\t\t\n")
    with assert_raises(contains="UDF_READ_SETS_MALFORMED: read set 'a,b' of x is neither absent nor [...]"):
        _ = load_read_sets("bad_read_sets.tsv")
    print("test_read_sets: ok")
