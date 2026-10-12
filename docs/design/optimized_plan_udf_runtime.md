# Design: user code in an `OptimizedPlan`, part 2 (host execution, the environment image, compatibility)

Status: proposed, not built. This is §10.10-§10.14 of [`optimized_plan.md`](optimized_plan.md), split from
[`optimized_plan_udfs.md`](optimized_plan_udfs.md) (§10.1-§10.9) so each file stays under 1,000 lines. Section numbers
continue those documents': `§10.10`-`§10.14` are here, `§10.1`-`§10.9` are in `optimized_plan_udfs.md`, and every
other `§n` is in `optimized_plan.md`.

Citations follow `optimized_plan_udfs.md`: komira `main` as merged by komira-ai/komira#977 unless marked otherwise.
Statements marked *(inferred)* are my reading, not facts taken from the code. Nothing was built or run to write this
document.

The runtime interface a UDF runs through, and what a language implements, is
`udf_runtime_interface.md` (komira-ai/komira#1132).

---

### 10.10 Host execution

The plan runs on the engine in the base layer of its environment image (§10.11).

The engine calls each UDF through its runtime's C ABI (`udf_runtime_interface.md` §4), with every runtime library
loaded in the engine's process. Each language has one mode, chosen by its runtime (§10.1, `udf_runtime_interface.md`
§1.2): `komira/native` runs native UDFs in-process; `komira/python` and `komira/node` run user code in worker
processes that they start and manage themselves. The host chooses no transport, and none is in the plan (§10.13). A
plan may use several runtimes, and every rule below holds for each.

- **Native UDFs run in-process** (`komira/native`, §10.1): no copy, no interpreter and no process per batch. A fault in
  an in-process native UDF ends the engine and fails the run, naming the library (`udf_runtime_interface.md` §1.2,
  §7). Native UDFs ship only once the launch gates of `udf_runtime_interface.md` §1.2 pass, the next rule among them.
- **The managed runtimes contain crashes and stop user code by force.** `komira/python` and `komira/node` report
  `CONTAINS_CRASHES` and `FORCED_STOP` (`udf_runtime_interface.md` §1.2, §4.2): a crash in user code fails the call
  with `ERR_WORKER_CRASHED` and leaves the engine running, and user code that ignores a cancel or a deadline is
  stopped and the call returns `ERR_KILLED` (§4.7 there). How a runtime does this is its own business
  (`udf_runtime_interface.md` §5, informative).
- **Runtimes from added image layers** would be loaded into the engine like any runtime; whether they are allowed is
  open (`udf_runtime_interface.md` §1.3 item 2, §8.3).
- **The heartbeat token stays in the supervisor.** The supervisor holds no long-lived credential and none
  that meters usage: it holds a run-scoped id and token used only to authenticate its heartbeats, and the party that
  receives the heartbeats meters the run's usage by accumulating them. The supervisor runs as its own process
  under its own user id, distinct from the engine's. The token is never passed to the engine: not in its arguments,
  its environment, a file its user id can read, or an inherited descriptor. So user code, whether in the engine or in
  a worker, cannot read the token, forge or suppress a heartbeat, or trace or signal the supervisor. Workers run under
  the engine's user id (`udf_runtime_interface.md` §1.3, §7): they hold nothing the engine does not, and they add crash
  containment, not a privilege boundary. User code is the customer's own, but the supervisor's reports must stay the
  supervisor's.
- **Code loads before data is read.**
  - The runtime verifies the sha256 of every code object and data blob it loads; a mismatch is
    `OPTIMIZED_UDF_CODE_DIGEST_MISMATCH`.
  - Each context loads each `UdfRef` **once** and keeps it across batches, so a captured model loads once per
    context, not once per batch.
  - Loading happens in §7.2 step 9, before any data is read.
