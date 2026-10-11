# Design: user code in an `OptimizedPlan` (UDF nodes and the environment image)

Status: proposed, not built. This is §10 of [`optimized_plan.md`](optimized_plan.md), kept in its own file so each
file stays under 1,000 lines. Section numbers continue that document's: `§10.x` is here, and every other `§n` is
there.

Citations are to komira `main` as merged by komira-ai/komira#977 unless marked otherwise; from the branch point of
`optimized_plan.md` to that state, no source file cited here changed. Statements marked *(inferred)* are my
reading, not facts taken from the code. Nothing was built or run to write this document.

The runtime interface a UDF runs through, and what a language implements, is
`udf_runtime_interface.md` (komira-ai/komira#1132). This section keeps the plan language-neutral to match it.

---

## 10. User code: UDF nodes and the environment image

### 10.1 Requirement

A user writes a dataframe expression locally, in Python or in TypeScript, that calls a function they wrote. It runs
the same way locally and on any host, with no Dockerfile and no manual packaging, and with no required decorator and
no wrapper class. In Python the function may be:

- a top-level function in a module of the user's project, installed or not;
- a function defined in a notebook cell or in `__main__`;
- a lambda or a nested function, closing over local variables;
- any of these reading a global that holds a loaded object, such as a trained model.

In TypeScript it may be a module-level function, or a closure or arrow function over plain data (§10.6, *TypeScript
functions*).

Further languages are added as runtimes and SDK producers (`udf_runtime_interface.md` §6) with no change to this
format.

**Three modes of UDF, one plan reference.** The plan system supports three modes of UDF. They differ in how a
runtime runs user code on several engine threads at once; in every mode, no lock is shared across engine threads, so
no engine thread ever waits on another engine thread's UDF call.

1. **Native.** Languages that compile to native code and speak the C ABI directly: Mojo, Rust, C, C++, Zig. A native
   UDF is a shared library compiled for the host platform, loaded and called through the UDF runtime C ABI over Arrow
   C Data, with no interpreter, by the one `komira/native` runtime (`udf_runtime_interface.md` §1.2). Native UDFs
   ship at the first release. They run in-process in the engine by default; the worker transport is opt-in, for
   crash isolation (§10.10).
2. **Managed, one interpreter per engine thread.** Runtimes with a global interpreter lock or a single-threaded virtual
   machine: Python on builds with a GIL, and TypeScript on Node. Each engine thread that runs a UDF operator gets its
   own interpreter or isolate: for Python, one worker process per engine thread, or a subinterpreter where the UDF's
   packages allow it; for Node, one `worker_threads` isolate per engine thread. One interpreter is never shared by
   several engine threads, so a GIL serializes only the thread that owns it.
3. **Managed, one shared parallel virtual machine.** Runtimes that run truly in parallel inside one virtual machine:
   the JVM, .NET and free-threaded Python, and later other runtimes that qualify. One virtual machine runs per process;
   each engine thread attaches to it as its own virtual-machine thread and holds its own per-thread UDF state. The
   virtual machine has no global lock. A runtime may declare this mode only if it has none: a declaration of this mode
   by a Python build with a GIL is refused.

Go is managed: a Go UDF library is built as a shared library, but it carries the Go runtime, with its garbage
collector and scheduler. It belongs to mode 3. A process holds one Go runtime (Go does not support two runtimes in one
process), every cgo call from an engine thread runs on its own operating-system thread inside that runtime, and the
runtime schedules those threads in parallel with no global lock. Each engine thread keeps its own per-thread UDF state.

The mode is a capability of the runtime, not a property of the plan. In the threading declaration of
`udf_runtime_interface.md` (komira-ai/komira#1132, §4.2), modes 1 and 2 are `CONTEXT_PER_THREAD`: one context per
engine thread, each called by one thread at a time (a Python build with a GIL that can hold only one interpreter per
process declares `SINGLE_THREAD` and reaches mode 2 through one worker process per engine thread). Mode 3 is
`THREAD_SAFE`: one virtual machine shared by the engine threads, each with its own per-thread UDF state.
**`THREAD_SAFE` requires a runtime with no global lock**; the host refuses a `THREAD_SAFE` declaration from a runtime
that has one.

All three modes are the same `UdfRef` (§10.3): an open runtime id, explicit Arrow types and a kind. All three run
through the same runtime contract and the same transports: the C ABI, called in-process or served by a worker process.
The logical, optimized and physical plans carry them identically, and nothing in this format tells the modes apart.
Crash isolation comes from the worker transport (§10.10). Privilege separation does not need it: the engine holds
only what the run itself may use, which is the user's own, and the one secret a run must not reach, the supervisor's
heartbeat token, lives in a separate process under a separate user id and never reaches the engine (§10.10).

**Every return type is explicit in the plan.** The optimizer decides predicate placement, typed kernels and every
node's output schema when the plan is built, so a type learned while the plan runs would leave those decisions open.
The user gives the type in the language's ordinary idiom: a Python type hint, or a `return_dtype=` (or `schema=`)
argument on the verb; in TypeScript, a type value passed to the verb (§10.5). A function with no type is refused by
name on the user's machine, before anything is submitted, with a message that shows the fix.

Two existing rules in the tree conflict with this requirement. This section replaces both for the OPTIMIZED context:

- **Closures are refused.** The wire refuses a UDF "minted from a live in-process closure" (`plan.proto:91-94`,
  `:1176-1182`), and §6.1 refuses closures.
- **The resolution key is a name.** A UDF crosses the wire as a **name** that the receiver resolves in its own
  registry (`WireUdfCall.name`, `plan.proto:791-797`; `WireUdf.name`, `:1186-1198`).

A name cannot identify a lambda or a notebook function, and a registry lookup cannot carry the variables a closure
captured. This section identifies code by **content digest**. The code bytes travel in an **environment image**
beside the plan, never in the plan.

### 10.2 Six UDF kinds

| Kind | Where it appears in the plan | The function receives | It returns |
|---|---|---|---|
| `SCALAR` | An expression, `WireUdfApply` (§10.4), anywhere a `WireExpr` may appear except a scan's pushed `filter`, including inside an aggregate's arguments | One value per argument, per row; the host calls it in a loop over each batch | One value per row |
| `ROW` | An expression, `WireUdfApply`, where a `SCALAR` may appear | One row object per input row, built from the declared read set only (below) | One value per row |
| `MAP_BATCHES_COLUMN` | An expression, `WireUdfApply` | One whole batch per argument (a column) | A column of the **same length** |
| `MAP_BATCHES_FRAME` | A plan node, `WireMapBatchesNode` (§10.4) | One whole batch of the input table, or one whole group when `group_by` is set | A table with any number of rows |
| `AGGREGATE` | An aggregate measure: a `WireAggExpr` with `func = AGG_UDF` whose argument is a `WireUdfApply` (§10.4) | Plain form: every row of one group, as one batch per argument. Mergeable form: the group's rows in batches, through an accumulator (below) | One value per group |
| `STEP` | A source node, `WireStepNode` (§10.4) | The node's literal arguments | A table, or nothing (an empty table with no columns) |

Every kind is runtime-neutral. Whether a runtime supports a kind is a runtime capability, checked at admission
(`OPTIMIZED_UDF_KIND_UNSUPPORTED`; the capability bit is `ROW` in `shapes`, `udf_runtime_interface.md` §4.2). At the
first release `komira/python` supports all kinds and `komira/node` all but `STEP`. *(Not yet decided: whether
`komira/node` ships `ROW` at the first release; the row proxy is staged in the Python runtime,
`udf_runtime_interface.md` §9 S4.)*

- **The kind records the call shape.** A `WireUdfApply` targets `SCALAR`, `ROW`, `MAP_BATCHES_COLUMN` or (inside
  `AGG_UDF`) `AGGREGATE`; a `WireMapBatchesNode` targets `MAP_BATCHES_FRAME`; a `WireStepNode` targets `STEP`. Any other pairing
  is refused (`OPTIMIZED_UDF_KIND_ARM_MISMATCH`). A runtime binds one argument schema per `UdfRef`, so one `UdfRef`
  cannot serve two shapes.
- **A grouped frame call** (`group_by` set) is pandas' `groupby(...).apply(f)` and polars' `group_by(...).map_groups(f)`.
  The host calls the function once per group with all of the group's rows. If a group does not fit the worker's
  memory, the run fails with `UDF_GROUP_TOO_LARGE`, carrying the group key.
- **A frame-form function may be a generator.** Each yielded table is streamed downstream as it is produced.
- **A `STEP` runs exactly once per run.** It covers training, calls to external APIs and scheduled scripts.
  To fan work out over data, a plan uses a `MAP_BATCHES_FRAME` node instead. A step runs under the run's identity, so the
  SDK inside the environment image can submit further plans from it as their own runs. Files it writes inside the
  container are discarded at the end of the run; durable output goes to object storage or to the step's returned
  table.

**An `AGGREGATE` UDF has two forms.** The plan tells them apart by `UdfRef.state_type` (§10.3): unset for the plain
form, set for the mergeable form.

- **Plain form, the default.** A function over a whole group, such as `def p95(v: npt.NDArray[np.float64]) -> float`.
  The host calls it once per group with all of the group's rows, after a `HASH` exchange on the group keys (§10.4), so
  the optimizer cannot split it into partial and final steps. The whole group must fit one worker's memory; otherwise
  the run fails with `UDF_GROUP_TOO_LARGE`, carrying the group key. Spilling does not help, because the function needs
  every row at once. With no group keys there is one group, and an empty input calls the function once with empty
  batches, as a SQL aggregate returns one row.
- **Mergeable form, for decomposable aggregates at scale.** The code is a zero-argument factory, usually a class, whose
  instances have `update(batch)`, `merge(state)`, `state()` and `finish()`. The host creates one accumulator per group
  and calls `update` with the group's rows in batches. The optimizer may split the aggregate into `PARTIAL` and
  `FINAL` (§5.2 `mode`): the partial step emits `state()` as an Arrow value of type `state_type`, which crosses the
  exchange as an ordinary column with no pickle in the shuffle, and the final step `merge`s the partial states and
  calls `finish()`. At the first release one group's state is capped at a fixed 64 MiB (67,108,864 bytes of Arrow
  state), the same on every host and not settable by a plan. A group whose state exceeds it fails the run with
  `UDF_STATE_TOO_LARGE`, carrying the group key and the cap. Making the cap tunable is tracked in komira-ai/komira#1148;
  `UdfResources.max_state_bytes` (§10.3) is reserved for it.

**Table functions need no kind of their own.** A function that returns a table of any length is
`MAP_BATCHES_FRAME`, which may be a generator, or a grouped one. A per-row table function is a `SCALAR` UDF that returns a
list, followed by an explode.

**A `ROW` UDF stays columnar.** A row-shaped function (`df.map_rows(f)`, pandas `DataFrame.apply(f, axis=1)`) reads
the fields of one row object by name. Handed the whole row, it would make every column of its input live and defeat
projection pushdown, so the `ROW` `UdfRef` declares the fields it reads, and nothing else reaches it
(`udf_runtime_interface.md` §3.1):

- **The read set is `arg_types`** (§10.3): one entry per field, whose `WireField.name` is the name user code reads and
  whose type is that column's explicit Arrow type. The call site's `WireUdfApply` passes one argument per entry, in
  the same order, usually a column reference; the argument binds the name by position, so a rename below the call
  does not change the `UdfRef`.
- **The producer determines it when the plan is built, never a host.** It takes the first of: `columns=[...]` on the
  verb; otherwise the union of a *recording row proxy* during the local run (§10.10), which records each field read,
  and static analysis of the function's field accesses where the SDK has one (an earlier engine recorded reads this
  way, `Row.accessed_column_names()`); otherwise every input column. A function that iterates the row, converts it to
  a dict or tuple, unpacks it or passes it whole to other code marks the read set as undetermined, and so does a local
  run that saw no rows with no static result: the producer then declares every input column, which is correct and
  slower, and says so in its local diagnostics. `columns=[...]` naming a column the input lacks is refused on the
  user's machine (`UDF_ROW_COLUMN_UNKNOWN`).
