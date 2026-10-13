# Design: one UDF runtime interface for every language

Status: proposed, not built. Nothing was built or run for this revision; earlier prototypes informed it (§9). Citations are to komira `main` as of 2026-10-09, except those to the optimized-plan design, which are to `main` after komira-ai/komira#1094 merged it: `docs/design/optimized_plan.md`, `docs/design/optimized_plan_udfs.md` and `docs/design/optimized_plan_udf_runtime.md` (split from `optimized_plan_udfs.md` by komira-ai/komira#1507).

Section numbers:
- `§10.1` to `§10.9` refer to `optimized_plan_udfs.md`; `§10.10` to `§10.14` refer to `optimized_plan_udf_runtime.md`.
- `§7.x`, `§9.x` and `§11` refer to `optimized_plan.md`; a citation of its other sections names the file.
- Every other section number is this document's.

Statements marked *(inferred)* are my reading, not facts taken from the code.

The optimized-plan design says what a plan carries and how it is admitted. This document says what a language must implement so that a plan can call a function written in it. It also says what the plan must carry, and must not carry, for that to work for any number of languages.

---

## 1. Goals, non-goals and one mode per language

### 1.1 Goals and non-goals

**Goals.**

1. **Each language implements one interface, once.** To gain UDF support, a language ships three things:
   - a *runtime* that implements one contract, the C ABI (§4); a native language (§1.2) ships none, because its UDFs implement the contract themselves and the one `komira/native` runtime loads them;
   - a *producer* in its SDK that emits UDF references (§6);
   - a pass of the shared conformance corpus (§6.3).

   Nothing else in komira changes.
2. **The plan formats never change per language.** Adding a language adds no field, no `oneof` arm and no enum value to any plan message. Language identity lives in one open, namespaced string (§3.1). The optimizer and the plan validator never branch on it, and a test holds them to that (§3.2).
3. **Plans stay backward compatible forever.** Every later engine decodes, admits and lowers every released plan that contains a UDF (§9.1, §10.12). Each runtime keeps its own runtime-specific bytes readable forever (§8.2).
4. **The C ABI is the abstraction.** The engine loads every runtime as a library, in its own process, and calls it through one C ABI over the Arrow C Data Interface (§4). How a runtime executes user code is the runtime's own business: native libraries run in-process; the Python and Node runtimes run user code in worker processes that they start and manage themselves (§1.2, §5). The engine and the plan never name a transport.
5. **The engine crosses into a runtime once per batch, never once per row and never once per group,** with no copy at the C ABI (§4.4).
6. **A row-shaped or frame UDF stays columnar when its SDK can say what it reads.** A function that takes a whole row (`df.map_rows(f)`, pandas `apply(axis=1)`) or a whole table reads only the columns of its `UdfRef`'s `read_set` when the SDK sets it, and every other column is pruned down to the scan (§3.1).

**Non-goals.**
- GPU UDFs. The ABI reserves their shape (§4.2), but §10.2 defers them.
- Remote UDF servers. §5 notes how one would fit later.
- A "register" step visible to users. §10.13 rejects it.
- An optimizer cost model per language.

### 1.2 One mode per language: native in-process, managed in worker processes the runtime owns

A UDF belongs to one of two classes, and each language has exactly one mode. The mode is how that language's runtime executes user code; it is chosen by the runtime, not by the engine, a host or the plan. **In every mode, no lock is shared across engine threads**: no engine thread ever waits on another engine thread's UDF call.

| | Native | Managed |
|---|---|---|
| Languages | Languages that compile to native code and speak the C ABI directly: C and Mojo at the first release; Rust, C++ and Zig later | Languages whose code runs in an interpreter or virtual machine: Python and Node/TypeScript at the first release |
| What the code object is | A shared library compiled for the host platform (OS and CPU) that implements the UDF runtime C ABI (§4.3) itself | Source, bytecode or a serialized value that the language's runtime executes |
| Runtime id | `komira/native`, one id for every native language | One per language runtime: `komira/python`, `komira/node` |
| How the runtime executes user code | In the engine's process: `komira/native` loads the library and calls it through the C ABI over Arrow C Data, without a copy | In worker processes the runtime library starts and manages: `komira/python` forks its workers from a single-threaded zygote; `komira/node` starts `node` processes. One worker serves one context (§5, informative) |
| Capabilities (§4.2) | `udf_class` `NATIVE` | `udf_class` `MANAGED`; `features` `CONTAINS_CRASHES` and `FORCED_STOP` |

**The C ABI is the only interface between the engine and a runtime.** The engine loads every runtime library in-process, opens one context per engine thread, and makes the same calls for every runtime (§4.3). It never starts a worker, never speaks a worker protocol and never chooses a transport. A runtime that runs user code elsewhere does so behind the table, and reports what it guarantees (a crash in user code is contained; user code that ignores a cancel can be stopped) as capabilities (§4.2), never how it achieves it. The class is not a plan field. The optimizer and plan validation never read it, and the runtime-swap invariance test holds them to that (§3.2). Only the conformance harness reads it, to select the class-specific cases.

**Later managed runtimes take the managed mode.** A JVM, .NET or Go runtime is managed; like every runtime, it chooses how it executes. Go compiles to native code, but a Go shared library carries the Go runtime: its scheduler, its garbage collector and its own signal handlers, one per process *(inferred: two Go shared libraries built separately each carry one)*. So Go is not native.

**Mojo is native, although its libraries need a runtime library.** Every `mojo_shared_lib` output has `DT_NEEDED libKGENCompilerRTShared.so`, which holds the Mojo allocator, async runtime and globals (`tools/build/mojo/README.md`). Unlike Go's runtime, it is a support library in the way `libstdc++` is for C++: it does not own the threads that call into it and does not take over the process's signals, so several Mojo libraries and the engine can share one process *(inferred; a native case checks it with two Mojo fixture libraries called from several engine threads in one process, §6.3)*. What happens if that check fails is open (§1.3).

**The native runtime, `komira/native`.** It is a base runtime with no interpreter: a loader that forwards the C ABI to user libraries.
- **Code.** `form` is `BUNDLE`. `code` lists one shared library per target platform, with the role `lib:<os>-<cpu>` (for example `lib:linux-x86_64`, `lib:linux-aarch64`). `entry` names the UDF inside the library, since one library may hold many UDFs. The descriptor records the entry's shapes and signature (§3.1, *Descriptor rules*), and the source language and toolchain, for diagnostics only; the runtime never dispatches on the language.
- **Platform.** `validate` refuses a spec with no library for the host's platform (`ERR_UNSUPPORTED`, §4.5). So a plan whose native code was not built for the host is refused at admission, by name, never in the middle of a run.
- **Validation without the library.** `validate` compares the spec with the descriptor: the entry, its shapes and its signature. It opens no library, so no library constructor runs at admission.
- **Loading.** `load` verifies the library's sha256 *before* `dlopen` (`RTLD_LOCAL | RTLD_NOW`, never `dlclose`d, as §4.3 states for runtimes). It resolves the library's one exported symbol, `komira_udf_native_init_v1`, which has the signature of `komira_udf_runtime_init_v1` and returns a `komira_udf_runtime` table. It negotiates that table's minor as §8.1 does, checks the library's `describe` (next item), calls the library's own `validate` with the spec, so that the library confirms the signature the descriptor recorded, and forwards every later entry to the table. A library that disagrees with the descriptor is refused with `ERR_LOAD` (`OPTIMIZED_UDF_CODE_UNLOADABLE`). The distinct symbol name keeps a user library from being registered as a runtime, and a runtime from being loaded as a user library.
- **Capabilities.** A library's own `describe` must report `runtime_id` `komira/native`, `udf_class` `NATIVE` and the spec's shape in `shapes`; `load` refuses any other library with `ERR_LOAD`, naming the capability (`OPTIMIZED_UDF_CODE_UNLOADABLE`). Every native library must allow what the host does with it: the host opens one context per engine thread, never calls one context from two threads at once, and may call a context from different threads over its life. A library that cannot be called from two threads, even in two contexts, or that serializes its calls behind one lock, is not supported at ABI 1.0 (a decision, §1.3); the parallelism case (§6.3) catches it.
- **ABI tag.** The `runtime_abi` of `komira/native` in `needs.runtimes` is the C ABI major its libraries target (`abi1`).
- **One id for every native language.** Every native language speaks the same C ABI, so the language is not part of dispatch. A new native language adds an SDK: helpers that export the table from a function's signature (an `extern "C"` Rust function, a `noexcept` C++ function, an exported Mojo function), a typed view of Arrow C Data in that language, and capture of the library into the code layer. It adds no runtime id and no change to the base.

**Native UDFs ship at the first release, in-process.** A native UDF is machine code inside the engine's address space, with the engine's privileges. It has the lowest cost per batch (no copy, no interpreter, no process boundary), and a fault in the library ends the engine and fails the run.
- **What in-process code could reach.** The engine holds only what the run itself may use, which is the user's own. The one secret a run must not reach is the supervisor's run token: a token scoped to one run, which the supervisor uses only to report that the run is alive. The supervisor holds no long-lived credential (`optimized_plan_udf_runtime.md` §10.10).
- **The rule: the run token stays in the supervisor.** The supervisor runs as its own process under its own user id, distinct from the engine's, and never passes the token to the engine: not in the engine's arguments or environment, not in the supervisor's own command line, not in a file the engine's user id can read, not through an inherited descriptor or a socket the engine can connect to. The supervisor learns that the run is alive by observing the engine process itself (a process descriptor, `waitpid`), never from a message the engine sends. So code in the engine can end the run, but cannot read the token, report on the run, or trace or signal the supervisor (§7).
- **Launch gates** (§6.3). Native UDFs do not ship until these pass on the release's hosts:
  1. **The run-token case:** in-process native code cannot find the token or reach the supervisor.
  2. **The `RTLD_GLOBAL` interposition case:** two libraries that define the same internal symbol each resolve their own, so one user library does not interpose on another or on the engine by symbol resolution. In-process code can still modify anything in the engine's memory (§7).
  3. **The NULL-dereference case:** a native fixture dereferences NULL in-process. The run fails with a named UDF fault naming the library, no partial output of the run is committed, and the next run on the host is unaffected. The supervisor's crash reporter that names the library is an S3b deliverable (§7, §9).

### 1.3 Open questions and decisions to confirm

Open, to be settled before the stages they name:
1. **A failed Mojo shared-process check (S3b).** If two Mojo libraries cannot share one process, Mojo has no mode at the first release.
2. **Runtimes from an added image layer (later; §8.3).** The engine loads every runtime in-process, so an added runtime library would run inside the engine, with the standing of a native UDF library. This reverses an earlier draft, in which added runtimes ran only in workers; whether they are allowed on this basis is open.
3. **WASM** has no mode yet; it gets one when it is added.
4. **The optimized-plan UDF section (S0) is aligned with this document.** `optimized_plan_udfs.md` §10.1 gives one mode per language (§1.2) and §10.3 carries `UdfRef.read_set` (§3.1); the read-set checks are in its §10.4, and `optimized_plan.md` §7.1 emits a set message field even when empty. Nothing is retried after a loss (§4.5): `optimized_plan_udf_runtime.md` §10.10 fails the run on a crash, and `optimized_plan_udfs.md` §10.7's *Delivery* paragraph and the `STABLE` row of its stability table say the same.
5. **`read_set` beyond `ROW` and `MAP_BATCHES_FRAME` (S0).** Today any other kind with a `read_set` is refused (§3.1); whether another kind should take one is open.
6. **Whether a UDF's state id changes when its `read_set` changes (S0).** `read_set` is part of the `UdfRef` bytes, so it is part of the UDF's identity; whether streaming state keyed by that identity survives a change of read set is open.
7. **The error for a frame that reads a column outside its read set (S0).** §3.1 proposes `ERR_RAISED` (`UDF_RAISED`), because the frame's data library raises it, with the read set appended to the message; a named error of its own is the alternative.

