# The store table: all four --test-s3-* flags are EXTERNAL_S3; some but not
# all is CANNOT_TELL naming each missing flag; an S3 store AND a MinIO binary
# is CANNOT_TELL, never a fall back; an invalid value is CANNOT_TELL naming
# the flag; a MinIO binary alone is EMBEDDED_MINIO; none is SKIP (77) naming
# both options. The lease defaults (5400 / 120) apply when the flags are
# absent. Every reason is checked by exact text, and none carries a value.
# Opening from the choice reaches the right store.

from std.testing import assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env
from komira_test_bucket import (
    BACKEND_CHOICE_CANNOT_TELL,
    BACKEND_CHOICE_EMBEDDED_MINIO,
    BACKEND_CHOICE_EXTERNAL_S3,
    BACKEND_CHOICE_SKIP,
    BACKEND_EXTERNAL_S3,
    DEFAULT_MAX_LEASE_SECONDS,
    DEFAULT_TEARDOWN_BUDGET_SECONDS,
    BackendChoice,
    FakeObjectStore,
    TestStoreFlags,
    open_test_bucket_from_flags,
    select_backend,
)
from komira_test_minio import Readiness, ScriptedProcessRunner
from komira_test_run_id import FixedWallClock, RunId, ScriptedEntropy
from komira_test_verdict import VERDICT_CLEAN

comptime _ENDPOINT: String = "https://cfg-sentinel.invalid:9443"
comptime _BUCKET: String = "cfg-bucket-sentinel"
comptime _CREDS: String = "/mnt/creds/sentinel-credentials"


def _s3() -> List[String]:
    return [
        "--test-s3-endpoint=" + String(_ENDPOINT),
        "--test-s3-region=test-region-1",
        "--test-s3-bucket=" + String(_BUCKET),
        "--test-s3-credentials-file=" + String(_CREDS),
    ]


def _choose(args: List[String]) raises -> BackendChoice:
    return select_backend(TestStoreFlags.parse(args))


def _assert_cannot_tell(args: List[String], want: String) raises:
    var c = _choose(args)
    assert_equal(c.kind, BACKEND_CHOICE_CANNOT_TELL)
    assert_equal(c.exit_code(), 3)
    assert_false(Bool(c.s3_target))
    assert_equal(c.reason, want)
    for value in [String(_ENDPOINT), "cfg-sentinel", String(_BUCKET), "sentinel-credentials", "test-region-1"]:
        assert_false(value in c.reason, "reason carries a value: " + c.reason)


def test_all_four_is_external_s3_with_defaults() raises:
    var args = _s3()
    args.append("--test-target=//pkg:it")
    var c = _choose(args)
    assert_equal(c.kind, BACKEND_CHOICE_EXTERNAL_S3)
    assert_equal(c.exit_code(), 0)
    assert_equal(c.target_label, "//pkg:it")
    var scope = c.scope()
    assert_equal(scope.target.endpoint, _ENDPOINT)
    assert_equal(scope.target.region, "test-region-1")
    assert_equal(scope.target.bucket, _BUCKET)
    assert_equal(scope.target.credentials_file, _CREDS)
    assert_equal(scope.max_lease_seconds, 5400)
    assert_equal(scope.teardown_budget_seconds, 120)
    assert_equal(DEFAULT_MAX_LEASE_SECONDS, 5400)
    assert_equal(DEFAULT_TEARDOWN_BUDGET_SECONDS, 120)


def test_lease_flags_override_the_defaults() raises:
    var args = _s3()
    args.append("--test-max-lease-seconds=600")
    args.append("--test-teardown-budget-seconds=60")
    var scope = _choose(args).scope()
    assert_equal(scope.max_lease_seconds, 600)
    assert_equal(scope.teardown_budget_seconds, 60)
    # Only one given: the other keeps its default.
    var only: List[String] = ["--test-minio-binary=/tools/minio", "--test-max-lease-seconds=900"]
    var m = _choose(only)
    assert_equal(m.max_lease_seconds, 900)
    assert_equal(m.teardown_budget_seconds, 120)


def test_s3_flags_are_all_or_none() raises:
    var names: List[String] = [
        "--test-s3-endpoint",
        "--test-s3-region",
        "--test-s3-bucket",
        "--test-s3-credentials-file",
    ]
    var full = _s3()
    # Each one missing alone is named.
    for i in range(len(full)):
        var args = List[String]()
        for j in range(len(full)):
            if j != i:
                args.append(full[j])
        _assert_cannot_tell(
            args, "the --test-s3-* flags are all-or-none; missing " + names[i]
        )
    # Several missing: every one is named, in flag order.
    var one: List[String] = ["--test-s3-bucket=" + String(_BUCKET)]
    _assert_cannot_tell(
        one,
        "the --test-s3-* flags are all-or-none; missing --test-s3-endpoint,"
        " --test-s3-region, --test-s3-credentials-file",
    )


def test_both_stores_is_a_refusal() raises:
    var both = _s3()
    both.append("--test-minio-binary=/tools/minio")
    var want = String(
        "both an external S3-compatible store (--test-s3-*) and a MinIO binary"
        " (--test-minio-binary) were given; give one"
    )
    _assert_cannot_tell(both, want)
    # Also with a partial S3 set: never a fall back to the embedded MinIO.
    var partial: List[String] = [
        "--test-s3-endpoint=" + String(_ENDPOINT),
        "--test-minio-binary=/tools/minio",
    ]
    _assert_cannot_tell(partial, want)


