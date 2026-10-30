# What a run leaves behind: the text a person reads, and the files.
#
#   <dir>/warm/result.json   the warm result (komira-bench-result/1)
#   <dir>/cold/result.json   the cold result, only when cold was measured
#   <dir>/queries.sha256     the digest of every query's text
#   <dir>/comparison.txt     the tolerance the answers were compared under
#
# The result schema has no field for the digest of a query, so the digests are
# a file of their own beside the results. Its lines are the corpus's listing
# (`<suite>/<id> <sha256>`, one per query in run order, so the suite's own
# digest is the digest of those lines when the run is the whole suite), then a
# last line with the digest of the lines above it.

from std.os import makedirs
from std.pathlib import Path

from komira_bench_duckdb import ABS_FLOOR, REL_TOL
from komira_bench_report import render_table, summarize, summary_line, write_result_json
from komira_crypto import hex_lower_array_32, sha256

from .query import QuerySpec
from .runner import RunOutput

comptime QUERIES_FILE: String = "queries.sha256"
comptime COMPARISON_FILE: String = "comparison.txt"


def comparison_text() -> String:
    """The tolerance the answers were compared under: integers, text and
    integer sums exactly, floats within the larger of the relative tolerance
    times the larger magnitude and the absolute floor."""
    return (
        String("float_rel_tol ") + String(REL_TOL) + String("\n")
        + String("float_abs_floor ") + String(ABS_FLOOR) + String("\n")
        + String("exact integers, text and integer sums\n")
    )


def queries_listing(queries: List[QuerySpec]) -> String:
    """`<suite>/<id> <sha256>` and a newline, for each query in order."""
    var out = String("")
    for i in range(len(queries)):
        out += queries[i].key() + String(" ") + queries[i].sha256() + String("\n")
    return out^


def queries_file_text(queries: List[QuerySpec]) -> String:
    """The listing, then `listing_sha256 <digest of the listing>`."""
    var listing = queries_listing(queries)
    return listing + String("listing_sha256 ") + hex_lower_array_32(sha256(listing.as_bytes())) + String("\n")


def format_run(run: RunOutput) raises -> String:
    """The console report: the shared settings as DuckDB read them back, the
    warm table and its line, the cold table or why there is none, then the
    queries komira refused (unserved) and those it answered wrongly or failed
    on, each with its cause."""
    var text = (
        String("threads ") + String(run.fairness.threads_readback)
        + String(" | memory limit ") + run.fairness.memory_limit_readback
        + String(" | duckdb ") + run.fairness.version + String("\n")
    )
    text += String("float tolerance: relative ") + String(REL_TOL) + String(", absolute floor ") + String(ABS_FLOOR)
    text += String("; integers, text and integer sums exact\n")
    text += String("== warm ==\n") + render_table(run.warm)
    text += summary_line(summarize(run.warm).overall, run.warm.run.pass_max, run.warm.env.duckdb) + String("\n")
    if run.cold:
        ref cold = run.cold.value()
        text += String("== cold ==\n") + render_table(cold)
        text += summary_line(summarize(cold).overall, cold.run.pass_max, cold.env.duckdb) + String("\n")
    elif run.cold_note.byte_length() > 0:
        text += String("== cold ==\nnot measured: ") + run.cold_note + String("\n")
    else:
        text += String("== cold ==\nnot requested\n")
    var unserved = String("")
    var failed = String("")
    for i in range(len(run.outcomes)):
        ref o = run.outcomes[i]
        if o.timed:
            continue
        if o.stage.startswith("UNSUPPORTED:"):
            unserved += o.key + String("  ") + o.stage + String("\n")
        else:
            failed += o.key + String("  ") + o.stage + String("  ") + o.value + String("  ") + o.note + String("\n")
    text += String("== unserved (refused by the komira arm) ==\n")
    if unserved.byte_length() == 0:
        unserved = String("none\n")
    text += unserved
    text += String("== failed ==\n")
    if failed.byte_length() == 0:
        failed = String("none\n")
    text += failed
    return text^


def write_run(run: RunOutput, dir: String) raises:
    """Write the files described at the top of this file under `dir`, which
    is created if needed. Existing files are replaced."""
    if dir.byte_length() == 0:
        raise Error("the output directory is empty")
    var base = dir.copy()
    if dir.as_bytes()[dir.byte_length() - 1] == 0x2F:
        base = String(dir[byte=0 : dir.byte_length() - 1])
    makedirs(base + String("/warm"), exist_ok=True)
    Path(base + String("/warm/result.json")).write_text(write_result_json(run.warm))
    if run.cold:
        makedirs(base + String("/cold"), exist_ok=True)
        Path(base + String("/cold/result.json")).write_text(write_result_json(run.cold.value()))
    Path(base + String("/") + String(QUERIES_FILE)).write_text(queries_file_text(run.queries))
    Path(base + String("/") + String(COMPARISON_FILE)).write_text(comparison_text())
