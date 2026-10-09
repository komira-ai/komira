# Design: user code in an `OptimizedPlan` (UDF nodes and the environment image)

Status: proposed, not built. This is §10 of [`optimized_plan.md`](optimized_plan.md), kept in its own file so each
file stays under 1,000 lines. Section numbers continue that document's: `§10.x` is here, and every other `§n` is
there.

Citations are to komira `origin/main` at `8bfba390` unless marked otherwise; `git diff` from the branch point of
`optimized_plan.md` to `8bfba390` is empty for every source file cited here. Statements marked *(inferred)* are my
reading, not facts taken from the code. Nothing was built or run to write this document.

---

## 10. User code: UDF nodes and the environment image

### 10.1 Requirement

A user writes a dataframe expression locally that calls a function they wrote. It runs the same way locally and on
any host, with no decorator, no Dockerfile and no manual packaging. The function may be:

- a top-level function in a module of the user's project, installed or not;
- a function defined in a notebook cell or in `__main__`;
- a lambda or a nested function, closing over local variables;
- any of these reading a global that holds a loaded object, such as a trained model.

Decorators and type hints are optional refinements. When the user gives no type, the SDK infers it or defers it
(§10.5). It never refuses the function because a type is missing.

Two existing rules in the tree conflict with this requirement. This section replaces both for the OPTIMIZED context:

- **Closures are refused.** The wire refuses a UDF "minted from a live in-process closure" (`plan.proto:91-94`,
  `:1176-1182`), and §6.1 refuses closures.
- **The resolution key is a name.** A UDF crosses the wire as a **name** that the receiver resolves in its own
  registry (`WireUdfCall.name`, `plan.proto:791-797`; `WireUdf.name`, `:1186-1198`).

A name cannot identify a lambda or a notebook function, and a registry lookup cannot carry the variables a closure
captured. This section identifies code by **content digest**. The code bytes travel in an **environment image**
beside the plan, never in the plan.

### 10.2 Three UDF kinds

| Kind | Where it appears in the plan | The function receives | It returns |
|---|---|---|---|
| `SCALAR` | An expression, `WireUdfApply` (§10.4), anywhere a `WireExpr` may appear except a scan's pushed `filter` | One Python value per argument, per row; the host calls it in a loop over each batch | One value per row |
| `MAP_BATCHES`, column form | An expression, `WireUdfApply` | One whole batch per argument (a column) | A column of the **same length** |
| `MAP_BATCHES`, frame form | A plan node, `WireMapBatchesNode` (§10.4) | One whole batch of the input table, or one whole group when `group_by` is set | A table with any number of rows |
| `PYTHON_STEP` | A source node, `WirePythonStepNode` (§10.4) | The node's literal arguments | A table, or nothing (an empty table with no columns) |

- **The form of a `MAP_BATCHES` UDF is derived, not recorded.** It is the column form when the UDF is the target of
  a `WireUdfApply`, and the frame form when it is the target of a `WireMapBatchesNode`. A separate field would state
  the same fact twice, which §5.2's rule forbids.
- **A grouped frame call** (`group_by` set) is pandas' `groupby(...).apply(f)` and polars' `group_by(...).map_groups(f)`.
  The host calls the function once per group with all of the group's rows. If a group does not fit the worker's
  memory, the run fails with `UDF_GROUP_TOO_LARGE`, carrying the group key.
- **A frame-form function may be a generator.** Each yielded table is streamed downstream as it is produced.
- **A `PYTHON_STEP` runs exactly once per run.** It covers training, calls to external APIs and scheduled scripts.
  To fan work out over data, a plan uses a `MAP_BATCHES` node instead. A step runs under the run's identity, so the
  SDK inside the environment image can submit further plans from it as their own runs. Files it writes inside the
  container are discarded at the end of the run; durable output goes to object storage or to the step's returned
  table.

How SDK verbs map to these kinds *(informative, for the SDKs)*:

| Kind | polars-style API | pandas-style API |
|---|---|---|
| `SCALAR` | `col.map_elements(f)` | `Series.map(f)`, `Series.apply(f)`, `DataFrame.apply(f, axis=1)` |
| `MAP_BATCHES` | `col.map_batches(f)`, `LazyFrame.map_batches(f)`, `group_by(...).map_groups(f)` | `DataFrame.pipe(f)` on a lazy frame, `groupby(...).apply(f)` |
| `PYTHON_STEP` | a step verb | a step verb |

