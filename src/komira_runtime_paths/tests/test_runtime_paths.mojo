# The gate of komira_runtime_paths. It runs in the staged directory that
# `test_data` names (BUCK): the current directory holds only the declared
# files; TEST_TMPDIR, TMPDIR and HOME are private to the run; `test_env`
# values arrive.
#
# The test executable is not at `<root>/bin/<name>` with its data under
# `<root>/share`: the runner keeps the executable in its build directory and the
# data in a directory of its own. So the layout the library reads is checked
# where it can be made: the test lays out a bundle under TEST_TMPDIR, copies
# its own executable to `<bundle>/bin/probe`, and starts that copy with
# KOMIRA_RUNTIME_PATHS_PROBE set. The copy runs `_probe` and prints what the
# library reports there; the test compares it with the bundle it built.
from komira_runtime_paths import (
    data_path,
    executable_path,
    install_root,
    read_data,
    share_dir,
    test_tmpdir,
)
from std.os import getenv, listdir, makedirs
from std.os.path import exists, isdir
from std.subprocess import run
from std.testing import assert_equal, assert_false, assert_raises, assert_true

comptime _GREETING = "fixtures/greeting.txt"
comptime _PROBE = "KOMIRA_RUNTIME_PATHS_PROBE"


def _probe() raises:
    """What the library reports for the bundle copy of this executable."""
    print("exe=" + executable_path())
    print("root=" + install_root())
    print("share=" + share_dir())
    print("greeting=" + String(read_data(_GREETING).strip()))
    print("other=" + String(read_data("renamed/other.txt").strip()))
    var refused = False
    try:
        _ = read_data("fixtures/undeclared.txt")
    except:
        refused = True
    print("undeclared_refused=" + String(refused))


def _field(text: String, key: String) raises -> String:
    """The value of the `key=value` line of the probe's output."""
    for line in text.split("\n"):
        if line.startswith(key + "="):
            return String(line[byte = key.byte_length() + 1 :])
    raise Error("probe output has no " + key + " line: " + text)


def main() raises:
    if getenv(_PROBE, "") != "":
        _probe()
        return

    # Declared under `test_data`, and the current directory is the staged
    # directory, so the staged path opens as-is.
    var greeting: String
    with open(_GREETING, "r") as f:
        greeting = f.read()
    assert_equal(greeting, "hello from share\n")
    var other: String
    with open("renamed/other.txt", "r") as f:
        other = f.read()
    assert_equal(other, "renamed on the way in\n")

    # The executable: an absolute path under the root the library reports, and
    # the share directory and a data path follow from that root.
    var exe = executable_path()
    assert_true(exe.startswith("/"), exe)
    assert_true(exe.startswith(install_root() + "/"), exe)
    assert_equal(share_dir(), install_root() + "/share")
    assert_equal(data_path("a/b.txt"), share_dir() + "/a/b.txt")
    with assert_raises():
        _ = data_path("../bin/x")
    with assert_raises():
        _ = data_path("/etc/passwd")

    # Undeclared files are absent: the fixture nobody declared and the
    # package's manifest both exist in the repository.
    assert_false(exists("mopm.toml"))
    assert_false(exists("fixtures/undeclared.txt"))

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

    # The layout: <root>/bin/<exe>, <root>/share. A bundle with the two
    # declared files under share/ and a copy of this executable in bin/.
    var bundle = t + "/bundle"
    makedirs(bundle + "/bin")
    makedirs(bundle + "/share/fixtures")
    makedirs(bundle + "/share/renamed")
    with open(bundle + "/share/" + _GREETING, "w") as f:
        f.write(greeting)
    with open(bundle + "/share/renamed/other.txt", "w") as f:
        f.write(other)
    _ = run("cp '" + exe + "' '" + bundle + "/bin/probe'")
    # Started from another directory, by absolute path: the answers do not
    # depend on the current directory.
    var out = run(
        "cd '" + t + "' && " + _PROBE + "=1 '" + bundle + "/bin/probe'"
    )
    var root = _field(out, "root")
    assert_true(root.endswith("/bundle"), root)
    assert_equal(_field(out, "exe"), root + "/bin/probe")
    assert_equal(_field(out, "share"), root + "/share")
    assert_equal(_field(out, "greeting"), "hello from share")
    assert_equal(_field(out, "other"), "renamed on the way in")
    assert_equal(_field(out, "undeclared_refused"), "True")
    print("test_runtime_paths: PASS")
