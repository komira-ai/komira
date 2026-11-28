# =============================================================================
# copy_runner -- run each COPY line of a cases file through run_sql
# =============================================================================
#
# The program behind the `:copy_komira` build action, which writes the
# Parquet, CSV and JSON files (and the directories of a partitioned COPY)
# DuckDB reads back (`:copy_readback_oracle`, `test_copy_readback_duckdb`).
#
#   copy_runner --cases <cases.sql> --input-dir <dir> --out-dir <dir>
#
# Every line of the cases file that starts with `COPY (` is one statement,
# ending with `;`. Before it runs, each `read_csv('<name>` becomes
# `read_csv('<input-dir>/<name>` (and `read_parquet('<name>` likewise) and its
# destination `TO '<file>` becomes
# `TO '<out-dir>/<file>`. The program creates `<out-dir>`, runs the lines in
# order on one context, and writes `<out-dir>/counts.tsv`: a header
# `case<TAB>count`, then each case's name (the destination's file name up to
# its first `.`) and the `Count` it answered. A refused line, a missing flag
# or a line whose destination has no extension ends the program with an
# error naming it, so the build action fails.

from std.os import makedirs
from std.sys import argv

from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql


def _flag(name: String) raises -> String:
    var args = argv()
    for i in range(1, len(args) - 1):
        if String(args[i]) == name:
            return String(args[i + 1])
    raise Error("copy_runner: missing " + name + " <value>")


def main() raises:
    var cases = _flag("--cases")
    var inputs = _flag("--input-dir")
    var out = _flag("--out-dir")
    makedirs(out, exist_ok=True)
    var text = String()
    with open(cases, "r") as f:
        text = f.read()
    var counts = String("case\tcount\n")
    var ctx = EngineContext(EngineOptions(worker_count=2))
    for raw in text.split("\n"):
        var line = String(String(raw).strip())
        if not line.startswith("COPY ("):
            continue
        var to = line.rfind(") TO '")
        var end = line.find("'", to + 6) if to >= 0 else -1
        var dot = line.find(".", to + 6) if to >= 0 else -1
        if to < 0 or dot < 0 or end < dot:
            raise Error("copy_runner: no destination with an extension in: " + line)
        var name = String(line[byte = to + 6 : dot])
        var sql = line.replace("read_csv('", "read_csv('" + inputs + "/")
        sql = sql.replace("read_parquet('", "read_parquet('" + inputs + "/")
        sql = sql.replace(") TO '", ") TO '" + out + "/")
        var outcome = run_sql(ctx, sql)
        if outcome.refusal:
            raise Error(
                "copy_runner: " + name + " refused at "
                + outcome.refusal.value().step + ": "
                + outcome.refusal.value().reason
            )
        var n = outcome.batches[0].column_at(0).as_primitive[DType.int64]().get(0)
        counts += name + "\t" + String(n) + "\n"
    with open(out + "/counts.tsv", "w") as f:
        f.write(counts)
