# Design: the `komira/python` runtime, zygote and workers

Status: proposed, not built. This is the build design of the `komira/python` runtime that
[the UDF runtime interface](udf_runtime_interface.md) defines through its C ABI (§4 there) and sketches in its §5
(informative). Where the two differ, this document is the one that holds for `komira/python`, and §5 of the interface
document points here. Its runtime-specific conformance cases are in
[the conformance corpus](udf_runtime_conformance.md#cases-of-the-komirapython-runtime).

Citations are to komira `main` as of 2026-11-20. Section numbers without a file name are this document's; `IF §x` is
`udf_runtime_interface.md`; as in the interface document, `§7.x` is `optimized_plan.md`, `§10.1` to `§10.9` are
`optimized_plan_udfs.md`, and `§10.10` to `§10.14` are `optimized_plan_udf_runtime.md`. Statements marked *(inferred)* are a reading, not a fact taken from the code.

It replaces an in-process trampoline, in which engine threads would call Python callables through
`ctypes.CFUNCTYPE` pointers and take the user's interpreter lock once per batch. That shape is not used: Python
UDFs run in worker processes forked from a zygote, the one Python mode (`AGENTS.md` B21; IF §1.2).

---

## 1. What is built, and the order

The runtime has two halves, joined by a protocol private to them (IF §8.1, last row):

| Half | Language | Where it runs | Where it lives |
|---|---|---|---|
| The runtime library, `libkomira_udf_python` | C, no Mojo | Inside the engine's process, loaded through `komira_udf_runtime_init_v1` like any runtime (IF §4.1) | `src/udf_python/` |
| The zygote and its workers | Python | Separate processes the library starts | `python/komira/_udf/` in the `komira` wheel |

Both halves ship in the `komira` wheel, beside `libkomira` (§7). Nothing in the engine, the plan or the C ABI names
them, and a change to either never changes those.

**Why the library is C.** It is a process, socket and Arrow-buffer manager with no Python in it. Written in C it needs
no Mojo runtime, so loading it beside `libkomira` does not raise the open question of two Mojo libraries in one
process (IF §1.3 item 1), and any host can load it. The prototypes that informed the interface were written the same
way, and the library starts from them (§8). It is standalone: it does not wait for the shared worker library of IF §9
stage S3, which a second managed runtime may later factor out of it.

**Build order.** Each stage lands with its tests welded. `describe` reports only the shapes built so far, so a plan
that needs a later one is refused by name (`OPTIMIZED_UDF_KIND_UNSUPPORTED`, IF §4.2):

| Stage | What lands | Done when (cases of the conformance corpus) |
|---|---|---|
| P0 | The ABI headers leave the test tree: `komira_udf_runtime.h` and `komira_udf_wire.h` move from `src/tests/helpers/komira_udf_spike_abi/` to `src/udf_abi/`, with the Mojo mirror and the harness (IF §9 S1-S2); the header gains the runtime options and `ERR_BAD_OPTION` (§2.2) | The prototype's welded tests pass against the moved headers |
| P1 | The library and the zygote: spawn, `HELLO`, `LOAD`, `FORK`, one worker per context, `SCALAR` and `MAP_BATCHES_COLUMN` with the `VALUES` and `ARROW` batch formats, `ERR_RAISED` with the user's trace, `validate` over the descriptor | Z1-Z15 and Z17-Z18: a UDF runs in a process whose pid is neither the engine's nor the zygote's, with correct rows |
| P2 | Supervision: exit reports, cancel, deadlines, forced stops, crash attribution, the ends of the zygote and the engine (§5) | S1-S13: an aborting UDF gives `UDF_WORKER_CRASHED` naming the signal and the session survives; `describe` reports `CONTAINS_CRASHES` and `FORCED_STOP` |
| P3 | `ROW` with the row proxy and the read set; frames, `STEP`, plain and mergeable aggregates; the nested-call rule (IF §4.3) | Z16, and the shared corpus with Python fixtures |
| P4 | The `PANDAS`, `NUMPY` and `POLARS` batch formats. The types beyond numerics (strings, binary, bool, dates, timestamps, decimals, lists, structs) have landed: see the "Types" section of `src/udf_python/README.md` | Each of the three formats round-trips every type of that table |
| Later | Shared-memory slot heaps for payloads (§4.4) | A measurement shows the socket copy matters |

The lowering of the UDF plan nodes and the Python `@udf` decorator are not part of this runtime; they use it through
the C ABI (§10).

## 2. The processes

```text
user's Python process (or a host's engine process)
  libkomira (engine threads)
    libkomira_udf_python  ── control socket ──  zygote (python -I -X utf8 .../komira/_udf/zygote.py)
          │                                       │ fork, one per context
          └──────── worker socket + cancel word ─ worker 1 .. worker N
```

- **The library** is loaded once per process, by the engine, from the path the session gives it (§7). Its `init`
  starts nothing.
- **The zygote** is one process per runtime handle and generation (§3.3): a Python interpreter running
  `komira/_udf/zygote.py`. It imports user code at `load`, so loaded modules and unpickled values are shared
  copy-on-write by every worker it forks, and it is the parent of every worker. It never runs a UDF call.
- **A worker** is one process per context (IF §3.3): a fork of the zygote that serves one engine thread's calls. It
  speaks to the library directly over its own socket; nothing it sends passes through the zygote.

### 2.1 The interpreter is an executable, never embedded

The zygote is started from a Python interpreter **executable**, with `-I` (isolated mode: no `PYTHON*` variables, no
user site directory, no script directory on `sys.path`) and `-X utf8` (UTF-8 for every text stream and file name,
whatever the locale):

- **Locally** (the pip package), that executable is the user's own interpreter, `sys.executable` of the process
  that created the session, so the workers import from the same environment the producer captured from. `-I` keeps
  the interpreter's own `site-packages`, a virtual environment's included.
- **On a host** (an environment image), it is `/opt/env/komira/python/bin/python3` (IF §6.1 item 4).

The interface's earlier sketch had the worker embed CPython and load `libpython` with `RTLD_GLOBAL` (IF §5.3, first
bullet). That is replaced: a CPython may have no shared `libpython` at all (a statically linked interpreter), and an
executable gives extension modules the `Py*` symbols the way they expect. There is still one mode: workers forked
from a zygote.

