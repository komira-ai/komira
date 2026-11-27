"""A Session used from several threads, on a stand-in (fake_threads.c, ABI
1.3) that journals each call's entry and exit on its context, holds a call at
a gate until the test opens it, and counts every call that enters a context
another call is inside, or one already freed:

- a call made while another thread's call on the same session is held waits
  for it, and runs after it returns: register_parquet, a register_parquet the
  library refuses (with its own message), sql the library refuses, sql that
  answers (its Result reads), and sealing a credential;
- a failed call's message is read before another thread's call runs on the
  context, so each thread gets its own error;
- close() waits for the running call, frees the context once, after that call
  returns, and later calls raise the closed error;
- two sessions run their calls at once: a call on one completes while a call
  on the other is held;
- a signal handler that calls the session while a call of the same thread is
  running gets a KomiraError instead of waiting for itself, and the session
  is still open and answers afterwards;
- a Result reads while a call on its session is held;
- of two threads reading one Result, one gets the reader and the other the
  already-read KomiraError, even when the first is stopped inside the read.

No test waits on a clock. A test that needs to know that a thread waits for
the session puts a lock in place of the session's own that says when a thread
is about to wait on it; when a thread instead returns from its call, that is
seen too, and the test fails on the journal.

    test_threads.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/fake_threads/libkomira.so` is the stand-in (`--runtime-dir`, which the
rule passes, is not read).
"""

import ctypes
import os
import signal
import sys
import threading

import komira
from komira import KomiraError, Result
from komira import _native
from komira._credentials import AwsKeys

import pyarrow as pa

ALREADY_READ = "the result was already read: run the query again to read it again"
REENTERED = (
    "a call on this session was made while another call on it is running on the same thread "
    "(from a signal handler, a finalizer or a progress callback): make it after that call returns"
)


class Fake:
    """The stand-in's controls."""

    def __init__(self, path):
        lib = ctypes.CDLL(path)
        self._open = lib.fake_open
        self._open.argtypes, self._open.restype = [ctypes.c_int], None
        self._wait = lib.fake_wait_entered
        self._wait.argtypes, self._wait.restype = [ctypes.c_int], None
        self._overlaps = lib.fake_overlaps
        self._overlaps.argtypes, self._overlaps.restype = [], ctypes.c_int
        self._journal = lib.fake_journal
        self._journal.argtypes, self._journal.restype = [ctypes.c_char_p, ctypes.c_size_t], ctypes.c_size_t

    def open(self, k):
        self._open(k)

    def wait_entered(self, k):
        """Returns once a call has entered gate k (ctypes lets go of the GIL
        while it waits)."""
        self._wait(k)

    def overlaps(self):
        return self._overlaps()

    def journal(self):
        n = self._journal(None, 0)
        buf = ctypes.create_string_buffer(n)
        self._journal(buf, n)
        return buf.raw[:n].decode().splitlines()


class Waiting:
    """A lock put in place of a session's own: it counts the threads that
    found it held and are about to wait for it, and notifies `cond`."""

    def __init__(self):
        self._inner = threading.Lock()
        self.cond = threading.Condition()
        self.waiting = 0

    def acquire(self, blocking=True, timeout=-1):
        if self._inner.acquire(False):
            return True
        with self.cond:
            self.waiting += 1
            self.cond.notify_all()
        return self._inner.acquire(blocking, timeout)

    def release(self):
        self._inner.release()

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *exc):
        self.release()


class Call(threading.Thread):
    """`fn()` on a thread of its own; `outcome` is ("ok", value) or ("err",
    exception), and `done` is set, with `cond` notified, when it returns."""

    def __init__(self, fn, cond):
        super().__init__(daemon=True)
        self._fn = fn
        self._cond = cond
        self.done = False
        self.outcome = None

    def run(self):
        try:
            self.outcome = ("ok", self._fn())
        except BaseException as e:  # each caller checks the exact type
            self.outcome = ("err", e)
        with self._cond:
            self.done = True
            self._cond.notify_all()


def after(lines, first, then):
    """Whether the journal line `then` comes after the line `first`, each
    present once."""
    assert lines.count(first) == 1, (first, lines)
    assert lines.count(then) == 1, (then, lines)
    return lines.index(first) < lines.index(then)