If a user calls a function directly on a column expression (`f(col("x"))`), the SDK refuses it with a message that
names the verb to use instead. NumPy ufuncs applied to an expression (`np.log1p(col("x"))`) stay legal where the
dataframe library already supports them, because they are native expressions, not UDFs.

A function defined with `async def` is a `SCALAR` or `MAP_BATCHES` UDF like any other. The host awaits its calls with
bounded concurrency (`max_concurrent_calls`, §10.8), which is the usual shape for per-row calls to an external API.

### 10.3 `UdfRef`

`UdfRef` is the type that §6.1 names, and this section defines it. Each `UdfRef` is one entry of `needs.udfs`. The
plan body refers to it by its **index** in that list, the same way `WireScanNode.pin_ref` refers to `scan_pins`
(§5.2). Neither the wire nor the IR has node ids, and an index adds none.

```proto
message UdfRef {
  UdfRuntime   runtime      = 1;   // PYTHON (closed enum; a new runtime is a new value)
  UdfKind      kind         = 2;   // SCALAR | MAP_BATCHES | PYTHON_STEP
  oneof code {
    PyInstalled installed   = 3;   // by reference to an installed distribution
    PySource    source      = 4;   // by reference into the code layer (project source)
    PyValue     value       = 5;   // by value: a serialized function object in the code layer
  }
  repeated bytes data_blobs = 6;   // sha256 of each captured value stored apart from the code (§10.6)
  BatchFormat  batch_format = 7;   // PY_VALUES | ARROW | PANDAS | POLARS | NUMPY
  WireField    return_type  = 8;   // full Arrow type, nested to any depth; unset iff resolution = FIRST_BATCH
  TypeResolution resolution = 9;   // DECLARED | OBSERVED | FIRST_BATCH (§10.5)
  UdfStability stability    = 10;  // IMMUTABLE | STABLE | VOLATILE (§10.7)
  UdfNullMode  null_mode    = 11;  // MANUAL | PROPAGATE (§10.7)
  UdfResources resources    = 12;  // §10.8
}

message PyInstalled {
  string distribution = 1;   // normalized distribution name, e.g. "scikit-learn"
  string module       = 2;   // importable module path
  string qualname     = 3;   // contains no "<locals>" and no "<lambda>"
}

message PySource {
  bytes  bundle_sha256 = 1;  // the source bundle: the .py files of the user's non-installed modules
  string module        = 2;
  string qualname      = 3;  // contains no "<locals>" and no "<lambda>"
}

message PyValue {
  bytes  payload_sha256 = 1; // the serialized function object (its closure cells, defaults, small globals)
  string serializer     = 2; // "cloudpickle/<version>"; the host's accepted set is per base release
  bytes  bundle_sha256  = 3; // the source bundle the payload imports by reference; empty if none
  bytes  source_sha256  = 4; // the function's own recovered source text; empty if unrecoverable (§10.11)
}

message UdfResources {
  AcceleratorKind accelerator  = 1;  // the closed enum of ResourceNeeds.accelerators; unset = none
  uint32  accelerators_per_worker = 2;
  uint64  worker_mem_bytes     = 3;  // 0 = the host's default per worker
  uint32  max_workers          = 4;  // 0 = the host chooses (§10.10)
  uint32  max_batch_rows       = 5;  // 0 = the host chooses; otherwise a ceiling on rows per call
  uint64  max_runtime_ms       = 6;  // PYTHON_STEP only; 0 = the host's default
  uint32  max_concurrent_calls = 7;  // async functions only; 0 = the host's default
}
```

**The installed version is advice, not identity.** `PyInstalled` names the distribution, not its version. The
version the producer captured against goes in `PlanAdvice`, and whether the function loads in a given environment is
decided by the load check (§10.11), as it is for the other two forms. So a patch upgrade of a dependency does not
invalidate a plan that references it by name.

**Diagnostics are advice, not identity.** The function's display name and origin go in `PlanAdvice` as
`repeated UdfOrigin udf_origins = 3` (`{udf_index, display_name, file, line, captured_version}`). Advice is outside the
digest (§6.3), so moving a function to another line does not change the plan.

