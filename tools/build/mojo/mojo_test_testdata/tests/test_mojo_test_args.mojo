# A mojo_test (run by `buck2 test` through the gate runner) given `args`: two
# `$(location ...)` paths, one of a build output and one of a source, and one
# argument holding two of them, must arrive as absolute paths of files the
# test can open, although it runs from its share/; a `$(exe_target ...)` of a
# mojo_binary must arrive as the absolute path of the binary in its runnable
# directory, with that directory's lib/ beside it; plain arguments arrive
# verbatim, in order, and are never exported.
from std.os import getenv, listdir
from std.os.path import dirname, isdir, isfile
from std.sys import argv
from std.testing import assert_equal, assert_true


def _path_after(arg: String, flag: String) raises -> String:
    assert_true(arg.startswith(flag), "argument " + arg + " does not start with " + flag)
    var parts = arg.split(flag)
    assert_equal(len(parts), 2)
    return String(parts[1])


def _check_fixture(path: String) raises:
    assert_true(path.startswith("/"), "path " + path + " is not absolute")
    with open(path, "r") as f:
        assert_equal(f.read(), "declared bytes\n")


def _check_program(path: String) raises:
    assert_true(path.startswith("/"), "path " + path + " is not absolute")
    assert_true(path.endswith("/args_helper"), "path " + path + " is not the helper binary")
    assert_true(isfile(path), "binary " + path + " is not on the worker")
    var lib = dirname(path) + "/lib"
    assert_true(isdir(lib), "runtime libraries " + lib + " are not beside the binary")
    assert_true(len(listdir(lib)) > 0, "runtime library directory " + lib + " is empty")


def main() raises:
    var raw = argv()
    var args = List[String]()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    assert_equal(len(args), 6, "the test must get exactly its six args")
    _check_fixture(_path_after(args[0], "--copied="))
    _check_fixture(_path_after(args[1], "--referenced="))
    var pair = _path_after(args[2], "--pair=").split(",")
    assert_equal(len(pair), 2)
    _check_fixture(String(pair[0]))
    _check_fixture(String(pair[1]))
    _check_program(_path_after(args[3], "--helper="))
    assert_equal(args[4], "two words")
    assert_equal(args[5], "TD_ARG=exported")
    assert_equal(getenv("TD_ARG"), "")
    print("test_mojo_test_args: PASS")
