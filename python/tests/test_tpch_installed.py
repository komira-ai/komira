"""TPC-H q1 .. q22 at scale factor 1 through the installed wheel, against the
answers DuckDB gave (python/BUCK, `tpch_via_wheel_test`).

The wheel is installed into an empty prefix (python/install_test.bzl, as for
test_installed.py) and this script runs there with the prefix's interpreter in
isolated mode, from an empty directory:

    python3 -I test_tpch_installed.py --site <site directory>
        --compare <tpch_compare.py> --data <dir> --answers <answers.txt>
        --queries <dir> [--host-lib <library>]...

`--data` holds `tpch/sf1/<table>.parquet` for the eight tables, `--answers` is
DuckDB's recorded answers to the 22 queries over those files and `--queries`
the directory of `q1.sql` .. `q22.sql`, all three from
`komira//src/tpch_answers:tpch_sf1` (`[data]`, `[answers.txt]`, `[queries]`).
The answers file names the SHA-256 of the 22 query texts (`# suite tpch sha256`);
the texts read here must hash to it, so the queries run are the ones DuckDB
answered.

It holds, for each of the 22 queries, in order:

- the query is accepted by `Session.sql` and answered; a refusal is a
  `KomiraError` whose message starts `<step>: <reason>` (the token printed in
  the table), and an answer column the comparison has no cell for is
  `RESULT_TYPE_UNSUPPORTED`;
- the answer's signature (tpch_compare.py: row count, per column the counts,
  the exact sums of integers and decimals, the double sums within 1e-9, the
  hash of texts, and the declared type of each column) equals DuckDB's;
- the rows are in the order of the query's ORDER BY.

The per-query table is written to standard output. The script fails when any
query is not `PASS`, with every failing query and its refusal token or first
difference on the last line.

The derived-from-TPC-H notice applies: this is not a TPC-H result and is not
comparable to published TPC-H results.
"""

import ctypes
import hashlib
import importlib.util
import os
import sys

_VALUED = ("--site", "--compare", "--data", "--answers", "--queries")

QUERIES = ["q{}".format(n) for n in range(1, 23)]

TABLES = ("customer", "lineitem", "nation", "orders", "part", "partsupp", "region", "supplier")


def parse(argv):
    opts = {"host-lib": []}
    for i in range(0, len(argv), 2):
        flag = argv[i]
        if (flag not in _VALUED and flag != "--host-lib") or i + 1 >= len(argv):
            raise SystemExit("test_tpch_installed: bad flag {}".format(flag))
        if flag == "--host-lib":
            opts["host-lib"].append(argv[i + 1])
        else:
            opts[flag[2:]] = argv[i + 1]
    for flag in _VALUED:
        if flag[2:] not in opts:
            raise SystemExit("test_tpch_installed: {} is required".format(flag))
    return opts


def load_compare(path):
    spec = importlib.util.spec_from_file_location("tpch_compare", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def suite_digest(texts):
    """The SHA-256 of one line per query, `tpch/<id> <sha256 of the text>`, as
    src/bench_corpus names a suite's hash."""
    lines = "".join("tpch/{} {}\n".format(q, hashlib.sha256(texts[q].encode("utf-8")).hexdigest()) for q in QUERIES)
    return hashlib.sha256(lines.encode("utf-8")).hexdigest()


def recorded_suite_digest(answers_path):
    with open(answers_path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("# suite tpch sha256 "):
                return line.split()[-1]
    raise AssertionError("{} names no suite digest".format(answers_path))


def token_of(message):
    """The refusal token of a KomiraError message: its `<step>` (the text before
    the first colon), or the whole message when it has none."""
    head, sep, _ = message.partition(":")
    return head.strip() if sep and head.strip() and " " not in head.strip() else message.strip()


def run_query(session, cmp, answer, sql):
    """(`PASS` or a failure, detail) for one query."""
    import komira

    try:
        table = session.sql(sql).to_arrow()
    except komira.KomiraError as e:
        return "REFUSED", "{} ({})".format(token_of(str(e)), str(e).replace("\n", " "))
    except Exception as e:  # reading the answer failed: named, and the other queries still run
        return "ERROR", "{}: {}".format(type(e).__name__, str(e).replace("\n", " "))
    try:
        result = cmp.result_of_table(table)
    except cmp.Refused as e:
        return "REFUSED", str(e)
    try:
        reasons, _departures = cmp.compare(cmp.signature_of(result), answer.signature)
        if reasons:
            return "DIVERGENT", reasons[0]
        bad = cmp.check_order(result, answer.order)
    except ValueError as e:
        return "ERROR", "ValueError: {}".format(e)
    if bad:
        return "ORDER", bad
    return "PASS", ""


def main(argv):
    opts = parse(argv)
    # The C++ runtime of the interpreter's host, which the action passes as
    # --host-lib; the environment has no library path.
    for lib in opts["host-lib"]:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
    site = os.path.realpath(opts["site"])
    import komira

    assert os.path.realpath(os.path.dirname(os.path.dirname(komira.__file__))) == site, "komira is imported from {}, not from {}".format(komira.__file__, site)
    cmp = load_compare(opts["compare"])
    answers = cmp.parse_answers(opts["answers"])
    assert sorted(answers) == sorted("tpch/" + q for q in QUERIES), "the answers hold {}, not tpch/q1 .. tpch/q22".format(sorted(answers))

    texts = {}
    for q in QUERIES:
        with open(os.path.join(opts["queries"], q + ".sql"), "rb") as f:
            texts[q] = f.read().decode("utf-8")
    recorded = recorded_suite_digest(opts["answers"])
    assert suite_digest(texts) == recorded, "the query texts hash to {}, the answers were recorded for {}".format(suite_digest(texts), recorded)

    rows = []
    with komira.Session() as session:
        for table in TABLES:
            session.register_parquet(table, os.path.join(opts["data"], "tpch", "sf1", table + ".parquet"))
        for q in QUERIES:
            rows.append((q,) + run_query(session, cmp, answers["tpch/" + q], texts[q]))

    print("TPC-H sf1 through the installed wheel against DuckDB (derived from TPC-H; not comparable to published TPC-H results)")
    print("query   result     detail")
    for q, verdict, detail in rows:
        print("{:<7} {:<10} {}".format(q, verdict, detail))
    passed = sum(1 for r in rows if r[1] == "PASS")
    print("{} of {} pass".format(passed, len(rows)))
    failing = ["{} {}: {}".format(q, v, d) for q, v, d in rows if v != "PASS"]
    assert not failing, "{} of {} queries do not pass: {}".format(len(failing), len(rows), "; ".join(failing))


if __name__ == "__main__":
    main(sys.argv[1:])