**Identity is the canonical bytes of the `UdfRef`.** So two lambdas never collide, as two names would. Two call
sites of one function with the same arguments are one UDF. Whether one call may serve both is decided by `stability`
(§10.7), not by a salt, so `WireUdf.call_site_salt` (`plan.proto:1209-1212`) has no counterpart here.

**Nested return types.** `WireField` describes children only one level deep today (`child_names`,
`child_type_ids`, `child_nullables`, fields 13-15), which cannot express `list<fixed_size_list<float32>>` or a struct
inside a list. A new field `repeated WireField children = 16` carries children recursively; a field that sets it
leaves 13-15 empty (`PLAN_WIRE_FIELD_CHILDREN_BOTH`). It is admitted in both contexts.

### 10.4 Wire arms

The UDF arms are admitted in **both** contexts, because a bound plan stored for re-optimization (§2, §9.1) contains
UDFs too. In RAW, the `UdfRef` list comes from a new `WirePlanEnvelope` field, `repeated UdfRef udfs = 4`. In
OPTIMIZED, it comes from `needs.udfs`.

```proto
// WireExpr, new arm 27. Engine tag EXPR_UDF_APPLY = 27 (expr.mojo:337 has 26 as the highest engine tag;
// EXPR_TAG_COUNT at :359 becomes 28). ExprTag wire value 28: the wire enum is the engine tag + 1
// (plan_vocabulary.proto:101, EXPR_STRING_FN_N = 27 for engine tag 26).
message WireUdfApply {
  uint32            udf_index = 1;  // index into needs.udfs (OPTIMIZED) or WirePlanEnvelope.udfs (RAW)
  repeated WireExpr args      = 2;  // n-ary; each argument is any expression, including another WireUdfApply
}

// WirePlan, new arm 21. Engine tag PLAN_MAP_BATCHES = 19; PlanTag wire value 20.
message WireMapBatchesNode {
  WirePlan          child     = 1;
  uint32            udf_index = 2;  // the UdfRef has kind MAP_BATCHES
  repeated WireExpr group_by  = 3;  // empty: one call per batch; set: one call per group
}

// WirePlan, new arm 22. Engine tag PLAN_PYTHON_STEP = 20; PlanTag wire value 21. A source: no child.
message WirePythonStepNode {
  uint32              udf_index = 1;  // the UdfRef has kind PYTHON_STEP
  repeated WireScalar args      = 2;  // literals only; a non-literal argument is captured with the code
}
```

Rules for these arms:

- **New tags follow the exchange arm.** §5.2 gives the exchange arm engine tag `PLAN_EXCHANGE = 18` (`PlanTag` 19) at
  WirePlan field 20. The new arms take engine tags 19 and 20 (`PlanTag` 20 and 21) and fields 21 and 22, and
  `PLAN_TAG_COUNT` becomes 21. The vocabulary, the census and the enum-number tests change in the same stage.
- **`WireUdfApply` is a new arm, not a change to `WireUdfCall`.**
  - `WireUdfCall` stays as it is: unary, keyed by name, "SINGULAR, AND IT MAY NOT BECOME `repeated`"
    (`plan.proto:820-824`).
  - It stays RAW-only, together with the node-level `WireUdf` on filter, project and aggregate nodes
    (`plan.proto:1215-1249`), for in-process round trips of registered Mojo UDFs.
  - OPTIMIZED refuses both by name (`OPTIMIZED_UDF_LEGACY_FORM`).
  - §9.2 forbids changing the meaning of an existing field; adding a new arm keeps that rule.
- **Output types come from the schema that already exists.** Each node's output type is `WirePlan.output_schema`. A
  column whose type is not yet locked (§10.5) carries a new `WireField` field, `bool type_deferred = 17`, in place of
  a type. OPTIMIZED admits that mark only on a column whose lineage reaches a `FIRST_BATCH` or `OBSERVED` `UdfRef`
  (`OPTIMIZED_SCHEMA_TYPE_DEFERRED_WITHOUT_UDF`).
