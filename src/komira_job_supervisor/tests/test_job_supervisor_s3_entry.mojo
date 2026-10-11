# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_s3_entry.mojo
#   The S3 entry point with no store, with stores the run never touches, and
#   with a binary store it cannot reach.
# =============================================================================
#
#   test_the_s3_entry_point_runs_without_stores
#       `run_job_supervisor_on_s3` with no bucket flag, through each
#       transport arm (no endpoint: TLS; an http:// endpoint: plain TCP),
#       runs the job to COMPLETED; nothing is fetched, written or dialled.
#       Which transport an endpoint gets is read from the wire in
#       test_s3_transport_first_byte.
#   test_the_s3_entry_point_builds_the_stores_it_is_given
#       A binary bucket with no --binary-key and an unreachable log bucket:
#       the stores are built (the credential chain's environment arm), the
#       job runs to COMPLETED, and the failed log write changes nothing. With
#       a --binary-key, the fetch goes to the binary bucket's store (a closed
#       loopback port): the run is refused before any beat or spawn.
#
# Every address is 127.0.0.1 or none: no store, no heartbeat endpoint and no
# credential provider is reached. One file: the S3 stack makes this binary
# large, and kcov's start-up on it, not the four runs, is most of its time.
# =============================================================================

from std.memory import ArcPointer
from std.os import setenv
from std.testing import assert_equal, assert_false, assert_true

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisorConfig,
    JobSupervisorPhase,
    S3StoreFlags,
    SupervisorHeartbeat,
    run_job_supervisor_on_s3,
)


struct Recorder(HeartbeatReporter):
    var beats: ArcPointer[List[String]]

    def __init__(out self, beats: ArcPointer[List[String]]):
        self.beats = beats

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        return HeartbeatOutcome(True, False, 200)


def _true_job(var name: String) -> JobSupervisorConfig:
    return JobSupervisorConfig(
        name^,
        String("instance-1"),
        String("/bin/true"),
        List[String](),
        String("http://127.0.0.1:1/beat"),
        heartbeat_interval_secs=1,
    )


def _no_bucket_flags(var endpoint: Optional[String]) -> S3StoreFlags:
    return S3StoreFlags(None, None, endpoint^, String("us-east-1"))


def test_the_s3_entry_point_runs_without_stores() raises:
    var tls_flags = _no_bucket_flags(None)
    assert_true(tls_flags.uses_tls())
    var beats = ArcPointer[List[String]](List[String]())
    var phase = run_job_supervisor_on_s3[Recorder](
        _true_job(String("s3-none-tls")), Recorder(beats), tls_flags
    )
    assert_true(phase == JobSupervisorPhase.completed(), "TLS arm: COMPLETED")
    assert_equal(beats[][len(beats[]) - 1], String("COMPLETED|"))

    var plain_flags = _no_bucket_flags(Optional[String](String("http://127.0.0.1:1")))
    assert_false(plain_flags.uses_tls())
    var pbeats = ArcPointer[List[String]](List[String]())
    var pphase = run_job_supervisor_on_s3[Recorder](
        _true_job(String("s3-none-plain")), Recorder(pbeats), plain_flags
    )
    assert_true(pphase == JobSupervisorPhase.completed(), "plain arm: COMPLETED")
    assert_equal(pbeats[][len(pbeats[]) - 1], String("COMPLETED|"))
    print("  test_the_s3_entry_point_runs_without_stores: PASS")


def test_the_s3_entry_point_builds_the_stores_it_is_given() raises:
    # Worthless static values for the default chain's environment arm.
    _ = setenv(String("AWS_ACCESS_KEY_ID"), String("AKIAIOSFODNN7EXAMPLE"), True)
    _ = setenv(
        String("AWS_SECRET_ACCESS_KEY"),
        String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        True,
    )
    # TLS: a binary bucket only, and no --binary-key: built, never used.
    var beats = ArcPointer[List[String]](List[String]())
    var phase = run_job_supervisor_on_s3[Recorder](
        _true_job(String("s3-bin-tls")),
        Recorder(beats),
        S3StoreFlags(Optional[String](String("bin")), None, None, String("us-east-1")),
    )
    assert_true(phase == JobSupervisorPhase.completed(), "TLS store: COMPLETED")

    # Plain: a log bucket on a closed loopback port: the write fails, the
    # result stands.
    var pbeats = ArcPointer[List[String]](List[String]())
    var pphase = run_job_supervisor_on_s3[Recorder](
        _true_job(String("s3-log-plain")),
        Recorder(pbeats),
        S3StoreFlags(
            None,
            Optional[String](String("logs")),
            Optional[String](String("http://127.0.0.1:1")),
            String("us-east-1"),
        ),
    )
    assert_true(pphase == JobSupervisorPhase.completed(), "plain store: COMPLETED")
    assert_equal(pbeats[][len(pbeats[]) - 1], String("COMPLETED|"))

    # A --binary-key: the fetch uses the binary bucket's store, which cannot
    # be reached, so the run is refused before its first beat.
    var fetch = _true_job(String("s3-fetch-plain"))
    fetch.binary_key = Optional[String](String("bin/job"))
    var fbeats = ArcPointer[List[String]](List[String]())
    var r = String("")
    try:
        _ = run_job_supervisor_on_s3[Recorder](
            fetch^,
            Recorder(fbeats),
            S3StoreFlags(
                Optional[String](String("bin")),
                None,
                Optional[String](String("http://127.0.0.1:1")),
                String("us-east-1"),
            ),
        )
    except e:
        r = String(e)
    assert_true(r.byte_length() > 0, "an unreachable binary store refuses the run")
    assert_false(r.find(String("no binary store")) >= 0, "the store was given: " + r)
    assert_equal(len(fbeats[]), 0, "refused before the first beat")
    print("  test_the_s3_entry_point_builds_the_stores_it_is_given: PASS")


def main() raises:
    print("test_job_supervisor_s3_entry:")
    test_the_s3_entry_point_runs_without_stores()
    test_the_s3_entry_point_builds_the_stores_it_is_given()
    print("test_job_supervisor_s3_entry: ALL PASS")
