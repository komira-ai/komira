"""Ctrl-C during Session.sql, on the stand-in (fake_libkomira.c, ABI 1.3),
whose komira_sql_stream raises SIGINT in the calling thread, as a Ctrl-C
during a query does, when its text starts "interrupted:", and then answers as
the rest of the text. A query cannot be interrupted while it runs; what this
holds is what happens once the call returns:

- with Python's own handler, sql raises KeyboardInterrupt, and the stream the
  call filled before Python raised is released exactly once, without pyarrow
  ever reading it;
- the same session then runs the next query and reads its answer, and does
  so again after a second interrupted query;
- a refusal (-3) during which SIGINT arrives raises KeyboardInterrupt, makes
  no stream, and the session answers after it;
- with a handler that does not raise, sql returns the result, which reads in
  full, and the handler has run once;
- with SIGINT ignored, sql returns the result as if no signal came;
- a `progress` callback raises KomiraError naming ABI 1.6, which a run handle
  needs, makes no stream and is never called, and the session answers after;
- the session closes and the process exits 0 after main returns.

    test_sql_interrupt.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/fake_v1_3/libkomira.so` is the stand-in reporting version 1.3
(`--runtime-dir`, which the rule passes, is not read).
"""

import ctypes
import gc
import os
import signal
import sys

import komira
from komira import KomiraError
from komira import _native

FIELDS = ("streams", "streams_released", "schemas", "schemas_released", "batches", "batches_released")

ROWS = [{"n": 1}, {"n": 2}, {"n": 3}]


class Counts:
    """The stand-in's counters, read with komira_fake_stream_counts."""

    def __init__(self, lib):
        self._fn = lib.komira_fake_stream_counts
        self._fn.restype = None
        self._fn.argtypes = [ctypes.POINTER(ctypes.c_int64)]

    def __call__(self):
        out = (ctypes.c_int64 * 6)()
        self._fn(out)
        return dict(zip(FIELDS, out))

    def since(self, before):
        now = self()
        return {k: now[k] - before[k] for k in now}


def zero(**changes):
    out = dict.fromkeys(FIELDS, 0)
    out.update(changes)
    return out


# A query whose answer was read in full and released.
ROWS_READ = zero(streams=1, streams_released=1, schemas=1, schemas_released=1, batches=2, batches_released=2)


def interrupted(call):
    """The KeyboardInterrupt `call` raises."""
    try:
        call()
    except KeyboardInterrupt as e:
        return e
    raise AssertionError("the call raised no KeyboardInterrupt")


def check_interrupted_query(s, counts):
    """An interrupted query raises KeyboardInterrupt before pyarrow reads the
    stream, and the one stream the call made is released, with no schema or
    batch ever taken from it."""
    before = counts()
    e = interrupted(lambda: s.sql("interrupted:rows"))
    assert type(e) is KeyboardInterrupt, repr(e)
    del e
    gc.collect()
    assert counts.since(before) == zero(streams=1, streams_released=1), counts.since(before)


def check_answers(s, counts):
    """The session runs a query and reads its whole answer."""
    before = counts()
    assert s.sql("rows").to_arrow().to_pylist() == ROWS
    gc.collect()
    assert counts.since(before) == ROWS_READ, counts.since(before)


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    directory = os.path.join(lib_dir, "fake_v1_3")
    native = _native.load(directory)
    assert native.abi_version == 1003, native.abi_version
    counts = Counts(ctypes.CDLL(os.path.join(directory, _native._LIB_NAME)))

    # Python's own handler, whatever the process was started with (a parent
    # that ignores SIGINT leaves it ignored in the child).
    signal.signal(signal.SIGINT, signal.default_int_handler)

    with komira.Session() as s:
        check_interrupted_query(s, counts)
        check_answers(s, counts)
        check_interrupted_query(s, counts)
        check_answers(s, counts)

        # A refusal during which SIGINT arrives: KeyboardInterrupt, no stream,
        # and the session answers the next call.
        before = counts()
        e = interrupted(lambda: s.sql("interrupted:nosuch"))
        assert type(e) is KeyboardInterrupt, repr(e)
        del e
        assert counts.since(before) == zero(), counts.since(before)
        check_answers(s, counts)
        # The refusal itself, with no signal, still carries its message.
        try:
            s.sql("nosuch")
        except KomiraError as e:
            assert str(e) == "bind: the stand-in runs no query nosuch" and e.status == -3, repr(e)
        else:
            raise AssertionError("the refusal raised nothing")

        # A handler that does not raise runs once, and sql returns the
        # answer, which reads in full.
        seen = []
        signal.signal(signal.SIGINT, lambda signum, frame: seen.append(signum))
        before = counts()
        result = s.sql("interrupted:rows")
        assert seen == [signal.SIGINT], seen
        assert result.to_arrow().to_pylist() == ROWS
        del result
        gc.collect()
        assert counts.since(before) == ROWS_READ, counts.since(before)

        # SIGINT ignored: as if no signal came.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        before = counts()
        assert s.sql("interrupted:rows").to_arrow().to_pylist() == ROWS
        gc.collect()
        assert counts.since(before) == ROWS_READ, counts.since(before)

        signal.signal(signal.SIGINT, signal.default_int_handler)
        check_answers(s, counts)

        # A 1.3 library has no run handle, so progress cannot be read.
        assert not native.has("komira_sql_stream_run")
        calls = []
        before = counts()
        try:
            s.sql("rows", progress=lambda done, total: calls.append((done, total)))
        except KomiraError as e:
            want = "komira_run_new needs libkomira ABI version 1.6; the library at {} is 1.3".format(native.path)
            assert str(e) == want and e.status is None, repr(e)
        else:
            raise AssertionError("progress on a 1.3 library raised nothing")
        assert calls == [] and counts.since(before) == zero(), (calls, counts.since(before))
        check_answers(s, counts)

    assert s.closed
    print("sql_interrupt: libkomira {} answers after Ctrl-C and releases every stream".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