- **Context count and threads.** The host sets the number of contexts (the pool size) from the CPU count,
  `max_workers`, and the memory a context uses with its UDFs loaded (`worker_mem_bytes`, counting what the runtime
  reports through `memory_report`), so N copies of a large model do not exceed the host's memory
  (`udf_runtime_interface.md` §3.3, §4.8). Native thread pools (OpenMP, BLAS) are set to each context's share of the
  CPUs, so N contexts do not each start one thread per CPU (`udf_runtime_interface.md` §7).
- **Batches cross as Arrow C Data.** Every call crosses the C ABI as Arrow C Data structs with no copy, and the engine
  validates every array it imports. The runtime converts each batch to the function's batch format. A runtime that
  runs user code in another process hands the engine only buffers that process can no longer write
  (`udf_runtime_interface.md` §4.4). The runtime C ABI is versioned (`udf_runtime_interface.md` §8.1); how a runtime
  talks to its own workers is private to it and carries no promise across releases.
- **Batch size adapts.** Within `max_batch_rows`, the host sizes batches from observed call latency, so a slow model
  or API call reports progress and balances load. This is a host-local rule (§5.3): observed latency adjusts batch and
  pool sizes only; it never changes the plan's shape.
- **Errors come back mapped.** A raised exception becomes `UDF_RAISED`, with the user's stack mapped by the runtime to
  the user's file and line (a Python traceback, a Node stack through the bundle's source map).
  Standard error goes to the run log.
- **A crash fails the run; nothing is retried.** Any `ERR_INSTANCE_LOST` or `ERR_WORKER_CRASHED` (signal or exit of
  the process running user code) fails the run with `UDF_WORKER_CRASHED`, naming the UDF and the signal or exit
  status, whatever the stability (§10.7, `udf_runtime_interface.md` §4.5). Retrying a batch or reopening a frame or
  aggregate after a lost context is rejected for the first release (§10.13).
- **A read outside the read set.** A `ROW` read outside the read set fails the batch with `UDF_FIELD_NOT_DECLARED`
  (§10.2), whatever the stability; it is not bisected, because the same batch fails the same way. A
  `MAP_BATCHES_FRAME` with a read set receives batches holding only those columns, so a read of another column fails
  in the user's own data library and is reported as `UDF_RAISED` (open, §10.2).
- **One nesting is allowed.** Calls on one context are serialized, except that while a frame's `frame_next` waits on
  its input pull, the host may call into the same context to produce that input (for example a scalar UDF of the
  same runtime upstream in the same pipeline); those calls complete before the pull returns
  (`udf_runtime_interface.md` §4.3). Pipelines stay fused and one context per engine thread suffices, so no lowering
  rule or pipeline break is needed around a frame.
- **Each call's output is checked.** A `MAP_BATCHES_COLUMN` call that returns a different length is
  `UDF_BATCH_LENGTH_MISMATCH`; a returned type outside `return_type` is `UDF_RETURN_TYPE_MISMATCH` (§10.5).
- **The `STEP` runtime limit is enforced.** A step that runs past `max_runtime_ms` is stopped with
  `UDF_STEP_TIMED_OUT`.

The context count, thread limits and batch slicing within `max_batch_rows` and `max_workers` are host-local rules
(§5.3).

**A producer's local run uses the same path** *(informative)*. It captures the function, calls it through the same runtime
and C ABI as a host does, and loads **the captured payload, not the live object**, so a capture that would fail remotely, or a
function that depends on notebook state it did not capture, fails locally first. Capture is not the only difference
between a laptop and a host, so the local run also runs user code with an empty working directory and only the environment
variables a host provides, and report by name a function that opens a file outside its bundle or blobs. Two
differences remain: a UDF that assigns to a global changes the runtime's copy, not the user's; and the network the
function can reach differs. When the plan sets a read set, the local run passes a `ROW` or frame UDF only its
columns (§10.2), so a read that a declaration or a scan missed fails on the user's machine first. The local run never
adds to the read set.