The library never calls the interpreter of the process it is loaded in, takes no interpreter lock and imports no
Python. So in the pip package, an engine thread running a UDF never waits on the user's interpreter, and the user's
interpreter never waits on a UDF.

### 2.2 What the library is told: runtime options

The library needs facts the engine does not have: which interpreter to start, which `sys.path`, which scratch
directory. They reach it as **runtime options**, a list of `key=value` strings the engine is given for this runtime
and passes through unread. They are flags, not environment variables (`AGENTS.md` S2). Locally the session gives
them (§7); on a host, the base release's runtime registry record carries them beside the library's path (IF §8.3).
ABI 1.0 adds them to `komira_udf_host`, which is per `init` call, after its last field:

```c
typedef struct komira_udf_host {
  /* ... the ABI 1.0 fields of IF §4.3, unchanged ... */
  size_t             n_options;      /* runtime options; opaque to the engine */
  const char* const* options;        /* UTF-8 "key=value"; borrowed for the init call */
} komira_udf_host;
```

The header has not shipped (it is test-only today, §8), so this is part of 1.0. A host whose `struct_size` does not
cover the two fields passes no options (IF §8.1 step 4). `init` refuses an option key it does not know, a required
key that is missing, and a value it cannot parse, with a new status, `KOMIRA_UDF_ERR_BAD_OPTION = 21`, whose run error
is `UDF_RUNTIME_OPTION_INVALID`, naming the runtime and the key. A misspelt option fails at `init`, never later.

| Option | Required | Meaning |
|---|---|---|
| `interpreter` | yes | Absolute path of the interpreter executable (§2.1) |
| `zygote` | yes | Absolute path of `komira/_udf/zygote.py` |
| `abi` | yes | The CPython tag the session expects, `cp` and the digits of the producer's `sys.implementation.cache_tag` (`cpython-313` gives `cp313`); `describe` reports it as `runtime_abi` |
| `sys_path` | no, repeated | One `sys.path` entry each, in order. The zygote's `sys.path` is the interpreter's isolated default followed by these. Locally the SDK passes the producer's `sys.path` entries that are directories outside the standard library, so a `PACKAGE` found by the producer is found by the zygote |
| `scratch` | yes | An existing directory the runtime may write; it holds the zygote's and each worker's working directory, `HOME` and `TMPDIR` (§2.4) |
| `grace_ms` | no | The grace period of a forced stop (IF §4.7); default 2000 |
| `trace` | no | Test only: a file to which the library appends one line per control event (§4.1). No production caller sets it |

`describe` stays cheap and pure, because the ABI tag is an option, not a question to the interpreter. The zygote checks
it at `HELLO` (§3.1).

### 2.3 Starting the zygote

The zygote starts at the first `load`, not at `init`: a session that never calls a Python UDF starts no process.
The library starts it with `posix_spawn`, never `fork`, because the engine is multi-threaded (IF §5.2):

- **Arguments:** `<interpreter> -I -X utf8 <zygote> --control-fd 3 --wire-version 3 [--sys-path <entry>]...`. The
  script is run by path, so it needs nothing on `sys.path` to start; it puts the `--sys-path` entries on `sys.path`
  before it imports anything else, `komira` included.
- **Descriptors:** a socket pair (`SOCK_STREAM`), the zygote's end placed at fd 3; stdin opened on `/dev/null`, so
  that user code cannot read the user's terminal; stdout and stderr inherited (locally the user's terminal; on a host
  the run log, §10.10's "Standard error goes to the run log"). No other descriptor of the engine's process reaches
  the zygote. On macOS the spawn sets `POSIX_SPAWN_CLOEXEC_DEFAULT` and keeps 1 and 2 with
  `posix_spawn_file_actions_addinherit_np`; on Linux it adds `posix_spawn_file_actions_addclosefrom_np(…, 4)`
  (glibc 2.34, which the wheel's `manylinux_2_34` floor guarantees *(inferred from the planned wheel tags)*). The
  library's own descriptors are created close-on-exec (`SOCK_CLOEXEC` on Linux; on macOS, which lacks it,
  `FD_CLOEXEC` at once, and the spawn flag covers the window).
- **Process group:** the zygote gets its own process group (`POSIX_SPAWN_SETPGROUP`), so a terminal's Ctrl-C, which
  the terminal sends to the user's foreground group, reaches the user's Python and never kills a worker in the middle
  of a call. A run is cancelled through the cancel flag (§5.2), never by a signal from the terminal.
- **Signals:** an empty mask (`POSIX_SPAWN_SETSIGMASK`) and every signal at its default disposition
  (`POSIX_SPAWN_SETSIGDEF` with a full set), so a signal the user's process ignores is not ignored by the zygote, as
  the prototype did (`src/tests/helpers/komira_udf_spike_node_worker/proxy/channel.c:479-492`).
- **No signal handler in the engine's process.** The library installs none and never changes `SIGCHLD`: the
  engine's process may be the user's Python, which owns its handlers. It waits for the zygote by its pid only
  (`waitpid(pid)`, after a pidfd on Linux or `EVFILT_PROC` on macOS reports the exit), never `waitpid(-1)`. If
  something else in the process reaps the zygote first (`ECHILD`), the zygote is lost with an unknown status.
- **Writes** never raise `SIGPIPE`: `MSG_NOSIGNAL` on Linux, `SO_NOSIGPIPE` on the socket on macOS.
- **A fork of the engine's process** (user code that forks the user's Python, as `multiprocessing`'s `fork` start
  method does) must not keep the runtime's sockets open in the child, or the zygote would never see end of file. The
  library registers a `pthread_atfork` child handler that closes every descriptor it owns and marks the runtime
  lost in the child: there, every entry returns `ERR_INSTANCE_LOST`. The parent is unaffected.

### 2.4 What user code sees

User code runs with the same environment on a laptop and on a host, as §10.10's local run requires ("an empty
working directory and only the environment variables a host provides"). The zygote is spawned with exactly this
environment, and nothing of the engine's; each worker, right after its fork, sets its own `HOME` and `TMPDIR` and
resets `tempfile.tempdir`:

