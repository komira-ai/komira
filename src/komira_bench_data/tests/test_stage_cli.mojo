# The `komira-bench-stage` command line: flags, exit status, and the refusals
# that happen before DuckDB is started. The "DuckDB" the tests pass is a shell
# script that would write a marker file if it ever ran; the marker never appears.
#
# What each test proves:
# - test_flags_in_both_spellings: `--name value` and `--name=value` parse, and
#   an unknown flag, a repeated flag, a missing value and a word that is not a
#   flag are refused.
# - test_numbers: positive decimal numbers only.
# - test_usage_errors_exit_2_and_run_nothing: no command, an unknown command,
#   a missing required flag, a scale factor that is not 1, 10 or 100 and a
#   malformed number each exit 2 and create nothing in the cache directory.
# - test_an_extension_that_is_not_the_pinned_file_stops_everything: a gzip that
#   is not the pinned file (exit 1) and a platform with no pin (exit 1) leave
#   no private directory and no dataset directory, and the DuckDB file never ran.
#   (That the pin check comes before DuckDB is started is the order of
#   `_run_tpch`; the library tests show a refused file creates nothing.)
# - test_a_complete_dataset_is_only_verified: with all eight files present the
#   run needs neither DuckDB nor the extension (paths that do not exist) and
#   exits 0; with some present it exits 1 and replaces nothing.
# - test_verify_reports_a_supplied_dataset: `verify` exits 0 for a usable
#   directory and 1 for a missing file or an unknown dataset.
from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_runtime_paths import test_tmpdir

from komira_bench_data import (
    Flags,
    parse_flags,
    parse_positive,
    run_stage,
    tpch_manifest,
    tpch_state,
)


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/stage_cli_" + name
    makedirs(d, exist_ok=True)
    return d^


def _args(var words: List[String]) -> List[String]:
    return words^


def _allowed() -> List[String]:
    return [String("a"), String("b")]


def test_flags_in_both_spellings() raises:
    var f = parse_flags(_args(["tpch", "--a", "1", "--b=two"]), 1, _allowed())
    assert_equal(f.require(String("a")), String("1"))
    assert_equal(f.require(String("b")), String("two"))
    assert_equal(f.get(String("c"), String("dflt")), String("dflt"))
    assert_false(f.has(String("c")))
    with assert_raises(contains="unknown flag --c"):
        _ = parse_flags(_args(["--c", "1"]), 0, _allowed())
    with assert_raises(contains="--a given twice"):
        _ = parse_flags(_args(["--a", "1", "--a=2"]), 0, _allowed())
    with assert_raises(contains="--a needs a value"):
        _ = parse_flags(_args(["--a"]), 0, _allowed())
    with assert_raises(contains="not a flag: stray"):
        _ = parse_flags(_args(["stray"]), 0, _allowed())
    with assert_raises(contains="missing --b"):
        _ = parse_flags(_args(["--a", "1"]), 0, _allowed()).require(String("b"))


def test_numbers() raises:
    assert_equal(parse_positive(String("24"), String("--n")), 24)
    for bad in [String(""), String("0"), String("-1"), String("1.5"), String("x"), String("1234567890")]:
        with assert_raises(contains="--n"):
            _ = parse_positive(bad, String("--n"))


def test_usage_errors_exit_2_and_run_nothing() raises:
    var d = _dir(String("usage"))
    assert_equal(run_stage(List[String]()), 2)
    assert_equal(run_stage(_args(["frobnicate"])), 2)
    assert_equal(run_stage(_args(["tpch", "--duckdb", "/x", "--cache-dir", d])), 2)
    assert_equal(run_stage(_args(["tpch", "--duckdb", "/x", "--tpch-extension", "/y", "--cache-dir", d, "--scale-factor", "5"])), 2)
    assert_equal(run_stage(_args(["tpch", "--duckdb", "/x", "--tpch-extension", "/y", "--cache-dir", d, "--scale-factor", "1", "--memory-limit-gib", "lots"])), 2)
    assert_equal(run_stage(_args(["tpch", "--duckdb", "/x", "--tpch-extension", "/y", "--cache-dir", d, "--scale-factor", "1", "--bogus", "1"])), 2)
    assert_equal(run_stage(_args(["verify", "--dataset", "tpch", "--scale", "sf1"])), 2)
    assert_equal(run_stage(_args(["tpch", "--duckdb", "/x", "--tpch-extension", "/y", "--cache-dir", "relative", "--scale-factor", "1"])), 2)
    assert_false(exists(d + "/tpch"))


