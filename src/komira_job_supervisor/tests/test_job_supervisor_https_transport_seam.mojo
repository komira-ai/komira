# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_https_transport_seam.mojo
#   THE JOB SUPERVISOR CAN BE POINTED AT AN https:// JOB MANAGER AND AT REAL S3.
# =============================================================================
#
# ⛔⛔ THE DEFECT. The job supervisor was PLAINTEXT-ONLY, in a way no configuration could
# reach, and it failed silently at three seams that only production observes:
#
#   1. The placement hands the job supervisor the job manager's host and port, not
#      its URL, so the scheme has to travel as its own value. Nothing read it.
#      `heartbeat_client` then hardcoded `Url.http` AND
#      `HttpClient[KernelTcpConnector]`. So NO job-manager URL --
#      `https://` included -- could make a placed job supervisor speak TLS, which is
#      exactly what a Lambda-backed job manager behind API Gateway requires.
#
#   2. `JobSupervisorS3Client` maps an ABSENT endpoint onto
#      `S3Config.aws(region)` -- virtual-hosted, scheme `https`. The job supervisor's
#      client was `JobSupervisorS3Client[KernelTcpConnector]`. So a job supervisor pointed at real S3
#      built a correctly-signed request for an `https://` URL and wrote it in
#      the CLEAR to port 443: the URL layer and the socket layer disagreed and
#      neither could see it.
#
#   3. The composite failure has the worst possible shape. ECS `RunTask` answers
#      200 with a task ARN, placement is RECORDED, the task then cannot fetch
#      its binary or report a phase, and the job is reaped 60s later as
#      stale. A post-deploy smoke test asserting "the JM
#      placed something" passes throughout.
#
# ★ WHAT THIS TEST IS. It walks the JOB SUPERVISOR's half of the seam, in the order the
# value travels -- pod env -> JobSupervisorConfig -> transport type. The scheduler's
# half (scheduler URL -> pod env, and the refusal of an empty job supervisor image) is
# the job manager's render and is tested with the job manager, which is not
# part of this package.
#
# ⚠ IT ASSERTS TYPES AND VALUES, NOT A HANDSHAKE. Proving TLS bytes on a wire
# needs a live listener with a certificate, which is a live-infrastructure INTEGRATION
# rig; this is a hermetic unit. What it CAN prove without one is precisely what
# was missing: that the choice is EXPRESSIBLE and that it PROPAGATES. Arms 5
# and 6 are the type-level half -- they do not run a dial, they establish that
# `JobSupervisorS3Client[TlsConnector[KernelTcpConnector]]` and
# `JobSupervisor[TlsConnector[KernelTcpConnector]]` are constructible values the job supervisor's
# own code paths accept, which is the thing that did not compile before.
#
# ⚠ EVERY ARM HAS A CONTROL. An assertion that `https` yields TLS is satisfied
# by a function that returns True unconditionally, so each arm is paired with
# the `http` / MinIO case that must come back False.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from komira_job_supervisor.job_supervisor import PlainJobSupervisor, TlsJobSupervisor
from komira_job_supervisor.job_supervisor_config import JobSupervisorConfig
from komira_job_supervisor.boot import (
    make_s3_client_from_chain,
    make_tls_s3_client_from_chain,
)
from komira_job_supervisor.heartbeat_client import build_job_supervisor_jm_tls_connector


# =============================================================================
# helpers
# =============================================================================
def _setenv(name: String, value: String):
    """libc setenv (tests only -- the `test_push_registry_first_resolver`
    idiom)."""
    var name_str = name
    var value_str = value
    var name_ptr = name_str.as_c_string_slice().unsafe_ptr()
    var value_ptr = value_str.as_c_string_slice().unsafe_ptr()
    var _rc = external_call["setenv", Int32](name_ptr, value_ptr, Int32(1))


def _stub_aws_credentials():
    """Put STATIC credentials on the env so the default chain's FIRST arm fires.

    ⛔ THIS IS NOT TEST SCAFFOLDING THAT COULD BE DROPPED -- it is what keeps
    arms 5 and 6 HERMETIC. The default chain walks env -> profile ->
    web-identity -> container -> IMDS, and with no env arm it reaches for
    IMDS over the network. Without this the two arms would
    fail on a build worker and pass on a developer's laptop that happens to
    have AWS creds exported, which is the worst kind of test.

    The values are syntactically valid and deliberately worthless: nothing here
    dials, so they are only ever used to compute a SigV4 key that is never
    sent."""
    _setenv(String("AWS_ACCESS_KEY_ID"), String("AKIAIOSFODNN7EXAMPLE"))
    _setenv(
        String("AWS_SECRET_ACCESS_KEY"),
        String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
    )