| Variable | Value | Why |
|---|---|---|
| `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`, `VECLIB_MAXIMUM_THREADS`, `NUMEXPR_NUM_THREADS` | `1` | Each worker runs one thread of numerical code (§4.3); the libraries read these when they load |
| `JE_ARROW_MALLOC_CONF` | `background_thread:false` | pyarrow's bundled jemalloc otherwise starts a background thread (`jemalloc_bg_thd`), which fails the zygote's thread check (§3.2) for any module that imports pyarrow |
| `LC_ALL` | `C` | One locale everywhere; `-X utf8` gives Python UTF-8 text under it |
| `TZ` | `UTC` | One time zone everywhere |
| `HOME`, `TMPDIR` | In the zygote, a directory of its own under `scratch`; in each worker, one of the worker's own | A library that writes a cache writes it there, not into the user's home |
| `PATH` | `/usr/bin:/bin` | A UDF that runs a system tool finds one |

These variables are what the runtime sets for third-party libraries in the processes it starts; the runtime itself
reads none of them. The working directory of the zygote and of each worker is an empty directory under `scratch`.
Credentials are not passed; a UDF that needs one receives it as a secret through the plan (§10.6), never from the
engine's environment.

## 3. The zygote

### 3.1 Lifecycle

The zygote runs one loop: `select` over its control socket and a wake descriptor that `signal.set_wakeup_fd` fills
on `SIGCHLD`. It installs no other handler.

1. **`HELLO`.** The library sends the wire version and the options. The zygote answers with its pid,
   `sys.implementation.name` and `cache_tag`, `importlib.util.MAGIC_NUMBER` and whether the interpreter is a
   free-threaded build (`sysconfig.get_config_var("Py_GIL_DISABLED")`). The library converts the tag as the `abi`
   option is converted (§2.2).
   - An implementation other than CPython, or a free-threaded build, fails the `load` that started the zygote with
     `ERR_UNSUPPORTED` (`OPTIMIZED_UDF_UNSUPPORTED`: "a free-threaded CPython is not a Python UDF mode", `AGENTS.md`
     B21). The SDK refuses the same interpreters earlier, on the user's machine.
   - A tag other than the `abi` option fails it with `ERR_ABI` (`UDF_RUNTIME_ABI_MISMATCH`, naming both tags).
   - An interpreter that cannot be started, or a zygote that exits before `HELLO`, fails it with `ERR_LOAD`
     (`OPTIMIZED_UDF_CODE_UNLOADABLE`), naming the interpreter path and the exit status.
