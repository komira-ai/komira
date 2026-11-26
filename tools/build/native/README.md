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
| brotli (the decoder) | `//third_party/brotli:brotlidec` | `komira_brotli_` (`BrotliDecoderDecompress` becomes `komira_brotli_DecoderDecompress`; any other global `X`, `komira_brotli__X`) |
| SQLite | `//third_party/sqlite:sqlite3` | `komira_sqlite3_` (`sqlite3_open_v2` becomes `komira_sqlite3_open_v2`) |

Mojo code calls the prefixed names: `external_call["komira_awslc_SHA256", ...]`.
A C caller that includes the library's headers gets them without writing
them, because the renaming header is an exported `-include` of the library.

## How a library is prefixed

Each library's BUCK file builds it three times over the same arguments:

1. `<lib>_unprefixed`, a `cxx_library` with upstream's names, which nothing
   links;
2. `prefix_symbols`, a `prefix_header` ([`defs.bzl`](defs.bzl),
   `prefix_tool header`): the defined non-local symbols of every member of
   the unprefixed archive (the names its symbol table lists) are read;
   aws-lc's `util/read_symbols.go` skip list (and the compiler builtin
   `__umodti3`) is applied, and the header
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
every non-local symbol of every member of the prefixed archive and fails its
build action unless

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
the prefixed library's providers, with the check as a dependency (on macOS,
where `:crypto` re-exports //src/awslc's archive, its `[static-pic]` is that
archive, `archive` of the rule, so a native shared library can link it). Its result
is a `ValidationInfo`, and Buck2 runs the validations of every target in the
graph it builds, so no build that links the library succeeds while the
check is red.

## prefix_tool

Both rules' actions run `prefix_tool`, a Zig program
([`src/main.zig`](src/main.zig)), built by `zig_exe` behind its unit tests
(`:prefix_tool_unit`); no shell runs and no other program. The C toolchain
has no `nm` or `readelf` (an action may not take one from the worker), so
the tool reads the archive itself, with the object reader `native_so` uses
(the module `:native_objects`: [`native_elf.zig`](native_elf.zig), which
hands Mach-O to [`native_macho.zig`](native_macho.zig)):

- a System V archive (the GNU `/` or `/SYM64/` symbol table, `//` long
  names) of 64-bit little-endian ELF objects, as the Linux builds make, or
- a BSD archive (`__.SYMDEF` symbol table, `#1/<n>` long names) of thin
  arm64 Mach-O objects, as the darwin-arm64 build makes. A Mach-O name loses
  the one `_` Mach-O prepends to a C name (`_snappy_compress` is
  `snappy_compress`), so the header renames the names the C sources use and
  the check holds the same names to the prefix on either platform.

Every member is read, never only the archive's symbol table, so the header
and the check read the same symbols. A member it cannot read (another
format, a thin archive, a header or a name pointing outside its file) fails
the action, naming the archive and what is wrong; nothing is skipped.

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
[`src/cli_test.zig`](src/cli_test.zig), which reads two committed archives
of the same C, one of each kind ([`src/testdata`](src/testdata/README.md)).

## Each library's shared library

A Mojo library that owns C ships it as its own shared library,
`libkomira_<library>_native.so.1` on Linux and
`libkomira_<library>_native.1.dylib` on macOS
([the design](../../../docs/design/native_packaging.md)).
`native_shared_library` ([`shared.bzl`](shared.bzl)) builds one from the
C archives the library owns (`archives`), the Mojo libraries that call
them (`callers`), the dependent owners' archives that call them
(`caller_archives`: crypto's lists s2n-tls, whose needs from aws-lc no
Mojo library calls) and the owners whose C its own archives call
(`needed_owners`: http_core's lists crypto's library). Every action runs a Zig-built tool: `native_so`
([`native_so.zig`](native_so.zig)), or for the link the Mojo toolchain's zig
through `zig_cc_launcher` on Linux, and on macOS the macOS compile wrapper's
`link` mode (below). Which form a target takes follows the operating system
the Mojo toolchain of its target platform compiles for
(`MojoToolchainInfo.os`).

1. `native_so exports` reads every name a caller archive references and
   does not define, and every `external_call` name in the callers'
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
   `libkomira_<library>_native.so.1`, for the toolchain's target (the platform
   row's `zig_triple`). Then `-lc++` when `cxx_runtime` is set (snappy is
   C++: zig's libc++ and libc++abi, static, made local by the version
   script), and each of `needed_owners`' shared libraries, with
   `DT_RUNPATH` `$ORIGIN`: a program's run path is not searched for its
   libraries' needs, so the owner is found beside this library. `[link]` is
   the unversioned link name.
3. Seven checks read the result back with `native_so check <n>`, each its
   own build action and a validation of the target, so no build of the
   target succeeds while one is red:

| check | fails when |
|---|---|
| 1 | an export lacks the `komira_` prefix, or the exports differ from the list or the version script |
| 2 | a name a caller (or caller archive) calls that an archive defines is not exported (read from the sources and archives again, so a name the list or the link dropped is caught) |
| 3 | a strong undefined `komira_` symbol no declared `NEEDED` owner's library exports, a declared owner exporting none of them, or a weak undefined `komira_` symbol not in `weak_undefined` |
| 4 | the SONAME differs; a `NEEDED` is neither glibc (`libc.so.6`, `libpthread.so.0`, `ld-linux-*`) nor a declared owner; a declared owner is not `NEEDED`; `libc.so.6` is not `NEEDED` though the library has an undefined symbol outside `komira_`; `DT_RUNPATH` is not exactly `$ORIGIN` when an owner is declared, or present when none is; any `DT_RPATH` |
| 5 | a `GLIBC_` version needed is above `glibc_floor` (the platform row's `os_floor`), or is not a release version, or none is needed though the library has an undefined symbol outside `komira_` (a shim of atomics alone needs nothing of glibc) |
| 6 | `DT_FLAGS` lacks `DF_SYMBOLIC` (0x2); zig links with `-z now`, so the value is 0xa |
| 7 | a strong undefined symbol is neither `GLIBC_`-versioned nor `komira_`, or the weak undefined symbols differ from `weak_undefined` |

4. The README check, `native_so readme` (`[readme_calls]`, a validation of
   the target too): the owning library's welded README gate compiles each
   README example's program a second time to an object
   (`[tests][readme][objects]` of the library, for every library listing a
   C library among its `deps`; [`../mojo/readme.bzl`](../mojo/readme.bzl)).
   A `.mojoc` holds no machine code, so the library's Mojo is compiled into
   that object, and every C function the example reaches is an undefined
   symbol of it. The check fails when no object references one of the
   exports, or the README has no example: an installed README run that
   calls none of the library's C passes with a broken shared library or
   without its `-l` (the design's "Every owner is called, not only
   loaded"). The linked README programs cannot be read for this: `mojo
   build` strips their symbol tables.

### On macOS (Mach-O)

For a darwin-arm64 target the same rule links a Mach-O library, with the
same export list, the same archives and the same checks; what differs:

| | Linux (ELF) | macOS (Mach-O) |
|---|---|---|
| file | `libkomira_<library>_native.so.1` | `libkomira_<library>_native.1.dylib` |
| its own name | SONAME, the file name | install name `@rpath/<file>` |
| `[link]` | `libkomira_<library>_native.so` | `libkomira_<library>_native.dylib` |
| export script | version script (`[version_script]`) | exported symbols list (`[exported_symbols_list]`, `native_so exports --format macho`), from the same export list |
| link | zig: `-Bsymbolic`, `--gc-sections`, `-z defs`, `--strip-debug`, `--whole-archive` | the host's `/usr/bin/cc` and ld on a Mac: `-dead_strip`, `-undefined,error`, `-S`, `-force_load` each archive; no `-Bsymbolic` and no DT_FLAGS (a two-level namespace, check 6) |
| C++ runtime (`cxx_runtime`) | zig's libc++ and libc++abi, static | the system's `/usr/lib/libc++.1.dylib` (`-lc++`), as every Mojo program linked on macOS |
| an owner it needs | `NEEDED` its SONAME, `DT_RUNPATH` `$ORIGIN` | `LC_LOAD_DYLIB` its install name, `LC_RPATH` `@loader_path` |
| check 5's floor | the linux-x86_64 row's glibc | the darwin-arm64 row's macOS (`11.0`), also the link's `-mmacosx-version-min` |
| check 7's weak list | `weak_undefined` | `weak_undefined` without the ELF C runtime's `__gmon_start__` (`ELF_CRT_WEAK`) |

The link runs on a Mac, like every other Mojo link there: `mojo_compile link`
([`../mojo/tools/macos_link.zig`](../mojo/tools/macos_link.zig)), a mode of
the macOS compile wrapper, refuses a host whose identity is not one of the
toolchain's `--macos-host` values (so the result is never filed under a host
toolchain the action key does not name), then runs `/usr/bin/cc` with an
environment of `PATH=/usr/bin:/bin`, `MACOSX_DEPLOYMENT_TARGET` and a private
`TMPDIR` and `HOME`, and checks that the output exists and does not hold the
action's directory. Every other action runs `native_so`, built for the
execution platform it is configured for (`exec_tool_target`), so on a Mac it
is a macOS executable. `shared_names` and `macho_link_args` in
[`shared.bzl`](shared.bzl) are the Mach-O names and arguments;
`:shared_form_darwin`, `:shared_form_darwin_alone` and `:shared_form_linux`
fail at analysis unless they are exactly the ones in [`BUCK`](BUCK).

How the library is found at run time: by its install name, through a run
path. A library that needs it carries `LC_RPATH @loader_path` and finds it in
its own directory; a program or test that links it stages it in the `lib/`
its own run path (`@loader_path/lib`) names, as on Linux. Nothing loads it by
an absolute path or through `DYLD_LIBRARY_PATH`. No `mojo_shared_lib` links an
owner's library on macOS yet (`native_owners` is refused there), and no conda
package for osx-arm64 holds one: the conda packer builds linux-64 only.

`native_so` reads Mach-O as well as ELF, by each file's magic: a `.dylib`,
Mach-O objects, and BSD-layout archives of them (`#1/<n>` long names, a
`__.SYMDEF` symbol table member), in
[`native_macho.zig`](native_macho.zig). Only thin arm64 is read. A C name
loses the `_` Mach-O prepends, an owner is named by its install name, and
`native_so exports --format macho` writes the exported symbols list ld64
takes in place of the version script (check 1 reads it back from the
built library's symbol table, so an export the link dropped or added is
red). Checks 4 to 7 hold a Mach-O library to the same properties through its
load commands:

| check | fails when (Mach-O) |
|---|---|
| 4 | the install name (`LC_ID_DYLIB`) differs; a loaded dylib is neither `/usr/lib/libSystem.B.dylib`, `/usr/lib/libc++.1.dylib` nor a declared owner; a declared owner is not loaded; a dylib is loaded by a command other than `LC_LOAD_DYLIB` (a re-export would pass the loaded library's API on as this one's); libSystem is not loaded though the library has a strong undefined symbol outside `komira_`; `LC_RPATH` is not exactly `@loader_path` when an owner is declared, or present when none is |
| 5 | no `LC_BUILD_VERSION` (or `LC_VERSION_MIN_MACOSX`), a platform other than macOS, or a minimum macOS version above the floor (the row's `os_floor` version, `11.0`) |
| 6 | `MH_TWOLEVEL` is clear or `MH_FORCE_FLAT` set (a flat namespace), or an exported definition is weak: ld64 has no `-Bsymbolic`, and these are the ways a name the library defines could bind to another image's copy |
| 7 | any undefined symbol, `komira_` included, is bound to flat lookup, the main executable or the library itself; a strong undefined symbol is neither `komira_` nor bound by its two-level ordinal to libSystem or libc++; or the weak undefined symbols differ from `weak_undefined` |

`[dynsym]` is `native_so dynsym`: the dynamic section, the versions needed
and every dynamic symbol with its version (for a Mach-O library: its install
name, loaded dylibs, `LC_RPATH`, header flags, minimum OS version and
symbols, each undefined one with the dylib it binds to). The unit tests
([`native_so_test.zig`](native_so_test.zig), `:native_so_unit`, which
`:native_so` waits for) show each check green on a library shaped as
crypto's is and red on its defect;
[`native_elf_test.zig`](native_elf_test.zig) builds a small shared object
byte by byte, with every dynamic tag and version section the reader keeps
(several NEEDED and run path entries among them), and checks what the
reader reads from it.
[`native_macho_test.zig`](native_macho_test.zig) does the same for Mach-O: a
dylib, an object and a BSD archive built byte by byte, every malformed input
refused with its reason, and each check green on an owner-shaped `.dylib`
and red on its defect.

Each owner of the design's table has its `<library>_native` target in its
own BUCK file: crypto, http_core (`NEEDED` crypto's),
compression, parquet_codec (brotli's decoder),
db_sqlite (SQLite) and the first-party shims' owners (libc,
async_rt, async_api, fs, objectstore,
metrics, scan_source, supervisor). log has none:
its holder's accessors are hidden by design, one copy per image (the design's
question 2), so its holder ships as a static archive. Every owner's
`mojo_library` except parquet_codec's and db_sqlite's names its
target (`native = ":<library>_native"`;
log's says `native_static = True`), and its conda package holds the
file at lib/ with a `lib_files` row
([packaging/conda/README.md](../../../packaging/conda/README.md), "A library's
native code in its package"). Those two libraries are built and checked, but
no package ships them yet.

## so_report

`so_report` (`so_report.zig`, tests in `so_report_test.zig`) reads a library's ELF
file and the libraries it needs and writes a markdown table: size, SONAME, RUNPATH, RPATH
and `DT_NEEDED` of each, the highest `GLIBC_`, `GLIBCXX_` and `CXXABI_` version each
requires, and which native owners the target reaches. It is built behind its unit tests and
run by `komira//tools/build/package/libkomira:libkomira_elf_report`.