**In a streaming plan** (a plan with an `UNBOUNDED` scan, §5.2), the same runtimes serve the streaming driver, with
three additions:

- **A plain-form `AGGREGATE` over an unbounded input is refused**, because its group never closes: at plan build on
  the producer (`UDF_AGGREGATE_UNBOUNDED_GROUP`) and at admission (`OPTIMIZED_UDF_AGGREGATE_UNBOUNDED_GROUP`). The
  mergeable form works incrementally, and its Arrow state is what a checkpoint of that aggregate holds.
- **State in a context does not survive a restart at the first release.** A restarted context loads the captured code
  again and its state starts empty; mergeable aggregate state is checkpointed as its Arrow state. Keeping a callable's
  own state across a restart needs `snapshot`/`restore` entries in the runtime ABI, which ABI 1.0 does not have
  (`udf_runtime_interface.md` §8.1, "Candidates for ABI 1.1").
- **A grouped `MAP_BATCHES_FRAME` over an unbounded input is refused** for the same reason as the plain
  aggregate (`OPTIMIZED_UNBOUNDED_INPUT_UNSUPPORTED`, §5.2).

### 10.11 The environment image and the engine-age rule

**The environment image travels beside the plan.** It is not part of the plan and not in `plan_digest`. A scheduler
receives the two together:

```proto
// Beside an OptimizedPlan, never inside it.
message PlanEnvironment {
  string image_digest   = 1;   // "sha256:<64 lower-case hex>" of the OCI image manifest
  bytes  image_manifest = 2;   // the manifest bytes; sha256(image_manifest) must equal image_digest
}
```

A plan with no `UdfRef` runs on an unmodified released base image. A plan whose stages need different images (for
example separate CPU and GPU pools) is a later, additive field; today a plan has one environment.

**What the image is.** An environment image is **built FROM a released komira base image**, so its layer list
begins with that base's layers. A release ships **several bases**: one per supported CPython minor and one per
supported Node major. Remote runs follow the client's version: a Python producer's environment is built FROM the base
of its CPython minor, and a TypeScript producer's FROM the base of its Node major. Each base contains:

- the engine and the producer library;
- the job supervisor (`src/komira_job_supervisor`);
- the runtime registry: `komira/native`, and the one managed runtime the base is for (`komira/python` with its one
  CPython minor, or `komira/node` with its one Node major), each with its library, and the
  serializers and capture formats each accepts.

**One managed runtime per base image.** A base carries exactly one managed runtime (one CPython minor or one Node
major) besides `komira/native`. A plan that needs two managed runtimes (for example both `komira/python` and
`komira/node`) therefore has no base and is refused at admission check 3 (`OPTIMIZED_ENV_RUNTIME_MISSING`). Each SDK
captures only its own language, so only an assembled plan can need two.

The base image's `[layers]` output lets this prefix be checked: "An image whose layers begin with these is built
FROM this one" (`packaging/images/base/README.md` in komira-ai/komira#1070, not yet on `main`). The layers the
user's side adds may contain:

- dependency layers, in the runtime's environment directory `/opt/env/<runtime>/` (one layer, or one per
  distribution or package): `/opt/env/komira/python/` is a virtual environment created at that path, and
  `/opt/env/komira/node/` holds the packages with native addons (§10.6). The
  older name `/opt/venv/` is retired: no base or added layer uses it;
- a code layer under `/komira-code/` with the source bundles, the JavaScript bundles (pure-JavaScript dependencies
  included, §10.6) and the payloads;
- data-blob layers. A large blob may be its own layer, so an unchanged blob is pulled once per host;
- third-party runtime layers, each under `/komira-runtimes/<namespace>/<name>/` with the runtime's library, its
  manifest (`udf_runtime_interface.md` §8.3). Such a runtime would be loaded into the engine like any runtime, never
  into the supervisor; whether added runtimes are allowed on that basis is open (`udf_runtime_interface.md` §1.3
  item 2).