Decisions this document makes that go beyond the language rulings it implements:
- The capability vocabulary: `udf_class`, and the features `MEMORY_REPORT`, `CONTAINS_CRASHES` and `FORCED_STOP` (§4.2).
- No lock is shared across engine threads, in either mode (§1.2, §6.3).
- A native library that serializes its calls behind one lock is not supported (§1.2).
- A base carries one managed runtime besides `komira/native`, so a plan that needs both `komira/python` and `komira/node` is refused (§3.2). This predates the one-mode rule.
- The capability fields that described a transport (`threading`, `global_lock`, `thread_affine`, `hosting`, `transports`) are removed, not split, because a transport is no longer the engine's (§4.2, §10).
- The Python and Node workers run under the engine's user id (§5, §7). This relaxes an earlier draft, which gave workers a user id of their own. It also means `CONTAINS_CRASHES` covers accidental crashes only: a malicious worker can kill or trace the engine.
- A runtime that runs user code in another process copies its results out of memory that process can still write (§4.4).
- A call whose user code was stopped by force returns its own status, `ERR_KILLED` (§4.5, §4.7).
- A runtime that cannot tell a crash from a stop for memory reports a crash (§4.5).
- Nothing is retried after a lost context: any `ERR_INSTANCE_LOST` or `ERR_WORKER_CRASHED` fails the run with `UDF_WORKER_CRASHED`, naming the UDF and the signal or exit status (§4.5). Automatic retry is rejected for the first release (§10).
- Calls on one context are serialized, with one exception: while a frame waits on its `in` pull, the host may call into the same context to produce that input (§4.3). This keeps pipelines fused and keeps one context per engine thread (§1.2); runtimes must support it.
- A grouped frame's read set must contain its `group_by` columns (§3.1).
- A read-set mismatch found by `validate` has its own status, `ERR_READ_SET_MISMATCH` (§4.5).
- An unknown status from a newer minor is treated as `ERR_INTERNAL` (§4.4), and `ERR_FIELD_NOT_DECLARED` is not bisected (§4.5).
- Go is managed; its runtime chooses how it executes (§1.2).

## 2. What exists today, and why the shape must change now

**The logical plan names a function, and the receiving process resolves the name.**
- `WireUdfCall` carries `name=1`, `in_arrow_type_id=2`, `out_arrow_type_id=3` and a single `child=4`. That child "MAY NOT BECOME `repeated`" (`src/komira_plan_proto/plan.proto:791-824`).
- The node form, `WireUdf` (`plan.proto:1186`), mirrors `UdfData` (`src/komira_plan_expr/udf_data.mojo:216-293`). The `UdfData` field `operator_factory_id` only means something for a Mojo function known at compile time.
- A UDF whose name cannot be resolved is refused (`plan.proto:88-94`).
- No field names a language.

**The engine's vocabulary is already language-neutral.**
- Kinds: `UDF_KIND_MAP/FILTER/AGG` (`udf_data.mojo:143-145`).
- Null modes (`:154-156`) and stability (`:165-167`).
- Parallelism contracts: `STATELESS`, `SERIAL_ORDERED`, `MERGEABLE`, `PARTITION_LOCAL` (`:186-189`), carried on the wire as `WireUdf.parallelism_tag` (`plan.proto:1204`). The optimized-plan `UdfRef` has no parallelism field; §3.4 states the rule that replaces it.
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

**Why the plan format must not name languages.** A plan format with a per-language shape hard-codes its languages in at least six places. This design keeps the plan language-neutral in each of them, and the optimized-plan UDF section follows it:

| Place | A per-language format would carry | This design carries | In the plan spec |
|---|---|---|---|
| The runtime | A closed enum (`PYTHON \| NODE`); a new runtime is a new value | An open, namespaced string, `UdfCode.runtime` (§3.1) | `optimized_plan_udfs.md` §10.3, `UdfCode` |
| The code form | A `oneof` with one arm per language's code form | A neutral `CodeForm` (`PACKAGE`, `BUNDLE`, `VALUE`), an `entry`, a digest list and a runtime-owned descriptor (§3.1) | §10.3, `UdfCode` and `CodeForm` |
| The batch format | An enum mixing the neutral `ARROW` with `PANDAS`, `POLARS`, `NUMPY` and per-language value formats | A field of each runtime's descriptor (§3.1, *Descriptor rules*) | §10.3, the informative table of descriptors |
| The kinds | A kind named after a language (a Python step) and an arm named after it | Shapes only: `STEP` and `WireStepNode` (§3.1) | §10.2, the kinds table; §10.4, the step arm |
| The ABI | One `DeclaredNeeds` field per language, each in the digest trailer | One `repeated RuntimeNeed runtimes` (§3.2) | `optimized_plan.md` §6.1, `DeclaredNeeds`; §7.1, the `DigestTrailer` |
| Admission | Checks, load checks, path prefixes and error codes written per language | Checks over the neutral fields; the rest is each runtime's `validate` and `load` (§3.1, §4.3) | `optimized_plan_udf_runtime.md` §10.11, from "Added layers write only their prefixes" through "Load check" |

Each of these places is part of a format that stays compatible forever. Had the format been released with a per-language shape, every new language would cost a `format_version` bump plus new optimizer and validator code, forever. No `format_version` has shipped, so the plan spec takes this shape before its first release, and an earlier draft's per-language fields are reserved, never reused (§10.3).

