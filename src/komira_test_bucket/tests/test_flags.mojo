# The runner flags (parse only; the store table is test_store_choice): each
# flag is read, others are left to the test, and every refusal -- an unknown
# flag in the family, a retired `--testinfra-*` spelling, a missing or empty
# value, a repeat, a lease value that is not a whole number from 1 to
# 999999999 -- raises with an exact message that names the flag and never
# its value.

from std.testing import assert_equal, assert_true

from komira_test_bucket import TestStoreFlags


def _parse_error(args: List[String]) -> String:
    try:
        _ = TestStoreFlags.parse(args)
    except e:
        return String(e)
    return String("")


def _assert_refused(args: List[String], want: String) raises:
    var msg = _parse_error(args)
    assert_equal(msg, want)


def test_parse_reads_every_flag_and_ignores_others() raises:
    var args: List[String] = [
        "--verbose",
        "--test-s3-endpoint=https://s3.example.invalid",
        "positional",
        "--test-s3-region=r1",
        "--test-s3-bucket=b1",
        "--test-s3-credentials-file=/c/credentials",
        "--test-minio-binary=/tools/minio",
        "--test-target=//pkg:test_x",
        "--test-max-lease-seconds=600",
        "--test-teardown-budget-seconds=60",
        # A test's own --test-* flag outside this family is left alone.
        "--test-shards=4",
        "--test",
    ]
    var f = TestStoreFlags.parse(args)
    assert_equal(f.s3_endpoint, "https://s3.example.invalid")
    assert_equal(f.s3_region, "r1")
    assert_equal(f.s3_bucket, "b1")
    assert_equal(f.s3_credentials_file, "/c/credentials")
    assert_equal(f.minio_binary, "/tools/minio")
    assert_equal(f.target, "//pkg:test_x")
    assert_equal(f.max_lease_seconds, 600)
    assert_equal(f.teardown_budget_seconds, 60)
    var none = TestStoreFlags.parse(List[String]())
    assert_equal(none.s3_endpoint, "")
    assert_equal(none.minio_binary, "")
    assert_equal(none.target, "")
    assert_equal(none.max_lease_seconds, -1)
    assert_equal(none.teardown_budget_seconds, -1)


def test_unknown_flags_in_the_family_are_refused() raises:
    _assert_refused(
        ["--test-s3-secret=/x"], "komira_test_bucket: unknown flag --test-s3-secret"
    )
    _assert_refused(
        ["--test-s3-endpont=https://x.invalid"],
        "komira_test_bucket: unknown flag --test-s3-endpont",
    )
    _assert_refused(
        ["--test-minio-bin=/tools/minio"], "komira_test_bucket: unknown flag --test-minio-bin"
    )
    _assert_refused(
        ["--test-targets=//p:t"], "komira_test_bucket: unknown flag --test-targets"
    )
    _assert_refused(
        ["--test-max-lease=600"], "komira_test_bucket: unknown flag --test-max-lease"
    )
    _assert_refused(
        ["--test-teardown-seconds=60"],
        "komira_test_bucket: unknown flag --test-teardown-seconds",
    )
    # A value glued on without `=` is not echoed as a "flag name".
    _assert_refused(
        ["--test-s3-endpointhttps://x.invalid:9000"],
        "komira_test_bucket: unknown flag (a flag whose name is not shown: not shaped like"
        " a flag name)",
    )


def test_retired_spellings_are_refused_loudly() raises:
    # A runner still passing the old flags must fail, not fall through to
    # SKIP.
    var retired: List[String] = [
        "--testinfra-s3-config",
        "--testinfra-minio-binary",
        "--testinfra-target",
        "--testinfra-config",
        "--testinfra-local-minio",
    ]
    for name in retired:
        var args: List[String] = [name + "=/some/path"]
        _assert_refused(
            args,
            "komira_test_bucket: unknown flag "
            + name
            + " (the --testinfra-* flags are retired; use the --test-* flags)",
        )


def test_value_refusals() raises:
    _assert_refused(
        ["--test-s3-endpoint="], "komira_test_bucket: --test-s3-endpoint has an empty value"
    )
    _assert_refused(
        ["--test-target"],
        "komira_test_bucket: --test-target needs a value (--test-target=<value>)",
    )
    _assert_refused(
        ["--test-minio-binary=/a", "--test-minio-binary=/b"],
        "komira_test_bucket: --test-minio-binary given more than once",
    )
    _assert_refused(
        ["--test-s3-region=r1", "--test-s3-region=r1"],
        "komira_test_bucket: --test-s3-region given more than once",
    )
    for bad in ["abc", "0", "-5", "1000000000", "60s", "1.5"]:
        _assert_refused(
            ["--test-max-lease-seconds=" + String(bad)],
            "komira_test_bucket: --test-max-lease-seconds: expected a whole number from 1 to"
            " 999999999",
        )
        _assert_refused(
            ["--test-teardown-budget-seconds=" + String(bad)],
            "komira_test_bucket: --test-teardown-budget-seconds: expected a whole number from"
            " 1 to 999999999",
        )
    var top: List[String] = ["--test-max-lease-seconds=999999999"]
    assert_equal(TestStoreFlags.parse(top).max_lease_seconds, 999999999)


def main() raises:
    test_parse_reads_every_flag_and_ignores_others()
    test_unknown_flags_in_the_family_are_refused()
    test_retired_spellings_are_refused_loudly()
    test_value_refusals()
    print("test_flags: OK")
