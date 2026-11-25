"""Session(threads=, memory_limit=) on the ABI 1.7 stand-in of fake_libkomira.c,
which records the two options of komira_ctx_new_with_options:

- Session() and Session(threads=None, memory_limit=None) call komira_ctx_new
  and leave the options of the last call as they were;
- a worker count, a memory limit, or both, reaches the library as given, the
  other as 0, which is the engine's own value;
- a value that is not an int (a str, a float, a bool) is a TypeError, and one
  below 1 or above 2**63 - 1 a ValueError, each raised before the library is
  called and each naming the option;
- the options are keyword-only;
- an option the library cannot start with (the stand-in refuses 99 workers)
  is a KomiraError that names the options, with no status;
- a session given options closes, twice without error.

    test_session_options.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/fake_v1_7/libkomira.so` is the stand-in (`--runtime-dir`, which the
rule passes, is not read).
"""

import ctypes
import os
import sys

import komira
from komira import _native


def raised(call, kind):
    try:
        call()
    except kind as e:
        return e
    raise AssertionError("the call did not raise {}".format(kind.__name__))


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    native = _native.load(os.path.join(lib_dir, "fake_v1_7"))
    assert native.abi_version == 1007, native.abi_version
    read = ctypes.CDLL(native.path).komira_fake_options
    read.argtypes = [ctypes.POINTER(ctypes.c_int64)]

    def options():
        out = (ctypes.c_int64 * 2)()
        read(out)
        return tuple(out)

    assert options() == (0, 0), options()

    # No option: komira_ctx_new, which records nothing.
    with komira.Session() as s:
        assert not s.closed
    with komira.Session(threads=None, memory_limit=None):
        pass
    assert options() == (0, 0), options()

    # Each option, and both; an absent one is 0.
    with komira.Session(threads=3):
        assert options() == (3, 0), options()
    with komira.Session(memory_limit=1 << 40):
        assert options() == (0, 1 << 40), options()
    with komira.Session(threads=2, memory_limit=1):
        assert options() == (2, 1), options()
    with komira.Session(threads=1, memory_limit=2**63 - 1):
        assert options() == (1, 2**63 - 1), options()

    # A call with no option after one with options records nothing new.
    with komira.Session():
        assert options() == (1, 2**63 - 1), options()

    # A wrong argument is Python's own error, before the library is called.
    before = options()
    for name in ("threads", "memory_limit"):
        for value in ("4", 2.0, True, b"1", [1]):
            e = raised(lambda: komira.Session(**{name: value}), TypeError)
            assert str(e) == "{} must be an int or None, not {}".format(name, type(value).__name__), str(e)
        for value in (0, -1, 2**63, 2**80):
            e = raised(lambda: komira.Session(**{name: value}), ValueError)
            assert str(e) == "{} must be between 1 and 2**63 - 1, not {}".format(name, value), str(e)
    assert options() == before, options()

    # The options are keyword-only.
    raised(lambda: komira.Session(2), TypeError)
    assert options() == before, options()

    # An option the library refuses is a KomiraError naming both options.
    e = raised(lambda: komira.Session(threads=99, memory_limit=7), komira.KomiraError)
    assert type(e) is komira.KomiraError and e.status is None, repr(e)
    assert str(e) == "komira_ctx_new_with_options returned NULL for 99 workers and a budget of 7 bytes", str(e)
    assert options() == (99, 7), options()

    # A session with options closes, and closing twice is allowed.
    s = komira.Session(threads=2, memory_limit=1 << 20)
    s.close()
    s.close()
    assert s.closed
    print("session options: reach the library as given, wrong values raise before it is called")


if __name__ == "__main__":
    main(sys.argv[1:])