def _write(path: String, text: String) raises:
    Path(path).write_bytes(text.as_bytes())


def _stopped_at_the_extension(name: String, platform: String) raises:
    var d = _dir(name)
    var marker = d + "/ran"
    var binary = d + "/duckdb"
    var ext = d + "/tpch.duckdb_extension.gz"
    _write(binary, String("#!/bin/sh\necho ran > ") + marker + String("\n"))
    var gz = List[UInt8]()
    gz.append(UInt8(0x1F))
    gz.append(UInt8(0x8B))
    gz.append(UInt8(8))
    Path(ext).write_bytes(Span(gz))
    var cache = d + "/cache"
    makedirs(cache, exist_ok=True)
    var code = run_stage(
        _args(["tpch", "--duckdb", binary, "--tpch-extension", ext, "--cache-dir", cache, "--scale-factor", "1", "--platform", platform])
    )
    assert_equal(code, 1)
    assert_false(exists(marker))
    assert_false(exists(cache + "/.komira-bench-stage"))
    assert_false(exists(cache + "/tpch"))


def test_an_extension_that_is_not_the_pinned_file_stops_everything() raises:
    # a file that is not the pinned linux_amd64 gzip, and a platform with no pin: both refused
    # before the private directory is made or any DuckDB is started
    _stopped_at_the_extension(String("ext_mismatch"), String("linux_amd64"))
    _stopped_at_the_extension(String("ext_unrecorded"), String("osx_arm64"))


def _put_dataset(cache: String, skip: String) raises:
    makedirs(cache + "/tpch/sf1", exist_ok=True)
    var m = tpch_manifest(1)
    for i in range(len(m.files)):
        if m.files[i].path.endswith(skip):
            continue
        _write(cache + "/" + m.files[i].path, String("bytes of ") + m.files[i].path)


def test_a_complete_dataset_is_only_verified() raises:
    var d = _dir(String("complete"))
    _put_dataset(d, String("nothing-skipped"))
    var code = run_stage(
        _args(["tpch", "--duckdb", "/no/such/duckdb", "--tpch-extension", "/no/such/ext", "--cache-dir", d, "--scale-factor", "1"])
    )
    assert_equal(code, 0)

    var p = _dir(String("incomplete"))
    _put_dataset(p, String("lineitem.parquet"))
    var before = Path(p + "/tpch/sf1/region.parquet").read_text()
    var partial = run_stage(
        _args(["tpch", "--duckdb", "/no/such/duckdb", "--tpch-extension", "/no/such/ext", "--cache-dir", p, "--scale-factor", "1"])
    )
    assert_equal(partial, 1)
    assert_equal(Path(p + "/tpch/sf1/region.parquet").read_text(), before)
    assert_false(exists(p + "/tpch/sf1/lineitem.parquet"))


def test_verify_reports_a_supplied_dataset() raises:
    var d = _dir(String("verify"))
    _put_dataset(d, String("nothing-skipped"))
    assert_equal(run_stage(_args(["verify", "--dataset", "tpch", "--scale", "sf1", "--cache-dir", d])), 0)
    var p = _dir(String("verify_missing"))
    _put_dataset(p, String("orders.parquet"))
    assert_equal(run_stage(_args(["verify", "--dataset", "tpch", "--scale", "sf1", "--cache-dir", p])), 1)
    assert_equal(run_stage(_args(["verify", "--dataset", "nope", "--scale", "x", "--cache-dir", p])), 1)
    var h = _dir(String("verify_clickbench"))
    assert_equal(run_stage(_args(["verify", "--dataset", "clickbench", "--scale", "full", "--cache-dir", h])), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
