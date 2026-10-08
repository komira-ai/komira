# komira_job_supervisor

A generic job supervisor. It runs one job (a local binary, or one fetched from
an object store), sends a heartbeat with the
job's phase while it runs, stops the job when a heartbeat reply asks it to
cancel, and when the job exits classifies the result (COMPLETED, FAILED or
CANCELLED). With a log store it streams the job's output there in chunks as it
runs, and at the end writes `logs.txt` and, for a FAILED job, a
`crash_report.json` with the exit code or signal and the last lines of stderr.

The embedding binary supplies:

- the configuration, `JobSupervisorConfig.from_args` (command-line flags; no
  environment variable is read);
- a `HeartbeatReporter`, where heartbeats go. `HttpHeartbeatReporter[A]`
  sends one HTTP POST per beat to `--heartbeat-url` (the
  `komira.job_report.v1` protobuf messages), authenticated by a
  `HeartbeatAuth` conformer `A` (`NoHeartbeatAuth` ships);
- optionally, a binary store and a log store: any komira_objectstore
  `ConditionalWriteStore`. `make_s3_store` and `run_job_supervisor_on_s3`
  build S3 or S3-compatible ones from flags.

A fetched binary is checked against a SHA-256 digest only when one is known:
the `--binary-sha256` flag when given, otherwise the first segment of the
object key that is 64 lowercase hex characters (a content-addressed layout
such as `<sha256>/binary`). A key with neither is fetched and run
unverified; pass `--binary-sha256` when the key does not carry the digest.

Process handling (pipes, pids, signals) is komira_supervisor's. A job is
stopped by signalling its pid, not its process group, so a child the job
spawns itself is not signalled.

## Examples

Flags in, a checked configuration out:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_job_supervisor import JobSupervisorConfig

var args: List[String] = [
    "--job-name=nightly-report",
    "--job-binary=/opt/job/run",
    "--heartbeat-url=https://heartbeat.example.com/beat",
    "--job-arg=--date",
    "--job-arg=2026-10-04",
    "--heartbeat-interval-secs=15",
]
var c = JobSupervisorConfig.from_args(args)
assert_equal(c.job_name, "nightly-report")
assert_equal(len(c.job_argv), 2)
assert_equal(c.heartbeat_interval_secs, 15)
assert_false(c.uses_binary_store())        # no --binary-key: run the local binary
assert_equal(c.log_prefix, "nightly-report")  # the default prefix is the job name

var missing: List[String] = ["--job-binary=/opt/job/run", "--heartbeat-url=https://heartbeat.example.com/beat"]
var message = String()
try:
    _ = JobSupervisorConfig.from_args(missing)
except e:
    message = String(e)
assert_true("--job-name" in message)
```

Run a short job to its end, with a reporter that records each heartbeat's
phase and an in-memory log store:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_job_supervisor import HeartbeatOutcome, HeartbeatReporter, JobSupervisorConfig
from komira_job_supervisor import JobSupervisorPhase, SupervisorHeartbeat, run_job_supervisor
from komira_objectstore import Path, SharedInMemoryConditionalStore

struct RecordingReporter(HeartbeatReporter):
    var phases: ArcPointer[List[String]]

    def __init__(out self, phases: ArcPointer[List[String]]):
        self.phases = phases

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        self.phases[].append(String(hb.phase.wire_str()))
        return HeartbeatOutcome(True, False, 200)  # delivered, no cancel

def text_of(store: SharedInMemoryConditionalStore, key: String) raises -> String:
    return String(unsafe_from_utf8=Span(store.get(Path.parse(key))))

var job_argv: List[String] = ["-c", "echo working; echo done; exit 0"]
var config = JobSupervisorConfig(
    "readme-job", "instance-1", "/bin/sh", job_argv^,
    "https://heartbeat.example.com/beat", log_prefix="logs/readme-job",
)
var phases = ArcPointer[List[String]](List[String]())
var logs = SharedInMemoryConditionalStore()
var reader = logs.clone()  # a clone shares the objects
var phase = run_job_supervisor[RecordingReporter, SharedInMemoryConditionalStore](
    config^, RecordingReporter(phases), None, Optional(logs^)
)
assert_true(phase == JobSupervisorPhase.completed())
assert_equal(phases[][0], "RUNNING")
assert_equal(phases[][len(phases[]) - 1], "COMPLETED")
assert_true("working\ndone" in text_of(reader, "logs/readme-job/logs.txt"))
```

A job that exits non-zero is FAILED, and its crash report is written next to
its logs (`RecordingReporter` and `text_of` are the ones declared above):

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from std.memory import ArcPointer
from komira_job_supervisor import JobSupervisorConfig, JobSupervisorPhase, run_job_supervisor
from komira_objectstore import SharedInMemoryConditionalStore

var job_argv: List[String] = ["-c", "echo boom >&2; exit 3"]
var config = JobSupervisorConfig(
    "failing-job", "instance-1", "/bin/sh", job_argv^,
    "https://heartbeat.example.com/beat", log_prefix="logs/failing-job",
)
var logs = SharedInMemoryConditionalStore()
var reader = logs.clone()
var phase = run_job_supervisor[RecordingReporter, SharedInMemoryConditionalStore](
    config^, RecordingReporter(ArcPointer[List[String]](List[String]())), None, Optional(logs^)
)
assert_true(phase == JobSupervisorPhase.failed())
var report = text_of(reader, "logs/failing-job/crash_report.json")
assert_true('"exit_code":3' in report)
assert_true("boom" in report)
```
