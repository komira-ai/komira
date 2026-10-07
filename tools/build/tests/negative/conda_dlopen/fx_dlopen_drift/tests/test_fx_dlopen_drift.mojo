from fx_dlopen_drift import fx_dlopen_drift_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_dlopen_drift_value(), 7, "the fixture's own value")
    print("test_fx_dlopen_drift: PASS")
