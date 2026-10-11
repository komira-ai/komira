# Passes only when the build passed all of `-D ASSERT=none`, `-D
# KOMIRA_PROBE_DEFINE=on` and `-D KOMIRA_PROBE_SECOND=2`: safe_probe's
# debug_assert fires unless the level is none, and each define is read.
from alevel import library_define, safe_probe
from std.sys.defines import get_defined_string
from std.testing import assert_equal


def main() raises:
    assert_equal(safe_probe(1), 2, "safe_probe returned past its assert")
    assert_equal(library_define(), "on", "-D KOMIRA_PROBE_DEFINE read in the library's package")
    assert_equal(String(get_defined_string["KOMIRA_PROBE_SECOND", "unset"]()), "2", "-D KOMIRA_PROBE_SECOND read in the test")
