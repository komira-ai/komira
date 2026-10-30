# The pure parts of the runner: no engine, no process, no file.
#
# What each test proves:
# - test_the_query_digest_is_the_sha256_of_the_text_bytes: "abc" and "hello"
#   give their published SHA-256 digests, the key is `suite/id`, and the
#   listing and its closing digest are the corpus's `<key> <sha256>` lines in
#   order; a query with a slash in its id, an empty text or another dataset's
#   name is refused.
# - test_tables_are_named_as_the_corpus_queries_name_them: TPC-H files by their
#   file name, ClickBench `hits`, the h2o group-by file `x`, the four join
#   files by their suffix; the path is the cache directory and the manifest
#   path, with or without a trailing slash; a dataset with no naming is
#   refused.
# - test_the_scale_is_the_factor_for_tpch_and_the_rows_otherwise: sf10 gives
#   (sf, 10), ClickBench its recorded 99,997,497 rows, an h2o table the rows
#   of its largest file; a manifest that records no rows has no scale.
# - test_the_flags_fill_the_defaults: threads default to cores, the memory
#   limit to 80 percent of memory in whole KiB, the DuckDB version to the
#   pinned one, and the order keys parse with their modifiers.
# - test_flags_are_checked: an unknown flag, a flag twice, a flag without a
#   value, a bare word, a missing required flag, a non-number and cold
#   sweeps with no cache-drop file are each refused.
# - test_the_refusal_arm_refuses_every_query_by_name: any query, materialized
#   or not, ends in a refusal of the named construct and prepare is recorded.
# - test_settings_are_checked: each unusable setting is refused.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_bench_data import find_manifest
from komira_bench_runner import (
    ARM_REFUSED,
    RefusalArm,
    EngineArm,
    QuerySpec,
    RunSettings,
    parse_flags,
    parse_order_key,
    queries_file_text,
    queries_listing,
    TableBinding,
    scale_of,
    table_name_of,
    tables_of,
)
from komira_bench_data import DatasetFile, DatasetManifest

comptime _ABC: String = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
comptime _HELLO: String = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"


def _query(id: String, text: String) -> QuerySpec:
    return QuerySpec(String("tpch"), id, String("tpch"), text)


def _words(text: String) -> List[String]:
    var out = List[String]()
    for p in text.split(" "):
        out.append(String(p))
    return out^


def test_the_query_digest_is_the_sha256_of_the_text_bytes() raises:
    var a = _query(String("q6"), String("abc"))
    assert_equal(a.sha256(), _ABC)
    assert_equal(a.key(), String("tpch/q6"))
    var b = _query(String("q1"), String("hello"))
    assert_equal(b.sha256(), _HELLO)
    var queries = List[QuerySpec]()
    queries.append(a.copy())
    queries.append(b.copy())
    var listing = queries_listing(queries)
    assert_equal(listing, String("tpch/q6 ") + _ABC + String("\ntpch/q1 ") + _HELLO + String("\n"))
    var file = queries_file_text(queries)
    assert_true(file.startswith(listing + String("listing_sha256 ")))
    assert_equal(file.byte_length(), listing.byte_length() + 15 + 64 + 1)
    a.validate()
    with assert_raises():
        _query(String("a/b"), String("abc")).validate()
    with assert_raises():
        _query(String("q6"), String("")).validate()
    with assert_raises():
        _query(String(""), String("abc")).validate()


def test_tables_are_named_as_the_corpus_queries_name_them() raises:
    assert_equal(table_name_of(String("tpch"), String("tpch/sf1/lineitem.parquet")), String("lineitem"))
    assert_equal(table_name_of(String("clickbench"), String("clickbench/hits.parquet")), String("hits"))
    assert_equal(
        table_name_of(String("h2o_groupby"), String("h2o/groupby_n1000_k10_seed1.parquet")), String("x")
    )
    assert_equal(table_name_of(String("h2o_join"), String("h2o/join_n1000_seed1_big.parquet")), String("big"))
    assert_equal(table_name_of(String("h2o_join"), String("h2o/join_n1000_seed1_x.parquet")), String("x"))
    with assert_raises():
        _ = table_name_of(String("other"), String("a/b.parquet"))
    with assert_raises():
        _ = table_name_of(String("tpch"), String("tpch/sf1/lineitem.csv"))

    var manifest = find_manifest(String("tpch"), String("sf1"))
    var tables = tables_of(manifest, String("/cache"))
    assert_equal(len(tables), 8)
    assert_equal(tables[7].name, String("lineitem"))
    assert_equal(tables[7].path, String("/cache/tpch/sf1/lineitem.parquet"))
    assert_equal(tables[7].rows, 6_001_215)
    assert_equal(tables_of(manifest, String("/cache/"))[7].path, String("/cache/tpch/sf1/lineitem.parquet"))
    with assert_raises():
        _ = tables_of(manifest, String(""))

    var twice = List[DatasetFile]()
    twice.append(DatasetFile.unrecorded(String("h2o/groupby_a.parquet"), 5))
    twice.append(DatasetFile.unrecorded(String("h2o/groupby_b.parquet"), 5))
    with assert_raises(contains="two files"):
        _ = tables_of(DatasetManifest(String("h2o_groupby"), String("a"), String(""), twice^), String("/c"))