2. **`LOAD`** (from the runtime's `load`, IF §4.3 item 4). The zygote verifies each code object's sha256
   (`ERR_CODE_DIGEST`), imports the `PACKAGE` or `BUNDLE` module or unpickles the `VALUE`, loads the data blobs,
   checks the function against the descriptor (`ERR_LOAD` on a disagreement, §6), checks its thread count (§3.2),
   and keeps the function under the library's UDF id. A `BUNDLE`'s directory under `code_root` is put on `sys.path`
   once.
3. **`FORK`** (from `open_context`). The library sends one end of a new socket pair and the cancel word (§5.2) with
   `SCM_RIGHTS`; the zygote checks that it is single-threaded (§3.2), forks, and answers with the worker's pid and,
   on Linux, a pidfd it opened for the child before answering (`pidfd_open` on its own unreaped child), sent with
   `SCM_RIGHTS`. The worker closes the zygote's control socket and the wake descriptor; the zygote closes its copies
   of the worker's descriptors.
4. **`EXIT`**, unsolicited: when a worker exits, the zygote reaps it and reports its context id, pid, and exit status
   or signal.
5. **`UNLOAD`** forgets a UDF id; **`SHUTDOWN`** (from the runtime's `shutdown`) ends the zygote after its workers.
   At end of file on its control socket, the zygote sends `SIGKILL` to every worker it has and exits; this is how it
   ends when the engine's process dies.

**The library side of the control socket.** The library reads the control socket only while it holds the zygote
lock, and records every `EXIT` it reads in the context it names, whichever thread read it. The lock is held around
`load`, `open_context`, `close_context`, `unload` and the wait for an `EXIT` report (§5.1), never around a call: calls
go to workers directly, so the rule that no engine thread waits on another engine thread's UDF call (IF §1.2) holds.
Loads run at §7.2 step 9, before any data of the run is read, so within one run a load never delays a call; a crash
report of one run can wait for another run's load in the same process to finish.

### 3.2 Single-threaded at every fork

`fork` copies only the calling thread, so a zygote with a second thread could hand a worker a lock that no thread will
ever release. The zygote therefore counts its own operating-system threads, not only Python's, after every import and
unpickle at `LOAD`, and again before every `FORK`: on Linux, the `Threads:` line of `/proc/self/status`; on macOS,
`pti_threadnum` of `proc_pidinfo(PROC_PIDTASKINFO)` less `pwq_nthreads` of `proc_pidinfo(PROC_PIDWORKQUEUEINFO)`.
Those are the threads of the process's dispatch workqueue, which the kernel starts for libdispatch and a fork does
not copy. Loading some libraries starts one: loading `libarrow`, as `import pyarrow` does, leaves one in the
zygote, so counting them would refuse every UDF that imports pyarrow on macOS.

- A `LOAD` after which the count is above 1 fails with `ERR_LOAD` (`OPTIMIZED_UDF_CODE_UNLOADABLE`), naming the
  module or value whose loading started the thread and the count: "importing `mylib` started 3 threads; Python UDFs
  run in workers forked from a single-threaded process". The thread cannot be stopped, so that zygote generation is
  retired (§3.3): it forks no more workers, and the next `load` starts a new generation. The thread-pool variables
  (§2.4) keep the common numerical libraries from starting their pools at import.
- A count above 1 before a `FORK` that no `LOAD` reported is a runtime defect: `open_context` returns `ERR_INTERNAL`.

No fallback starts workers another way: one mode per language (IF §1.2).

### 3.3 Generations

A Python module name can be imported once per interpreter. When a `LOAD` needs a module name the zygote has already
imported from different bytes (a notebook user edits a project module, so its `BUNDLE` digest changes), the library
starts a new zygote, a new *generation*, and loads into it. A generation is also retired after a thread check fails
(§3.2) and when its zygote ends (§5.4). Contexts forked from a retired generation keep running; its zygote is shut
down once its last context closes, or at once when it has none. A `PACKAGE` reference names an installed, non-editable distribution (IF §3.1,
*Code forms*), so its bytes do not change within a session.

### 3.4 State does not outlive a context

A worker is a fork; a UDF that assigns to a module global changes its own worker's copy (§10.10's first remaining
difference). Contexts are closed at the end of each run (IF §4.3 item 8), so the next run forks fresh workers from the
zygote, and no global a UDF wrote in one run is seen by the next.

## 4. A worker

### 4.1 The protocol

The worker protocol is the prototype's `komira_udf_wire.h`, raised to wire version 3 for the zygote messages; it
stays private to one build, and `HELLO` refuses any other version (IF §8.1). Each message is the 40-byte header
followed, at first, by an inline payload (`KOMIRA_UDF_WIRE_INLINE`); the shared-memory `slot` and `payload_offset`
fields stay reserved for §4.4.

| Channel | Requests | Replies |
|---|---|---|
| Control (library to zygote) | `HELLO`, `LOAD`, `UNLOAD`, `FORK`, `SHUTDOWN` | `OK`, `ERROR`, and the unsolicited `EXIT` |
| Worker (library to one worker) | The ops of `komira_udf_wire.h`, one per table entry (`OPEN_INSTANCE` … `AGG_CLOSE`), plus `FRAME_IN` | `OK`, `ERROR` |

New op numbers: `FORK` 30, `EXIT` 130. `OPEN_CONTEXT` and `CLOSE_CONTEXT` of the prototype become `FORK` and the
closing of the worker socket; the prototype's `CANCEL` op is not used, because cancel is the cancel word (§5.2).

With the `trace` option set, the library appends one line per control event to that file: each `HELLO` answer (the
zygote's pid, tag and thread state), each `LOAD` result with the zygote's thread count, each `FORK` with the worker's
pid, each `EXIT`, each cancel or deadline the library stores in a cancel word (with the call id and `now_ns`), each `SIGKILL` the library
sends, and each generation started, retired or shut down. It is how the cases see
what the C ABI does not show (IF §6.3, the analogue of echo's test-only settings).

Payloads are Arrow IPC encapsulated messages with 64-byte aligned bodies, after the prototype's 64-byte request head
(`kudfw.h:1-50`): schemas once, at `LOAD` (`args`, `result`, `state`), and one record batch per call. The worker
decodes them with `pyarrow.ipc.read_record_batch` against the schema it bound at `LOAD` and encodes its result
with `pyarrow`, which the SDK depends on. The library encodes `args` in C and decodes results in C, then validates the
layout against the bound schema before it hands the array to the engine (IF §4.4); the prototype's encoder and
validating decoder (`proxy/ipc.c`) carried 64-bit integers, 32-bit integers and doubles; `src/udf_python` now carries the types of its
README's "Types" section, nested columns included, and the `PANDAS`, `NUMPY` and `POLARS` formats are still to land (P4).

### 4.2 Calls

- **`SCALAR` with `VALUES`:** the worker converts each argument column to Python values, calls the function once
  per row inside a loop of its own, checks the cancel word between rows (§5.2), and builds the result column. An
  `async` function is awaited in the worker's own event loop, with at most `max_concurrent_calls` in flight.
- **`MAP_BATCHES_COLUMN` and `SCALAR` with `ARROW`:** the function receives `pyarrow` arrays and returns one.
- **`ROW` (P3):** the row proxy over the `args` children only, which records a read outside the read set even when
  user code catches the exception (IF §4.3 item 7); who supplies the read set and what fails outside it is §6.1.
- **`MAP_BATCHES_FRAME` (P3):** the batches hold only the read set's columns; a lookup of another column is mapped to
  `ERR_FIELD_NOT_DECLARED` as §6.1 says.
- **Errors:** every exception user code raises, `BaseException` included (`KeyboardInterrupt`, `SystemExit` from
  `sys.exit()`), is caught at the call and answered as `ERR_RAISED`, with the row when the loop knows it and the
  traceback trimmed to the user's frames (`user_trace`, mapped to the user's file and line). A `SystemExit` never ends
  the worker. A `MemoryError` is answered as `ERR_OUT_OF_MEMORY`, after which the worker exits (IF §4.5: the context is
  lost).
- **Output:** the worker casts what user code returned to the bound result type, refusing a lossy cast with
  `ERR_RETURN_TYPE`, and checks the length (`ERR_LENGTH`); the host checks both again (IF §4.6). The cast of an `ARROW` result stays within its own kind, as the README's "Types" section lists.

### 4.3 Threads in a worker

Each worker runs user code on its main thread. Numerical libraries keep one thread each (§2.4), and the worker sets
`pyarrow.set_cpu_count(1)` after the fork. A worker is a context, and the engine opens one context per engine thread
(IF §3.3), so N workers use N cores. This settles the interface's two statements (one thread at the zygote, IF §5.2;
each context's share of the CPUs, §10.10): at the first release a context's share is one thread. A worker may start
threads of its own after the fork (§5.4 uses one on macOS); the single-thread rule is the zygote's.

### 4.4 Copies, and the later slot heaps

At the first stages every payload travels inline on the worker's socket:

- **Into the worker:** the library encodes `args` into the socket; the worker reads into a buffer of its own and
  decodes in place. The library releases `args` when the call returns, since the worker holds its own copy; a view
  user code keeps is of that copy.
- **Out of the worker:** the library reads the reply into a 64-byte aligned buffer it allocates, so the buffers it
  returns are ones no other process can write (IF §4.4, the `out` rule) with no extra copy. Their release is an
  atomic reference count that frees the buffer; no interpreter is involved, so release is safe on any engine thread
  at any time (IF §4.4).

The interface's shared-memory slot heaps (IF §5.2, *Channels*) remove the copy into the worker. They are a later
stage, because the protocol is private (IF §8.1) and nothing outside the runtime changes when they land. Their region
would be passed at `FORK` beside the cancel word, made the same way (§5.2).

### 4.5 Frames and nested calls

A frame's user code is a generator over an input iterator (P3). When the generator needs input, the iterator answers
the pending `FRAME_OUT` with "needs input" and then **re-enters the worker's dispatcher**: it reads the next
message; a `FRAME_IN` for its frame returns the batch to the generator, and any other request, a nested call the host
makes to produce that input (IF §4.3), is served on the spot, recursively. So nested calls complete before the pull
returns, with no second thread and no event loop, and a frame over a frame over a scalar is two levels of the same
recursion.

## 5. Supervision

### 5.1 Who sees an exit

A worker is the zygote's child, not the engine's, so only the zygote can reap it and read its status. The library
learns of a worker's end in two ways, and uses both:

- **End of file on the worker's socket**, at once, on the engine thread that is waiting on it.
- **The zygote's `EXIT` report**, which names the status. Before it returns the status of a call whose worker's
  socket ended, or any status after which the worker exits (`ERR_OUT_OF_MEMORY`), the library waits, under the zygote lock, for that context's `EXIT` report; the wait also ends when
  the zygote's control socket ends, and the call then names the zygote's end instead (§5.4).

`src/supervisor` is not used for workers: it watches only its own children and is a Mojo package, and the library is
C with no Mojo runtime (§1). Its exit decoding (`ExitInfo`, `src/supervisor/supervisor.mojo:464-485`) is the model the
zygote's report follows: an exit status 0-255, or a signal number.

### 5.2 Cancel and deadlines: the cancel word

Each context has a **cancel word**: 8 bytes of memory shared by the library and the worker, made at `open_context`
(`memfd_create` on Linux; on macOS, which has no memfd, a file of its own under the `scratch` option made with
`mkostemp`, unlinked at once, then `ftruncate`; not `shm_open`, which a sandboxed process is refused) and passed to
the worker at `FORK`. It holds the id of the call to cancel, as
the prototype's did (`kudfw.h:38-41`):

- Every call carries its `call_id` in the request head. While the library waits on the worker's socket, it reads the
  call's cancel flag and compares `host->now_ns` with its deadline at a fixed tick (a poll timeout, a host-local
  default); when either fires it stores that call's id in the word with a release store.
- The worker reads the word between rows of a `VALUES` loop and between batches of a frame, and acts only when the
  word equals the id of the call it is running. It then answers `ERR_CANCELLED` or `ERR_DEADLINE`, and the context
  stays usable (IF §4.7).
- A word written for a call that has already returned names an id the worker is no longer running, so it can never
  cancel the next call, which IF §4.7 requires.

A test drives this without a real clock: it sets the cancel flag, or advances the injected `now_ns`, and waits for the
call's status; the tick bounds how soon the library notices, and no case asserts it.

### 5.3 Forced stops

If the worker has not answered `grace_ms` (by `now_ns`) after the library stored the call's id in the cancel word, the library stops it by
force: it records in the context that it is sending the signal, then sends `SIGKILL`. On Linux it sends it through
the worker's pidfd (`pidfd_send_signal`), which can never reach another process. On macOS, which has no pidfd, it
sends `kill(pid)` only while the worker's socket is still open. The worker can still exit, be reaped by the zygote and
have its pid given to a new process between that check and the `kill`; macOS hands out pids in increasing order, so
that needs the pid space to wrap within the window, and the race is accepted. A call waiting on its `in` pull is never stopped by force (IF §4.3).

| What ended the worker | Status of the call in progress | Run error |
|---|---|---|
| The `SIGKILL` the library recorded and sent | `ERR_KILLED` | The run's cancel, or `UDF_DEADLINE_EXCEEDED` (IF §4.5) |
| Any other signal, `SIGKILL` from anywhere else included (the kernel's out-of-memory killer cannot be told apart, IF §4.5) | `ERR_WORKER_CRASHED`, naming the signal | `UDF_WORKER_CRASHED` |
| An exit the worker did not report first, status 0 included | `ERR_WORKER_CRASHED`, naming the status | `UDF_WORKER_CRASHED` |
| A `MemoryError` the worker reported, then its exit | `ERR_OUT_OF_MEMORY` | `UDF_OUT_OF_MEMORY` |
| Any end while no call was in progress (before it sends a request, the library polls the worker's socket for a hang-up) | The next call returns `ERR_INSTANCE_LOST`, naming the signal or status; no user code runs | `UDF_WORKER_CRASHED` |

After any of these the context is lost: a later call on it returns `ERR_INSTANCE_LOST` without running user code,
and closing it succeeds (IF §4.5). Nothing is retried.

No per-process memory cap is set at the first release: `RLIMIT_AS` breaks allocators that reserve address space,
and a cap is optional (IF §4.8). `worker_mem_bytes` alone sizes the pool, and the library does not report
`MEMORY_REPORT`; memory is one setting, and a cap per worker would be a second one (§9).

### 5.4 When the zygote or the engine ends

- **The zygote ends** while contexts are open: its generation is retired and every context of it is lost. On Linux
  each worker set `PR_SET_PDEATHSIG(SIGKILL)` after the fork and then checked `getppid()` against the zygote's pid,
  so it ends with the zygote (the zygote is single-threaded, so the parent thread is the parent process). On macOS,
  which has no such call, each worker starts one thread after the fork that waits on a `kqueue` `EVFILT_PROC`
  `NOTE_EXIT` for the zygote's pid and ends the worker with `os._exit`; it checks `getppid()` once the filter is
  registered, and treats a registration that fails with `ESRCH` as a zygote already gone. Calls in progress return
  `ERR_WORKER_CRASHED` naming the zygote's exit; the next `load` starts a new generation.
- **The engine's process ends** (the user's Python is killed): the sockets close, the zygote sees end of file, sends
  `SIGKILL` to its workers and exits, and the workers would follow the zygote anyway (above). An idle worker also
  exits at end of file on its own socket. No process of the runtime outlives the engine's process once the zygote has
  seen the end of file; a zygote busy in a `LOAD` sees it when the import returns.
- **The zygote is never `PR_SET_PDEATHSIG`'s target.** That signal follows the thread that started the process, and
  engine threads come and go.

## 6. The descriptor and `validate`

The `komira/python` descriptor (IF §3.1, *Descriptor rules*) is a new protobuf message,
`komira.udf.python.v1.PythonDescriptor`, in `src/plan_proto/udf_python_descriptor.proto`, which imports `WireField`
and `RecordedFields` from `plan.proto` (`plan.proto:238`) and copies neither. `descriptor_version` 1 is this message;
it is readable forever (IF §8.2), so it changes only additively (`AGENTS.md` B8).

```proto
message PythonDescriptor {
  string             entry           = 1;  // equals UdfCode.entry: "pkg.mod:qualname"
  uint32             shapes          = 2;  // the shapes the entry supports, as KOMIRA_UDF_SHAPE_* bits (IF §4.2)
  repeated WireField arg_types       = 3;  // SCALAR, MAP_BATCHES_COLUMN, AGGREGATE, STEP: the argument types captured;
                                           // empty for ROW and MAP_BATCHES_FRAME, whose columns are recorded_fields
  WireField          return_type     = 4;
  WireField          state_type      = 5;  // mergeable AGGREGATE only
  RecordedFields     recorded_fields = 6;  // ROW and MAP_BATCHES_FRAME only, always set: fields + key_fields = the read set
  BatchFormat        batch_format    = 7;  // required: UNSPECIFIED is refused
  string             serializer      = 8;  // VALUE only: "cloudpickle/<version>"
  string             python_abi      = 9;  // VALUE only: the tag the payload needs, "cp313"
  bool               is_async        = 10;
  string             distribution    = 11; // PACKAGE only: "<name>==<version>"
}
enum BatchFormat { BATCH_FORMAT_UNSPECIFIED = 0; VALUES = 1; ARROW = 2; PANDAS = 3; NUMPY = 4; POLARS = 5; }
```

**`validate` runs in the library, in C,** with a decoder of this one message, as the prototype's descriptor decoder
does (`src/tests/helpers/komira_udf_spike_abi/native/spike_descriptor.c`). It starts no process and imports
nothing (IF §4.3 item 3), so admission works before any zygote exists. It refuses, each naming the field and both
values:

- with `ERR_DESCRIPTOR`: a `descriptor_version` other than 1; bytes that are not canonical (fields in number order,
  no unknown field, no field equal to its default except `recorded_fields`, which is emitted whenever it is set); a `ROW` or
  `MAP_BATCHES_FRAME` entry whose `recorded_fields` is absent; an
  `entry` other than `UdfCode.entry`; a spec shape outside `shapes`; for `SCALAR`, `MAP_BATCHES_COLUMN`, `AGGREGATE` and
  `STEP`, a descriptor `arg_types` that differs from the `UdfRef`'s `arg_types` (the spec's `args`), and a
  `recorded_fields` that is set; for `ROW` and `MAP_BATCHES_FRAME`, a descriptor `arg_types` that is not empty, and a
  recorded field whose type differs from the `UdfRef.arg_types` entry of the same name; a `return_type` or
  `state_type` that differs from the spec's; a `RecordedFields` whose lists are not ascending by UTF-8 bytes, repeat a name, or
  share one; `BATCH_FORMAT_UNSPECIFIED`, or a batch format not built yet; and a `serializer`, `python_abi` or
  `distribution` set on a form that does not use it;
- with `ERR_READ_SET_MISMATCH`: a `ROW` or `MAP_BATCHES_FRAME` whose `UdfRef.arg_types` names (which plan validation
  holds equal to its `read_set`) differ, as a sorted set, from the union of the descriptor's `recorded_fields.fields`
  and `recorded_fields.key_fields`. The names are always compared, because the plan always carries a read set on
  these two kinds (§6.1);
- with `ERR_UNSUPPORTED`: a `VALUE` whose `python_abi` differs from the `abi` option, because a pickled code object
  belongs to its interpreter's minor (IF §3.1, *The runtime's ABI tag*); the zygote's own tag is checked against the
  same option at `HELLO` (§3.1).

