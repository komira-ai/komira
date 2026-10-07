# The release gate's runtime contract, checked from inside the test: green
# in the release gate and in its coverage run (test 43), which runs the test
# under kcov through the same runner, so it sees the same environment, data
# and working directory, and may run on as many CPUs as the processes that
# started it (kcov v42 as released pins itself and the test to one CPU;
# komira's build of it does not: tools/build/toolchains/kcov/README.md).
from covenv import tag
from std.os import getenv
from std.testing import assert_equal, assert_true


def _ends(s: String, suffix: String) -> Bool:
    return s.endswith(suffix)


def _field(status: String, name: String) -> String:
    """The value of `name:` in a /proc/<pid>/status text, or "" without it.
    Split on "\n" only: the pinned Mojo's splitlines() also splits at the
    tab after the field name."""
    for line in status.split("\n"):
        var l = String(line)
        if l.startswith(name + ":"):
            return String(String(l[byte = name.byte_length() + 1 : l.byte_length()]).strip())
    return String("")


def _cpu_count(cpus: String) raises -> Int:
    """The number of CPUs a Cpus_allowed_list names (`0-3,6,8-9`)."""
    var n = 0
    for part in cpus.split(","):
        var t = String(String(part).strip())
        if t.byte_length() == 0:
            continue
        var dash = t.find("-")
        if dash < 0:
            _ = Int(t)
            n += 1
        else:
            var lo = Int(String(t[byte=0:dash]))
            var hi = Int(String(t[byte = dash + 1 : t.byte_length()]))
            n += hi - lo + 1
    return n


def _status(pid: String) raises -> String:
    var text = String("")
    with open(String("/proc/") + pid + "/status", "r") as f:
        text = f.read()
    return text


def _check_cpus() raises:
    """The test may run on as many CPUs as its parent and grandparent (the
    runner, and what started it): nothing between narrowed its affinity."""
    var mine = _status(String("self"))
    var cpus = _field(mine, String("Cpus_allowed_list"))
    var n = _cpu_count(cpus)
    assert_true(n > 0, "test_env: no Cpus_allowed_list in /proc/self/status")
    var pid = _field(mine, String("PPid"))
    for _ in range(2):
        if pid.byte_length() == 0 or pid == String("0"):
            return
        var theirs = String("")
        try:
            theirs = _status(pid)
        except:
            return  # an ancestor outside this PID namespace's view
        var their_cpus = _field(theirs, String("Cpus_allowed_list"))
        if _cpu_count(their_cpus) > n:
            raise Error(
                String("test_env: the test may run on CPUs ")
                + cpus
                + ", its ancestor "
                + pid
                + " ("
                + _field(theirs, String("Name"))
                + ") on "
                + their_cpus
                + ": something between them narrowed its CPU affinity"
            )
        pid = _field(theirs, String("PPid"))


def main() raises:
    assert_equal(tag(), "covenv", "the library value, read back")
    # test_env reaches the test.
    assert_equal(getenv("COVENV"), "set by test_env", "COVENV from test_env")
    # Declared data, reached by its path from the working directory (share/).
    var text = String("")
    with open(String("functional/coverage/tests/data/covenv.txt"), "r") as f:
        text = f.read()
    assert_equal(text, "covenv data\n", "the declared data file")
    # A declared data file at the name this binary's line tables give a
    # standard library source (relative, as the pinned Mojo writes it): kcov,
    # started in this directory, can open it, and only the run's
    # --include-path list keeps it out of the report (cov_run.sh).
    var decoy = String("")
    with open(String("oss/modular/mojo/stdlib/std/testing/testing.mojo"), "r") as f:
        decoy = f.read()
    assert_true(decoy.startswith("covenv decoy:"), "the decoy data file: " + decoy)
    # No preloaded library: the gate sets none, and kcov sets one (its
    # libkcov_sowrapper.so) unless told to skip shared libraries.
    assert_equal(getenv("LD_PRELOAD"), "", "LD_PRELOAD is unset")
    # The runner's variables: PATH is one directory of busybox applets, and
    # HOME and TMPDIR (= TEST_TMPDIR) are private; the three are bin/, home/
    # and tmp/ of the one directory the runner makes for this run.
    var path = getenv("PATH")
    var home = getenv("HOME")
    var tmp = getenv("TMPDIR")
    assert_true(_ends(path, "/bin") and path.find(":") < 0, "PATH is one bin/ directory: " + path)
    assert_true(_ends(home, "/home"), "HOME is a home/ directory: " + home)
    assert_true(_ends(tmp, "/tmp"), "TMPDIR is a tmp/ directory: " + tmp)
    var run_dir = String(path[byte=0 : path.byte_length() - 4])
    assert_true(run_dir.byte_length() > 0, "PATH has a parent directory")
    assert_equal(home, run_dir + "/home", "HOME beside PATH's bin/")
    assert_equal(tmp, run_dir + "/tmp", "TMPDIR beside PATH's bin/")
    assert_equal(getenv("TEST_TMPDIR"), tmp, "TEST_TMPDIR is TMPDIR")
    assert_true(_ends(getenv("LD_LIBRARY_PATH"), "/lib"), "LD_LIBRARY_PATH is the toolchain's lib/")
    # As many CPUs as the processes that started it.
    _check_cpus()
