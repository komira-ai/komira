# Symbol prefixing of the vendored C libraries, and libkomira_native.so.1

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
member it cannot read is an error, never skipped. `elfsyms dynsym <file>`
prints a shared object's or a program's dynamic section (`SONAME`,
`NEEDED`, `RUNPATH`, `RPATH`, `SYMBOLIC`, `FLAGS`) and its dynamic symbols
in the `symtab` form.

## One shared library

`//tools/build/native:komira_native` is `libkomira_native.so.1` (and its
link name `libkomira_native.so`, the `[link]` sub-target): every
komira-owned C archive the Mojo packages call, and the prefixed aws-lc,
s2n-tls and snappy, in one shared object. A consumer links it with
`-Xlinker -L<env>/lib -Xlinker -lkomira_native`; a built program finds it
with the run path `$ORIGIN/../lib`.

### What goes in

Each C archive declares its kind, next to its `cxx_library`
([`defs.bzl`](defs.bzl)):

- `native_archive(name = "<lib>_native", lib = ":<lib>", kind = ..., reason = ...)`
  for komira's own C; it carries every provider of the library, and a Mojo
  package names it in `deps` in place of the library (the link arguments are
  the library's, so no action key changes);
- `native_kind = "shared"` on a vendored library's `checked_cxx_library`.

[`members.bzl`](members.bzl) states what the library holds, once: its
`ARCHIVES`, its `PER_LIBRARY` archives and its `CALLERS`. The library's
target is built from those lists, and every Mojo package's conda package
reads them (below).

`shared` C is one copy per process and goes in the library. `per_library`
C holds state that must be one per Mojo library and stays out: today only
komira_log's holder (`src/komira_log/engine/_log_holder_shim.c`), whose
cells hold the addresses of Mojo structs that only the library that built
them may read, so its accessors are hidden and each Mojo library links its
own copy. The rule takes only declared archives (an undeclared one is an
analysis error: the dependency lacks `NativeArchiveInfo`) and refuses a
`per_library` one in `archives`, or a `shared` one in `per_library`.

### The exports, generated

[`native_exports.sh`](native_exports.sh) writes the export list and the
version script from the code: the names the `callers`' sources pass to
`external_call["..."]` (their `[src]`, tests excluded) that a `shared`
archive defines. Every other symbol is local: aws-lc's and s2n-tls's
internals, snappy's C++ and the C++ runtime. A call site is code: names in
docstrings (triple-quoted strings) and `#` comments are not read, and the
quoted name may be on a later line than `external_call[`. It fails when

- a symbol is defined by two archives (one owner per C symbol), whatever its
  binding: a strong pair fails the link, and a weak or common pair would
  link with the linker keeping one copy silently, so it is refused too;
- a called name is defined only hidden (the library could not export it);
- a called `komira_*` name is defined by no `shared` and no `per_library`
  archive, or by both;
- an archive defines none of the exports, or a caller calls none of them.

`callers` is a list in the BUCK file: a package that calls the library and
is not listed fails its own link against the library once packages link it,
so a missing one cannot ship.

Names only welded tests call (`komira_objstore_test_*`, `komira_fs_test_*`,
`komira_mac_*`, `komira_s2n_config_enable_quic`) are not exported.

### Welded tests link the archives, never the library

A welded test (and a README example) is linked against the static archives
of its package's closure, exactly as before the library existed, and never
against `libkomira_native.so.1`: the library's target provides no
`MergedLinkInfo`, so a Mojo target cannot name it in `deps`. A test process
therefore holds one copy of every C static, and a test hook it sets
(`komira_objstore_test_fail_next_link_emlink`, say) is the copy the code
under test reads. Were a test to link both, its hook would set the archive's
copy while the library's code read its own, and the test would pass without
testing anything. Planted, red: that hook made inert in
`_objectstore_shim.c` fails `test_local_fs_store_create_write_failure`
(`AssertionError: not an I/O error`). What a user links, the library, is
tested by the run tests below, against the same archives linked whole.

### The package

`:komira_native_conda` (`conda_native_package`,
[`../package/conda.bzl`](../package/conda.bzl)) is the conda package
`komira_native`: `lib/libkomira_native.so.1` and the symbolic link
`lib/libkomira_native.so` to it, made from `:komira_native`, so it exists
only after the export checks and the run test passed. Its version and build
string are every package's of the release; its run requirements are the
platform guard and `__glibc >=2.34` (the glibc of the platform table's link
target). A Mojo library whose closure links an archive of `ARCHIVES` requires
it at its own version and build string, and its `.mojoc` carries no C (it
never did: a `.mojoc` holds no machine code). A library that names a
`PER_LIBRARY` archive in `deps` ships it in its own package as
`lib/lib<name>.a` (komira_log: `lib/libkomira_log_holder.a`), which a
program built against the package links into its own image
(`-Xlinker -lkomira_log_holder`), keeping one copy of its state per Mojo
library. A library linking C that is in neither list is refused
([packaging/conda](../../../packaging/conda/README.md)).

A consumer links `-Xlinker -L<env>/lib -Xlinker -lkomira_native`, and a
built program finds the library with the run path `$ORIGIN/../lib`.
`mojo run` does not link a static archive, so a program using komira_log (or a
library depending on it) must be built, not run with `mojo run`.

The installed run tests build the environment from the packages themselves
(`conda_prefix`, [`../package/conda_prefix.bzl`](../package/conda_prefix.bzl):
`komira_pack conda-install` follows the root's run requirements through a
pool of package targets and extracts what they reach):

| target | environment | cases |
|---|---|---|
| `:installed_crypto_run_test` | komira_crypto's package and what it requires | R1 and B1 of `run_test/installed_crypto.mojo`: SHA-256 and HMAC-SHA256 known answers through komira_crypto, whose aws-lc is the library's |
| `:installed_log_run_test` | komira_log's package and what it requires | B1 of `run_test/installed_log.mojo`, linking `-lkomira_log_holder`: a filter installed through the package's holder archive is read back |

Only the requirements decide what is installed, so a library package that
stopped requiring `komira_native` gets an environment without the library.
Planted, red: the requirement dropped from every library package
(`conda.bzl` `_native_deps`) leaves the packages' own `[check]` green (it is
given the same list) and fails R1 (`Symbols not found: [ komira_awslc_SHA256,
... ]`) and B1 (`unable to find dynamic system library 'komira_native'`).
`:komira_native_conda_kci` reads the package's manifest and its `metadata.json`
with kci's parsers, and fails unless kci reads the metadata as kind `native`.