**Added layers write only their prefixes.** An added layer may contain paths only under a runtime's environment
directory `/opt/env/<runtime>/` (dependencies), `/komira-code/` (code and data) and
`/komira-runtimes/<namespace>/<name>/` (third-party runtimes), and no whiteout. Everything else belongs to the base: its program prefixes
(`/komira/`, `/opt/kci/`), and also its C library, loader configuration and CA certificates
(`packaging/images/base/README.md` in komira-ai/komira#1070), any of which an added layer could otherwise use to run
code inside the supervisor. System libraries a dependency needs are a builder concern and land in the same
runtime's environment directory *(inferred: a relocatable install prefix; see question 8 in §14)*.

**Command and configuration are always ours.** The runner names `/komira/bin/supervisor` as the command. It ignores
the image configuration's `Entrypoint`, `Cmd`, `Env`, `User` and `WorkingDir`, which a derived image can set (same
README).

**Admission of the pair (plan, environment).** The checks split by what each party may read. The header library
needs only the manifest bytes, so a scheduler never pulls a layer:

1. **Released base.** `sha256(image_manifest)` equals `image_digest`, and the manifest's leading layers equal the
   layer list of a **released** base. The release record is published with the release; it is never read from image
   labels, which a user can write. Otherwise: `OPTIMIZED_ENV_BASE_UNRELEASED`.
2. **The engine is at least as new as the plan needs.** The plan's `format_version` and `optimizer_contract_version`
   must be **members** of that base release's accepted sets. Otherwise: `OPTIMIZED_ENV_ENGINE_TOO_OLD`, carrying the
   accepted sets and the oldest released base that accepts the plan.
   - "At least as new" is stated as membership because `engine_build` is an unordered digest (§4.1).
   - Every later base accepts every earlier version (§9.1), so rebuilding the environment on a newer base always
     fixes it. The producer's engine and the image's engine need not be equal.
3. **Runtimes present.** Every `needs.runtimes` pair `(runtime, runtime_abi)` is in the base release's runtime
   registry, or is declared by an added runtime layer; otherwise `OPTIMIZED_ENV_RUNTIME_MISSING`, naming the pair.
   - For `komira/python` the ABI tag is the CPython tag (for example `cp312`; a free-threaded build is a different
     tag, `cp313t`), and patch releases within a minor may differ. *(Inferred: this relies on CPython keeping the
     bytecode magic number fixed within a released minor, which it has broken once, in 3.5.3. Each base release
     compares `importlib.util.MAGIC_NUMBER` across the patches of each minor it ships.)*
   - For `komira/node` the ABI tag is the Node major (for example `node22`), and runs follow the client's major.

The host runs these again, and then, with the layers in hand:

4. **Code present.** Every `code.code[i].sha256` and every `data_blobs` digest is in the image's code or data
   layers. Otherwise: `OPTIMIZED_ENV_CODE_MISSING`, naming the digest and the UDF.
5. **Packages present.** Every `PACKAGE` reference resolves in its runtime's environment directory (for
   `komira/python`, the distribution is importable from `/opt/env/komira/python/`). Otherwise: `OPTIMIZED_ENV_PACKAGE_MISSING`.
6. **Added layers stay in their prefixes.** Otherwise: `OPTIMIZED_ENV_RESERVED_PATH`, naming the layer and the path.
7. **Descriptors valid and shapes supported.** Each runtime's `validate` accepts its descriptors and its capabilities
   cover each shape. Otherwise: `OPTIMIZED_UDF_DESCRIPTOR_INVALID` or `OPTIMIZED_UDF_KIND_UNSUPPORTED`; a `ROW` or
   `MAP_BATCHES_FRAME` whose `arg_types` names differ from the fields its descriptor records (`validate` returns
   `ERR_READ_SET_MISMATCH`) is `OPTIMIZED_UDF_READ_SET_DESCRIPTOR_MISMATCH`, and the user rebuilds.

