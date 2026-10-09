# Design: one UDF runtime interface for every language

Status: proposed, not built. Nothing was built or run to write this document. Citations are to komira `main` as of 2026-10-09 unless marked **[#1094]**. That mark means the head of branch `docs/optimized-plan` (komira-ai/komira#1094, unmerged; this branch is stacked on it), and covers two files: `docs/design/optimized_plan.md` and `docs/design/optimized_plan_udfs.md`.

Section numbers:
- `§10.x` refers to `optimized_plan_udfs.md`.
- `§7.x`, `§9.x` and `§11` refer to `optimized_plan.md`; a citation of its other sections names the file.
- Every other section number is this document's.

Statements marked *(inferred)* are my reading, not facts taken from the code.

The optimized-plan design says what a plan carries and how it is admitted. This document says what a language must implement so that a plan can call a function written in it. It also says what the plan must carry, and must not carry, for that to work for any number of languages.

---

## 1. Goals, non-goals and the three modes of UDF

### 1.1 Goals and non-goals

**Goals.**

1. **Each language implements one interface, once.** To gain UDF support, a language ships three things:
   - a *runtime* that implements one contract (§4); a native language (§1.2) ships none, because its UDFs implement the contract themselves and the one `komira/native` runtime loads them;
   - a *producer* in its SDK that emits UDF references (§6);
   - a pass of the shared conformance corpus (§6.3).

   Nothing else in komira changes.
2. **The plan formats never change per language.** Adding a language adds no field, no `oneof` arm and no enum value to any plan message. Language identity lives in one open, namespaced string (§3.1). The optimizer and the plan validator never branch on it, and a test holds them to that (§3.2).
3. **Plans stay backward compatible forever.** Every later engine decodes, admits and lowers every released plan that contains a UDF (§9.1, §10.12). Each runtime keeps its own runtime-specific bytes readable forever (§8.2).
4. **One contract, two transports.** The same operations run either in-process, through a C ABI over the Arrow C Data Interface, or in a worker process, over Arrow IPC on shared memory. The host picks the transport. Neither the language nor the plan does (§4.1, §5.3).
5. **The engine crosses into a runtime once per batch, never once per row and never once per group,** with no copy wherever the transport and the trust boundary allow it (§4.4, §5.2).
6. **A row-shaped UDF stays columnar.** A function that takes a whole row (`df.map_rows(f)`, pandas `apply(axis=1)`) reads only the columns it declares, and every other column is pruned down to the scan (`ROW`, §3.1).

**Non-goals.**
- GPU UDFs. The ABI reserves their shape (§4.2), but §10.2 defers them.
- Remote UDF servers. §5.3 shows how they would fit later.
- A "register" step visible to users. §10.13 rejects it.
- An optimizer cost model per language.

### 1.2 Three modes of UDF: native, per-thread interpreter, shared parallel virtual machine

The plan system supports three modes of UDF (§10.1). The mode decides how a runtime runs user code on several engine threads at once. It decides nothing that a plan carries. **In every mode, no lock is shared across engine threads**: no engine thread ever waits on another engine thread's UDF call.

| | Mode 1: native | Mode 2: managed, one interpreter per engine thread | Mode 3: managed, one shared parallel virtual machine |
|---|---|---|---|
| Languages | Languages that compile to native code and speak the C ABI directly: Mojo, Rust, C, C++, Zig | Runtimes with a global interpreter lock or a single-threaded virtual machine: Python on builds with a GIL, Node/TypeScript; later WASM (one instance per engine thread) | Runtimes that run truly in parallel inside one virtual machine: the JVM, .NET, free-threaded Python and Go (below), and later others that qualify |
| What the code object is | A shared library compiled for the host platform (OS and CPU) that implements the UDF runtime C ABI (§4.3) itself | Source, bytecode or a serialized value that the language's runtime executes | The same as mode 2 |
| Interpreter | None | Embedded in the runtime library, or provided by the runtime's launcher (§4.1); one per engine thread | One virtual machine per process, embedded or provided by the launcher |
| Runtime id | `komira/native`, one id for every native language | One per language runtime: `komira/python`, `komira/node` | One per language runtime: `komira/python` (free-threaded ABI), `example.org/go` |
| How a batch reaches user code | `komira/native` loads the library and calls it through the C ABI over Arrow C Data, without a copy | The runtime converts each batch to the language's values or columns and calls user code inside the engine thread's own interpreter or isolate | The runtime converts each batch as in mode 2 and calls user code on the engine thread's own virtual-machine thread |
| Contexts (§3.3) | One per engine thread | One per engine thread: an interpreter or isolate (Python: a sub-interpreter where the UDF's packages allow it, otherwise one worker process per engine thread; Node: one `worker_threads` isolate). Never one interpreter shared by several engine threads | One per engine thread: the engine thread attached to the one virtual machine as its own thread, with its own instances and UDF state |
| Global lock | None in the runtime | One per interpreter at most, so it serializes only the engine thread that owns that interpreter | **None.** A runtime with a global lock may not declare this mode (§4.2) |
| Capabilities (§4.2) | `udf_class` `NATIVE`; `threading` `CONTEXT_PER_THREAD`, fixed by `komira/native` | `udf_class` `MANAGED`; `threading` `CONTEXT_PER_THREAD`, or `SINGLE_THREAD` for a runtime that holds one interpreter per process (one worker process per engine thread) | `udf_class` `MANAGED`; `threading` `THREAD_SAFE`; `global_lock` 0 |
| Transports (§5.3) | Both. In-process in the engine is the default; the worker transport is opt-in, for crash isolation (below) | Both, as the runtime's capabilities allow | Both, as the runtime's capabilities allow; workers first for runtimes that are not yet proven in-process |
| Conformance (§6.3) | The shared corpus on both transports, plus the native cases | The shared corpus on both transports, plus the managed and per-thread interpreter cases | The shared corpus on both transports, plus the managed and shared virtual-machine cases |

**The mode is a runtime capability, not a plan property.** A runtime does not report the mode as a field; the host derives it from two capabilities (§4.2): `udf_class` `NATIVE` is mode 1; `MANAGED` with `threading` `CONTEXT_PER_THREAD` or `SINGLE_THREAD` is mode 2; `MANAGED` with `THREAD_SAFE` is mode 3. **`THREAD_SAFE` requires a runtime with no global lock.** A runtime reports `global_lock` beside `threading`, and the host refuses a runtime that reports `THREAD_SAFE` with a global lock, so a Python build with a GIL that declares mode 3 is refused (§4.2). A runtime that falsely reports `global_lock` 0 fails a conformance case that measures parallelism (§6.3).

**Go is managed, in mode 3.** Go compiles to native code, but a Go shared library carries the Go runtime: its scheduler, its garbage collector and its own signal handlers. A process holds one Go runtime; Go does not support two in one process *(inferred: two Go shared libraries built separately each carry one; a Go runtime therefore serves one Go library per worker process)*. Every cgo call from an engine thread runs on its own OS thread inside that runtime, and the runtime schedules those threads in parallel with no global lock. So a Go runtime declares `THREAD_SAFE` with `global_lock` 0, and each engine thread keeps its own context and UDF state. It runs in workers first, like the JVM and .NET (§5.3).

**Mojo is native, although its libraries need a runtime library.** Every `mojo_shared_lib` output has `DT_NEEDED libKGENCompilerRTShared.so`, which holds the Mojo allocator, async runtime and globals (`tools/build/mojo/README.md`). Unlike Go's runtime, it is a support library in the way `libstdc++` is for C++: it does not own the threads that call into it and does not take over the process's signals, so several Mojo libraries and the engine can share one process *(inferred; S3b checks it with two Mojo fixture libraries called from several engine threads in one process, §6.3)*. If that check fails, Mojo libraries run only on the worker transport; the mode and the plan do not change.

**What is the same for all three modes.**
- **The plan reference.** Every mode is a `UdfRef` like any other: an open runtime id, explicit Arrow types and a kind (§3.1). A native UDF's code form is `BUNDLE`.
- **The runtime contract.** All three modes use the C ABI (§4) and the worker transport (§5). A managed runtime implements the C ABI table around its interpreter or virtual machine; a native UDF library implements the same table directly.
- **The plan levels.** Logical, optimized and physical plans carry all three modes identically. No plan field names the mode. The optimizer and plan validation never read it, and the runtime-swap invariance test holds them to that (§3.2). Only the host reads the capabilities that give the mode, to bind contexts and choose a default transport, and the conformance harness reads them, to select the mode-specific cases.

**The native runtime, `komira/native`.** It is a base runtime with no interpreter: a loader that forwards the C ABI to user libraries.
- **Code.** `form` is `BUNDLE`. `code` lists one shared library per target platform, with the role `lib:<os>-<cpu>` (for example `lib:linux-x86_64`, `lib:linux-aarch64`). `entry` names the UDF inside the library, since one library may hold many UDFs. The descriptor records the source language and toolchain, for diagnostics only; the runtime never dispatches on them.
- **Platform.** `validate` refuses a spec with no library for the host's platform (`ERR_UNSUPPORTED`). So a plan whose native code was not built for the host is refused at admission, by name, never in the middle of a run.
- **Loading.** `load` verifies the library's sha256 *before* `dlopen` (`RTLD_LOCAL | RTLD_NOW`, never `dlclose`d, as §4.3 states for runtimes). It resolves the library's one exported symbol, `komira_udf_native_init_v1`, which has the signature of `komira_udf_runtime_init_v1` and returns a `komira_udf_runtime` table. It negotiates that table's minor as §8.1 does, checks the library's `describe` (next item), and forwards every later entry to the table. The distinct symbol name keeps a user library from being registered as a runtime, and a runtime from being loaded as a user library.
- **Capabilities.** The host binds contexts and the transport from `komira/native`'s own `describe`, never from a library's, so `komira/native` reports one fixed set: `runtime_id` `komira/native`, `udf_class` `NATIVE`, `hosting` 0, `threading` `CONTEXT_PER_THREAD` without `thread_affine`, `global_lock` 0, and both transports. That is the least concurrency it can offer a library: the host never calls one context from two threads at once, and a context may move between threads. A library's own `describe` must report `runtime_id` `komira/native`, `udf_class` `NATIVE`, a `threading` of `CONTEXT_PER_THREAD` or `THREAD_SAFE` (which is stronger; the host still binds one context per engine thread), `global_lock` 0, no `thread_affine`, `IN_PROCESS` in `transports` (a library always runs in-process, in the engine or in a worker; the transport belongs to `komira/native`), and the spec's shape in `shapes`. `load` refuses any other library with `ERR_LOAD`, naming the capability (`OPTIMIZED_UDF_CODE_UNLOADABLE`). A library that cannot be called from two threads, even in two contexts, or that serializes its calls behind one lock, is not supported at ABI 1.0.
- **ABI tag.** The `runtime_abi` of `komira/native` in `needs.runtimes` is the C ABI major its libraries target (`abi1`).
- **One id for every native language.** Every native language speaks the same C ABI, so the language is not part of dispatch. A new native language adds an SDK: helpers that export the table from a function's signature (an `extern "C"` Rust function, a `noexcept` C++ function, an exported Mojo function), a typed view of Arrow C Data in that language, and capture of the library into the code layer. It adds no runtime id and no change to the base.

**Native UDFs ship at the first release, in-process by default.** In-process, a native UDF is machine code inside the engine's address space, with the engine's privileges. It has the lowest cost per batch (no copy, no interpreter, no process boundary), and a fault in the library ends the engine and fails the run.
- **What in-process code could reach.** The engine holds only what the run itself may use, which is the user's own. The one secret a run must not reach is the supervisor's heartbeat token. The supervisor holds no long-lived credential and none that meters usage: it holds a run-scoped id and token used only to authenticate its heartbeats, and the party that receives the heartbeats meters the run's usage by accumulating them (`optimized_plan_udfs.md` §10.10 [#1094]).
- **The default rests on one rule: the heartbeat token stays in the supervisor.** The supervisor runs as its own process under its own user id, distinct from the engine's, and never passes the token to the engine: not in its arguments, its environment, a file the engine's user id can read, or an inherited descriptor. So native code in the engine cannot read the token, forge or suppress a heartbeat, or trace or signal the supervisor (§7). A host that cannot meet this rule runs native UDFs in workers.
- **The worker transport is opt-in, for crash isolation:** a fault ends a worker, not the engine (§5.1). A host enables it by policy, or a run by an option outside the plan; the transport is never in the plan (§10.13), so the plan does not change.

## 2. What exists today, and why the shape must change now

**The logical plan names a function, and the receiving process resolves the name.**
- `WireUdfCall` carries `name=1`, `in_arrow_type_id=2`, `out_arrow_type_id=3` and a single `child=4`. That child "MAY NOT BECOME `repeated`" (`src/komira_plan_proto/plan.proto:791-824`).
- The node form, `WireUdf` (`plan.proto:1186`), mirrors `UdfData` (`src/komira_plan_expr/udf_data.mojo:216-293`). The `UdfData` field `operator_factory_id` only means something for a Mojo function known at compile time.
- A UDF whose name cannot be resolved is refused (`plan.proto:88-94`).
- No field names a language.

**The engine's vocabulary is already language-neutral.**
- Kinds: `UDF_KIND_MAP/FILTER/AGG` (`udf_data.mojo:143-145`).
- Null modes (`:154-156`) and stability (`:165-167`).
- Parallelism contracts: `STATELESS`, `SERIAL_ORDERED`, `MERGEABLE`, `PARTITION_LOCAL` (`:186-189`), carried on the wire as `WireUdf.parallelism_tag` (`plan.proto:1204`). The optimized-plan `UdfRef` [#1094] has no parallelism field; §3.4 states the rule that replaces it.
- The Mojo aggregate trait already has the lifecycle every language needs: `init`, `update`, `merge`, `finalize` (`src/komira_udf/agg_fn.mojo:67-140`).

**Part of the data plane exists.**

- Arrow C Data structs with release callbacks: `CArrowSchema` and `CArrowArray` (`src/komira_arrow_ipc/c_data_interface.mojo:136`, `:234`), under an `FFI-BOUNDARY` header (`:1-25`). That exporter *borrows*: "Caller promises the Mojo-owned backing buffers outlive the consumer's reads", and its release never frees the buffer bytes (`:17-20`). It cannot back an array whose release runs after the call returns.
- The C Stream interface, `CArrowArrayStream` (`src/komira_arrow_ipc/c_data_stream.mojo:232`).
  - Export makes no copy, and each exported column holds a shared reference on its buffer (`c_data_stream.mojo:385-395`). This is the model the UDF exporter reuses (§4.4).
  - Import copies: "buffers are COPIED" (`drain_record_batch_stream`, `:3083-3087`; `drain_c_abi_record_batch_stream`, `:3264-3278`).
- Arrow IPC can decode from mapped memory without copying: `decode_record_batch_message_mmap` (`src/komira_arrow_ipc/ipc_decoder_dispatch.mojo:4088`) and `borrow_from_mmap` (`src/komira_buffer/shared_aligned_buffer.mojo:467`).
- Missing:
  - import of a foreign array without a copy, with validation of its layout;
  - the Arrow C Device structs;
  - any shared-memory channel (`git grep -E 'memfd|shm_open' origin/main -- src` finds nothing);
  - a UDF executor;
  - a UDF operator in the physical plan. `src/komira_plan_ir/physical_plan.mojo:206-209` lists only `OP_FILTER/PROJECT/LIMIT/JOIN_PROBE`. Today the SDK walks the expression and evaluates UDF calls itself, because of a package cycle (`src/komira_plan_ir/expr_udf_sites.mojo:1-30`).

**Why the plan format must not name languages.** A plan format with a per-language shape hard-codes its languages in at least six places. This design keeps the plan language-neutral in each of them, and the optimized-plan UDF section follows it [#1094]:

| Place | A per-language format would carry | This design carries | In the plan spec [#1094] |
|---|---|---|---|
| The runtime | A closed enum (`PYTHON \| NODE`); a new runtime is a new value | An open, namespaced string, `UdfCode.runtime` (§3.1) | `optimized_plan_udfs.md` §10.3, `UdfCode` |
| The code form | A `oneof` with one arm per language's code form | A neutral `CodeForm` (`PACKAGE`, `BUNDLE`, `VALUE`), an `entry`, a digest list and a runtime-owned descriptor (§3.1) | §10.3, `UdfCode` and `CodeForm` |
| The batch format | An enum mixing the neutral `ARROW` with `PANDAS`, `POLARS`, `NUMPY` and per-language value formats | A field of each runtime's descriptor (§3.1, *Descriptor rules*) | §10.3, the informative table of descriptors |
| The kinds | A kind named after a language (a Python step) and an arm named after it | Shapes only: `STEP` and `WireStepNode` (§3.1) | §10.2, the kinds table; §10.4, the step arm |
| The ABI | One `DeclaredNeeds` field per language, each in the digest trailer | One `repeated RuntimeNeed runtimes` (§3.2) | `optimized_plan.md` §6.1, `DeclaredNeeds`; §7.1, the `DigestTrailer` |
| Admission | Checks, load checks, path prefixes and error codes written per language | Checks over the neutral fields; the rest is each runtime's `validate` and `load` (§3.1, §4.3) | `optimized_plan_udfs.md` §10.11, from "Added layers write only their prefixes" through "Load check" |

Each of these places is part of a format that stays compatible forever. Had the format been released with a per-language shape, every new language would cost a `format_version` bump plus new optimizer and validator code, forever. No `format_version` has shipped, so the plan spec takes this shape before its first release, and an earlier draft's per-language fields are reserved, never reused (§10.3).

Spark Connect took the path of one arm per language: `CommonInlineUserDefinedFunction` has `PythonUDF`, `ScalarScalaUDF` and `JavaUDF` arms ([expressions.proto](https://github.com/apache/spark/blob/master/sql/connect/common/src/main/protobuf/spark/connect/expressions.proto)). Spark's Python eval-type enum grew to dozens of values that mix shape, format and mode ([pyspark/util.py](https://github.com/apache/spark/blob/master/python/pyspark/util.py)). SPARK-55278 proposes a language-agnostic UDF protocol for Spark ([JIRA](https://issues.apache.org/jira/browse/SPARK-55278)). This design starts language-neutral instead of retrofitting it.

## 3. The three plan levels

### 3.1 Logical plan: the UDF reference

A `UdfRef` describes one UDF. In a RAW (bound, logical) plan, the list of `UdfRef`s comes from `WirePlanEnvelope.udfs`. In an OPTIMIZED plan, it comes from `needs.udfs` (§10.4). As in §10.3-§10.4, the plan body refers to an entry by its index.

```proto
message UdfRef {
  UdfKind      kind        = 2;   // a shape, never a language (below)
  UdfCode      code        = 16;  // which runtime, which entry, which code bytes
  repeated WireField arg_types = 17; // declared argument types, in call order; for ROW, the declared read set (*Types*, below)
  WireField    return_type = 8;   // required; nested to any depth (WireField.children, §10.3)
  WireField    state_type  = 15;  // AGGREGATE only; set iff the mergeable form (§10.2)
  UdfStability stability   = 10;  // IMMUTABLE | STABLE | VOLATILE: this is the determinism declaration
  UdfNullMode  null_mode   = 11;  // MANUAL | PROPAGATE
  UdfResources resources   = 12;  // §10.8, unchanged
  repeated bytes data_blobs = 6;  // sha256 of each captured value stored apart from the code (§10.6)
  bool         preserves_event_time = 18;  // MAP_BATCHES_FRAME only: event time passes through (§10.3)
  reserved 1, 3, 4, 5, 7, 13, 14;  // drafts' runtime enum, per-language code arms, batch_format
  reserved "runtime", "installed", "source", "value", "batch_format", "js_module", "js_value";
  reserved 9; reserved "resolution";
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
  CodeForm form               = 2;  // PACKAGE | BUNDLE | VALUE (below); the only code fact the format reads
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
```

**A runtime id is an open string with a grammar, not an enum value.**
- The grammar is `<namespace>/<name>`, and each part matches `[a-z0-9][a-z0-9._-]{0,62}`.
- The namespace `komira` is reserved for runtimes shipped in the komira base image, and `komira-test` for test runtimes. Any other namespace is a DNS name that its owner controls.
- So a new language adds a string, not a format value.
- The id is part of the UDF's identity, because it is inside the canonical `UdfRef` bytes. A runtime id is therefore never renamed; a successor gets a new id.

**The runtime's ABI tag is not part of the UDF's identity.** `UdfCode` carries no ABI tag (`cp312`, `node22`). The tag lives only in `needs.runtimes` (§3.2; `optimized_plan_udfs.md` §10.3 [#1094] states the same rule). So a `PACKAGE` or `BUNDLE` reference keeps its digest when it is recaptured under a new interpreter minor. A form whose bytes really are ABI-specific (a pickled payload) records that in its descriptor, and the runtime's `validate` refuses a mismatch.

**The kind is the call shape, fully resolved.** The plan spec records two kinds, `MAP_BATCHES_COLUMN` (the target of a `WireUdfApply`) and `MAP_BATCHES_FRAME` (the target of a `WireMapBatchesNode`), and does not derive the form from the arm (`optimized_plan_udfs.md` §10.2, the kinds table and the bullet "The kind records the call shape" [#1094]). With one `MAP_BATCHES` kind whose form came from the arm, identical `UdfRef` bytes would be one entry, so one index could be the target of both a `WireUdfApply` and a `WireMapBatchesNode`, with two different argument schemas. A runtime binds its schemas once per `UdfRef` at `load` (§4.3), so the shape must be in the `UdfRef`. Plan validation refuses an arm whose target has the wrong kind (`OPTIMIZED_UDF_KIND_ARM_MISMATCH`). Plain versus mergeable `AGGREGATE` is already decided by `state_type`.

**What each field is for, and who reads it.**

| Field | Read by the optimizer | Read by plan validation | Read by the runtime |
|---|---|---|---|
| `kind`, `arg_types`, `return_type`, `state_type` | yes | yes (arms, schemas) | yes (bound at `load`) |
| `stability`, `null_mode`, `resources` | yes | yes | `stability`, `null_mode` as facts; the host applies `PROPAGATE` |
| `preserves_event_time` | yes (the watermark rules of `plan_models.md` §3.2) | false unless `MAP_BATCHES_FRAME` (`optimized_plan_udfs.md` §10.3 [#1094]) | — (not in `komira_udf_spec`) |
| `code.runtime` | **never** | grammar; declared in `needs.runtimes` (§3.2) | — |
| `code.form`, `code.code` | never | form set; every digest 32 bytes; `entry` non-empty for `PACKAGE` | yes |
| `code.entry`, `descriptor_version`, `descriptor` | never | never (opaque) | yes, through `validate` (§4.3) |

**Types.**
- `arg_types` makes each `UdfRef` a self-contained signature. A runtime binds the argument schema once, at `load`, before it sees the plan body.
- At each call site, the argument types must equal `arg_types` exactly. A producer that wants a conversion inserts an explicit cast (`OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`).
- For `MAP_BATCHES_FRAME`, and for an `AGGREGATE` over several columns, each column is one entry, in input order. For a `STEP`, `arg_types` lists the types of the literal arguments. For a `ROW`, `arg_types` is the declared read set: one entry per field, whose `name` is the field name user code reads and whose type is that column's Arrow type (below).
- Arrow is the single source of truth for every type (§6.2).

**Determinism is `stability`.** `IMMUTABLE`, `STABLE` and `VOLATILE` already state what the optimizer and the host may assume about repeated calls and retries (§10.7). A separate determinism field would state the same fact twice.

**`STEP` is a shape, not a language.** A step is a shape: a source node with literal arguments that runs once per run. Whether a runtime supports steps is a runtime capability (§4.2), checked at admission; it is not a plan rule. Its arm is `WireStepNode` (`optimized_plan_udfs.md` §10.4 [#1094]). A `STEP` `UdfRef` must be `VOLATILE` (`OPTIMIZED_UDF_STEP_NOT_VOLATILE`): §10.7 lists a step as always `VOLATILE` (the `VOLATILE` row of the stability table), and plan validation enforces it (§7.2 step 8).

**`ROW`: a row-shaped UDF with a declared read set.** A row-shaped function receives one row object per input row and reads its fields by name (`df.map_rows(f)`, pandas `DataFrame.apply(f, axis=1)`). Handed the whole row, it would make every column of its input live and defeat projection pushdown. So the `ROW` `UdfRef` carries the fields it reads, and nothing else reaches it.
- **The read set is `arg_types`.** Each entry names one field and gives its explicit Arrow type. The call site's `WireUdfApply` passes one argument per entry, in the same order, usually a column reference. Names are non-empty and unique (`OPTIMIZED_UDF_ROW_READ_SET_INVALID`). The field name is what user code reads; the argument binds it by position, so a rename below the call does not change the `UdfRef`.
- **The producer determines it when the plan is built** (§6.1), never a host:
  1. `columns=[...]` on the verb, when the user declares it;
  2. otherwise the union of a *recording row proxy* during the local run, which records each field read, and static analysis of the function's field accesses, where the SDK has one. An earlier engine recorded reads this way (`Row.accessed_column_names()`);
  3. otherwise every input column. A function that iterates the row, converts it to a dict or passes it whole to other code marks the read set as undetermined, and so does a local run that saw no rows with no static result. This is correct and slower; the SDK says so in its local diagnostics.
- **The optimizer prunes everything else.** Because the call site's arguments are ordinary expressions, projection pushdown through the UDF needs no rule of its own: only the read set's columns stay live, down to the scan. No host re-derives the read set.
- **The runtime builds rows from those columns only**, per batch, inside the runtime (§4.3). A read of an undeclared field fails the batch with `ERR_FIELD_NOT_DECLARED` (`UDF_FIELD_NOT_DECLARED`), naming the field and the read set, with a fix-it: add the field to `columns=[...]`. It never yields a null. A field read only on a branch the local run did not take is the case this catches; static analysis narrows it, and the error makes it safe.
- **A `ROW` UDF is `MANUAL`** (`OPTIMIZED_UDF_ROW_NULL_MODE`). Under `PROPAGATE`, a null in a field read only on some branches would drop rows the function would have computed.
- **Output.** One value of `return_type` per row, as for `SCALAR`. A function returning several values per row (`map_rows` returning a tuple) declares a struct, which the producer unpacks into columns with ordinary field access.

**Code forms.** Three neutral forms cover every language. §10.6 [#1094] is the Python and TypeScript instance, and §10.3's informative table maps an earlier draft's per-language code messages onto them:

| Language | The function is | `CodeForm` |
|---|---|---|
| Python | A top-level function of an installed, non-editable distribution | `PACKAGE` |
| Python | A top-level function of a project module, not installed or installed editable | `BUNDLE` |
| Python | Anything else: `__main__`, a notebook cell, a lambda, a closure | `VALUE` |
| TypeScript | A module-level function in a bundle | `BUNDLE` |
| TypeScript | A closure or arrow function over plain data | `VALUE` |
| A native UDF (Mojo, Rust, C, C++, Zig; §1.2) | none | `BUNDLE`, whose code objects are one shared library per platform, run by `komira/native` |
| A managed compiled UDF (Go; any language compiled to a WASM component) | none | `BUNDLE`, whose code object is a Go shared library or a WASM component, run by that language's runtime |

Every digest the runtime will read is listed in `code.code` with a role. So admission check 4 ("code present", §10.11) stays one loop over language-neutral fields. The runtime's `validate` refuses a descriptor that references a digest not listed there.

**Descriptor rules.** The descriptor holds what only its runtime understands. Examples:
- Python: the serializer name (`"cloudpickle/<version>"`), the batch format (`ARROW`, `PANDAS`, `POLARS`, `NUMPY` or `VALUES`), a package name, and for a pickled payload the interpreter ABI it requires.
- Node: the capture serializer.
- WASM: a component's world name.
- `komira/native`: the source language and toolchain, for diagnostics only (§1.2).

Each runtime:

- defines its descriptor as a protobuf message, with its own field numbers and the format's forever rules (§9.2);
- defines a canonical encoding of that message. Its `validate` refuses bytes that are not canonical, so the `UdfRef` digest is stable (§10.3, "Identity is the canonical bytes");
- reads every `descriptor_version` it has ever released, for as long as any base ships that runtime (§8.2).

**An unknown runtime is refused by name.** At each stage the refusal names the runtime id and, where known, the ABI tag:

| Where | Check | Refusal |
|---|---|---|
| Producer, when the plan is built | The SDK can emit only runtimes it implements | `UDF_RUNTIME_UNKNOWN` |
| Plan validation | `code.runtime` matches the grammar; `form` is set; each runtime is in `needs.runtimes` | `OPTIMIZED_UDF_RUNTIME_MALFORMED`, `OPTIMIZED_UDF_RUNTIME_UNDECLARED` |
| Admission from the header only (§10.11 check 3) | Every `needs.runtimes` pair is in the base release's runtime registry, or an added runtime layer declares it (§8.3) | `OPTIMIZED_ENV_RUNTIME_MISSING`, naming the pair |
| Admission on the host (§10.11 checks 4-7) | The runtime's `validate` accepts each descriptor, and its capabilities cover each shape | `OPTIMIZED_UDF_DESCRIPTOR_INVALID`, `OPTIMIZED_UDF_KIND_UNSUPPORTED` |

The engine itself knows no runtime ids, so a plan is never refused because the *engine* lacks a runtime. It is refused because the *environment* lacks it, and the refusal says which environment would run it.

### 3.2 Optimized plan: what it adds and pins

The optimized plan carries the same `UdfRef` entries. It adds one message:

```proto
message RuntimeNeed {            // in DeclaredNeeds (optimized_plan.md §6.1)
  string runtime     = 1;
  string runtime_abi = 2;        // the runtime's own ABI tag: "cp312", "cp313t", "node22"; may be empty
}
// DeclaredNeeds: repeated RuntimeNeed runtimes = 9;  reserved 6, 7; reserved "python_abi", "node_abi";
```

- **`needs.runtimes`** lists one entry for each distinct runtime id that `needs.udfs` uses.
  - It is sorted by runtime id.
  - It has at most one entry per runtime id (`OPTIMIZED_NEEDS_RUNTIME_ABI_CONFLICT`): each base ships one ABI of each runtime it carries (§10.11), so a plan naming two could never be admitted. A release ships several bases, one per supported CPython minor and one per supported Node major, and a remote run uses the base of the client's version. A base carries exactly one managed runtime besides `komira/native`, so a plan that needs two managed runtimes (for example `komira/python` and `komira/node`) has no base and is refused at admission (`OPTIMIZED_ENV_RUNTIME_MISSING`, §10.11 [#1094]).
  - It has no missing and no unused runtime (`OPTIMIZED_UDF_RUNTIME_UNDECLARED`, `OPTIMIZED_NEEDS_RUNTIME_UNUSED`).
  - It is part of the `DigestTrailer` (§7.1).
  - A scheduler can place a plan using this list from the header alone.
- **Shape decisions are pinned, as they are today.** These are:
  - where each UDF is placed (§10.9);
  - `PARTIAL`/`FINAL` for mergeable aggregates;
  - `HASH` exchanges for grouped frames and plain aggregates (§10.4);
  - CSE of calls that are not `VOLATILE`.

  None of these decisions reads the runtime.
- **What the optimizer may read:** `kind`, the types, `stability`, `null_mode` and `resources`. It must not read `code`. A `ROW` call's columns are its arguments, so pruning treats it as any other call (§3.1).
- **Host observations never change shape.** The optimizer runs on the producer, before any run, and an optimized plan is never re-optimized (§10.9). Latency the host observes changes only host-local choices: batch size and pool size (§3.3). An optional producer-side cost hint on the verb (a relative per-row cost class, an expected selectivity) may be added later to order several UDF conjuncts. It would live in `PlanAdvice`, not in `UdfRef`, because `UdfRef` bytes are identity. This document does not add it.
- **The runtime-swap invariance test.**
  - Plan every query in the UDF corpus twice. The second time, replace every `code` with `{runtime: "komira-test/null"}` and empty fields, and every `needs.runtimes` entry likewise.
  - After applying the same substitution to the first result, the two optimized plans must be equal.
  - A third planning replaces every runtime with `komira/native`, and the result must again be equal. This holds the optimizer to the rule that the mode of a UDF (§1.2) does not change the plan.
  - Mutants: an optimizer rule that skips CSE when `runtime == "komira/python"`; a rule that pushes calls below a filter only when the runtime is native. The test must go red for each.

### 3.3 Physical plan: what the host binds

The physical plan is the host's lowering of the optimized plan. It is not a wire format; §11 reserves a segment field for one later. Lowering maps every UDF arm to one operator family:

| Plan arm | Physical operator | Runtime operation (§4.3) |
|---|---|---|
| `WireUdfApply` targeting `SCALAR`, `ROW` or `MAP_BATCHES_COLUMN` | `UdfProject`, inside a project or filter segment | `call_batch` |
| `WireMapBatchesNode`, ungrouped or grouped (`MAP_BATCHES_FRAME`) | `UdfFrame` | `frame_open` / `frame_next` |
| `AGG_UDF` measure, plain form | `UdfAggregate`, behind a `HASH` exchange | `frame_open` / `frame_next`, many groups per batch |
| `AGG_UDF` measure, mergeable form | A groups accumulator in the aggregate operator | `agg_*`, many groups per batch |
| `WireStepNode` | `UdfStep` source | `frame_open` with one length-1 input batch |

At lowering, the host binds the following for each runtime. None of it is recorded in the plan.

- **The runtime handle**, taken from the image's runtime registry (§8.3), together with the runtime's capabilities (§4.2).
- **The transport**: in-process or worker (§5). It is the host's policy intersected with the runtime's capabilities. For `komira/native` it is in-process unless the host or the run opts into the worker transport (§1.2, §5.3).
- **Contexts and instances**, by the runtime's mode (§1.2) and threading model (§4.2). A *context* is what one engine thread calls: an interpreter, an isolate, a thread attached to a shared virtual machine, or a native library's per-thread state. An *instance* is one loaded UDF inside one context. In every mode, each engine thread that runs a UDF operator has its own context, holding an instance of each UDF that thread runs, and no context is called by two engine threads at once.
  - `CONTEXT_PER_THREAD` (modes 1 and 2): independent contexts in one process, one per engine thread.
  - `SINGLE_THREAD` (mode 2): one context per process. On the worker transport the host runs one worker process per engine thread, as many as the pool size. In-process (the host interpreter, §5.3) the host runs every UDF operator of that runtime on one engine thread, a pool of one, so the interpreter is never shared by several engine threads. A `SINGLE_THREAD` runtime run in-process is therefore a pool of one that serializes every UDF operator of that runtime, so hosts run `SINGLE_THREAD` runtimes on the worker transport (one worker per engine thread) unless they accept that serialization.
  - `THREAD_SAFE` (mode 3): one virtual machine per process, with no global lock; each context is one engine thread attached to it as its own virtual-machine thread, with its own instances and UDF state.
- **Pool size**: the number of contexts. It is set from the CPU count, `max_workers`, and the memory a context uses *with its UDFs loaded* (`worker_mem_bytes`), as §10.10 states. For a runtime whose loaded objects belong to one context (a Node isolate, a Python sub-interpreter), a captured model is loaded once per context, so its memory is counted once per context. In mode 3 each context holds its own UDF state, so a model the UDF loads into that state is likewise counted once per context.
- **Batch rows**: adapted at run time, below `max_batch_rows` (§10.8).

These are host-local choices (`optimized_plan.md` §5.3). Two hosts may bind one plan differently. The results are still equal, because the contract (§4), the call semantics (§3.4) and the post-conditions (§4.6) are the same on both transports.

### 3.4 Call semantics the format fixes

These rules are part of the plan's meaning, so they hold on every host, for every runtime and both transports. Each has a conformance case (§6.3).

1. **Conditional evaluation.** A UDF call is evaluated only on rows for which every enclosing conditional selects its branch (`CASE`, `coalesce`, the right-hand side of `AND`/`OR`), and only on rows that survive earlier conjuncts of the same filter. So `CASE WHEN x > 0 THEN f(x) END` never calls `f` on a row with `x <= 0`. The ordering of UDF conjuncts last (`optimized_plan_udfs.md` §10.9, the conjunct-order row) depends on this rule.
2. **Compaction.** The host compacts the selected rows (a `take`) before the call and scatters the result after it. Under `PROPAGATE` it also removes rows with a null argument. The arrays a runtime receives contain only rows it must compute.
3. **Independence from instances and batch boundaries.** The result of a `SCALAR`, `ROW` or `MAP_BATCHES_COLUMN` call on a row does not depend on which instance serves it or on where batches were split. A function may cache (a loaded model, a memo table); a function whose per-row result depends on earlier calls (a row counter) is not expressible at the first format version. This replaces the `SERIAL_ORDERED` parallelism contract, which `UdfRef` does not carry. A frame-form function already sees batch boundaries; #1094 states its rule in §10.8 ("Declared resources"): a `MAP_BATCHES_FRAME` function must not depend on batch boundaries unless the node is grouped.
4. **Exact argument encoding.** The host hands the runtime arrays in exactly the `arg_types` encoding: no dictionary or view encoding unless the declared type is one; the host casts first. Arrays may have a non-zero `offset`, including bit offsets that are not multiples of 8.
5. **The argument struct.** Arguments arrive as one struct array, one child per `arg_types` entry, with no validity buffer and offset 0. For a `ROW`, the children are exactly the read set, named as in `arg_types`; the host passes no other column. Its `length` is the row count and is authoritative: a zero-argument `SCALAR` such as `uuid()` receives a struct with no children and `length` rows.
6. **Delivery.** A call to a non-`VOLATILE` UDF is at-least-once, as §10.7 states; a `VOLATILE` batch is never called twice.

## 4. The runtime interface

### 4.1 One contract, two transports

A runtime is a shared library that exports one symbol, `komira_udf_runtime_init_v1`. That symbol returns a table of functions (§4.3). The engine uses the table in one of two ways:

- **In-process.** The engine loads the library and calls the table directly. Arrow data crosses as C Data structs, with no copy.
- **Worker.** A worker process loads *the same library* and serves the same table over the protocol in §5. On the engine side, a proxy implements the table and talks to the worker.

komira writes the worker protocol once, as a C library, `komira_udf_worker`, that serves any runtime's table. Each runtime's manifest (§8.3) names its *launcher*, the program that starts a worker:

- For a runtime that runs in any process (`komira-test/echo`, `komira/native`, CPython embedded in the worker), the launcher is the generic `komira-udf-worker` executable, which links the library and `dlopen`s the runtime.
- For a runtime that needs a particular host program, the launcher is that program. Node-API symbols are exported by the `node` executable, and embedding Node uses its C++ embedder API, which is not ABI-stable; so the `komira/node` launcher is `node` running a small script that loads the runtime as an addon, and the addon links `komira_udf_worker`.
- A native UDF library (§1.2) is not a runtime and has no launcher. `komira/native` loads it, in the engine or in a generic `komira-udf-worker`, and the bytes of the library are the same on both transports.

So each language is implemented once, and the protocol is written once, not once per language. This is also the shape of DuckDB's C extension API, whose function struct is only appended to ([duckdb#14992](https://github.com/duckdb/duckdb/pull/14992)).

### 4.2 Capabilities

`describe` returns what the runtime can do. When a plan needs a capability the runtime lacks, the host refuses the plan by name.

| Capability | Values | Used for |
|---|---|---|
| `runtime_id`, `runtime_abi` | strings | Matched against `needs.runtimes` |
| `max_descriptor_version` | the highest version the runtime reads | `validate` refuses any newer version |
| `shapes` | bitmask of SCALAR, ROW, MAP_BATCHES_COLUMN, MAP_BATCHES_FRAME, MAP_BATCHES_FRAME_GROUPED, AGG_PLAIN, AGG_MERGEABLE, STEP | `OPTIMIZED_UDF_KIND_UNSUPPORTED` |
| `threading` | `CONTEXT_PER_THREAD`: several independent contexts run in parallel in one process, and one thread at a time calls each (modes 1 and 2). `SINGLE_THREAD`: one context per process (mode 2, through one worker per engine thread). `THREAD_SAFE`: one virtual machine per process with no global lock, in which one context per engine thread runs in parallel, one thread at a time calling each (mode 3) | Binding contexts and the pool (§3.3), and the mode (§1.2) |
| `global_lock` | flag: the runtime holds a lock that serializes user code across contexts in one process (a CPython GIL; a GIL re-enabled by an extension module counts) | **The host refuses `THREAD_SAFE` with `global_lock` 1**: at `init`, it reports `UDF_RUNTIME_FAULT` naming the runtime and the two capabilities, and loads no UDF on it. So a Python build with a GIL cannot declare mode 3 |
| `thread_affine` | flag: the host always calls a context, its instances and their objects from the OS thread that opened the context | A CPython thread state, a sub-interpreter and a Node env are bound to one OS thread, not merely serialized. Without the flag, the runtime does its own handoff, as Node in-process does (§5.3) |
| `transports` | `IN_PROCESS`, `WORKER`, or both | Binding the transport (§5.3) |
| `udf_class` | `NATIVE` or `MANAGED` (§1.2) | With `threading`, the mode: the host's default transport (§5.3) and the mode-specific conformance cases (§6.3). Never read by the optimizer or by plan validation |
| `hosting` | Managed runtimes only (a native runtime reports 0). `EMBEDDED`: the runtime brings its own interpreter. `HOST_INTERPRETER`: in-process, it runs inside an interpreter that already loaded the engine (the Python SDK) | The Python runtime is one library with both modes; the host must know which it is in (§5.3) |
| `devices` | bitmask; CPU only at the first release | GPU UDFs later, with no change of signature |
| `features` | `MEMORY_REPORT` | Which optional entries are present |

### 4.3 The C ABI: `komira_udf_runtime.h`

The header is plain C99 with no include beyond `<stdint.h>` and `<stddef.h>`. It embeds the Arrow C Data, C Stream and C Device struct definitions verbatim under their standard guards (`ARROW_C_DATA_INTERFACE`, `ARROW_C_STREAM_INTERFACE`, `ARROW_C_DEVICE_DATA_INTERFACE`), as the Arrow specification recommends, so a runtime needs no Arrow headers ([C Data](https://arrow.apache.org/docs/format/CDataInterface.html), [C Stream](https://arrow.apache.org/docs/format/CStreamInterface.html), [C Device](https://arrow.apache.org/docs/format/CDeviceDataInterface.html)).

Every data argument is an `ArrowDeviceArray` or an `ArrowDeviceArrayStream`. The first version uses `device_type = ARROW_DEVICE_CPU` and `device_id = -1`, so GPU UDFs are a new capability value later, not a new signature. Every struct that crosses the ABI begins with `size_t struct_size`, so each one can grow within a major version (§8.1).

```c
/* komira_udf_runtime.h: ABI 1.0. Append-only within a major version (§8.1). */
#include <stdint.h>
#include <stddef.h>
/* ArrowSchema, ArrowArray, ArrowArrayStream, ArrowDeviceArray, ArrowDeviceArrayStream:
   copied verbatim from the Arrow specification under their standard include guards. */

#define KOMIRA_UDF_ABI_MAJOR 1
#define KOMIRA_UDF_ABI_MINOR 0

typedef enum {                        /* 0 is success; values are never reused */
  KOMIRA_UDF_OK = 0,
  KOMIRA_UDF_ERR_ABI = 1,             /* major mismatch or missing minimum minor */
  KOMIRA_UDF_ERR_DESCRIPTOR = 2,      /* unknown descriptor_version, non-canonical bytes, bad entry */
  KOMIRA_UDF_ERR_UNSUPPORTED = 3,     /* shape, type or feature this runtime does not support */
  KOMIRA_UDF_ERR_CODE_DIGEST = 4,     /* a code object's bytes do not match its sha256 */
  KOMIRA_UDF_ERR_LOAD = 5,            /* import, compile or deserialize failed */
  KOMIRA_UDF_ERR_RAISED = 6,          /* user code raised; message and trace set */
  KOMIRA_UDF_ERR_RETURN_TYPE = 7,     /* user output not castable to the declared type */
  KOMIRA_UDF_ERR_LENGTH = 8,          /* column-form output length differs from input */
  KOMIRA_UDF_ERR_STATE_TOO_LARGE = 9,
  KOMIRA_UDF_ERR_GROUP_TOO_LARGE = 10,
  KOMIRA_UDF_ERR_CANCELLED = 11,
  KOMIRA_UDF_ERR_DEADLINE = 12,
  KOMIRA_UDF_ERR_OUT_OF_MEMORY = 13,  /* refused by the host's memory hook, or the runtime's own */
  KOMIRA_UDF_ERR_INSTANCE_LOST = 14,  /* the context cannot be used again; the host closes and reopens it */
  KOMIRA_UDF_ERR_INTERNAL = 15,       /* a runtime bug; never user code */
  KOMIRA_UDF_ERR_FIELD_NOT_DECLARED = 16  /* ROW: user code read a field outside the read set; message names it */
} komira_udf_status;

typedef struct komira_udf_error {     /* allocated by the host per call; filled by the runtime on failure */
  size_t      struct_size;
  int32_t     code;                   /* a komira_udf_status */
  const char* message;                /* UTF-8, one line */
  const char* user_trace;             /* mapped to the user's file and line where the runtime can; may be NULL */
  int64_t     row;                    /* row in the batch when known; -1 otherwise */
  int64_t     group;                  /* group ordinal when known; -1 otherwise */
  void      (*release)(struct komira_udf_error*);  /* frees the strings; NULL: nothing to free */
  void*       private_data;
} komira_udf_error;

typedef struct komira_udf_host {      /* provided by the engine; valid until shutdown returns */
  size_t   struct_size;
  uint32_t abi_major, abi_minor;
  void*    host_data;                 /* every callback below is thread-safe; none from a signal handler */
  int32_t  (*mem_reserve)(void* host_data, int64_t bytes);  /* OK or ERR_OUT_OF_MEMORY */
  void     (*mem_release)(void* host_data, int64_t bytes);
  int64_t  (*now_ns)(void* host_data);                      /* monotonic clock deadlines are read against */
  void     (*log)(void* host_data, int32_t level, const char* utf8);
} komira_udf_host;

typedef struct komira_udf_capabilities {
  size_t      struct_size;
  const char* runtime_id;             /* "komira/python"; static for the runtime's life */
  const char* runtime_abi;            /* "cp312" */
  uint32_t    max_descriptor_version;
  uint32_t    shapes, threading, thread_affine, transports, hosting, devices, features;  /* §4.2 */
  uint32_t    udf_class;              /* NATIVE or MANAGED (§1.2) */
  uint32_t    global_lock;            /* 1 if user code is serialized across contexts; THREAD_SAFE requires 0 */
} komira_udf_capabilities;

typedef struct komira_udf_spec {      /* the UdfRef, decoded by the host; borrowed for the call */
  size_t             struct_size;
  int32_t            shape;           /* one bit of capabilities.shapes, fully resolved */
  int32_t            form;            /* CodeForm */
  const char*        entry;
  uint32_t           descriptor_version;
  const uint8_t*     descriptor;  size_t descriptor_len;
  const struct ArrowSchema* args;     /* a struct schema, one child per arg_types entry; for ROW, the read set by name */
  const struct ArrowSchema* result;   /* return_type; a struct for a table */
  const struct ArrowSchema* state;    /* state_type, or NULL */
  int32_t            null_mode, stability;
  const char*        code_root;       /* directory holding code objects named by hex sha256 */
  size_t             n_code;
  const char* const* code_roles;  const uint8_t (*code_sha256)[32];
} komira_udf_spec;

typedef struct komira_udf_call {
  size_t                  struct_size;
  int64_t                 deadline_ns;  /* against host->now_ns; 0 = none */
  int64_t                 call_id;      /* stable across a retry of the same batch */
  const volatile int32_t* cancel;       /* host-owned, alive until the call returns; nonzero = cancel */
} komira_udf_call;

typedef struct komira_udf_rt       komira_udf_rt;        /* the runtime, once per process */
typedef struct komira_udf_udf      komira_udf_udf;       /* a validated, loaded UDF: process-wide part */
typedef struct komira_udf_context  komira_udf_context;   /* one interpreter or isolate (§3.3) */
typedef struct komira_udf_instance komira_udf_instance;  /* one UDF inside one context */
typedef struct komira_udf_frame    komira_udf_frame;     /* one frame, plain-aggregate or step call */
typedef struct komira_udf_groups   komira_udf_groups;    /* the accumulators of many groups */

typedef struct komira_udf_runtime {   /* static in the runtime; the host reads entries below struct_size */
  size_t   struct_size;
  uint32_t abi_major, abi_minor;
  int32_t (*describe)(komira_udf_rt*, komira_udf_capabilities* out);
  int32_t (*validate)(komira_udf_rt*, const komira_udf_spec*, komira_udf_error*);  /* pure; no user code */
  int32_t (*load)(komira_udf_rt*, const komira_udf_spec*, komira_udf_udf** out, komira_udf_error*);
  void    (*unload)(komira_udf_udf*);
  int32_t (*open_context)(komira_udf_rt*, uint32_t slot, komira_udf_context** out, komira_udf_error*);
  void    (*close_context)(komira_udf_context*);
  int32_t (*open_instance)(komira_udf_context*, komira_udf_udf*, komira_udf_instance** out, komira_udf_error*);
  void    (*close_instance)(komira_udf_instance*);
  /* SCALAR, ROW, MAP_BATCHES_COLUMN. args moved in; out moved out (release == NULL on failure). */
  int32_t (*call_batch)(komira_udf_instance*, const komira_udf_call*,
                        struct ArrowDeviceArray* args, struct ArrowDeviceArray* out, komira_udf_error*);
  /* MAP_BATCHES_FRAME (grouped or not), AGG_PLAIN, STEP. `in` is moved in. */
  int32_t (*frame_open)(komira_udf_instance*, const komira_udf_call*,
                        struct ArrowDeviceArrayStream* in, komira_udf_frame** out, komira_udf_error*);
  int32_t (*frame_next)(komira_udf_frame*, const komira_udf_call*,
                        struct ArrowDeviceArray* out, komira_udf_error*);  /* end: OK with out->array.release == NULL */
  void    (*frame_close)(komira_udf_frame*);
  /* AGG_MERGEABLE, vectorized over groups. group_ids: an int32 array, one per row; ids < n_groups. */
  int32_t (*agg_open)(komira_udf_instance*, komira_udf_groups** out, komira_udf_error*);
  int32_t (*agg_update)(komira_udf_groups*, const komira_udf_call*, struct ArrowDeviceArray* args,
                        struct ArrowDeviceArray* group_ids, uint32_t n_groups, komira_udf_error*);
  int32_t (*agg_merge)(komira_udf_groups*, const komira_udf_call*, struct ArrowDeviceArray* states,
                       struct ArrowDeviceArray* group_ids, uint32_t n_groups, komira_udf_error*);
  int32_t (*agg_state)(komira_udf_groups*, uint32_t emit_first_n, struct ArrowDeviceArray* out, komira_udf_error*);
  int32_t (*agg_finish)(komira_udf_groups*, uint32_t emit_first_n, struct ArrowDeviceArray* out, komira_udf_error*);
  void    (*agg_close)(komira_udf_groups*);
  void    (*shutdown)(komira_udf_rt*);           /* after it returns: no release, no host callback */
  /* Optional (NULL when the feature bit is clear): */
  int64_t (*memory_report)(komira_udf_context*); /* bytes held outside Arrow buffers, or -1 */
} komira_udf_runtime;

/* The one exported symbol. Returns the runtime's static table, or NULL with *err filled. */
const komira_udf_runtime* komira_udf_runtime_init_v1(const komira_udf_host* host,
                                                     komira_udf_rt** rt, komira_udf_error* err);
```

**The operations, in lifecycle order.**

1. **`init`** negotiates the version (§8.1) and creates the runtime handle. It runs once per process. The host loads the library with `RTLD_LOCAL | RTLD_NOW` and never `dlclose`s it, because runtimes start threads and register exit handlers. Runtimes are built with hidden symbol visibility except for the one exported symbol.
2. **`describe`** returns the capabilities (§4.2). It is cheap and pure.
3. **`validate(spec)`** checks the descriptor, the shape and the signature without running user code.
   - It plays the role of PostgreSQL's validator function ([plhandler](https://www.postgresql.org/docs/current/plhandler.html)).
   - It runs at host admission, and in the producer's local check.
4. **`load(spec)`** verifies each code object's sha256, and binds the argument, result and state schemas. It runs once per UDF per process, before any data is read (§7.2 step 9). For a runtime whose loaded objects can be shared across contexts, the code is loaded here once; for one whose objects belong to a context (Node isolates, Python sub-interpreters), `open_instance` does the loading.
5. **`open_context(slot)`** creates one context per engine thread or per worker (§3.3): an interpreter, an isolate, a thread attached to the runtime's one virtual machine, or a native library's per-thread state. `slot` is a dense index. For a `thread_affine` runtime, the thread that opens a context is the only thread that uses it and its instances.
6. **`open_instance(context, udf)`** makes a UDF callable in a context. A plan with 10 UDFs on 32 engine threads has 32 contexts and 320 instances, not 320 interpreters. This is the counterpart of DuckDB's `local_init`.
7. **Calls**, by shape:
   - **`SCALAR` and `MAP_BATCHES_COLUMN`: `call_batch`.** A `SCALAR` runtime loops over the rows *inside* the runtime, in its own language. An `async` function is awaited inside the runtime, with at most `max_concurrent_calls` calls in flight (§10.8). The output has the same length as the input.
   - **`ROW`: `call_batch`, rows built inside the runtime.** At `load` the runtime binds the field names from `spec->args`, the read set. Per batch it builds one row object per row over the `args` children only, in its own language: a lazy view that reads child *i* at row *r* when a field is read (a Python row proxy or a pandas `Series` holding only the read set, a JavaScript object with getters, a typed row view in a native SDK). A read of any other name fails with `ERR_FIELD_NOT_DECLARED`, with `row` set. If user code catches the language's exception, the runtime still fails the batch: the proxy records the violation and `call_batch` checks it before it returns. A native SDK whose row view exposes only the declared fields rejects other names when the library is built.
   - **`MAP_BATCHES_FRAME`, ungrouped: `frame_open`, then `frame_next` until the end.** The runtime pulls input batches from `in` when it needs them; the host pulls output batches, so a generator yields as it goes, before it has read all its input.
   - **`MAP_BATCHES_FRAME`, grouped, and plain `AGGREGATE`: the same entries, with a group column.** Each input batch's first child is a non-null `int64` group ordinal. Rows of one group are contiguous and ordinals increase; a group may span batches. The runtime collects a group's rows and calls the user function once per group, in its own language. A grouped frame returns the user's tables (which carry their own key columns, §10.4); a plain aggregate returns one row per completed group, in ordinal order, so the host pairs results with keys by position. One crossing serves many groups.
   - **Mergeable `AGGREGATE`: the `agg_*` entries, vectorized over groups** (the shape of DataFusion's `GroupsAccumulator`, [docs](https://docs.rs/datafusion/latest/datafusion/logical_expr/trait.GroupsAccumulator.html)):
     1. `agg_open` once per aggregate operator and instance;
     2. `agg_update` once per batch, with a group id per row; `n_groups` only grows;
     3. `agg_state` in a `PARTIAL` step: an `n`-row column of `state_type`, one row per group;
     4. `agg_merge` of partial states in a `FINAL` step, again with a group id per row;
     5. `agg_finish`: an `n`-row result column.

     `emit_first_n` emits and forgets the first `n` groups, so the host can emit early. The state is an Arrow value of `state_type`, never an object private to the language, so it crosses an exchange and a checkpoint as a column. A groups object is used only with the instance that created it, and is closed before `close_instance`.
   - **`STEP`: `frame_open`** with a stream of one length-1 struct batch holding the literal arguments. The output is the stream of the step's table, which may be empty or have no columns.
8. **`frame_close`, `agg_close`, `close_instance`, `close_context`, `unload`**, at the end of the run or when the host shrinks the pool; then **`shutdown`**, at process exit or when the host drops the runtime.

The host serializes the calls on one frame, one groups object and one context, in every mode; the C Stream specification does not make a stream thread-safe.

### 4.4 Data, zero copy and ownership

Every pointer that crosses the ABI has exactly one named owner. The Mojo binding states each owner in an `# FFI-BOUNDARY:` comment. It keeps every `UnsafePointer` private to the binding, and its public API takes and returns values (`docs/design/mojo_safety_and_idioms.md`).

| Object | Owner | Rule |
|---|---|---|
| `args`, `states`, `group_ids` of every call | **Moved to the runtime on entry, whatever status it returns** | The struct itself belongs to the host (often on its stack). Before returning, the runtime moves it into its own storage (`*mine = *args; args->array.release = NULL;`) and later calls `release` only on its own copy, exactly once. It may release after returning, when user code kept a view. The host exports without copying: each buffer is kept alive by a shared reference that the release drops, as the stream exporter already does (`c_data_stream.mojo:385-395`), not with the borrowing exporter of `c_data_interface.mojo:17-20`. |
| `out` of every call | **Moved to the host on success** | The runtime produces it with its own release callback. On any status other than OK, `out->array.release == NULL` and the host never calls it. The host imports it **without copying**, after validating it (below), and calls release when its last reference goes away. A runtime may return its input buffers in its output. |
| `in` stream of `frame_open` | **Moved to the runtime** | Same move rule as `args`. The runtime releases it after the end of the stream, at `frame_close`, or on failure. |
| `komira_udf_spec`, with its strings and schemas | Borrowed for the call | `validate` and `load` copy whatever they keep. |
| `komira_udf_error` | The host owns the struct; the runtime owns the strings | The host allocates one per call, so concurrent calls never share one. The host calls `release` once when it is non-NULL. An unknown `code` from a newer minor is treated as `ERR_INTERNAL`. |
| `cancel` flag | The host | Alive until the call returns. The host sets it with a release store; the runtime reads it with an atomic load. |
| Handles (`rt`, `udf`, `context`, `instance`, `frame`, `groups`) | The runtime | Created and freed only through the table. |
| Callbacks into a language (a C callback object, a Node-API reference) | The runtime, inside its context or instance | Freed in `close_instance` or `close_context`. The host never holds a reference into a language. |

**Release runs on any thread, at any time.** The Arrow specification does not say which thread may call `release`, so this ABI does: the host calls release on whatever engine thread drops the last reference, possibly after `close_instance` and `close_context`, until `shutdown` begins. Release must not block on an interpreter lock or an event loop:
- In Python, freeing a buffer backed by a numpy or pyarrow object needs `Py_DECREF`, which needs the GIL; taking the GIL from an engine thread while the interpreter's thread waits on the engine deadlocks.
- In Node, `napi_delete_reference` must run on the env's JavaScript thread.

A runtime therefore implements release with an atomic reference count and a deferred-free queue, which the owning context's thread drains on its next call or at close. `shutdown` drains every queue; the host releases everything before calling it, and keeps `komira_udf_host` alive until it returns.

**The host validates every imported array.** The runtime returns exactly the bound result or state schema and does any cast itself (`ERR_RETURN_TYPE` is the runtime's report). Because no schema travels with `out`, a wrong layout would be read through the declared type, and int64 and float64 have identical layouts. So on import the host checks the layout against the bound schema before any kernel reads it: `n_buffers` and `n_children` per format, each buffer's size against `length + offset`, offsets monotonic and within the data, a dictionary exactly where the type has one, and device CPU. A failure is `UDF_RUNTIME_FAULT`, naming the runtime. In-process this guards against runtime bugs; across the worker boundary it is a security check, which is why the engine validates its own copy (§5.2).

- **One batch at a time; schemas once.** Schemas are bound at `load` and never sent per call; `args` carries only arrays.
- **Importing without a copy is new work.** Today's importers copy (`c_data_stream.mojo:3083-3087`, `:3264-3278`). The in-process transport needs an importer that validates foreign buffers and wraps them in reference-counted storage whose last reference calls the producer's `release`.
- **Device arrays.** At the first release, `device_type` is CPU, `device_id` is -1 and `sync_event` is NULL. A runtime that receives any other device returns `ERR_UNSUPPORTED`.

### 4.5 Errors

Every entry returns a `komira_udf_status` and on failure fills the host's `komira_udf_error`. The host maps status codes to the run's named errors through one table, so every language reports a raised exception the same way. A runtime returns the user's message and trace, not only a code.

| `komira_udf_status` | Run error |
|---|---|
| `ERR_RAISED` | `UDF_RAISED`, with `user_trace` and the row (per §10.7, the host bisects a batch that is not `VOLATILE`) |
| `ERR_RETURN_TYPE`, `ERR_LENGTH` | `UDF_RETURN_TYPE_MISMATCH`, `UDF_BATCH_LENGTH_MISMATCH` |
| `ERR_FIELD_NOT_DECLARED` | `UDF_FIELD_NOT_DECLARED`, naming the field, the read set and the row, with the fix-it "add it to `columns=[...]`". Never retried: the same batch fails the same way |
| `ERR_STATE_TOO_LARGE`, `ERR_GROUP_TOO_LARGE` | `UDF_STATE_TOO_LARGE`, `UDF_GROUP_TOO_LARGE` (the host names the key from `group`; `UDF_STATE_TOO_LARGE` also names the cap, a fixed 64 MiB of Arrow state per group at the first release, §10.2) |
| `ERR_LOAD`, `ERR_CODE_DIGEST`, `ERR_DESCRIPTOR` | `OPTIMIZED_UDF_CODE_UNLOADABLE`, `OPTIMIZED_UDF_CODE_DIGEST_MISMATCH`, `OPTIMIZED_UDF_DESCRIPTOR_INVALID` |
| `ERR_CANCELLED`, `ERR_DEADLINE` | The run's cancel, or `UDF_DEADLINE_EXCEEDED` (`UDF_STEP_TIMED_OUT` for a step) |
| `ERR_INSTANCE_LOST` | Not an error by itself: the host closes the context, opens a new one, and retries the batch under the delivery rule (§3.4) |
| `ERR_OUT_OF_MEMORY` | `UDF_OUT_OF_MEMORY` |
| `ERR_INTERNAL`, `ERR_ABI`, an unknown code, `ERR_UNSUPPORTED` at call time, or a failed import validation | `UDF_RUNTIME_FAULT`, naming the runtime; never blamed on user code |

Per-row errors for a TRY form, like Velox's `errorPayload` ([RemoteFunction.thrift](https://github.com/facebookincubator/velox/blob/main/velox/functions/remote/if/RemoteFunction.thrift)), are not in ABI 1.0. They would be added later as a new entry.

### 4.6 Post-conditions belong to the host

After every call, the host checks the output in one shared library, `komira_udf_host`, for every runtime and both transports. The conformance harness (§6.3) and the engine's operators (§9, S6) link the same library.

- the output passes import validation against the bound schema (§4.4), so its type is exactly `return_type` or `state_type`;
- a column-form output has the same length as the input;
- a plain aggregate returns one row per completed group, every state has one row per group, and a mergeable result has `emit_first_n` rows;
- a declared non-nullable type contains no nulls.

The same library holds compaction and scatter (§3.4 rules 1-2) and the error table (§4.5). A runtime may check its outputs too, but the host never relies on it.

### 4.7 Cancellation and deadlines

- **Cancel is a per-call flag**, `komira_udf_call.cancel`. It applies to one call, cannot outlive it, and so cannot race with closing an instance or land on the next call. The runtime checks it between rows and between batches, and returns `ERR_CANCELLED`. There is no cancel entry, and nothing in the ABI runs in a signal handler.
- **A runtime watches the flag with its own thread when user code is busy.** Interrupting user code is runtime-specific:
  - CPython: `PyErr_SetInterrupt` acts only on the main thread of the main interpreter, and `PyThreadState_SetAsyncExc` needs the GIL; neither interrupts a long C loop. A watchdog thread in the runtime uses `PyThreadState_SetAsyncExc` on the context's thread.
  - Node: Node-API has no call that stops running JavaScript in an isolate; the stable mechanism is `worker.terminate()`, which destroys the isolate.
  - When interrupting leaves the context unusable, the runtime returns `ERR_INSTANCE_LOST` and the host reopens the context.
- **Deadlines** arrive with each call, in `deadline_ns`. A runtime that notices one has passed returns `ERR_DEADLINE`. This is cooperative.
- **Hard limits** (`max_runtime_ms` for a step, a host's limit per batch) are enforced only in the worker transport, by killing the worker. In-process, there is no safe way to stop code that ignores the flag. That is one reason a shared host runs managed runtimes in workers (§7), and why a native UDF that must be stoppable opts into the worker transport.

### 4.8 Memory accounting

- The host counts the Arrow buffers a runtime produces when it imports them.
- A runtime with the `MEMORY_REPORT` feature reports, through `memory_report`, the memory a context holds outside Arrow (an interpreter heap, a loaded model).
- Large allocations that a runtime controls go through `host->mem_reserve` and `mem_release`. The host may refuse them with `ERR_OUT_OF_MEMORY`.
- In the worker transport, the process's resident memory, under its own memory limit, is the authoritative number. The hooks are only advisory there.

## 5. The worker transport

### 5.1 Why workers

Workers give four things:

- **Crash containment.** A segfault in a user's native extension ends a worker, not the engine.
- **Isolation.** A separate user id, so a worker cannot trace or signal the engine, and no access to the supervisor's heartbeat token or channel (§10.10).
- **Hard limits.** The worker is killed on a deadline, and each process has its own memory limit.
- **Scaling per core** for a runtime whose contexts cannot run in parallel in one process, such as CPython with a global interpreter lock.

### 5.2 The protocol

The worker protocol carries **the same operations** as §4.3: one message per call and one per reply. It is private to a base release, because the engine and the worker always come from the same image (§8.1).

- **Starting a worker.** The engine starts the runtime's launcher (§4.1) with `posix_spawn`, never `fork`, because the engine is multi-threaded.
- **Channels.** There are two:
  - a control channel: a Unix socket pair the engine creates when it spawns the worker;
  - a shared-memory region: an anonymous memory file, created per worker and passed over that socket. It holds two *slot heaps*, engine-to-worker and worker-to-engine.

  Where shared memory is not available, payloads travel over the control channel itself, as a pipe. The messages are the same.
- **Framing.**
  - Each message is a fixed little-endian header on the control channel: `{magic, op, request_id, flags, slot, payload_offset, payload_len}`.
  - An optional payload sits in a slot.
  - A payload is **Arrow IPC encapsulated messages**: a record batch or, for `LOAD` and `OPEN`, the schemas. Body buffers are 64-byte aligned, so the reader can borrow them in place (`ipc_decoder_dispatch.mojo:4088`).
- **Slots, not rings.** Either side may hold a payload for an arbitrary time: user code may keep a view of its input (§4.4), and the engine keeps imported outputs alive, for example inside a hash build. So payloads free out of order, and a ring would fill and deadlock (the worker blocked writing output while the engine waits for it). Each heap is a slot allocator with a bound on the bytes pinned per direction; past the bound, the holder copies the payload out and frees its slot.
- **Copies, by direction.**
  - **Engine to worker: no copy beyond serialization.** The engine writes a batch's IPC body directly into a slot; the worker decodes it in place (`ipc_decoder_dispatch.mojo:4088`, `shared_aligned_buffer.mojo:467`) and hands it to the runtime as a C Data array whose release frees the slot.
  - **Worker to engine: one copy.** The worker is the boundary for untrusted code, and it can still write its half of the region after the engine has validated a payload. So the engine copies each worker-to-engine payload out of its slot once, frees the slot, and validates and decodes its own copy (§4.4). Sealed per-payload memory files would avoid the copy and are not chosen for the first release (§10).
- **Flow control for frames.** The engine grants `FRAME_IN` credits as it pulls `FRAME_OUT` results, so a frame that yields before reading its input and a frame that reads all its input before yielding both make progress without filling a heap.
- **Operations.**
  - `HELLO` exchanges the protocol and C ABI versions. Since both sides come from one image, any difference is refused.
  - Then `DESCRIBE`, `VALIDATE`, `LOAD`, `OPEN_CONTEXT`, `OPEN_INSTANCE` and `CALL_BATCH`.
  - Frames: `FRAME_OPEN`, `FRAME_IN`, `FRAME_OUT`, `FRAME_CLOSE`.
  - Aggregates: `AGG_OPEN`, `AGG_UPDATE`, `AGG_MERGE`, `AGG_STATE`, `AGG_FINISH`, `AGG_CLOSE`.
  - `CANCEL` (for one `request_id`), the closes, and `SHUTDOWN`.
  - Replies: `OK`, and `ERROR`, which carries a `komira_udf_error` with its strings.
- **Schemas are sent once.** `LOAD` sends the argument, result and state schemas; batches carry only their bodies.
- **Cancellation.** `CANCEL` is sent out of band on the control channel; the worker sets that call's flag. If the worker has not answered after a grace period, the engine kills it.
- **Crashes.**
  - End of file on the control channel, or an exit by signal, is `UDF_WORKER_CRASHED`.
  - The host retries the batch on a new worker only when the UDF is not `VOLATILE` (§10.10).
  - State already merged in the crashed worker is lost with it. The host restarts the groups' accumulators from their input, or, in a streaming run, from the last checkpoint.

### 5.3 Which runtime uses which transport

The host chooses: `transport = host policy ∩ runtime.transports`. This is the policy for the runtimes komira ships:

| Runtime | Mode (§1.2) | Capabilities | Default on a remote host | Default on the producer's machine |
|---|---|---|---|---|
| `komira/python` (CPython with a GIL) | 2 | `SINGLE_THREAD`, `thread_affine`, `global_lock` 1; `IN_PROCESS` (`HOST_INTERPRETER`), `WORKER` (`EMBEDDED`). Later, `CONTEXT_PER_THREAD` with one sub-interpreter per engine thread where the UDF's packages allow it | Worker processes, one per engine thread | In-process on one engine thread for a quick preview (§3.3); workers for a full local run (§10.10's "same path") |
| `komira/python` on the free-threaded ABI (`cp313t`), later | 3 | `THREAD_SAFE`, `global_lock` 0 (refused if the GIL is enabled, below) | Workers (for crash containment), with one context per engine thread inside each | In-process |
| `komira/node` | 2 | `CONTEXT_PER_THREAD`, `global_lock` 0; `IN_PROCESS` (Node-API: one `worker_threads` isolate per context, Arrow buffers as external `ArrayBuffer`s), `WORKER` (launcher: `node`) | Worker processes, or in-process isolates where host policy allows | In-process isolates (the engine runs as a Node addon) |
| `komira/native` (Mojo, Rust, C, C++, Zig; first release; stages S3b, S3c) | 1 | `CONTEXT_PER_THREAD`, `global_lock` 0, fixed; each library must allow it (§1.2); both | In-process, when the heartbeat token stays in the supervisor (§1.2); the worker transport by opt-in, for crash isolation; workers on a host that cannot keep the token out of the engine | In-process |
| Future: JVM, .NET | 3 | `THREAD_SAFE`, `global_lock` 0; `WORKER` first | Worker | Worker |
| Future: Go (a Go shared library carries the Go runtime, one per process; §1.2) | 3 | `THREAD_SAFE`, `global_lock` 0; `WORKER` first | Worker | Worker |
| Future: `komira/wasm` (any language compiled to a WASM component, with a WIT world that mirrors §4.3, run by Wasmtime) | 2 | `CONTEXT_PER_THREAD`, `global_lock` 0; both | In-process (a memory-safe sandbox, with fuel or epoch deadlines) | In-process |

**Python requirements** (the `komira/python` runtime, stage S4):
- **In-process uses the host interpreter.** When the Python SDK loads the engine, the runtime must not start a second interpreter; it reports `HOST_INTERPRETER`. In a worker it embeds CPython and reports `EMBEDDED`. On the producer's machine the host checks the live interpreter's ABI tag against `needs.runtimes` before the first call.
- **The SDK's entry into the engine releases the GIL** (`Py_BEGIN_ALLOW_THREADS`, or a ctypes `CDLL`, not `PyDLL`). Otherwise the first callback from an engine thread deadlocks.
- **A persistent thread state per context.** A callback that calls `PyGILState_Ensure` on a thread with no thread state creates and destroys one on every call. That is a per-batch cost, and it clears `threading.local` state, so a UDF that caches a model in thread-local storage would reload it every batch. `open_context` creates a `PyThreadState` that lives as long as the context, on its affine thread.
- **Finalization.** The SDK registers an exit hook that drains the engine, so every `close_context` completes before interpreter finalization; `PyGILState_Ensure` from a foreign thread during finalization hangs or exits the thread.
- **The GIL decides the mode.** The runtime reports `global_lock` from the live interpreter (`sys._is_gil_enabled()`), so a GIL build never reaches mode 3 (§4.2). On a free-threaded build, importing an extension module that does not declare free-threading support re-enables the GIL, and CPython warns naming the module. The runtime checks again after `load` and `open_instance` import user code; if the GIL is now enabled it fails with `ERR_LOAD` naming the module (`OPTIMIZED_UDF_CODE_UNLOADABLE`), rather than run mode 3 behind a lock. Such a UDF runs on the GIL runtime, in mode 2.
- **Embedding in a worker.** Extension modules built to the manylinux policy do not link `libpython`. The embedded runtime loads `libpython` with `RTLD_GLOBAL` (or `dlopen(..., RTLD_NOLOAD | RTLD_GLOBAL)` once loaded), so `import numpy` finds the `Py*` symbols.

**Node requirements** (the `komira/node` runtime, stage S5):
- **In-process hands each batch to an isolate.** The engine thread cannot run JavaScript in an isolate it does not own, so `call_batch` posts the batch to its context's isolate through a thread-safe function and waits. The addon is context-aware (`NAPI_MODULE_INIT`), and each thread-safe function is created inside its worker thread's env.
- **The engine's JavaScript API is asynchronous.** A synchronous call on the main JavaScript thread that waits on that same env deadlocks.
- **External buffers, with a copy fallback.** Buffers are wrapped as external `ArrayBuffer`s whose finalizer queues the Arrow release (§4.4). `napi_create_external_arraybuffer` may return `napi_no_external_buffers_allowed` on runtimes built with the V8 sandbox, so the runtime has a copy path, and the conformance harness forces it.
- **Release `args` at return unless user code kept a view.** Garbage-collection finalizers may not run until the env is torn down, so relying on them would pin engine memory for an unpredictable time.
- **Cancel destroys the isolate.** The runtime terminates the worker thread and returns `ERR_INSTANCE_LOST`; the host opens a new context.

Notes:

- **WASM is a runtime, not the interface.**
  - The component model's canonical ABI copies values into linear memory ([Canonical ABI](https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md)), so it cannot share Arrow buffers.
  - One Arrow UDF project that runs several runtimes reports these costs per 1024-row batch ([arrow-udf](https://github.com/arrow-udf/arrow-udf)): native about 1.5 µs, WASM about 15.5 µs, JS about 85 µs, Python about 175 µs.
  - WASM earns its place as a sandbox for compiled languages, with no interpreter in the image.
- **A remote transport can come later.**
  - It would carry the same messages over Arrow Flight `DoExchange`, and needs no plan change.
  - Delivery would become at-least-once: BigQuery remote functions document duplicate requests ([docs](https://cloud.google.com/bigquery/docs/remote-functions)).
  - So the host would allow it only for UDFs that are not `VOLATILE`.
- **Native code must not unwind across the ABI.** C++ entries are `noexcept` and catch everything, returning `ERR_RAISED`; Rust entries catch panics with `catch_unwind` and return `ERR_RAISED`, and an uncaught panic in an `extern "C"` entry aborts the process. Each native SDK's export helper does this, so user code cannot forget it. A Go runtime (mode 3) needs every signal handler in its process installed with `SA_ONSTACK`, which is one reason it runs in workers first.

## 6. Language SDKs: the producer side

### 6.1 What a language SDK implements

1. **Verbs** that build `WireUdfApply`, `WireMapBatchesNode`, `AGG_UDF` measures and `WireStepNode`, mapping the language's idioms onto the kinds. §10.2's table is the Python and TypeScript instance.
2. **A way to declare types.**
   - It must yield a concrete Arrow `return_type`, and where needed `state_type` and `arg_types`, when the plan is built.
   - A missing type is refused by name on the user's machine (`UDF_RETURN_TYPE_MISSING`).
   - How the type is declared depends on the language:
     - A language whose types survive to run time (Python) may read them, from type hints or from a `return_dtype=` or `schema=` argument on the verb (§10.5).
     - A language whose types are erased (TypeScript) takes the type as a **value** on the verb. The static type is derived from that value, so the compiler still checks the function (§10.5).
     - For a `ROW` verb, the read set's types are the input columns' types, which the SDK knows when the plan is built; `columns=[...]` naming a column the input lacks is refused (`UDF_ROW_COLUMN_UNKNOWN`).
     - A native language (Mojo, Rust, C++, Zig; §1.2) derives the types from the function's signature when the library is built, through its SDK's mapping table (§6.2); the export helper records them in the library, and capture checks them against the verb's declared types. C, whose signatures cannot carry Arrow types, takes them as a value on the verb. A managed compiled language (Go) does the same as the native ones, in its own SDK.
3. **Capture.** The SDK:
   - chooses a `CodeForm`;
   - writes each code object to the code layer, under its sha256;
   - splits large captured values into `data_blobs`;
   - normalizes whatever does not change behaviour, so digests are stable across sessions;
   - writes its canonical descriptor and fills `UdfCode`.

   It refuses by name:
   - what cannot move to another process (`UDF_CAPTURE_UNSUPPORTED`);
   - credentials not wrapped as secrets (`UDF_CAPTURE_CREDENTIAL`);
   - captures that are too large (`UDF_CAPTURE_TOO_LARGE`).

   §10.6 is the Python and TypeScript instance.
4. **The code layer and the dependencies.** Code objects go under the image's code prefix, `/komira-code/`, named by hex sha256. That prefix is the `code_root` a runtime receives in `komira_udf_spec`. Dependencies live in the image, never in the plan (§10.11):
   - each runtime's installed dependencies go in its environment directory, `/opt/env/<runtime>/` (for `komira/python`, a virtual environment at `/opt/env/komira/python/`; the older name `/opt/venv/` is retired and no layer uses it);
   - a JavaScript bundle includes its pure-JavaScript dependencies and goes in the code layer under `/komira-code/`;
   - a JavaScript package with a native addon stays outside the bundle; the SDK records its name and exact version, and the image builder installs it for the host's platform into `/opt/env/komira/node/`, where the runtime resolves the bundle's external imports (§10.6).
5. **A local run through the same runtime and transport** (§10.10's "same path"), so that a capture error or a type error fails on the user's machine first.
6. **The read set of each `ROW` UDF** (§3.1), before the plan is optimized: `columns=[...]`, else the union of the recording proxy's reads during the local run and the SDK's static analysis, else every input column. The recording proxy treats whole-row operations (iteration, length, conversion to a dict or tuple, unpacking) as "undetermined".

A language may ship a producer without a runtime, for plans that reference only runtimes in the base image. It may also ship a runtime without a producer: a runtime that executes code another SDK captured, such as WASM components built by any toolchain.

### 6.2 Type mapping

**The Arrow type in the plan is the only source of truth.**
- Every runtime publishes its own mapping table, Arrow to the language's types and back, for both null modes. For a native UDF the table belongs to the language's SDK: the library receives Arrow C Data unchanged, and the SDK gives typed views of it (for example `arrow-rs` arrays in Rust, `komira_arrow` arrays in Mojo), so no value is converted inside the runtime.
- Each table states every loss.
- The format never encodes a native type.

The table below gives the shipped runtimes' rows for common types. Each runtime's full table is part of its own package documentation and of its conformance cases.

| Arrow | `komira/python`, `VALUES` | `komira/python`, batch | `komira/node` |
|---|---|---|---|
| bool | `bool` | numpy bool, or a pyarrow, polars or pandas column | `boolean` |
| int64 | `int` | `int64` column | `bigint`; a returned `number` is accepted while it is a safe integer |
| int32, int16, int8 | `int` | that width | `number` |
| float64, float32 | `float` | that width | `number` |
| large_utf8, utf8 | `str` | string column | `string` |
| large_binary | `bytes` | binary column | `Uint8Array` |
| date32 | `datetime.date` | date column | `Date` at UTC midnight |
| timestamp[us], no time zone | `datetime.datetime`, naive | timestamp column | `Date` (millisecond precision: microseconds are lost, and the table says so) |
| large_list<T> | `list` | list column | `Array` |
| map<utf8, T> | `dict` | map column | `Map` |
| struct | `dict` (or the declared `TypedDict` or dataclass) | struct column or frame | plain object |
| null in `MANUAL` mode | `None` (`NaN` or `pd.NA` in pandas, per §10.7) | the format's own null | `null` |

When a runtime's language cannot represent an Arrow type, its `validate` returns `ERR_UNSUPPORTED`. The plan is then refused at admission, and earlier by the language's own SDK, never in the middle of a run.

### 6.3 Conformance: the executable spec

A new runtime is done when it passes the **shared conformance corpus** as welded tests. The tests are `test_srcs` of the runtime's package, so the runtime cannot build unless they pass.

- **The corpus is language-neutral data, in two parts.**
  - **ABI cases** (stages S1-S5): Arrow IPC input files, a shape and declared types, and either an expected Arrow IPC output or a named error. The harness drives the C table directly.
  - **Plan cases** (stage S6): small optimized plans that run through lowering and the engine's UDF operators.
  - Each runtime adds a *fixture* for each case: the function, in its language, that the case expects. Examples: `double(x)`, `raise_on_row(3)`, `p95(v)`, a mergeable `sum`, a generator that yields three tables.
  - Every case runs on **both** transports, and the results are compared.
- **The harness and the operators share the host library** (`komira_udf_host`, §4.6): post-conditions, compaction, import validation and the error table. A test asserts that the S6 operators link that library; its mutant is an operator with its own length check that skips the shared one. So a runtime cannot pass by special-casing the harness.
- **Each case names the defect it catches, and the planted mutant that proves the case can fail.**

| Case | Defect caught | Planted mutant |
|---|---|---|
| Scalar over a batch with nulls, `PROPAGATE`; nested null children | The runtime is called for null rows | The host skips null compaction |
| `MAP_BATCHES_COLUMN` returns one row short | The length check is missing | Remove the length post-condition |
| A float function returns int64 | An unsafe cast is accepted | Cast float to int64 silently |
| A runtime returns the wrong `n_buffers`, or offsets past the data | The engine reads out of bounds | Skip import validation |
| Empty batch; empty group; an aggregate with no keys over empty input | Off-by-one on empty input | Skip the call on zero rows |
| Sliced input with an offset that is not a multiple of 8 | A reader ignores `offset` | Echo ignores the bit offset |
| Zero-argument scalar over 5 rows | The row count is lost | Take the length from the first child |
| `raise_on_row(3)` under `CASE WHEN` that never selects row 3 (plan case) | Eager evaluation of a branch | Evaluate both branches |
| The same input split 1×N and N×1 across two instances | A result depends on the instance or the split | An instance-local row counter |
| Mergeable `sum`, split `PARTIAL`/`FINAL` across two instances | A merge that is not associative; lost state | `agg_merge` overwrites instead of adding |
| 100 000 groups of one row, mergeable and plain | One crossing per group | A host that calls once per group (the case asserts crossings ≤ batches + pulls) |
| A frame generator yields before reading all its input; yields three tables, then raises | A borrowed input stream; lost batches; the wrong error row | Drain all input before the first output; buffer all output |
| `raise` on row 3 of 8 | An error code without a message; the wrong row | Return `ERR_RAISED` with a NULL message |
| Every array is released exactly once, including `args` on an error path | A leak or a double release | Count release callbacks; release `args` in both the runtime and the host on error |
| A UDF holds a view of every input batch (worker) | A full slot heap deadlocks | No copy-out fallback |
| Cancel flag set during a long call; a context that must be reopened | Cancel is ignored; a lost context is reused | Ignore the flag; reuse the context after `ERR_INSTANCE_LOST` |
| Worker calls `abort()` mid-batch | The crash is not mapped, or a `VOLATILE` batch is retried | Retry a `VOLATILE` batch |
| Two contexts in parallel (`CONTEXT_PER_THREAD`) | Mutable state shared across contexts | A global accumulator in the runtime |
| Node with external buffers disallowed | No copy fallback | Always create external buffers |
| A descriptor with a trailing unknown field; non-canonical bytes; a newer `descriptor_version` | The validator is too lax | `validate` always returns OK |
| A `STEP` returning a table with no columns | An empty table is mistaken for an error | Treat zero columns as failure |
| Round trip of every type in the runtime's mapping table | A silent loss beyond the stated ones | Truncate microseconds in Python |
| `ROW` with a conditionally read field: `f(r) = r.a if r.flag else r.b`, read set `{flag, a}` (recorded on a local run where `flag` was always true), over a batch where row 3 has `flag` false | An undeclared read returns null or a wrong value | The row proxy returns null for an unknown name |
| The same case with the read set `{flag, a, b}` (static analysis or `columns=[...]`) | A correct read set still fails | The proxy checks names against the input schema instead of the read set |
| `ROW` whose function catches the language's exception around the undeclared read | A caught violation passes silently | `call_batch` reports only uncaught errors |
| `ROW` reading 2 fields of a 100-column scan (plan case) | The row UDF keeps every column live | Lowering passes the whole input row; the case asserts the scan's projection and the `args` children equal the read set |
| Producer: a function that iterates its row; a local run with zero rows and no static result | A guessed read set too small | The recording proxy ignores iteration; an empty recording becomes an empty read set |

- **Reference runtimes ship with the harness.**
  - `komira-test/echo`, written in C, implements every entry trivially, with no user code and no code objects. It proves the harness and the transports independently of any language, and it is the template a new managed runtime copies: the C table it implements is the part every managed runtime writes around its interpreter. A test-only setting makes it report any `threading` and `global_lock`, or take one process-wide mutex around every call, so the mode cases below can plant their mutants without a language.
  - `komira/native` with fixture libraries next to echo, one per native language at the first release: C (`komira-test/native-c`), Mojo (`komira-test/native-mojo`), Rust (`komira-test/native-rust`), C++ (`komira-test/native-cpp`) and Zig (`komira-test/native-zig`). Each implements the corpus fixtures as exported native UDFs. The C library is the template a new native language's SDK copies; the Mojo library proves that a Mojo package can export the table. It builds with the existing `mojo_shared_lib` rule, which emits a C-ABI shared library from `@export` functions and can check that the library exports exactly the named symbols (`tools/build/mojo/README.md:20`, `:704-722`).
- **Cases per mode.** The harness derives the mode from `describe` (§1.2) and runs these in addition to the shared corpus, on both transports. A "managed" case runs for modes 2 and 3.

| Mode | Case | Defect caught | Planted mutant |
|---|---|---|---|
| 1 (native) | A library whose bytes differ from their sha256 | Unverified machine code is loaded | `load` calls `dlopen` before it checks the digest |
| 1 (native) | A spec with libraries only for another platform | A wrong-platform library is loaded, or the refusal comes mid-run | `validate` accepts any platform and `load` picks the first library |
| 1 (native) | Two fixture libraries that both define the same internal symbol | One library's symbol resolves into the other | Load with `RTLD_GLOBAL` |
| 1 (native) | A library that exports `komira_udf_runtime_init_v1` instead of `komira_udf_native_init_v1`, or a second symbol | A runtime and a user library are confused | Resolve either symbol |
| 1 (native) | A fixture that raises on row 3: a Mojo function declared `raises`, behind the Mojo export helper (S3b); a C++ fixture that throws and a Rust fixture that panics, behind their helpers (S3c) | An error escaping the export helper: unwinding across the ABI, or a Mojo error with no `ERR_RAISED` | An export helper without the catch |
| 1 (native) | A library whose `describe` reports `SINGLE_THREAD`, `thread_affine`, no `IN_PROCESS`, or another `runtime_id` | The host binds a library to concurrency it cannot take | `load` forwards without checking the library's capabilities |
| 1 (native) | Two Mojo fixture libraries loaded in one process, called from several engine threads | The Mojo runtime library cannot be shared in one process | None: it tests an assumption (§1.2), not host code. Red means Mojo libraries run on workers only |
| 1 (native) | A fixture that dereferences NULL, with the worker transport opted into | The engine dies with the library | Ignore the opt-in and run the library in-process |
| 1 (native) | In-process, a fixture that looks for the heartbeat token: its environment and arguments, `/proc/<supervisor pid>/environ` and `mem`, files the engine's user id can read, every inherited descriptor; then `ptrace` and a signal to the supervisor | The token, or the supervisor, is reachable from the engine, so in-process native code could forge or suppress heartbeats | The supervisor passes the token to the engine in an environment variable; the supervisor and the engine share one user id |
| plan case | A mergeable aggregate whose state for one group grows to 64 MiB, then one byte past it | The fixed cap is not enforced, is off by one, or is read from the plan | Accept a state equal to the cap plus one byte; take the cap from `max_state_bytes`. The case asserts `UDF_STATE_TOO_LARGE` naming the group key and the 64 MiB cap, and success at exactly 64 MiB |
| managed | Two contexts in parallel, each with a cached model | State shared across interpreters, isolates or per-thread UDF state | One interpreter, or one UDF state, shared by all contexts |
| all, except `SINGLE_THREAD` in-process (a pool of one) | Parallelism: N engine threads (N ≥ 4, each on a reserved core) each call a fixture that spins on the CPU for 200 ms in user code; the harness compares the process's CPU time with the wall time | A lock shared across engine threads: a global interpreter lock in a `THREAD_SAFE` runtime, or one interpreter or library lock serving every engine thread. The case requires CPU time ≥ 0.75 × N × wall time; under one lock it is about 1 × wall time | Echo with the process-wide mutex, reporting `THREAD_SAFE` and `global_lock` 0; on a GIL build, `komira/python` hard-coded to report `THREAD_SAFE` and `global_lock` 0 |
| 3 | A runtime that reports `THREAD_SAFE` with `global_lock` 1 (echo's test setting; a GIL build of `komira/python` patched to declare `THREAD_SAFE`) | A runtime with a global lock is bound as a shared parallel virtual machine | The host binds contexts from `threading` without reading `global_lock` |
| 3 | Free-threaded `komira/python`: a UDF that imports an extension module which re-enables the GIL (§5.3) | Mode 3 silently runs behind a lock | The runtime checks the GIL only at `init` |
| 2 | `SINGLE_THREAD` in-process, with N engine threads running UDF operators | One interpreter called from several engine threads | The host binds the one in-process context to every engine thread; the case asserts every call arrives on one engine thread |
| managed | A context used from a thread other than the one that opened it (`thread_affine`) | A thread state or env used off its thread | The host calls from any engine thread |
| managed | Runtime shutdown with arrays still held by the host | A release that needs the interpreter after it is gone | Finalize the interpreter before draining the release queues |

- **The coverage assertion** covers each native language's fixture library, every value of `UdfKind`, `CodeForm`, `UdfStability`, `UdfNullMode`, each capability bit, each of the three modes, both values of `global_lock` with `THREAD_SAFE` (bound and refused), and each `komira_udf_status`, on both transports.

## 7. Security, isolation, resource limits, crash containment

- **The engine treats user code as untrusted.**
  - In-process execution puts user code inside the engine's address space, with the engine's privileges and memory. Those are the run's own: the engine holds only what the run itself may use.
  - **The heartbeat token stays in the supervisor.** The supervisor holds no long-lived credential and none that meters usage, only a run-scoped id and token that authenticate its heartbeats; usage is metered from the accumulated heartbeats. It runs as its own process under its own user id, and the token never reaches the engine: not in its arguments, its environment, a readable file or an inherited descriptor (`optimized_plan_udfs.md` §10.10 [#1094]). So no user code, in the engine or in a worker, can read the token, forge or suppress a heartbeat, or trace or signal the supervisor. A conformance case holds the host to this (§6.3).
  - **Managed runtimes run in workers by default on a shared host,** for crash containment, hard limits and per-worker memory. A host permits them in-process only by policy, in three cases:
    - on the producer's own machine;
    - on a single-tenant host, where a crash that fails the run is acceptable;
    - for runtimes whose sandbox is the boundary (WASM).
  - **Native code (mode 1, §1.2) runs in-process by default,** on every host that keeps the heartbeat token in the supervisor; a host that cannot runs it in workers. The worker transport is opt-in for crash isolation, by host policy or a run option outside the plan.
- **Workers are isolated.**
  - They run as a further user id of their own, distinct from the engine's and the supervisor's.
  - They cannot read the supervisor's heartbeat token or channel, and cannot trace or signal the engine or the supervisor (§10.10).
  - The shared-memory region is created per worker and passed only to that worker.
  - The engine copies every worker-to-engine payload out of shared memory before it validates it (§5.2), so a worker cannot change bytes the engine has already checked.
  - Each worker has its own memory and CPU limit.
- **Only base runtimes run in-process.** A runtime library supplied by an added image layer (§8.3) runs only in workers. It is never loaded into the engine or the supervisor, so an added layer cannot place code in the engine. `komira/native` is a base runtime; the libraries it loads are user code from the code layer and follow the native default above (in-process, with the worker transport opt-in).
- **Code integrity.** On both transports, `load` verifies every code object against its sha256 before use (`OPTIMIZED_UDF_CODE_DIGEST_MISMATCH`). Admission already checks that the code is present (§10.11 check 4).
- **Resource limits.**
  - Memory per worker, from `worker_mem_bytes` or the observed footprint.
  - Native thread pools set to each worker's share of the CPUs (§10.10).
  - State per group capped at a fixed 64 MiB at the first release, the same on every host and not settable by a plan; a group over it fails the run with `UDF_STATE_TOO_LARGE`, naming the group key (§10.2). Making the cap tunable is tracked in komira-ai/komira#1148, and `max_state_bytes` (§10.8) is reserved for it.
  - Hard deadlines only in workers (§4.7).
- **Crash containment.**
  - A worker crash is `UDF_WORKER_CRASHED`; the batch is retried if the UDF is not `VOLATILE`, and the engine survives.
  - An in-process crash kills the engine process and fails the run. The supervisor reports it as a UDF fault when the runtime library is on the faulting stack *(inferred: this needs the supervisor's crash reporter)*.
  - This asymmetry is why managed runtimes default to workers on remote hosts, and why a native UDF that must not fail the run on a fault opts into the worker transport.
- **Captured data is data** (§10.6). Whoever can pull the image can read it, so the producer lists large captures before upload.

## 8. Versioning

### 8.1 The rule

| Contract | Promise | Why |
|---|---|---|
| The plan format: `UdfRef`, `UdfCode`, `RuntimeNeed`, the arms | **Backward compatible forever** (§9) | Plans are stored and replayed |
| A runtime's descriptor schema | **Readable forever by that runtime**, in every base that ships the runtime | The descriptor is part of the plan's identity |
| The C ABI, `komira_udf_runtime.h` | Entries and struct fields are only appended within a major version; a base accepts every minor of each major it lists | Needed only for runtimes built outside the base release (§8.3) |
| The worker protocol | **None across releases**; `HELLO` refuses any difference | The engine and the worker come from the same image |

**Negotiation.**
1. The engine calls `komira_udf_runtime_init_v1` with its `komira_udf_host`, whose `struct_size`, `abi_major` and `abi_minor` describe the engine.
2. A runtime built for a different major returns NULL with `ERR_ABI`.
3. Otherwise the runtime returns a pointer to its static table, which carries its own `struct_size` and minor. The host reads only fields below `min(table->struct_size, sizeof(the host's komira_udf_runtime))`; an entry past the runtime's size is absent and treated as unsupported. No side writes into memory sized by the other.
4. Every other struct is read the same way: each side reads only the fields both sizes cover, and a field the reader does not know is ignored.
5. The engine refuses a runtime whose minor is below the minimum required by a feature it needs (`ERR_ABI` → `UDF_RUNTIME_ABI_MISMATCH`).
6. A new major is a new symbol, `komira_udf_runtime_init_v2`, so one base can load runtimes of both majors.

This follows two precedents: DuckDB's C extension API, whose function struct is only appended to ([duckdb#14992](https://github.com/duckdb/duckdb/pull/14992)), and the Arrow C Device structs, which reserve space and add a new struct for any other change.

**Why this is enough.**
- The engine that runs a plan is the one in the plan's environment image.
- The runtimes komira ships are in the same base image, built in the same release, so they need no compatibility of the C ABI across releases.
- The ABI promise matters only for a runtime built and shipped separately (§8.3). Such a runtime must keep loading into newer bases without a rebuild for every release.

**Candidates for ABI 1.1, not in 1.0.** Entries the format may need later are left out of 1.0 rather than frozen with undefined meaning:
- **`snapshot` and `restore`** for a callable's own state, kept across a restart by a streaming checkpoint. ABI 1.0 has neither, and the plan spec says so: a restarted worker loads the code again and starts with empty state, and keeping a callable's own state needs these entries (`optimized_plan_udfs.md` §10.10, the bullet on worker state across a restart, which cites this section [#1094]). Their meaning must be fixed first: per instance, called by the host only between calls at a checkpoint barrier, returning one Arrow value. Until they exist, a restarted context starts with empty state, and mergeable aggregate state is checkpointed through `agg_state`.
- **Per-row errors** for a TRY form (§4.5).

### 8.2 Plans stay readable forever

- Decoding and admitting a plan never needs a runtime, because the format is neutral. A plan that names a runtime no base has ever shipped still decodes; it is then refused at admission by name (§3.1), never misread.
- A stored plan executes in the environment image it was recorded with (§10.12), so its runtime is present.
- When a plan moves to a newer base, that base's runtime with the same id must read the plan's `descriptor_version`.
  - A runtime never drops a released descriptor version while any base ships the runtime.
  - The corpus enforces this. Each runtime's descriptor corpus holds one plan per released descriptor version, and a newer runtime that refuses one turns its welded test red.

### 8.3 Runtimes outside the base

- **Packaging.** A third-party runtime ships as an added image layer, under the reserved prefix `/komira-runtimes/<namespace>/<name>/`. The layer holds the library and a manifest: `runtime_id`, `runtime_abi`, the C ABI major and minor, the library's sha256, and its launcher (§4.1).
- **The registry.** The image's runtime registry is the base's release record plus these manifests.
- **Header-only admission (§10.11 check 3)** accepts a `needs.runtimes` pair that the base lists, or that an added runtime manifest layer declares. The layer is identified by its digest in the image manifest *(inferred: the scheduler cannot read layer contents, so the base release record must name the form of the manifest digest; the detail is left to the image design)*.
- **Host admission** re-checks the manifest and the library's digest once the layers are in hand.
- **Execution.** Such a runtime always runs in workers (§7).

## 9. Implementation stages

Each stage lands with its tests welded and its testing plan stated: what each test proves, and the mutant that turns it red.

| Stage | Work | Owner area | Done when |
|---|---|---|---|
| S0 | This document, and the optimized-plan UDF section aligned to it before any `format_version` ships [#1094]: open runtime ids, `CodeForm`, `needs.runtimes`, `STEP`, the two `MAP_BATCHES` kinds and the `ROW` kind (`DataFrame.apply(f, axis=1)` and `map_rows` map to `ROW`) | design | Both merged |
| S1 | `komira_udf_runtime.h`; a Mojo binding package, with private pointers behind a safe API; the Arrow C Device structs; an args exporter on the stream path's shared-reference model, and C Data import without copying, with layout validation and release ownership, in `komira_arrow_ipc`; the host library `komira_udf_host` (post-conditions, compaction and scatter, error table); the reference runtime `komira-test/echo`, in C | engine, Arrow | Echo passes every ABI case in-process; the leak, double-release and skip-validation mutants go red |
| S2 | The conformance corpus package (ABI cases), the harness and the coverage assertion; the runtime-swap invariance test for the optimizer (§3.2) | tests, optimizer | The corpus runs against echo; the invariance mutant goes red |
| S3 | The worker transport: `komira_udf_worker` and `komira-udf-worker`, slot heaps, worker-to-engine copy-out, IPC framing, frame credits, `HELLO`, cancel, crash mapping; supervisor integration (user id, limits, `posix_spawn`) | engine, supervisor | Echo passes the corpus on both transports; the worker-abort, held-views and cancel cases pass |
| S3b | The `komira/native` runtime (§1.2): digest check before `dlopen`, library choice per platform, `komira_udf_native_init_v1`, forwarding; the fixture libraries `komira-test/native-c` and `komira-test/native-mojo`; export helpers for C and Mojo; the native cases (§6.3) | engine, Mojo | Both fixture libraries pass the corpus and the native cases on both transports; the digest-after-`dlopen`, `RTLD_GLOBAL`, unchecked-capabilities and missing-catch mutants go red (the catch case uses the Mojo fixture's raising function; C cannot raise); the heartbeat-token case passes in-process |
| S3c | Native SDKs for Rust, C++ and Zig, at the first release with C and Mojo: export helpers (Rust catches panics, C++ is `noexcept`, §5.3), typed views of Arrow C Data, capture of the library into the code layer; fixture libraries `komira-test/native-rust`, `komira-test/native-cpp`, `komira-test/native-zig` | engine, SDKs | Each fixture library passes the corpus and the native cases on both transports; the C++ throw and Rust panic cases go red without the catch |
| S4 | The `komira/python` runtime: in-process on the host interpreter, and worker (CPython embedded in the worker); batch formats in the descriptor; the requirements of §5.3; the `ROW` proxy, and the producer's recording proxy and read set (§6.1) | Python | Python fixtures pass the corpus, `ROW` cases included, on both transports |
| S5 | The `komira/node` runtime: Node-API in-process, with one `worker_threads` isolate per context and external `ArrayBuffer`s with a copy fallback; worker processes launched by `node` | Node | Node fixtures pass the corpus on both transports |
| S6 | Physical operators (`UdfProject`, `UdfFrame`, `UdfAggregate`, the groups accumulator, `UdfStep`) in lowering, linking `komira_udf_host`; the plan cases. They replace the SDK-side walk that works around the package cycle (`expr_udf_sites.mojo:1-30`) | engine | UDF plan cases run through lowering, not through the SDK |
| Later | ABI 1.1 candidates (§8.1); third-party runtime layers (§8.3); further native languages (each adds an SDK and fixtures, no runtime id); a tunable per-group state cap (komira-ai/komira#1148); managed runtimes for JVM, .NET, Go and WASM; free-threaded Python; GPU devices; remote transport | — | Each native SDK adds corpus fixtures; each managed runtime adds a runtime id and fixtures; neither changes the format |

**Validating the design with prototypes.** Five prototypes exercise the cells this design depends on. Each should implement the §4.3 table, or the subset it exercises, so its numbers measure this interface and not a one-off bridge.

| Prototype | What it validates | What it measures, and what result would change the design |
|---|---|---|
| P1: Python in-process, through a C callback | The ownership rules of §4.4 (`args` moved in, `out` produced by the runtime, the callback held by the context); `SINGLE_THREAD` on one engine thread (§3.3); the persistent thread state and the GIL release on SDK entry (§5.3) | Overhead per batch on one engine thread. If single-threaded in-process beats workers at small batches, keep it as the local default. Never make it the remote default (§7) |
| P2: Python worker, over Arrow IPC on shared memory | The framing of §5.2, in-place decode engine-to-worker, slot heaps, crash mapping; embedding with `libpython` loaded globally | Round-trip cost per batch compared with P1, the cost of the worker-to-engine copy, and the batch size at which the difference stops mattering. If the slot cannot be decoded in place, §5.2 is wrong and must say so |
| P3: Node in-process, through Node-API | Wrapping external `ArrayBuffer`s with the release queued from the finalizer; the handoff to an isolate; the `node` launcher | Handoff latency per batch; how long `args` stay pinned when user code keeps no view, which feeds §4.8 |
| P4: per-thread contexts (a pool of Python workers, Node isolates) | Mode 2: `CONTEXT_PER_THREAD`, `SINGLE_THREAD` workers and the pool binding (§3.3) | The scaling curve from 1 to N cores; memory per context with a loaded model, which feeds the pool-size rule |
| P5: one native library, in-process and in a worker | The `komira/native` loader and forwarding (§1.2); the same library bytes on both transports | Cost per batch on each transport at several batch sizes. This sets how much opting a native UDF into the worker transport costs, and the batch size at which the opt-in stops costing more than the crash isolation is worth |

Every prototype and benchmark here runs on the build farm's existing benchmark support, not a harness of its own. Whatever the prototypes measure, the results do not change the plan format. They choose host defaults and capability values. Keeping the transport out of the plan is what makes this true.

## 10. Options considered

| Option | Verdict |
|---|---|
| A closed runtime enum, with one `oneof` arm per language's code form (an earlier draft; Spark Connect's shape) | Rejected. Each language becomes a format change, an optimizer change and a validator change, forever. SPARK-55278 proposes moving Spark away from it. |
| A fully neutral code record (`{form, bundle, module, symbol, payload, serializer}`) that every language fills the same way | Partly adopted. `form`, `entry` and the digest list are neutral, and admission reads them. What genuinely differs between languages (serializer, batch format) goes in the descriptor the runtime owns. |
| An opaque descriptor only, with no neutral `form`, `entry` or digest list | Rejected. Admission could not check that code is present without the runtime, and diagnostics could not name the entry. |
| The runtime's ABI tag in `UdfCode` | Rejected. It would change a reference's identity on every interpreter upgrade, and allow plans that name two ABIs of one runtime. It lives only in `needs.runtimes`. |
| The `MAP_BATCHES` form derived from the arm that targets it | Rejected. One `UdfRef` could then be bound with two schemas; the shape is in the kind. |
| The transport chosen in the plan | Rejected. The transport is a host-local decision (§5.3). Putting it in the plan would only cause refusals on hosts whose policies differ. |
| An ABI that mirrors one engine's traits (DataFusion's FFI crate, written for Rust libraries, [README](https://github.com/apache/datafusion/blob/main/datafusion/ffi/README.md)) | Rejected. Plain C over Arrow is the only ABI every language can implement. |
| The WASM component model as the outer ABI | Rejected. The canonical ABI copies values, and Python in WASM loses native packages. Kept as one runtime. |
| Calls per row (PostgreSQL's Datum convention; Trino's invocation per position, [trino#30301](https://github.com/trinodb/trino/pull/30301)) | Rejected. Calls are one batch at a time, and a scalar runtime loops in its own language. |
| Aggregate calls per group, with an opaque handle per group | Rejected. A high-cardinality group-by would cross the ABI once per group per batch. Aggregates are vectorized over groups, as DataFusion's `GroupsAccumulator` is. |
| Aggregate state that is pickled or private to the language | Rejected. `state_type` is Arrow: it crosses exchanges and checkpoints, and it has a size the host can cap. |
| A separate determinism field | Rejected. `stability` is the determinism declaration. |
| A row-shaped UDF as a `SCALAR` over the whole row, or a host that infers the fields read | Rejected. The whole row keeps every column live; a host cannot re-derive what the producer knew, and two hosts could disagree. `ROW` declares the read set in `arg_types` (§3.1). |
| A separate `read_set` field beside `arg_types` in a `ROW` | Rejected. It would state the bound argument schema twice. |
| A `cancel` entry callable from any thread or a signal handler | Rejected. It races with close and cannot be built for CPython or Node-API. Cancel is a per-call flag (§4.7). |
| Zero-copy decode of worker-to-engine payloads, with sealed per-payload memory files (`F_SEAL_WRITE`) | Not chosen for the first release. It removes one copy but adds a file per payload; the copy-out is simpler and P2 measures its cost. |
| A mode field in `UdfRef`, or a plan rule per mode | Rejected. The mode is how a runtime executes code, which is a host fact like the transport. It is derived from capabilities (§4.2), and the plan carries all three modes identically (§1.2). |
| A `udf_mode` capability beside `udf_class` and `threading` | Rejected. It would state the mode twice, and the two could disagree; the host derives it (§1.2). |
| `THREAD_SAFE` as one context shared by all engine threads (an earlier draft of this document) | Rejected. Each engine thread keeps its own UDF state in every mode, so a UDF's cached objects are never contended; mode 3 shares only the virtual machine, which has no global lock (§1.2). |
| One in-process GIL interpreter serving every engine thread | Rejected. The GIL would be a lock shared across engine threads. A GIL runtime reaches parallelism through one interpreter per engine thread (mode 2). |
| One runtime id per native language (`komira/rust`, `komira/mojo`) | Rejected. Native languages share one ABI, so one loader serves all; the language is in the descriptor for diagnostics. A new native language adds an SDK, not a runtime. |
| Native UDFs in workers by default, until a host shows in-process native code cannot reach privileged credentials (an earlier draft) | Rejected. The supervisor holds no credential that meters usage, only a run-scoped heartbeat token, kept in its own process and user id and never passed to the engine, so in-process native code reaches only the run's own privileges. Native UDFs run in-process by default, and the worker transport is opt-in for crash isolation (§1.2, §7). |
| A per-group state cap set per host or per plan at the first release | Not chosen. A fixed 64 MiB cap is the same on every host, so a plan that runs on one runs on all; tuning it is komira-ai/komira#1148, with `max_state_bytes` reserved. |
| One base carrying several CPython minors or Node majors, or both a Python and a Node runtime | Rejected. A release ships one base per CPython minor and one per Node major, each with one managed runtime, and a remote run follows the client's version; a plan that needs two managed runtimes is refused with `OPTIMIZED_ENV_RUNTIME_MISSING` (§3.2). |
| Go as a native language (mode 1), or in mode 2 | Rejected. A Go shared library carries the Go runtime (scheduler, collector, signal handlers, one per process), so it is managed; that runtime runs cgo calls from several threads in parallel with no global lock, so it is mode 3 (§1.2). |
| One generic worker executable for every runtime | Rejected. Node-API is exported by `node`, and embedding Node is not ABI-stable. Each manifest names its launcher; the protocol library is shared. |
| No ABI promise at all (internal to the image only) | Rejected. Third-party runtimes would need a rebuild for every base release. The promise costs only a header and a version check. |
