# The test support of the UDF host tests: the spike descriptor `echo_ref`
# records, and the int64 columns the tests build and read.
#
# What it proves: the descriptor of a two-argument scalar fixture is exactly
# the canonical bytes komira_udf_spike_descriptor.h states (entry, shape
# varint, one named field per argument, the unnamed result, in that order),
# so the reference runtime's validate accepts every UdfRef the host tests
# make; and a column written with NULLs reads back with them, so a test that
# reads a NULL where a value belongs fails.
# Catches: a field out of order or a default emitted (echo refuses a
# non-canonical descriptor, and every host test would fail at load for a
# reason that is not its own); a read that drops a NULL.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from plan_ir.udf_ref import CODE_FORM_BUNDLE, CODE_FORM_PACKAGE, UDF_REF_KIND_MAP_BATCHES_COLUMN

from komira_test_udf_host.echo_udfs import (
    ECHO_RUNTIME,
    bundle_ref,
    echo_descriptor,
    echo_ref,
    int64_column,
    read_int64,
    render,
)


def test_the_descriptor_is_the_canonical_spike_message() raises:
    var formats: List[String] = ["l", "l"]
    var got = echo_descriptor("ab", 1, formats, "l")
    # 0a 02 'a' 'b' | 10 01 | 1a 07 (0a 02 'a' '0' 12 01 'l') | the same for a1 | 22 03 (12 01 'l')
    var want: List[UInt8] = [
        0x0A, 2, 0x61, 0x62,
        0x10, 1,
        0x1A, 7, 0x0A, 2, 0x61, 0x30, 0x12, 1, 0x6C,
        0x1A, 7, 0x0A, 2, 0x61, 0x31, 0x12, 1, 0x6C,
        0x22, 3, 0x12, 1, 0x6C,
    ]
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "byte " + String(i))


def test_a_ref_names_the_echo_runtime_and_its_shape() raises:
    var u = echo_ref("double", 1)
    assert_equal(u.code.runtime, ECHO_RUNTIME)
    assert_equal(u.code.form, CODE_FORM_PACKAGE)
    assert_equal(len(u.arg_types), 1)
    assert_true(u.return_type.value().nullable)
    var col = echo_ref("identity", 1, kind=UDF_REF_KIND_MAP_BATCHES_COLUMN, nullable_result=False)
    # The shape varint is the fourth and fifth bytes after the 8-byte entry field.
    assert_equal(col.code.descriptor[2 + 8 + 1], 4)
    assert_false(col.return_type.value().nullable)
    var b = bundle_ref("double", [UInt8(1), UInt8(2)])
    assert_equal(b.code.form, CODE_FORM_BUNDLE)
    assert_equal(b.code.code[0].role, "bundle")


def test_a_column_keeps_its_nulls() raises:
    var col = int64_column([Int64(1), Int64(0), Int64(3)], [False, True])
    assert_equal(render(read_int64(col)), "[1, NULL, 3]")


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_descriptor_is_the_canonical_spike_message]()
    suite.test[test_a_ref_names_the_echo_runtime_and_its_shape]()
    suite.test[test_a_column_keeps_its_nulls]()
    suite^.run()
