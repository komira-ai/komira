from libgate_ok import payload_width
from std.testing import assert_equal


def main() raises:
    assert_equal(payload_width(), 7, "the library's own value, read back")
    print("test_payload_passes: PASS")