- **A grouped `WireMapBatchesNode` takes its distribution from exchanges, as a join does (§5.2).** On one host it
  needs no exchange. On more than one host it needs a `HASH` exchange on its input with the same keys. Any other shape
  is refused (`OPTIMIZED_UDF_GROUP_EXCHANGE_INCONSISTENT`).

### 10.5 Return types

The producer fills `return_type` and `resolution` from the first source below that applies:

1. **A declared type** (`DECLARED`): an SDK keyword (`return_dtype=`) or a decorator option.
2. **A type hint the SDK maps to Arrow** (`DECLARED`): `float` to float64, `int` to int64, `str` to large_utf8, `bool`
   to bool, and dataclasses and typed dicts to struct.
3. **A type the SDK observed** when it ran the same code locally (`OBSERVED`, §10.10). The SDK caches it under the
   `UdfRef`'s canonical bytes **with `return_type` and `resolution` cleared**, so the key does not depend on what the
   cache fills in.
4. **Otherwise `FIRST_BATCH`**, with `return_type` unset.

An `OBSERVED` type came from a sample, so it is a starting point, not a contract: the host locks a type that is at
least as wide as it (below). The optimizer treats an `OBSERVED` column exactly as a `FIRST_BATCH` one for every
decision that depends on the type, and uses the observed type only for estimates.

**One lock per run.** A `FIRST_BATCH` or `OBSERVED` type is locked once for the whole run, never per host:

- Each worker's first output batch that is not entirely null is a **proposal**. Until the lock is published, that
  worker holds its output of the UDF; nothing typed by the UDF crosses an exchange.
- The run's coordinator (on a single host, the host itself) locks the type: the widest common type of the
  `OBSERVED` type, if any, and the proposals it has received when it decides. It publishes the lock to every host and
  records it in the run record, so a replay uses the same type. *(Inferred: how long the coordinator waits for more
  proposals is a host-local tuning choice; the first proposal alone is a valid lock.)*
- Widest common type: int32 and int64 give int64; any integer and float64 give float64; structs give the union of
  their fields, with fields missing from one side nullable; anything else has no common type and fails by name
  (`UDF_RETURN_TYPE_DRIFT`).

**After the lock** the host checks every batch against it:

- A batch that fits the locked type is cast into it: integers into a float64 lock, int32 into an int64 lock, a struct
  missing a field into the locked struct with that field null.
- A batch that needs a wider type fails the run with `UDF_RETURN_TYPE_DRIFT`, naming the function, the row, the
  locked type, the observed type and the remedy (declare the type).
- A `DECLARED` type that the function violates fails with `UDF_RETURN_TYPE_MISMATCH`, after the same casts. A value
  is never coerced to a string.

**How the optimizer treats a column whose type is not declared:**

- It pushes no predicate through it.
- It chooses no typed kernel for it.
- The host binds the operators that read it, including a comparison such as `p > 0.7`, when the lock is published.
  *(Inferred: this needs operator binding at lowering-time-plus-lock rather than at plan time. The cost is in the
  engine, not in the format.)*

### 10.6 The code reference: by reference or by value

The producer chooses the form **by where the function object lives**, never by how the program was started:

| The function is… | Form | The environment image must contain |
|---|---|---|
| A top-level function of an installed, non-editable distribution | `installed` | That distribution, importable |
| A top-level function of a project module that is not installed, or is installed editable | `source` | The source bundle `bundle_sha256` |
| Anything else: `__main__`, a notebook cell, a lambda, a nested function, a closure, a `functools.partial`, a callable instance | `value` | The payload `payload_sha256`, plus the bundle it imports, if any |

Every form also needs every digest listed in `data_blobs`.

**How captured values are stored.** One pickler serializes the function and everything it reaches. Inside it:

- Installed and project modules, and the functions and classes defined in them, are pickled **by reference**. Only
  `__main__` and dynamic code are pickled by value. This holds inside captured data too: a fitted pipeline that holds
  a notebook-defined transformer carries that transformer by value.
- Every captured global or closure cell whose serialized size is above a threshold (1 MiB by default) is serialized
  **on its own** as a data blob named by its sha256 and listed in `data_blobs`. Object identity is kept across the
  split: two references to one object load as one object. This does not rely on pickle protocol 5 out-of-band
  buffers, which many model objects do not produce.