**`load` runs in the zygote** and checks that the imported function agrees with the descriptor: its qualified name,
its parameters, and its type hints where it has them (`ERR_LOAD` otherwise).

### 6.1 The read set: whose duty is what

`UdfRef.read_set` (`UdfReadSet`, IF §3.1) is required on `ROW` and on `MAP_BATCHES_FRAME`, grouped or not. It may be
set and empty (the function reads no column); unset is refused. It stays refused on every other kind
(`OPTIMIZED_UDF_READ_SET_KIND`), because `SCALAR`, `MAP_BATCHES_COLUMN` and `AGGREGATE` carry their columns as their
arguments (`arg_types`) and a `STEP` has no input. So every kind that receives rows or a frame carries an explicit
list, and for these two kinds the `UdfRef`'s `arg_types` equals its read set's names in order. Where each list
lives:

| Place | `ROW` | `MAP_BATCHES_FRAME` |
|---|---|---|
| `UdfRef.read_set` (the plan) | The fields the function reads | The columns the function receives, a grouped frame's `group_by` columns included |
| `UdfRef.arg_types` (the plan) | The same names, same order, with their types | The same |
| Descriptor `arg_types` | Empty | Empty |
| Descriptor `recorded_fields.fields` | The read set as capture found it (`columns=`, annotation or scan) | The read set as capture found it (`columns=` or annotation) |
| Descriptor `recorded_fields.key_fields` | Empty | The `group_by` columns capture added because `fields` lacks them |

