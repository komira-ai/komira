# =============================================================================
# create_spill_root: exclusive creation, collision skip, exhaustion
# =============================================================================
#
#   * a directory that already holds the next name is skipped, not reused: the
#     returned root is a different path and the pre-created directory is left
#     as it was (its marker file is still there);
#   * when every name tried is taken the call raises, naming the directory;
#   * a name is never handed out twice.
#
# The names are `thsplc_<kind>_<pid>_<counter>` with a process-wide counter;
# the tests learn the next counter value by creating one root, then
# pre-create the following names.
# =============================================================================

from std.ffi import external_call
from std.os import listdir, makedirs, mkdir
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_libc.posix import _read_env

from komira_op_spill_rows.spill_root import create_spill_root


def _scratch_dir(name: String) raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d + "/" + name


def _counter_of(root: String) raises -> Int:
    """The trailing counter of a root path `.../thsplc_<kind>_<pid>_<n>`."""
    var parts = root.split("_")
    return Int(parts[len(parts) - 1])


def _name(dir: String, kind: String, counter: Int) -> String:
    var pid = Int(external_call["getpid", Int32]())
    return (
        dir + "/thsplc_" + kind + "_" + String(pid) + "_" + String(counter)
    )


def test_spill_root_skips_a_name_that_already_exists() raises:
    var dir = _scratch_dir("root_collide")
    var first = create_spill_root(dir, "agg")
    var next = _counter_of(first) + 1
    var stale = _name(dir, "agg", next)
    mkdir(stale, 0o755)
    var marker = stale + "/marker"
    with open(marker, "w") as f:
        f.write("stale")

    var got = create_spill_root(dir, "agg")
    assert_true(got != stale, "the pre-created directory was reused")
    assert_equal(_counter_of(got), next + 1, "the next free name")
    assert_true(exists(marker), "the stale directory is untouched")
    assert_equal(len(listdir(stale)), 1)


def test_spill_root_raises_naming_the_directory_when_every_name_is_taken() raises:
    var dir = _scratch_dir("root_exhausted")
    var first = create_spill_root(dir, "sortrows")
    var next = _counter_of(first) + 1
    for i in range(64):
        mkdir(_name(dir, "sortrows", next + i), 0o755)

    var raised = False
    var msg = String("")
    try:
        _ = create_spill_root(dir, "sortrows")
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "exhaustion is an error")
    assert_true(dir in msg, "names the directory: " + msg)
    # The 64 stale names and the first root are all that is there: nothing
    # was created by the failed call.
    assert_equal(len(listdir(dir)), 65)


def test_spill_root_names_are_never_handed_out_twice() raises:
    var dir = _scratch_dir("root_distinct")
    var a = create_spill_root(dir, "agg")
    var b = create_spill_root(dir, "agg")
    var c = create_spill_root(dir, "sortrows")
    assert_true(a != b and b != c and a != c, "three distinct roots")
    assert_equal(len(listdir(dir)), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
