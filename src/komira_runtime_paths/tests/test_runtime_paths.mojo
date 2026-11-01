# The gate of komira_runtime_paths. It runs in the installed layout (BUCK,
# `test_layout = "installed"`), the layout the library reads:
#
#   <root>/bin/<exe>      this test binary, a copy
#   <root>/share/...      the files declared under `test_data`, each key relative to share/
#   working directory     <root>
#
# TEST_TMPDIR, TMPDIR and HOME are private to the run; `test_env` values arrive.
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

comptime _GREETING = "fixtures/greeting.txt"


def _basename(path: String) -> String:
    var cut = 0
    for i in range(path.byte_length()):
        if path[byte=i] == "/":
            cut = i + 1
    return String(path[byte=cut:])


def main() raises:
    # The layout: <root>/bin/<exe>, <root>/share.
    var exe = executable_path()
    assert_true(exe.startswith("/"), exe)
    assert_equal(exe, install_root() + "/bin/" + _basename(exe))
    assert_equal(share_dir(), install_root() + "/share")
    assert_equal(data_path("a/b.txt"), share_dir() + "/a/b.txt")
    with assert_raises():
        _ = data_path("../bin/x")
    with assert_raises():
        _ = data_path("/etc/passwd")

    # The working directory is <root>: a relative path reaches bin/ and share/,
    # and the runner names share/ in BUILDRULES_TEST_DATA.
    assert_true(exists("bin/" + _basename(exe)), exe)
    assert_true(isdir("share"))
    assert_equal(getenv("BUILDRULES_TEST_DATA"), share_dir())

    # Declared under `test_data`, at its key under share/: through the
    # working directory and through the executable-relative helper.
    with open("share/" + _GREETING, "r") as f:
        assert_equal(f.read(), "hello from share\n")
    assert_equal(read_data(_GREETING), "hello from share\n")
    # A dict entry is staged at its key, not at the path of its source.
    assert_equal(read_data("renamed/other.txt"), "renamed on the way in\n")
    assert_false(exists("share/fixtures/other.txt"))

    # Undeclared files are absent: the fixture nobody declared and the
    # package's manifest both exist in the repository.
    assert_false(exists("share/fixtures/undeclared.txt"))
    assert_false(exists("share/mopm.toml"))
    with assert_raises():
        _ = read_data("fixtures/undeclared.txt")

    # TEST_TMPDIR: set, private, empty at the start, writable; TMPDIR is it.
    var t = test_tmpdir()
    assert_true(t.startswith("/"), t)
    assert_true(isdir(t), t)
    assert_equal(len(listdir(t)), 0, "TEST_TMPDIR must start empty")
    assert_equal(getenv("TMPDIR"), t)
    var home = getenv("HOME")
    assert_true(home.startswith("/") and home != t and isdir(home), home)
    assert_equal(len(listdir(home)), 0, "HOME must start empty")
    with open(t + "/probe.txt", "w") as f:
        f.write("written")
    with open(t + "/probe.txt", "r") as f:
        assert_equal(f.read(), "written")

    # test_env reaches the test.
    assert_equal(getenv("KOMIRA_TEST_GREETING"), "hello, env")
    print("test_runtime_paths: PASS")