Spark Connect took the path of one arm per language: `CommonInlineUserDefinedFunction` has `PythonUDF`, `ScalarScalaUDF` and `JavaUDF` arms ([expressions.proto](https://github.com/apache/spark/blob/master/sql/connect/common/src/main/protobuf/spark/connect/expressions.proto)). Spark's Python eval-type enum grew to dozens of values that mix shape, format and mode ([pyspark/util.py](https://github.com/apache/spark/blob/master/python/pyspark/util.py)). SPARK-55278 proposes a language-agnostic UDF protocol for Spark ([JIRA](https://issues.apache.org/jira/browse/SPARK-55278)). This design starts language-neutral instead of retrofitting it.

## 3. The three plan levels

### 3.1 Logical plan: the UDF reference

A `UdfRef` describes one UDF. In a RAW (bound, logical) plan, the list of `UdfRef`s comes from `WirePlanEnvelope.udfs`. In an OPTIMIZED plan, it comes from `needs.udfs` (§10.4). As in §10.3-§10.4, the plan body refers to an entry by its index.

```proto
message UdfRef {
  UdfKind      kind        = 2;   // a shape, never a language (below)
  UdfCode      code        = 16;  // which runtime, which entry, which code bytes
  repeated WireField arg_types = 17; // declared argument types, in call order; for ROW and MAP_BATCHES_FRAME, the
                                     // columns received: read_set's if set, else every input column (*Types*, below)
  WireField    return_type = 8;   // required; nested to any depth (WireField.children, §10.3)
  WireField    state_type  = 15;  // AGGREGATE only; set iff the mergeable form (§10.2)
  UdfStability stability   = 10;  // IMMUTABLE | STABLE | VOLATILE: this is the determinism declaration
  UdfNullMode  null_mode   = 11;  // MANUAL | PROPAGATE
  UdfResources resources   = 12;  // §10.8, unchanged
  repeated bytes data_blobs = 6;  // sha256 of each captured value stored apart from the code (§10.6)
  bool         preserves_event_time = 18;  // MAP_BATCHES_FRAME only: event time passes through (§10.3)
  UdfReadSet   read_set    = 19;  // ROW and MAP_BATCHES_FRAME only; unset = reads every input column (below)
  reserved 1, 3, 4, 5, 7, 13, 14;  // drafts' runtime enum, per-language code arms, batch_format
  reserved "runtime", "installed", "source", "value", "batch_format", "js_module", "js_value";
  reserved 9; reserved "resolution";
}

// The input columns a ROW or MAP_BATCHES_FRAME UDF reads. A message, not a bare repeated field, so that unset
// (reads every input column) and set with no names (reads none) are different values (optimized_plan.md §7.1).
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
  ROW                  = 6;   // target of a WireUdfApply; one row object per input row, from the columns passed (below)
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

**The runtime's ABI tag is not part of the UDF's identity.** `UdfCode` carries no ABI tag (`cp312`, `node22`). The tag lives only in `needs.runtimes` (§3.2; `optimized_plan_udfs.md` §10.3 states the same rule). So a `PACKAGE` or `BUNDLE` reference keeps its digest when it is recaptured under a new interpreter minor. A form whose bytes really are ABI-specific (a pickled payload) records that in its descriptor, and the runtime's `validate` refuses a mismatch.

**The kind is the call shape, fully resolved.** The plan spec records two kinds, `MAP_BATCHES_COLUMN` (the target of a `WireUdfApply`) and `MAP_BATCHES_FRAME` (the target of a `WireMapBatchesNode`), and does not derive the form from the arm (`optimized_plan_udfs.md` §10.2, the kinds table and the bullet "The kind records the call shape"). With one `MAP_BATCHES` kind whose form came from the arm, identical `UdfRef` bytes would be one entry, so one index could be the target of both a `WireUdfApply` and a `WireMapBatchesNode`, with two different argument schemas. A runtime binds its schemas once per `UdfRef` at `load` (§4.3), so the shape must be in the `UdfRef`. Plan validation refuses an arm whose target has the wrong kind (`OPTIMIZED_UDF_KIND_ARM_MISMATCH`). Plain versus mergeable `AGGREGATE` is already decided by `state_type`.

**What each field is for, and who reads it.**

| Field | Read by the optimizer | Read by plan validation | Read by the runtime |
|---|---|---|---|
| `kind`, `arg_types`, `return_type`, `state_type` | yes | yes (arms, schemas) | yes (bound at `load`) |
| `read_set` | yes (projection pushdown, §3.2) | yes: kind, names, agreement with `arg_types` (`optimized_plan_udfs.md` §10.4) | through `args`: exactly the columns it receives |
| `stability`, `null_mode`, `resources` | yes | yes | `stability`, `null_mode` as facts; the host applies `PROPAGATE` |
| `preserves_event_time` | yes (the watermark rules of `plan_models.md` §3.2) | false unless `MAP_BATCHES_FRAME` (`optimized_plan_udfs.md` §10.3) | — (not in `komira_udf_spec`) |
| `code.runtime` | **never** | grammar; declared in `needs.runtimes` (§3.2) | — |
| `code.form`, `code.code` | never | form set; every digest 32 bytes; `entry` non-empty for `PACKAGE` | yes |
| `code.entry`, `descriptor_version`, `descriptor` | never | never (opaque) | yes, through `validate` (§4.3) |

**Types.**
- `arg_types` makes each `UdfRef` a self-contained signature. A runtime binds the argument schema once, at `load`, before it sees the plan body.
- At each call site, the argument types must equal `arg_types` exactly. A producer that wants a conversion inserts an explicit cast (`OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`).
- For an `AGGREGATE` over several columns, each column is one entry, in input order. For a `STEP`, `arg_types` lists the types of the literal arguments. For a `ROW` and a `MAP_BATCHES_FRAME`, `arg_types` lists the columns the function receives: one entry per read-set name, in the same order and with the same names, when `read_set` is set; one entry per input column, in input order, when it is unset (below).
- Arrow is the single source of truth for every type (§6.2).

**Determinism is `stability`.** `IMMUTABLE`, `STABLE` and `VOLATILE` already state what the optimizer and the host may assume about repeated calls (§10.7). A separate determinism field would state the same fact twice.

**`STEP` is a shape, not a language.** A step is a shape: a source node with literal arguments that runs once per run. Whether a runtime supports steps is a runtime capability (§4.2), checked at admission; it is not a plan rule. Its arm is `WireStepNode` (`optimized_plan_udfs.md` §10.4). A `STEP` `UdfRef` must be `VOLATILE` (`OPTIMIZED_UDF_STEP_NOT_VOLATILE`): §10.7 lists a step as always `VOLATILE` (the `VOLATILE` row of the stability table), and plan validation enforces it (§7.2 step 8).

**`ROW` and `MAP_BATCHES_FRAME`: an optional read set.** A row-shaped function receives one row object per input row and reads its fields by name (`df.map_rows(f)`, pandas `DataFrame.apply(f, axis=1)`); a frame function receives a table and reads its columns. Neither names its inputs as arguments, so the `UdfRef` may carry a read set, `read_set`: the input columns the function reads.
- **Unset means every input column.** The function receives every column of its input and the optimizer keeps them all live. This is always correct, and slower on a wide input. A producer leaves it unset whenever it cannot bound the reads.
- **Set means exactly those columns, and may be empty.** The optimizer projects the input to the read set, and the host passes no other column. A grouped frame returns tables that carry their own key columns (§4.3), so its read set must contain every column its `group_by` reads (`OPTIMIZED_UDF_READ_SET_GROUP_KEY`), and its input stays exactly `arg_types`. An empty read set means the function reads no column; it receives a struct or batch with no children whose `length` is the row count (§3.4 rule 5). It matches a descriptor's present, empty field list, not an absent one (*Descriptor rules*, below). Names are non-empty, unique and ascend by UTF-8 bytes (`OPTIMIZED_UDF_READ_SET_INVALID`). A `read_set` on any other kind is refused (`OPTIMIZED_UDF_READ_SET_KIND`): `SCALAR`, `MAP_BATCHES_COLUMN` and `AGGREGATE` read exactly their arguments, and a `STEP` has no input.
- **`arg_types` agrees with it** (*Types*, above; `OPTIMIZED_UDF_READ_SET_ARG_MISMATCH`). For a `ROW`, the call site's `WireUdfApply` passes one argument per `arg_types` entry, in the same order, usually a column reference. The field name is what user code reads; the argument binds it by position, so a rename below the call does not change the `UdfRef`. For a `MAP_BATCHES_FRAME`, each read-set name is a column of the child's output (`OPTIMIZED_UDF_READ_SET_COLUMN_UNKNOWN`).
- **Every call site agrees with it.** Every node that references the `UdfRef`'s index must supply those columns: each `WireUdfApply` one argument per `arg_types` entry, each `WireMapBatchesNode` a child whose output contains every read-set name. When `read_set` is unset, each referencing node's input equals `arg_types` exactly, in names, types and order (`OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`). An input with two columns of one name is ambiguous, so a `ROW` call or a `read_set` over such an input is refused (`OPTIMIZED_UDF_READ_SET_INVALID`, naming the name).
- **Unset and empty are different bytes.** The canonical encoding emits field 19 whenever it is set, even with no names, so an empty read set and an unset one give different `UdfRef` digests.
- **The producer determines it when the plan is built** (§6.1), never a host, from the first of:
  1. an explicit declaration: `columns=[...]` on the verb, or, in Python, a `TypedDict` or a dataclass as the annotation of a `ROW` function's row parameter or a frame function's input parameter, whose field names are the read set; given together, the two must name the same set (`UDF_READ_SET_INVALID` otherwise; they are never merged);
  2. inspection: the SDK's static scan of the function's field or column accesses (for Python, a scan of the function's bytecode for attribute and subscript reads on the row or frame parameter). The scan counts every access it finds, on every branch, taken or not. A function that iterates the row or table, converts it to a dict or tuple, unpacks it or passes it whole to other code cannot be bounded by the scan;
  3. otherwise none: `read_set` stays unset. This is correct and slower; the SDK says so in its local diagnostics, with the fix-it to declare `columns=[...]`. It never lists every input column as a stand-in for "unknown".

  A local run never adds to the read set: a field read only on a branch the local run happened to take would otherwise hide a scan defect.
- **The optimizer prunes everything else.** A `ROW` call's arguments are ordinary expressions, so projection pushdown through it needs no rule of its own: with a read set only its columns stay live, down to the scan; without one every input column does. A frame node with a read set needs from its child only the read set, which contains its `group_by` columns. No host re-derives the read set.
- **The runtime hands over those columns only**, per batch (§4.3). For a `ROW`, a read of an undeclared field fails the batch with `ERR_FIELD_NOT_DECLARED` (`UDF_FIELD_NOT_DECLARED`), naming the field and the read set, with a fix-it: add the field to `columns=[...]`. It never yields a null. A read outside a `columns=[...]` list that the user made too short, or one a defective scan missed, is the case this catches, and the error makes it safe. For a `MAP_BATCHES_FRAME`, the batch holds only the read set's columns, so a read of another column fails in the user's data library (`ERR_RAISED`; open, §1.3).
- **A `ROW` UDF is `MANUAL`** (`OPTIMIZED_UDF_ROW_NULL_MODE`). Under `PROPAGATE`, a null in a field read only on some branches would drop rows the function would have computed.
- **Output.** One value of `return_type` per row, as for `SCALAR`. A function returning several values per row (`map_rows` returning a tuple) declares a struct, which the producer unpacks into columns with ordinary field access.

**Code forms.** Three neutral forms cover every language. §10.6 is the Python and TypeScript instance, and §10.3's informative table maps an earlier draft's per-language code messages onto them:

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

**Every descriptor records the signature, so `validate` stays pure.** Whatever else it holds, each runtime's descriptor records what the producer found when it captured the function:
- **the entry** it captured, which must equal `code.entry`;
- **the shapes** the entry supports, as `UdfKind` values (`MAP_BATCHES_FRAME` grouped or not, `AGGREGATE` plain or mergeable, as the capability bits of §4.2 distinguish them);
- **the signature**: the argument types in call order (for `ROW` and `MAP_BATCHES_FRAME`, the field list, when the producer knows it: a native library's export helper, or a Python `TypedDict` or dataclass annotation; otherwise the list is absent. A present, empty list means the function reads no column), the return type and, for a mergeable aggregate, the state type, each as a `WireField` (an Arrow type, nested to any depth).

The field list is a message, so that absent and empty differ, as for `UdfRef.read_set` (field 19, §3.1); each runtime's descriptor carries it as a field of this type, emitted whenever it is set, even when empty. `RecordedFields` is added to `src/komira_plan_proto/plan.proto`, beside `WireField`, in stage 11 of `optimized_plan.md` §12, and every runtime's descriptor schema imports both from there rather than copying them. `validate` refuses a `RecordedFields` that breaks its order, its uniqueness or the disjointness of its two lists with `ERR_DESCRIPTOR`; that `key_fields` holds only `group_by` columns is the producer's rule, which `validate` cannot check because the spec carries no `group_by`:

```proto
message RecordedFields {            // in a runtime's descriptor, for ROW and MAP_BATCHES_FRAME entries
  repeated WireField fields     = 1;  // the annotation's or the export table's fields
  repeated WireField key_fields = 2;  // group_by columns capture added; never in a komira/native descriptor
}
// a runtime descriptor: RecordedFields recorded_fields = <the runtime's own field number>;
// Canonical form: both lists ascend by UTF-8 bytes of the name; names are unique across both lists;
// key_fields holds only group_by columns absent from fields.
```

Where the signature comes from depends on the language, and in every case it is read at capture, on the producer's machine (§6.1): a native library's export helper records each entry's signature and shapes in the library when it is built, and capture reads them from there; a TypeScript function's types are the type values given on the verb; a Python function's types come from its type hints or the verb's `return_dtype=`/`schema=`, read before a `VALUE` is serialized. `validate` compares the spec (the kind, `arg_types`, `return_type`, `state_type`) with what the descriptor records (for a `ROW` or `MAP_BATCHES_FRAME`, it compares the `arg_types` names with the fields the descriptor records (for a Python descriptor, the union of its annotation and key fields, below), as sorted sets: a difference of names is `ERR_READ_SET_MISMATCH`, and with equal names a difference of types is `ERR_DESCRIPTOR`. The field list has presence: when it is absent, `validate` skips the check, except in `komira/native`, which returns `ERR_DESCRIPTOR` because native code has no lazy view; a present, empty list is compared like any other), and refuses any difference, a shape the entry does not support included, with `ERR_DESCRIPTOR` (`OPTIMIZED_UDF_DESCRIPTOR_INVALID`), naming the field and both values. (A shape the runtime as a whole lacks never reaches `validate`: the host refuses it from `describe` first, `OPTIMIZED_UDF_KIND_UNSUPPORTED`.) It never opens a code object: it loads no library, imports no module and deserializes no value. `load`, which does open the code, checks that the code agrees with the descriptor and refuses a disagreement with `ERR_LOAD` (§4.3). The signature duplicates nothing in the plan: `arg_types` and `return_type` are what the plan binds at the call; the descriptor's signature is what the function was captured as, and `validate` is where the two meet.

**Recorded fields from an annotation.** A Python descriptor records the annotation's fields (an empty `TypedDict` records a present, empty list) and, separately, the key fields capture added for a grouped frame (§6.1), each a `WireField` typed from the input schema at capture, so their types are compared too. `validate` compares their union with the `arg_types` names; `load` compares the function's annotation with the annotation's fields only.

**A native library is built against one read set.** For a `ROW` or `MAP_BATCHES_FRAME` entry, the native export helper builds the library against one set of fields and records it in the library's export table, from which capture copies it into the descriptor; for a grouped frame the library author includes the `group_by` columns in that set, and capture never adds to a native descriptor. The library's views bind the `args` children by name, after the group ordinal, at `load`. Admission refuses, by name, a `UdfRef` whose `arg_types` names (the read set, or the whole input when it is unset) differ from it (`validate` returns `ERR_READ_SET_MISMATCH`, `OPTIMIZED_UDF_READ_SET_DESCRIPTOR_MISMATCH`): the plan disagrees with what the code was built against, and the fix is to rebuild.

Each runtime:

- defines its descriptor as a protobuf message, with its own field numbers and the format's forever rules (§9.2), and with the entry, shapes and signature above;
- defines a canonical encoding of that message. Its `validate` refuses bytes that are not canonical, so the `UdfRef` digest is stable (§10.3, "Identity is the canonical bytes");
- reads every `descriptor_version` it has ever released, for as long as any base ships that runtime (§8.2).

**An unknown runtime is refused by name.** At each stage the refusal names the runtime id and, where known, the ABI tag:

| Where | Check | Refusal |
|---|---|---|
| Producer, when the plan is built | The SDK can emit only runtimes it implements | `UDF_RUNTIME_UNKNOWN` |
| Plan validation | `code.runtime` matches the grammar; `form` is set; each runtime is in `needs.runtimes` | `OPTIMIZED_UDF_RUNTIME_MALFORMED`, `OPTIMIZED_UDF_RUNTIME_UNDECLARED` |
| Admission from the header only (§10.11 check 3) | Every `needs.runtimes` pair is in the base release's runtime registry, or an added runtime layer declares it (§8.3) | `OPTIMIZED_ENV_RUNTIME_MISSING`, naming the pair |
| Admission on the host (§10.11 checks 4-7) | The runtime's `validate` accepts each descriptor, and its capabilities cover each shape | `OPTIMIZED_UDF_DESCRIPTOR_INVALID`, `OPTIMIZED_UDF_READ_SET_DESCRIPTOR_MISMATCH`, `OPTIMIZED_UDF_UNSUPPORTED`, `OPTIMIZED_UDF_KIND_UNSUPPORTED` |

The engine itself knows no runtime ids, so a plan is never refused because the *engine* lacks a runtime. It is refused because the *environment* lacks it, and the refusal says which environment would run it.

### 3.2 Optimized plan: what it adds and pins

The optimized plan carries the same `UdfRef` entries. It adds one message:

```proto
message RuntimeNeed {            // in DeclaredNeeds (optimized_plan.md §6.1)
  string runtime     = 1;
  string runtime_abi = 2;        // the runtime's own ABI tag: "cp312", "node22"; may be empty
}
// DeclaredNeeds: repeated RuntimeNeed runtimes = 9;  reserved 6, 7; reserved "python_abi", "node_abi";
```

- **`needs.runtimes`** lists one entry for each distinct runtime id that `needs.udfs` uses.
  - It is sorted by runtime id.
  - It has at most one entry per runtime id (`OPTIMIZED_NEEDS_RUNTIME_ABI_CONFLICT`): each base ships one ABI of each runtime it carries (§10.11), so a plan naming two could never be admitted. A release ships several bases, one per supported CPython minor and one per supported Node major, and a remote run uses the base of the client's version. A base carries exactly one managed runtime besides `komira/native`, so a plan that needs two managed runtimes (for example `komira/python` and `komira/node`) has no base and is refused at admission (`OPTIMIZED_ENV_RUNTIME_MISSING`, §10.11).
  - It has no missing and no unused runtime (`OPTIMIZED_UDF_RUNTIME_UNDECLARED`, `OPTIMIZED_NEEDS_RUNTIME_UNUSED`).
  - It is part of the `DigestTrailer` (§7.1).
  - A scheduler can place a plan using this list from the header alone.
- **Shape decisions are pinned, as they are today.** These are:
  - where each UDF is placed (§10.9);
  - `PARTIAL`/`FINAL` for mergeable aggregates;
  - `HASH` exchanges for grouped frames and plain aggregates (§10.4);
  - CSE of calls that are not `VOLATILE`.

  None of these decisions reads the runtime.
- **What the optimizer may read:** `kind`, the types, `read_set`, `stability`, `null_mode` and `resources`. It must not read `code`. A `ROW` call's columns are its arguments, so pruning treats it as any other call; a frame node needs only its read set (which contains its `group_by` columns) when it has one, and every child column when it has none (§3.1).
- **Host observations never change shape.** The optimizer runs on the producer, before any run, and an optimized plan is never re-optimized (§10.9). Latency the host observes changes only host-local choices: batch size and pool size (§3.3). An optional producer-side cost hint on the verb (a relative per-row cost class, an expected selectivity) may be added later to order several UDF conjuncts. It would live in `PlanAdvice`, not in `UdfRef`, because `UdfRef` bytes are identity. This document does not add it.
- **The runtime-swap invariance test.**
  - Plan every query in the UDF corpus twice. The second time, replace every `code` with `{runtime: "komira-test/null"}` and empty fields, and every `needs.runtimes` entry likewise.
  - After applying the same substitution to the first result, the two optimized plans must be equal.
  - A third planning replaces every runtime with `komira/native`, and the result must again be equal. This holds the optimizer to the rule that the class and mode of a UDF (§1.2) do not change the plan.
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
- **Contexts and instances.** A *context* is what one engine thread calls; an *instance* is one loaded UDF inside one context. Each engine thread that runs a UDF operator opens its own context in each runtime it uses, holding an instance of each UDF that thread runs, and no context is called by two engine threads at once. What a context is inside the runtime is the runtime's business: a native library's per-thread state, or, in the Python and Node runtimes, one worker process (§5).
- **Pool size**: the number of contexts. It is set from the CPU count, `max_workers`, and the memory a context uses *with its UDFs loaded* (`worker_mem_bytes`), as §10.10 states, counting what the runtime reports through `memory_report` (§4.8).
- **Batch rows**: adapted at run time, below `max_batch_rows` (§10.8).

These are host-local choices (`optimized_plan.md` §5.3). Two hosts may bind one plan differently. The results are still equal, because the contract (§4), the call semantics (§3.4) and the post-conditions (§4.6) are the same for every runtime.

### 3.4 Call semantics the format fixes

These rules are part of the plan's meaning, so they hold on every host and for every runtime. Each has a conformance case (§6.3).

1. **Conditional evaluation.** A UDF call is evaluated only on rows for which every enclosing conditional selects its branch (`CASE`, `coalesce`, the right-hand side of `AND`/`OR`), and only on rows that survive earlier conjuncts of the same filter. So `CASE WHEN x > 0 THEN f(x) END` never calls `f` on a row with `x <= 0`. The ordering of UDF conjuncts last (`optimized_plan_udfs.md` §10.9, the conjunct-order row) depends on this rule.
2. **Compaction.** The host compacts the selected rows (a `take`) before the call and scatters the result after it. Under `PROPAGATE` it also removes rows with a null argument. The arrays a runtime receives contain only rows it must compute.
3. **Independence from instances and batch boundaries.** The result of a `SCALAR`, `ROW` or `MAP_BATCHES_COLUMN` call on a row does not depend on which instance serves it or on where batches were split. A function may cache (a loaded model, a memo table); a function whose per-row result depends on earlier calls (a row counter) is not expressible at the first format version. This replaces the `SERIAL_ORDERED` parallelism contract, which `UdfRef` does not carry. A frame-form function already sees batch boundaries; #1094 states its rule in §10.8 ("Declared resources"): a `MAP_BATCHES_FRAME` function must not depend on batch boundaries unless the node is grouped.
4. **Exact argument encoding.** The host hands the runtime arrays in exactly the `arg_types` encoding: no dictionary or view encoding unless the declared type is one; the host casts first. Arrays may have a non-zero `offset`, including bit offsets that are not multiples of 8.
5. **The argument struct.** Arguments arrive as one struct array, one child per `arg_types` entry (after the group ordinal, for a grouped frame or plain aggregate), with no validity buffer and offset 0. For a `ROW`, the children are exactly the columns `arg_types` lists, named as there: the read set when one is set, otherwise every input column; the host passes no other column. A `MAP_BATCHES_FRAME`'s input batches carry the same columns. Its `length` is the row count and is authoritative: a zero-argument `SCALAR` such as `uuid()`, and a `ROW` or frame whose read set is empty, receive a struct with no children and `length` rows.
6. **Delivery.** Within one run, user code never runs a `VOLATILE` batch twice, and nothing is retried after a loss (§4.5); a run restarted from a checkpoint delivers again the batches after that checkpoint. A non-`VOLATILE` `call_batch` batch may run more than once only through bisection after `ERR_RAISED` (§4.5, §10.7).

## 4. The runtime interface

### 4.1 One contract; the runtime decides how it executes

A runtime is a shared library that exports one symbol, `komira_udf_runtime_init_v1`. That symbol returns a table of functions (§4.3). The engine loads the library into its own process and calls the table directly; Arrow data crosses as C Data structs, with no copy. That is the only way the engine reaches user code.

Behind the table, a runtime runs user code wherever is best for its language: `komira/native` calls a native library on the calling thread; `komira/python` and `komira/node` run user code in worker processes that they start and manage (§5, informative). Whatever a runtime does, the table's semantics (§4.3-§4.7) hold at the C ABI. The engine never starts a process for a runtime and never speaks to a runtime's worker. A native UDF library (§1.2) is not a runtime: `komira/native` loads it.

So each language is implemented once, behind one interface. This is also the shape of DuckDB's C extension API, whose function struct is only appended to ([duckdb#14992](https://github.com/duckdb/duckdb/pull/14992)).

### 4.2 Capabilities: what a runtime can do

`describe` returns what the runtime is and what its UDFs can do. It says nothing about how the runtime executes them. When a plan needs a capability the runtime lacks, the host refuses the plan by name.

| Capability | Values | Used for |
|---|---|---|
| `runtime_id`, `runtime_abi` | strings | Matched against `needs.runtimes` |
| `max_descriptor_version` | the highest version the runtime reads | `validate` refuses any newer version |
| `shapes` | bitmask of SCALAR, ROW, MAP_BATCHES_COLUMN, MAP_BATCHES_FRAME, MAP_BATCHES_FRAME_GROUPED, AGG_PLAIN, AGG_MERGEABLE, STEP | Refusing a shape the runtime lacks before `validate` (`OPTIMIZED_UDF_KIND_UNSUPPORTED`) |
| `udf_class` | `NATIVE` or `MANAGED` (§1.2) | The class-specific conformance cases (§6.3), and `komira/native`'s check of a library. Never read by the optimizer, by plan validation or by the host's binding |
| `devices` | bitmask; CPU only at the first release | GPU UDFs later, with no change of signature |
| `features` | `MEMORY_REPORT`: the optional `memory_report` entry is present. `CONTAINS_CRASHES`: a crash of user code fails the call with `ERR_WORKER_CRASHED` (or `ERR_OUT_OF_MEMORY`) and leaves the engine running. `FORCED_STOP`: the runtime stops user code that ignores a cancel or a deadline, and returns `ERR_KILLED` (§4.7) | Which optional entries are present; which cooperative or forced guarantees the host may rely on; the crash and kill conformance cases |

**How a runtime executes is not a capability.** No field says where user code runs, how many processes a runtime starts, or which thread runs user code; those are the runtime's own business (§5). An earlier draft reported them (`threading`, `global_lock`, `thread_affine`, `hosting`, `transports`); they are removed, because the engine binds nothing from them (§10).

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
  KOMIRA_UDF_ERR_INSTANCE_LOST = 14,  /* the context cannot be used again; no user code ran for this call */
  KOMIRA_UDF_ERR_INTERNAL = 15,       /* a runtime bug; never user code */
  KOMIRA_UDF_ERR_FIELD_NOT_DECLARED = 16, /* ROW: user code read a field outside the read set; message names it */
  KOMIRA_UDF_ERR_WORKER_CRASHED = 17, /* the process running user code died, not by the runtime's own stop; context lost */
  KOMIRA_UDF_ERR_HOST_CONTRACT = 18,  /* the host broke this ABI (§4.5); message names the rule */
  KOMIRA_UDF_ERR_KILLED = 19,         /* user code ignored a cancel or deadline and was stopped by force; context lost */
  KOMIRA_UDF_ERR_READ_SET_MISMATCH = 20 /* validate: ROW/FRAME arg_types names differ from the descriptor's fields */
} komira_udf_status;

/* capabilities.udf_class (0 reserved, refused) */
#define KOMIRA_UDF_CLASS_NATIVE   1u
#define KOMIRA_UDF_CLASS_MANAGED  2u
/* capabilities.shapes and spec.shape: one bit per shape (0: none) */
#define KOMIRA_UDF_SHAPE_SCALAR                    (1u << 0)
#define KOMIRA_UDF_SHAPE_ROW                       (1u << 1)
#define KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN        (1u << 2)
#define KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME         (1u << 3)
#define KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED (1u << 4)
#define KOMIRA_UDF_SHAPE_AGG_PLAIN                 (1u << 5)
#define KOMIRA_UDF_SHAPE_AGG_MERGEABLE             (1u << 6)
#define KOMIRA_UDF_SHAPE_STEP                      (1u << 7)
/* capabilities.devices (0: none) */
#define KOMIRA_UDF_DEVICE_CPU                      (1u << 0)
/* capabilities.features (0: none) */
#define KOMIRA_UDF_FEATURE_MEMORY_REPORT           (1u << 0)
#define KOMIRA_UDF_FEATURE_CONTAINS_CRASHES        (1u << 1)
#define KOMIRA_UDF_FEATURE_FORCED_STOP             (1u << 2)

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
  uint32_t    shapes, devices, features;  /* §4.2 */
  uint32_t    udf_class;              /* NATIVE or MANAGED (§1.2) */
} komira_udf_capabilities;               /* what the runtime can do; nothing about how it executes */

typedef struct komira_udf_spec {      /* the UdfRef, decoded by the host; borrowed for the call */
  size_t             struct_size;
  int32_t            shape;           /* one bit of capabilities.shapes, fully resolved */
  int32_t            form;            /* CodeForm */
  const char*        entry;
  uint32_t           descriptor_version;
  const uint8_t*     descriptor;  size_t descriptor_len;   /* records entry, shapes and signature (§3.1) */
  const struct ArrowSchema* args;     /* a struct schema, one child per arg_types entry; for ROW and
                                         MAP_BATCHES_FRAME, the read set by name if set, else every input column */
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
  int64_t                 call_id;      /* unique per call, for diagnostics */
  const volatile int32_t* cancel;       /* host-owned, alive until the call returns; nonzero = cancel */
} komira_udf_call;

typedef struct komira_udf_rt       komira_udf_rt;        /* the runtime, once per process */
typedef struct komira_udf_udf      komira_udf_udf;       /* a validated, loaded UDF: process-wide part */
typedef struct komira_udf_context  komira_udf_context;   /* what one engine thread calls (§3.3) */
typedef struct komira_udf_instance komira_udf_instance;  /* one UDF inside one context */
typedef struct komira_udf_frame    komira_udf_frame;     /* one frame, plain-aggregate or step call */
typedef struct komira_udf_groups   komira_udf_groups;    /* the accumulators of many groups */

typedef struct komira_udf_runtime {   /* static in the runtime; the host reads entries below struct_size */
  size_t   struct_size;
  uint32_t abi_major, abi_minor;
  int32_t (*describe)(komira_udf_rt*, komira_udf_capabilities* out);
  int32_t (*validate)(komira_udf_rt*, const komira_udf_spec*, komira_udf_error*);  /* pure: spec vs descriptor; opens no code */
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

1. **`init`** negotiates the version (§8.1) and creates the runtime handle. It runs once per process. The host loads the library with `RTLD_LOCAL | RTLD_NOW` and never `dlclose`s it, because runtimes start threads and register exit handlers. Runtimes are built with hidden symbol visibility except for the one exported symbol. A runtime that runs user code in worker processes starts them when and how it chooses (§5).
2. **`describe`** returns the capabilities (§4.2). It is cheap and pure.
3. **`validate(spec)`** compares the spec with the descriptor: the entry, the shape and the signature the producer recorded at capture (§3.1, *Descriptor rules*).
   - It is pure: it opens no code object, loads no library, imports nothing and deserializes nothing, so no user code and no library constructor runs.
   - It plays the role of PostgreSQL's validator function ([plhandler](https://www.postgresql.org/docs/current/plhandler.html)).
   - It runs at host admission, and in the producer's local check.
4. **`load(spec)`** verifies each code object's sha256, opens the code, checks that it agrees with the descriptor's entry, shapes and signature (`ERR_LOAD` otherwise), and binds the argument, result and state schemas. It runs once per UDF and argument schema (§3.3), before any data is read (§7.2 step 9). Where the code is actually loaded (the engine's process, or the runtime's workers) is the runtime's choice (§5).
5. **`open_context(slot)`** creates one context for one engine thread (§3.3). `slot` is a dense index.
6. **`open_instance(context, udf)`** makes a UDF callable in a context. A plan with 10 UDFs on 32 engine threads has 32 contexts and 320 instances, not 320 interpreters. This is the counterpart of DuckDB's `local_init`.
7. **Calls**, by shape:
   - **`SCALAR` and `MAP_BATCHES_COLUMN`: `call_batch`.** A `SCALAR` runtime loops over the rows *inside* the runtime, in its own language. An `async` function is awaited inside the runtime, with at most `max_concurrent_calls` calls in flight (§10.8). The output has the same length as the input.
   - **`ROW`: `call_batch`, rows built inside the runtime.** At `load` the runtime binds the field names from `spec->args`: the read set, or every input column when the `UdfRef` sets none. Per batch it builds one row object per row over the `args` children only, in its own language: a lazy view that reads child *i* at row *r* when a field is read (a Python row proxy or a pandas `Series` holding only the read set, a JavaScript object with getters, a typed row view in a native SDK). A read of any other name fails with `ERR_FIELD_NOT_DECLARED`, with `row` set. If user code catches the language's exception, the runtime still fails the batch: the proxy records the violation and `call_batch` checks it before it returns. A native SDK whose row view exposes only the declared fields rejects other names when the library is built; that covers the one read set the library records (§3.1).
   - **`MAP_BATCHES_FRAME`, ungrouped: `frame_open`, then `frame_next` until the end.** The runtime pulls input batches from `in` when it needs them; the host pulls output batches, so a generator yields as it goes, before it has read all its input. Each input batch carries exactly the `args` columns: the read set's, in its order, when the `UdfRef` sets one.
   - **`MAP_BATCHES_FRAME`, grouped, and plain `AGGREGATE`: the same entries, with a group column.** Each input batch's first child is a non-null `int64` group ordinal. Rows of one group are contiguous and ordinals increase; a group may span batches. The runtime collects a group's rows and calls the user function once per group, in its own language. A grouped frame returns the user's tables (which carry their own key columns, §10.4); a plain aggregate returns one row per completed group, in ordinal order, so the host pairs results with keys by position. One crossing serves many groups.
   - **Mergeable `AGGREGATE`: the `agg_*` entries, vectorized over groups** (the shape of DataFusion's `GroupsAccumulator`, [docs](https://docs.rs/datafusion/latest/datafusion/logical_expr/trait.GroupsAccumulator.html)):
     1. `agg_open` once per aggregate operator and instance;
     2. `agg_update` once per batch, with a group id per row; `n_groups` only grows;
     3. `agg_state` in a `PARTIAL` step: an `n`-row column of `state_type`, one row per group;
     4. `agg_merge` of partial states in a `FINAL` step, again with a group id per row;
     5. `agg_finish`: an `n`-row result column.

     `emit_first_n` emits and forgets the first `n` groups, so the host can emit early. The state is an Arrow value of `state_type`, never an object private to the language, so it crosses an exchange and a checkpoint as a column. A groups object is used only with the instance that created it, and is closed before `close_instance`.
   - **`STEP`: `frame_open`** with a stream of one length-1 struct batch holding the literal arguments. The output is the stream of the step's table, which may be empty or have no columns.
8. **`frame_close`, `agg_close`, `close_instance`, `close_context`, `unload`.** The host closes a frame or a groups object once it needs nothing more from it, and instances, contexts and loaded UDFs at the end of the run or when it shrinks the pool; then **`shutdown`**, at process exit or when the host drops the runtime.

The host serializes the calls on one frame and one groups object, in every mode; the C Stream specification does not make a stream thread-safe. A runtime calls `in`'s `get_schema`, `get_next` and `get_last_error` only inside `frame_next`, on the thread that called it; it calls `in`'s release at `frame_close` at the latest (§4.4). **Calls on one context are serialized, with one exception:** while a `frame_next` (or a plain aggregate's frame) is waiting on its `in` pull, the host may call into the same context to produce that input, for example a scalar UDF of the same runtime upstream in the same pipeline. Such calls nest: they complete before the pull returns. A runtime must support this: a managed runtime serves a nested call while the frame's user code is suspended waiting for input (§5.2), and a native runtime's entries must be re-entrant across distinct instances, frames and groups objects on one context. No other nesting is allowed. *Re-entry* means calling an entry whose first argument is an object already in a call; it is never allowed. Frames of one instance are distinct objects, so one frame's `frame_next` inside another frame's pull, on the same instance, is allowed. A runtime is not required to detect a re-entry, which would need a busy flag on every object, so it is not in the `ERR_HOST_CONTRACT` list (§4.5).

**When producing a pull's input fails.** This covers any failure while the host produces the input of a waiting `in` pull: a nested call on the same context, a call into another runtime, any other upstream operator, or the run failing or being cancelled. The first such failure fixes the run error: for a nested call, naming that call's UDF; otherwise that failure's own error (the run's cancel, the upstream's error). Every pull waiting on that failure returns `EIO` from `get_next`, innermost first, with the failure's message in `get_last_error`; every later `get_next` on that stream returns `EIO` again. A runtime copies the `get_last_error` text before its next callback, and after `EIO` calls nothing on the stream but its release. If the failing call is being bisected (§4.5), the host finishes bisection before `get_next` returns `EIO`. The host releases each waiting call's output unread and ignores its status, except to learn that the context is lost. The host closes nothing on a context until no call on it is in progress: then frames innermost first, then groups objects, instances and, if a status lost it, the context. This also covers frames of different runtimes nested on each other, for example a Python frame whose input comes from a native frame, where the host calls into the Python frame's context to produce the native frame's input. While a call waits on its `in` pull, its deadline and cancel are not enforced by a forced stop; the host gives each nested call a `deadline_ns` no later than the waiting call's (a `deadline_ns` of 0 means none, so it is the latest), and sets the nested call's cancel whenever it sets the waiting call's. When a pull returns after the waiting call's deadline has passed, or with its cancel set, the runtime returns `ERR_DEADLINE` (or `ERR_CANCELLED`) from that `frame_next` without passing the batch to user code; the grace period of a forced stop starts when the pull returns.

### 4.4 Data, zero copy and ownership

Every pointer that crosses the ABI has exactly one named owner. The Mojo binding states each owner in an `# FFI-BOUNDARY:` comment. It keeps every `UnsafePointer` private to the binding, and its public API takes and returns values (`docs/design/mojo_safety_and_idioms.md`).

| Object | Owner | Rule |
|---|---|---|
| `args`, `states`, `group_ids` of every call | **Moved to the runtime on entry, whatever status it returns** | The struct itself belongs to the host (often on its stack). Before returning, the runtime moves it into its own storage (`*mine = *args; args->array.release = NULL;`) and later calls `release` only on its own copy, exactly once. It may release after returning, when user code kept a view. The host exports without copying: each buffer is kept alive by a shared reference that the release drops, as the stream exporter already does (`c_data_stream.mojo:385-395`), not with the borrowing exporter of `c_data_interface.mojo:17-20`. |
| `out` of every call | **Moved to the host on success** | The runtime produces it with its own release callback. On any status other than OK, `out->array.release == NULL` and the host never calls it. The host imports it **without copying**, after validating it (below), and calls release when its last reference goes away. A runtime may return its input buffers in its output. Its buffers must not change while the host holds them: a runtime whose user code produced them in another process copies them out of any memory that process can still write before it returns. |
| `in` stream of `frame_open` | **Moved to the runtime** | Same move rule as `args`. The runtime releases it after the end of the stream, at `frame_close`, or on failure. |
| `komira_udf_spec`, with its strings and schemas | Borrowed for the call | `validate` and `load` copy whatever they keep. |
| `komira_udf_error` | The host owns the struct; the runtime owns the strings | The host allocates one per call, so concurrent calls never share one. The host calls `release` once when it is non-NULL. An unknown `code` from a newer minor is treated as `ERR_INTERNAL`. |
| `cancel` flag | The host | Alive until the call returns. The host sets it with a release store; the runtime reads it with an atomic load. |
| Handles (`rt`, `udf`, `context`, `instance`, `frame`, `groups`) | The runtime | Created and freed only through the table. |
| Callbacks into a language (a C callback object, a Node-API reference) | The runtime, inside its context or instance | Freed in `close_instance` or `close_context`. The host never holds a reference into a language. |

**Release runs on any thread, at any time.** The Arrow specification does not say which thread may call `release`, so this ABI does: the host calls release on whatever engine thread drops the last reference, possibly after `close_instance` and `close_context`, until `shutdown` begins. Release must not wait for anything that another thread may hold while it waits on the engine, such as an interpreter lock or an event loop, and must not need the thread that created the array.

A runtime therefore implements release with an atomic reference count and a deferred-free queue, which the owning context's thread drains on its next call or at close. `shutdown` drains every queue; the host releases everything before calling it, and keeps `komira_udf_host` alive until it returns.

**The host validates every imported array.** The runtime returns exactly the bound result or state schema and does any cast itself (`ERR_RETURN_TYPE` is the runtime's report). Because no schema travels with `out`, a wrong layout would be read through the declared type, and int64 and float64 have identical layouts. So on import the host checks the layout against the bound schema before any kernel reads it: `n_buffers` and `n_children` per format, each buffer's size against `length + offset`, offsets monotonic and within the data, a dictionary exactly where the type has one, and device CPU. A failure is `UDF_RUNTIME_FAULT`, naming the runtime. It guards against runtime bugs, and against a runtime that hands on a layout its user code chose.

- **One batch at a time; schemas once.** Schemas are bound at `load` and never sent per call; `args` carries only arrays.
- **Importing without a copy is new work.** Today's importers copy (`c_data_stream.mojo:3083-3087`, `:3264-3278`). The C ABI needs an importer that validates foreign buffers and wraps them in reference-counted storage whose last reference calls the producer's `release`.
- **Device arrays.** At the first release, `device_type` is CPU, `device_id` is -1 and `sync_event` is NULL. A runtime that receives any other device returns `ERR_HOST_CONTRACT` (§4.5).

### 4.5 Errors

Every entry returns a `komira_udf_status` and on failure fills the host's `komira_udf_error`. Each status says what failed: user code (`ERR_RAISED`, `ERR_RETURN_TYPE`, `ERR_LENGTH`, `ERR_FIELD_NOT_DECLARED`, the size limits), the code or the plan (`ERR_LOAD`, `ERR_CODE_DIGEST`, `ERR_DESCRIPTOR`, `ERR_READ_SET_MISMATCH`, `ERR_UNSUPPORTED`), a stop (`ERR_CANCELLED`, `ERR_DEADLINE`, `ERR_KILLED`), the process running user code (`ERR_WORKER_CRASHED`, `ERR_OUT_OF_MEMORY`), the host (`ERR_HOST_CONTRACT`) or the runtime itself (`ERR_ABI`, `ERR_INTERNAL`). The host maps status codes to the run's named errors through one table, so every language reports a failure the same way. A runtime returns the user's message and trace, not only a code.

| `komira_udf_status` | Run error |
|---|---|
| `ERR_RAISED` | `UDF_RAISED`, with `user_trace` and the row. `ERR_RAISED` leaves the context usable. Per §10.7, the host bisects a `call_batch` batch that is not `VOLATILE`, on the same instance, only when the reported `row` is -1; a `VOLATILE` batch is not bisected. During bisection, any status other than OK or `ERR_RAISED` ends it with that status's run error, carrying the original `UDF_RAISED` message (a loss gives `UDF_WORKER_CRASHED`); if no half raises, the host reports the original `UDF_RAISED`. Bisection stops at a half that reports a row, mapped to the row of the batch; a one-row half that still reports row -1 ends bisection with that row. A frame or aggregate that raises fails the run with the row it reports |
| `ERR_RETURN_TYPE`, `ERR_LENGTH` | `UDF_RETURN_TYPE_MISMATCH`, `UDF_BATCH_LENGTH_MISMATCH` |
| `ERR_FIELD_NOT_DECLARED` | `UDF_FIELD_NOT_DECLARED`, naming the field, the read set and the row, with the fix-it "add it to `columns=[...]`" (§6.1). Not bisected: the same batch fails the same way |
| `ERR_STATE_TOO_LARGE`, `ERR_GROUP_TOO_LARGE` | `UDF_STATE_TOO_LARGE`, `UDF_GROUP_TOO_LARGE` (the host names the key from `group`; `UDF_STATE_TOO_LARGE` also names the cap, a fixed 64 MiB of Arrow state per group at the first release, §10.2) |
| `ERR_LOAD`, `ERR_CODE_DIGEST`, `ERR_DESCRIPTOR` | `OPTIMIZED_UDF_CODE_UNLOADABLE`, `OPTIMIZED_UDF_CODE_DIGEST_MISMATCH`, `OPTIMIZED_UDF_DESCRIPTOR_INVALID` |
| `ERR_READ_SET_MISMATCH` | `OPTIMIZED_UDF_READ_SET_DESCRIPTOR_MISMATCH`, naming the fields the descriptor records and the `arg_types` names (§3.1): the plan disagrees with what the code was built or captured against, and the user rebuilds. At admission. (`OPTIMIZED_UDF_READ_SET_ARG_MISMATCH` is plan validation's error for `arg_types` that disagree with `read_set` inside the plan) |
| `ERR_UNSUPPORTED` from `validate` or `load` | `OPTIMIZED_UDF_UNSUPPORTED`, naming the runtime and carrying its message, which says what is unsupported: no library for the host's platform (`komira/native`, §1.2) or a type the language cannot represent (§6.2). A shape the runtime lacks is refused earlier, from `describe`, as `OPTIMIZED_UDF_KIND_UNSUPPORTED` (§4.2), and a shape the entry lacks is `ERR_DESCRIPTOR` (§3.1). One status serves both remaining uses because the host does the same thing for each: it refuses the plan at admission |
| `ERR_ABI` | `UDF_RUNTIME_ABI_MISMATCH`, naming the runtime and both versions (§8.1) |
| `ERR_CANCELLED` | The run's cancel |
| `ERR_DEADLINE` | `UDF_DEADLINE_EXCEEDED` (`UDF_STEP_TIMED_OUT` for a step) |
| `ERR_KILLED` | The run's cancel when the host had set the call's cancel flag; otherwise `UDF_DEADLINE_EXCEEDED` (`UDF_STEP_TIMED_OUT`), saying that user code was stopped by force. The context is lost, and the host closes it once no call on the context is in progress (§4.3, §4.7) |
| `ERR_INSTANCE_LOST` | `UDF_WORKER_CRASHED`, naming the runtime, the UDF whose call reported it, and the signal or exit status observed (carried in the message), which also says that no user code ran for this call. A runtime returns it only without having run user code for this call: the context was lost earlier, or the process running user code ended between calls. A runtime whose user code may have run returns `ERR_WORKER_CRASHED` or `ERR_KILLED` instead, and one that knows a between-calls end was for memory returns `ERR_OUT_OF_MEMORY` on the next call instead. The host closes the context once no call on it is in progress (§4.3); nothing is retried |
| `ERR_WORKER_CRASHED` | `UDF_WORKER_CRASHED`, naming the runtime, the UDF whose call reported it, and the signal or exit status observed. The context is lost (later calls return `ERR_INSTANCE_LOST`; closing it succeeds), and the host closes it once no call on it is in progress (§4.3); nothing is retried. A runtime that cannot tell a crash from a stop for memory reports a crash |
| `ERR_OUT_OF_MEMORY` | `UDF_OUT_OF_MEMORY`. Also what a runtime returns when it knows the process running user code was ended for memory (its own per-process cap, or the kernel's out-of-memory killer); the context is then lost, as after `ERR_KILLED`. The host closes the context after any `ERR_OUT_OF_MEMORY`, once no call on it is in progress (§4.3). Nothing is retried |
| `ERR_HOST_CONTRACT` | `UDF_HOST_CONTRACT_VIOLATION`, naming the runtime and the rule the host broke; a defect in the engine, never blamed on user code or on the runtime, and never retried. A runtime returns it when the host breaks a rule of this ABI that the runtime can see: an `args` struct whose children, after the group ordinal for a grouped frame or plain aggregate, differ from the bound schema (for a `ROW`, or a `MAP_BATCHES_FRAME` with a read set, a column outside it), an argument struct with a validity buffer or a non-zero offset (§3.4 rule 5), or an array on a device other than the CPU (§4.4) |
| `ERR_INTERNAL`, an unknown code, `ERR_UNSUPPORTED` at call time, or a failed import validation | `UDF_RUNTIME_FAULT`, naming the runtime; never blamed on user code |

**No retry after a loss.** Any `ERR_INSTANCE_LOST` or `ERR_WORKER_CRASHED`, from any entry, fails the run with `UDF_WORKER_CRASHED`, naming the runtime, the UDF whose call reported it (for `open_context`, which has none, the slot) and the signal or exit status observed. Once no call on the context is in progress (§4.3), the host closes its frames, groups objects and instances, then the context. `ERR_KILLED` and `ERR_OUT_OF_MEMORY` keep their own run errors (above). Nothing is retried, for any UDF, `VOLATILE` or not.

**Other failures leave the context usable.** Any status not listed above as losing the context leaves the context and its instances usable; the frame or groups object whose call failed is never called again, only closed.

Per-row errors for a TRY form, like Velox's `errorPayload` ([RemoteFunction.thrift](https://github.com/facebookincubator/velox/blob/main/velox/functions/remote/if/RemoteFunction.thrift)), are not in ABI 1.0. They would be added later as a new entry.

### 4.6 Post-conditions belong to the host

After every call, the host checks the output in one shared library, `komira_udf_host`, for every runtime. The conformance harness (§6.3) and the engine's operators (§9, S6) link the same library.

- the output passes import validation against the bound schema (§4.4), so its type is exactly `return_type` or `state_type`;
- a column-form output has the same length as the input;
- a plain aggregate returns one row per completed group, every state has one row per group, and a mergeable result has `emit_first_n` rows;
- a declared non-nullable type contains no nulls.

The same library holds compaction and scatter (§3.4 rules 1-2) and the error table (§4.5). A runtime may check its outputs too, but the host never relies on it.

### 4.7 Cancellation, deadlines and forced stops

- **Cancel is a per-call flag**, `komira_udf_call.cancel`. It applies to one call, cannot outlive it, and so cannot race with closing an instance or land on the next call. The runtime checks it between rows and between batches, and returns `ERR_CANCELLED`. There is no cancel entry, and nothing in the ABI runs in a signal handler.
- **Deadlines** arrive with each call, in `deadline_ns`, against `host->now_ns`. A runtime that notices one has passed returns `ERR_DEADLINE`. A step's `max_runtime_ms` and a host's limit per batch reach the runtime this way.
- **Forced stops.** A runtime with `FORCED_STOP` (§4.2) stops user code that has not honoured a cancel within the runtime's grace period, or that runs past its deadline, by force, except for a call that is waiting on its `in` pull, whatever produces the input (§4.3) (the Python and Node runtimes kill the worker, §5), and returns `ERR_KILLED`, with a message that says whether a cancel or a deadline caused it. The context, its instances and their frames and groups objects are then lost: a later call on any of them returns `ERR_INSTANCE_LOST` without running user code, and closing them succeeds. The host closes the context once no call on it is in progress (§4.3); the run fails with the run error of `ERR_KILLED` (§4.5).
- **The race between a result and a stop.** A runtime returns `ERR_KILLED` for a call if and only if it stopped the process running that call's user code, even when a result was already on its way. Several calls may be in progress on one context only through nesting (§4.3), and a stop that ends the process ends all of them. A host that set the cancel flag discards an `OK` result that arrives after it.
- **Why a status of its own.** The stop happens inside the runtime, so the status is the only way the host learns that user code did not return and that the context is gone. `ERR_CANCELLED` and `ERR_DEADLINE` stay the statuses of user code that honoured the request, after which the context is still usable.
- **Without `FORCED_STOP`** (`komira/native`), cancel and deadlines are cooperative: there is no safe way to stop in-process code that ignores the flag.

### 4.8 Memory accounting

- The host counts the Arrow buffers a runtime produces when it imports them.
- A runtime with the `MEMORY_REPORT` feature reports, through `memory_report`, the memory a context holds outside Arrow buffers: an interpreter heap, a loaded model, and the resident memory of any process the runtime runs for that context.
- Large allocations that a runtime controls go through `host->mem_reserve` and `mem_release`. The host may refuse them with `ERR_OUT_OF_MEMORY`.
- A runtime that runs user code in its own processes may cap each one; a process ended at its cap is `ERR_OUT_OF_MEMORY` (§4.5).

## 5. How the Python and Node runtimes execute user code (informative)

This section is not part of the contract. It records how komira's two managed runtimes are built behind the C ABI. Either may change in any release without a change to the engine, the plan or the ABI, and nothing in the engine depends on it. Their conformance is the shared corpus plus the managed cases, through the C ABI (§6.3).

### 5.1 Why workers

Both runtimes run user code in worker processes, one per context, because that is what serves their languages best:
- **Python:** the common data libraries (numpy, pandas, pyarrow, scikit-learn) refuse to load in a sub-interpreter, so the only way to run Python UDFs on several cores at once is one interpreter per process.
- **Node:** Node-API is exported by the `node` executable and embedding Node is not ABI-stable, so JavaScript runs in `node` processes, not in the engine.
- **Both:** a crash in user code or in a native extension ends a worker, not the engine (`CONTAINS_CRASHES`); user code that ignores a cancel can be stopped by killing its worker (`FORCED_STOP`); each worker can have its own memory cap.

### 5.2 How they are built

- **The library the engine loads is thin.** Per context it owns one worker process and forwards each call to it over a protocol private to that runtime. The two runtimes may share one private C library for this (`komira_udf_worker`); the engine does not link it.
- **Starting workers.** The library starts processes with `posix_spawn`, never `fork`, because the engine is multi-threaded.
  - `komira/python` spawns one *zygote* per runtime: a single-threaded process that initializes the interpreter, limits native thread pools (BLAS, OpenMP) to one thread, and loads user code at `load`. It then forks one worker per context, so the loaded code and captured values are shared copy-on-write.
  - `komira/node` spawns one `node` process per context, running a small script that loads the runtime as an addon; a `node` process cannot fork safely.
- **Channels.** A Unix socket pair per worker for control messages, and a shared-memory region per worker for payloads, which are Arrow IPC encapsulated messages with 64-byte aligned bodies (`ipc_decoder_dispatch.mojo:4088`).
  - **Slots, not rings.** Either side may hold a payload for an arbitrary time (user code may keep a view of its input, §4.4), so payloads free out of order, and a ring would fill and deadlock. Each direction is a slot heap with a bound on the bytes pinned; when the bound is reached, the runtime copies the inputs it still holds out of the slot heap.
  - **Into the worker: no copy beyond serialization;** the worker decodes in place.
  - **Out of the worker: one copy.** The worker can still write its half of the region, so the library copies each result out before it returns it to the engine (§4.4, the `out` rule).
- **Frames.** The library grants input credits as the engine pulls outputs, and the worker answers a pull with "needs input" when its frame must read before it can yield. The runtime runs a frame's user code so that its wait for input returns to the worker's dispatcher (an async iterator, or the frame on its own thread or `worker_thread`), so the worker can serve the nested calls that produce that input (§4.3).
- **Cancel and deadlines.** The library watches each call's cancel flag and deadline on the engine's clock, and tells the worker; if the worker has not answered within the grace period, it kills the worker and returns `ERR_KILLED` (§4.7). A call waiting on its `in` pull is not stopped by force, whatever produces the input (§4.3).
- **Crashes.** End of file on a worker's channel, or an exit the library did not cause, is `ERR_WORKER_CRASHED`; an exit the library can attribute to memory is `ERR_OUT_OF_MEMORY` (§4.5).
- **User ids.** Workers run under the engine's user id. They hold what the engine holds and nothing more; the rule that keeps the supervisor's run token out of the engine keeps it out of the workers too (§7).

### 5.3 Language notes

**Python** (the `komira/python` runtime, stage S4):
- **Embedding.** The worker embeds CPython. Extension modules built to the manylinux policy do not link `libpython`, so the worker loads `libpython` with `RTLD_GLOBAL` (or `dlopen(..., RTLD_NOLOAD | RTLD_GLOBAL)` once loaded), so `import numpy` finds the `Py*` symbols. This is the worker's own loading of its interpreter; user libraries loaded by `komira/native` are never loaded `RTLD_GLOBAL`.
- **ABI tag.** The runtime reports the CPython tag of its worker interpreter as `runtime_abi`, matched against `needs.runtimes`.
- **Finalization.** A worker drains its release queues before it finalizes the interpreter.

**Node** (the `komira/node` runtime, stage S5):
- **External buffers, with a copy fallback.** In the worker, buffers are wrapped as external `ArrayBuffer`s whose finalizer queues the Arrow release. `napi_create_external_arraybuffer` may return `napi_no_external_buffers_allowed` on runtimes built with the V8 sandbox, so the runtime has a copy path, and its tests force it.
- **Release `args` at return unless user code kept a view.** Garbage-collection finalizers may not run until the env is torn down, so relying on them would pin memory for an unpredictable time.
- **Cancel kills the worker.** Node-API cannot stop running JavaScript, so a call that does not return after a cancel ends with the forced stop of §4.7.

**Other notes.**
- **WASM is a runtime, not the interface.** The component model's canonical ABI copies values into linear memory ([Canonical ABI](https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md)), so it cannot share Arrow buffers. One Arrow UDF project that runs several runtimes reports these costs per 1024-row batch ([arrow-udf](https://github.com/arrow-udf/arrow-udf)): native about 1.5 µs, WASM about 15.5 µs, JS about 85 µs, Python about 175 µs. WASM may earn a place later as a sandbox for compiled languages; its mode is chosen when it is added.
- **A remote runtime can come later.** It would be one more runtime behind the C ABI, forwarding calls over Arrow Flight `DoExchange`, and needs no plan change. Delivery would become at-least-once (BigQuery remote functions document duplicate requests, [docs](https://cloud.google.com/bigquery/docs/remote-functions)), so it would serve only UDFs that are not `VOLATILE`.
- **Native code must not unwind across the ABI.** C++ entries are `noexcept` and catch everything, returning `ERR_RAISED`; Rust entries catch panics with `catch_unwind` and return `ERR_RAISED`, and an uncaught panic in an `extern "C"` entry aborts the process. Each native SDK's export helper does this, so user code cannot forget it. A Go runtime (managed, later) needs every signal handler in its process installed with `SA_ONSTACK`.

## 6. Language SDKs: the producer side

### 6.1 What a language SDK implements

1. **Verbs** that build `WireUdfApply`, `WireMapBatchesNode`, `AGG_UDF` measures and `WireStepNode`, mapping the language's idioms onto the kinds. §10.2's table is the Python and TypeScript instance.
2. **A way to declare types.**
   - It must yield a concrete Arrow `return_type`, and where needed `state_type` and `arg_types`, when the plan is built.
   - A missing type is refused by name on the user's machine (`UDF_RETURN_TYPE_MISSING`).
   - How the type is declared depends on the language:
     - A language whose types survive to run time (Python) may read them, from type hints or from a `return_dtype=` or `schema=` argument on the verb (§10.5).
     - A language whose types are erased (TypeScript) takes the type as a **value** on the verb. The static type is derived from that value, so the compiler still checks the function (§10.5).
     - For a `ROW` or `MAP_BATCHES_FRAME` verb, the types of the columns the function receives are the input columns' types, which the SDK knows when the plan is built (item 6).
     - A native language (Mojo, Rust, C++, Zig; §1.2) derives the types from the function's signature when the library is built, through its SDK's mapping table (§6.2); the export helper records them in the library, and capture checks them against the verb's declared types. C, whose signatures cannot carry Arrow types, takes them as a value on the verb. A managed compiled language (Go) does the same as the native ones, in its own SDK.
3. **Capture.** The SDK:
   - chooses a `CodeForm`;
   - writes each code object to the code layer, under its sha256;
   - splits large captured values into `data_blobs`;
   - normalizes whatever does not change behaviour, so digests are stable across sessions;
   - records the entry, the shapes it supports and its signature in the descriptor (§3.1, *Descriptor rules*), from the types above, before any value is serialized;
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
5. **A local run through the same runtime** (§10.10's "same path"), so that a capture error or a type error fails on the user's machine first.
6. **The read set of each `ROW` and `MAP_BATCHES_FRAME` UDF** (§3.1), before the plan is optimized: an explicit declaration (`columns=[...]` on the verb; in Python, a `TypedDict` or dataclass annotation on a `ROW` function's row parameter or a frame function's input parameter), else the SDK's static scan, which counts accesses on every branch; when whole-row or whole-table operations (iteration, length, conversion to a dict or tuple, unpacking, passing the row or table on) leave the reads unbounded, or the SDK has no scan, `read_set` stays unset, never a listed "every column". A local run never adds to it. The SDK refuses, by name, on the user's machine:
   - `UDF_ROW_SIGNATURE`: a `ROW` function does not take exactly one positional parameter, the row;
   - `UDF_READ_SET_INVALID`: a declaration names a column twice, or `columns=[...]` and an annotation disagree, compared before any `group_by` columns are added (the producer-side form of `OPTIMIZED_UDF_READ_SET_INVALID`);
   - `UDF_READ_SET_COLUMN_UNKNOWN`: a declared name (`columns=[...]` or an annotation), or a literal field or column name the scan finds, that the input lacks, even on a branch no row would take, naming the field and the input's columns. A name the scan cannot resolve statically (a computed `getattr`, `r[var]`, a subscript on an object that is not the row) is never refused: it leaves `read_set` unset.

   For a grouped frame, the SDK adds the columns its `group_by` reads to the read set, declared or scanned (§3.1), and, whenever it records fields in the descriptor, records them as key fields, separate from the annotation's fields and typed from the input schema; a `komira/native` descriptor is the exception, whose fields are the library's export table's, verbatim.

   *Informative: what else leaves the Python scan unbounded.* A name that is also a pandas `Series` attribute (`r.name`, `r.index`, `r.values`, `r.get`), which the scan cannot tell from a field.

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
  - Every case runs through the C ABI against each runtime, whatever it does behind the table. There is no transport harness: the harness loads the runtime library and calls it, as the engine does.
- **The harness and the operators share the host library** (`komira_udf_host`, §4.6): post-conditions, compaction, import validation and the error table. A test asserts that the S6 operators link that library; its mutant is an operator with its own length check that skips the shared one. So a runtime cannot pass by special-casing the harness.
- **Each case names the defect it catches, and the planted mutant that proves the case can fail.**

The shared cases are listed in [the conformance corpus](udf_runtime_conformance.md#shared-cases).

- **Reference runtimes ship with the harness.**
  - `komira-test/echo`, written in C, implements every entry trivially, in the calling thread, with no user code and no code objects. It proves the harness and the host library independently of any language, and it is the template a new runtime copies: the C table it implements is the part every runtime writes around its interpreter or its workers. A test-only setting makes it report `MANAGED` or any feature bit, return `ERR_INSTANCE_LOST`, `ERR_WORKER_CRASHED`, `ERR_KILLED` or `ERR_OUT_OF_MEMORY` on a chosen call, refuse or block a call made while a frame on the same context waits on its input, or take one process-wide mutex around every call, so the host's handling of each status and the class cases ([the conformance corpus](udf_runtime_conformance.md#cases-per-class)) can plant their mutants without a language.
  - `komira/native` with fixture libraries next to echo, one per native language: C (`komira-test/native-c`) and Mojo (`komira-test/native-mojo`) at the first release, then Rust (`komira-test/native-rust`), C++ (`komira-test/native-cpp`) and Zig (`komira-test/native-zig`). Each implements the corpus fixtures as exported native UDFs. The C library is the template a new native language's SDK copies; the Mojo library proves that a Mojo package can export the table. It builds with the existing `mojo_shared_lib` rule, which emits a C-ABI shared library from `@export` functions and can check that the library exports exactly the named symbols (`tools/build/mojo/README.md:20`, `:704-722`).
- **Cases per class** run in addition to the shared cases, chosen by class and features; they are listed in [the conformance corpus](udf_runtime_conformance.md#cases-per-class).

- **The coverage assertion** covers each native language's fixture library, every value of `UdfKind`, `CodeForm`, `UdfStability`, `UdfNullMode`, each capability bit, each class, a set, an unset and an empty `read_set`, and each `komira_udf_status`.
- **A runtime's own tests** cover what it does behind the table (§5): for `komira/python`, that forked workers share what the zygote loaded and that the zygote is single-threaded when it forks; for `komira/node`, the forced copy path. They are welded to the runtime's package like the corpus, and are not part of it.

## 7. Security, isolation, resource limits, crash containment

- **The engine treats user code as untrusted, and holds only what the run may use.** Every runtime library is loaded into the engine (§4.1), and a native UDF runs there, with the engine's privileges and memory. Those are the run's own.
- **No secret is scoped to one UDF.** Every secret the run holds is reachable by every UDF in it, native in the engine or managed in a worker under the engine's user id.
- **The run token stays in the supervisor.** The supervisor holds no long-lived credential, only a token scoped to one run that it uses to report that the run is alive. It runs as its own process under its own user id, and the token never reaches the engine: not in the engine's arguments or environment, not in the supervisor's own command line, not in a readable file, an inherited descriptor or a socket the engine can connect to (`optimized_plan_udf_runtime.md` §10.10). The supervisor observes the engine process itself (a process descriptor, `waitpid`) and never takes a liveness message from the engine. So user code, in the engine or in a process a runtime starts, can end the run but cannot read the token, report on the run, or trace or signal the supervisor. A launch-gate case holds the host to this (§6.3); a host that fails it does not ship native UDFs.
- **Processes a runtime starts** (the Python and Node workers, §5) run under the engine's user id and hold nothing the engine does not; they add crash containment and forced stops, not a privilege boundary: `CONTAINS_CRASHES` covers accidental crashes, and a malicious worker can still kill or trace the engine. A runtime that runs user code in another process hands the engine only buffers that process can no longer write (§4.4).
- **Runtimes from an added image layer** would be loaded into the engine like any runtime; whether they are allowed is open (§1.3, §8.3).
- **Code integrity.** `load` verifies every code object against its sha256 before use (`OPTIMIZED_UDF_CODE_DIGEST_MISMATCH`). Admission already checks that the code is present (§10.11 check 4).
- **Resource limits.**
  - Memory per context, from `worker_mem_bytes` and `memory_report` (§4.8); a runtime that runs user code in its own processes may cap each one.
  - Native thread pools set to each context's share of the CPUs (§10.10).
  - State per group capped at a fixed 64 MiB at the first release, the same on every host and not settable by a plan; a group over it fails the run with `UDF_STATE_TOO_LARGE`, naming the group key (§10.2). Making the cap tunable is tracked in komira-ai/komira#1148, and `max_state_bytes` (§10.8) is reserved for it.
  - Forced stops only in runtimes with `FORCED_STOP` (§4.7).
- **Crash containment.**
  - In a runtime with `CONTAINS_CRASHES`, a crash of user code is `UDF_WORKER_CRASHED`; the engine survives, and the run fails with `UDF_WORKER_CRASHED`, naming the UDF and the signal or exit status; nothing is retried (§4.5). A forced stop is not a crash (§4.7).
  - A crash of in-process native code kills the engine process and fails the run. The run fails with a named UDF fault naming the faulting library, commits no partial output, and leaves the host fit for the next run; the supervisor's crash reporter that names the library is an S3b deliverable, and the NULL-dereference launch gate holds the host to this (§1.2, §6.3).
- **Captured data is data** (§10.6). Whoever can pull the image can read it, so the producer lists large captures before upload.

## 8. Versioning

### 8.1 The rule

| Contract | Promise | Why |
|---|---|---|
| The plan format: `UdfRef`, `UdfCode`, `RuntimeNeed`, the arms | **Backward compatible forever** (`optimized_plan.md` §9) | Plans are stored and replayed |
| A runtime's descriptor schema | **Readable forever by that runtime**, in every base that ships the runtime | The descriptor is part of the plan's identity |
| The C ABI, `komira_udf_runtime.h` | Entries and struct fields are only appended within a major version; a base accepts every minor of each major it lists | Needed only for runtimes built outside the base release (§8.3) |
| A runtime's own worker protocol (§5) | **None**: private to that runtime | Only the runtime speaks it; the engine never does |

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
- **`snapshot` and `restore`** for a callable's own state, kept across a restart by a streaming checkpoint. ABI 1.0 has neither, and the plan spec says so: a restarted run loads the code again and starts with empty state, and keeping a callable's own state needs these entries (`optimized_plan_udf_runtime.md` §10.10, the bullet "State in a context does not survive a restart at the first release", which cites this section). Their meaning must be fixed first: per instance, called by the host only between calls at a checkpoint barrier, returning one Arrow value. Until they exist, a restarted context starts with empty state, and mergeable aggregate state is checkpointed through `agg_state`.
- **Per-row errors** for a TRY form (§4.5).

### 8.2 Plans stay readable forever

- Decoding and admitting a plan never needs a runtime, because the format is neutral. A plan that names a runtime no base has ever shipped still decodes; it is then refused at admission by name (§3.1), never misread.
- A stored plan executes in the environment image it was recorded with (§10.12), so its runtime is present.
- When a plan moves to a newer base, that base's runtime with the same id must read the plan's `descriptor_version`.
  - A runtime never drops a released descriptor version while any base ships the runtime.
  - The corpus enforces this. Each runtime's descriptor corpus holds one plan per released descriptor version, and a newer runtime that refuses one turns its welded test red.

### 8.3 Runtimes outside the base

- **Packaging.** A third-party runtime ships as an added image layer, under the reserved prefix `/komira-runtimes/<namespace>/<name>/`. The layer holds the library and a manifest: `runtime_id`, `runtime_abi`, the C ABI major and minor, and the library's sha256.
- **The registry.** The image's runtime registry is the base's release record plus these manifests.
- **Header-only admission (§10.11 check 3)** accepts a `needs.runtimes` pair that the base lists, or that an added runtime manifest layer declares. The layer is identified by its digest in the image manifest *(inferred: the scheduler cannot read layer contents, so the base release record must name the form of the manifest digest; the detail is left to the image design)*.
- **Host admission** re-checks the manifest and the library's digest once the layers are in hand.
- **Execution.** Such a runtime would be loaded into the engine like any runtime (§4.1). Whether added runtimes are allowed on that basis is open (§1.3).

## 9. Implementation stages

Each stage lands with its tests welded and its testing plan stated: what each test proves, and the mutant that turns it red.

| Stage | Work | Owner area | Done when |
|---|---|---|---|
| S0 | This document, and the optimized-plan UDF section aligned to it before any `format_version` ships: open runtime ids, `CodeForm`, `needs.runtimes`, `STEP`, the two `MAP_BATCHES` kinds and the `ROW` kind (`DataFrame.apply(f, axis=1)` and `map_rows` map to `ROW`), and the optional read set on `ROW` and `MAP_BATCHES_FRAME`; one mode per language in place of #1094's three modes (§1.3); a review rule, or a lint if one is written, that no runtime's descriptor schema declares its own copy of `RecordedFields` (§3.1; the message itself is added to `plan.proto` in stage 11 of `optimized_plan.md` §12) | design | Both merged, and the review rule written down |
| S1 | `komira_udf_runtime.h`; a Mojo binding package, with private pointers behind a safe API; the Arrow C Device structs; an args exporter on the stream path's shared-reference model, and C Data import without copying, with layout validation and release ownership, in `komira_arrow_ipc`; the host library `komira_udf_host` (post-conditions, compaction and scatter, error table); the reference runtime `komira-test/echo`, in C | engine, Arrow | Echo passes every ABI case, and the host maps each status echo can be set to return; the leak, double-release and skip-validation mutants go red |
| S2 | The conformance corpus package (ABI cases), the harness and the coverage assertion; the runtime-swap invariance test for the optimizer (§3.2) | tests, optimizer | The corpus runs against echo; the invariance mutant goes red |
| S3 | `komira_udf_worker`: a private C library the Python and Node runtimes link to run user code in worker processes (§5, informative): spawning, slot heaps, copy-out, frame credits, cancel and forced stop, crash and memory reporting. The engine does not link it | engine | A test runtime built on it passes the corpus through the C ABI, with the forced-stop, crash, out-of-memory, held-views and cancel cases |
| S3b | The `komira/native` runtime (§1.2): `validate` against the descriptor, digest check before `dlopen`, library choice per platform, `komira_udf_native_init_v1`, the library's own `validate` at `load`, forwarding; the fixture libraries `komira-test/native-c` and `komira-test/native-mojo`; export helpers for C and Mojo that record each entry's shapes and signature; the native cases (§6.3); the supervisor's crash reporter that names a faulting native library (§7) | engine, Mojo | Both fixture libraries pass the corpus and the native cases; the digest-after-`dlopen`, unchecked-capabilities and missing-catch mutants go red (the catch case uses the Mojo fixture's raising function; C cannot raise); **the three launch gates pass: the run-token case, the `RTLD_GLOBAL` case and the NULL-dereference case**, with the supervisor's crash reporter that names the faulting library. Native UDFs do not ship before they are green |
| S3c | Native SDKs for Rust, C++ and Zig, after the first release: export helpers (Rust catches panics, C++ is `noexcept`, §5.3), typed views of Arrow C Data, capture of the library into the code layer; fixture libraries `komira-test/native-rust`, `komira-test/native-cpp`, `komira-test/native-zig` | engine, SDKs | Each fixture library passes the corpus and the native cases; the C++ throw and Rust panic cases go red without the catch |
| S4 | The `komira/python` runtime: a C-ABI library that runs user code in workers forked from a zygote (§5); batch formats, entry, shapes and signature in the descriptor; the `ROW` proxy; the producer's read-set declaration, scan and refusals for `ROW` and `MAP_BATCHES_FRAME` (§6.1) | Python | Python fixtures pass the corpus, `ROW`, read-set, crash, forced-stop and managed cases included, through the C ABI |
| S5 | The `komira/node` runtime: a C-ABI library that runs user code in `node` worker processes (§5); external `ArrayBuffer`s with a copy fallback; entry, shapes and signature in the descriptor | Node | Node fixtures pass the corpus, crash, forced-stop and managed cases included, through the C ABI |
| S6 | Physical operators (`UdfProject`, `UdfFrame`, `UdfAggregate`, the groups accumulator, `UdfStep`) in lowering, linking `komira_udf_host`; the plan cases. They replace the SDK-side walk that works around the package cycle (`expr_udf_sites.mojo:1-30`) | engine | UDF plan cases run through lowering, not through the SDK |
| Later | ABI 1.1 candidates (§8.1); third-party runtime layers (§8.3); further native languages (each adds an SDK and fixtures, no runtime id); a tunable per-group state cap (komira-ai/komira#1148); managed runtimes for JVM, .NET and Go; WASM, with its one mode chosen when it is added; GPU devices; a remote runtime | — | Each native SDK adds corpus fixtures; each managed runtime adds a runtime id and fixtures; neither changes the format |

**Prototypes.** Prototypes of each runtime and transport were built against this contract before this revision, and their findings shaped §1.2, §3.1 (*Descriptor rules*, `ROW`), §4.2, §4.5, §4.7 and §5.2. None of their measurements is part of this design. Measurements choose only host-local defaults (batch size, pool size, the cancel grace period), which can change in any release without a plan change; keeping the transport out of the plan is what makes this true.

## 10. Options considered

| Option | Verdict |
|---|---|
| A closed runtime enum, with one `oneof` arm per language's code form (an earlier draft; Spark Connect's shape) | Rejected. Each language becomes a format change, an optimizer change and a validator change, forever. SPARK-55278 proposes moving Spark away from it. |
| A fully neutral code record (`{form, bundle, module, symbol, payload, serializer}`) that every language fills the same way | Partly adopted. `form`, `entry` and the digest list are neutral, and admission reads them. What genuinely differs between languages (serializer, batch format) goes in the descriptor the runtime owns. |
| An opaque descriptor only, with no neutral `form`, `entry` or digest list | Rejected. Admission could not check that code is present without the runtime, and diagnostics could not name the entry. |
| The runtime's ABI tag in `UdfCode` | Rejected. It would change a reference's identity on every interpreter upgrade, and allow plans that name two ABIs of one runtime. It lives only in `needs.runtimes`. |
| The `MAP_BATCHES` form derived from the arm that targets it | Rejected. One `UdfRef` could then be bound with two schemas; the shape is in the kind. |
| The transport chosen in the plan, or bound by the engine (an engine-side proxy for each runtime's workers, a transport field in the host struct; an earlier draft) | Rejected. How a runtime executes is its own business, and each language knows what serves it best. An engine-side transport would add a second protocol to the engine and capabilities that describe the proxy, not the runtime. The C ABI is the one interface (§4.1). |
| An ABI that mirrors one engine's traits (DataFusion's FFI crate, written for Rust libraries, [README](https://github.com/apache/datafusion/blob/main/datafusion/ffi/README.md)) | Rejected. Plain C over Arrow is the only ABI every language can implement. |
| The WASM component model as the outer ABI | Rejected. The canonical ABI copies values, and Python in WASM loses native packages. Kept as one runtime. |
| Calls per row (PostgreSQL's Datum convention; Trino's invocation per position, [trino#30301](https://github.com/trinodb/trino/pull/30301)) | Rejected. Calls are one batch at a time, and a scalar runtime loops in its own language. |
| Aggregate calls per group, with an opaque handle per group | Rejected. A high-cardinality group-by would cross the ABI once per group per batch. Aggregates are vectorized over groups, as DataFusion's `GroupsAccumulator` is. |
| Aggregate state that is pickled or private to the language | Rejected. `state_type` is Arrow: it crosses exchanges and checkpoints, and it has a size the host can cap. |
| A separate determinism field | Rejected. `stability` is the determinism declaration. |
| A row-shaped UDF as a `SCALAR` over the whole row, or a host that infers the fields read | Rejected. The whole row keeps every column live; a host cannot re-derive what the producer knew, and two hosts could disagree. `ROW` carries an optional read set (§3.1). |
| The read set carried only in `arg_types`, with every input column listed when the reads are undetermined (an earlier draft) | Rejected. `arg_types` can say "every input column" only by listing them, which reads the same as a declared read set naming every column, and it gave a frame no read set. An optional `read_set`, unset meaning every column, states the rule; validation keeps `arg_types` in agreement. |
| `read_set` as a bare `repeated string` | Rejected. A repeated field has no presence in proto3, so "reads every column" and "reads none" would be one encoding. |
| An empty read set refused | Rejected. A function that reads no column is legitimate, and a struct with no children already carries the row count (§3.4 rule 5). For the same reason a descriptor's field list has presence: absent means none recorded, empty means no column. |
| The read set on the call-site node rather than on `UdfRef` (an earlier draft) | Rejected. `arg_types` already binds a `UdfRef` to the columns it receives, and the runtime binds them once at `load`; a read set on the call site would let two calls of one `UdfRef` disagree with its `arg_types`. |
| A `cancel` entry callable from any thread or a signal handler | Rejected. It races with close and cannot be built for CPython or Node-API. Cancel is a per-call flag (§4.7). |
| Zero-copy decode of worker-to-engine payloads, with sealed per-payload memory files (`F_SEAL_WRITE`) | Not chosen for the Python and Node runtimes at the first release (§5, informative). It removes one copy but adds a file per payload; the copy-out is simpler. |
| A mode field in `UdfRef`, or a plan rule per mode | Rejected. The mode is how a runtime executes code, which is the runtime's own business (§4.1). No plan field names the class, and the plan carries both classes identically (§1.2). |
| Capabilities that state the mode or the transport: `threading`, `global_lock`, `thread_affine`, `hosting` and `transports` (an earlier draft) | Rejected. They describe how a runtime executes, which is its own business; through a worker proxy they described the proxy, not the runtime. `describe` reports what a runtime can do (§4.2). |
| Managed user code in the engine's process, with one interpreter or isolate per engine thread (Python sub-interpreters, Node `worker_threads` isolates), or in one shared parallel virtual machine (free-threaded Python) | Rejected. Both were prototyped before this revision. Python's common data libraries (numpy, pandas, pyarrow, scikit-learn) refuse to load in a sub-interpreter; Node in the engine needs `node` to host the engine; nothing measured for the free-threaded build justified a second Python mode. One mode per language leaves one path to build, certify and support (§1.2). |
| `validate` that opens the code (a `dlopen`, an import, an unpickle) to check entries, shapes and signatures | Rejected. It would run library constructors and user code at admission, and TypeScript keeps no types at run time to check. The producer records them in the descriptor at capture; `validate` compares, and `load` confirms (§3.1, §4.3). |
| One runtime id per native language (`komira/rust`, `komira/mojo`) | Rejected. Native languages share one ABI, so one loader serves all; the language is in the descriptor for diagnostics. A new native language adds an SDK, not a runtime. |
| Native UDFs in workers by default, until a host shows in-process native code cannot reach privileged credentials (an earlier draft) | Rejected. The supervisor holds no long-lived credential, only a run-scoped token for liveness reports, kept in its own process and user id and never passed to the engine, so in-process native code reaches only the run's own privileges. Native UDFs run in-process (§1.2, §7). |
| A per-group state cap set per host or per plan at the first release | Not chosen. A fixed 64 MiB cap is the same on every host, so a plan that runs on one runs on all; tuning it is komira-ai/komira#1148, with `max_state_bytes` reserved. |
| One base carrying several CPython minors or Node majors, or both a Python and a Node runtime | Rejected. A release ships one base per CPython minor and one per Node major, each with one managed runtime, and a remote run follows the client's version; a plan that needs two managed runtimes is refused with `OPTIMIZED_ENV_RUNTIME_MISSING` (§3.2). |
| Go as a native language | Rejected. A Go shared library carries the Go runtime (scheduler, collector, signal handlers, one per process), so it is managed; its runtime chooses how it executes (§1.2). |
| No ABI promise at all (internal to the image only) | Rejected. Third-party runtimes would need a rebuild for every base release. The promise costs only a header and a version check. |
| A status that reports a forced stop as its reason (`ERR_CANCELLED`, `ERR_DEADLINE`; an earlier draft) | Rejected. The runtime stops user code itself, so the host learns only from the status that the context is gone; `ERR_KILLED` says so, and its message gives the reason (§4.7). |
| Retrying a batch, or reopening a frame or aggregate, after a lost context | Rejected for the first release. A retry rule needs open-object tracking across `emit_first_n`, `PARTIAL` steps and failed opens, and none of it is settled. Any loss or crash fails the run with `UDF_WORKER_CRASHED`, naming the UDF (§4.5). |
