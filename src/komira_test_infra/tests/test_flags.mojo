# The runner flags and the backend table: a readable config is EXTERNAL_S3,
# an unreadable or invalid one is CANNOT_TELL (exit 3) and NEVER a fall back
# to EMBEDDED_MINIO, a MinIO path alone is EMBEDDED_MINIO, and neither (the
# default) is SKIP (exit 77).

from std.testing import assert_equal, assert_false, assert_true

from komira_test_infra import (
    BACKEND_CHOICE_CANNOT_TELL,
    BACKEND_CHOICE_EXTERNAL_S3,
    BACKEND_CHOICE_EMBEDDED_MINIO,
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
        "--testinfra-s3-config=/cfg/t.textproto",
        "positional",
        "--testinfra-target=//pkg:test_x",
        "--testinfra-minio-binary=/tools/minio",
    ]
    var f = TestInfraFlags.parse(args)
    assert_equal(f.config_path, "/cfg/t.textproto")
    assert_equal(f.target, "//pkg:test_x")
    assert_equal(f.minio_binary, "/tools/minio")
    var none = TestInfraFlags.parse(List[String]())
    assert_equal(none.config_path, "")
    assert_equal(none.minio_binary, "")


def test_parse_refusals() raises:
    var unknown: List[String] = ["--testinfra-secret=/x"]
    assert_true("unknown flag --testinfra-secret" in _parse_error(unknown))
    var empty: List[String] = ["--testinfra-s3-config="]
    assert_true("empty value" in _parse_error(empty))
    var bare: List[String] = ["--testinfra-target"]
    assert_true("needs a value" in _parse_error(bare))
    var twice: List[String] = ["--testinfra-minio-binary=/a", "--testinfra-minio-binary=/b"]
    assert_true("more than once" in _parse_error(twice))
    # The pre-rename config flag is refused, not ignored: a runner still
    # passing it must fail loudly rather than fall through to SKIP.
    var old_config: List[String] = ["--testinfra-config=/cfg/t.textproto"]
    assert_true("unknown flag --testinfra-config" in _parse_error(old_config))


def test_backend_table() raises:
    var files = MapFiles()
    files.put("/cfg/good.textproto", _GOOD)
    files.put("/cfg/bad.textproto", "object_store { endpoint: 5 }")

    var external_args: List[String] = ["--testinfra-s3-config=/cfg/good.textproto"]
    var external = select_backend(TestInfraFlags.parse(external_args), files)
    assert_equal(external.kind, BACKEND_CHOICE_EXTERNAL_S3)
    assert_true(Bool(external.config))
    assert_equal(external.config.value().bucket, "b1")
    assert_equal(external.exit_code(), 0)

    # Config + MinIO: the config wins.
    var both_args: List[String] = [
        "--testinfra-s3-config=/cfg/good.textproto",
        "--testinfra-minio-binary=/tools/minio",
    ]
    var both = select_backend(TestInfraFlags.parse(both_args), files)
    assert_equal(both.kind, BACKEND_CHOICE_EXTERNAL_S3)

    # Unreadable config, even with a MinIO path: CANNOT_TELL, never
    # EMBEDDED_MINIO.
    var missing_args: List[String] = [
        "--testinfra-s3-config=/cfg/absent.textproto",
        "--testinfra-minio-binary=/tools/minio",
    ]
    var missing = select_backend(TestInfraFlags.parse(missing_args), files)
    assert_equal(missing.kind, BACKEND_CHOICE_CANNOT_TELL)
    assert_equal(missing.exit_code(), 3)
    assert_false(Bool(missing.config))

    # Invalid config: CANNOT_TELL, naming the field.
    var bad_args: List[String] = [
        "--testinfra-s3-config=/cfg/bad.textproto",
        "--testinfra-minio-binary=/tools/minio",
    ]
    var bad = select_backend(TestInfraFlags.parse(bad_args), files)
    assert_equal(bad.kind, BACKEND_CHOICE_CANNOT_TELL)
    assert_true("object_store.endpoint" in bad.reason, bad.reason)

    var embedded_args: List[String] = ["--testinfra-minio-binary=/tools/minio"]
    var embedded = select_backend(TestInfraFlags.parse(embedded_args), files)
    assert_equal(embedded.kind, BACKEND_CHOICE_EMBEDDED_MINIO)
    assert_equal(embedded.exit_code(), 0)

    var skip = select_backend(TestInfraFlags.parse(List[String]()), files)
    assert_equal(skip.kind, BACKEND_CHOICE_SKIP)
    assert_equal(skip.exit_code(), 77)
    assert_true("--testinfra-s3-config" in skip.reason, skip.reason)
    assert_true("--testinfra-minio-binary" in skip.reason, skip.reason)


def main() raises:
    test_parse_reads_the_three_flags_and_ignores_others()
    test_parse_refusals()
    test_backend_table()
    print("test_flags: OK")
