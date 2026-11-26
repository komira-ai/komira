# shared_lib_native: a C-ABI library linking an owner's shared library

`spike_native` is a `mojo_shared_lib` whose Mojo closure reaches `libc`,
a library that owns C (`komira_openat_creat`, `komira_write_bytes`,
`komira_lseek_end`) and ships it as its own shared library,
`libkomira_libc_native.so.1` on Linux and `libkomira_libc_native.1.dylib` on
macOS arm64 (`//src/libc:komira_libc_native`, see
[native packaging](../../../../docs/design/native_packaging.md)). Without
`native_owners` the owner's static archive is linked into the library, which
is what every other `mojo_shared_lib` does with a C dependency. With
`native_owners = ["//src/libc:komira_libc_native"]` the library is
NEEDED on the owner's SONAME and the archive is not pulled in.

The one export, `native_owner_write_probe`, writes bytes to a file and returns
its size through `RawWriteFd`, so all three owner functions run.

## The gate

[`call_driver.mojo`](call_driver.mojo) `dlopen`s `./spike_native.so`
(`./spike_native.dylib` on macOS, `RTLD_NOW`), calls the export, and then checks
that the owner's C is the owner's copy. First, the library leaves
`komira_openat_creat`, `komira_write_bytes` and `komira_lseek_end` undefined.
Then, opening `libkomira_libc_native.so.1` (on macOS
`libkomira_libc_native.1.dylib`) by name finds the copy the gate staged in `lib/`,
which is the one the loader mapped for the NEEDED edge. On Linux the driver
reads the first check from the ELF dynamic symbol table. On macOS it reads the Mach-O load commands and symbol
table: each of the three names must be undefined and bound, by its two-level
library ordinal, to the load command for `@rpath/libkomira_libc_native.1.dylib`,
and the library must carry `LC_CODE_SIGNATURE`. The gate stages the owner, and
every library it needs, in `lib/` beside the library, where the run path
(`$ORIGIN/lib:$ORIGIN`, on macOS `@loader_path/lib`) finds them.
Two negative twins in [`tests//negative/shared_lib`](../../tests/negative/shared_lib/BUCK)
build the same library without `native_owners`, and both are red on Linux and on
darwin-arm64:

- `owner_embedded` runs a smaller driver that only opens the owner by name. The
  open fails because no owner is staged (dyld: `no such file`).
- `owner_embedded_bound` is named `spike_native` and runs this driver unchanged.
  It is red on the first check: on Linux `komira_openat_creat is not bound to the
  owner's shared library`, on macOS `has no load command for
  @rpath/libkomira_libc_native.1.dylib`.

## Measured (linux-x86_64)

| | `spike_native.so` | the same without `native_owners` |
|---|---|---|
| size | 17600 bytes | 20920 bytes |
| NEEDED | `libKGENCompilerRTShared.so`, `libkomira_libc_native.so.1`, `libpthread.so.0`, `libc.so.6` | the same without `libkomira_libc_native.so.1` |
| RUNPATH | `$ORIGIN/lib:$ORIGIN` | `$ORIGIN/lib:$ORIGIN` |
| undefined `komira_*` | 3 (the owner's) | 0 |
| default-visibility defined symbols | 1 (`native_owner_write_probe`) | 1 |

`libkomira_libc_native.so.1` itself is 11080 bytes, NEEDED on `libpthread.so.0`
and `libc.so.6`, RUNPATH none (it needs no other owner), with 19 defined
dynamic symbols.

With `exports_exact` the dynamic symbol table is the one export. The owner's names are undefined in the
library (bound at load), so the library defines none of them either way.

## Measured (darwin-arm64)

Read from `[dist]` and `tests//negative/shared_lib:owner_embedded[ungated]` built
with `--target-platforms komira//tools/build/platforms:darwin-arm64` on the
farm's Macs.

| | `spike_native.dylib` | the same without `native_owners` |
|---|---|---|
| size | 56848 bytes | 56856 bytes |
| install name (`LC_ID_DYLIB`) | `@rpath/spike_native.dylib` | `@rpath/owner_embedded.dylib` |
| `LC_LOAD_DYLIB` | `@rpath/libKGENCompilerRTShared.dylib`, `@rpath/libkomira_libc_native.1.dylib`, `/usr/lib/libSystem.B.dylib` | the same without `@rpath/libkomira_libc_native.1.dylib` |
| `LC_RPATH` | `@loader_path/lib` | `@loader_path/lib` |
| undefined `komira_*`, each bound to the owner | 3 | 0 |
| external defined symbols | 1 (`native_owner_write_probe`) | 1 |
| code signature | ad hoc, linker-signed (CodeDirectory flags `0x20002`) | the same |

`libkomira_libc_native.1.dylib` itself is 52000 bytes, install name
`@rpath/libkomira_libc_native.1.dylib`, loading only `/usr/lib/libSystem.B.dylib`,
no `LC_RPATH` (it needs no other owner), with 19 external defined symbols, and
signed the same way.

## What `native_owners` does

- links each owner's shared library on the link line **before** the C
  archives of the closure. The linker binds the owner's names to the shared
  library, and an archive member is pulled in only for a name still
  undefined. Putting the owners after the archives embeds the C and keeps
  the NEEDED entry, which is why the gate reads the symbol table;
- stages the owner and its own NEEDED owners in the gate's `lib/`;
- does the same on macOS arm64: ld64 records the owner by its install name,
  `@rpath/libkomira_<library>_native.1.dylib`, and the library's run path
  (`@loader_path/lib`) finds the staged copy. `[dist]` holds the owner's
  closure in `lib/` beside the Mojo runtime libraries. There is no codesign
  step: ld64 signs an arm64 output ad hoc as it links it, and nothing changes
  the file afterwards (no `install_name_tool`), so the copies the gate and
  `[dist]` make load as they are.

## What is not done

- The archives stay on the link line. If the closure calls a name the owner
  does not export (the owner exports what its `callers` pass to
  `external_call`), the member defining it is embedded silently. Removing the
  owner's archives from the link needs `MojoInfo` to keep its C libraries per
  owner instead of one merged link; the rule does not do that.
- The packaged copy of the library has no `native_owners` handling: a conda
  package of it would have to require the owner's package, and the owner's
  `lib/` must be next to it (or the run path changed).
- `exports` is not checked against the source's `@export` set.
- A coverage build of the library (`-c komira.coverage=true`) does not link
  `native_owners`: it embeds the C as before.
