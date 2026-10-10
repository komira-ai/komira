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
   [`prefix_header.sh`](prefix_header.sh)): `elfsyms armap` reads the
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

`prefixed_archive_check` ([`archive_check.sh`](archive_check.sh)) then reads
every member of the prefixed archive (`elfsyms symtab`) and fails its build
action unless

- every defined symbol starts with the prefix (or matches the target's
  `allow`, each with its reason in the BUCK file: `__umodti3` and
  jemalloc's `sdallocx` for aws-lc, C++ `_Z...` names for snappy),
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
