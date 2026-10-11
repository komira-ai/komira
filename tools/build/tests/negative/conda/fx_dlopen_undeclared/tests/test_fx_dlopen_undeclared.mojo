from fx_dlopen_undeclared import fx_dlopen_undeclared_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_dlopen_undeclared_value(), 7, "the fixture's own value")
    print("test_fx_dlopen_undeclared: PASS")