- So an unchanged captured object keeps an unchanged digest while the code around it is edited. It is uploaded once,
  and every host that already holds it reuses its cached copy.

**Digests are stable across sessions.** Before hashing, the producer normalizes what does not change the function's
behaviour: code objects' file names, first line numbers, line tables and positions are replaced by fixed values and
moved to `PlanAdvice`, and frozenset constants are written in sorted order. The worker restores the real file and line
from advice when it maps a traceback. So restarting a notebook kernel, which changes the file name the notebook gives
each cell, does not change a payload digest. Test: capture one cell in two processes with different hash seeds and
kernel file names; the digests are equal. Mutant: keep `co_filename` in the hashed bytes.

**Why there are three forms:**

- `installed` and `source` keep the function's real file and line in tracebacks. They survive a change of Python
  minor version once a producer captures the function again (§10.11). An unchanged module is shared across runs
  instead of being shipped again.
- `value` is the only form that can carry a notebook function or a closure, which §10.1 requires.

Each payload costs the producer one pickle round trip. The producer's local run loads the payload anyway (§10.10).

**Refusals, all at capture time, on the producer's machine:**

- An object that cannot move to another process is refused before pickling, with `UDF_CAPTURE_UNSUPPORTED`. This
  covers an open socket, a lock, a thread, an open file, a generator, a database connection, a cloud SDK client and a
  tensor on a device (CUDA or MPS; the error suggests moving it to the CPU). The error gives the variable's path from
  the function and the fix, for example ``score captures global `conn` (psycopg.Connection)``.
- A secret is captured as a **reference** that the host resolves under the run's identity. Its value is never
  serialized. A captured string that matches a high-confidence credential pattern (a cloud access key id, a PEM
  private-key header) is refused with `UDF_CAPTURE_CREDENTIAL` unless it is wrapped as a secret.
- A capture above a configured size is refused with `UDF_CAPTURE_TOO_LARGE`, naming the variable.

**Captured data is data.** A closure over a table read in a notebook puts that table into the environment image.
Whoever can pull the image can read it. The producer lists every captured value above the blob threshold by name,
type and size before its first upload, and marks tabular values.

**The plan carries digests, never code bytes.** Code bytes do not count against the 16 MiB budget
(`plan_wire_admit.mojo:255`). Each `UdfRef` is a few hundred bytes. *(Inferred from the field list.)*

### 10.7 Stability and nulls

These fields reuse the engine's vocabularies as wire enums: `UDF_STABILITY_*` (`src/komira_plan_expr/udf_data.mojo:165-167`)
and `UDF_NULL_*` (`:154-156`). Each enum has `*_WIRE_UNSPECIFIED = 0`, which is refused, and both fields are required
in a `UdfRef`. The SDK's defaults are part of its API, not of the format:

| Stability | Meaning to the optimizer and the host | SDK default for *(informative)* |
|---|---|---|
| `IMMUTABLE` | Same arguments, same result, in every run | A function the user marks as such |
| `STABLE` | Same arguments, same result, within one run. Calls may be merged, skipped for rows no later node reads, or repeated on a retried batch | The polars-style API's `SCALAR` and `MAP_BATCHES` |
| `VOLATILE` | Every call counts. Calls are never merged, duplicated, retried, or moved across a node that changes which rows reach them | `PYTHON_STEP` (always); the pandas-style API, whose eager semantics call the function on every row; or when the user declares it |

`UDF_NULL_SKIP_NULL_FAST_PATH` is a Mojo-registry optimization with no meaning in Python, so a `UdfRef` may not use
it.

- **`PROPAGATE`.** A null input yields a null output without a call. This is the polars-style default, as polars'
  `map_elements` skips nulls.
- **`MANUAL`.** The function is called for null inputs, and receives them in the batch format's own representation.
  This is the pandas-style default; the pandas batch format delivers what pandas' `Series.map` would (`NaN` in a float
  column, `None` or `pd.NA` in an object or nullable column).

### 10.8 Declared resources

`UdfResources` is per worker:

- `needs.resources.accelerators` must cover every `UdfRef`'s accelerator kind and count. `needs.resources.peak_mem_bytes`
  must include `worker_mem_bytes` times the worker count the producer assumed. A plan that understates either is
  refused (`OPTIMIZED_UDF_RESOURCES_UNDECLARED`).
