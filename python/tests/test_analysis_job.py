"""python/examples/analysis_job.py run from the installed komira wheel, and
every answer it computes held to DuckDB's for the same SQL (python/BUCK,
`analysis_job_test`).

    <prefix>/bin/python3.13 -I test_analysis_job.py --site <dir>
        [--host-lib <lib>]... --example <analysis_job.py>

Run by wheel_install_run.py, which installed komira, pyarrow and duckdb into
`--site` and starts this from an empty working directory. In order:

- `import komira` is the package installed in `--site`;
- the job runs through komira: its per-region top two, its overall top three
  and the Parquet file it wrote each equal DuckDB's answer to the same query
  over the same files, row for row and column for column (names, order and
  values), and the answers are not empty;
- the same job with the join on the wrong key (the order's own id in place of
  its customer) gives komira an answer that is not DuckDB's for the right
  key, so the comparison fails on a defect in the join.

Any failure raises; its last traceback line is what a failing run names.
"""

import ctypes
import importlib.util
import os
import sys
import tempfile

_VALUED = ("--site", "--example")


def parse(argv):
    opts = {"host_lib": []}
    i = 0
    while i < len(argv):
        flag = argv[i]
        if i + 1 >= len(argv):
            raise SystemExit("test_analysis_job: flag {} needs a value".format(flag))
        if flag == "--host-lib":
            opts["host_lib"].append(argv[i + 1])
        elif flag in _VALUED:
            opts[flag[2:]] = argv[i + 1]
        else:
            raise SystemExit("test_analysis_job: unknown flag {}".format(flag))
        i += 2
    for flag in _VALUED:
        if flag[2:] not in opts:
            raise SystemExit("test_analysis_job: {} is required".format(flag))
    return opts


def load_example(path):
    spec = importlib.util.spec_from_file_location("analysis_job", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def duckdb_rows(con, query):
    """DuckDB's answer to `query` as a list of dicts in its column order."""
    cursor = con.execute(query)
    names = [d[0] for d in cursor.description]
    return [dict(zip(names, row)) for row in cursor.fetchall()]


def same(got, want):
    """Whether two answers are the same rows: the same columns in the same
    order, and the same values in the same row order."""
    return [list(r.items()) for r in got] == [list(r.items()) for r in want]


def check(label, got, want):
    assert want, "{}: DuckDB's answer is empty, so it proves nothing".format(label)
    assert same(got, want), "{}: komira answers {}, DuckDB answers {}".format(label, got, want)


def main(argv):
    opts = parse(argv)
    for lib in opts["host_lib"]:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)

    site = os.path.realpath(opts["site"])
    import komira

    init = os.path.realpath(komira.__file__)
    assert init == os.path.join(site, "komira", "__init__.py"), "komira was imported from {}, not from {}".format(init, site)

    import duckdb

    job = load_example(opts["example"])
    with tempfile.TemporaryDirectory(dir=os.getcwd()) as directory:
        answer = job.run(directory)
        orders = os.path.join(directory, "orders.parquet")
        customers = os.path.join(directory, "customers.csv")

        con = duckdb.connect()
        con.execute("CREATE VIEW orders AS SELECT * FROM read_parquet('{}')".format(orders))
        per_region = duckdb_rows(con, job.TOP_PER_REGION.format(customers=customers))
        overall = duckdb_rows(con, job.TOP_OVERALL.format(customers=customers))

        check("the top two of each region", answer["per_region"], per_region)
        check("the top three overall", answer["overall"], overall)
        check("the Parquet file the job wrote", answer["written"], per_region)
        assert len(per_region) == 2 * len(job.REGIONS), "expected two customers of each of {} regions, got {} rows".format(
            len(job.REGIONS), len(per_region)
        )
        assert len(overall) == 3, "expected three customers overall, got {}".format(len(overall))

        # The same query with the join on the wrong key must not equal DuckDB's
        # answer for the right one.
        wrong = job.TOP_PER_REGION.replace("o.customer_id = c.id", "o.order_id = c.id").format(customers=customers)
        assert wrong != job.TOP_PER_REGION.format(customers=customers), "the wrong-key query is the right one"
        with komira.Session() as s:
            s.register_parquet("orders", orders)
            got = s.sql(wrong).to_arrow().to_pylist()
        assert not same(got, per_region), "a join on the wrong key still equals DuckDB's answer: {}".format(got)


if __name__ == "__main__":
    main(sys.argv[1:])