`fields` and `key_fields` are disjoint, and their union is the read set. Each part has a duty:

- **The producer supplies it.** `ROW`: `columns=[...]`, else an annotation of the row parameter (`TypedDict`,
  dataclass), else the SDK's static scan of the function's bytecode for attribute and subscript reads on the row
  parameter. `MAP_BATCHES_FRAME`: `columns=[...]` or an annotation of the frame parameter (`TypedDict`,
  dataclass), and nothing else: there is no default and no static scan for frames. The SDK adds a grouped frame's
  `group_by` columns to the declared set (recorded in `key_fields` when the declaration lacks them), and the read set
  contains them (`OPTIMIZED_UDF_READ_SET_GROUP_KEY`). A user whose function really uses the whole input lists it
  (`columns=list(df.columns)`).
- **Capture refuses** a `ROW` function whose reads neither `columns=` nor an annotation bounds and the scan cannot
  bound, and a frame function with neither `columns=` nor an annotation, with `UDF_READ_SET_REQUIRED` naming the
  function and the argument to give, `columns=[...]`. For either kind the SDK never lists every input column as a
  stand-in.
- **Admission refuses** a `ROW` or `MAP_BATCHES_FRAME` `UdfRef` whose `read_set` is unset, with
  `OPTIMIZED_UDF_READ_SET_REQUIRED` naming the UDF's index.