- Accelerators are **never inferred** from the code. A user who wants a GPU says so.
- `max_batch_rows` is a ceiling. A GPU model that takes at most 256 rows per call gets at most 256; the host may pass
  fewer, and adapts batch size to the observed call latency below that ceiling (§10.10).
- A frame-form function must not depend on batch boundaries, unless the node is grouped.

### 10.9 How the optimizer treats a UDF

A UDF is opaque. The optimizer knows its arguments, its type (or that the type is not declared), its stability and
its kind. It knows nothing about its cost.

| Rewrite | `SCALAR` / column `MAP_BATCHES` | Frame `MAP_BATCHES` | `PYTHON_STEP` |
|---|---|---|---|
| Projection pushdown | Reads only its arguments | Reads every input column; pushdown stops at the node | Not applicable (source) |
| Predicate pushdown | A predicate that does not read the UDF's output may move below it, unless the UDF is `VOLATILE`. A predicate that reads the output stays above it | Stops at the node: the output rows are not the input rows | Not applicable |
| Limit pushdown | Through, unless `VOLATILE` | Stops | Not applicable |
| Conjunct order in a filter | A conjunct with a UDF goes after the conjuncts without one | — | — |
| CSE | Same `udf_index`, same arguments, not `VOLATILE`: evaluated once | Same node, not `VOLATILE`: `cse_ref` | Never |
| Scan filter | Never pushed into a scan's `filter` (`OPTIMIZED_UDF_IN_SCAN_FILTER`) | — | — |
| Cardinality | Row-preserving | Unknown: `advice` estimate with source `UNKNOWN` | Unknown |
| Partitioning and ordering | Preserved | Lost, except the grouping keys of a grouped node | None |
| Join and aggregate reordering around it | As for any projection | It is a barrier | — |

**Where each UDF is evaluated is a decision expressed by shape** (§5.2). The host does not move it, and the
post-condition (§7.3) checks it.

A limit that cannot pass a UDF means a preview such as "the first 1,000 rows of a filter on a UDF's output" may read
the whole input. That is the SDK's concern, not the format's: a preview verb caps the rows each scan reads, as polars'
`fetch` does *(informative)*.

### 10.10 Host execution

The plan runs on the engine in the base layer of its environment image (§10.11).

When the plan has UDF nodes, the engine starts **Python worker processes** from the same image, in the same container:

- **Processes, not embedded CPython.** A crash in a user's C extension cannot take the engine down, the GIL does not
  serialize workers, and memory is attributed per worker.
- **Workers are isolated from the supervisor.** They run as a separate user id, cannot read the supervisor's
  credentials or its heartbeat channel, and cannot trace or signal the engine or the supervisor. User code is the
  customer's own, but the supervisor's reports must stay the supervisor's.
- **Code loads before data is read.**
  - Each worker verifies the sha256 of every code object and data blob it loads; a mismatch is
    `OPTIMIZED_UDF_CODE_DIGEST_MISMATCH`.
  - Each worker loads each `UdfRef` **once** and keeps it across batches, so a captured model loads once per worker,
    not once per batch.
  - Loading happens in §7.2 step 9, before any data is read.
- **Worker count and threads.** The host sets the worker count from the CPU count, `max_workers`, and the memory a
  worker uses after its first load (or `worker_mem_bytes`), so N copies of a large model do not exceed the host's
  memory. It sets each worker's native thread pools (OpenMP, BLAS) to its share of the CPUs, so N workers do not each
  start one thread per CPU.
- **Batches move as Arrow C Data over shared memory.** The worker converts each batch to the function's
  `batch_format`. The engine-to-worker protocol and that conversion belong to the base release. They are not part of
  this format and carry no promise across releases, because the engine and the worker always come from the same image.
- **Batch size adapts.** Within `max_batch_rows`, the host sizes batches from observed call latency, so a slow model
  or API call reports progress and balances load. This is a host-local rule (§5.3).
- **Errors come back mapped.** A raised exception becomes `UDF_RAISED`, with the worker's traceback mapped to the
  user's file and line, or notebook cell and line. Standard error goes to the run log.
