# udf_python

`komira/python`: the UDF runtime library for Python functions. It is C11 with GNU extensions (`memfd_create`, `posix_spawn_file_actions_addclosefrom_np`), built as
`libkomira_udf_python.so`, and implements the `komira_udf_runtime` table of
[`udf_abi`](../udf_abi/). It exports one symbol, `komira_udf_runtime_init_v1`. The design is
[`docs/design/udf_python_worker.md`](../../docs/design/udf_python_worker.md); this build covers
SCALAR (VALUES and ARROW) and MAP_BATCHES_COLUMN (ARROW) over int64, int32 and float64, with the
code forms PACKAGE and BUNDLE. Linux only, with glibc 2.34 or later.

## What it does

- `init` reads the runtime options from the host struct (`key=value` strings): `interpreter`, `zygote`,
  `abi` and `scratch` are required; `sys_path` (repeated), `grace_ms` and `trace` are optional. A refused
  option is `KOMIRA_UDF_ERR_BAD_OPTION` with a message that starts `UDF_RUNTIME_OPTION_INVALID`. Nothing
  starts at `init`.
- `describe` answers runtime id `komira/python`, the `abi` option as its runtime ABI, descriptor version 1,
  the two shapes above, CPU, class MANAGED, and the features `CONTAINS_CRASHES` and `FORCED_STOP`.
- `validate` is pure: it decodes the descriptor (protobuf, canonical form only), checks it against the spec
  and the types, and starts no process and opens no file.
- `load` validates, then starts a zygote when there is no current generation: `posix_spawn` of
  `<interpreter> -I -X utf8 <zygote> --control-fd 3 ...` with a scrubbed environment, a working directory under
  `scratch`, descriptor 3 the control socket. The zygote answers HELLO (the library refuses a free-threaded
  or non-CPython interpreter, or a tag that differs from `abi`), and imports the module on LOAD.
- `open_context` asks the zygote (FORK) for one worker, passing its socket end and the memfd of the cancel
  word as `SCM_RIGHTS`; the reply carries the worker's pid and a pidfd the zygote opened on it before
  answering. Calls go to the context's worker over the socket as Arrow IPC messages. While waiting
  for a reply the library polls every 10 ms and, when the host cancels or the deadline passes, stores the
  request's id (never 0, never reused on a context) in the cancel word, which the worker reads between rows.
- Forced stop: a worker that has not answered `grace_ms` (default 2000, read against `host->now_ns`) after
  the store is sent `SIGKILL` through its pidfd, and the call returns `ERR_KILLED`.
- Supervision (design section 5): end of file on a worker's socket is its end. The library then waits,
  under the zygote lock, for the zygote's `EXIT` report of that worker, or for the zygote's own end, and
  names it: during a call `ERR_KILLED` for its own `SIGKILL`, else `ERR_WORKER_CRASHED` with the signal
  (`signal 6 (SIGABRT)`), the exit status, or the zygote's end; before a call (a context polls its socket
  for a hang-up before each request) `ERR_INSTANCE_LOST` naming the same. After a `MemoryError`
  (`ERR_OUT_OF_MEMORY`) it waits for the worker's exit too. A lost context runs no user code again and
  closes cleanly; nothing is retried. A zygote that ends retires its generation: its contexts are lost, the
  next `load` starts a new zygote. The zygote is reaped by its own pid only; if something else in the
  process reaped it, its status is unknown.
- A fork of the engine's process: a `pthread_atfork` child handler closes every descriptor the runtimes
  own in the child, so the zygote still sees end of file when the engine ends; there every `load`,
  `open_context` and call returns `ERR_INSTANCE_LOST`. The prepare handler takes each runtime's zygote
  lock, so a fork waits for a `load`, a FORK or a wait for an `EXIT` report in progress.
- Generations: a LOAD reply with the RETIRE flag (a module imported from another bundle, or threads started
  by an import) retires the generation; it is shut down when its last context closes, and a RETRY reply loads
  again in a new generation.

## Files

| File | Holds |
|---|---|
| `runtime.c` | the table, `init` and the options, `describe`, `load`, `unload`, the fork handler, the entries of shapes not built |
| `descriptor.c` | the descriptor decoder and `validate` |
| `zygote.c` | generations, the control channel and its `EXIT` reports, spawn, HELLO, the trace |
| `worker.c` | contexts, instances and calls, the cancel word, the forced stop and the naming of a worker's end |
| `wire.c`, `udfpy_wire.h` | the framing, the wire constants, the error helpers |
| `ipc.c` | Arrow IPC writing of schemas and argument batches, and the checked reading of a worker's output |
| `udfpy.h` | the private structures |

The `trace` option appends one line per event (`spawn`, `hello`, `load`, `fork`, `exit`, `cancel_word`,
`sigkill`, `retire`, `shutdown`, `unload`, `close_instance`) to a file; it exists for tests. `cancel_word`
and `sigkill` carry the host's `now_ns` at that moment.

## Not built yet

- A time limit on a call with no cancel and no deadline, and on the zygote: a worker that stops answering
  while its socket stays open is waited for until the host cancels the call or its deadline passes, and
  `shutdown` waits for the zygote to exit. A worker whose user code closes the worker's own socket and keeps
  running is waited for until it exits, since only its `EXIT` report names its end.
- Removal of the directories under `scratch`: each generation's `zygote-XXXXXX` directory and its workers'
  `worker-*` directories stay after `shutdown`; the owner of `scratch` removes them.