- **The engine passes only those columns:** only they stay live, down to the scan, and a frame node needs from its
  child only the read set.
- **A read outside the set fails loudly.** The `ROW` proxy answers `ERR_FIELD_NOT_DECLARED`, naming the field and the
  read set, even when user code catches the exception. In a frame the batches hold only the read set's columns, and
  the worker maps the batch format's column-lookup error for a name outside the read set (`KeyError` from pandas and
  pyarrow, polars' `ColumnNotFoundError`) to `ERR_FIELD_NOT_DECLARED` naming the column and the read set. A lookup
  error the worker cannot recognise is raised by the data library and answered as `ERR_RAISED` with the read set in
  the message.
- **The descriptor records it** (§6): `recorded_fields` is always written for these two kinds.

## 7. Packaging and the local run

**In the wheel** *(the layout itself belongs to the wheel design; these are the names this runtime needs)*:

- `komira/_lib/libkomira_udf_python.so` (`.dylib` on macOS), beside `libkomira`; it links only the C library and
  needs no Mojo runtime.
- `komira/_udf/zygote.py`, `worker.py`, `wire.py`, `formats.py` and `rows.py`: the zygote, the worker loop, the
  wire codec, the batch formats and the row proxy.
- `cloudpickle` and `pyarrow` are dependencies of the wheel; the worker uses the ones of the user's environment,
  because the zygote runs the user's interpreter (§2.1).

**The local run.** The engine runs inside the user's Python, and there is no environment image:

- The session registers the runtime with the engine: the library's path and its options (§2.2). The symbol that does
  this is part of `libkomira`'s session ABI, which its own design owns; this runtime needs only that the path and
  the options reach `komira_udf_runtime_init_v1` unchanged.
- **`code_root`** is a directory the session creates under its scratch directory and removes at close. The SDK writes
  each captured code object there, named by its hex sha256, as it would into `/komira-code/` (IF §6.1 item 4).
- **Admission** runs the host checks that do not need an image: code present (§10.11 check 4, against `code_root`:
  `OPTIMIZED_ENV_CODE_MISSING`), descriptors valid and shapes supported (check 7), and the load check. The image
  checks (1-3, 5, 6) have no image to read and are not run; a remote run runs them all.
- **`PACKAGE` references** resolve on the `sys_path` the session passed, the producer's own environment.

## 8. What the prototypes give

The prototypes under `src/tests/helpers/` were built against the interface before this revision. The runtime takes
from them, and none of them ships:

| Prototype | Taken | Changed |
|---|---|---|
| `komira_udf_spike_abi` | `komira_udf_runtime.h`, `komira_udf_wire.h`, the Mojo mirror, the engine-side harness, the case files, the `komira-test/echo` runtime | Moved to `src/udf_abi/` at P0; the header gains the runtime options and `ERR_BAD_OPTION` (§2.2), the wire version becomes 3 (§4.1) |
| `komira_udf_spike_node_worker` | The engine-side proxy table (`proxy/proxy.c`), the channel (`proxy/channel.c`: spawn, framing, the grace-period kill), the IPC codec (`proxy/ipc.c`), the cancel word holding a call id (`kudfw.h:38-41`) | Spawns one zygote instead of one process per worker; the cancel word is an unlinked file under `scratch` on macOS, which lacks the prototype's Linux `memfd` (`channel.c:155`); kills go through a pidfd on Linux; exits come from the zygote's `EXIT` report instead of the proxy's own `waitpid` |
| `komira_udf_spike_native` | The sha256 check before use | — |

## 9. Decisions this document makes

- The library is C, needs no Mojo runtime, and does not wait for a shared worker library (§1).
- The zygote runs an interpreter executable, the user's own locally, as a script by path; no embedding of
  `libpython` (§2.1, §2.3).
- Runtime options in `komira_udf_host`, flags passed through the engine unread, and `ERR_BAD_OPTION` for a bad one
  (§2.2).
- The zygote starts at the first `load`, in its own process group, with a fixed environment and an empty working
  directory; a fork of the engine's process loses the runtime in the child (§2.3, §2.4).
- A zygote that is not single-threaded refuses the load, and its generation is retired; there is no other way to
  start workers (§3.2).
- A changed module starts a new zygote generation (§3.3).
- Inline payloads first; shared-memory slot heaps later, when measured (§4.4).
- The frame's input iterator re-enters the worker's dispatcher to serve nested calls (§4.5).
- Cancel is a shared word holding the id of the call to cancel; a forced stop is a `SIGKILL` the library records and
  sends itself, through a pidfd on Linux (§5.2, §5.3).
- No per-process memory cap and no `MEMORY_REPORT` at the first release (§5.3). This is deliberate: memory is one
  setting, the session's memory setting, which sizes the pool (`worker_mem_bytes` counts against it); a cap per worker
  would be a second memory knob.
- Workers run on the user's own interpreter, with `cloudpickle` and `pyarrow` as dependencies of the wheel. This is
  deliberate, and an exception to the rule that the package carries what it runs (it carries `libkomira` and the
  runtime library). It cannot be otherwise: a UDF imports the user's own packages (numpy, pandas, their model code)
  from the user's environment, which only the user's interpreter sees; a `VALUE` pickled by the producer's
  `cloudpickle` must be loaded by the same `cloudpickle` and interpreter minor; and `pyarrow` is a C extension built
  for that interpreter. A bundled interpreter would see none of the user's packages.