- **The runtime builds rows from those columns only**, per batch, inside the runtime: a lazy row view over the
  argument struct's children. A read of any other field fails the batch with `UDF_FIELD_NOT_DECLARED`, naming the
  field, the read set and the row, with the fix-it "add it to `columns=[...]`". It never yields a null, and it fails
  even if user code catches the language's exception. It is never retried: the same batch fails the same way. A field
  read only on a branch the local run did not take is the case this catches.
- **A `ROW` UDF is `MANUAL`** (§10.7). Under `PROPAGATE`, a null in a field read only on some branches would drop
  rows the function would have computed.
- **Output.** One value of `return_type` per row, as for `SCALAR`. A function that returns several values per row (a
  tuple from `map_rows`) declares a struct, which the producer unpacks into columns with ordinary field access.

**GPU UDFs come later.** At the first release a UDF runs on CPUs only. The accelerator fields of `UdfResources`
(§10.3) are not in the first `format_version`, and the SDK refuses a request for a GPU by name
(`UDF_ACCELERATOR_UNSUPPORTED`). GPU UDFs are added under a later `format_version` (§9.2).

How SDK verbs map to these kinds *(informative, for the SDKs)*:

| Kind | polars-style API (Python) | pandas-style API (Python) | TypeScript API |
|---|---|---|---|
| `SCALAR` | `col.map_elements(f)` | `Series.map(f)`, `Series.apply(f)` | `col.mapElements(f, dtype)` |
| `ROW` | `df.map_rows(f)` | `DataFrame.apply(f, axis=1)` | not yet decided |
| `MAP_BATCHES_COLUMN` | `col.map_batches(f)` | — | `col.mapBatches(f, dtype)` |
| `MAP_BATCHES_FRAME` | `LazyFrame.map_batches(f)`, `group_by(...).map_groups(f)` | `DataFrame.pipe(f)` on a lazy frame, `groupby(...).apply(f)` | `df.mapBatches(f, {schema})`, `groupBy(...).mapGroups(f, {schema})` |
| `AGGREGATE` | `group_by(...).agg(col.agg_udf(f))` | `groupby(...).agg(f)` | `groupBy(...).agg(col.aggUdf(f, dtype))` |
| `STEP` | a step verb | a step verb | none |

