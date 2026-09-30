# Runs in the staged tree of the test runtime contract
# (tools/build/mojo/README.md, "Test data, environment and scratch"): share/
# holds only the files the BUCK file declares for this test.
from komira_resources import read_resource, resource_path
from std.ffi import external_call
from std.os import getenv, listdir
from std.os.path import isdir, isfile
from std.testing import assert_equal, assert_false, assert_true

comptime _PKG = "src/komira_resources/tests/fixtures/"
comptime _DECLARED = _PKG + "declared.txt"
# Present in the repository beside the declared fixture, never declared.
comptime _UNDECLARED = _PKG + "undeclared.txt"


def _error_of(name: String) -> String:
    """The message `read_resource(name)` raises, or "" when it returns."""
    try:
        _ = read_resource(name)
    except e:
        return String(e)
    return String("")


def _chdir(path: String) raises:
    var c = path.copy()
    # SAFETY: `c` is a local that outlives the call; chdir reads the
    # NUL-terminated string and keeps no pointer to it.
    var rc = external_call["chdir", Int32](c.as_c_string_slice().unsafe_ptr())
    if rc != 0:
        raise Error("chdir failed: " + path)


def _check_reads() raises:
    # A declared fixture, named by its repository path.
    assert_equal(read_resource(_DECLARED), "declared fixture\n")
    var p = resource_path(_DECLARED)
    assert_true(p.startswith("/"), p)
    assert_true(p.endswith("/share/" + _DECLARED), p)
    assert_true(isfile(p), p)
    # A dict entry is named by its key, as a bundle's data is.
    assert_equal(read_resource("renamed/shipped.txt"), "declared fixture\n")
    # A directory holds exactly the files declared under it.
    var d = resource_path(_PKG + "dir")
    assert_true(isdir(d), d)
    var entries = listdir(d)
    assert_equal(len(entries), 2)
    assert_equal(read_resource(_PKG + "dir/b.txt"), "b\n")


def _exit_status(path: String) raises -> Int:
    """The exit status of program `path` run with no arguments; -1 when it did
    not exit normally, 127 when it could not be started."""
    var p = path.copy()
    var argv = InlineArray[Int, 2](fill=0)
    # FFI-BOUNDARY: execv reads argv as a NULL-terminated char*[]; its one
    # entry is the address of `p`'s NUL-terminated bytes.
    argv[0] = Int(p.as_c_string_slice().unsafe_ptr())
    var status = List[Int32](length=1, fill=Int32(0))
    var pid = external_call["fork", Int32]()
    if pid < 0:
        raise Error("fork failed")
    if pid == 0:
        # SAFETY: `p` and `argv` are live locals; execv only returns on
        # failure, and the child then leaves without running destructors.
        _ = external_call["execv", Int32](
            p.as_c_string_slice().unsafe_ptr(), argv.unsafe_ptr()
        )
        external_call["_exit", NoneType](Int32(127))
    # SAFETY: `status` holds one Int32 and outlives the call.
    var r = external_call["waitpid", Int32](pid, status.unsafe_ptr(), Int32(0))
    if r != pid:
        raise Error("waitpid failed for " + p)
    var st = Int(status[0])
    if (st & 0x7F) != 0:
        return -1
    return (st >> 8) & 0xFF


def main() raises:
    _check_reads()

    # An undeclared file is refused, with a message naming it and saying
    # where to declare it -- although it exists in the repository.
    var msg = _error_of(_UNDECLARED)
    assert_true(msg != "", "an undeclared file must raise")
    assert_true(_UNDECLARED in msg, msg)
    assert_true("test_data" in msg, msg)
    assert_true("mojo_bundle" in msg, msg)
    assert_true(("share/" + _UNDECLARED) in msg, msg)

    # Names that could leave share/ are refused before any lookup.
    assert_false(_error_of("../bin/x") == "", "'..' must raise")
    assert_false(_error_of("/etc/hostname") == "", "absolute must raise")
    assert_false(_error_of("") == "", "empty must raise")

    # A built program that is test data finds its share/ beside its bin/:
    # staged as `tool/bin` + `tool/share/...` it reads its resource; staged at
    # `flat`, its share/ is `share/share`, which holds nothing.
    assert_equal(_exit_status(resource_path("tool/bin") + "/resources_probe"), 0)
    assert_equal(_exit_status(resource_path("flat") + "/resources_probe"), 3)
    assert_false(_error_of(_PKG + "./declared.txt") == "", "'.' must raise")

    # The lookup is relative to the executable, not the current directory.
    var scratch = getenv("TEST_TMPDIR", "")
    assert_true(scratch != "", "TEST_TMPDIR must be set by the runner")
    _chdir(scratch)
    _check_reads()
    print("test_resources: PASS")
