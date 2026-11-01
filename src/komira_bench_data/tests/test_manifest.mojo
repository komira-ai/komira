# The dataset manifests: what each supported dataset lists, and what a manifest
# refuses.
#
#   * test_every_supported_manifest_is_valid_and_distinct: the six supported
#     manifests validate, have distinct name and scale pairs, and each file path
#     sits under its dataset's directory.
#   * test_tpch_row_counts_follow_the_specification: region and nation do not
#     scale, the other tables scale linearly, lineitem is recorded at scale
#     factor 1 only.
#   * test_tpch_refuses_an_unsupported_scale_factor.
#   * test_clickbench_records_size_and_rows.
#   * test_a_checksum_is_recorded_only_where_certain: a checksum in a supported
#     manifest is one `recorded_files` holds (none is recorded yet, so a first
#     verified run is the one that records it).
#   * test_h2o_manifests_follow_the_sizes: the generated files' paths carry the
#     size and seed, the join tables have rows, rows // 1e6 and rows // 1e3
#     (at least 1) rows, and nonsense sizes are refused.
#   * test_find_manifest_by_name_and_scale: a hit, and a miss that lists what
#     is supported.
#   * test_validation_refuses_a_malformed_manifest: an absolute path, a
#     parent-directory segment, a backslash, an empty segment, a space, a
#     repeated path, a short or upper-case checksum, no files, a name that is
#     not a token, a size below the marker.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_bench_data import (
    DatasetFile,
    DatasetManifest,
    H2O_DEFAULT_GROUPS,
    H2O_DEFAULT_ROWS,
    H2O_DEFAULT_SEED,
    UNRECORDED_BYTES,
    UNRECORDED_ROWS,
    clickbench_manifest,
    find_manifest,
    h2o_groupby_manifest,
    h2o_join_manifest,
    is_sha256_hex,
    is_token,
    recorded_files,
    supported_manifests,
    tpch_manifest,
    validate_relative_path,
)


def _rows_of(m: DatasetManifest, path: String) raises -> Int:
    for i in range(len(m.files)):
        if m.files[i].path == path:
            return m.files[i].expected_rows
    raise Error("no file " + path)


def _one(path: String) -> List[DatasetFile]:
    var files = List[DatasetFile]()
    files.append(DatasetFile.unrecorded(path.copy(), 1))
    return files^


def _manifest_of(var files: List[DatasetFile]) -> DatasetManifest:
    return DatasetManifest(String("tpch"), String("sf1"), String(), files^)


def test_every_supported_manifest_is_valid_and_distinct() raises:
    var all = supported_manifests()
    assert_equal(len(all), 6)
    for i in range(len(all)):
        all[i].validate()
        assert_true(len(all[i].files) >= 1)
        for j in range(i):
            assert_false(all[i].name == all[j].name and all[i].scale == all[j].scale)
    assert_equal(all[0].name, "tpch")
    assert_equal(all[0].scale, "sf1")
    assert_equal(all[3].name, "clickbench")
    assert_equal(all[4].name, "h2o_groupby")
    assert_equal(all[5].name, "h2o_join")
    for i in range(len(all[0].files)):
        assert_true(all[0].files[i].path.startswith("tpch/sf1/"))


