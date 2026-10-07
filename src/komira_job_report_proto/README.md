# `komira_job_report_proto`

## Responsibility

The job report wire (`komira.job_report.v1`), as protobuf messages and the
Mojo structs generated from them. A supervised job's sender reports the job's
phase while it runs and once more when it ends; the receiver answers each
report with CONTINUE or CANCEL. A receiver depends on this package and its codec, `komira_proto_codec`, not on the supervisor that produces the reports.

- `JobPhase`: `JOB_PHASE_UNSPECIFIED` (never sent), `JOB_PHASE_RUNNING`,
  `JOB_PHASE_COMPLETED`, `JOB_PHASE_FAILED`, `JOB_PHASE_CANCELLED`.
- `JobDirective`: `JOB_DIRECTIVE_CONTINUE` (the zero value, so an empty reply
  means CONTINUE) and `JOB_DIRECTIVE_CANCEL`.
- `JobHeartbeat`: one report: job id, phase, instance name, optional progress
  and message, and a `JobFailure` when the phase is FAILED.
- `JobHeartbeatReply`: the reply, one `JobDirective`.
- `JobFailure`: exit code or signal, the tail of stderr, a panic line.

The file imports no other `.proto`. Field and enum numbers are the contract;
the welded tests pin them as exact wire bytes. Proto3 enums are open: an enum
number this build does not know decodes to that number.

## API

The definitions are in
[job_report.proto](https://github.com/komira-ai/komira/blob/main/src/komira_job_report_proto/job_report.proto);
the Mojo module is `komira_job_report_proto.job_report`. Each message is a
struct whose constructor takes its fields in declaration order (a proto3
`optional` field or a message field is an `Optional`, a `repeated` field a
`List`); an enum is a struct over its number (`.value`), with one constant per
value. Encode and decode with `komira_proto_codec`'s `encode_proto` and
`decode_proto`.

## Examples

Every example below runs as a test when the package is built.

A running job's report survives encode and decode:

```mojo
from komira_job_report_proto.job_report import JobHeartbeat, JobPhase
from komira_proto_codec import decode_proto, encode_proto
from std.testing import assert_equal, assert_false

var beat = JobHeartbeat(
    String("job-0001"),  # job_id
    JobPhase(JobPhase.JOB_PHASE_RUNNING),  # phase
    String("worker-a"),  # instance_name
    Optional[UInt32](UInt32(50)),  # progress
    Optional[String](String("halfway")),  # message
    None,  # failure: set only when the phase is FAILED
)
var got = decode_proto[JobHeartbeat](encode_proto[JobHeartbeat](beat))
assert_equal(got.job_id, String("job-0001"))
assert_equal(got.phase.value, JobPhase.JOB_PHASE_RUNNING)
assert_equal(got.progress.value(), UInt32(50))
assert_equal(got.message.value(), String("halfway"))
assert_false(Bool(got.failure))
```

A failed job says why:

```mojo
from komira_job_report_proto.job_report import JobFailure, JobHeartbeat, JobPhase
from komira_proto_codec import decode_proto, encode_proto
from std.testing import assert_equal, assert_false

var tail = List[String]()
tail.append(String("thread panicked: index out of range"))
var failure = JobFailure(
    Optional[Int32](Int32(101)),  # exit_code
    None,  # signal: the job exited, no signal killed it
    tail^,  # stderr_tail
    Optional[String](String("index out of range")),  # panic_message
)
var beat = JobHeartbeat(
    String("job-0002"),
    JobPhase(JobPhase.JOB_PHASE_FAILED),
    String(""),
    None,
    None,
    Optional[JobFailure](failure^),
)
var got = decode_proto[JobHeartbeat](encode_proto[JobHeartbeat](beat))
assert_equal(got.phase.value, JobPhase.JOB_PHASE_FAILED)
ref report = got.failure.value()
assert_equal(report.exit_code.value(), Int32(101))
assert_false(Bool(report.signal))
assert_equal(report.stderr_tail[0], String("thread panicked: index out of range"))
```

Only an explicit CANCEL stops a job: an empty reply decodes to CONTINUE, and
CANCEL is on the wire as field 1, varint 1:

```mojo
from komira_job_report_proto.job_report import JobDirective, JobHeartbeatReply
from komira_proto_codec import decode_proto, encode_proto
from std.testing import assert_equal

var empty = decode_proto[JobHeartbeatReply](List[UInt8]())
assert_equal(empty.directive.value, JobDirective.JOB_DIRECTIVE_CONTINUE)

var cancel = JobHeartbeatReply(JobDirective(JobDirective.JOB_DIRECTIVE_CANCEL))
var bytes = encode_proto[JobHeartbeatReply](cancel)
assert_equal(len(bytes), 2)
assert_equal(bytes[0], UInt8(0x08))
assert_equal(bytes[1], UInt8(0x01))
assert_equal(
    decode_proto[JobHeartbeatReply](bytes^).directive.value,
    JobDirective.JOB_DIRECTIVE_CANCEL,
)
```
