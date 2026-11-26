# udf_python

`komira/python`: the UDF runtime library for Python functions. It is C11 with GNU extensions on linux (`memfd_create`, `posix_spawn_file_actions_addclosefrom_np`), built as
`libkomira_udf_python.so` (ELF) on linux and `libkomira_udf_python.dylib` (Mach-O) on macOS
([macOS](#macos)), and implements the `komira_udf_runtime` table of
[`udf_abi`](../udf_abi/). It exports one symbol, `komira_udf_runtime_init_v1`. The design is
[`docs/design/udf_python_worker.md`](../../docs/design/udf_python_worker.md); this build covers
SCALAR (VALUES and ARROW) and MAP_BATCHES_COLUMN (ARROW) over the types of [Types](#types), with the
code forms PACKAGE and BUNDLE. Linux with glibc 2.34 or later, and macOS arm64 (11.0 or later).

## What it does

What follows is the linux build; [macOS](#macos) says what differs there.

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

## macOS

The same sources, built for a macOS target as a Mach-O `libkomira_udf_python.dylib`
(`c_shared_lib(target_os = True)`, the darwin-arm64 row's `aarch64-macos.11.0`). macOS has no memfd, no
pidfd, no `SOCK_CLOEXEC`, `MSG_NOSIGNAL`, `MSG_CMSG_CLOEXEC`, closefrom spawn action or
`sigabbrev_np`, so there (design sections 2.3, 5.2 to 5.4):

- the library's sockets are made close-on-exec with `FD_CLOEXEC` and carry `SO_NOSIGPIPE`, and a descriptor
  received is made close-on-exec as it is taken;
- the zygote is spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT`, keeping 1 and 2
  (`posix_spawn_file_actions_addinherit_np`) and the 0 and 3 its actions make;
- the cancel word is a file of its own under `scratch` (`cancel-XXXXXX`, `mkostemp`, mode 0600), unlinked
  at once and sized to 8 bytes: only the library's and the worker's descriptors name it. `shm_open`, which
  the design first named, is refused in a sandboxed process;
- the FORK reply carries the worker's pid and no descriptor, and a forced stop is `kill(pid)` sent only while
  the worker's socket has not ended and no `EXIT` report names the worker. A worker that exits, is reaped and
  has its pid handed out again between that check and the `kill` is the race the design accepts;
- a worker ends with its zygote through a thread that waits on a `kqueue` `EVFILT_PROC` `NOTE_EXIT` filter for
  the zygote's pid (`python/komira/_udf/worker.py`), where linux uses `PR_SET_PDEATHSIG`;
- the zygote's thread count leaves out the threads of its dispatch workqueue
  (`proc_pidinfo(PROC_PIDWORKQUEUEINFO)`), which the kernel starts for libdispatch and a fork does not copy:
  loading `libarrow`, as `import pyarrow` does, leaves one;
- a signal is named from `sys_signame`, upper-cased (`signal 9 (SIGKILL)`).

## Files

| File | Holds |
|---|---|
| `runtime.c` | the table, `init` and the options, `describe`, `load`, `unload`, the fork handler, the entries of shapes not built |
| `descriptor.c` | the descriptor decoder and `validate` |
| `zygote.c` | generations, the control channel and its `EXIT` reports, spawn, HELLO, the trace |
| `worker.c` | contexts, instances and calls, the cancel word, the forced stop and the naming of a worker's end |
| `wire.c`, `udfpy_wire.h` | the framing, the wire constants, the error helpers |
| `types.c` | the bound Arrow types: the reading of a C Data schema into a pre-order array of type nodes, and the limits |
| `ipc.c` | Arrow IPC writing of schemas and argument batches, nested columns included |
| `ipc_read.c` | the checked reading of a worker's reply into one array per type node |
| `udfpy.h` | the private structures |

## Types

A schema is read from the bound Arrow C Data schemas into a pre-order array of type nodes (`types.c`). The
arguments are the children of one struct, each child a column; the result is one column. The runtime carries
these types; every other type is refused by `validate` with `ERR_UNSUPPORTED`.

| Arrow type | C Data format | Python value in `VALUES` | Checked on a return |
|---|---|---|---|
| `bool` | `b` | `bool` | a `bool` only |
| `int8`, `int16`, `int32`, `int64` | `c`, `s`, `i`, `l` | `int` | an `int` (not a `bool`) within the width |
| `float32`, `float64` | `f`, `g` | `float` | a `float`, or an `int` exactly representable; for `float32` the value must survive a round trip through 32 bits, and an overflow is refused |
| `string`, `large_string` | `u`, `U` | `str` | a `str` that encodes as UTF-8 (a lone surrogate is refused) |
| `binary`, `large_binary` | `z`, `Z` | `bytes` | `bytes`, `bytearray` or `memoryview`; a `str` is refused |
| `date32[day]` | `tdD` | `datetime.date` | a `date` that is not a `datetime` |
| `timestamp[s]`, `[ms]`, `[us]`, `[ns]`, with an optional time zone | `tss:`, `tsm:`, `tsu:`, `tsn:` and the zone | `datetime.datetime`, naive without a zone, aware with one | a `datetime`, naive exactly when the type has no zone; `[s]` needs a zero microsecond and `[ms]` a microsecond divisible by 1000; the value must fit 64 bits in the unit |
| `decimal128(P, S)`, 1 <= P <= 38, 0 <= S <= P | `d:P,S` (`d:P,S,128` too) | `decimal.Decimal` | a finite `Decimal` or an `int` (not a `bool`) whose value at scale S drops no nonzero digit and has at most P digits; a `float` is refused |
| `list<item: T>`, `large_list<item: T>` | `+l`, `+L`, one child | `list` | a `list` or `tuple`, each item checked against `T` |
| `struct<a: T, b: U, ...>`, one or more fields | `+s` | `dict` keyed by field name | a `dict` whose keys are exactly the field names, or a dataclass instance whose fields are exactly them |

Where a type loses something, the table of the runtime says so:

- A `datetime.datetime` holds microseconds, so a `timestamp[ns]` argument is refused for the `VALUES` batch format,
  at any depth, with `ERR_UNSUPPORTED`. A `timestamp[ns]` result is exact. The `ARROW` batch formats take
  `timestamp[ns]` unchanged.
- A `timestamp[s]` or `[ms]` argument reaches a function as a `datetime` of the same instant; a result with a finer
  fraction is refused, not rounded.
- A result `timestamp` with a time zone other than the declared one is refused in `ARROW` batches.
- A `date32` or `timestamp` argument outside the years 1 to 9999 of `datetime` is refused at call time with
  `ERR_UNSUPPORTED`, naming the row and the argument.
- An `ARROW` function's result is cast to the declared type only within its own kind: integers to integers or
  floats, floats to floats, `string` and `large_string`, `binary` and `large_binary`, timestamps of the same zone,
  decimals, and lists and structs by their children. Any other result type is refused with `ERR_RETURN_TYPE`.
- Every returned value that would change on the way into the declared type is refused with
  `ERR_RETURN_TYPE` naming the row, never rounded, truncated or wrapped.

Limits: at most 256 type nodes in one schema, nesting at most 16 deep (a column is depth 1), and names and
time zones under 64 bytes. A dictionary-encoded type is refused by name. The refusal text is `type '<format>' of
<path> is not built in komira/python yet`, where the path is the argument's name (or `the result`), followed by
`.<child name>` for each level of children.

The reader of a worker's reply treats it as untrusted. Before it forms a pointer into the payload it checks, for
the bound schema's tree:

- the node and buffer counts equal the counts the tree implies;
- each node's length: the batch's rows at the top, the struct's length for a struct child, and for a list child a
  length at least the list's last offset;
- `0 <= null_count <= length`, and every buffer lies inside the body (checked without overflow);
- a validity bitmap of at least `(length + 7) / 8` bytes when the node has nulls;
- a fixed-width values buffer of at least `length * width` bytes, aligned to the smaller of the width and 8, and
  a boolean values bitmap of at least `(length + 7) / 8` bytes;
- an offsets buffer of `length + 1` entries (a node of length 0 may send none), aligned to the offset width,
  starting at or above 0, never decreasing, and ending within the data (strings and binary) or the child (lists);
- every `string` and `large_string` value is valid UTF-8 (overlong forms, surrogates and values above U+10FFFF
  are refused).

Each node of a decoded column is its own `ArrowArray` holding a reference on the payload; releasing a node
releases its children and drops that reference. A refusal releases everything built so far.

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