**Load check.** At §7.2 step 9 the host calls each runtime's `load` for every UdfRef (for `komira/python` this imports
every `PACKAGE` and `BUNDLE` module and loads every payload and data blob; for `komira/node` it loads every bundle and
restores every `VALUE`'s captures), and refuses a failure by name before
any data is read (`OPTIMIZED_UDF_CODE_UNLOADABLE`); for example, a model pickled under one library version and loaded
under another. Whoever builds an environment image may run the same check inside the new image, with no network,
before returning its digest. A module that needs the network at import time fails that check with a message that says
so.

**What each change requires.**

| Change | `PACKAGE` | `BUNDLE` | `VALUE` |
|---|---|---|---|
| New base, same Python minor, same distributions | Runs | Runs | Runs if the base accepts `serializer` and the load check passes |
| A distribution upgraded | Runs if the load check passes | Runs if the load check passes | Runs if the load check passes |
| Python minor changed | A producer re-captures: new plan | A producer re-captures: new plan | A producer re-captures from the `"source"` code object, and each data blob must load under the new minor. Without recovered source, refused by name |

For a `komira/node` reference, a new base with the same Node major runs it if the base accepts its capture format and the load
check passes. After a Node major change a producer captures it again from its source, which both TypeScript forms
always carry (§10.6), so a stored TypeScript UDF is never blocked for lack of source.

**Stored plans.** A party that keeps a plan for later runs keeps its environment with it:

- **A stored `OptimizedPlan`** (replayed, or kept with its cut, §9.6) runs in the image it was recorded with. The
  party that keeps the plan keeps that image (§10.12).
- **A stored bound plan, re-optimized on each run** (§2), is re-optimized by the producer library **inside the
  environment's base**, so it emits only versions that base accepts and is never refused as `OPTIMIZED_ENV_ENGINE_TOO_OLD`.
  A re-capture after a Python minor change runs the same way, in the new base, from the `"source"` code object.

**Saving a stored job prefers `BUNDLE`** *(informative)*:

- The SDK promotes every `VALUE` function whose source it can recover: the function's own `def`, or the exact span of
  a lambda located from its code positions (Python 3.11 and later), never the rest of a notebook cell, which may have
  side effects. Its globals stay bound to the captured blobs.
- Before saving, the SDK runs the promoted function and the live payload on the local preview sample and blocks the
  save by name if they differ, because rebound globals, default arguments and decorators can make re-executed source
  behave differently.
- If a function's source cannot be recovered (one built with `exec`, or a lambda typed at a bare interpreter prompt),
  saving is **blocked by name**. Running it is never blocked.

### 10.12 Backward compatibility, restated for code

Five contracts carry different promises:

| Layer | Promise | Bound to |
|---|---|---|
| The plan format: `UdfRef`, `UdfCode`, the arms, `AGG_UDF`, `needs.runtimes` | **Forever backward compatible** (§9). Every later engine decodes, admits and lowers every released plan that contains them, and never refuses one for its age | Nothing |
| A runtime's descriptor schema | Forever readable by that runtime in every base that ships it | The runtime |
| Code and data: source bundles, payloads, blobs | They load in the environment image they were captured for, and in any other that passes §10.11 | The environment image |
| A runtime to its own worker processes: that runtime's private protocol | None across releases; not part of komira's contract | The runtime, shipped in the base layer of the same image |
| The runtime C ABI | Append-only within a major version | Only for runtimes built outside the base release |

The serialized function belongs to the image-bound code layer, not to the plan format. The plan holds only digests
and the serializer's name, so the plan-format promise is unchanged. Whether a payload *loads* is a property of the
environment, just as whether a `PACKAGE` module imports already is.

What §9.1's "accepts and executes" means for a UDF plan:

