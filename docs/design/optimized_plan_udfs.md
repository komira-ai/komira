# Design: user code in an `OptimizedPlan` (UDF nodes and the environment image)

Status: proposed, not built. This is §10.1-§10.9 of [`optimized_plan.md`](optimized_plan.md), kept in its own file
so each file stays under 1,000 lines; §10.10-§10.14 (host execution, the environment image, backward compatibility
for code, the options considered and the comparison) are in
[`optimized_plan_udf_runtime.md`](optimized_plan_udf_runtime.md). Section numbers continue that document's:
`§10.1`-`§10.9` are here, `§10.10`-`§10.14` are in `optimized_plan_udf_runtime.md`, and every other `§n` is in
`optimized_plan.md`.

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

**One mode per language, one plan reference.** Each language has exactly one mode: how its runtime executes user
code. The runtime chooses it; the engine, the host and the plan do not (`udf_runtime_interface.md` §1.2). In every
mode, no lock is shared across engine threads, so no engine thread ever waits on another engine thread's UDF call.

- **Native.** Languages that compile to native code and speak the C ABI directly: C and Mojo at the first release;
  Rust, C++ and Zig later. A native UDF is a shared library compiled for the host platform, loaded in the engine's
  process by the one `komira/native` runtime and called through the UDF runtime C ABI over Arrow C Data, with no
  interpreter and no copy. Native UDFs ship at the first release, in-process; a fault in the library fails the run
  (§10.10).
- **Managed.** Languages whose code runs in an interpreter or virtual machine: Python and Node/TypeScript at the first
  release, each with its own runtime id (`komira/python`, `komira/node`). The runtime library is loaded in the
  engine's process like every runtime, and runs user code in worker processes that it starts and manages itself
  (`udf_runtime_interface.md` §1.2, §5). Later managed runtimes (a JVM, .NET or Go) take this
  mode; Go is managed because a Go shared library carries the Go runtime.

**The C ABI is the only interface between the engine and a runtime** (`udf_runtime_interface.md` §1.1 goal 4, §1.2).
The engine loads every runtime library in-process, opens one context per engine thread, and makes the same calls for
every runtime. It never starts a worker, never speaks a worker protocol and never chooses a transport. What a runtime
guarantees (a crash in user code is contained; user code that ignores a cancel can be stopped) it reports as
capabilities (`udf_runtime_interface.md` §4.2); how it achieves them is not a capability.

Both modes are the same `UdfRef` (§10.3): an open runtime id, explicit Arrow types and a kind. The logical,
optimized and physical plans carry them identically, and nothing in this format names the mode, the class or a
transport. Privilege separation does not come from the mode: the engine holds only what the run itself may use, which
is the user's own, and the one secret a run must not reach, the supervisor's heartbeat token, lives in a separate
process under a separate user id and never reaches the engine (§10.10).

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
| `ROW` | An expression, `WireUdfApply`, where a `SCALAR` may appear | One row object per input row, built from the columns the call passes: the read set when the `UdfRef` sets one, otherwise every input column (below) | One value per row |
| `MAP_BATCHES_COLUMN` | An expression, `WireUdfApply` | One whole batch per argument (a column) | A column of the **same length** |
| `MAP_BATCHES_FRAME` | A plan node, `WireMapBatchesNode` (§10.4) | One whole batch of the input table, or one whole group when `group_by` is set; only the read set's columns when the `UdfRef` sets one, otherwise every input column (below) | A table with any number of rows |
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

**A `ROW` or frame UDF may declare its read set.** A row-shaped function (`df.map_rows(f)`, pandas
`DataFrame.apply(f, axis=1)`) reads a row object's fields by name, and a `MAP_BATCHES_FRAME` function reads a table's
columns. Neither names its inputs as arguments, so the `UdfRef` carries an optional **read set**, `read_set` (§10.3):
the input columns the function reads (`udf_runtime_interface.md` §3.1).

- **Unset means every input column**, all kept live (§10.9): always correct, slower on a wide input. A producer leaves
  it unset whenever it cannot bound the reads. **Set means exactly those columns, and may be empty:** the optimizer
  projects the input to them and the host passes no other column; an empty read set receives a struct or batch with
  no children whose `length` is the row count (`udf_runtime_interface.md` §3.4 rule 5). Unset and empty have different
  canonical bytes (§10.3). A grouped frame's read set contains every column its `group_by` reads (§10.4).