- **A crashed worker** (signal or exit) is `UDF_WORKER_CRASHED`. The host may retry the batch on a new worker only if
  the UDF is not `VOLATILE`.
- **Each call's output shape is checked.** A column-form `MAP_BATCHES` that returns a different length is
  `UDF_BATCH_LENGTH_MISMATCH`.
- **The `PYTHON_STEP` runtime limit is enforced.** A step that runs past `max_runtime_ms` is stopped with
  `UDF_STEP_TIMED_OUT`.

The worker count, thread limits and batch slicing within `max_batch_rows` and `max_workers` are host-local rules
(§5.3).

**A producer's local run uses the same path** *(informative)*. It captures the function, starts local worker
processes and loads **the captured payload, not the live object**, so a capture that would fail remotely, or a
function that depends on notebook state it did not capture, fails locally first. Capture is not the only difference
between a laptop and a host, so the local workers also run with an empty working directory and only the environment
variables a host provides, and report by name a function that opens a file outside its bundle or blobs. Two
differences remain: a UDF that assigns to a global changes the worker's copy, not the user's; and the network the
function can reach differs.

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
begins with that base's layers. The base contains:

- the engine and the producer library;
- the job supervisor (`src/komira_job_supervisor`);
- the komira Python runtime: the worker and the accepted serializers;
- one CPython minor version.

The base image's `[layers]` output lets this prefix be checked: "An image whose layers begin with these is built
FROM this one" (`packaging/images/base/README.md` in komira-ai/komira#1070, not yet on `main`). The layers the
user's side adds may contain:

- a dependency layer, or one layer per distribution;
- a code layer with the source bundles and payloads;
- data-blob layers. A large blob may be its own layer, so an unchanged blob is pulled once per host.

**Added layers write only two prefixes.** An added layer may contain paths only under `/opt/venv/` (dependencies) and
`/komira-code/` (code and data), and no whiteout. Everything else belongs to the base: its program prefixes
(`/komira/`, `/opt/kci/`), and also its C library, loader configuration and CA certificates
(`packaging/images/base/README.md` in komira-ai/komira#1070), any of which an added layer could otherwise use to run
code inside the supervisor. System libraries a dependency needs are a builder concern and land under `/opt/venv/`
too *(inferred: a relocatable install prefix; see open question 8 in §14)*.

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
3. **Same Python.** `needs.python_abi` equals the base's CPython ABI tag (for example `cp312`; a free-threaded build
   is a different tag, `cp313t`). Otherwise: `OPTIMIZED_ENV_PYTHON_ABI_MISMATCH`.
   - Patch releases within a minor may differ. *(Inferred: this relies on CPython keeping the bytecode magic number
     fixed within a released minor, which it has broken once, in 3.5.3. Each base release compares
     `importlib.util.MAGIC_NUMBER` across the patches of each minor it ships.)*

The host runs these again, and then, with the layers in hand:

4. **Code present.** Every `payload_sha256`, `bundle_sha256`, `source_sha256` and `data_blobs` digest is in the
   image's code or data layers. Otherwise: `OPTIMIZED_ENV_CODE_MISSING`, naming the digest and the UDF.
5. **Distributions present.** Every `installed` distribution is importable. Otherwise:
   `OPTIMIZED_ENV_DISTRIBUTION_MISSING`.
6. **Added layers stay in their prefixes.** Otherwise: `OPTIMIZED_ENV_RESERVED_PATH`, naming the layer and the path.

**Load check.** At §7.2 step 9 the host imports every `installed` and `source` module, loads every payload and data
blob, and refuses a failure by name before any data is read (`OPTIMIZED_UDF_CODE_UNLOADABLE`); for example, a model
pickled under one library version and loaded under another. Whoever builds an environment image may run the same
check inside the new image, with no network, before returning its digest. A module that needs the network at import
time fails that check with a message that says so.

**What each change requires.**

| Change | `installed` | `source` | `value` |
|---|---|---|---|
| New base, same Python minor, same distributions | Runs | Runs | Runs if the base accepts `serializer` and the load check passes |
| A distribution upgraded | Runs if the load check passes | Runs if the load check passes | Runs if the load check passes |
| Python minor changed | A producer re-captures: new plan | A producer re-captures: new plan | A producer re-captures from `source_sha256`, and each data blob must load under the new minor. Without recovered source, refused by name |