def test_value_rules_name_the_flag() raises:
    var no_scheme = _s3()
    no_scheme[0] = "--test-s3-endpoint=cfg-sentinel.invalid:9443"
    _assert_cannot_tell(no_scheme, "--test-s3-endpoint: must start with http:// or https://")
    var relative = _s3()
    relative[3] = "--test-s3-credentials-file=mnt/creds/sentinel-credentials"
    _assert_cannot_tell(relative, "--test-s3-credentials-file: must be an absolute path")
    var lease_want = String(
        "--test-teardown-budget-seconds: must be below --test-max-lease-seconds (defaults 120"
        " and 5400)"
    )
    var equal = _s3()
    equal.append("--test-max-lease-seconds=600")
    equal.append("--test-teardown-budget-seconds=600")
    _assert_cannot_tell(equal, lease_want)
    # A lease shorter than the default teardown budget, on the embedded path.
    var short: List[String] = ["--test-minio-binary=/tools/minio", "--test-max-lease-seconds=100"]
    _assert_cannot_tell(short, lease_want)


def test_minio_alone_and_nothing() raises:
    var embedded_args: List[String] = ["--test-minio-binary=/tools/minio", "--test-target=//p:e"]
    var embedded = _choose(embedded_args)
    assert_equal(embedded.kind, BACKEND_CHOICE_EMBEDDED_MINIO)
    assert_equal(embedded.exit_code(), 0)
    assert_equal(embedded.minio_binary, "/tools/minio")
    assert_equal(embedded.target_label, "//p:e")
    assert_false(Bool(embedded.s3_target))

    var skip = _choose(List[String]())
    assert_equal(skip.kind, BACKEND_CHOICE_SKIP)
    assert_equal(skip.exit_code(), 77)
    assert_equal(
        skip.reason,
        "no S3-compatible endpoint configured (--test-s3-endpoint, --test-s3-region,"
        " --test-s3-bucket, --test-s3-credentials-file) and no pinned MinIO binary given"
        " (--test-minio-binary)",
    )
    # Only a target: still SKIP.
    var target_only: List[String] = ["--test-target=//p:t"]
    assert_equal(_choose(target_only).kind, BACKEND_CHOICE_SKIP)


def test_open_from_flags_reaches_the_chosen_store() raises:
    var clock = FixedWallClock(1790000000)
    var entropy = ScriptedEntropy(List[UInt64]())
    var id = RunId(String("1790000000-00000000000000f1"), 1790000000)

    # EXTERNAL_S3: the external store, no server, no bucket created.
    var args = _s3()
    args.append("--test-target=//pkg:it")
    var b = open_test_bucket_from_flags(
        _choose(args), id, String("/unused"), FakeObjectStore(), ScriptedProcessRunner(List[Readiness]()), entropy, clock
    )
    assert_equal(b.backend(), BACKEND_EXTERNAL_S3)
    assert_false(b.has_server())
    assert_equal(b.endpoint(), _ENDPOINT)
    assert_false(b.client().bucket_created)
    assert_equal(b.close().kind, VERDICT_CLEAN)

    # EMBEDDED_MINIO: the real pins are checked first, so a fixture file
    # that is not MinIO is refused there; reaching that refusal proves the
    # choice went to the embedded server and not to the external store.
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    var fixture = tmp + "/not-minio"
    with open(fixture, "w") as f:
        f.write("not a server\n")
    var embedded_args: List[String] = ["--test-minio-binary=" + fixture, "--test-target=//p:e"]
    var raised = False
    try:
        var e = open_test_bucket_from_flags(
            _choose(embedded_args), id, tmp, FakeObjectStore(), ScriptedProcessRunner([Readiness.ready()]), entropy, clock
        )
        _ = e.close()
    except err:
        raised = True
        assert_true("komira_test_minio: the binary's sha256" in String(err), String(err))
    assert_true(raised, "an unpinned binary was started")

    # A --test-minio-binary that cannot be read (a typo'd path) is refused
    # naming the FLAG; the path is a value and never reaches the message.
    var missing: List[String] = ["--test-minio-binary=/nonexistent/sentinel-path"]
    raised = False
    try:
        var m = open_test_bucket_from_flags(
            _choose(missing), id, tmp, FakeObjectStore(), ScriptedProcessRunner([Readiness.ready()]), entropy, clock
        )
        _ = m.close()
    except err:
        raised = True
        var msg = String(err)
        assert_false("sentinel-path" in msg, msg)
        assert_false("nonexistent" in msg, msg)
        assert_equal(
            msg,
            "komira_test_bucket: the MinIO given by --test-minio-binary did not start:"
            " komira_test_minio: cannot read the MinIO binary",
        )
    assert_true(raised, "an unreadable binary was accepted")

    # SKIP and CANNOT_TELL are refused, not opened.
    raised = False
    try:
        var s = open_test_bucket_from_flags(
            _choose(List[String]()), id, tmp, FakeObjectStore(), ScriptedProcessRunner(List[Readiness]()), entropy, clock
        )
        _ = s.close()
    except err:
        raised = True
        assert_equal(
            String(err),
            "komira_test_bucket: open_test_bucket_from_flags: the choice is SKIP or"
            " CANNOT_TELL; call exit_unless_runnable() first",
        )
    assert_true(raised, "a SKIP choice was opened")


def main() raises:
    test_all_four_is_external_s3_with_defaults()
    test_lease_flags_override_the_defaults()
    test_s3_flags_are_all_or_none()
    test_both_stores_is_a_refusal()
    test_value_rules_name_the_flag()
    test_minio_alone_and_nothing()
    test_open_from_flags_reaches_the_chosen_store()
    print("test_store_choice: OK")