- **`arg_types` lists the columns received:** one entry per read-set name, in order, when set; one per input column,
  in input order, when unset (§10.4). A `ROW` call's `WireUdfApply` passes one argument per entry, usually a column
  reference; the argument binds the field name by position, so a rename below the call does not change the `UdfRef`.
- **Only `ROW` and `MAP_BATCHES_FRAME` carry one.** `SCALAR`, `MAP_BATCHES_COLUMN` and `AGGREGATE` read exactly their
  argument expressions, and a `STEP` has no input (§10.4). *(Open: whether another kind should take one,
  `udf_runtime_interface.md` §1.3.)*
- **The producer determines it when the plan is built, never a host** (`udf_runtime_interface.md` §6.1 item 6), from
  the first of: (1) an explicit declaration, `columns=[...]` on the verb or, in Python, a `TypedDict` or dataclass
  annotation on a `ROW` function's row parameter or a frame function's input parameter (given together, the two must
  name the same set, else `UDF_READ_SET_INVALID`; never merged); (2) the SDK's static scan of field or column
  accesses, counting every branch, taken or not; (3) otherwise none, with a local diagnostic and the fix-it to declare
  `columns=[...]`. Iterating, converting, unpacking or passing on the whole row or table, or a name the scan cannot
  resolve (a computed `getattr`, `r[var]`), leaves `read_set` unset; it never lists every column as a stand-in for
  "unknown". A declared or literal name the input lacks is refused on the user's machine, even on a branch not taken
  (`UDF_READ_SET_COLUMN_UNKNOWN`). For a grouped frame the SDK adds the `group_by` columns. A local run never adds to
  the read set: a field read only on a branch it happened to take would hide a scan defect.
- **The runtime hands over those columns only.** For a `ROW`, a lazy row view over the argument struct's children: a
  read of any other field fails the batch with `UDF_FIELD_NOT_DECLARED`, naming the field, the read set and the row,
  with the fix-it "add it to `columns=[...]`"; it never yields a null, fails even if user code catches the exception,
  and is never bisected. For a `MAP_BATCHES_FRAME`, the batch holds only the read set's columns, so a read of another
  column fails in the user's data library as `UDF_RAISED` *(open: a named error instead, `udf_runtime_interface.md`
  §1.3)*.
- **A `ROW` UDF is `MANUAL`** (§10.7): under `PROPAGATE`, a null in a field read only on some branches would drop rows
  the function would have computed. **Output:** one value of `return_type` per row; several values per row (a tuple
  from `map_rows`) are a struct, which the producer unpacks with ordinary field access.

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
  repeated WireField arg_types = 17;  // declared argument types, in call order (§10.4); for ROW and
                                      // MAP_BATCHES_FRAME, the columns received: read_set's if set, else all
  repeated bytes data_blobs = 6;   // sha256 of each captured value stored apart from the code (§10.6)
  WireField    return_type  = 8;   // required: full Arrow type, nested to any depth (§10.5); a table is a struct
  reserved 9; reserved "resolution";  // a draft's type-resolution mark; types are always explicit (§10.5)
  UdfStability stability    = 10;  // IMMUTABLE | STABLE | VOLATILE: the determinism declaration (§10.7)
  UdfNullMode  null_mode    = 11;  // MANUAL | PROPAGATE (§10.7)
  UdfResources resources    = 12;  // §10.8
  WireField    state_type   = 15;  // AGGREGATE only: set iff the mergeable form (§10.2); explicit Arrow type
  bool         preserves_event_time = 18;  // MAP_BATCHES_FRAME only: event time passes through (below)
  UdfReadSet   read_set     = 19;  // ROW and MAP_BATCHES_FRAME only; unset = reads every input column (§10.2)
  reserved 1, 3, 4, 5, 7, 13, 14;  // an earlier draft's runtime enum, per-language code arms and batch_format
  reserved "runtime", "installed", "source", "value", "batch_format", "js_module", "js_value";
}

// The input columns a ROW or MAP_BATCHES_FRAME UDF reads (§10.2). A message, not a bare repeated field, so that
// unset (reads every input column) and set with no names (reads none) are different values (optimized_plan.md §7.1).
message UdfReadSet {
  repeated string columns = 1;  // each non-empty, no repeats, ascending by UTF-8 bytes; may be empty
}