### The link and the checks

[`native_link.sh`](native_link.sh) links the archives `--whole-archive` with
`-Bsymbolic`, `--gc-sections`, `-z defs` and the version script, with the
Mojo toolchain's zig and target. [`native_check.sh`](native_check.sh), a
validation of `:libkomira_native`, reads the result back and fails unless
every exported symbol is `komira_*` and the exports are exactly the
generated list (and the version script's), no strong undefined symbol is
`komira_*`, the SONAME is `libkomira_native.so.1`, NEEDED is only glibc's
own libraries, and it was linked `-Bsymbolic` with no run path.
[`native_callsite_check.sh`](native_callsite_check.sh), a second
validation, does not trust the generator: it reads the call sites again
with [`callsites`](callsites.c), a tokenizer of Mojo sharing nothing with
the generator's line scan, and fails unless the exports are exactly the
call-site names it finds that the archives define. A name the generator's
scan missed, absent from both its list and its script, is a difference
there.

`:komira_native_run_test` ([`native_run.sh`](native_run.sh), programs in
[`run_test/`](run_test)) lays the library out as a conda environment holds
it, with `komira_libc` as `lib/mojo/komira_libc.mojoc`, and runs Mojo
programs calling aws-lc (SHA-256, AES-256-GCM), snappy, s2n-tls (init, a
TLS 1.3 config, a client connection) and komira_libc's shim through it.
IR1 and IR2 fail on a worker without the system `libcrypto.so.3` and
`libssl.so.3`: a case that cannot load them proves nothing about them.

| case | what |
|---|---|
| R1 | `mojo run` with `-Xlinker -L<prefix>/lib -Xlinker -lkomira_native` |
| B1 | `mojo build --runpath='$ORIGIN/../lib'`, the program in `<prefix>/bin`, run with `LD_LIBRARY_PATH` unset; it must NEED `libkomira_native.so.1` |
| IR1 | as R1 (ours loaded at start through `-lkomira_native`), then the system `libcrypto.so.3` and `libssl.so.3` dlopened `RTLD_GLOBAL` and called: the library exports none of their names, the global scope resolves them to the system's, our calls still answer right, and the system `SSL_CTX_new` still works |
| IR2 | the order a host process (a Python interpreter, say) gives: the system OpenSSL loaded `RTLD_GLOBAL` and called first, then ours dlopened by path `RTLD_GLOBAL` and called through the handle (the program links nothing of ours); the same checks |

`:komira_native` is `:libkomira_native` with the run test as a check, so no
build of it succeeds while any of the three is red. The run test takes an
installed environment in place of the library (`prefix`), a program other
than `native_run` (`program`) and per_library archives to link after the
library (`link`): the installed run tests above. The library is built for linux
x86_64 only (an ELF version script; aws-lc's assembly).