If a user calls a function directly on a column expression (`f(col("x"))`), the SDK refuses it with a message that
names the verb to use instead. NumPy ufuncs applied to an expression (`np.log1p(col("x"))`) stay legal where the
dataframe library already supports them, because they are native expressions, not UDFs.

A function defined with `async def`, or a TypeScript function that returns a `Promise`, is a `SCALAR`, `ROW`,
`MAP_BATCHES_COLUMN` or `MAP_BATCHES_FRAME` UDF like any other. The host awaits its calls with bounded concurrency (`max_concurrent_calls`, §10.8),
which is the usual shape for per-row calls to an external API.

### 10.3 `UdfRef`

`UdfRef` is the type that §6.1 names, and this section defines it. Each `UdfRef` is one entry of `needs.udfs`. The
plan body refers to it by its **index** in that list, the same way `WireScanNode.pin_ref` refers to `scan_pins`
(§5.2). Neither the wire nor the IR has node ids, and an index adds none.

```proto
message UdfRef {
  UdfKind      kind         = 2;   // a call shape, never a language (§10.2)
  UdfCode      code         = 16;  // which runtime, which entry, which code objects (below)
  repeated WireField arg_types = 17;  // declared argument types, in call order (§10.4); for ROW, the read set
  repeated bytes data_blobs = 6;   // sha256 of each captured value stored apart from the code (§10.6)
  WireField    return_type  = 8;   // required: full Arrow type, nested to any depth (§10.5); a table is a struct
  reserved 9; reserved "resolution";  // a draft's type-resolution mark; types are always explicit (§10.5)
  UdfStability stability    = 10;  // IMMUTABLE | STABLE | VOLATILE: the determinism declaration (§10.7)
  UdfNullMode  null_mode    = 11;  // MANUAL | PROPAGATE (§10.7)
  UdfResources resources    = 12;  // §10.8
  WireField    state_type   = 15;  // AGGREGATE only: set iff the mergeable form (§10.2); explicit Arrow type
  bool         preserves_event_time = 18;  // MAP_BATCHES_FRAME only: event time passes through (below)
  reserved 1, 3, 4, 5, 7, 13, 14;  // an earlier draft's runtime enum, per-language code arms and batch_format
  reserved "runtime", "installed", "source", "value", "batch_format", "js_module", "js_value";
}

enum UdfKind {
  UDF_KIND_UNSPECIFIED = 0;   // refused
  SCALAR               = 1;
  MAP_BATCHES_COLUMN   = 2;   // target of a WireUdfApply; output length = input length
  AGGREGATE            = 3;   // plain or mergeable, decided by state_type
  STEP                 = 4;   // source node, runs once per run
  MAP_BATCHES_FRAME    = 5;   // target of a WireMapBatchesNode; any number of output rows
  ROW                  = 6;   // target of a WireUdfApply; one row object per input row, built from arg_types only
}

message UdfCode {
  string   runtime            = 1;  // open, namespaced id: "komira/python", "komira/node", "example.org/go"
  CodeForm form               = 2;  // PACKAGE | BUNDLE | VALUE; the only code fact the format reads
  string   entry              = 3;  // the runtime's entry reference, e.g. "pkg.mod:qualname", "dist/m.js#score"
  repeated CodeDigest code    = 4;  // every code object the entry needs, by role and sha256
  uint32   descriptor_version = 5;  // version of the runtime's descriptor schema; 0 means "no descriptor"
  bytes    descriptor         = 6;  // runtime-owned canonical bytes: serializer, batch format, package name...
}

message CodeDigest {
  string role   = 1;  // runtime-defined label: "bundle", "payload", "source", "captures"
  bytes  sha256 = 2;  // 32 bytes
}

enum CodeForm {
  CODE_FORM_UNSPECIFIED = 0;  // refused
  PACKAGE = 1;  // by reference to an installed package in the dependency layer; `entry` names it
  BUNDLE  = 2;  // by reference into a code-layer bundle (source or compiled artifact); `entry` is inside it
  VALUE   = 3;  // by value: a serialized function object in the code layer
}

message UdfResources {
  AcceleratorKind accelerator  = 1;  // not in the first format_version: GPU UDFs come later (§10.2)
  uint32  accelerators_per_worker = 2;  // likewise
  uint64  worker_mem_bytes     = 3;  // 0 = the host's default per worker
  uint32  max_workers          = 4;  // 0 = the host chooses (§10.10)
  uint32  max_batch_rows       = 5;  // 0 = the host chooses; otherwise a ceiling on rows per call
  uint64  max_runtime_ms       = 6;  // STEP only; 0 = the host's default
  uint32  max_concurrent_calls = 7;  // async functions only; 0 = the host's default
  uint64  max_state_bytes      = 8;  // not in the first format_version: the per-group state cap is fixed
                                     // at 64 MiB (§10.2); tuning it is komira-ai/komira#1148
}
```

These are the messages of `udf_runtime_interface.md` §3.1. Nothing here has shipped in a `format_version`, so the
draft's fields are reserved by the rule for fields removed before any release (§9.2).

**`ROW` adds an enum value and no field.** `ROW = 6` is a new `UdfKind` value whose number no release has carried;
under §9.2 it is added, never renumbered, and ships with the other UDF arms (§10.12, *Format version*). The read set
needs no field number of its own: it is the bound argument schema, which `arg_types` (field 17, itself never released)
already carries. A separate `read_set` field would state that schema twice (§10.13).