def held(fake, s, k, b_call):
    """Holds a register_parquet of `s` at gate k on thread A, makes `b_call`
    on thread B, and opens the gate once B waits for the session or has
    returned. Returns (A, B), both finished."""
    lock = Waiting()
    s._lock = lock
    a = Call(lambda: s.register_parquet("gate:%d" % k, "t.parquet"), lock.cond)
    a.start()
    fake.wait_entered(k)
    b = Call(b_call, lock.cond)
    b.start()
    with lock.cond:
        lock.cond.wait_for(lambda: lock.waiting >= 1 or b.done)
    fake.open(k)
    a.join()
    b.join()
    assert a.outcome == ("ok", None), a.outcome
    return a, b


def a_call_waits_for_the_call_running_on_its_session(fake, s, c):
    cred = AwsKeys("cred", key_id="k", secret="s")
    cases = [
        (lambda: s.register_parquet("after", "t.parquet"), "register after"),
        (lambda: s.register_parquet("fail:b refused", "t.parquet"), "register fail:b refused"),
        (lambda: s.sql("fail:parse: bad"), "sql fail:parse: bad"),
        (lambda: s.sql("answer"), "sql answer"),
        (lambda: s._seal_credential(cred), "credential_add cred"),
    ]
    for k, (call, entry) in enumerate(cases):
        _, b = held(fake, s, k, call)
        lines = fake.journal()
        assert after(lines, "c%d register gate:%d leave" % (c, k), "c%d %s enter" % (c, entry)), lines
        assert fake.overlaps() == 0, lines
        kind, value = b.outcome
        if k == 0:
            assert b.outcome == ("ok", None), b.outcome
        elif k in (1, 2):
            text = "b refused" if k == 1 else "parse: bad"
            assert kind == "err" and type(value) is KomiraError, b.outcome
            assert str(value) == text and value.status == -3, repr(value)
        elif k == 3:
            assert kind == "ok" and type(value) is Result, b.outcome
            table = value.to_arrow()
            assert table.schema == pa.schema([pa.field("n", pa.int64())]) and table.num_rows == 0, table
        else:
            assert b.outcome == ("ok", None), b.outcome
            # The credential's calls ran together, after the held call.
            lines = fake.journal()
            start = lines.index("c%d credential_add cred enter" % c)
            assert lines[start : start + 8] == [
                "c%d %s %s" % (c, op, step)
                for op in ("credential_add cred", "credential_set -", "credential_set -", "credential_seal -")
                for step in ("enter", "leave")
            ], lines[start:]


def each_thread_reads_its_own_error(fake, s, c):
    # A fails, and its read of the last error is held at gate 10; B's call,
    # which fails with another message, waits for A's read.
    lock = Waiting()
    s._lock = lock
    a = Call(lambda: s.register_parquet("failgate:10:a refused", "t.parquet"), lock.cond)
    a.start()
    fake.wait_entered(10)
    b = Call(lambda: s.register_parquet("fail:b refused", "t.parquet"), lock.cond)
    b.start()
    with lock.cond:
        lock.cond.wait_for(lambda: lock.waiting >= 1 or b.done)
    fake.open(10)
    a.join()
    b.join()
    for call, text in ((a, "a refused"), (b, "b refused")):
        kind, e = call.outcome
        assert kind == "err" and type(e) is KomiraError and str(e) == text and e.status == -3, call.outcome
    assert fake.overlaps() == 0, fake.journal()
    # The lock was let go after both failures: a call answers.
    assert s.register_parquet("ok", "t.parquet") is None


def two_sessions_run_at_once(fake, s, c, other, d):
    # A call on `s` is held at gate 20; one on `other` returns meanwhile.
    s._lock = Waiting()
    a = Call(lambda: s.register_parquet("gate:20", "t.parquet"), s._lock.cond)
    a.start()
    fake.wait_entered(20)
    lock = Waiting()
    other._lock = lock
    b = Call(lambda: other.register_parquet("meanwhile", "t.parquet"), lock.cond)
    b.start()
    with lock.cond:
        lock.cond.wait_for(lambda: lock.waiting >= 1 or b.done)
    assert b.done and lock.waiting == 0 and b.outcome == ("ok", None), (b.done, lock.waiting, b.outcome)
    lines = fake.journal()
    assert "c%d register gate:20 leave" % c not in lines, lines
    assert "c%d register meanwhile leave" % d in lines, lines
    fake.open(20)
    a.join()
    assert a.outcome == ("ok", None), a.outcome
    assert fake.overlaps() == 0, fake.journal()


