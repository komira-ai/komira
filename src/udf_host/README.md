# udf_host

The engine's host of UDF runtimes ([docs/design/udf_runtime_interface.md](../../docs/design/udf_runtime_interface.md)
section 4). A UDF runtime is a shared library that implements the C ABI of
[`src/udf_abi/komira_udf_runtime.h`](../udf_abi/komira_udf_runtime.h); komira's
Python runtime is `libkomira_udf_python.so` (`src/udf_python`). This package
opens one, admits the UDFs of a plan on it, and makes the calls of the
column-kind UDFs (`SCALAR` and `MAP_BATCHES_COLUMN`) that `OP_UDF_APPLY`
(`pipeline_exec`) runs. `so` reaches it through `komira_udf_runtime_set` and
the plan door ([src/so](../so/README.md)).

- `_abi.mojo`: the one file that holds pointers (`FFI-BOUNDARY`). It mirrors
  the header's structs field for field, opens the library with `dlopen`
  (never closed again, since runtimes start threads), calls its one export
  `komira_udf_runtime_init_v1` with the host struct, and calls the table's
  entries. The rest of the package sees handles it cannot read through.
- `status.mojo`: the runtime's `komira_udf_status` as the engine's named
  error (`status_code`, `status_name`, `loses_context`); the table is below.
- `runtime.mojo`: `UdfRuntimeConfig` (the library path, the runtime's own
  `key=value` options, the code root and the per-batch bound), `UdfRuntime`
  (one opened runtime, shut down when dropped) and `UdfBinding` (the UDFs of
  one plan, admitted and loaded).
- `instance.mojo`: `UdfInstance`, one worker's calls of one UDF.

A session holds its `UdfRuntime` behind an `ArcPointer`; each run's binding and
each worker's instance hold it too, so it is shut down when the last of them
is dropped.

## Admission

`UdfBinding.bind(runtime, udfs)` checks every `UdfRef` of the plan before any
row is read, and refuses the plan with the first that fails:

- the runtime the UDF names is the one the session holds
  (`OPTIMIZED_ENV_RUNTIME_MISSING`, naming both);
- its kind is `SCALAR` or `MAP_BATCHES_COLUMN`, and a shape the runtime's
  `describe` reports (`OPTIMIZED_UDF_KIND_UNSUPPORTED`; a `ROW` UDF is refused
  here);
- it has a return type (`OPTIMIZED_UDF_RETURN_TYPE_MISSING`), and under
  `NULL_PROPAGATE` one the host can put back into the NULL rows: a fixed-width,
  boolean or string type (`UDF_NULL_PROPAGATE_UNSUPPORTED`);
- every code object it names is a file of the code root, named by its hex
  sha256 (`OPTIMIZED_ENV_CODE_MISSING`, naming the digest), checked before the
  runtime is asked anything;
- the runtime's `validate` and then its `load` accept it, their statuses mapped
  by the table below.

Opening a runtime (`UdfRuntime.open`) refuses a library that does not load
(`UDF_RUNTIME_OPEN_FAILED`), one without the init export
(`UDF_RUNTIME_MISSING_SYMBOL`), a table of another major version or shorter
than the host needs (`UDF_RUNTIME_ABI_MISMATCH`), an option the runtime refuses
(`UDF_RUNTIME_OPTION_INVALID`), an init that fails (`UDF_RUNTIME_INIT_REFUSED`)
and a `describe` that fails. The UDFs are unloaded when the binding is dropped,
after every instance made from it.

## A call

`UdfInstance.call(args, rows)` is one batch of one worker. Each worker has a
context and an instance of its own (komira/python: one worker process forked
from the zygote), so two workers never share state and their calls run at once.

- Each argument column is the type its `arg_types` entry declares
  (`OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`, naming the argument).
- Under `NULL_PROPAGATE` a row with a NULL argument is not passed to the
  runtime and its result is NULL: the runtime sees the other rows only, in
  order, and the host scatters its answer back. A batch with no NULL argument
  is passed as it is, and a batch of only NULL rows makes no call. Under
  `MANUAL` every row is passed.
- A ceiling on rows per call (`UdfResources.max_batch_rows`, 0 for none) cuts a
  batch into calls of at most that many rows, in order.
- The output is validated (layout) and copied at the return type, then checked
  against the post-conditions: `rows` rows (`UDF_BATCH_LENGTH_MISMATCH`) and no
  NULL in a non-nullable return type (`UDF_RETURN_TYPE_MISMATCH`).
- A failure is the status's code with the UDF's name and the runtime's message,
  the row it names in this batch's numbering (mapped back through the
  compaction and the cuts), and the user's trace on the lines after.
- A worker that died or was stopped by force, a runtime out of memory, or a
  context already lost loses the instance: every later call refuses with
  `UDF_WORKER_CRASHED` and runs nothing. Nothing is retried.

## Errors

The first word of the error text is the code; `so` reports it as the last
error's code, at step `bind` for admission and `execute` for a call.

