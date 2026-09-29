# The gate of komira_runtime_paths runs this in the staged tree of the test
# runtime contract (tools/build/mojo/README.md): the current directory is
# share/, which holds only the declared data; TEST_TMPDIR, TMPDIR and HOME are
# private to the run; `test_env` values arrive.
from komira_runtime_paths import (
    data_path,
    executable_path,
    install_root,
    read_data,
    share_dir,
    test_tmpdir,
)
from std.os import getenv, listdir
from std.os.path import exists, isdir
from std.testing import assert_equal, assert_false, assert_raises, assert_true

comptime _GREETING = "tools/build/mojo/runtime_paths/fixtures/greeting.txt"


def main() raises:
    # Declared at its repository path, and the current directory is share/,
    # so the repository-relative path opens as-is.
    with open(_GREETING, "r") as f:
        assert_equal(f.read(), "hello from share\n")
    # The same file through the executable-relative helper.
    assert_equal(read_data(_GREETING), "hello from share\n")
    # A dict entry is staged at its key.
    assert_equal(read_data("renamed/other.txt"), "renamed on the way in\n")

    # The layout: <root>/bin/<exe>, <root>/share.
    var exe = executable_path()
    assert_true(exe.startswith(install_root() + "/bin/"), exe)
    assert_equal(share_dir(), install_root() + "/share")
    assert_equal(data_path("a/b.txt"), share_dir() + "/a/b.txt")
    with assert_raises():
        _ = data_path("../bin/x")
    with assert_raises():
        _ = data_path("/etc/passwd")

    # Undeclared files are absent: this library's own source and the fixture
    # nobody declared both exist in the repository.
    assert_false(exists("tools/build/mojo/runtime_paths/paths.mojo"))
    assert_false(exists("tools/build/mojo/runtime_paths/fixtures/undeclared.txt"))
    with assert_raises():
        _ = read_data("tools/build/mojo/runtime_paths/fixtures/undeclared.txt")

    # TEST_TMPDIR: set, private, empty at the start, writable; TMPDIR is it.
    var t = test_tmpdir()
    assert_true(isdir(t), t)
    assert_false(t == "/tmp" or t.startswith("/tmp/"), t)
    assert_equal(len(listdir(t)), 0, "TEST_TMPDIR must start empty")
    assert_equal(getenv("TMPDIR"), t)
    var home = getenv("HOME")
    assert_true(home != "" and home != t and isdir(home), home)
    with open(t + "/probe.txt", "w") as f:
        f.write("written")
    with open(t + "/probe.txt", "r") as f:
        assert_equal(f.read(), "written")

    # test_env reaches the test.
    assert_equal(getenv("KOMIRA_TEST_GREETING"), "hello, env")
    print("test_runtime_paths: PASS")
