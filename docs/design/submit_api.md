# Submitting a plan to a job manager: the public side

Status: design, not built. **EXISTS** names code on `main`; **PROPOSED** is new. Statements the author deduced
rather than read are marked *(inferred)*. Nothing was built or run to write this document.

Scope: what a komira SDK sends to a job manager and what it gets back, as a protocol any job manager can implement,
and the Python calls over it. It does not design a job manager: how one stores runs, places them, bills them, issues
tokens or keeps secrets is its own business. komira ships one job manager only, the in-process stand-in its tests
use ([How is it tested?](#how-is-it-tested)).

A **job manager** here is the scheduler of [optimized_plan.md §2](optimized_plan.md#2-roles) together with the
service a client talks to: it accepts a plan, places it by its header and reports on it. The coordinator (which
verifies `plan_digest` and cuts the plan) and the run's committer run behind it, on the hosts it places the plan on;
they are roles of the plan's design, not parties to this protocol.

## What a user types

```python
import komira

jm = komira.JobManager("https://jobs.example.com", token=token)

s = komira.Session()
s.add_sql_binding("orders", komira.files(
    "s3://raw-events/orders/*.parquet",
    credential=komira.AwsKeys("raw-etl", key_id=key_id, secret=secret),
    region="eu-west-1",
))

run = s.submit("SELECT region, sum(amount) AS total FROM orders GROUP BY region", job_manager=jm)
print(run.id, run.state)          # "QUEUED", then "RUNNING", ...
table = run.result().to_arrow()   # waits for the run to finish, then reads its rows
```

- `Session.submit` parses, binds and optimizes on the user's machine, exactly as `Session.sql` does, and sends the
  optimized plan. The SQL text never leaves the process.
- The run lives on the job manager. Closing the session, ending the process or pressing Ctrl-C while waiting does
  not cancel it; `run.cancel()` does.
- Another process attaches to the same run by its id: `jm.run(run_id)`.
- The credential `raw-etl` travels as its name only. The job manager resolves that name from its own secret store
  ([credentials_and_writes.md](credentials_and_writes.md#5-who-binds-credential-names-to-values), decision 5); the
  key pair given to `AwsKeys` stays in the process, where the optimizer uses it to read Parquet footers.

## What problem does this solve?

[optimized_plan.md](optimized_plan.md#2-roles) fixes **what** a client submits: one `OptimizedPlan`, optimized once
by the SDK, which a scheduler places by its header and never decodes. It says nothing about **how** it is submitted:
"authenticating the submitter is the transport's job" (its §7.1), and no document defines the request, the answer, a run
id, a run's state, cancellation or how the rows come back. The TypeScript design lists "remote jobs" as later for the
same reason ([typescript_package.md](typescript_package.md), "Explicitly later"), and
[credentials_and_writes.md](credentials_and_writes.md) leaves "the export call" to this milestone.

Every SDK needs the same answer, and so does anyone who writes a job manager, so it is a protocol with a published
schema rather than a Python API alone. The earlier tree had no client that submitted a plan: its SDK was local
only, and its job API took a binary and a map of strings, not a plan. Nothing is ported here; the lessons kept from
it are in [Options considered](#options-considered).

## What exists today

- **EXISTS** `komira.plan.v1.OptimizedPlan` (`src/plan_proto/optimized_plan.proto`), the header library
  (`src/optimized_plan_header`: `admit_optimized_plan_header`, `check_optimized_plan_contract`,
  `admit_plan_environment`) and the producer and admission (`src/optimized_plan`: `produce_optimized_plan`,
  `admit_optimized_plan`), for format version 1 with a body of `plan` only.
- **EXISTS** the refusal tokens of [optimized_plan.md §7.2](optimized_plan.md#72-admission-order-and-refusal-tokens),
  permanent by name.
- **EXISTS** `PlanEnvironment { image_digest, image_manifest }` as a Mojo struct in the header library and as text in
  [optimized_plan_udf_runtime.md §10.11](optimized_plan_udf_runtime.md#1011-the-environment-image-and-the-engine-age-rule);
  it is in no `.proto` file.
- **EXISTS** a Mojo gRPC and Connect client and server (`src/grpc`, `src/connect`) and the generator that writes a
  typed client from a `service` ([protobuf_grpc_and_codegen.md](protobuf_grpc_and_codegen.md)).
- **EXISTS** in the Python package: `Session`, `Result` (one read, five terminals), `KomiraError` with `status`,
  `code` and `step`, and the class table of [python_package.md decision 9](python_package.md#9-errors). The wheel
  requires `pyarrow` and `protobuf` and nothing else.
- **Missing**: `DeclaredNeeds.credentials`, the sorted credential names a plan reads, is **PROPOSED** by
  [credentials_and_writes.md](credentials_and_writes.md#4-the-plan-a-location-and-a-credential-name-never-a-value)
  and only held in `optimized_plan.proto` (a `held:` comment at number 8; optimized_plan.md §7.1 writes 11, a
  mismatch for that field's own pull request to settle). The binding surface of the opening example
  (`Session.add_sql_binding`, `komira.files`, `komira.AwsKeys`) is that document's too, and private until it lands.
- **Missing**: no libkomira call returns `OptimizedPlan` bytes. `komira_plan_stream` takes a `WirePlanEnvelope`
  and refuses an `OptimizedPlan` by name, and no entry calls `produce_optimized_plan`
  ([libkomira_run_abi.md](libkomira_run_abi.md)). komira has no optimizer driver yet
  ([optimized_plan.md §12](optimized_plan.md#12-implementation-plan), critical path).

## The decisions

### 1. A run is the unit; the protocol has four calls

A submission creates a **run**: one execution of one `OptimizedPlan`. The word is the one the plan designs already
use ("the run's identity", "the run record"). The protocol is one service:

| call | what it does |
|---|---|
| `SubmitRun` | sends a plan (and, with UDFs, its environment image) and answers the new run, or a refusal |
| `GetRun` | answers a run's state; it can wait for the next change (long poll) |
| `CancelRun` | asks the run to stop; idempotent |
| `ReadRunResult` | streams a finished run's rows as one Arrow IPC stream |

There is no call to list runs, rename them, attach labels or read logs. Each is additive later, and none is needed
to submit a plan and get its answer. A job manager may offer them on its own API.

### 2. The schema: `komira.run.v1`

**PROPOSED** `src/run_proto/run_service.proto`, package `komira.run.v1`, importing
`komira/plan/v1/optimized_plan.proto`. `PlanEnvironment` moves from text into `optimized_plan.proto` (package
`komira.plan.v1`, unchanged fields) in the same pull request, because it belongs to the plan's admission and a host
reads it too.

```proto
service RunService {
  rpc SubmitRun(SubmitRunRequest) returns (SubmitRunResponse);
  rpc GetRun(GetRunRequest) returns (Run);
  rpc CancelRun(CancelRunRequest) returns (Run);
  rpc ReadRunResult(ReadRunResultRequest) returns (stream ResultChunk);
}

message SubmitRunRequest {
  bytes                          optimized_plan   = 1;  // an OptimizedPlan, byte for byte as the producer wrote it
  komira.plan.v1.PlanEnvironment environment      = 2;  // set iff the plan's needs.runtimes is not empty
  string                         image_repository = 3;  // OCI repository holding environment; set iff 2 is set
  string                         request_id       = 4;  // required; the client's idempotency key (decision 5)
}

message SubmitRunResponse {
  Run  run          = 1;
  bool deduplicated = 2;  // true: request_id was seen with the same request (decision 5); run is that earlier run
}

message GetRunRequest {
  string run_id         = 1;
  uint64 after_revision = 2;  // answer once run.revision > after_revision, or when wait_millis elapses
  uint32 wait_millis    = 3;  // 0: answer now; a job manager caps it (decision 6)
}

message CancelRunRequest     { string run_id = 1; }
message ReadRunResultRequest { string run_id = 1; }

message Run {
  string      run_id      = 1;  // opaque, 1-128 bytes of printable ASCII; the SDK never parses it
  RunState    state       = 2;
  uint64      revision    = 3;  // 1 for a new run; grows on every change a client can see
  bytes       plan_digest = 4;  // copied from the plan's header
  string      request_id  = 5;
  RunError    error       = 6;  // set iff state is FAILED, or CANCELLED for a reason other than CancelRun
  RunProgress progress    = 7;  // optional; absent means unknown
  uint64      result_expires_unix_ms = 8;  // with SUCCEEDED: when the result may stop being readable; 0: unknown
}

enum RunState {
  RUN_STATE_UNSPECIFIED = 0;
  RUN_STATE_QUEUED      = 1;  // accepted, not started
  RUN_STATE_RUNNING     = 2;
  RUN_STATE_SUCCEEDED   = 3;  // terminal; the result can be read (decision 7)
  RUN_STATE_FAILED      = 4;  // terminal; error is set
  RUN_STATE_CANCELLED   = 5;  // terminal
}

message RunProgress {
  uint64 segments_done  = 1;
  uint64 segments_total = 2;  // 0: not known yet
}

// A refusal or a failure, from the job manager or from a host.
message RunError {
  string          code    = 1;  // a named code, UPPER_SNAKE: OPTIMIZED_*, CREDENTIAL_*, RUN_*, an engine code
  string          step    = 2;  // "lower" or "execute" from a host while running; empty for a refusal
  string          message = 3;  // the "<CODE>: ..." text; never a secret (decision 8)
  repeated uint32 accepted_format_versions   = 4;  // with OPTIMIZED_PLAN_VERSION_UNSUPPORTED
  repeated uint32 accepted_contract_versions = 5;  // with OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED
  string          oldest_accepting_base      = 6;  // with OPTIMIZED_ENV_ENGINE_TOO_OLD
}

message ResultChunk {
  bytes arrow_ipc = 1;  // the chunks, in order, concatenate to one Arrow IPC stream; an encoded ResultChunk is
                        // at most 4 MiB (4,194,304 bytes), so arrow_ipc is a few bytes less
}
```

- **The plan is `bytes`, not an `OptimizedPlan` field.** The digest and the canonical check are over the bytes the
  producer wrote ([optimized_plan.md §7.1](optimized_plan.md#71-canonical-form-and-the-digest)). A generic
  protobuf library that decodes and re-encodes the header may reorder or drop what it does not know, so the request
  carries the producer's bytes untouched and the job manager reads the header through the header library or its own
  decoder of those bytes.
- **The plan is the contract; the request is transport.** Everything that changes what a run computes or may touch
  (its sources, write target, credential names, code digests, versions) is inside the plan and under its digest. No
  request field changes what a run computes. That is why an unknown request field may be ignored (decision 10) while
  an unknown plan field is refused.
- **The image is named, not uploaded.** `PlanEnvironment` carries the manifest's digest and bytes; the job
  manager's checks 1-3 of §10.11 need nothing else. The layers are pulled by the hosts from `image_repository` by
  digest (`<image_repository>@<image_digest>`), by the
  [OCI distribution specification](https://github.com/opencontainers/distribution-spec). Pushing the image there is
  the image builder's step, before submit; this protocol has no blob upload. A plan without UDFs sends neither field
  and runs on a released base.
- **A repository is a location the job manager checks, not free text.** The digest proves the content, not where a
  host connects or which registry credentials it presents. A job manager pulls only from repositories its own policy
  allows for the caller, presents registry credentials only to the registry they belong to, and refuses any other
  repository at `SubmitRun` with `RUN_IMAGE_REPOSITORY_REFUSED`, creating no run (decision 11).
- **One error type for both moments.** A refusal at `SubmitRun` and a failure found later on a host are the same
  `RunError`, so an SDK maps a code to the same exception whichever moment found it (decision 8).

### 3. The transport: Connect over HTTPS, gRPC on the same paths

A job manager serves `RunService` by the [Connect protocol](https://connectrpc.com/docs/protocol/) with protobuf
bodies (`application/proto`), at `POST <base URL>/komira.run.v1.RunService/<Method>`. It may serve gRPC on the same
paths as well; Connect servers commonly do both. JSON bodies are not required of a job manager.

- **Why Connect.** A unary Connect call is a plain HTTP POST with a bare protobuf body, and a server stream is
  HTTP/1.1 chunked with 5-byte envelopes. The Python package makes both with the standard library's `http.client`
  and the `protobuf` it already requires: **no new dependency**. Node's `fetch` does the same for the TypeScript
  package. The Mojo SDK uses the client the generator already writes over `src/grpc` (`ProtocolConnectProto`).
- **Message size.** Two limits, checked by the SDK before sending. The plan bytes are at most the header library's
  `OPTIMIZED_PLAN_MAX_BYTES` (the 16 MiB plan budget plus the 1 MiB header allowance), refused with that library's
  `OPTIMIZED_PLAN_LIMIT_EXCEEDED`. The manifest is at most 4 MiB, the limit the OCI specification sets for a
  manifest, a value this design chooses and no code holds yet, refused with `RUN_ENVIRONMENT_TOO_LARGE`. A job
  manager therefore accepts a `SubmitRun` request of about 21 MiB; that is its own server's setting. An encoded
  `ResultChunk` is at most 4 MiB, which equals the receive limit the Mojo client has today
  (`MAX_RECV_MESSAGE_SIZE`, EXISTS, receive side only). The Mojo client has no per-call message limit, so a Mojo
  `SubmitRun` larger than that needs one (**PROPOSED**, in `src/grpc`, with the Mojo client of
  [What lands when](#what-lands-when)).
- **Wire rules**, so an implementer does not guess: unary calls are `Content-Type: application/proto`, and
  `ReadRunResult` is `application/connect+proto` with 5-byte envelopes; every request carries
  `Connect-Protocol-Version: 1`; the SDK sends no `Connect-Content-Encoding`, accepts `identity` only, and a job
  manager compresses nothing unless the client advertises it; an error before the first byte of an answer is an
  ordinary Connect error response, and an error after a stream began arrives in its end-stream envelope (flags
  `0x02`), never as a later HTTP status; the SDK sends `Connect-Timeout-Ms` on every call, and on `GetRun` it is the
  long poll's bound plus a margin (decision 6).
- **TLS.** The base URL is `https://`. `http://` is refused (`JOB_MANAGER_URL_REFUSED`) unless its host is a
  literal loopback address (`127.0.0.1` to `127.255.255.254`, or `[::1]`), which the stand-in and a job manager on
  the same machine use. The name `localhost` is not enough: a name is resolved, and need not be loopback. Trust
  roots are the system's, or a `ca_file=` keyword, the one
  [credentials_and_writes.md decision 9](credentials_and_writes.md#9-https-reads) proposes for `Session` (**PROPOSED**,
  not built); the two share one trust-root helper.
- **No redirects.** An SDK never follows a redirect on a `RunService` call: Python's `http.client` does not, and the
  TypeScript client sets `redirect: "error"`. A 3xx answer raises `JOB_MANAGER_PROTOCOL`. The token, and the token
  callable, are used only for the base URL's origin.
- **Authentication is the transport's.** The SDK sends `Authorization: Bearer <token>` when given a token, and
  nothing else identifies the caller. What a token is, who issues it and how it is verified are the job manager's.
  The protocol fixes one rule every job manager must keep: **every call is scoped to the caller**, and a run the
  caller may not see answers exactly as a run that does not exist (`RUN_NOT_FOUND`). An earlier job API addressed
  runs by id alone, and any caller could read or cancel any run by guessing; this rule is the lesson.

### 4. The Python surface

**PROPOSED**, all keyword arguments as in the rest of the package, none read from the environment (rule S2):

| name | what it is |
|---|---|
| `JobManager(url, *, token=None, ca_file=None, timeout=60.0)` | where runs go: a base URL and how to authenticate. `token` is a `str`, or a callable taking no argument and returning a `str`, called before every request so a short-lived token can be refreshed. `timeout` bounds one HTTP request in seconds, never a run. It opens no connection until a call needs one; it holds no secret beyond the token it was given, and `repr()` never shows the token |
| `JobManager.run(run_id) -> Run` | attaches to an existing run, from any process; a run the caller cannot see raises `RunError` with `RUN_NOT_FOUND` |
| `Session.submit(query, *, job_manager, request_id=None) -> Run` | parses, binds and optimizes `query` over the session's bindings, as `sql` does, exports the optimized plan (decision 9) and calls `SubmitRun`. It returns once the job manager has accepted the run. `request_id` defaults to a new random id per call |
| `DataFrame.submit(*, job_manager, request_id=None) -> Run` | the same for a frame's plan, when the plan door can optimize a frame's plan |
| `Run.id`, `Run.state`, `Run.error` | the run's id; its state as last seen: `"QUEUED"`, `"RUNNING"`, `"SUCCEEDED"`, `"FAILED"`, `"CANCELLED"`, or the name of a state this package does not know; and the run's `RunError` as an exception of its class (decision 8) when the job manager sent one, else `None` (a run cancelled by `cancel()` has none, and `result()` raises `RunCancelledError` with `RUN_CANCELLED` for it) |
| `Run.refresh() -> str` | calls `GetRun` now and returns the state |
| `Run.wait(timeout=None) -> str` | waits with long polls until the state is terminal, and returns it; `timeout` in seconds, `None` for no bound. It raises `TimeoutError` when the bound passes first; the run continues |
| `Run.result(timeout=None) -> Result` | waits as `wait(timeout)` does (the bound is on the wait, not on reading the rows), then opens `ReadRunResult` and returns a `Result`, the same type `sql` returns, with the same five terminals and the same one-read rule. Calling `result()` again opens the stream again, while the job manager keeps it. A run that did not succeed raises its error instead (decision 8) |
| `Run.cancel() -> str` | calls `CancelRun` and returns the state it answers. Cancelling a finished run changes nothing and is not an error |
| `JobManagerError`, `RunError`, `RunCancelledError` | the three new exception classes of decision 8 |

Behaviour the implementing pull requests keep:

- **`submit` fails early, as `sql` does.** A syntax error, an unknown name, a refusal at binding or optimizing, an
  export refusal (decision 9) and every refusal the job manager makes at `SubmitRun` raise from `submit` itself. A
  failure found later on a host raises from `result()`. `wait()` does not raise it: it returns the terminal state,
  and `Run.error` holds the failure as a `RunError` for a caller that only waits.
- **Waiting is not owning.** Ctrl-C, or an exception from a `progress` callback, while `wait()` or `result()` waits,
  stops the wait and is raised again; it does not cancel the run, which the job manager owns. This differs from
  `Session.sql`, where Ctrl-C cancels, because a local run dies with its process and a remote one does not.
- **Progress.** `wait()` and `result()` take `progress=None`, a callable called on the calling thread with
  `(segments_done, segments_total)` when `GetRun` answers a change, as `sql`'s `progress` is.
- **Retries.** `SubmitRun` is retried on a connection failure or the Connect codes `unavailable` and
  `deadline_exceeded`, with the same `request_id`, so a retry makes no second run (decision 5). `GetRun`,
  `CancelRun` and `ReadRunResult` before its first chunk are retried on the same failures. Each call makes at most
  three attempts, waiting between them on an injected clock, never on wall time in tests. Nothing else is retried; a
  stream that breaks after its first chunk raises from the terminal that reads it.
- **Threads and fork.** A `JobManager` and a `Run` may be used from several threads; a `Run` serializes its own
  calls. After `os.fork` the child may keep using them: they hold no engine context, only a URL and a token.
- **The session is not needed after submit.** A `Run` refers to its `JobManager`, never to the session, so closing
  the session leaves every run and its `result()` usable.

### 5. Idempotency: `request_id`

`request_id` is required, 1-128 bytes of letters, digits, `-` and `_`. The SDK makes a new random one per `submit`
call unless the caller gives one; a caller that wants "submit at most once" across its own restarts passes a stable
one.

- **The same request** is the same `plan_digest`, the same `environment.image_digest` (or none) and the same
  `image_repository` (or none). The same caller sending the same `request_id` with the same request gets the
  earlier run, whatever its state, with `deduplicated = true`. A caller that wants to run a failed or cancelled
  plan again sends a new `request_id`.
- The same `request_id` with a different request is refused with `RUN_REQUEST_ID_REUSED`. A silent second run and a
  silent first run would each be a different answer from the one asked for.
- **Lookup and create are one atomic step** per caller and `request_id`, so two concurrent `SubmitRun`s with one id
  (a retry racing a slow first attempt, the case the retries of decision 4 create) make one run.
- **The window.** A job manager keeps a `request_id` for at least 24 hours after the run it names was created, and
  never forgets it while it still keeps that run. After that a retry may create a new run; the SDK's own retries
  span seconds, far inside it.
- `request_id` is scoped to the caller, as runs are: two callers' equal ids are unrelated.

### 6. Run states and waiting

- **The terminal states are closed forever**: `SUCCEEDED`, `FAILED`, `CANCELLED`. A later version may add states,
  and every added state is non-terminal. An SDK reading a state it does not know reports its name and keeps
  waiting. This is what lets a job manager add a state (a `PAUSED`, a `RETRYING`) without breaking an installed SDK,
  and what keeps an old SDK from waiting forever on a run that finished.
- `CANCELLED` is reached by `CancelRun`, or by the job manager's own decision (for example a deadline it enforces),
  in which case `error` says why.
- A terminal state is final. Before it, a run may move between non-terminal states in any order (a job manager may
  put a `RUNNING` run back to `QUEUED` after losing a host), so a client never infers anything from the order of
  non-terminal states. `revision` starts at 1 and grows with every change; a change of `progress` is a change, and
  a job manager may fold several progress changes into one.
- **Long poll.** `GetRun` with `after_revision = r` and `wait_millis = w` answers as soon as the run's revision passes
  `r`, or after `w` milliseconds with the current run. A terminal run answers at once whatever `r` is, and
  `after_revision = 0` always answers at once. A job manager caps `w` at a value of its choice of at least 10
  seconds. The SDK asks for the smallest of 30 seconds, the time left of `wait(timeout)`, and the `JobManager`'s
  `timeout` less a margin, and loops; the HTTP request's own bound is `w` plus that margin, so a long poll is
  never taken for a dead connection. Clients therefore never poll on a timer of their own.
- **Cancel** answers the run as it stands. A queued run becomes `CANCELLED` at once. A running one may still answer
  `RUNNING`: the hosts stop at their next cancellation point (the libkomira run handle's cancel), and the run then
  becomes `CANCELLED`, unless it reached `SUCCEEDED` or `FAILED` first.
- **Commit and cancel.** For a plan that writes, the commit and the move to `SUCCEEDED` are one atomic step. A run
  whose write committed ends `SUCCEEDED`, never `CANCELLED` or `FAILED`, so `CANCELLED` means nothing was
  committed and a caller may submit again. A cancel that loses the race to the commit leaves the run `SUCCEEDED`.

### 7. Results

- A run that succeeded has one result: the same rows, in the same Arrow schema, that `Session.sql` answers for the
  same plan on the same pinned data. For a write (`write_target`, `COPY ... TO`, `INSERT`) that is the summary a
  local session answers for the statement ([credentials_and_writes.md decision 10](credentials_and_writes.md#10-writes)).
  The commit is made once, by the run's committer ([iceberg_tables.md](iceberg_tables.md)), never by the SDK and
  never by the part of the job manager that places the plan.
- `ReadRunResult` streams it as one Arrow IPC stream (schema, dictionaries, record batches, end-of-stream) cut into
  `ResultChunk`s at any byte boundary. IPC body compression (LZ4 frame or ZSTD) is the job manager's choice; pyarrow
  and the engine's reader take both. The Python package hands the stream to `pyarrow.ipc.open_stream` over a reader
  of the chunks, so no batch is copied in Python, and `Result` wraps that reader as it wraps a local one.
- A job manager keeps a result for at least one hour after the run succeeded, longer at its choice, and sets
  `result_expires_unix_ms` when it knows the end. After that, and for a run that has not succeeded,
  `ReadRunResult` refuses: `RUN_RESULT_EXPIRED`, `RUN_NOT_FINISHED`, or the run's own `RunError` for a failed or
  cancelled run.
- Every read of one result answers the same rows in the same order; the bytes and the chunk boundaries may differ.
  A stream that breaks is read again from its start: resuming at an offset is a later, additive field of
  `ReadRunResultRequest`.
- **A plan with an `UNBOUNDED` scan** never finishes by itself, so it has no result to read. A job manager accepts
  one only with a `write_target`, and refuses one without at `SubmitRun` with `RUN_UNBOUNDED_RESULT_UNSUPPORTED`; the
  SDK checks the same before sending. Reading a streaming run's rows live is a later, additive call.

### 8. Errors

Every failure has a named code, and the SDK chooses the exception class by the code first, through the table that
already exists ([python_package.md decision 9](python_package.md#9-errors)), extended by the codes below, then by
where the failure came from:

| class (all `KomiraError`) | when |
|---|---|
| the existing class for the code | a code the table already maps: `CREDENTIAL_UNBOUND` and `CREDENTIAL_KIND_MISMATCH` raise `CredentialsError`, `STORAGE_*` raise `StorageError`, `MEMORY_BUDGET_EXCEEDED` raises `MemoryLimitError`, `PLAN_URL_QUERY_REFUSED` raises `UnsupportedOperation`, as they do locally |
| `UnsupportedOperation` | the SDK's own refusals before sending: the export refusals of decision 9 (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY` and `PLAN_LOCAL_PATH_REFUSED` join the table), `RUN_UNBOUNDED_RESULT_UNSUPPORTED`, `RUN_ENVIRONMENT_MISMATCH` found by the SDK, and the size limits `OPTIMIZED_PLAN_LIMIT_EXCEEDED` and `RUN_ENVIRONMENT_TOO_LARGE`. No job manager answered, so these are never `RunError` and their `run_id` is `None` |
| **PROPOSED** `RunCancelledError(RunError)` | `result()` of a run that ended `CANCELLED`: with the job manager's code when it sent a `RunError`, else with `RUN_CANCELLED` |
| **PROPOSED** `RunError` | any other `RunError` the job manager answered: the `OPTIMIZED_*` refusals, `ENDPOINT_NOT_ALLOWED`, `RUN_*`, an engine code from a host that the table does not map, and any code the SDK does not know (an unknown code never picks a more specific class) |
| **PROPOSED** `JobManagerError` | the job manager could not be reached, refused the caller (`unauthenticated`, `permission_denied`), or answered outside this protocol (a non-Connect body, a redirect, a missing field, an `UNSPECIFIED` state, an `unimplemented` call) |

- Every `KomiraError` raised by a `Run` or a `JobManager` call carries the existing attributes `status` (always
  `None`: no library status is involved), `code` and `step`, and a new attribute `run_id` (`None` when no run
  exists yet). `run_id` is added to `KomiraError` itself as `None` for every local error, so
  `except komira.KomiraError as e: e.run_id` never fails. Python's own `ValueError` and `TypeError` for a bad
  argument stay as they are, before any call (python_package.md decision 9).
- `step` keeps its existing values. A refusal by the job manager or by a host's admission carries none, as
  [credentials_and_writes.md](credentials_and_writes.md#11-error-shapes) already says of refusals outside
  libkomira; a failure while running carries the host's `lower` or `execute`.
- **Which moment finds which refusal.** The job manager reads only the header, so at `SubmitRun` it can refuse what
  the header shows: versions, revocation, needs over its limits, the environment's checks 1-3, the write target,
  the image repository and, once `DeclaredNeeds.credentials` exists, a credential name it cannot resolve
  (`CREDENTIAL_UNBOUND`). What needs the body (`OPTIMIZED_NEEDS_CREDENTIALS_MISMATCH`, `ENDPOINT_NOT_ALLOWED`,
  the structure and pin refusals of §7.2, a credential name before that field exists) is found by a host's
  admission and arrives as a `FAILED` run, raised from `result()`.
- A refusal that carries accepted versions or a base names them in its message, and `RunError` exposes them as
  `accepted_format_versions`, `accepted_contract_versions` and `oldest_accepting_base`, so the SDK can say "upgrade
  komira" or "rebuild the environment on base X" without parsing text ([optimized_plan.md §9.5](optimized_plan.md#95-not-promised-forward-compatibility)).
- **The codes this design adds**, each permanent once released:

| code | from | when | class |
|---|---|---|---|
| `JOB_MANAGER_UNREACHABLE` | SDK | connecting failed after the retries of decision 4 | `JobManagerError` |
| `JOB_MANAGER_UNAUTHENTICATED`, `JOB_MANAGER_PERMISSION_DENIED` | SDK, from the Connect code | the job manager refused the caller | `JobManagerError` |
| `JOB_MANAGER_PROTOCOL` | SDK | an answer that is not this protocol, a redirect, or an `unimplemented` call (the message names the call) | `JobManagerError` |
| `PLAN_LOCAL_PATH_REFUSED` | SDK, export | the plan reads a local file path, which a host cannot read | `UnsupportedOperation` |
| `RUN_ENVIRONMENT_TOO_LARGE` | SDK | the manifest is over 4 MiB (decision 3) | `UnsupportedOperation` |
| `RUN_CANCELLED` | SDK | `result()` of a run cancelled by `CancelRun`, which carries no `RunError` | `RunCancelledError` |
| `RUN_NOT_FOUND` | job manager | no run with that id that the caller may see | `RunError` |
| `RUN_REQUEST_ID_REUSED` | job manager | decision 5 | `RunError` |
| `RUN_NOT_FINISHED`, `RUN_RESULT_EXPIRED` | job manager | decision 7 | `RunError` |
| `RUN_UNBOUNDED_RESULT_UNSUPPORTED` | SDK and job manager | decision 7 | `UnsupportedOperation` |
| `RUN_ENVIRONMENT_MISMATCH` | SDK and job manager | `environment` set without `needs.runtimes`, or the reverse, or `image_repository` set without `environment` | `RunError` (from the SDK's own check: `UnsupportedOperation`) |
| `RUN_IMAGE_REPOSITORY_REFUSED` | job manager | decision 2: a repository its policy does not allow for the caller | `RunError` |

A bad URL is a bad argument: `JobManager(...)` raises Python's own `ValueError`, whose message begins
`JOB_MANAGER_URL_REFUSED:`, when the URL is not `https://` and not `http://` to a literal loopback address
(decision 3), or has user info, a query or a fragment.

- **Connect codes.** A job manager answers a refusal with the Connect code `failed_precondition` (or
  `invalid_argument` for a malformed request, `not_found` for `RUN_NOT_FOUND`, `resource_exhausted` for
  `OPTIMIZED_PLAN_NEEDS_OVER_LIMIT`) and one `komira.run.v1.RunError` in the error's details. The SDK reads the code
  from the detail; it maps a Connect error without one by its Connect code to `JobManagerError`.
- **No secret in an error.** A `RunError.message` follows the message grammar and redaction rules of
  [credentials_and_writes.md](credentials_and_writes.md#11-error-shapes): no credential value, no URL query, fragment
  or user info, no response body. The SDK adds one rule of its own: the token is never in a message, a `repr` or a
  log line.

### 9. Export: what may leave the process

Submitting is exporting a plan, and a plan that leaves the process must hold nothing that only works, or is only
safe, inside it. Before `SubmitRun`, the SDK refuses, each by name and before any byte is sent:

- a URL with a query string, as [credentials_and_writes.md](credentials_and_writes.md#4-the-plan-a-location-and-a-credential-name-never-a-value)
  already decides (`PLAN_URL_QUERY_REFUSED`);
- an in-memory source, which the plan wire already refuses (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`);
- a local file path, relative or absolute, a `file://` URL included (`PLAN_LOCAL_PATH_REFUSED`). A host has no
  access to the user's disk; a local table registered with `register_parquet(name, "./orders.parquet")` runs with
  `sql` and refuses with `submit`;
- an `UNBOUNDED` plan without a write target (decision 7);
- a plan larger than the limit of decision 3.

**PROPOSED** libkomira calls, additive in an ABI minor: `komira_sql_export(ctx, sql, ...)` and
`komira_plan_export(ctx, plan, ...)`, the export counterparts of `komira_sql_stream` and `komira_plan_stream`.
Each parses or decodes, binds, optimizes and runs the export checks above, then returns the bytes of
`produce_optimized_plan` with `ProducerStamp.kind` set by the SDK (`"komira/python-sdk"`, `"komira/typescript-sdk"`,
`"komira/mojo-sdk"`). They depend on the optimizer driver; until it exists `submit` cannot be built over the real
optimizer, and [the follow-up](#what-lands-when) builds over a fixed plan instead. Their C signatures belong to the
ABI design ([libkomira_run_abi.md](libkomira_run_abi.md)).

### 10. Versioning

- `komira.run.v1` changes additively only (rule B8): new optional fields, new messages, new calls, new enum values.
  Nothing is renumbered, renamed on the wire, removed or re-meant. A `v2` package is never planned; a change that
  cannot be additive is a new call.
- **Both sides ignore unknown fields** of this package's messages, and an SDK keeps working against a job manager of
  any later version. That is safe only under a rule every later version keeps: **a request field may only inform or
  hint**, so losing it on an older job manager loses only that. A field the caller needs honoured (a deadline, a
  cost cap, a retention it asks for) is never a plain request field. It goes inside the plan, where an unknown
  field is refused; or it ships as a new call, which an older job manager answers `unimplemented`; or the job
  manager echoes the value it applied in a new `Run` field, and the SDK refuses to go on when the echo is absent.
- An unknown `RunState` is non-terminal (decision 6). An unknown Connect method answers `unimplemented`, which the
  SDK raises as `JobManagerError` naming the method, so a newer SDK against an older job manager says what is missing.
- The plan inside keeps its own rules: refused if unknown, accepted forever once released
  ([optimized_plan.md §9](optimized_plan.md#9-versioning-backward-compatibility-always)).
- **Cross-version test.** Each release that ships `komira.run.v1` adds golden encodings of each request and response
  to the package's tests, append-only; every later SDK must decode every recorded response and every later stand-in
  every recorded request. That is the "previous release on new data, and new release on old data" check of B8,
  without fetching an older release.

### 11. What a job manager must do

A job manager that implements this protocol keeps these, whatever else it does. They are the public contract; a
job manager breaking one is not a job manager of this protocol.

1. It accepts plan work only as `SubmitRunRequest.optimized_plan`: never SQL text, never a bound plan, never a
   `WirePlanEnvelope`. It never decodes the body and never runs the optimizer (rule B21).
2. It runs the header library's steps 1-3 (with §10.11 checks 1-3 when an environment is sent), checks
   `image_repository` against its policy, and authorizes `write_target`, before it answers `SubmitRun`; once
   `DeclaredNeeds.credentials` exists (**PROPOSED**, decision 4 of credentials_and_writes.md), it also checks those
   names against what it can resolve there. A refusal there is a refusal of the call, not a failed run, and creates
   no run.
3. It accepts every plan a released producer emitted (backward compatibility with no window): it places a plan
   only on hosts whose build accepts its versions, or refuses with the token and the accepted sets.
4. It resolves credential names and nothing else, as decision 5 of credentials_and_writes.md says.
5. It scopes every call to the caller (decision 3), keeps `request_id` atomically for its window (decision 5), makes
   a write's commit and `SUCCEEDED` one step (decision 6), and keeps a result for its floor (decision 7).
6. Its codes are this document's, optimized_plan.md's and the engine's, never renamed. A code of its own is upper
   snake case, does not begin with any prefix a komira code begins with (today `OPTIMIZED_`, `OPTIMIZE_`, `PLAN_`,
   `RUN_`, `JOB_MANAGER_`, `CREDENTIAL`, `STORAGE_`, `SQL_`, `BIND_`, `STATEMENT_`, `LOWERING_`, `COPY_`,
   `MEMORY_`, `ICEBERG_`, `UDF_`, `ENDPOINT_` and `QUERY_`; the code tables of python_package.md decision 9 and
   credentials_and_writes.md are the list), and reaches the user as a `RunError`.

## What lands when

| step | pull request | proof |
|---|---|---|
| 1 | this design | merged; the public-boundary lint (`//:public_boundary`) and the link check (`//:docs`) pass |
| 2 | `src/run_proto` (the `.proto`, its generated Mojo, its welded tests) and `PlanEnvironment` in `optimized_plan.proto`; the Python `python_proto` target for both | the wire bytes of each field pinned, round trips, the golden set started (decision 10) |
| 3 | the Python client: `JobManager`, `Session.submit`, `Run`, the three classes, the codes, and the stand-in job manager in `python/tests` | the cases of [How is it tested?](#how-is-it-tested). `submit` exports through a fixed, hand-built `OptimizedPlan` until the export call of step 4 exists |
| 4 | `komira_sql_export` and `komira_plan_export`, after the optimizer driver | `submit` over real SQL; the export refusals of decision 9 |
| 5 | TypeScript and Mojo clients; for Mojo, a per-call message limit in `src/grpc` so `SubmitRun` can carry more than 4 MiB | the same cases against the same stand-in |

## How is it tested?

This pull request is a design and has no tests. What step 3 must show, against the stand-in job manager: a Python
`RunService` over Connect on a loopback listener bound to port 0, started and stopped by each test, with no fixed
port, network or shared state (rule T12). It checks the header with the same rules as the header library (step 2
gives it the generated Python modules), answers results it is given, and records every request it receives.

- **Happy path**: submit, wait, `result().to_arrow()` equals the stand-in's table; `jm.run(id)` from a second
  `JobManager` sees the same run; a second `result()` opens the stream again; the session closed after `submit`.
- **Refusals at submit**, one test per code, each raising its class with `code`, `step` and the full message by
  exact equality: `OPTIMIZED_PLAN_VERSION_UNSUPPORTED` with the accepted set, `OPTIMIZED_PLAN_PRODUCER_REVOKED`,
  `RUN_REQUEST_ID_REUSED` (same id, other plan; same id, other image), `RUN_ENVIRONMENT_MISMATCH`,
  `RUN_UNBOUNDED_RESULT_UNSUPPORTED`, `RUN_IMAGE_REPOSITORY_REFUSED`; each creates no run. `CREDENTIAL_UNBOUND` (as
  `CredentialsError`) joins them when `DeclaredNeeds.credentials` exists; until then it is a failure after submit.
- **Export refusals** before any request (the stand-in records none): `PLAN_URL_QUERY_REFUSED`,
  `PLAN_LOCAL_PATH_REFUSED`, `PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`, and each size limit of decision 3 at the
  limit (sent) and one byte over (`OPTIMIZED_PLAN_LIMIT_EXCEEDED`, `RUN_ENVIRONMENT_TOO_LARGE`).
- **Failure after submit**: a run the stand-in fails with an engine code raises from `result()` with `run_id` and
  `step`; `CREDENTIAL_UNBOUND` from a host raises `CredentialsError`; an unknown code raises `RunError`; a run
  cancelled by `cancel()` raises `RunCancelledError` with `RUN_CANCELLED`, and one the job manager cancelled
  raises it with the job manager's code; `wait()` returns the terminal state without raising, and `Run.error`
  holds the failure.
- **States**: an unknown state value is reported by name and waited through; a `RUNNING` run put back to `QUEUED`
  is waited through; a terminal state ends the wait; `GetRun` on a terminal run answers at once. The stand-in
  answers a long poll only when the test releases it or its poll bound is reached on the injected clock, and counts
  requests, so the SDK is seen to ask with `after_revision` and never to poll between answers; `wait(timeout)` past
  its bound raises `TimeoutError` and does not cancel.
- **Idempotency and retries**: a connection dropped on the first `SubmitRun` is retried once with the same
  `request_id` and makes one run (`deduplicated` on the second answer); two concurrent submits with one id make
  one run; three failures raise `JOB_MANAGER_UNREACHABLE`; a stream broken after its first chunk is not retried.
  Waits run on an injected clock.
- **Cancel**: of a queued run, of a running run (answers `RUNNING`, then `CANCELLED`), of a finished run (no change,
  no error), and of a writing run after its commit (ends `SUCCEEDED`, `result()` answers the write summary); Ctrl-C
  during `wait()` does not call `CancelRun` (the stand-in records none).
- **Transport and secrets**: `http://` to a non-loopback host, `http://localhost`, and a URL with user info,
  a query or a fragment raise `ValueError` with the exact message; the token is sent as a bearer header, refreshed
  through a callable, and absent from every message and `repr` (exact equality); a 307 to another origin gets no
  second request and raises `JOB_MANAGER_PROTOCOL`, as does an answer that is not Connect; an `unauthenticated`
  answer raises `JobManagerError`; an `unimplemented` call raises `JOB_MANAGER_PROTOCOL` naming the call.
- **Results**: a result over 4 MiB arrives in several chunks and reads whole; an encoded chunk of exactly 4 MiB
  reads and one byte more is refused; a chunk boundary inside an IPC message reads; an error in the end-stream
  envelope raises from the terminal; two reads answer the same rows; `RUN_RESULT_EXPIRED` and `RUN_NOT_FINISHED`
  raise.
- **Versions**: the golden requests and responses of decision 10 decode; a response with an unknown field decodes.

The list is complete in this sense: every code of decision 8 has a case, every state rule of decision 6 has one,
every call of decision 1 has a success and a failure, and every "never" in this document (no second run on retry,
no cancel on Ctrl-C, no token in text or to another origin, no request before an export refusal, no commit under
`CANCELLED`) has a case that would see it broken.

## What must always hold?

- No SQL text, bound plan or credential value leaves the process; only `OptimizedPlan` bytes, an environment
  reference and a request id do.
- A run computes what `Session.sql` computes for the same plan on the same pinned data.
- A retried submit never makes a second run within the `request_id` window (decision 5).
- `CANCELLED` means nothing was committed.
- An SDK never waits forever on a finished run, whatever states a later job manager adds.
- No call of an SDK reads configuration from the environment; the URL, token and trust roots are arguments.
- A caller sees only its own runs.

## Options considered

| option | verdict |
|---|---|
| gRPC only | Rejected: a Python gRPC client is a new, large native dependency of the wheel, and a browser or a plain HTTP stack cannot call it. Connect keeps gRPC as an option for the job manager. |
| REST with JSON bodies | Rejected: the plan is 16 MiB of bytes, base64 in JSON adds a third, and a second encoding of the same messages is a second thing to keep in step. |
| Arrow Flight for results | Rejected for now: `pyarrow.flight` is an optional part of pyarrow, and the in-tree Flight server is the broker's. A result stream over Connect reuses the one transport; a Flight endpoint can be added as a later call. |
| `submit` blocks and returns a `Result` | Rejected: a remote run outlives the caller's process, a notebook kernel restart or a laptop lid. A handle with `result()` gives the blocking form in one more call. |
| Ctrl-C cancels the run, as locally | Rejected: it would make an interrupted wait destroy hours of shared work; `cancel()` is explicit. |
| The SDK uploads the environment image through the job manager | Rejected: images are large and layered, registries already move them by digest, and it would make every job manager a registry. |
| The tenant chosen by a request header | Rejected: a header that names a tenant is not authentication. The earlier job API trusted one and also let any caller address any run by id; decision 3's scoping rule replaces both. |
| A generic job API (`binary`, `config` map) carrying the plan as a string | Rejected: untyped, and the plan's digest would be over whatever the map held. |

## What is decided elsewhere

| question | where |
|---|---|
| the plan: header, body, digest, admission refusals, versions | [optimized_plan.md](optimized_plan.md) |
| the environment image and its checks | [optimized_plan_udf_runtime.md §10.11](optimized_plan_udf_runtime.md#1011-the-environment-image-and-the-engine-age-rule) |
| credential names and the job manager's resolver | [credentials_and_writes.md decision 5](credentials_and_writes.md#5-who-binds-credential-names-to-values) |
| the export calls' C signatures | [libkomira_run_abi.md](libkomira_run_abi.md) |
| how a job manager authenticates, stores, places, bills and retains | the job manager |

## What are the limits and open questions?

- A `STEP` UDF may submit further plans as their own runs ([optimized_plan_udfs.md](optimized_plan_udfs.md)). How
  the SDK inside the image learns the job manager's URL and the run's token, with no environment variable, is not
  decided here; it is the job manager's to pass in as arguments, and a later design.
- Reading a streaming run's rows live, listing runs and labels are later, additive calls (decisions 1 and 7).
- Until the optimizer driver and the export calls exist, nothing can submit real SQL; step 3 tests the client over a
  fixed plan.
- Format version 1 carries no UDFs, pins or advice, so the first plans a job manager sees have no environment.

## Where is the code?

Nothing yet. Proposed: `src/run_proto/` (the schema), `python/komira/` (the client, in private modules), the
stand-in under `python/tests/`.