| Runtime status | Code |
|---|---|
| `ERR_RAISED` | `UDF_RAISED` |
| `ERR_RETURN_TYPE` | `UDF_RETURN_TYPE_MISMATCH` |
| `ERR_LENGTH` | `UDF_BATCH_LENGTH_MISMATCH` |
| `ERR_WORKER_CRASHED`, `ERR_INSTANCE_LOST` | `UDF_WORKER_CRASHED` |
| `ERR_DEADLINE`, `ERR_KILLED` | `UDF_DEADLINE_EXCEEDED` |
| `ERR_OUT_OF_MEMORY` | `UDF_OUT_OF_MEMORY` |
| `ERR_CANCELLED` | `UDF_CANCELLED` |
| `ERR_HOST_CONTRACT` | `UDF_HOST_CONTRACT_VIOLATION` |
| `ERR_FIELD_NOT_DECLARED` | `UDF_FIELD_NOT_DECLARED` |
| `ERR_STATE_TOO_LARGE` | `UDF_STATE_TOO_LARGE` |
| `ERR_GROUP_TOO_LARGE` | `UDF_GROUP_TOO_LARGE` |
| `ERR_DESCRIPTOR` | `OPTIMIZED_UDF_DESCRIPTOR_INVALID` |
| `ERR_UNSUPPORTED` | `OPTIMIZED_UDF_UNSUPPORTED` |
| `ERR_CODE_DIGEST` | `OPTIMIZED_UDF_CODE_DIGEST_MISMATCH` |
| `ERR_LOAD` | `OPTIMIZED_UDF_CODE_UNLOADABLE` |
| `ERR_READ_SET_MISMATCH` | `OPTIMIZED_UDF_READ_SET_DESCRIPTOR_MISMATCH` |
| `ERR_ABI` | `UDF_RUNTIME_ABI_MISMATCH` |
| `ERR_BAD_OPTION` | `UDF_RUNTIME_OPTION_INVALID` |
| any other status, `ERR_INTERNAL` among them | `UDF_RUNTIME_FAULT` |

`ERR_WORKER_CRASHED`, `ERR_KILLED`, `ERR_INSTANCE_LOST` and `ERR_OUT_OF_MEMORY`
leave the context unusable (`loses_context`); only its closes may be called
after.

## Bounds

- **A batch.** Each call has a deadline: the session's per-batch bound
  (`batch_deadline_ms` of `komira_udf_runtime_set`; 0 is 600000 ms) after the
  call starts. The runtime stops the user code by then and, past its own grace
  period (`grace_ms`), stops the worker by force (komira/python: SIGKILL); the
  call returns `ERR_DEADLINE` or `ERR_KILLED`, both `UDF_DEADLINE_EXCEEDED`.
- **A worker's death.** The runtime sees it at once (komira/python: the end of
  the worker's socket), the call returns `ERR_WORKER_CRASHED`
  (`UDF_WORKER_CRASHED`) and the instance is lost.
- **Not bounded.** Starting a runtime (komira/python: the zygote's hello and
  each UDF's load) and shutting it down (waiting for the zygote) have no
  bound in the runtime today: `src/udf_python/zygote.c` blocks in `recv` and
  `waitpid`. The host's memory hook accepts every reservation, so a UDF's memory
  is not accounted.

## Not here yet

`OP_UDF_FRAME` and `SOURCE_UDF_STEP` (the frame and step kinds), the `ROW`
kind, aggregates and grouped calls, bisecting a raise that names no row to its
first failing row, a host cancel flag for a running call, a bound on a
runtime's start-up and shutdown, memory accounting, the SQL call of a Python
function, and a public decorator, `Series.apply` and `map_elements`.

## Tests

The welded tests run on `komira-test/echo`, the reference runtime of the
conformance suite (staged as `echo.so`), and on `echo_variant.so`, the same
runtime with one thing wrong in its table or answers (chosen by
`KOMIRA_UDF_ECHO_VARIANT`). The Python runtime is driven end to end by
`//python:udf_installed_test`, and the plan door by
`so`'s `test_plan_result_udfs`.

- `test_udf_host_runtime`: opening a runtime and admitting a plan's UDFs, each
  refusal by its code (a library that does not load, an init that refuses, a
  table of another major version or too short, a describe that fails, a UDF of
  another runtime or kind, without a return type, with a code object missing
  from the code root, or that `validate` or `load` refuses), and that a bound
  UDF's spec reaches the runtime in the ABI's numbering.
- `test_udf_host_calls`: one worker's calls: rows in equal rows out, NULLs under
  `MANUAL` and `NULL_PROPAGATE` (the runtime sees no NULL row, and an all-NULL
  batch makes no call), a call with no argument, an empty batch, the row
  ceiling, a raise with its row mapped back through the compaction, a lost
  context and the calls after it, each post-condition and each ABI fault of the
  output, and the contexts and instances a variant refuses.