**Stored plans.** A party that keeps a plan for later runs keeps its environment with it:

- **A stored `OptimizedPlan`** (replayed, or kept with its cut, §9.6) runs in the image it was recorded with. The
  party that keeps the plan keeps that image (§10.12).
- **A stored bound plan, re-optimized on each run** (§2), is re-optimized by the producer library **inside the
  environment's base**, so it emits only versions that base accepts and is never refused as `OPTIMIZED_ENV_ENGINE_TOO_OLD`.
  A re-capture after a Python minor change runs the same way, in the new base, from `source_sha256`.

**Saving a stored job prefers `source`** *(informative)*:

- The SDK promotes every `value` function whose source it can recover: the function's own `def`, or the exact span of
  a lambda located from its code positions (Python 3.11 and later), never the rest of a notebook cell, which may have
  side effects. Its globals stay bound to the captured blobs.
- Before saving, the SDK runs the promoted function and the live payload on the local preview sample and blocks the
  save by name if they differ, because rebound globals, default arguments and decorators can make re-executed source
  behave differently.
- If a function's source cannot be recovered (one built with `exec`, or a lambda typed at a bare interpreter prompt),
  saving is **blocked by name**. Running it is never blocked.

### 10.12 Backward compatibility, restated for code

Three layers carry three different promises:

| Layer | Promise | Bound to |
|---|---|---|
| The plan format: `UdfRef`, the three arms, `needs.python_abi` | **Forever backward compatible** (§9). Every later engine decodes, admits and lowers every released plan that contains them, and never refuses one for its age | Nothing |
| Code and data: source bundles, payloads, blobs | They load in the environment image they were captured for, and in any other that passes §10.11 | The environment image |
| Engine to worker: the batch protocol and the format conversions | None across releases | The base layer of the same image |

The serialized function belongs to the image-bound code layer, not to the plan format. The plan holds only digests
and the serializer's name, so the plan-format promise is unchanged. Whether a payload *loads* is a property of the
environment, just as whether an `installed` module imports already is.

What §9.1's "accepts and executes" means for a UDF plan:

- **It executes, forever, with the environment image it was recorded with.** That image's base is a released base,
  and a released base is never withdrawn from the parties that keep plans recorded against it (a base revoked for a
  vulnerability is §9.7's build revocation, applied to the base's engine build). So a UDF plan is never refused for
  its age, including after its Python minor leaves the set new bases are built for.
- It also executes with any later image that passes §10.11, which is how such a plan reaches a newer engine. A
  rebuilt image is a different environment. A run record keeps both digests and any type it locked, so replaying with
  the original image reproduces the original result.

The corpus (§9.4) holds this: each UDF corpus plan is executed with an environment on the newest base of its Python
minor, so a plan whose minor new bases no longer ship still runs, on the last base that shipped it.

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
| A type lock per host | Rejected. Two hosts can lock different types for one column, and the exchanges between them disagree. |
| Exact version pins on `installed` references | Rejected. A dependency patch would invalidate the plan, while the same dependency reached through a `value` payload would not; the load check decides both. |
| Whole-environment sync instead of the import closure of the captured code | Left to the producer, not the format. The format requires only that every `installed` reference imports. |

### 10.14 Comparison

- **PySpark and Spark Connect.** A Python UDF is pickled by value with cloudpickle, and the worker's Python version
  must match the client's. Spark Connect carries the pickled bytes and the Python version inside the plan message
  ([`expressions.proto`](https://github.com/apache/spark/blob/master/sql/connect/common/src/main/protobuf/spark/connect/expressions.proto),
  `PythonUDF`). *(My reading.)* This design uses the same by-value capture, but the bytes live with the environment
  and the plan holds their digest.
- **Daft and Ray Data.** A class-based UDF builds its state once per worker, and Daft sizes batches at run time.
  Here every function's captured state loads once per worker, with no class needed, and the host adapts batch size
  below `max_batch_rows`.
- **Polars.** This design reuses its verbs, `map_elements` and `map_batches`. Polars runs the function at plan time
  to learn its type, which needs the data on the client. `FIRST_BATCH` moves that step to the host, and the run-wide
  lock keeps it one type.