def test_the_scale_is_the_factor_for_tpch_and_the_rows_otherwise() raises:
    var tpch = scale_of(find_manifest(String("tpch"), String("sf10")))
    assert_equal(tpch.kind, String("sf"))
    assert_equal(tpch.value, Int64(10))
    var hits = scale_of(find_manifest(String("clickbench"), String("full")))
    assert_equal(hits.kind, String("rows"))
    assert_equal(hits.value, Int64(99_997_497))
    var files = List[DatasetFile]()
    files.append(DatasetFile.unrecorded(String("h2o/join_n9_seed1_x.parquet"), 9))
    files.append(DatasetFile.unrecorded(String("h2o/join_n9_seed1_small.parquet"), 1))
    var h2o = scale_of(DatasetManifest(String("h2o_join"), String("n9_seed1"), String(""), files^))
    assert_equal(h2o.value, Int64(9))
    var none = List[DatasetFile]()
    none.append(DatasetFile.unrecorded(String("h2o/groupby_a.parquet"), -1))
    with assert_raises(contains="no row count"):
        _ = scale_of(DatasetManifest(String("h2o_groupby"), String("a"), String(""), none^))


def _required() -> String:
    return String(
        "--duckdb d --cache-dir c --out-dir o --dataset tpch --scale sf1 --suite tpch --query q6"
        " --sql-file q.sql --hostclass test-class --cpu-model cpu --os linux --komira-version v"
        " --cores 8 --mem-bytes 1000000"
    )


def test_the_flags_fill_the_defaults() raises:
    var f = parse_flags(_words(_required() + String(" --order-key 0 --order-key 2:desc:nulls_first")))
    assert_equal(f.threads, 8)
    assert_equal(f.memory_limit_bytes, 800_000 // 1024 * 1024)
    assert_equal(f.duckdb_version, String("1.5.6"))
    assert_equal(f.warm_sweeps, 3)
    assert_equal(f.cold_sweeps, 0)
    assert_equal(len(f.order_keys), 2)
    assert_equal(f.order_keys[0].column, 0)
    assert_false(f.order_keys[0].descending)
    assert_equal(f.order_keys[1].column, 2)
    assert_true(f.order_keys[1].descending)
    assert_true(f.order_keys[1].nulls_first)
    var g = parse_flags(_words(_required() + String(" --threads 3 --memory-limit-bytes 4096 --pass-max 1.25")))
    assert_equal(g.threads, 3)
    assert_equal(g.memory_limit_bytes, 4096)
    assert_equal(g.pass_max, 1.25)
    var cold = parse_flags(_words(_required() + String(" --cold-sweeps 2 --drop-caches-file p")))
    assert_equal(cold.cold_sweeps, 2)
    assert_equal(parse_order_key(String("3:desc")).column, 3)


def test_flags_are_checked() raises:
    with assert_raises(contains="unknown flag"):
        _ = parse_flags(_words(_required() + String(" --bogus 1")))
    with assert_raises(contains="given twice"):
        _ = parse_flags(_words(_required() + String(" --threads 1 --threads 2")))
    with assert_raises(contains="needs a value"):
        _ = parse_flags(_words(_required() + String(" --threads")))
    with assert_raises(contains="unexpected argument"):
        _ = parse_flags(_words(String("stray ") + _required()))
    with assert_raises(contains="missing --sql-file"):
        _ = parse_flags(_words(_required().replace(String(" --sql-file q.sql"), String(""))))
    with assert_raises(contains="whole number"):
        _ = parse_flags(_words(_required() + String(" --threads x")))
    with assert_raises(contains="needs a number"):
        _ = parse_flags(_words(_required() + String(" --pass-max 1.2.3")))
    with assert_raises(contains="--drop-caches-file"):
        _ = parse_flags(_words(_required() + String(" --cold-sweeps 1")))
    with assert_raises(contains="unknown modifier"):
        _ = parse_order_key(String("1:up"))


def test_the_refusal_arm_refuses_every_query_by_name() raises:
    var arm = RefusalArm()
    arm.prepare(List[TableBinding](), 4, 4096)
    assert_true(arm.prepared)
    var a = arm.run(_query(String("q6"), String("abc")), True)
    assert_equal(a.kind, ARM_REFUSED)
    assert_equal(a.detail, String("no_engine_arm"))
    assert_false(a.completed())
    var b = arm.run(_query(String("q1"), String("hello")), False)
    assert_equal(b.kind, ARM_REFUSED)
    assert_equal(arm.asked, 2)
    var named = RefusalArm(String("join"))
    assert_equal(named.run(_query(String("q6"), String("abc")), True).detail, String("join"))
    arm.close()
    assert_false(arm.prepared)
    assert_equal(arm.label(), String("refusal"))


def test_settings_are_checked() raises:
    RunSettings(4, 4096).validate()
    with assert_raises():
        RunSettings(0, 4096).validate()
    with assert_raises():
        RunSettings(4, 4000).validate()
    with assert_raises():
        RunSettings(4, 4096, 0).validate()
    with assert_raises():
        RunSettings(4, 4096, 3, 1).validate()
    with assert_raises():
        RunSettings(4, 4096, 3, 6, 1, 1).validate()
    with assert_raises():
        RunSettings(4, 4096, 3, 6, 0, 3, 0.0).validate()
    RunSettings(4, 4096, 3, 6, 2, 3).validate()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