def a_result_reads_while_its_session_runs_a_call(fake, s, c):
    r = s.sql("answer")
    s._lock = Waiting()
    a = Call(lambda: s.register_parquet("gate:30", "t.parquet"), s._lock.cond)
    a.start()
    fake.wait_entered(30)
    table = r.to_arrow()
    assert table.num_rows == 0 and table.schema.names == ["n"], table
    assert "c%d register gate:30 leave" % c not in fake.journal()
    fake.open(30)
    a.join()
    assert a.outcome == ("ok", None), a.outcome


def one_result_read_by_two_threads_is_read_once(s):
    # Thread A is stopped at the second line of Result._take that it runs
    # (or as it returns, if it runs one), and the main thread reads the
    # result there.
    r = s.sql("answer")
    take = Result._take.__code__
    stopped, go = threading.Event(), threading.Event()

    def stop():
        if not stopped.is_set():
            stopped.set()
            go.wait()

    def tracer(frame, event, arg):
        if frame.f_code is not take:
            return None
        lines = [0]

        def local(frame, event, arg):
            if event == "line":
                lines[0] += 1
                if lines[0] == 2:
                    stop()
            elif event == "return":
                stop()
            return local

        return local

    def read():
        previous = sys.gettrace()
        sys.settrace(tracer)
        try:
            return r.to_reader()
        finally:
            sys.settrace(previous)

    cond = threading.Condition()
    a = Call(read, cond)
    a.start()
    stopped.wait()
    try:
        main = ("ok", r.to_reader())
    except KomiraError as e:
        main = ("err", e)
    go.set()
    a.join()
    outcomes = [a.outcome, main]
    readers = [v for kind, v in outcomes if kind == "ok"]
    errors = [v for kind, v in outcomes if kind == "err"]
    assert len(readers) == 1 and len(errors) == 1, outcomes
    assert type(readers[0]) is pa.RecordBatchReader, readers
    assert type(errors[0]) is KomiraError and str(errors[0]) == ALREADY_READ, repr(errors[0])
    readers[0].close()


def close_waits_for_the_running_call(fake, s, c):
    _, b = held(fake, s, 40, s.close)
    assert b.outcome == ("ok", None), b.outcome
    lines = fake.journal()
    assert after(lines, "c%d register gate:40 leave" % c, "c%d free - enter" % c), lines
    assert fake.overlaps() == 0, lines
    assert s.closed
    e = raised(lambda: s.register_parquet("late", "t.parquet"))
    assert type(e) is KomiraError and str(e) == "the session is closed", repr(e)
    s.close()
    assert fake.journal().count("c%d free - enter" % c) == 1


def a_signal_handler_calling_its_session_during_a_call_is_refused(fake, s, c):
    seen = []

    def handler(signum, frame):
        for call in (lambda: s.sql("from handler"), s.close):
            try:
                call()
                seen.append(None)
            except Exception as e:  # checked below
                seen.append(e)

    previous = signal.signal(signal.SIGUSR1, handler)
    try:
        # The stand-in raises SIGUSR1 in this thread inside the call; the
        # handler runs once the call is back in Python, holding the session.
        assert s.register_parquet("signal", "t.parquet") is None
    finally:
        signal.signal(signal.SIGUSR1, previous)
    assert len(seen) == 2, seen
    for e in seen:
        assert type(e) is KomiraError and str(e) == REENTERED, repr(e)
    lines = fake.journal()
    assert "c%d sql from handler enter" % c not in lines and "c%d free - enter" % c not in lines, lines
    assert not s.closed
    assert s.register_parquet("after signal", "t.parquet") is None


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def context_number(fake):
    """The number of the context the newest `cN new` line names."""
    news = [line for line in fake.journal() if line.endswith(" new")]
    return int(news[-1].split()[0][1:])


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    directory = os.path.join(lib_dir, "fake_threads")
    native = _native.load(directory)
    assert native.abi_version == 1003, native.abi_version
    fake = Fake(os.path.join(directory, _native._LIB_NAME))

    s = komira.Session()
    c = context_number(fake)
    a_call_waits_for_the_call_running_on_its_session(fake, s, c)
    each_thread_reads_its_own_error(fake, s, c)
    other = komira.Session()
    two_sessions_run_at_once(fake, s, c, other, context_number(fake))
    other.close()
    a_result_reads_while_its_session_runs_a_call(fake, s, c)
    one_result_read_by_two_threads_is_read_once(s)
    a_signal_handler_calling_its_session_during_a_call_is_refused(fake, s, c)
    close_waits_for_the_running_call(fake, s, c)
    assert fake.overlaps() == 0, fake.journal()


if __name__ == "__main__":
    main(sys.argv[1:])
