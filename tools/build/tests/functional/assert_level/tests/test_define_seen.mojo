# Passes only when the build passed `-D KOMIRA_PROBE_DEFINE=on`
# (test_defines), read both in this file and inside the library's package.
from alevel import library_define
from std.sys.defines import get_defined_string
from std.testing import assert_equal


def main() raises:
    assert_equal(String(get_defined_string["KOMIRA_PROBE_DEFINE", "unset"]()), "on", "-D KOMIRA_PROBE_DEFINE read in the test")
    assert_equal(library_define(), "on", "-D KOMIRA_PROBE_DEFINE read in the library's package")
