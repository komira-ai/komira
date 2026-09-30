# The twin of test_env_and_tmp.mojo: the same assertions from another action.
# private (not /tmp), empty at the start, and is TMPDIR; the env arrives.
from std.os import getenv, listdir
from std.os.path import exists
from std.testing import assert_equal, assert_false


def main() raises:
    var t = getenv("TEST_TMPDIR")
    assert_false(t == "", "TEST_TMPDIR is unset")
    assert_false(t == "/tmp" or t.startswith("/tmp/"), t)
    assert_equal(len(listdir(t)), 0, "TEST_TMPDIR must start empty")
    assert_equal(getenv("TMPDIR"), t)
    # A file the other test (test_env_and_tmp_twin) leaves behind would be here
    # if the two shared a directory.
    assert_false(exists(t + "/left_by_twin"))
    with open(t + "/left_by_twin", "w") as f:
        f.write("x")
    assert_equal(getenv("TD_MODE"), "tests")
    print("test_env_and_tmp_twin: PASS")