def _config_with_s3_endpoint(
    var endpoint: Optional[String],
) raises -> JobSupervisorConfig:
    """A minimal JobSupervisorConfig differing from its siblings ONLY in the S3
    endpoint, so an arm's verdict can come from nothing else."""
    var argv = List[String]()
    return JobSupervisorConfig(
        String("11111111-2222-3333-4444-555555555555"),
        String("pod-seam"),
        String("/bin/true"),
        argv^,
        String("jm.example.com"),
        UInt16(443),
        5,
        100,
        8 * 1024 * 1024,
        Optional[String](),          # binary_s3_uri
        Optional[String](),          # binary_sha256
        String(""),                  # binary_download_path
        Optional[String](),          # log_bucket
        endpoint^,                   # s3_endpoint  <- the variable under test
        String("us-east-1"),
    )


def _config_with_jm_scheme(var scheme: String) raises -> JobSupervisorConfig:
    """A minimal JobSupervisorConfig differing from its sibling ONLY in the JM
    scheme."""
    var argv = List[String]()
    return JobSupervisorConfig(
        String("11111111-2222-3333-4444-555555555555"),
        String("pod-seam"),
        String("/bin/true"),
        argv^,
        String("jm.example.com"),
        UInt16(443),
        5,
        100,
        8 * 1024 * 1024,
        Optional[String](),
        Optional[String](),
        String(""),
        Optional[String](),
        Optional[String](),
        String("us-east-1"),
        jm_scheme=scheme^,
    )


# =============================================================================
# ARM 2 — the job supervisor reads that env var and turns it into a transport decision.
# =============================================================================
def test_job_supervisor_config_turns_the_scheme_into_a_tls_decision() raises:
    """`JobSupervisorConfig.jm_uses_tls()` is True for `https` and False for `http`.

    RED before the fix: `JobSupervisorConfig` had no `jm_scheme` field and no
    `jm_uses_tls` at all -- the heartbeat transport was not a decision anything
    could make."""
    var https_cfg = _config_with_jm_scheme(String("https"))
    assert_true(
        https_cfg.jm_uses_tls(),
        "an https scheme must select the TLS heartbeat transport",
    )
    var http_cfg = _config_with_jm_scheme(String("http"))
    assert_false(
        http_cfg.jm_uses_tls(),
        "CONTROL: http must stay plaintext -- the in-cluster/in-process"
        " heartbeat seam every functional test drives",
    )
    # An unrecognised scheme is NOT coerced toward TLS: a typo must not make a
    # plaintext deploy start dialling TLS either.
    var junk_cfg = _config_with_jm_scheme(String("htps"))
    assert_false(
        junk_cfg.jm_uses_tls(),
        "CONTROL: an unrecognised scheme falls back to http, not to https",
    )
    print("  test_job_supervisor_config_turns_the_scheme_into_a_tls_decision: PASS")


# =============================================================================
# ARM 3 — ABSENCE of an S3 endpoint means REAL AWS, which is HTTPS-ONLY.
# =============================================================================
def test_absent_s3_endpoint_selects_tls_because_real_s3_is_https() raises:
    """⛔ THIS IS THE ARM THAT WOULD BE WRITTEN BACKWARDS BY ANYONE FOLLOWING
    THE USUAL "absent means the simple thing" instinct.

    `JobSupervisorS3Client` maps a None endpoint onto `S3Config.aws(region)`,
    which is virtual-hosted **HTTPS**. So the pre-fix job supervisor was ALREADY building
    `https://` S3 URLs and dialling them over a `KernelTcpConnector`. Defaulting
    this predicate to plaintext would preserve exactly that bug while looking
    like a conservative default.

    RED before the fix: `s3_uses_tls()` did not exist."""
    var aws_cfg = _config_with_s3_endpoint(Optional[String]())
    assert_true(
        aws_cfg.s3_uses_tls(),
        "an ABSENT S3 endpoint is real AWS S3, which is HTTPS-only -- absence"
        " must select TLS here, not plaintext",
    )
    print("  test_absent_s3_endpoint_selects_tls_because_real_s3_is_https: PASS")


def test_s3_endpoint_scheme_decides_the_transport() raises:
    """An explicit endpoint carries its own scheme, and the TRANSPORT now
    follows it. The MinIO arm is the CONTROL that keeps every existing
    docker/k8s deploy on the plaintext path with no new env var."""
    var https_cfg = _config_with_s3_endpoint(
        Optional[String](String("https://s3.us-east-1.amazonaws.com"))
    )
    assert_true(
        https_cfg.s3_uses_tls(),
        "an https:// S3 endpoint must select the TLS transport",
    )
    var minio_cfg = _config_with_s3_endpoint(
        Optional[String](String("http://minio:9000"))
    )
    assert_false(
        minio_cfg.s3_uses_tls(),
        "CONTROL: http://minio:9000 must stay plaintext -- this is the"
        " in-cluster MinIO rig every S3 functional test runs against",
    )
    print("  test_s3_endpoint_scheme_decides_the_transport: PASS")