**`preserves_event_time`: a frame UDF that keeps event time.** In a streaming plan a node's event-time column and
watermark are derived by fixed rules (`plan_models.md` §3.2, komira-ai/komira#1169). `SCALAR`, `ROW` and
`MAP_BATCHES_COLUMN` keep their input rows, so event time passes through them unchanged. A `MAP_BATCHES_FRAME` UDF
may emit any rows, so its output carries no event time unless its `UdfRef` sets `preserves_event_time`: the UDF
declares that it keeps the event-time column and that the input's watermark holds for its output. The output watermark
is then the input's wherever the column is kept. On every other kind the field is false, so the canonical form (§7.1)
has one encoding. It is inside the identity bytes, like every field here. Number 18 is the next free one and was never
released; the field is added under the `format_version` that adds the streaming forms (§5.2, §9.2).

**The runtime is a string the format never enumerates.** `code.runtime` is an open, namespaced string
(`udf_runtime_interface.md` §3.1); the format never enumerates runtimes. Plan validation checks its grammar
(`OPTIMIZED_UDF_RUNTIME_MALFORMED`), that `form` is set, that a `PACKAGE` `entry` is non-empty, and that every
`code.code[i].sha256` is 32 bytes. Which forms and descriptors a runtime accepts is decided by its `validate`
(`OPTIMIZED_UDF_DESCRIPTOR_INVALID`, at host admission). Each descriptor has a canonical encoding and `validate`
refuses other bytes, so identity is stable.

**The runtime's ABI tag is not part of identity.** `UdfCode` carries no ABI tag (`cp312`, `node22`); the tag lives
only in `needs.runtimes` (§6.1). A form whose bytes really are ABI-specific (a pickled payload) records that in its
descriptor, and the runtime's `validate` refuses a mismatch.

**The installed version is advice, not identity.** A `PACKAGE` reference names the package, not its version. The
version the producer captured against goes in `PlanAdvice`, and whether the function loads in a given environment is
decided by the load check (§10.11), as it is for the other two forms. So a patch upgrade of a dependency does not
invalidate a plan that references it by name.

**Diagnostics are advice, not identity.** The function's display name and origin go in `PlanAdvice` as
`repeated UdfOrigin udf_origins = 3` (`{udf_index, display_name, file, line, captured_version}`). Advice is outside the
digest (§6.3), so moving a function to another line does not change the plan.

**Identity is the canonical bytes of the `UdfRef`.** So two lambdas never collide, as two names would. Two call
sites of one function with the same arguments are one UDF. Whether one call may serve both is decided by `stability`
(§10.7), not by a salt, so `WireUdf.call_site_salt` (`plan.proto:1209-1212`) has no counterpart here. The runtime
id and descriptor are inside those bytes, so a runtime id is never renamed. The runtime's ABI tag is not, so
recapturing a reference under a new interpreter minor keeps its identity.

**Nested return types.** `WireField` describes children only one level deep today (`child_names`,
`child_type_ids`, `child_nullables`, fields 13-15), which cannot express `list<fixed_size_list<float32>>` or a struct
inside a list. A new field `repeated WireField children = 16` carries children recursively; a field that sets it
leaves 13-15 empty (`PLAN_WIRE_FIELD_CHILDREN_BOTH`). It is admitted in both contexts. An earlier draft of this
design numbered a deferred-type mark `type_deferred = 17`; types are now always explicit (§10.5), so `WireField`
reserves that number and name (`reserved 17; reserved "type_deferred";`), by the rule for fields removed before any
release (§9.2).

**Informative: the `komira/python` and `komira/node` descriptors.** An earlier draft of this section defined one
message per language code form (`PyInstalled`, `PySource`, `PyValue`, `JsModule`, `JsValue`). They are not part of
the format. Each is now a `CodeForm` plus the runtime's own `entry`, code roles and descriptor:

| Draft message | `form` | `entry` | `code` roles | Descriptor |
|---|---|---|---|---|
| `PyInstalled` | `PACKAGE` | `"<module>:<qualname>"` | — | `{distribution}` |
| `PySource` | `BUNDLE` | `"<module>:<qualname>"` | `"bundle"` | — |
| `PyValue` | `VALUE` | — | `"payload"`, optional `"bundle"` and `"source"` | `{serializer, python_abi}` |
| `JsModule` | `BUNDLE` | `"<module>#<export_name>"` | `"bundle"` | — |
| `JsValue` | `VALUE` | — | `"source"`, optional `"captures"` and `"bundle"` | `{serializer}` |

- The draft's `BatchFormat` (`PY_VALUES`, `ARROW`, `PANDAS`, `POLARS`, `NUMPY`, `JS_VALUES`) becomes a field of each
  runtime's descriptor: `komira/python` records `ARROW`, `PANDAS`, `POLARS`, `NUMPY` or `VALUES`; `komira/node`
  records Arrow or its values format.
- A Python `qualname` in an `entry` contains no `<locals>` and no `<lambda>`; such a function is captured as `VALUE`.
- `serializer` names a version (`"cloudpickle/<version>"`, `"v8-structured-clone/<version>"`). The host's accepted set
  is per base release, and the runtime's `validate` refuses a serializer outside it.

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
}                                   // the UdfRef has kind SCALAR, ROW, MAP_BATCHES_COLUMN, or AGGREGATE inside AGG_UDF

// WirePlan, new arm 21. Engine tag PLAN_MAP_BATCHES = 19; PlanTag wire value 20.
message WireMapBatchesNode {
  WirePlan          child     = 1;
  uint32            udf_index = 2;  // the UdfRef has kind MAP_BATCHES_FRAME
  repeated WireExpr group_by  = 3;  // empty: one call per batch; set: one call per group
}

// WirePlan, new arm 22. Engine tag PLAN_STEP = 20; PlanTag wire value 21. A source: no child.
message WireStepNode {
  uint32              udf_index = 1;  // the UdfRef has kind STEP
  repeated WireScalar args      = 2;  // literals only; a non-literal argument is captured with the code
}

// AggFn, new value AGG_UDF = 38; engine tag AGG_UDF = 37 (src/komira_plan_expr/agg_expr.mojo:403 has 36,
// AGG_KURTOSIS_POP, as the highest; the wire value is the engine tag + 1). No new message: a WireAggExpr with
// func = AGG_UDF carries one argument, child0, which is a WireUdfApply naming an AGGREGATE UdfRef.
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
- **Output types come from the schema that already exists, and they are always concrete.** Each node's output type
  is `WirePlan.output_schema`. A UDF's output column has the type of its `UdfRef.return_type`; a
  `MAP_BATCHES_FRAME` node and a `STEP` node output the columns of that struct. A `UdfRef` without `return_type`
  (`OPTIMIZED_UDF_RETURN_TYPE_MISSING`), an `AGGREGATE` mergeable form without `state_type`
  (`OPTIMIZED_UDF_STATE_TYPE_MISSING`) and a schema that disagrees with the `return_type` it derives from
  (`OPTIMIZED_UDF_SCHEMA_DISAGREES`) are refused. `WireField` gains only `children` (§10.3).