- Workers end with their zygote: `PR_SET_PDEATHSIG` on Linux, a watcher thread on macOS; the zygote kills its workers
  at end of file (§5.4).
- The descriptor message, its canonical bytes and what `validate` compares (§6), and the read set's duties (§6.1).
- A local run admits against `code_root` and the session's `sys_path`, without image checks (§7).

**macOS.** Workers fork from the zygote on macOS as on Linux. CPython's own multiprocessing spawns instead of forking there by default, because some system frameworks are not safe across a fork; no failing run of a worker forked from this zygote is known, so the runtime does nothing different on macOS.

## 10. What the next work needs from this design

| Work | Uses |
|---|---|
| The zygote and workers (P1) | §2, §3, §4, §6, §7; cases Z1-Z15, Z17, Z18 |
| Worker supervision (P2) | §5; cases S1-S13. Supervision is the zygote's `EXIT` report and the library's own kill, not `src/supervisor` (§5.1) |
| Lowering the UDF plan nodes | Only the C ABI (IF §3.3, §4); nothing of this document |
| The Python `@udf` decorator | §6 (the descriptor it writes), §7 (where it writes code objects), IF §6.1 |
| The UDF conformance cases | The shared corpus and the cases of this runtime (the conformance corpus) |
| The `PANDAS`, `NUMPY` and `POLARS` batch formats | §4.2 (the calls), P4; the types they carry are those of the README's "Types" section |
| The wheel design | §7; it decides the CPython minors the wheel supports, and the runtime supports every minor whose tag the SDK passes, refusing only other implementations and free-threaded builds (§3.1) |

The runtime-specific cases (Z for the zygote and workers, S for supervision) are listed in
[the conformance corpus](udf_runtime_conformance.md#cases-of-the-komirapython-runtime). They are the runtime's own
tests (IF §6.3, last bullet): welded to `src/udf_python/` (C, through the Mojo harness) and to `python/` (the worker,
in Python, the one surface where Python tests are allowed, `AGENTS.md` T11).

## 11. Code that must change for the required read set

No code changes in this pull request. The work, each item a brief of its own:

1. **Plan proto:** `src/plan_proto/plan.proto`, `UdfRef.arg_types` (:1684), `UdfRef.read_set` (:1708) and message
   `UdfReadSet` (:1721): the comments say required on `ROW` and `MAP_BATCHES_FRAME`; today the `read_set` comment
   (:1705-1707) and the `UdfReadSet` comment (:1717-1719) say that unset reads every input column. No field number, type or name
   changes; presence stays (empty is valid, unset is refused). Regenerate `src/plan_proto/generated` if it carries
   comments.
2. **Admission:** `src/plan_wire/plan_wire_udf.mojo`, `_check_udf_ref` (:380): refuse a `ROW` or
   `MAP_BATCHES_FRAME` with `read_set` unset with the new token `OPTIMIZED_UDF_READ_SET_REQUIRED`, declared beside
   `OPTIMIZED_UDF_READ_SET_KIND` (:97), listed in the file's token header, and exported from
   `src/plan_wire/__init__.mojo`. `src/plan_wire/plan_wire_udf_check.mojo`: drop the unset-read-set branches (`not
   u.read_set`, :425 and :588). `src/plan_ir/udf_ref.mojo`: the `read_set` docstring (:152) and the header comment
   (:12).
3. **Tests:** `src/plan_wire/tests` (`test_plan_wire_udf_ref.mojo`, `test_plan_wire_udf_plans.mojo`,
   `test_plan_wire_udf_args.mojo`, `test_plan_wire_udf_position_sweeps.mojo`): refusal of an unset read set on each
   of the two kinds, acceptance of an empty one, and every `ROW` and frame fixture given a read set.
4. **The Python SDK's producer** (`python/komira`: the `@udf` decorator, the DataFrame verbs and the plan encoding):
   - the `columns=[...]` argument on every `ROW` and frame verb, and the `TypedDict` or dataclass annotation read as
     a declaration;
   - for a `ROW`, the static scan of the function's bytecode, and `UDF_READ_SET_REQUIRED` naming `columns=[...]` when
     nothing bounds the reads;
   - for a frame, `columns=` or the annotation, else `UDF_READ_SET_REQUIRED` naming `columns=[...]`; the `group_by`
     columns added;
   - `read_set` and `arg_types` written on every `ROW` and frame `UdfRef`, and `recorded_fields` in every `ROW` and
     frame descriptor (§6);
   - the error table (`_errors.py`): `UDF_READ_SET_REQUIRED` from capture, and `OPTIMIZED_UDF_READ_SET_REQUIRED` from
     admission, each with its message and fix-it.

   *Status.* Built, privately (no query runs a UDF yet): the `@udf` decorator with `columns=`, the annotation and the
   `ROW` scan (`python/komira/_capture`), and the plan encoding with `read_set`, `arg_types` and `recorded_fields`
   (`python/komira/_plan/_udf.py`). Not yet: the DataFrame verbs, the grouped frame's `group_by` columns, and
   `OPTIMIZED_UDF_READ_SET_REQUIRED`, which comes with the run door. `UDF_READ_SET_REQUIRED` is the message prefix of
   an `UnsupportedOperation`, not a table in `_errors.py`.
5. **The TypeScript SDK's producer** (`node/`, when its UDF verbs land): the same `columns` value on every `ROW` and
   frame verb; a frame verb without `columns` is refused too. It has no static scan at first (a TypeScript function keeps no types at run
   time, and its source is not read), so a `ROW` verb without `columns` is refused at capture with
   `UDF_READ_SET_REQUIRED`. Its error table gains both tokens.
6. **The `komira/python` runtime (this document):** `validate` refuses an absent `recorded_fields`; the worker maps
   a frame's column-lookup errors (§6.1).
7. **`komira/native`:** unchanged (it already answers `ERR_DESCRIPTOR` on an absent field list); its export helper
   records the field list for `ROW` and frame entries.
8. **The optimizer's projection pushdown and lowering (not built yet):** no every-column path for either kind.
9. **`udf_runtime_conformance.md`:** changed in this pull request.