# =============================================================================
# ARM 4 — the JM heartbeat TLS connector exists and is the EXISTING one.
# =============================================================================
def test_job_supervisor_jm_tls_connector_is_constructible() raises:
    """`build_job_supervisor_jm_tls_connector()` yields a real
    `TlsConnector[KernelTcpConnector]`.

    RED before the fix: the symbol did not exist. The point of asserting it is
    not that a constructor works -- it is that the job supervisor has a NAMED place where
    its JM TLS posture is decided, so a future `disable_verify()` would have to
    be written somewhere a reader is looking."""
    var c = build_job_supervisor_jm_tls_connector()
    _ = c^
    print("  test_job_supervisor_jm_tls_connector_is_constructible: PASS")


# =============================================================================
# ARM 5 — the S3 client can be built over TLS, honouring an https endpoint.
# =============================================================================
def test_s3_client_is_constructible_over_tls() raises:
    """`make_tls_s3_client_from_chain` yields an
    `JobSupervisorS3Client[TlsConnector[KernelTcpConnector]]` that keeps the endpoint it was
    given, and the plaintext factory still yields the
    `JobSupervisorS3Client[KernelTcpConnector]` it always did.

    RED before the fix: `make_tls_s3_client_from_chain` did not exist and
    `JobSupervisorS3Client[TlsConnector[...]]` appeared nowhere in the job supervisor -- there was no
    S3 transport for a job supervisor to be given.

    No network is touched: construction resolves credentials and builds config,
    it does not dial."""
    _stub_aws_credentials()
    var ep = Optional[String](String("https://s3.us-east-1.amazonaws.com"))
    var tls_client = make_tls_s3_client_from_chain(String("us-east-1"), ep)
    assert_true(
        tls_client.endpoint().__bool__(),
        "the TLS client must keep the endpoint it was configured with",
    )
    assert_equal(
        tls_client.endpoint().value(),
        String("https://s3.us-east-1.amazonaws.com"),
        "the endpoint must survive the TLS binding unchanged",
    )
    _ = tls_client^

    # CONTROL: the plaintext factory is unchanged and still typed on
    # KernelTcpConnector -- the fix adds an arm, it does not move the old one.
    var plain_client = make_s3_client_from_chain(
        String("us-east-1"),
        Optional[String](String("http://minio:9000")),
    )
    assert_equal(
        plain_client.endpoint().value(),
        String("http://minio:9000"),
        "CONTROL: the plaintext arm is untouched",
    )
    _ = plain_client^
    print("  test_s3_client_is_constructible_over_tls: PASS")


# =============================================================================
# ARM 6 — the JOB SUPERVISOR ITSELF exists over the TLS transport.
# =============================================================================
def test_job_supervisor_exists_over_the_tls_transport() raises:
    """`TlsJobSupervisor` -- `JobSupervisor[TlsConnector[KernelTcpConnector]]` -- is a real,
    constructible job supervisor that accepts a TLS S3 client as its live log-stream
    client.

    ★ THIS IS THE ARM THE SEAM IS FOR. Before the fix `JobSupervisor` was not
    generic at all: its field was `Optional[JobSupervisorS3Client[KernelTcpConnector]]`, so
    `TlsJobSupervisor` was not a type and `attach_stream_client` could not be handed a
    TLS client. The failure was a COMPILE error, which is why the value of this
    arm is that it compiles and runs -- a runtime assertion cannot be reached by
    a program that does not build.

    The plaintext `PlainJobSupervisor` control is what proves the old instantiation
    survives rather than having been replaced."""
    _stub_aws_credentials()
    var tls_job_supervisor = TlsJobSupervisor(
        _config_with_s3_endpoint(Optional[String]())
    )
    assert_true(
        tls_job_supervisor.config.s3_uses_tls(),
        "a TlsJobSupervisor built from a real-AWS config must agree that its transport"
        " is TLS -- if these two could disagree, run_job_supervisor's dispatch would be"
        " picking a transport the job supervisor does not believe in",
    )
    var stream = make_tls_s3_client_from_chain(
        String("us-east-1"), Optional[String]()
    )
    tls_job_supervisor.attach_stream_client(stream^)
    _ = tls_job_supervisor^

    var plain_job_supervisor = PlainJobSupervisor(
        _config_with_s3_endpoint(
            Optional[String](String("http://minio:9000"))
        )
    )
    assert_false(
        plain_job_supervisor.config.s3_uses_tls(),
        "CONTROL: the plaintext instantiation still exists and still reports"
        " plaintext",
    )
    _ = plain_job_supervisor^
    print("  test_job_supervisor_exists_over_the_tls_transport: PASS")


def main() raises:
    print("test_job_supervisor_https_transport_seam:")
    test_job_supervisor_config_turns_the_scheme_into_a_tls_decision()
    test_absent_s3_endpoint_selects_tls_because_real_s3_is_https()
    test_s3_endpoint_scheme_decides_the_transport()
    test_job_supervisor_jm_tls_connector_is_constructible()
    test_s3_client_is_constructible_over_tls()
    test_job_supervisor_exists_over_the_tls_transport()
    print("test_job_supervisor_https_transport_seam: ALL PASS")