- **Argument types are exact.** Each argument's type equals `arg_types[i]` exactly; the producer inserts any cast
  (`OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`). For a `MAP_BATCHES_FRAME` node, and for an `AGGREGATE` over several
  columns, each input column is one entry, in input order; for a `STEP`, `arg_types` lists the types of its literal
  arguments; for a `ROW`, `arg_types` is the read set and the call passes exactly one argument per entry.
- **A `ROW` UdfRef is checked at plan validation.** Every `arg_types` name is non-empty and no name repeats
  (`OPTIMIZED_UDF_ROW_READ_SET_INVALID`), and `null_mode` is `MANUAL` (`OPTIMIZED_UDF_ROW_NULL_MODE`). At host
  admission (§10.11 check 7) its runtime must declare `ROW` in `shapes` (`OPTIMIZED_UDF_KIND_UNSUPPORTED`).
- **An `AGGREGATE` UdfRef is admitted only as an aggregate measure**, as `child0` of a `WireAggExpr` with
  `func = AGG_UDF`, and that measure names only an `AGGREGATE` UdfRef. Anything else is refused
  (`OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE`).
- **A grouped `WireMapBatchesNode`, and an aggregate node with a plain-form `AGGREGATE` measure, take their
  distribution from exchanges, as a join does (§5.2).** On one host they need no exchange. On more than one host they
  need a `HASH` exchange on their input with the same keys (a `GATHER` exchange when the aggregate has no group keys).
  Any other shape is refused (`OPTIMIZED_UDF_GROUP_EXCHANGE_INCONSISTENT`). Such an aggregate node has
  `mode = SINGLE`; a `PARTIAL` or `FINAL` node with a plain-form measure is refused
  (`OPTIMIZED_UDF_AGGREGATE_NOT_DECOMPOSABLE`). A mergeable-form measure may be split like any built-in aggregate.

### 10.5 Return types

