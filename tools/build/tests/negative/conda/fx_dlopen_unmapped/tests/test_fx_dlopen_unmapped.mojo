from fx_dlopen_unmapped import fx_dlopen_unmapped_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_dlopen_unmapped_value(), 8, "the fixture's own value")
    print("test_fx_dlopen_unmapped: PASS")
