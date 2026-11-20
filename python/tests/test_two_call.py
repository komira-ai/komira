"""The error path of the loader's Native on the stand-in library
(fake_libkomira.c): a failed call's KomiraError, its status and its message,
read from komira_last_error with the two-call protocol.

    test_two_call.py --lib-dir <dir>

`<dir>/fake_modes/libkomira.so` is the stand-in; the name passed to
register_parquet sets how it answers.
"""

import os
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
    lib_dir = args[args.index("--lib-dir") + 1]
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

    # Arguments are checked before the library is called.
    e = raised(lambda: native.register_parquet(ctx, "o\0k", "f.parquet"))
    assert type(e) is ValueError and str(e) == "name holds a NUL byte", repr(e)
    e = raised(lambda: native.register_parquet(ctx, "ok", "f\0.parquet"))
    assert type(e) is ValueError and str(e) == "path holds a NUL byte", repr(e)
    e = raised(lambda: native.register_parquet(ctx, b"ok", "f.parquet"))
    assert type(e) is TypeError and str(e) == "name must be a str, not bytes", repr(e)
    e = raised(lambda: native.register_parquet(ctx, "ok", b"f.parquet"))
    assert type(e) is TypeError and str(e) == "path must be a str, not bytes", repr(e)

    # A context the library could not make is an error, not a NULL handle.
    assert native.register_parquet(ctx, "null_ctx", "f.parquet") is None
    expect_error(native.ctx_new, "komira_ctx_new returned NULL", None)

    native.ctx_free(ctx)
    assert issubclass(LibraryLoadError, KomiraError)
    print("two_call: the stand-in's errors are reported")


if __name__ == "__main__":
    main(sys.argv[1:])
