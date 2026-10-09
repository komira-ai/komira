# komira_udf_spike_node

Spike code, test-only: a Node.js UDF runtime in-process behind the C ABI of
`docs/design/udf_runtime_interface.md`
(the contract, its harness and its conformance cases are
[`komira_udf_spike_abi`](../komira_udf_spike_abi/)), the engine side that drives
it from a node process, and the measurements. Nothing outside `src/tests` may
depend on it.

## What it is

- **The runtime** ([`runtime/`](runtime/)) is a Node-API addon written in C and
  built by `c_shared_lib` (its `napi_*` symbols are left undefined: node
  resolves them when it loads the library, so node hosts the process). The same
  file is the module a script `require`s and the library an engine `dlopen`s
  for `komira_udf_runtime_init_v1`; node loads it first, so the two share its
  state. It is context-aware: each environment's state is instance data
  (`napi_set_instance_data`), never a global.
  - `rt_table.c` is the table as engine threads see it. It calls no Node-API:
    `validate` and `load` read the spec and the bundle's text, every other
    entry that reaches user code queues a request on the environment that runs
    the context and waits.
  - `rt_js.c` runs the requests on that environment's JavaScript thread (a
    threadsafe function's callback), `rt_arrow.c` converts between Arrow C Data
    and JavaScript, `rt_main.c` is the module, its environments and their
    registry.
  - `adapter.js` binds a user function to a shape and loops: per row, per batch
    over Arrow vectors, over a record of the declared fields, over groups, over
    a generator of batches. `worker.js` is the entry of a context's isolate.
- **Two builds of one source** (`-DKOMIRA_NODE_WORKERS`).
  - `runtime_workers.node`, `komira-test/node-workers`: `open_context` starts a
    `worker_threads` thread, one isolate per context and so per engine thread.
    It declares `CONTEXT_PER_THREAD`, `global_lock` 0.
  - `runtime_shared.node`, `komira-test/node-shared-isolate`: every context is
    an object of the main isolate, behind its one thread. It is the baseline
    and the expected ceiling, and it breaks the rule that no lock is shared
    across engine threads, which it declares (`global_lock` 1).
- **User code** ([`fixtures/`](fixtures/)) is TypeScript as a user writes it, no
  decorator and no runtime import, bundled alone by esbuild. apache-arrow is
  imported for its types and is the base image's package at run time. The
  result type is the plan's: TypeScript's types are erased.
- **The engine side** ([`engine/`](engine/)): `engine_loop.c` is what an engine
  thread does with a UDF operator (open a context and an instance, then
  `call_batch` once per batch, timed with `CLOCK_MONOTONIC` around the table
  entry alone), `engine_host.c` the addon that starts those threads and returns
  the results to a script, and `engine_so.mojo` the Mojo conformance harness as
  a library that addon runs on a thread of its own.

## Data

Into JavaScript there is no copy: each buffer of an argument array is wrapped
as an external ArrayBuffer over the engine's memory, once per distinct address
in a call, and every wrap is detached when the call ends, so a view the user's
code kept is empty and the engine's array is released at return, not at a
garbage collection. Where external buffers are not allowed (a node built with
the V8 sandbox), or when a test forces it, the bytes are copied into V8's
memory and counted. Out of JavaScript there is one copy: a result is a
V8-owned typed array, copied into a block this addon allocates. Both are
counters of the addon (`stats()`).

## Tests

Each is a `node_test` (building the target runs it), except the one Mojo test.
The mutant each was seen red against is in the script's header.

| target | what it proves | the defect it catches |
|---|---|---|
| `:test_load_gate` | the Mojo runtime starts inside a library node's addon loads and is entered from the main thread, a thread node made and four `worker_threads`; the exit statuses are pinned | Mojo runtime libraries not found through `$ORIGIN/lib`, a Mojo runtime that crashes when entered from a thread it did not create |
| `:test_conform_shared`, `:test_conform_workers` | the shared conformance cases a TypeScript function can express (30 of 38) and the capabilities check pass on each build, through the Mojo harness, none skipped | an offset ignored, a null lost, a release missing, cancel or a deadline ignored, an undeclared ROW read passed, an aggregate that overwrites on merge, a frame that drains its input first |
| `:test_context_aware` | the addon loads in four `worker_threads` at once, each environment has instance data of its own and it is freed when the worker exits | state shared across environments, state never freed |
| `:test_external_buffers_*` | what node 24 does when an address is wrapped twice (pinned); each buffer is wrapped once per call and detached at its end, a sliced argument is read from its offset, a kept view is empty, the copy path gives the same values and counts its copies, the result is one counted copy, every engine array is released at return | a column wrapped twice, a wrap left attached, a sliced reader ignoring the offset, an array held until the finalizer |
| `:test_threads_*` | four engine threads: values, one runtime call per batch, releases, state per context, a model held per context, outputs held past the close of their context, one isolate per context (workers) or the main thread (shared), CPU/wall near 4 (workers) or 1 (shared), a call on the environment's own thread refused | a shared interpreter behind per-thread contexts, a lock across engine threads, a per-row hop, a leaked array |
| `:test_cancel_*` | cancel is seen between rows, at the next row boundary: a 100 ms row is followed by a stop, a 300 ms row is not interrupted; in the workers build a row that never returns is killed after a 1 s grace period (the isolate is terminated, the call ends `ERR_INSTANCE_LOST`, a new context works), in the shared build it cannot be | a flag read only before the call, a hard stop that never comes, a lost context reused |
| `:test_errors_*` | `validate` refuses by name without running the bundle; a wrong return type, a thrown string and an export of the wrong kind are reported by name | a lax validator, a lossy cast, a thrown non-Error lost |
| `:komira_udf_spike_node` (`tests/test_node_cases.mojo`) | the Node runtime runs 30 of the corpus's 38 cases, each entry rewritten to the bundle; the list of cases left out raises when it goes stale | a stale list, an entry not rewritten |

`:bench` runs `bench/bench.js` and keeps its output, one JSON object, as a
file; `bench/run_id` names the run, and bumping it re-runs the bench and
nothing else. The `:log_*` targets keep the stdout of a test script.

## Limits

- linux x86_64 only, as the Node.js rules are.
- Types: int32, int64 and float64 columns; no strings, no nested types.
- No code digests: a spec that lists code objects is refused.
- A row that does not return cannot be interrupted by Node-API (it has no call
  that stops JavaScript running in an isolate): cancel stops at the next row
  boundary. In the workers build the runtime then kills the isolate
  (`worker.terminate()`) once the flag has been set for 1 s and the call has
  not ended, and the context is lost; in the shared build the main isolate
  cannot be killed, so a row that never returns hangs its engine thread.
