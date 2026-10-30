# The program around the run, on files in the test's scratch directory.
#
# What each test proves:
# - test_the_query_text_loses_only_its_trailing_whitespace: newlines, carriage
#   returns, spaces and tabs at the end go; the inside and the start stay.
# - test_proc_drop_caches_writes_3_to_its_control_file: the dropper writes
#   "3" and a newline to the file it is given, each time, and says it can drop.
# - test_the_lock_is_written_then_read_and_a_changed_file_is_refused: with
#   no lock the files are verified and a lock is written; the next call
#   returns the same fingerprint; a changed file is refused against the lock;
#   with no lock and a missing file nothing is written and the call raises.
# - test_a_bad_command_line_exits_2_and_runs_nothing: no arguments, an unknown
#   flag and a file that is not the pinned DuckDB each exit 2 and leave no
#   output directory behind.
# The exit statuses 0 and 1 of a finished run are `run_status` in
# test_runner.mojo.

from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_bench_data import find_manifest
from komira_runtime_paths import test_tmpdir

from komira_bench_runner import (
    NoCacheDropper,
    ProcDropCaches,
    lock_fingerprint,
    run_entrypoint,
    trim_query_text,
)


def test_the_query_text_loses_only_its_trailing_whitespace() raises:
    assert_equal(trim_query_text(String("select 1\n")), String("select 1"))
    assert_equal(trim_query_text(String("select 1 \t\r\n\n")), String("select 1"))
    assert_equal(trim_query_text(String("  select\n1;")), String("  select\n1;"))
    assert_equal(trim_query_text(String("\n")), String(""))


def test_proc_drop_caches_writes_3_to_its_control_file() raises:
    var d = test_tmpdir() + "/drop_caches"
    makedirs(d, exist_ok=True)
    var path = d + "/control"
    var dropper = ProcDropCaches(path)
    assert_true(dropper.can_drop())
    var files = List[String]()
    files.append(String("a"))
    dropper.drop(files)
    assert_equal(Path(path).read_text(), String("3\n"))
    Path(path).write_text("x")
    dropper.drop(files)
    assert_equal(Path(path).read_text(), String("3\n"))
    assert_false(NoCacheDropper().can_drop())
    with assert_raises():
        var none = NoCacheDropper()
        none.drop(files)


def _put_tpch(dir: String, tail: String) raises:
    makedirs(dir + "/tpch/sf1", exist_ok=True)
    var names = List[String]()
    names.append(String("region"))
    names.append(String("nation"))
    names.append(String("supplier"))
    names.append(String("customer"))
    names.append(String("part"))
    names.append(String("partsupp"))
    names.append(String("orders"))
    names.append(String("lineitem"))
    for i in range(len(names)):
        Path(dir + "/tpch/sf1/" + names[i] + ".parquet").write_text(names[i] + tail)


def test_the_lock_is_written_then_read_and_a_changed_file_is_refused() raises:
    var manifest = find_manifest(String("tpch"), String("sf1"))
    var d = test_tmpdir() + "/entry_lock"
    makedirs(d, exist_ok=True)
    _put_tpch(d, String(""))
    var first = lock_fingerprint(manifest, d)
    assert_equal(first.byte_length(), 64)
    assert_true(exists(d + "/locks/tpch_sf1.lock"))
    assert_equal(lock_fingerprint(manifest, d), first)
    Path(d + "/tpch/sf1/part.parquet").write_text("changed")
    with assert_raises(contains="differ from the lock"):
        _ = lock_fingerprint(manifest, d)

    var e = test_tmpdir() + "/entry_nolock"
    makedirs(e + "/tpch/sf1", exist_ok=True)
    Path(e + "/tpch/sf1/region.parquet").write_text("region")
    with assert_raises(contains="not usable"):
        _ = lock_fingerprint(manifest, e)
    assert_false(exists(e + "/locks/tpch_sf1.lock"))


def _words(text: String) -> List[String]:
    var out = List[String]()
    for p in text.split(" "):
        out.append(String(p))
    return out^


def test_a_bad_command_line_exits_2_and_runs_nothing() raises:
    assert_equal(run_entrypoint(List[String]()), 2)
    assert_equal(run_entrypoint(_words(String("--bogus 1"))), 2)

    var d = test_tmpdir() + "/entry_args"
    makedirs(d, exist_ok=True)
    Path(d + "/q.sql").write_text("select 1\n")
    Path(d + "/not_duckdb").write_text("not a database")
    var out = d + "/out"
    var args = _words(
        String("--duckdb ") + d + String("/not_duckdb --cache-dir ") + d + String(" --out-dir ") + out
        + String(" --dataset tpch --scale sf1 --suite tpch --query q6 --sql-file ") + d + String("/q.sql")
        + String(" --hostclass test-class --cpu-model cpu --os linux --komira-version v --cores 4 --mem-bytes 1000000")
    )
    assert_equal(run_entrypoint(args), 2)
    assert_false(exists(out))
    # the same line with a dataset that is not supported
    var other = _words(
        String("--duckdb ") + d + String("/not_duckdb --cache-dir ") + d + String(" --out-dir ") + out
        + String(" --dataset nope --scale sf1 --suite tpch --query q6 --sql-file ") + d + String("/q.sql")
        + String(" --hostclass test-class --cpu-model cpu --os linux --komira-version v --cores 4 --mem-bytes 1000000")
    )
    assert_equal(run_entrypoint(other), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
