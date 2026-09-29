from std.ffi import external_call
from std.testing import assert_equal


def main() raises:
    # assert_equal on Int32 records this file's source location; see
    # tests/test_cadd.mojo.
    assert_equal(external_call["komira_example_add", Int32](Int32(40), Int32(2)), Int32(42))
    print("test_add_direct: PASS")