def test_tpch_row_counts_follow_the_specification() raises:
    var sf1 = tpch_manifest(1)
    assert_equal(len(sf1.files), 8)
    assert_equal(_rows_of(sf1, "tpch/sf1/region.parquet"), 5)
    assert_equal(_rows_of(sf1, "tpch/sf1/nation.parquet"), 25)
    assert_equal(_rows_of(sf1, "tpch/sf1/customer.parquet"), 150_000)
    assert_equal(_rows_of(sf1, "tpch/sf1/lineitem.parquet"), 6_001_215)
    var sf10 = tpch_manifest(10)
    assert_equal(_rows_of(sf10, "tpch/sf10/region.parquet"), 5)
    assert_equal(_rows_of(sf10, "tpch/sf10/nation.parquet"), 25)
    assert_equal(_rows_of(sf10, "tpch/sf10/supplier.parquet"), 100_000)
    assert_equal(_rows_of(sf10, "tpch/sf10/part.parquet"), 2_000_000)
    assert_equal(_rows_of(sf10, "tpch/sf10/partsupp.parquet"), 8_000_000)
    assert_equal(_rows_of(sf10, "tpch/sf10/orders.parquet"), 15_000_000)
    assert_equal(_rows_of(sf10, "tpch/sf10/lineitem.parquet"), UNRECORDED_ROWS)
    var sf100 = tpch_manifest(100)
    assert_equal(_rows_of(sf100, "tpch/sf100/customer.parquet"), 15_000_000)


def test_tpch_refuses_an_unsupported_scale_factor() raises:
    with assert_raises(contains="scale factor 5"):
        _ = tpch_manifest(5)
    with assert_raises(contains="scale factor 0"):
        _ = tpch_manifest(0)


def test_clickbench_records_size_and_rows() raises:
    var m = clickbench_manifest()
    assert_equal(len(m.files), 1)
    assert_equal(m.files[0].path, "clickbench/hits.parquet")
    assert_equal(m.files[0].expected_bytes, 14_779_976_446)
    assert_equal(m.files[0].expected_rows, 99_997_497)
    # its checksum is the recorded one or none (see the test below)
    assert_equal(m.generator, "")


def test_a_checksum_is_recorded_only_where_certain() raises:
    # A checksum in a supported manifest is one `recorded_files` holds: a human
    # records it from a staging run, nothing else puts one there. The h2o
    # manifests carry none (their files are generated and recorded per run).
    var all = supported_manifests()
    var recorded = recorded_files()
    for i in range(len(all)):
        for j in range(len(all[i].files)):
            ref f = all[i].files[j]
            if not f.has_sha256():
                continue
            var found = False
            for r in range(len(recorded)):
                if recorded[r].path == f.path and recorded[r].sha256 == f.expected_sha256:
                    found = True
            assert_true(found, all[i].name + ": " + f.path + " records a checksum that recorded_files does not hold")


def test_h2o_manifests_follow_the_sizes() raises:
    var g = h2o_groupby_manifest(H2O_DEFAULT_ROWS, H2O_DEFAULT_GROUPS, H2O_DEFAULT_SEED)
    assert_equal(len(g.files), 1)
    assert_equal(g.files[0].expected_rows, 10_000_000)
    assert_equal(g.generator, "komira-h2o-1")
    assert_equal(g.scale, "n10000000_k100_seed" + String(H2O_DEFAULT_SEED))
    assert_equal(g.files[0].path, "h2o/groupby_" + g.scale + ".parquet")
    var g2 = h2o_groupby_manifest(10_000_000, 100, 7)
    assert_true(g2.files[0].path != g.files[0].path)

    var j = h2o_join_manifest(10_000_000, 5)
    assert_equal(len(j.files), 4)
    assert_equal(j.files[0].expected_rows, 10_000_000)
    assert_equal(j.files[1].expected_rows, 10)
    assert_equal(j.files[2].expected_rows, 10_000)
    assert_equal(j.files[3].expected_rows, 10_000_000)
    assert_equal(j.files[1].path, "h2o/join_n10000000_seed5_small.parquet")
    var tiny = h2o_join_manifest(999, 5)
    assert_equal(tiny.files[1].expected_rows, 1)
    assert_equal(tiny.files[2].expected_rows, 1)

    with assert_raises(contains="rows must be in"):
        _ = h2o_groupby_manifest(0, 1, 1)
    with assert_raises(contains="groups must be in"):
        _ = h2o_groupby_manifest(10, 11, 1)
    with assert_raises(contains="groups must be in"):
        _ = h2o_groupby_manifest(10, 0, 1)
    with assert_raises(contains="rows must be in"):
        _ = h2o_join_manifest(2_000_000_001, 1)


