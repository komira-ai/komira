# shared_lib_native: a C-ABI library linking an owner's shared library

`spike_native` is a `mojo_shared_lib` whose Mojo closure reaches `komira_libc`,
a library that owns C (`komira_openat_creat`, `komira_write_bytes`,
`komira_lseek_end`) and ships it as its own shared library,
`libkomira_libc_native.so.1` (`//src/komira_libc:komira_libc_native`, see
[native packaging](../../../../docs/design/native_packaging.md)). Without
`native_owners` the owner's static archive is linked into the library, which
is what every other `mojo_shared_lib` does with a C dependency. With
`native_owners = ["//src/komira_libc:komira_libc_native"]` the library is
NEEDED on the owner's SONAME and the archive is not pulled in.

The one export, `native_owner_write_probe`, writes bytes to a file and returns
its size through `RawWriteFd`, so all three owner functions run.

## The gate

[`call_driver.mojo`](call_driver.mojo) `dlopen`s `./spike_native.so`
(`RTLD_NOW`), calls the export, and then checks that the owner's C is the
owner's copy: opening `libkomira_libc_native.so.1` by SONAME finds the library
the loader mapped for the NEEDED edge, and the library's own dynamic symbol
table leaves `komira_openat_creat`, `komira_write_bytes` and `komira_lseek_end`
undefined. The gate stages the owner, and every library it needs, in `lib/`
beside the library, where the run path (`$ORIGIN/lib:$ORIGIN`) finds them.
[`tests//negative/shared_lib:owner_embedded`](../../tests/negative/shared_lib/BUCK)
is the same library without `native_owners`: it fails the SONAME lookup.

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

## What `native_owners` does

- links each owner's shared library on the link line **before** the C
  archives of the closure. The linker binds the owner's names to the shared
  library, and an archive member is pulled in only for a name still
  undefined. Putting the owners after the archives embeds the C and keeps
  the NEEDED entry, which is why the gate reads the symbol table;
- stages the owner and its own NEEDED owners in the gate's `lib/`;
- is refused on macOS (a library's shared library is ELF only).

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
