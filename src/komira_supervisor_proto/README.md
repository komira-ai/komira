# `komira_supervisor_proto`

## Responsibility

The wire contract between a job supervisor (or a broker node running
beside one) and the coordinator it reports to, as protobuf messages
(`komira.supervisor.v1`) and the Mojo structs generated from them:

- `JobPhase`: the job phase vocabulary (`JOB_PHASE_PENDING` ...
  `JOB_PHASE_SUPERVISOR_ABSENT`). Values are only ever appended; the
  correspondence with any store that keeps a phase as text is by name.
- `SupervisorHeartbeat`: what a supervisor sends on every beat: the job, its
  phase, progress, an optional `FailureReport`, and, for a broker node, its
  identity, load, the partitions it serves now and its reachable endpoint.
- `HeartbeatResponse`: the reply: whether to cancel, and, for a broker node,
  the partitions it should serve (each with its lease generation), the
  cluster shape and the cluster-wide routing map.
- `FailureReport`: exit code, signal, the tail of stderr, a panic message.

Every multi-node field is additive: a plain job supervisor leaves them unset
or empty, and its heartbeat is the job-only one. The routing types the
multi-node fields carry (`NodeLoad`, `ClusterConfig`, `BrokerClusterMap`)
are `komira_broker_proto`'s; this file imports that one, never the reverse.
The field and enum numbers are the contract:
`tests/test_supervisor_field_numbers.mojo` pins every one of them as wire
bytes.

## API

| name | file | what it is |
|---|---|---|
| `JobPhase` | [supervisor.proto](https://github.com/komira-ai/komira/blob/main/src/komira_supervisor_proto/komira/supervisor/v1/supervisor.proto) | the phase enum |
| `SupervisorHeartbeat`, `HeartbeatResponse` | [supervisor.proto](https://github.com/komira-ai/komira/blob/main/src/komira_supervisor_proto/komira/supervisor/v1/supervisor.proto) | one beat and its reply |
| `FailureReport` | [supervisor.proto](https://github.com/komira-ai/komira/blob/main/src/komira_supervisor_proto/komira/supervisor/v1/supervisor.proto) | why a job failed |

The Mojo module is `komira_supervisor_proto.supervisor`. Each message is a
struct whose constructor takes its fields in declaration order (a proto3
`optional` field or a message field is an `Optional`, a `repeated` field a
`List`); an enum is a struct over its number, with one constant per value.
The structs conform to `komira_proto_codec`'s `Serializable`.

The generated module's `# Mojo package:` header line names
`komira_broker_proto`: the generator writes a reference to the imported
broker types as `komira_broker_proto.broker`, so the heartbeat shares those
types instead of carrying a second copy of them. Import from
`komira_supervisor_proto.supervisor` as usual.

## Example

Every example below runs as a test when the package is built.

A plain job supervisor's heartbeat, and the reply that cancels it:

```mojo
from komira_supervisor_proto.supervisor import HeartbeatResponse, JobPhase, SupervisorHeartbeat
from komira_proto_codec import decode_proto, encode_proto
from std.testing import assert_equal, assert_false, assert_true

var beat = SupervisorHeartbeat(
    String("job-0001"),  # job_id
    JobPhase(JobPhase.JOB_PHASE_RUNNING),  # phase
    String("worker-a"),  # pod_name
    Optional[UInt32](UInt32(50)),  # progress
    None,  # message
    None,  # failure
    None,  # node_id: the multi-node fields stay unset for a plain job
    None,  # load
    List[UInt32](),  # owned_partitions
    None,  # advertised_host
    None,  # advertised_port
)
var got = decode_proto[SupervisorHeartbeat](encode_proto(beat))
assert_equal(got.phase.json_name(), "JOB_PHASE_RUNNING")
assert_equal(got.progress.value(), UInt32(50))
assert_false(Bool(got.node_id))

var reply = HeartbeatResponse(True, List[UInt32](), None, None, List[Int64]())
assert_true(decode_proto[HeartbeatResponse](encode_proto(reply)).cancel)
```

A failed job reports why:

```mojo
from komira_supervisor_proto.supervisor import FailureReport, JobPhase
from komira_proto_codec import decode_proto, encode_proto
from std.testing import assert_equal

var tail = List[String]()
tail.append(String("thread panicked: index out of range"))
var failure = FailureReport(
    Optional[Int32](Int32(101)),  # exit_code
    None,  # signal
    tail^,  # stderr_tail
    None,  # panic_message
    Optional[String](String("exited with code 101")),  # reason
    None,  # last_record_offset
)
var report = decode_proto[FailureReport](encode_proto(failure))
assert_equal(report.exit_code.value(), Int32(101))
assert_equal(report.stderr_tail[0], "thread panicked: index out of range")
assert_equal(JobPhase(JobPhase.JOB_PHASE_FAILED).json_name(), "JOB_PHASE_FAILED")
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_supervisor_proto`, version 0.1.0
(`mopm.toml`). Its library is the generator's output, committed at `generated/komira_supervisor_proto_generated/` and
compiled as the module `komira_supervisor_proto` (`[targets] lib` of `mopm.toml`); its tests are `tests/`. It depends on 2 sibling packages, `komira_broker_proto`, `komira_proto_codec` (each `{ path = "../<name>", version = "0.1" }`), so the `.conda` of this package records `mojo-<name> >=0.1,<0.2` for each as its dependencies
and holds none of their files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, direct and transitive (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

The `.proto` files are the inputs of the generator. `komira_supervisor_proto_generated_gen` writes the Mojo for them,
`komira_supervisor_proto_generated_fresh` compares it with the committed directory and fails when they differ, and
`:lib` is built only after that check has passed. Regenerate with
`./buck2 run komira//tools/build/gen:regen -- komira//src/komira_supervisor_proto:komira_supervisor_proto_generated`.
`mojo_package` does not run that check itself, so the gate is a target beside it (`BUCK`).

After any change to a `.proto` file, a test, or a manifest of this package or of a sibling, regenerate, run
`buildrules mojo sync` with the packages staged, commit what it writes, and build `komira//src/komira_supervisor_proto:lib`
on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`, packed with the manifests of the path dependencies beside its own
(`members`); `:conda_holds` reads it back and fails when the dependencies are not exactly the ones above.
`:komira_supervisor_proto` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from.
It also compiles and runs the README's examples (`[tests][readme]`) against `:lib`.
