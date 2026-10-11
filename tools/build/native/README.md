# Symbol prefixing of the vendored C libraries

The C libraries built from source in [`third_party/`](../../../third_party) are
built with every global symbol renamed under a komira prefix, so that a
process can hold komira's copy of a library and any other copy (a system
`libcrypto.so.3`, say) without either binding to the other's functions:

| library | target | prefix |
|---|---|---|
| aws-lc | `//third_party/aws-lc:crypto` | `komira_awslc_` (e.g. `komira_awslc_SHA256`) |
| s2n-tls | `//third_party/s2n-tls:s2n` | `komira_s2n_` (`s2n_init` becomes `komira_s2n_init`; any other global `X`, `komira_s2n__X`) |
| snappy | `//third_party/snappy:snappy` | `komira_snappy_` on its C API (`komira_snappy_compress`); its C++ names stay |

Mojo code calls the prefixed names: `external_call["komira_awslc_SHA256", ...]`.
A C caller that includes the library's headers gets them without writing
them, because the renaming header is an exported `-include` of the library.

## How a library is prefixed

Each library's BUCK file builds it three times over the same arguments:

1. `<lib>_unprefixed`, a `cxx_library` with upstream's names, which nothing
   links;
2. `prefix_symbols`, a `prefix_header` ([`defs.bzl`](defs.bzl),
   `prefix_tool header`): `elfsyms armap` reads the
   unprefixed archive's symbol table, aws-lc's `util/read_symbols.go` skip
   list (and the compiler builtin `__umodti3`) is applied, and the header
   says `#define X <prefixed X>` for each name left, plus the
   `extra_symbols` (names the library references but never defines, such as
   aws-lc's four weak `OPENSSL_memory_*` allocator hooks). Its `[symbols]`
   sub-target is the list of original names. For aws-lc the header is the
   library's own `boringssl_prefix_symbols.h` form, which is how aws-lc's
   prefix build renames, without Go or CMake;
3. `<lib>_prefixed`, the same `cxx_library` with
   `exported_preprocessor_flags = ["-include", "$(location :prefix_symbols)"]`,
   which reaches every C, C++ and assembly compile of the library and of
   its C users.

`prefixed_archive_check` (`prefix_tool check`) then reads
every member of the prefixed archive (`elfsyms symtab`) and fails its build
action unless

- every defined symbol starts with the prefix (or matches the target's
  `allow`, each with its reason in the BUCK file: `__umodti3` and
  jemalloc's `sdallocx` for aws-lc, C++ names, `_Z*`, for snappy; an
  `allow` is a whole name, or a name's beginning followed by `*`),
- every weak undefined symbol starts with the prefix (a hook another object
  of the process could define),
- no undefined symbol is one of the original names (of this library, and for
  s2n-tls of aws-lc too: a reference the renaming missed), and
- at least `min_defined` symbols carry the prefix (a check that read nothing
  cannot pass).

The target users name, `//third_party/<lib>:<lib>`, is a `checked_cxx_library`:
the prefixed library's providers, with the check as a dependency. Its result
is a `ValidationInfo`, and Buck2 runs the validations of every target in the
graph it builds, so no build that links the library succeeds while the
check is red.

## elfsyms

[`elfsyms.c`](elfsyms.c), built static (musl) with the pinned zig by `c_exe`:
the C toolchain has no `nm` or `readelf` (an action may not take one from the
worker), so the build reads ELF itself. `elfsyms armap <lib.a>` prints an
archive's symbol table; `elfsyms symtab <lib.a>` prints every non-local
symbol of every member as `DEF|UND <bind> <type> <visibility> <name>`. A
member it cannot read is an error, never skipped.

## prefix_tool

Both rules' actions run `prefix_tool`, a Zig program
([`src/main.zig`](src/main.zig)), built by `zig_exe` behind its unit tests
(`:prefix_tool_unit`); no shell runs. It reads the archive by running
`elfsyms` and nothing else.

- `prefix_tool header` ([`src/prefix.zig`](src/prefix.zig)) sorts the names
  by bytes, each once (as `LC_ALL=C sort -u` does), and writes the header:
  `boringssl` style, aws-lc's own form (`#define X
  BORINGSSL_ADD_PREFIX(BORINGSSL_PREFIX, X)`); `strip` style, `#define X
  <prefix><X less strip>` when `X` starts with `strip`, else `#define X
  <prefix>_X`. Fewer than `min_symbols` names, or an empty one, fails the
  action. The header's first line still names `prefix_header.sh`, the
  script the tool replaced, so that the header's bytes, and the key of every
  compile that includes it, did not change.
- `prefix_tool check` gives the verdict above. Red, it names each finding on
  stderr (`archive_check RED: <n> <what> in <archive>:` and at most 50 of
  the names) and exits 1; green, it writes the validation result.

The command line is in [`src/cli.zig`](src/cli.zig); the cases are in
[`src/prefix_test.zig`](src/prefix_test.zig) and
[`src/cli_test.zig`](src/cli_test.zig).

## Each library's shared library

A Mojo library that owns C ships it as its own shared library,
`lib<library>_native.so.1`
([the design](../../../docs/design/native_packaging.md)).
`native_shared_library` ([`shared.bzl`](shared.bzl)) builds one from the
C archives the library owns (`archives`) and the Mojo libraries that call
them (`callers`). Every action runs a Zig-built tool: `native_so`
([`native_so.zig`](native_so.zig)), or the Mojo toolchain's zig through
`zig_cc_launcher` for the link.

1. `native_so exports` reads every `external_call` name in the callers'
   library sources ([`native_callsites.zig`](native_callsites.zig), which
   skips comments and string literals and refuses a call whose name is not
   a literal) and every symbol of the archives
   ([`native_elf.zig`](native_elf.zig)). The exports are the called names an
   archive defines with default visibility. It writes the list
   (`[exports]`), a version script making everything else local
   (`[version_script]`) and a report (`[report]`). It fails on a symbol
   defined by two archives (weak or common included), a called name
   defined only hidden, an archive no caller calls, or a caller calling
   none of the exports.
2. The link: every archive whole, `-Bsymbolic`, `--gc-sections`,
   `-z defs`, the version script, `--strip-debug`, SONAME
   `lib<library>_native.so.1`, for the toolchain's target (the platform
   row's `zig_triple`). `[link]` is the unversioned link name.
3. Seven checks read the result back with `native_so check <n>`, each its
   own build action and a validation of the target, so no build of the
   target succeeds while one is red:

| check | fails when |
|---|---|
| 1 | an export lacks the `komira_` prefix, or the exports differ from the list or the version script |
| 2 | a name a caller calls that an archive defines is not exported (read from the sources and archives again, so a name the list or the link dropped is caught) |
| 3 | a strong undefined `komira_` symbol (no komira owner is a declared `NEEDED` yet), or a weak one not in `weak_undefined` |
| 4 | the SONAME differs, a `NEEDED` is not glibc (`libc.so.6`, `libpthread.so.0`, `ld-linux-*`), `libc.so.6` is not `NEEDED`, or there is a run path |
| 5 | a `GLIBC_` version needed is above `glibc_floor` (the platform row's `os_floor`), or is not a release version |
| 6 | `DT_FLAGS` lacks `DF_SYMBOLIC` (0x2); zig links with `-z now`, so the value is 0xa |
| 7 | a strong undefined symbol is neither `GLIBC_`-versioned nor `komira_`, or the weak undefined symbols differ from `weak_undefined` |

`[dynsym]` is `native_so dynsym`: the dynamic section, the versions needed
and every dynamic symbol with its version. The unit tests
([`native_so_test.zig`](native_so_test.zig), `:native_so_unit`, which
`:native_so` waits for) show each check green on a library shaped as
komira_crypto's is and red on its defect;
[`native_elf_test.zig`](native_elf_test.zig) builds a small shared object
byte by byte, with every dynamic tag and version section the reader keeps
(several NEEDED and run path entries among them; komira_crypto's library
has no run path), and checks what the reader reads from it.

Only `//src/komira_crypto:komira_crypto_native` exists so far, and no
package ships it.
