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
  the two shapes above, CPU, class MANAGED.
- `validate` is pure: it decodes the descriptor (protobuf, canonical form only), checks it against the spec
  and the types, and starts no process and opens no file.
- `load` validates, then starts a zygote when there is no current generation: `posix_spawn` of
  `<interpreter> -I -X utf8 <zygote> --control-fd 3 ...` with a scrubbed environment, a working directory under
  `scratch`, descriptor 3 the control socket. The zygote answers HELLO (the library refuses a free-threaded
  or non-CPython interpreter, or a tag that differs from `abi`), and imports the module on LOAD.
- `open_context` asks the zygote (FORK) for one worker, passing its socket end and the memfd of the cancel
  word as `SCM_RIGHTS`. Calls go to the context's worker over the socket as Arrow IPC messages. While waiting
  for a reply the library polls every 10 ms and, when the host cancels or the deadline passes, stores the
  request's id (never 0, never reused on a context) in the cancel word, which the worker reads between rows.
- Generations: a LOAD reply with the RETIRE flag (a module imported from another bundle, or threads started
  by an import) retires the generation; it is shut down when its last context closes, and a RETRY reply loads
  again in a new generation.

## Files

| File | Holds |
|---|---|
| `runtime.c` | the table, `init` and the options, `describe`, `load`, `unload`, the entries of shapes not built |
| `descriptor.c` | the descriptor decoder and `validate` |
| `zygote.c` | generations, the control channel, spawn, HELLO, the trace |
| `worker.c` | contexts, instances and calls, the cancel word |
| `wire.c`, `udfpy_wire.h` | the framing, the wire constants, the error helpers |
| `ipc.c` | Arrow IPC writing of schemas and argument batches, and the checked reading of a worker's output |
| `udfpy.h` | the private structures |

The `trace` option appends one line per event (`spawn`, `hello`, `load`, `fork`, `exit`, `cancel_word`,
`retire`, `shutdown`, `unload`, `close_instance`) to a file; it exists for tests.

## Not built yet

- Supervision of a worker or zygote that stops answering without closing its socket: the library waits on
  the socket with no time limit, and `shutdown` waits for the zygote to exit. A process that dies closes its
  socket, which the library reads as the end of that context or generation.
- Removal of the directories under `scratch`: each generation's `zygote-XXXXXX` directory and its workers'
  `worker-*` directories stay after `shutdown`; the owner of `scratch` removes them.