def test_find_manifest_by_name_and_scale() raises:
    var m = find_manifest("tpch", "sf10")
    assert_equal(m.scale, "sf10")
    assert_equal(len(m.files), 8)
    with assert_raises(contains="no dataset tpch/sf2"):
        _ = find_manifest("tpch", "sf2")
    try:
        _ = find_manifest("tpch", "sf2")
    except e:
        assert_true(String(e).find("clickbench/full") >= 0, String(e))
        assert_true(String(e).find("tpch/sf100") >= 0, String(e))


def test_validation_refuses_a_malformed_manifest() raises:
    _manifest_of(_one("a/b.parquet")).validate()
    var bad_paths: List[String] = [
        "/etc/passwd",
        "a/../b",
        "..",
        "a\\b",
        "a//b",
        "a/ b",
        "",
        "./a",
        "a/",
    ]
    for i in range(len(bad_paths)):
        with assert_raises(contains="dataset path"):
            _manifest_of(_one(bad_paths[i])).validate()
        with assert_raises(contains="dataset path"):
            validate_relative_path(bad_paths[i])

    var twice = _one("a.parquet")
    twice.append(DatasetFile.unrecorded(String("a.parquet"), 1))
    with assert_raises(contains="listed twice"):
        _manifest_of(twice^).validate()

    var short = List[DatasetFile]()
    short.append(DatasetFile(String("a.parquet"), 1, String("abc"), 1))
    with assert_raises(contains="64 lowercase hex"):
        _manifest_of(short^).validate()
    var upper = List[DatasetFile]()
    upper.append(DatasetFile(String("a.parquet"), 1, String("A") * 64, 1))
    with assert_raises(contains="64 lowercase hex"):
        _manifest_of(upper^).validate()
    var good = List[DatasetFile]()
    good.append(DatasetFile(String("a.parquet"), 1, String("a") * 64, 1))
    _manifest_of(good^).validate()

    with assert_raises(contains="no files"):
        _manifest_of(List[DatasetFile]()).validate()
    with assert_raises(contains="name is not a token"):
        DatasetManifest(String("bad name"), String("sf1"), String(), _one("a")).validate()
    with assert_raises(contains="scale is not a token"):
        DatasetManifest(String("tpch"), String(""), String(), _one("a")).validate()
    with assert_raises(contains="generator is not a token"):
        DatasetManifest(String("tpch"), String("sf1"), String("a b"), _one("a")).validate()
    var neg = List[DatasetFile]()
    neg.append(DatasetFile(String("a"), UNRECORDED_BYTES - 1, String(), 1))
    with assert_raises(contains="size below"):
        _manifest_of(neg^).validate()
    var negrows = List[DatasetFile]()
    negrows.append(DatasetFile(String("a"), 1, String(), UNRECORDED_ROWS - 1))
    with assert_raises(contains="row count below"):
        _manifest_of(negrows^).validate()


def test_token_and_checksum_predicates() raises:
    assert_true(is_token("sf10"))
    assert_true(is_token("n1_k2-seed.3"))
    assert_false(is_token(""))
    assert_false(is_token("a b"))
    assert_false(is_token("a/b"))
    assert_true(is_sha256_hex(String("0123456789abcdef") * 4))
    assert_false(is_sha256_hex(String("0123456789abcdeg") * 4))
    assert_false(is_sha256_hex(String("0123456789abcdef") * 3))


def main() raises:
    test_every_supported_manifest_is_valid_and_distinct()
    test_tpch_row_counts_follow_the_specification()
    test_tpch_refuses_an_unsupported_scale_factor()
    test_clickbench_records_size_and_rows()
    test_a_checksum_is_recorded_only_where_certain()
    test_h2o_manifests_follow_the_sizes()
    test_find_manifest_by_name_and_scale()
    test_validation_refuses_a_malformed_manifest()
    test_token_and_checksum_predicates()
    print("OK")
