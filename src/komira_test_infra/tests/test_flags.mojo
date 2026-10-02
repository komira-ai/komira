# The runner flags and the backend table: a readable config is FARM, an
# unreadable or invalid one is CANNOT_TELL (exit 3) and NEVER a fall back to
# LOCAL, a MinIO path alone is LOCAL, and neither is SKIP (exit 77).

from std.testing import assert_equal, assert_false, assert_true

from komira_test_infra import (
    BACKEND_CHOICE_CANNOT_TELL,
    BACKEND_CHOICE_FARM,
    BACKEND_CHOICE_LOCAL,
    BACKEND_CHOICE_SKIP,
    MapFiles,
    TestInfraFlags,
    select_backend,
)

comptime _GOOD: String = """
object_store {
  endpoint: "https://flags-sentinel.invalid"
  region: "r1"
  bucket: "b1"
  run_prefix: "runs/"
  credentials_file: "/c/credentials"
}
max_lease_seconds: 600
teardown_budget_seconds: 60
"""


def _parse_error(args: List[String]) -> String:
    try:
        _ = TestInfraFlags.parse(args)
    except e:
        return String(e)
    return String("")


def test_parse_reads_the_three_flags_and_ignores_others() raises:
    var args: List[String] = [
        "--verbose",
        "--testinfra-config=/cfg/t.textproto",
        "positional",
        "--testinfra-target=//pkg:test_x",
        "--testinfra-local-minio=/tools/minio",
    ]
    var f = TestInfraFlags.parse(args)
    assert_equal(f.config_path, "/cfg/t.textproto")
    assert_equal(f.target, "//pkg:test_x")
    assert_equal(f.local_minio, "/tools/minio")
    var none = TestInfraFlags.parse(List[String]())
    assert_equal(none.config_path, "")
    assert_equal(none.local_minio, "")


def test_parse_refusals() raises:
    var unknown: List[String] = ["--testinfra-secret=/x"]
    assert_true("unknown flag --testinfra-secret" in _parse_error(unknown))
    var empty: List[String] = ["--testinfra-config="]
    assert_true("empty value" in _parse_error(empty))
    var bare: List[String] = ["--testinfra-target"]
    assert_true("needs a value" in _parse_error(bare))
    var twice: List[String] = ["--testinfra-local-minio=/a", "--testinfra-local-minio=/b"]
    assert_true("more than once" in _parse_error(twice))


def test_backend_table() raises:
    var files = MapFiles()
    files.put("/cfg/good.textproto", _GOOD)
    files.put("/cfg/bad.textproto", "object_store { endpoint: 5 }")

    var farm_args: List[String] = ["--testinfra-config=/cfg/good.textproto"]
    var farm = select_backend(TestInfraFlags.parse(farm_args), files)
    assert_equal(farm.kind, BACKEND_CHOICE_FARM)
    assert_true(Bool(farm.config))
    assert_equal(farm.config.value().bucket, "b1")
    assert_equal(farm.exit_code(), 0)

    # Config + MinIO: the config wins.
    var both_args: List[String] = [
        "--testinfra-config=/cfg/good.textproto",
        "--testinfra-local-minio=/tools/minio",
    ]
    assert_equal(select_backend(TestInfraFlags.parse(both_args), files).kind, BACKEND_CHOICE_FARM)

    # Unreadable config, even with a MinIO path: CANNOT_TELL, never LOCAL.
    var missing_args: List[String] = [
        "--testinfra-config=/cfg/absent.textproto",
        "--testinfra-local-minio=/tools/minio",
    ]
    var missing = select_backend(TestInfraFlags.parse(missing_args), files)
    assert_equal(missing.kind, BACKEND_CHOICE_CANNOT_TELL)
    assert_equal(missing.exit_code(), 3)
    assert_false(Bool(missing.config))

    # Invalid config: CANNOT_TELL, naming the field.
    var bad_args: List[String] = [
        "--testinfra-config=/cfg/bad.textproto",
        "--testinfra-local-minio=/tools/minio",
    ]
    var bad = select_backend(TestInfraFlags.parse(bad_args), files)
    assert_equal(bad.kind, BACKEND_CHOICE_CANNOT_TELL)
    assert_true("object_store.endpoint" in bad.reason, bad.reason)

    var local_args: List[String] = ["--testinfra-local-minio=/tools/minio"]
    var local = select_backend(TestInfraFlags.parse(local_args), files)
    assert_equal(local.kind, BACKEND_CHOICE_LOCAL)
    assert_equal(local.exit_code(), 0)

    var skip = select_backend(TestInfraFlags.parse(List[String]()), files)
    assert_equal(skip.kind, BACKEND_CHOICE_SKIP)
    assert_equal(skip.exit_code(), 77)
    assert_true("--testinfra-config" in skip.reason, skip.reason)


def main() raises:
    test_parse_reads_the_three_flags_and_ignores_others()
    test_parse_refusals()
    test_backend_table()
    print("test_flags: OK")