**Every UDF's return type is in the plan before it is submitted.** The plan cannot be built without it: each node's
output schema, each predicate placement and each typed kernel is decided from it. Polars reached the same
answer: since 1.32 a lazy `map_elements` without `return_dtype` is an error, where it used to guess by calling the
function on dummy data ([polars#23874](https://github.com/pola-rs/polars/issues/23874)). So `return_type` is
required, and there is no type learned while the plan runs, no type lock and no late binding of the operators that
read a UDF's output.

The user writes the type once, in the ordinary idiom of the language. Neither SDK needs a decorator or a wrapper class
to carry it.

**Python.** The producer takes the first of these that applies *(the verbs are informative, for the SDK)*:

1. **An argument on the verb:** `return_dtype=` for a column, `schema=` for a table (a `MAP_BATCHES_FRAME`, a
   grouped one, or a step), `state_dtype=` for a mergeable aggregate's state. `return_dtype=same_as_input` (polars'
   `self_dtype()`) is resolved by the producer to the argument's type, so the plan still holds a concrete type.
2. **The function's type hints,** read with `typing.get_type_hints`, which also resolves the string annotations of
   `from __future__ import annotations`. The return hint gives the type; a parameter hint of a batch type chooses the
   Python descriptor's batch format; the shape of the hints (a batch in, a scalar out) marks a plain aggregate; the return hint of
   `state()` gives a mergeable aggregate's `state_type`. A row type (a `TypedDict` or a dataclass) in
   `-> Iterator[Row]` can stand in for `schema=`.
3. **Otherwise the producer refuses** (below). A lambda cannot carry hints, so a lambda always takes `return_dtype=`.

For a `ROW` verb the return type comes the same way; the read set's types are the input columns' types, which the
producer knows when the plan is built, so `columns=[...]` takes names only.

```python
def score(x: float) -> float: ...
col("x").map_elements(score)                                        # the hint is the type
col("x").map_elements(lambda v: v * 2, return_dtype=kt.Float64)     # a lambda carries the type on the verb
def norm(v: npt.NDArray[np.float64]) -> npt.NDArray[np.float32]: ...
col("v").map_batches(norm)                                          # parameter hint: NUMPY; return: float32
df.group_by("k").map_groups(fit, schema={"k": kt.Int64, "coef": kt.Float64})
```

Arrow is the only type in the plan; these tables are the `komira/python` and `komira/node` runtimes' own mappings
(`udf_runtime_interface.md` §6.2).

| Hint | Arrow type |
|---|---|
| `float`, `int`, `bool` | float64, int64, bool |
| `str`, `bytes` | large_utf8, large_binary |
| `datetime.date`, `datetime.datetime` | date32, timestamp[us] with no time zone |
| `list[T]`, `dict[str, T]` | large_list<T>, map<utf8, T> |
| `T \| None` | T. A type taken from a hint is always nullable, because `PROPAGATE` (§10.7) yields nulls whatever the hint says |
| a `TypedDict` or a dataclass | struct, recursively (`WireField.children`, §10.3) |
| `npt.NDArray[np.<dtype>]` | that primitive type, as a batch |
| `pa.Array`, `pl.Series`, `pd.Series` as a **parameter** | no type; chooses the Python descriptor's batch format: `ARROW`, `POLARS` or `PANDAS` |

**TypeScript.** Types do not exist when TypeScript runs: the compiler and every type-stripping loader erase them, so
an annotation can never reach the plan. The verb therefore takes the type as a **value**, `kt.Float64` or
`kt.struct({...})`, and the static type is inferred from that value, so the compiler still rejects a function whose
return type disagrees with it. The user writes the type once.

```ts
df.withColumns({ p: col("x").mapElements((x: number) => score(x), kt.Float64) });
const Row = kt.struct({ id: kt.Int64, tags: kt.list(kt.Utf8) });   // kt.Infer<typeof Row> is its TS type
df.groupBy("k").mapGroups(fit, { schema: Row });
```

JavaScript numbers are doubles. An int64 argument arrives as a `bigint`. A `number` returned into an int64 column is
accepted while it is a safe integer; otherwise the batch fails with `UDF_RETURN_TYPE_MISMATCH`.

**Refused by name when the plan is built, on the user's machine:**

- `UDF_RETURN_TYPE_MISSING`: no argument and no return hint. The message shows both fixes, for example "`score()` has
  no return type. Annotate it (`def score(x: float) -> float`) or pass `return_dtype=` to `map_elements`", and says
  that a lambda takes `return_dtype=`, or `return_dtype=same_as_input` when the type does not change.
- `UDF_RETURN_TYPE_UNMAPPABLE`: a hint that names no single Arrow type: `pd.Series`, `pa.Array` or `np.ndarray` as a
  return (no element type), `Any`, `object`, `Decimal` (no precision), a time-zone-aware timestamp (the hint cannot
  say which zone) and a union such as `int | float`. The message names the hint and the fix (`return_dtype=`, or
  `npt.NDArray[...]`).
- `UDF_ARGUMENT_TYPE_MISMATCH`: a parameter hint that disagrees with the argument column's type, such as `x: int`
  over a float64 column. Parameter hints are optional; when present they are checked.

**At run time** the host checks every batch against `return_type`. A batch is cast into it only by a safe cast:
integers into float64, a narrower integer into a wider one, a struct missing a nullable field into the struct with
that field null. A batch that needs any other cast (a float into int64), or a null in a type declared non-nullable
through `return_dtype=` or `schema=`, fails the run with `UDF_RETURN_TYPE_MISMATCH`, naming the function, the row,
the declared type and the type it returned. A value is never coerced to a string. The producer's local run uses the
same worker path (§10.10), so a mismatch fails on the user's machine first.

`state_type` is checked the same way at each `state()` call. `WireUdfApply` needs no type field of its own: its type
is the `return_type` of its `udf_index`, and `WirePlan.output_schema` shows it.

### 10.6 The code reference: by reference or by value

The producer chooses the form **by where the function object lives**, never by how the program was started.

**Python functions:**

| The function is… | Form | The environment image must contain |
|---|---|---|
| A top-level function of an installed, non-editable distribution | `PACKAGE` | That distribution, importable |
| A top-level function of a project module that is not installed, or is installed editable | `BUNDLE` | The source bundle (code role `"bundle"`) |
| Anything else: `__main__`, a notebook cell, a lambda, a nested function, a closure, a `functools.partial`, a callable instance | `VALUE` | The payload (code role `"payload"`), plus the bundle it imports, if any |

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

**Why Python has three forms:**

- `PACKAGE` and `BUNDLE` keep the function's real file and line in tracebacks. They survive a change of Python
  minor version once a producer captures the function again (§10.11). An unchanged module is shared across runs
  instead of being shipped again.
- `VALUE` is the only form that can carry a notebook function or a closure, which §10.1 requires.

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

**TypeScript functions.** The TypeScript SDK runs on Node, where the engine runs as a Node addon. It captures a
function in one of two forms:

| The function is… | Form | The environment image must contain |
|---|---|---|
| A module-level exported function | `BUNDLE` | The bundle (code role `"bundle"`) |
| A closure or an arrow function whose captured variables are plain data or module bindings | `VALUE` | Its source, its captures, and the bundle its module bindings resolve into |

- **The bundle and the dependencies.** JavaScript dependencies live in the environment image, never in the plan, in
  one of two places by what they contain:
  - **Pure JavaScript.** The SDK bundles the function's module and everything it imports, its pure-JavaScript npm
    dependencies included, into one JavaScript bundle (esbuild, *informative*), named by its sha256, in the code
    layer under `/komira-code/`.
  - **A package with a native addon** stays outside the bundle (marked external), because an addon built on the
    user's machine is built for that machine's platform. The SDK records its name and exact version from the
    project's lockfile, and the image builder installs it for the host's platform into `komira/node`'s environment
    directory, `/opt/env/komira/node/` (§10.11), as Python wheels are resolved for Linux. The runtime resolves the
    bundle's external imports there. A package with no build for the host's platform is refused by name when the
    image is built (`ENV_BUILD_NATIVE_ADDON_UNAVAILABLE`), and an image that lacks it fails the load check
    (`OPTIMIZED_UDF_CODE_UNLOADABLE`, §10.11).
- **Closures.** JavaScript gives a program no access to a closure's variables, and a function's source text alone
  cannot recover them ([Arquero](https://idl.uw.edu/arquero/api/expressions) refuses closures for that reason). The
  SDK reads them through the V8 inspector, the way Pulumi's `serializeFunction` does
  ([docs](https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/functions/runtime.serializeFunction.html)).
  The inspector also gives a function's source location, which is how the SDK finds the module to bundle. Each
  captured variable is taken by one rule:
  - a binding imported from a module, or a module-level function, is captured **by reference** into the bundle;
  - a captured closure is captured by the same rules, recursively;
  - a value that survives a structured clone (numbers, bigints, strings, booleans, plain objects and arrays, `Map`,
    `Set`, `Date`, typed arrays) is captured **by value** into the `"captures"` code object; a value above the blob threshold
    goes into `data_blobs`, as in Python;
  - anything else (a client, a socket, a class instance with native state, a native function) is refused with
    `UDF_CAPTURE_UNSUPPORTED`, naming the variable.
- **Node only, for both forms.** The SDK captures only on Node: the inspector is a Node facility, and the bundle is
  resolved and run against Node. A producer on another JavaScript runtime (Bun, Deno, a browser) is refused by name
  (`UDF_CAPTURE_RUNTIME_UNSUPPORTED`), for the `BUNDLE` form and the `VALUE` form alike. Reading closures this way depends on V8 internals
  that have changed between Node releases ([pulumi#11488](https://github.com/pulumi/pulumi/issues/11488)), so
  each Node major a base ships is tested against the corpus (§9.4).
- **Source is always recoverable.** Both forms carry source text, so a stored TypeScript UDF can always be captured
  again under a newer Node (§10.11).

Secrets, credential patterns and capture size limits follow the Python rules above.

**Captured data is data.** A closure over a table read in a notebook puts that table into the environment image.
Whoever can pull the image can read it. The producer lists every captured value above the blob threshold by name,
type and size before its first upload, and marks tabular values.

**The plan carries digests, never code bytes.** Code bytes do not count against the 16 MiB budget
(`plan_wire_admit.mojo:255`). Each `UdfRef` is a few hundred bytes. *(Inferred from the field list.)*

### 10.7 Stability and nulls

These fields reuse the engine's vocabularies as wire enums: `UDF_STABILITY_*` (`src/komira_plan_expr/udf_data.mojo:165-167`)
and `UDF_NULL_*` (`:154-156`). Each enum has `*_WIRE_UNSPECIFIED = 0`, which is refused, and both fields are required
in a `UdfRef`. `stability` is the UDF's determinism declaration; there is no separate field. The SDK's defaults are
part of its API, not of the format:

| Stability | Meaning to the optimizer and the host | SDK default for *(informative)* |
|---|---|---|
| `IMMUTABLE` | Same arguments, same result, in every run | A function the user marks as such |
| `STABLE` | Same arguments, same result, within one run. Calls may be merged, skipped for rows no later node reads, or repeated on a retried batch | The polars-style API's and the TypeScript API's `SCALAR`, `ROW`, `MAP_BATCHES_COLUMN`, `MAP_BATCHES_FRAME` and `AGGREGATE` |
| `VOLATILE` | Every call counts. Calls are never merged, duplicated, retried, or moved across a node that changes which rows reach them | `STEP` (always: a plan rule, below); the pandas-style API, whose eager semantics call the function on every row; or when the user declares it |

A `STEP` `UdfRef` that is not `VOLATILE` is refused (`OPTIMIZED_UDF_STEP_NOT_VOLATILE`).

`UDF_NULL_SKIP_NULL_FAST_PATH` is a Mojo-registry optimization with no meaning in Python or Node, so a `UdfRef` may
not use it.

- **`PROPAGATE`.** A null input yields a null output without a call. This is the polars-style default, as polars'
  `map_elements` skips nulls.
- **`MANUAL`.** The function is called for null inputs, and receives them in the batch format's own representation.
  This is the pandas-style default; the pandas batch format delivers what pandas' `Series.map` would (`NaN` in a float
  column, `None` or `pd.NA` in an object or nullable column). In the Node runtime's values format a null is `null`.
- **A `ROW` UDF is always `MANUAL`** (§10.2; `OPTIMIZED_UDF_ROW_NULL_MODE`). Each field it reads arrives null as the
  row object's language represents it.
- **For an `AGGREGATE` UDF**, `PROPAGATE` drops rows whose arguments are null before the call, as a SQL aggregate
  ignores nulls, and `MANUAL` passes them.

**Delivery.** A call to a non-`VOLATILE` UDF is at-least-once: a batch may be retried after a worker crash, so a
function with side effects should be `VOLATILE`. When a call raises, the host bisects a non-`VOLATILE` batch to the
first failing row and then fails the run (`UDF_RAISED`, naming the row); a `VOLATILE` batch is not called again, and
the run fails naming the batch.

### 10.8 Declared resources

`UdfResources` is per worker:

- `needs.resources.peak_mem_bytes` must include `worker_mem_bytes` times the worker count the producer assumed. A
  plan that understates it is refused (`OPTIMIZED_UDF_RESOURCES_UNDECLARED`). When GPU UDFs are added (§10.2),
  `needs.resources.accelerators` must likewise cover every `UdfRef`'s accelerator kind and count.
- Accelerators are **never inferred** from the code. A user who wants a GPU will say so.
- `max_batch_rows` is a ceiling. A model that takes at most 256 rows per call gets at most 256; the host may pass
  fewer, and adapts batch size to the observed call latency below that ceiling (§10.10).
- A `MAP_BATCHES_FRAME` function must not depend on batch boundaries, unless the node is grouped.
- The result of a `SCALAR`, `ROW` or `MAP_BATCHES_COLUMN` call on a row does not depend on which instance serves it or on
  where batches were split. A function may cache; a function whose per-row result depends on earlier calls is not
  expressible at this format version.

### 10.9 How the optimizer treats a UDF

A UDF is opaque. The optimizer knows its arguments, its return type, its stability and its kind. It knows nothing about
its cost. Because every return type is explicit (§10.5), a predicate on a UDF's output is typed when the plan is built
and gets a typed kernel like any other.

**Conditional evaluation.** A UDF call is evaluated only on rows for which every enclosing conditional selects its
branch (`CASE`, `coalesce`, the right-hand side of `AND`/`OR`), and only on rows that survive earlier conjuncts; the
host compacts the selected rows before the call and scatters after. The conjunct-order row below relies on it.

| Rewrite | `SCALAR` / `ROW` / `MAP_BATCHES_COLUMN` | `MAP_BATCHES_FRAME` | `STEP` |
|---|---|---|---|
| Projection pushdown | Reads only its arguments; for a `ROW`, the read set | Reads every input column; pushdown stops at the node | Not applicable (source) |
| Predicate pushdown | A predicate that does not read the UDF's output may move below it, unless the UDF is `VOLATILE`. A predicate that reads the output stays above it | Stops at the node: the output rows are not the input rows | Not applicable |
| Limit pushdown | Through, unless `VOLATILE` | Stops | Not applicable |
| Conjunct order in a filter | A conjunct with a UDF goes after the conjuncts without one | — | — |
| CSE | Same `udf_index`, same arguments, not `VOLATILE`: evaluated once | Same node, not `VOLATILE`: `cse_ref` | Never |
| Scan filter | Never pushed into a scan's `filter` (`OPTIMIZED_UDF_IN_SCAN_FILTER`) | — | — |
| Cardinality | Row-preserving | Unknown: `advice` estimate with source `UNKNOWN` | Unknown |
| Partitioning and ordering | Preserved | Lost, except the grouping keys of a grouped node | None |
| Join and aggregate reordering around it | As for any projection | It is a barrier | — |

**Projection pushdown through a `ROW` UDF needs no rule of its own.** The call's arguments are ordinary expressions,
one per read-set entry, so only the read set's columns stay live, down to the scan's `projection`, as for any
`SCALAR` call. The optimizer never reads `code` and never widens or narrows the read set; no host re-derives it. A
`ROW` UDF that reads 2 fields of a 100-column table keeps 2 columns live (§9.4 holds a plan case for it).

**An `AGGREGATE` UDF is treated as an aggregate measure.** A predicate on the group keys may move below the
aggregate, as for any aggregate; one that reads the UDF's output stays above it. The plain form keeps the node
`SINGLE` behind a `HASH` exchange on the group keys; the mergeable form may be split into `PARTIAL` and `FINAL` (§10.4).
Neither is ever pushed into a scan.

**Where each UDF is evaluated is a decision expressed by shape** (§5.2). The host does not move it, and the
post-condition (§7.3) checks it. Host observations (latency, memory) never change shape; they change only batch and
pool sizes.

A limit that cannot pass a UDF means a preview such as "the first 1,000 rows of a filter on a UDF's output" may read
the whole input. That is the SDK's concern, not the format's: a preview verb caps the rows each scan reads, as polars'
`fetch` does *(informative)*.

### 10.10 Host execution

The plan runs on the engine in the base layer of its environment image (§10.11).

The engine calls each UDF through its runtime's interface (`udf_runtime_interface.md` §4), either in-process or in
worker processes started from the same image by the runtime's launcher; the host chooses the transport from its
policy and the runtime's declared capabilities (§5.3 there). A plan may use several runtimes, and every rule below
holds for each.

- **Managed runtimes run in workers by default on a shared host,** because a crash in a user's native extension then
  cannot take the engine down, a GIL does not serialize workers, and memory is attributed per worker. Runtimes from
  added image layers run only in workers.
- **Native UDFs run in-process by default** (`komira/native`, §10.1): no copy, no interpreter and no process per
  batch. The worker transport is opt-in, for crash isolation, by host policy or a run option outside the plan (the
  transport is never in the plan, §10.13); a crash in an in-process native UDF fails the run. This default rests on
  the next rule, and a host that cannot meet that rule runs native UDFs in workers.
- **The heartbeat token stays in the supervisor.** The supervisor holds no long-lived credential and none
  that meters usage: it holds a run-scoped id and token used only to authenticate its heartbeats, and the party that
  receives the heartbeats meters the run's usage by accumulating them. The supervisor runs as its own process
  under its own user id, distinct from the engine's. The token is never passed to the engine: not in its arguments,
  its environment, a file its user id can read, or an inherited descriptor. So user code, whether in the engine or in
  a worker, cannot read the token, forge or suppress a heartbeat, or trace or signal the supervisor. Workers run under
  a further user id of their own, so a worker cannot trace or signal the engine either. User code is the customer's
  own, but the supervisor's reports must stay the supervisor's.
- **Code loads before data is read.**
  - The runtime verifies the sha256 of every code object and data blob it loads, on either transport; a mismatch is
    `OPTIMIZED_UDF_CODE_DIGEST_MISMATCH`.
  - Each worker, or each in-process context, loads each `UdfRef` **once** and keeps it across batches, so a captured
    model loads once per context, not once per batch.
  - Loading happens in §7.2 step 9, before any data is read.
- **Worker count and threads.** The host sets the worker count from the CPU count, `max_workers`, and the memory a
  worker uses after its first load (or `worker_mem_bytes`), so N copies of a large model do not exceed the host's
  memory. It sets each worker's native thread pools (OpenMP, BLAS) to its share of the CPUs, so N workers do not each
  start one thread per CPU.
- **Batches cross as Arrow.** In-process, batches cross as Arrow C Device structs with no copy, and the engine
  validates every array it imports. To a worker, as Arrow IPC messages in shared-memory slots: engine-to-worker
  payloads are decoded in place; worker-to-engine payloads are copied out once and then validated, because the worker
  is the trust boundary. The runtime converts each batch to the function's batch format. The runtime C ABI is
  versioned (`udf_runtime_interface.md` §8.1); the worker protocol carries no promise across releases, because the
  engine and the worker come from the same image.
- **Batch size adapts.** Within `max_batch_rows`, the host sizes batches from observed call latency, so a slow model
  or API call reports progress and balances load. This is a host-local rule (§5.3): observed latency adjusts batch and
  pool sizes only; it never changes the plan's shape.
- **Errors come back mapped.** A raised exception becomes `UDF_RAISED`, with the user's stack mapped by the runtime to
  the user's file and line (a Python traceback, a Node stack through the bundle's source map).
  Standard error goes to the run log.
- **A crashed worker** (signal or exit) is `UDF_WORKER_CRASHED`. The host may retry the batch on a new worker only if
  the UDF is not `VOLATILE`.
- **A `ROW` read outside the read set** fails the batch with `UDF_FIELD_NOT_DECLARED` (§10.2), whatever the stability:
  the host never retries it, because the same batch fails the same way.
- **Each call's output is checked.** A `MAP_BATCHES_COLUMN` call that returns a different length is
  `UDF_BATCH_LENGTH_MISMATCH`; a returned type outside `return_type` is `UDF_RETURN_TYPE_MISMATCH` (§10.5).
- **The `STEP` runtime limit is enforced.** A step that runs past `max_runtime_ms` is stopped with
  `UDF_STEP_TIMED_OUT`.

The worker count, thread limits and batch slicing within `max_batch_rows` and `max_workers` are host-local rules
(§5.3).

**A producer's local run uses the same path** *(informative)*. It captures the function, starts local worker
processes and loads **the captured payload, not the live object**, so a capture that would fail remotely, or a
function that depends on notebook state it did not capture, fails locally first. Capture is not the only difference
between a laptop and a host, so the local workers also run with an empty working directory and only the environment
variables a host provides, and report by name a function that opens a file outside its bundle or blobs. Two
differences remain: a UDF that assigns to a global changes the worker's copy, not the user's; and the network the
function can reach differs. The local run is also where a `ROW` UDF's recording row proxy records the fields read
(§10.2), before the plan is optimized; whole-row operations (iteration, length, conversion to a dict or tuple,
unpacking) mark the read set undetermined.

**In a streaming plan** (a plan with an `UNBOUNDED` scan, §5.2), the same workers serve the streaming driver, with
three additions:

- **A plain-form `AGGREGATE` over an unbounded input is refused**, because its group never closes: at plan build on
  the producer (`UDF_AGGREGATE_UNBOUNDED_GROUP`) and at admission (`OPTIMIZED_UDF_AGGREGATE_UNBOUNDED_GROUP`). The
  mergeable form works incrementally, and its Arrow state is what a checkpoint of that aggregate holds.
- **State in a worker does not survive a restart at the first release.** A restarted worker loads the captured code
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
  CPython minor, or `komira/node` with its one Node major), each with its library and its worker launcher, and the
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
  manifest and its launcher (`udf_runtime_interface.md` §8.3). Such a runtime is never loaded into the engine or the
  supervisor; it runs only in workers.

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
   cover each shape. Otherwise: `OPTIMIZED_UDF_DESCRIPTOR_INVALID` or `OPTIMIZED_UDF_KIND_UNSUPPORTED`.

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
| Engine to worker: the worker protocol | None across releases | The base layer of the same image |
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
| Transport (in-process or worker) in the plan | Rejected: host-local, chosen from host policy and runtime capabilities. |
| `MAP_BATCHES` form derived from the arm | Rejected: one UdfRef could be bound with two schemas. |
| A row-shaped UDF as a `SCALAR` over the whole row, or a host that infers the fields read | Rejected. The whole row keeps every column live; a host cannot re-derive what the producer knew, and two hosts could disagree. `ROW` declares the read set in `arg_types` (§10.2). |
| A separate `read_set` field beside `arg_types` in a `ROW` | Rejected. It would state the bound argument schema twice. |

### 10.14 Comparison

- **PySpark and Spark Connect.** A Python UDF is pickled by value with cloudpickle, and the worker's Python version
  must match the client's. Spark Connect carries the pickled bytes and the Python version inside the plan message
  ([`expressions.proto`](https://github.com/apache/spark/blob/master/sql/connect/common/src/main/protobuf/spark/connect/expressions.proto),
  `PythonUDF`). *(My reading.)* This design uses the same by-value capture, but the bytes live with the environment
  and the plan holds their digest.
- **Daft and Ray Data.** A class-based UDF builds its state once per worker, and Daft sizes batches at run time.
  Here every function's captured state loads once per worker, with no class needed, and the host adapts batch size
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