- **It executes, forever, with the environment image it was recorded with.** That image's base is a released base,
  and a released base is never withdrawn from the parties that keep plans recorded against it (a base revoked for a
  vulnerability is §9.7's build revocation, applied to the base's engine build). A base with a known vulnerability
  that is not revoked stays released: a deployment may stop building new environments on it, but a plan recorded
  against it still runs, with a warning. So a UDF plan is never refused for its age, including after its Python minor
  or Node major leaves the set new bases are built for.
- It also executes with any later image that passes §10.11, which is how such a plan reaches a newer engine. A
  rebuilt image is a different environment. A run record keeps both digests, so replaying with
  the original image reproduces the original result.

The corpus (§9.4) holds this: each UDF corpus plan is executed with an environment on the newest base of its runtime
ABI, so a plan whose interpreter minor or major new bases no longer ship still runs, on the last base that shipped it.

**Format version.** If the UDF arms ship in the first release that ships `OptimizedPlan`, they are part of
`format_version` 1 and need no bump. Otherwise each field above is added under a new `format_version` (§9.2); none of
them needs a contract bump.

### 10.13 The options considered

| Option | Verdict |
|---|---|
| Reference by name, resolved in a registry on the host (today's `WireUdfCall`, `WireUdf`) | Rejected for user code. A lambda or notebook function has no resolvable name, and a registry cannot carry captured variables. Kept RAW-only for registered Mojo UDFs. |
| Reference only by `{module, qualname}` and refuse closures | Rejected. It fails §10.1 for every notebook user. |
| Serialized function bytes inside the plan (as Spark Connect's Python UDF message carries pickled bytes) | Rejected. It ties a forever-compatible format to a pickle that loads only under one Python and one set of libraries, and it puts megabytes of captured data under the plan's size budget and digest. |
| By value in an image-bound code layer, by reference where the code is installed or is project source, with the plan holding digests | **Chosen.** The plan format stays pure data. The fragile part lives with the environment that can load it, and is checked there (§10.11). |
| Code layer in a bucket beside the plan instead of in the image | Rejected. It needs a second digest, a second retention rule and a second integrity check, for what one image digest already pins. |
| Return types learned while the plan runs: observed by a local run, or locked from the first batches (an earlier draft of this section) | Rejected. The plan needs every output type when it is built; a deferred type leaves predicate placement, typed kernels and the output schema undecided, and needs operators bound late in the engine. Polars removed its plan-time guess from lazy mode for the same reason. |
| A required decorator or a wrapper class (`@udf(...)`, a `MapFn` class) to carry the type | Rejected. A type hint or a verb argument carries it in the language's own idiom; a decorator would only register a name, which this design does not need (§10.3). |
| TypeScript return types from annotations, through a compile-time transformer | Not needed at the first release. The type value on the verb gives the compiler the same check. A transformer that derives the value from the annotation can be added later as an SDK option, with no format change. |
| TypeScript: module-level functions only, closures refused | Rejected as the default. A closure over plain data is the common case and the inspector captures it. The cost is upkeep against V8 internals for each Node major (§10.6). |
| Aggregate UDFs only in the mergeable form | Rejected. Most users write a function over a group; the plain form is the default and the mergeable form is for scale. |
| A Python object (pickle) as an aggregate's partial state | Rejected. An explicit Arrow `state_type` crosses exchanges as a column, has a size that can be capped, and is already a streaming checkpoint. |
| Exact version pins on `PACKAGE` references | Rejected. A dependency patch would invalidate the plan, while the same dependency reached through a `VALUE` payload would not; the load check decides both. |
| Whole-environment sync instead of the import closure of the captured code | Left to the producer, not the format. The format requires only that every `PACKAGE` reference resolves. |
| A closed runtime enum and a `oneof` arm per language code form (an earlier draft; Spark Connect's `CommonInlineUserDefinedFunction`) | Rejected: each language would be a format change forever; SPARK-55278 proposes moving Spark away from it. |
| Transport (in-process or worker) in the plan, or chosen by the host or the engine | Rejected. Each language has one mode, chosen by its runtime; the C ABI is the only interface between the engine and a runtime, and how a runtime executes user code is its own business (`udf_runtime_interface.md` §1.2, §10). |
| `MAP_BATCHES` form derived from the arm | Rejected: one UdfRef could be bound with two schemas. |
| A row-shaped UDF as a `SCALAR` over the whole row, or a host that infers the fields read | Rejected. The whole row keeps every column live; a host cannot re-derive what the producer knew, and two hosts could disagree. `ROW` carries an optional read set (§10.2). |
| The read set carried only in `arg_types`, with every input column listed when the reads are undetermined (an earlier draft) | Rejected. `arg_types` can say "every input column" only by listing them, which reads the same as a declared read set naming every column, and it gave a frame no read set. An optional `read_set`, unset meaning every column, states the rule; validation keeps `arg_types` in agreement (§10.4). |
| `read_set` as a bare `repeated string` | Rejected. A repeated field has no presence in proto3, so "reads every column" and "reads none" would be one encoding. |
| An empty read set refused | Rejected. A function that reads no column is legitimate, and a batch with no children carries the row count. |
| A local run (a recording row proxy) as a source of the read set (an earlier draft) | Rejected. A field read only on a branch the local run did not take would be missing, and the scan defect it hides would surface only on a host. |
| Retrying a batch, or reopening a frame or aggregate, after a lost context | Rejected for the first release (`udf_runtime_interface.md` §10). Any loss or crash fails the run with `UDF_WORKER_CRASHED`, naming the UDF (§10.10). |

### 10.14 Comparison

- **PySpark and Spark Connect.** A Python UDF is pickled by value with cloudpickle, and the worker's Python version
  must match the client's. Spark Connect carries the pickled bytes and the Python version inside the plan message
  ([`expressions.proto`](https://github.com/apache/spark/blob/master/sql/connect/common/src/main/protobuf/spark/connect/expressions.proto),
  `PythonUDF`). *(My reading.)* This design uses the same by-value capture, but the bytes live with the environment
  and the plan holds their digest.
- **Daft and Ray Data.** A class-based UDF builds its state once per worker, and Daft sizes batches at run time.
  Here every function's captured state loads once per context, with no class needed, and the host adapts batch size
  below `max_batch_rows`. Daft derives a return type from the return hint when `return_dtype` is absent, through its
  decorator ([docs](https://docs.daft.ai/en/stable/custom-code/func/)); here the hint works with no decorator.
- **Polars.** This design reuses its verbs, `map_elements` and `map_batches`, and its rule: a lazy `map_elements`
  needs `return_dtype` ([polars#23874](https://github.com/pola-rs/polars/issues/23874)). Here a return hint is an
  alternative to the argument. `map_groups(schema=)` and PySpark's `applyInPandas(f, schema=...)` are the precedent
  for a table's `schema=`.
- **DuckDB and Snowpark.** Both register a Python function from its hints with no return-type argument
  ([DuckDB](https://duckdb.org/docs/current/clients/python/function.html),
  [Snowpark](https://docs.snowflake.com/en/developer-guide/snowpark/python/creating-udfs)).
- **JavaScript UDFs elsewhere.** BigQuery and Snowflake declare a JavaScript UDF's return type in SQL, and
  duckdb-wasm takes it as an argument; all of them take the type as a value, as this design's TypeScript verbs do.
- **Aggregate UDFs.** PySpark's grouped-aggregate pandas UDF is the plain form, with the same limit: "all data for a
  group" is loaded into memory ([guide](https://spark.apache.org/docs/latest/api/python/tutorial/sql/arrow_pandas.html)).
  DataFusion's aggregate UDFs declare input, return and state types explicitly, as the mergeable form does
  ([docs](https://datafusion.apache.org/python/user-guide/common-operations/udf-and-udfa.html)); Snowflake caps a
  Python aggregate's pickled state at 64 MB, where this design caps an Arrow state per group.
