"""The public surface of release 1 on the real libkomira: abi_version(),
Session and register_parquet, and a session's close: a second close does
nothing, and any other call on a closed session is a KomiraError.

    test_session.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` and
`<dir>/two_columns.parquet` a Parquet file.
"""

import gc
import os
import pathlib
import sys

import komira
from komira import KomiraError
from komira import _native


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() // 1000 == 1, komira.abi_version()
    parquet = os.path.join(lib_dir, "two_columns.parquet")

    with komira.Session() as s:
        assert not s.closed
        # A str, a pathlib.Path, a name registered again, a relative path
        # (resolved against the working directory) and a path under `~`.
        assert s.register_parquet("t", parquet) is None
        assert s.register_parquet("t", pathlib.Path(parquet)) is None
        # The working directory and HOME are put back afterwards: the runner
        # writes its result to a path relative to where the action started.
        cwd, home = os.getcwd(), os.environ.get("HOME")
        try:
            os.chdir(lib_dir)
            assert s.register_parquet("rel", "two_columns.parquet") is None
            os.environ["HOME"] = lib_dir
            assert s.register_parquet("home", "~/two_columns.parquet") is None
        finally:
            os.chdir(cwd)
            if home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = home

        # A file the engine cannot read: its message, status -3, a BindError
        # at the bind step with no code.
        e = raised(lambda: s.register_parquet("gone", "no_such_file.parquet"))
        assert type(e) is komira.BindError and e.status == -3 and str(e), repr(e)
        assert (e.step, e.code) == ("bind", None), (e.step, e.code)
        assert str(e) == _native.load().last_error(s._ctx), str(e)

        # Arguments are checked before the library is called.
        e = raised(lambda: s.register_parquet(b"t", parquet))
        assert type(e) is TypeError and str(e) == "name must be a str, not bytes", repr(e)
        e = raised(lambda: s.register_parquet("", parquet))
        assert type(e) is ValueError and str(e) == "name is empty", repr(e)
        e = raised(lambda: s.register_parquet("t", 3))
        assert type(e) is TypeError and str(e) == "path must be a str or os.PathLike[str], not int", repr(e)
        e = raised(lambda: s.register_parquet("t", parquet.encode()))
        assert type(e) is TypeError and str(e) == "path must be a str or os.PathLike[str], not bytes", repr(e)

    # Leaving the block closed the session; closing again does nothing, and
    # every other use is a KomiraError, never a call on a freed context.
    assert s.closed
    assert s.close() is None
    e = raised(lambda: s.register_parquet("t", parquet))
    assert type(e) is KomiraError and str(e) == "the session is closed" and e.status is None, repr(e)

    def reenter():
        with s:
            pass

    e = raised(reenter)
    assert type(e) is KomiraError and str(e) == "the session is closed", repr(e)

    # An exception inside the block still closes the session and is raised.
    try:
        with komira.Session() as t:
            raise RuntimeError("inside")
    except RuntimeError as e:
        assert str(e) == "inside"
    assert t.closed

    # Two sessions are separate, and one closed explicitly frees its context
    # once: closing it before the block ends is clean.
    with komira.Session() as a, komira.Session() as b:
        a.close()
        assert a.closed and not b.closed
        assert b.register_parquet("t", parquet) is None

    # A session never closed is freed when it is collected.
    u = komira.Session()
    free = u._free
    assert free.alive
    del u
    gc.collect()
    assert not free.alive
    print("session: libkomira {} sessions open, register and close".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
