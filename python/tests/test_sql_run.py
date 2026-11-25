"""Session.sql under a run handle on the real libkomira (ABI 1.6 or later):

- the progress readings of a GROUP BY over a checked-in Parquet file
  (labels.parquet: 3000 rows, five labels) are given on the calling thread,
  only grow, have done at most total, and end with done equal to total and
  more than 0, and the answer is the five groups;
- a Ctrl-C from inside the progress callback (SIGINT sent to the main thread,
  whose handler raises KeyboardInterrupt) raises KeyboardInterrupt from sql,
  and the session answers the next query with its rows, twice in a row;
- an exception the callback raises is raised from sql, and the session
  answers after it;
- a query the engine refuses never calls the callback;
- the session closes.

    test_sql_run.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` and `<dir>/labels.parquet`
the Parquet file.
"""

import os
import signal
import sys
import threading

import komira
from komira import _native

MAIN = threading.main_thread().ident

LABELS = "SELECT label, count(*) AS n FROM labels GROUP BY label ORDER BY label"
LABEL_ROWS = [{"label": label, "n": 600} for label in ("alpha", "bravo", "charlie", "delta", "echo")]


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def check_readings(seen):
    assert seen, "the progress callback was never called"
    for done, total in seen:
        assert 0 <= done <= total, seen
    assert seen == sorted(seen), seen
    assert len(set(seen)) == len(seen), seen
    done, total = seen[-1]
    assert done == total > 0, seen


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    native = _native.load(os.path.join(lib_dir, "libkomira"))
    assert native.has("komira_sql_stream_run"), komira.abi_version()
    signal.signal(signal.SIGINT, signal.default_int_handler)

    with komira.Session() as s:
        s.register_parquet("labels", os.path.join(lib_dir, "labels.parquet"))

        seen, threads = [], set()

        def record(done, total):
            seen.append((done, total))
            threads.add(threading.get_ident())

        assert s.sql(LABELS, progress=record).to_arrow().to_pylist() == LABEL_ROWS
        check_readings(seen)
        assert threads == {MAIN}, threads

        # Ctrl-C from inside the callback: the handler raises in this thread.
        for _ in range(2):
            e = raised(lambda: s.sql(LABELS, progress=lambda done, total: signal.pthread_kill(MAIN, signal.SIGINT)))
            assert type(e) is KeyboardInterrupt, repr(e)
            assert s.sql(LABELS).to_arrow().to_pylist() == LABEL_ROWS

        stop = ValueError("stop")

        def fail(done, total):
            raise stop

        assert raised(lambda: s.sql(LABELS, progress=fail)) is stop
        assert s.sql("SELECT 1 AS n").to_arrow().to_pylist() == [{"n": 1}]

        # A refusal before the plan is checked counts no segment.
        seen.clear()
        e = raised(lambda: s.sql("SELECT * FROM nosuch", progress=record))
        assert type(e) is komira.BindError and e.status == -3 and str(e).startswith("bind: "), repr(e)
        assert seen == [], seen
    assert s.closed
    print("sql_run: libkomira {} reports a query's progress and answers after Ctrl-C".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