enum UdfKind {
  UDF_KIND_UNSPECIFIED = 0;   // refused
  SCALAR               = 1;
  MAP_BATCHES_COLUMN   = 2;   // target of a WireUdfApply; output length = input length
  AGGREGATE            = 3;   // plain or mergeable, decided by state_type
  STEP                 = 4;   // source node, runs once per run
  MAP_BATCHES_FRAME    = 5;   // target of a WireMapBatchesNode; any number of output rows
  ROW                  = 6;   // target of a WireUdfApply; one row object per input row, from the columns passed (§10.2)
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
  uint64  worker_mem_bytes     = 3;  // 0 = the host's default per context
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

**`ROW` adds an enum value; the read set adds a field.** `ROW = 6` is a new `UdfKind` value whose number no release
has carried; under §9.2 it is added, never renumbered, and ships with the other UDF arms (§10.12, *Format version*).
`read_set = 19` is the next free `UdfRef` number (18 is `preserves_event_time`; the reserved numbers are listed in the
message), never released, and ships in the same `format_version`. It is a message, `UdfReadSet`, because proto3 gives
a repeated field no presence: a bare `repeated string` could not tell "reads every column" from "reads none", and
`arg_types` alone can say "every input column" only by listing them, which reads the same as a declared read set
naming every column. The two cannot drift: plan validation checks that `arg_types` agrees with `read_set` (§10.4).
The canonical form emits field 19 whenever it is set, even with no names (`optimized_plan.md` §7.1), so an empty read
set and an unset one give different `UdfRef` digests.

**Recorded fields: the runtime descriptors' recorded-fields schema.** For a `ROW` or `MAP_BATCHES_FRAME` entry, each
runtime's descriptor records the fields the code was built or captured against as a `RecordedFields`
(`{repeated WireField fields = 1; repeated WireField key_fields = 2;}`), a plan-proto message beside `WireField` that
every descriptor schema imports (`udf_runtime_interface.md` §3.1, *Descriptor rules*). Canonical form: both lists
ascend by UTF-8 bytes of the name, names are unique across both, `key_fields` holds only `group_by` columns absent
from `fields`, and a set `RecordedFields` is emitted even when empty (absent means nothing recorded). It lives inside
the opaque descriptor, never in the plan; `validate` compares it with `arg_types` at admission (§10.11 check 7).

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

// AggFn, new value AGG_UDF = 38; engine tag AGG_UDF = 37 (src/komira_plan_expr/src/komira_plan_expr/agg_expr.mojo:403 has 36,
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
  (`OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`). For an `AGGREGATE` over several columns, each input column is one entry,
  in input order; for a `STEP`, `arg_types` lists the types of its literal arguments; for a `ROW` and a
  `MAP_BATCHES_FRAME`, `arg_types` lists the columns the function receives (next rule), and a `ROW` call passes
  exactly one argument per entry.
- **A read set is checked at plan validation** (§10.2). The input of a `MAP_BATCHES_FRAME` is its child's
  `output_schema`; the input of a `ROW` call is the `output_schema` of the child of the node whose expression holds it.
  - `read_set` is set only on a `ROW` or a `MAP_BATCHES_FRAME` (`OPTIMIZED_UDF_READ_SET_KIND`).
  - Every name is non-empty, no name repeats, and the names ascend by UTF-8 bytes; an empty list is valid. An input
    with two columns of one name is ambiguous, so a `ROW` call or a `read_set` over such an input is refused, naming
    the name (`OPTIMIZED_UDF_READ_SET_INVALID`).
  - When `read_set` is set, `arg_types` has one entry per name, in the same order and with the same names
    (`OPTIMIZED_UDF_READ_SET_ARG_MISMATCH`, a producer defect). For a `MAP_BATCHES_FRAME`, every name is a column of
    the child's `output_schema` (`OPTIMIZED_UDF_READ_SET_COLUMN_UNKNOWN`), with the type its `arg_types` entry
    declares (`OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`).
  - When `read_set` is unset, each referencing node's input equals `arg_types` exactly, in names, types and order
    (`OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`). Unset never means "whatever `arg_types` lists".
  - A grouped `MAP_BATCHES_FRAME` with a read set names every column its `group_by` reads
    (`OPTIMIZED_UDF_READ_SET_GROUP_KEY`); its input stays exactly `arg_types`.
- **A `ROW` UdfRef is `MANUAL`** (`OPTIMIZED_UDF_ROW_NULL_MODE`). At host admission (§10.11 check 7) its runtime must
  declare `ROW` in `shapes` (`OPTIMIZED_UDF_KIND_UNSUPPORTED`).
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
same runtime path (§10.10), so a mismatch fails on the user's machine first.

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

These fields reuse the engine's vocabularies as wire enums: `UDF_STABILITY_*` (`src/komira_plan_expr/src/komira_plan_expr/udf_data.mojo:165-167`)
and `UDF_NULL_*` (`:154-156`). Each enum has `*_WIRE_UNSPECIFIED = 0`, which is refused, and both fields are required
in a `UdfRef`. `stability` is the UDF's determinism declaration; there is no separate field. The SDK's defaults are
part of its API, not of the format:

| Stability | Meaning to the optimizer and the host | SDK default for *(informative)* |
|---|---|---|
| `IMMUTABLE` | Same arguments, same result, in every run | A function the user marks as such |
| `STABLE` | Same arguments, same result, within one run. Calls may be merged, skipped for rows no later node reads, or repeated while the host bisects a batch that raised (below) | The polars-style API's and the TypeScript API's `SCALAR`, `ROW`, `MAP_BATCHES_COLUMN`, `MAP_BATCHES_FRAME` and `AGGREGATE` |
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

**Delivery.** Within one run, user code never runs a `VOLATILE` batch twice, and nothing is retried after a loss at
the first release; a non-`VOLATILE` `call_batch` batch runs again only through bisection after `ERR_RAISED`
(`udf_runtime_interface.md` §3.4 rule 6, §4.5). A lost context or a crash of the process running user code
(`ERR_INSTANCE_LOST`, `ERR_WORKER_CRASHED`) fails the run with `UDF_WORKER_CRASHED`, naming the UDF and the signal or
exit status, whatever the stability, so a `VOLATILE` call never runs twice. When a `call_batch` batch raises
(`SCALAR`, `ROW`, `MAP_BATCHES_COLUMN`) without naming a row, the host bisects a non-`VOLATILE` batch on the same
instance to the first failing row and then fails the run (`UDF_RAISED`, naming the row); a `VOLATILE` batch is not
called again, and the run fails naming the batch. A frame or aggregate that raises fails the run with the row it
reports. A run restarted from a checkpoint delivers again the batches after that checkpoint.

### 10.8 Declared resources

`UdfResources` is per context (in the Python and Node runtimes, a context is one worker process;
`udf_runtime_interface.md` §3.3):

- `needs.resources.peak_mem_bytes` must include `worker_mem_bytes` times the context count the producer assumed. A
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
| Projection pushdown | Reads only its arguments. A `ROW` call's arguments are the read set's columns when `read_set` is set, and every input column when it is unset | With `read_set` set, reads only the read set (which contains its `group_by` columns), and pushdown continues below the node; unset, reads every input column and pushdown stops at the node | Not applicable (source) |
| Predicate pushdown | A predicate that does not read the UDF's output may move below it, unless the UDF is `VOLATILE`. A predicate that reads the output stays above it | Stops at the node: the output rows are not the input rows | Not applicable |
| Limit pushdown | Through, unless `VOLATILE` | Stops | Not applicable |
| Conjunct order in a filter | A conjunct with a UDF goes after the conjuncts without one | — | — |
| CSE | Same `udf_index`, same arguments, not `VOLATILE`: evaluated once | Same node, not `VOLATILE`: `cse_ref` | Never |
| Scan filter | Never pushed into a scan's `filter` (`OPTIMIZED_UDF_IN_SCAN_FILTER`) | — | — |
| Cardinality | Row-preserving | Unknown: `advice` estimate with source `UNKNOWN` | Unknown |
| Partitioning and ordering | Preserved | Lost, except the grouping keys of a grouped node | None |
| Join and aggregate reordering around it | As for any projection | It is a barrier | — |

**Projection pushdown uses the read set when it is set and keeps every column when it is unset.** A `ROW` call's
arguments are ordinary expressions, one per column it receives, so pushdown through it needs no rule of its own: with
a read set only its columns stay live, down to the scan's `projection`; without one, every input column does. A
`MAP_BATCHES_FRAME` node with a read set needs from its child only the read set, which contains its `group_by`
columns; without one it needs every child column. An empty read set keeps no column live: the scan still delivers
the row count. The optimizer never reads `code` and never widens, narrows or invents a read set; no host re-derives
it. A `ROW` or frame UDF whose read set names 2 columns of a 100-column table keeps 2 columns live, and one with no
read set keeps 100 (§9.4 holds a plan case for each).

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
