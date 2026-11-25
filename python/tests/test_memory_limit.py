"""Session(memory_limit=) on the real libkomira, over labels.parquet (3000 rows,
`id` INT64 0 to 2999 and `label` cycling alpha to echo):

- with a memory limit of 1 byte, each query whose operator must hold state
  raises MemoryLimitError from `sql`: an aggregate with no GROUP BY, a GROUP BY
  over an integer key and over a string key, a COUNT(DISTINCT), a sort and a
  window function. The error is a KomiraError, has status -3, the code
  MEMORY_BUDGET_EXCEEDED and the step "execute", and its message is the
  engine's, which starts with the code and names the operator that was denied
  memory and its budget;
- the session answers the next query after the refusal, and a plain syntax
  error is still a ParseError, not a MemoryLimitError;
- the same queries, on a session with no limit and on one with a limit of
  1 GiB (and two workers), give the same answers, which are the ones the file
  holds.

    test_memory_limit.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` and `<dir>/labels.parquet`
the Parquet file.
"""

import os
import sys

import komira
from komira import _native

QUERIES = {
    "an aggregate": "SELECT count(*) AS n, sum(id) AS total FROM labels",
    "a GROUP BY over an integer key": "SELECT id, count(*) AS n FROM labels GROUP BY id",
    "a GROUP BY over a string key": "SELECT label, count(*) AS n FROM labels GROUP BY label",
    "a COUNT(DISTINCT)": "SELECT count(DISTINCT label) AS n FROM labels",
    "a sort": "SELECT id FROM labels ORDER BY id DESC",
    "a window function": "SELECT id, row_number() OVER (ORDER BY id) AS r FROM labels",
}


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def answers(s):
    """The rows of each query; the rows of every query but the sort in a fixed
    order, since a GROUP BY's order is the engine's."""
    out = {}
    for name, text in QUERIES.items():
        rows = s.sql(text).to_arrow().to_pylist()
        out[name] = rows if name == "a sort" else sorted(rows, key=lambda r: sorted(r.items()))
    return out


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() >= 1007, komira.abi_version()
    labels = os.path.join(lib_dir, "labels.parquet")

    def session(**options):
        s = komira.Session(**options)
        s.register_parquet("labels", labels)
        return s

    # A limit too small for any operator's state.
    with session(memory_limit=1) as s:
        for name, text in QUERIES.items():
            e = raised(lambda: s.sql(text))
            assert type(e) is komira.MemoryLimitError, (name, repr(e))
            assert isinstance(e, komira.KomiraError), name
            assert (e.status, e.code, e.step) == (-3, "MEMORY_BUDGET_EXCEEDED", "execute"), (name, e.status, e.code, e.step)
            assert str(e).startswith("execute: MEMORY_BUDGET_EXCEEDED: pipeline_exec: the "), (name, str(e))
            assert " was denied " in str(e) and "budget 1" in str(e), (name, str(e))
        # The session answers the next query, and other refusals keep their class.
        e = raised(lambda: s.sql("SELEC 1"))
        assert type(e) is komira.ParseError, repr(e)
        e = raised(lambda: s.sql("SELECT * FROM nosuch"))
        assert type(e) is komira.BindError, repr(e)
        e = raised(lambda: s.sql(QUERIES["a sort"]))
        assert type(e) is komira.MemoryLimitError, repr(e)

    # No limit, and a limit that holds the state: the same answers.
    with session() as s:
        want = answers(s)
    assert want["an aggregate"] == [{"n": 3000, "total": 4498500}], want["an aggregate"]
    assert [r["id"] for r in want["a GROUP BY over an integer key"]] == list(range(3000))
    assert [r["n"] for r in want["a GROUP BY over a string key"]] == [600] * 5
    assert want["a COUNT(DISTINCT)"] == [{"n": 5}], want["a COUNT(DISTINCT)"]
    assert [r["id"] for r in want["a sort"]] == list(range(2999, -1, -1))
    assert [r["r"] for r in want["a window function"]] == list(range(1, 3001))
    with session(threads=2, memory_limit=1 << 30) as s:
        assert answers(s) == want
    print("memory limit: a limit of 1 byte raises MemoryLimitError for each operator, 1 GiB answers")


if __name__ == "__main__":
    main(sys.argv[1:])
