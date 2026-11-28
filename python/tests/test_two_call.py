"""The calls of the loader's Native on the stand-in library
(fake_libkomira.c): a failed call's KomiraError, its status and its message,
read from komira_last_error with the two-call protocol; the arguments the four
output calls pass and the bytes they answer; and the argument checks made
before the library is called.

    test_two_call.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/fake_modes/libkomira.so` is the stand-in; the name passed to
register_parquet sets how it answers.
"""

import os
import pathlib
import sys

from komira import KomiraError, LibraryLoadError
from komira import _native


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def expect_error(call, message, status):
    e = raised(call)
    assert type(e) is KomiraError, repr(e)
    assert str(e) == message, str(e)
    assert e.status == status, e.status


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    native = _native.load(os.path.join(lib_dir, "fake_modes"))
    ctx = native.ctx_new()

    # The second call gets exactly the length the first reported: the text
    # names the capacity it was given, 29, which is its own length.
    expect_error(lambda: native.register_parquet(ctx, "capacity", "f.parquet"), "capacity 00000000000000000029", -3)
    assert native.last_error(ctx) == "capacity 00000000000000000029"

    # The status is the call's own, not a fixed one.
    expect_error(lambda: native.register_parquet(ctx, "null_arg", "f.parquet"), "name is NULL", -2)

    # Text that is not UTF-8 is reported, with U+FFFD for the bad byte.
    expect_error(lambda: native.register_parquet(ctx, "utf8", "f.parquet"), "café bad�", -3)

    # A failure with an empty last error names the call and its status.
    expect_error(
        lambda: native.register_parquet(ctx, "empty", "f.parquet"),
        "komira_register_parquet failed with status -3 and no message",
        -3,
    )

    # A last error whose length changes between the two calls is not read as
    # an answer; the failed call is still reported with its status.
    grew = "komira_last_error changed its length between the two calls: 4 bytes, then 8"
    expect_error(
        lambda: native.register_parquet(ctx, "grow", "f.parquet"),
        "komira_register_parquet failed with status -3; its last error could not be read: " + grew,
        -3,
    )
    expect_error(lambda: native.last_error(ctx), grew, None)

    # A second call that succeeds with a shorter length is not read as an
    # answer either.
    shrank = "komira_last_error changed its length between the two calls: 8 bytes, then 4"
    expect_error(
        lambda: native.register_parquet(ctx, "shrink", "f.parquet"),
        "komira_register_parquet failed with status -3; its last error could not be read: " + shrank,
        -3,
    )
    expect_error(lambda: native.last_error(ctx), shrank, None)

    # A second call that fails is reported with its own status.
    expect_error(
        lambda: native.register_parquet(ctx, "fail_second", "f.parquet"),
        "komira_register_parquet failed with status -3; its last error could not be read: "
        "komira_last_error failed with status -1",
        -3,
    )
    expect_error(lambda: native.last_error(ctx), "komira_last_error failed with status -1", -1)

    # komira_last_error failing itself.
    expect_error(
        lambda: native.register_parquet(ctx, "unreadable", "f.parquet"),
        "komira_register_parquet failed with status -3; its last error could not be read: "
        "komira_last_error failed with status -2",
        -3,
    )
    expect_error(lambda: native.last_error(ctx), "komira_last_error failed with status -2", -2)

    # Success raises nothing, and the stand-in's empty last error reads as "".
    assert native.register_parquet(ctx, "ok", "f.parquet") is None
    assert native.last_error(ctx) == ""

    # The output calls pass their arguments as given and answer the bytes the
    # library wrote: the delimiter as its byte, the flags as 1 and 0, and a
    # plan holding a NUL byte whole, with its length.
    assert native.parquet_schema(ctx, "p.parquet") == b"parquet:p.parquet"
    assert native.parquet_schema(ctx, pathlib.PurePosixPath("d/p.parquet")) == b"parquet:d/p.parquet"
    got = native.csv_binding(ctx, "c.csv", delimiter=";", has_header=True, all_varchar=False)
    assert got == b"csv:c.csv:59:1:0", got
    got = native.csv_binding(ctx, "c.csv", delimiter="\t", has_header=False, all_varchar=True)
    assert got == b"csv:c.csv:9:0:1", got
    # A skip of 0 is the same call; one above 0 needs the call of ABI 1.11,
    # which this library lacks, and a skip that is not a count is refused
    # before either.
    got = native.csv_binding(ctx, "c.csv", delimiter=";", has_header=True, all_varchar=False, skip=0)
    assert got == b"csv:c.csv:59:1:0", got
    want = "komira_csv_binding_with_skip needs libkomira ABI version 1.11; the library at {} is 1.1".format(native.path)
    expect_error(
        lambda: native.csv_binding(ctx, "c.csv", delimiter=";", has_header=True, all_varchar=False, skip=1),
        want,
        None,
    )
    e = raised(lambda: native.csv_binding(ctx, "c.csv", delimiter=";", has_header=True, all_varchar=False, skip=True))
    assert type(e) is TypeError and str(e) == "skip must be an int, not bool", repr(e)
    e = raised(lambda: native.csv_binding(ctx, "c.csv", delimiter=";", has_header=True, all_varchar=False, skip=-1))
    assert type(e) is ValueError and str(e) == "skip must be 0 or more, and fit in 64 bits, not -1", repr(e)
    assert native.json_binding(ctx, "j.json") == b"json:j.json"
    assert native.plan_render(ctx, b"a\0b") == "plan:3:610062"
    assert native.plan_render(ctx, bytearray(b"\x01")) == "plan:1:01"
    assert native.plan_render(ctx, memoryview(b"")) == "plan:0:"

    # An empty answer is a success with no bytes: the first call's.
    assert native.register_parquet(ctx, "empty_out", "f.parquet") is None
    assert native.parquet_schema(ctx, "p.parquet") == b""
    assert native.plan_render(ctx, b"x") == ""

    # An output call that fails is a KomiraError with its status and the last
    # error, like any other call.
    expect_error(lambda: native.register_parquet(ctx, "null_arg", "f.parquet"), "name is NULL", -2)
    expect_error(lambda: native.parquet_schema(ctx, "p.parquet"), "name is NULL", -2)
    expect_error(lambda: native.csv_binding(ctx, "c.csv", delimiter=",", has_header=True, all_varchar=True), "name is NULL", -2)
    expect_error(lambda: native.json_binding(ctx, "j.json"), "name is NULL", -2)
    expect_error(lambda: native.plan_render(ctx, b"x"), "name is NULL", -2)
    assert native.register_parquet(ctx, "ok", "f.parquet") is None

    # Arguments are checked before the library is called.
    e = raised(lambda: native.register_parquet(ctx, "o\0k", "f.parquet"))
    assert type(e) is ValueError and str(e) == "name holds a NUL byte", repr(e)
    e = raised(lambda: native.register_parquet(ctx, "ok", "f\0.parquet"))
    assert type(e) is ValueError and str(e) == "path holds a NUL byte", repr(e)
    e = raised(lambda: native.register_parquet(ctx, b"ok", "f.parquet"))
    assert type(e) is TypeError and str(e) == "name must be a str, not bytes", repr(e)
    e = raised(lambda: native.register_parquet(ctx, "ok", b"f.parquet"))
    assert type(e) is TypeError and str(e) == "path must be a str, not bytes", repr(e)
    e = raised(lambda: native.register_parquet(ctx, "ok", 7))
    assert type(e) is TypeError and str(e) == "path must be a str, not int", repr(e)
    e = raised(lambda: native.register_parquet(ctx, "ok", "f\udcff.parquet"))
    assert type(e) is ValueError and str(e) == "path is not valid UTF-8", repr(e)
    e = raised(lambda: native.parquet_schema(ctx, b"p"))
    assert type(e) is TypeError and str(e) == "path must be a str, not bytes", repr(e)
    e = raised(lambda: native.json_binding(ctx, "j\0"))
    assert type(e) is ValueError and str(e) == "path holds a NUL byte", repr(e)
    e = raised(lambda: native.csv_binding(ctx, "c.csv", delimiter=b",", has_header=True, all_varchar=True))
    assert type(e) is TypeError and str(e) == "delimiter must be a str, not bytes", repr(e)
    for bad in ("", ";;", "\u00e9"):
        e = raised(lambda: native.csv_binding(ctx, "c.csv", delimiter=bad, has_header=True, all_varchar=True))
        assert type(e) is ValueError and str(e) == "delimiter must be one ASCII character, not {!r}".format(bad), repr(e)
    e = raised(lambda: native.csv_binding(ctx, "c.csv", delimiter=",", has_header=1, all_varchar=True))
    assert type(e) is TypeError and str(e) == "has_header must be a bool, not int", repr(e)
    e = raised(lambda: native.csv_binding(ctx, "c.csv", delimiter=",", has_header=True, all_varchar=None))
    assert type(e) is TypeError and str(e) == "all_varchar must be a bool, not NoneType", repr(e)
    e = raised(lambda: native.plan_render(ctx, "plan"))
    assert type(e) is TypeError and str(e) == "plan must be bytes, not str", repr(e)

    # A context the library could not make is an error, not a NULL handle.
    assert native.register_parquet(ctx, "null_ctx", "f.parquet") is None
    expect_error(native.ctx_new, "komira_ctx_new returned NULL", None)

    native.ctx_free(ctx)
    assert issubclass(LibraryLoadError, KomiraError)
    print("two_call: the stand-in's calls and errors are reported")


if __name__ == "__main__":
    main(sys.argv[1:])
