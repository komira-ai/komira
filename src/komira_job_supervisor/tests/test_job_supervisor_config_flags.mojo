# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_config_flags.mojo
#   The supervisor is configured by flags, and every bad flag is refused
#   naming it, before anything runs.
# =============================================================================
#
# `JobSupervisorConfig.from_args` and `S3StoreFlags.from_args` are the whole
# configuration surface. These arms parse a full flag set, then show each
# refusal: a missing or empty required flag, an unknown flag (a typo must not
# become a silent default), a flag given twice, a number that does not parse,
# a malformed digest, a heartbeat URL that is not usable. Each refusal is
# paired with the accepted form.
#
# The S3 half: an absent endpoint selects TLS (AWS's own endpoint is
# HTTPS-only) and an endpoint's own scheme decides otherwise; each tool's
# flags pass through the other's parser via `other_flags`.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_job_supervisor import (
    HttpHeartbeatReporter,
    JobSupervisorConfig,
    NoHeartbeatAuth,
    S3StoreFlags,
    job_supervisor_flag_names,
    run_job_supervisor_on_s3,
    s3_store_flag_names,
)


def _args(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _base() -> List[String]:
    return _args(
        "--job-name=nightly-report",
        "--job-binary=/opt/job/run",
        "--heartbeat-url=https://hb.example.com/beat",
    )


def _refusal(var args: List[String]) -> String:
    try:
        _ = JobSupervisorConfig.from_args(args)
    except e:
        return String(e)
    return String("")


def test_a_full_flag_set_parses() raises:
    var args = _args(
        "--job-name=nightly-report",
        "--instance-name=worker-7",
        "--job-binary=/opt/job/run",
        "--heartbeat-url=https://hb.example.com/beat",
        "--job-arg=--date",
        "--job-arg=2026-10-04",
        "--heartbeat-interval-secs=15",
        "--max-stderr-lines=20",
        "--max-stdout-bytes=4096",
        "--binary-key=jobs/run",
        "--binary-sha256=" + "a" * 64,
        "--binary-download-path=/tmp/job/run",
        "--log-prefix=logs/nightly",
        "--log-chunk-bytes=1024",
        "--log-flush-secs=3",
        "--",
        "--verbose",
    )
    var c = JobSupervisorConfig.from_args(args)
    assert_equal(c.job_name, String("nightly-report"))
    assert_equal(c.instance_name, String("worker-7"))
    assert_equal(c.job_binary_path, String("/opt/job/run"))
    assert_equal(c.heartbeat_url, String("https://hb.example.com/beat"))
    assert_equal(len(c.job_argv), 3, "two --job-arg plus the trailing one")
    assert_equal(c.job_argv[0], String("--date"))
    assert_equal(c.job_argv[1], String("2026-10-04"))
    assert_equal(c.job_argv[2], String("--verbose"), "after -- is verbatim")
    assert_equal(c.heartbeat_interval_secs, 15)
    assert_equal(c.max_stderr_lines, 20)
    assert_equal(c.max_stdout_bytes, 4096)
    assert_equal(c.binary_key.value(), String("jobs/run"))
    assert_equal(c.binary_sha256.value(), String("a" * 64))
    assert_equal(c.binary_download_path, String("/tmp/job/run"))
    assert_equal(c.log_prefix, String("logs/nightly"))
    assert_equal(c.log_chunk_bytes, 1024)
    assert_equal(c.log_flush_secs, 3)

    # CONTROL: the minimum set takes every default.
    var d = JobSupervisorConfig.from_args(_base())
    assert_equal(d.instance_name, String(""), "instance name defaults empty")
    assert_equal(d.heartbeat_interval_secs, 5)
    assert_false(d.uses_binary_store(), "no --binary-key: run the local binary")
    assert_equal(d.binary_download_path, String("/opt/job/run"))
    assert_equal(d.log_prefix, String("nightly-report"), "prefix = job name")
    print("  test_a_full_flag_set_parses: PASS")


def test_each_bad_flag_is_refused_naming_it() raises:
    var missing = _refusal(
        _args("--job-binary=/opt/job/run", "--heartbeat-url=http://h/beat")
    )
    assert_true(missing.find(String("--job-name")) >= 0, "missing: " + missing)

    var empty = _base()
    empty.append(String("--job-name="))
    var e2 = _refusal(empty^)
    assert_true(e2.find(String("--job-name")) >= 0, "twice/empty: " + e2)

    var empty_only = _args(
        "--job-name=",
        "--job-binary=/opt/job/run",
        "--heartbeat-url=http://h/beat",
    )
    var e3 = _refusal(empty_only^)
    assert_true(e3.find(String("is empty")) >= 0, "empty: " + e3)

    var typo = _base()
    typo.append(String("--heartbeat-intervl-secs=9"))
    var t = _refusal(typo^)
    assert_true(
        t.find(String("unknown flag --heartbeat-intervl-secs")) >= 0, "typo: " + t
    )

    var twice = _base()
    twice.append(String("--job-binary=/other"))
    var tw = _refusal(twice^)
    assert_true(tw.find(String("more than once")) >= 0, "twice: " + tw)

    var garbage = _base()
    garbage.append(String("--heartbeat-interval-secs=5s"))
    var g = _refusal(garbage^)
    assert_true(
        g.find(String("--heartbeat-interval-secs")) >= 0, "garbage int: " + g
    )

    var zero = _base()
    zero.append(String("--max-stderr-lines=0"))
    var z = _refusal(zero^)
    assert_true(z.find(String("--max-stderr-lines")) >= 0, "zero: " + z)

    var bad_sha = _base()
    bad_sha.append(String("--binary-sha256=ABC"))
    var bs = _refusal(bad_sha^)
    assert_true(bs.find(String("--binary-sha256")) >= 0, "digest: " + bs)

    var no_value = _base()
    no_value.append(String("--job-arg"))
    var nv = _refusal(no_value^)
    assert_true(nv.find(String("has no value")) >= 0, "no value: " + nv)

    var bare = _base()
    bare.append(String("stray"))
    var br = _refusal(bare^)
    assert_true(br.find(String("unexpected argument")) >= 0, "bare: " + br)

    var bad_url = _args(
        "--job-name=j", "--job-binary=/b", "--heartbeat-url=hb.example.com"
    )
    var bu = _refusal(bad_url^)
    assert_true(bu.find(String("--heartbeat-url")) >= 0, "url: " + bu)

    # CONTROL: the base set itself is accepted, so each refusal above is the
    # one flag's.
    assert_equal(_refusal(_base()), String(""), "CONTROL: the base set parses")
    print("  test_each_bad_flag_is_refused_naming_it: PASS")


def test_the_s3_store_flags() raises:
    var args = _base()
    args.append(String("--s3-log-bucket=logs"))
    args.append(String("--s3-endpoint=http://127.0.0.1:9000"))
    # Each parser skips the other's flags when told about them, and refuses
    # them when not.
    var refused = False
    try:
        _ = JobSupervisorConfig.from_args(args)
    except:
        refused = True
    assert_true(refused, "S3 flags are unknown to the core parser on their own")
    _ = JobSupervisorConfig.from_args(args, s3_store_flag_names())
    var s3 = S3StoreFlags.from_args(args, job_supervisor_flag_names())
    assert_false(Bool(s3.binary_bucket), "no binary bucket given")
    assert_equal(s3.log_bucket.value(), String("logs"))
    assert_equal(s3.region, String("us-east-1"), "default region")
    assert_false(s3.uses_tls(), "an http:// endpoint dials plaintext")

    var tls = S3StoreFlags(None, None, String("https://minio:9000"), String("r"))
    assert_true(tls.uses_tls(), "an https:// endpoint dials TLS")
    var aws = S3StoreFlags(None, None, None, String("us-east-1"))
    assert_true(aws.uses_tls(), "no endpoint is AWS itself: HTTPS only")

    var empty = _base()
    empty.append(String("--s3-region="))
    var e_refused = False
    try:
        _ = S3StoreFlags.from_args(empty, job_supervisor_flag_names())
    except:
        e_refused = True
    assert_true(e_refused, "an empty S3 flag is refused")
    print("  test_the_s3_store_flags: PASS")


def test_the_s3_entry_point_instantiates(run_it: Bool) raises:
    """Instantiates `run_job_supervisor_on_s3` with the shipped reporter so the
    compiler checks the whole S3 path (both transports). `run_it` is False:
    nothing is dialled."""
    if run_it:
        var c = JobSupervisorConfig.from_args(_base())
        var r = HttpHeartbeatReporter[NoHeartbeatAuth](
            c.heartbeat_url, NoHeartbeatAuth()
        )
        _ = run_job_supervisor_on_s3[HttpHeartbeatReporter[NoHeartbeatAuth]](
            c^, r^, S3StoreFlags(None, None, None, String("us-east-1"))
        )
    print("  test_the_s3_entry_point_instantiates: PASS")


def main() raises:
    print("test_job_supervisor_config_flags:")
    test_a_full_flag_set_parses()
    test_each_bad_flag_is_refused_naming_it()
    test_the_s3_store_flags()
    test_the_s3_entry_point_instantiates(len(_base()) == 0)
    print("test_job_supervisor_config_flags: ALL PASS")
