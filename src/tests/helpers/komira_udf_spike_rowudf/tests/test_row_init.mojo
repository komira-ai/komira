# python_row.so's init when what it finds beside its own library file is
# wrong. Each layout is staged in its own directory and initialized in its
# own child process (engine.mojo, open_in_child): init runs once per
# process, and the loader would hand two layouts of the same file one copy
# of the library.
#
# What it proves, and the defect each part catches:
#   - lonely/: no python/ beside the library: ERR_LOAD naming the absolute
#     path of the libpython it looked for (a directory taken from the wrong
#     part of the library's path, or left relative);
#   - fake/: a python/lib/libpython3.13.so.1.0 that is not libpython:
#     ERR_LOAD naming the missing symbol (a loader that carries on with an
#     incomplete table);
#   - noadapter/: a real interpreter with no pyrt/ beside it: ERR_LOAD
#     naming the import error (the Python exception taken whole into the
#     message);
#   - a library whose directory path is 1023 bytes long initializes (the
#     directory and its NUL fill the runtime's 1024-byte buffer exactly);
#     at 1024 bytes, or opened relative to a working directory longer than
#     the buffer, init refuses with ERR_LOAD "cannot find the runtime
#     library's own directory" (a bound off by one, a copy past the buffer,
#     a getcwd failure taken for success);
#   - each refusal with row -1.
#
# Every single-point mutant of the runtime and the adapter was run against
# the runtime tests (the PR's mutation scorecard). One that this file kills:
# row_runtime.c's own_dir writing the terminator at at - len (the directory
# cut short): red.

from std.ffi import external_call
from std.os import getenv, makedirs, symlink
from std.os.path import realpath
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import status_name
from komira_udf_spike_rowudf.engine import open_in_child


def refused(dir: String, path: String, words: String) raises:
    """Init of `path` (opened from `dir` when not empty) in a child: ERR_LOAD
    with `words` in its message and row -1."""
    var c = open_in_child(dir, path)
    var w = path + ": " + status_name(c.status) + " " + c.message
    assert_equal(status_name(c.status), "ERR_LOAD", w)
    assert_true(words in c.message, w + " (wanted '" + words + "')")
    assert_equal(c.row, Int64(-1), w)


def dir_of_length(base: String, n: Int) raises -> String:
    """A directory path of exactly `n` bytes under `base` (made), each
    component at most 200 bytes."""
    var s = base
    while len(s.as_bytes()) < n:
        var left = n - len(s.as_bytes()) - 1
        var k = 200 if left > 201 else left
        if left - k == 1:
            k -= 1
        s += "/"
        for _ in range(k):
            s += "d"
    assert_equal(len(s.as_bytes()), n, "the path's length")
    makedirs(s, exist_ok=True)
    return s^


def main() raises:
    var here = realpath(".")
    # Long directories under TMPDIR (in a directory of this process's own),
    # each holding links to the staged library (and, for the one that must
    # initialize, python/ and pyrt/).
    var tmp = getenv("TMPDIR") + "/" + String(external_call["getpid", Int32]())
    var d1023 = dir_of_length(tmp + "/a", 1023)
    var d1024 = dir_of_length(tmp + "/b", 1024)
    var d1100 = dir_of_length(tmp + "/c", 1100)
    symlink(here + "/python_row.so", d1023 + "/python_row.so")
    symlink(here + "/python", d1023 + "/python")
    symlink(here + "/pyrt", d1023 + "/pyrt")
    symlink(here + "/python_row.so", d1024 + "/python_row.so")
    symlink(here + "/python_row.so", d1100 + "/python_row.so")
    var ok = open_in_child("", d1023 + "/python_row.so")
    assert_equal(status_name(ok.status), "OK", "the 1023-byte directory: " + ok.message)
    refused("", d1024 + "/python_row.so", "init: cannot find the runtime library's own directory")
    refused(d1100, "./python_row.so", "init: cannot find the runtime library's own directory")
    refused(
        "",
        "lonely/python_row.so",
        "cannot load libpython: " + here + "/lonely/python/lib/libpython3.13.so.1.0: cannot open shared object file",
    )
    refused("", "fake/python_row.so", here + "/fake/python/lib/libpython3.13.so.1.0 has no symbol _Py_NoneStruct")
    refused("", "noadapter/python_row.so", "init: the adapter: ModuleNotFoundError: No module named 'komira_udf_rowrt'")
    print("test_row_init: ok")
