# Native code in conda packages: each library ships its own

Status: plan, not built. It replaces the plan of one shared library for all of komira's C
(#681 and the PRs stacked on it). Each item is marked **EXISTS** (with the path that does it) or
**PROPOSED**. "On #NNN" means the code is on that open pull request and not on `main`.

## Decision summary

1. A Mojo library that owns C code ships that code as **its own shared library, in its own conda
   package**, next to its `.mojoc`. There is no package that holds everyone's C.
2. Dependencies between these shared libraries follow the library graph: a library's `.so` has a
   `DT_NEEDED` entry for the `.so` of each library whose C it calls.
3. The vendored C libraries are symbol-prefixed, so any number of them can share a process with a
   system copy (a `libcrypto.so.3`, say). **EXISTS:** [tools/build/native/README.md](../../tools/build/native/README.md)
   (aws-lc, s2n-tls, snappy).
4. Shared libraries only. Static archives are not shipped, except C that holds per-library state
   (komira_log's holder, below). Reason: `mojo run` (the JIT) does not link a static archive, and a
   library that only works under `mojo build` cannot pass a README run.
5. Codecs that are system libraries stay out: they are opened by soname and required from
   conda-forge.
6. The engine library that the Python and TypeScript SDKs load is a separate artifact. It is out of
   scope here (last section).

## What each library ships

Every owned C archive below **EXISTS** today as a `cxx_library` listed in
[tools/build/one_definition/libraries.bzl](../../tools/build/one_definition/libraries.bzl)
(`SRC_C_LIBRARIES` and `THIRD_PARTY_C_LIBRARIES`). Each **artifact** is **PROPOSED**. The name form
is `lib<library>_native.so.1`, plus the link name `lib<library>_native.so` (a symbolic link).

| library | native code it owns | artifact | native dependencies (`DT_NEEDED`) |
|---|---|---|---|
| komira_crypto | aws-lc, prefixed `komira_awslc_`; `komira_crypto_sha256_hw` (the exported SHA-NI wrapper) | `libkomira_crypto_native.so.1` | glibc only |
| komira_http_core | s2n-tls, prefixed `komira_s2n_`, built against the prefixed aws-lc | `libkomira_http_core_native.so.1` | `libkomira_crypto_native.so.1` |
| komira_compression | snappy (C API prefixed `komira_snappy_`; its C++ runtime linked static and kept local) | `libkomira_compression_native.so.1` | glibc only; opens system codecs at run time (below) |
| komira_libc | `komira_libc_posix` | `libkomira_libc_native.so.1` | glibc only |
| komira_async | `komira_async_posix` | `libkomira_async_native.so.1` | glibc only |
| komira_async_api | `komira_concurrency_pool_depth` | `libkomira_async_api_native.so.1` | glibc only |
| komira_fs | `komira_fs_posix` | `libkomira_fs_native.so.1` | glibc only |
| komira_objectstore | `komira_objectstore_posix` | `libkomira_objectstore_native.so.1` | glibc only |
| komira_metrics | `komira_metrics_ea_flag` | `libkomira_metrics_native.so.1` | glibc only |
| komira_scan_source | `komira_scan_source_inmem_id` | `libkomira_scan_source_native.so.1` | glibc only |
| komira_supervisor | `komira_supervisor_proc` | `libkomira_supervisor_native.so.1` | glibc only |
| komira_log | `komira_log_holder` (per-library state) | `libkomira_log_holder.a`, see below | none |
| komira_parquet_codec | the brotli decoder, **unprefixed** today | after it is prefixed: `libkomira_parquet_codec_native.so.1` | glibc only |
| komira_db_sqlite | SQLite, **unprefixed** today | none until it has welded tests (it has no conda package) | |

**One owner per vendored library (PROPOSED).** A library that calls another library's C goes through
that owner's `.so`; it does not link a second copy:

- komira_uuid declares aws-lc's `RAND_bytes` itself (**EXISTS:** `src/komira_uuid/BUCK`, a dependency on
  `//third_party/aws-lc:crypto`). Its package would require komira_crypto.
- komira_http_client calls `komira_s2n_*` and already depends on komira_http_core.
- komira_objectstore links `//src/komira_fs:komira_fs_posix` directly. Its package would require
  komira_fs.

So a package's run requirements are its Mojo dependencies plus the owners of the C it calls. That
is how komira_http_core comes to require komira_crypto, which its Mojo `deps` do not list.

The one-definition gate stays as it is (**EXISTS:** `tools/build/one_definition/`). It catches a C
symbol defined twice across all archives, whichever `.so` each archive ends up in.

## How each shared library is linked (PROPOSED, generalizing #681)

#681 links one library with `--whole-archive`, `-Bsymbolic`, `--gc-sections`, `-z defs` and a
generated version script (on #681: `tools/build/native/native_link.sh`, `native_exports.sh`,
`native_check.sh`, `callsites.c`). Per library, the same steps:

- **Contents:** the archives the library owns, linked whole. A dependency's archives are not
  linked in; they are reached through `DT_NEEDED`.
- **SONAME:** `lib<library>_native.so.1`. Every package of a release is pinned to the same version
  and build string, so `.1` does not change until symbol versioning is decided.
- **RUNPATH:** `$ORIGIN` when the library has a komira `DT_NEEDED`. A program's run path is not used
  to find its dependencies' dependencies, so `libkomira_http_core_native.so.1` must find
  `libkomira_crypto_native.so.1` by its own run path. A library with no komira `DT_NEEDED` gets no run
  path, as #681's check requires today.
- **Version script, generated:** export the names that `external_call` passes in any package whose
  closure reaches this owner, plus the names a dependent `.so` leaves undefined that this one
  defines (s2n-tls needs many aws-lc functions that Mojo never calls). Everything else is
  `local: *`.
- **`-Bsymbolic`:** each library binds its own references to its own definitions, so nothing
  loaded earlier can interpose on them.
- **The checks, per library:**
  - every export starts `komira_`;
  - the exports equal the generated list, and #681's independent call-site reader agrees with it;
  - `NEEDED` is glibc plus the declared komira owners, and nothing else;
  - the SONAME and RUNPATH are as above.

## Linking from Mojo

A `.mojoc` holds no machine code (**EXISTS:** the refusal text in `tools/build/mojo/defs.bzl`,
`_conda_facts`). Mojo code is compiled into the consumer's program, and only C is in the `.so` files,
so each native package in the closure must be named at the consumer's link. Below, `<env>` is the
conda environment. Each `-l` names one native package of the program's closure, dependents first.

**`mojo run` (the JIT):**

```sh
mojo run -Xlinker -L<env>/lib \
    -Xlinker -lkomira_http_core_native -Xlinker -lkomira_crypto_native \
    -Xlinker -lkomira_libc_native prog.mojo
```

**`mojo build`:** the same `-L` and `-l` flags, plus a run path for the installed layout:

```sh
mojo build -Xlinker -L<env>/lib \
    -Xlinker -lkomira_http_core_native -Xlinker -lkomira_crypto_native \
    -Xlinker -lkomira_libc_native \
    -Xlinker -rpath -Xlinker '$ORIGIN/../lib' prog.mojo -o <env>/bin/prog
```

- **One library, proven (on #681's run test):** `mojo run -Xlinker -L<prefix>/lib -Xlinker -lkomira_native`,
  and `mojo build` with the run path `$ORIGIN/../lib`. There the run path was set through the build
  wrapper's `--runpath` (**EXISTS:** `tools/build/mojo/mojo_wrapper.sh`).
- **Not proven:** the `-Xlinker -rpath` spelling a user writes with conda's `mojo`, and the
  multi-library form.

**Welded tests and the README gate do not change.** They link the static archives of their closure
(**EXISTS:** `_link_tail` in `tools/build/mojo/defs.bzl`). #685 records why they must not also
link a shared copy: a test hook set in one copy is not read by the other. The installed packages are
what the gamma validation below tests.

## Per-library state: komira_log's holder

`src/komira_log/engine/_log_holder_shim.c` (**EXISTS**) holds three one-word cells: the address of
the process's logging engine, the address of its configuration, and its line layout. The engine is a
Mojo struct, and only the image that compiled it may read it. The accessors are therefore hidden,
and each image that links the archive gets its own cells: **one engine per library**. An "image"
here is a program or a Mojo shared library.

Per-package `.so` files contain only C, so this concern is confined to the holder. If the holder were
an ordinary shared `.so`, two Mojo images in one process would share its cells. The second image's
install would do nothing, and that image would read the first image's struct. This is the type
confusion the file's header describes.

**Today:**

- #685 ships the holder as `lib/libkomira_log_holder.a` and links it into each built program.
- It also states that a program whose closure holds komira_log must be built, not run with
  `mojo run`. komira_async depends on komira_log, so this covers most libraries with native code.

**Options (open decision 2):**

- **(A)** Ship `libkomira_log_holder.a` for `mojo build`, linked as `-l:libkomira_log_holder.a`, and
  also `libkomira_log_holder.so.1`, used only by `mojo run`. A JIT process is one image. A Mojo
  shared library built by komira's rules links the archive, hidden, and never the `.so`.
- **(B)** Change the holder to keep one slot per image, keyed by an address private to that image,
  and ship it as an ordinary `.so`. This is a change to komira_log and needs a Mojo-safety review.
- **(C)** Keep #685's rule: no `mojo run` for these libraries. Then gamma cannot validate them
  through `mojo run`.

Recommendation: **(A)**, pending probe 3.

## System codecs (dlopened)

These stay as they are on #685. That code is not on `main`; `main`'s packer refuses every library that
links C.

- zstd, zlib, lz4, bz2 and lzma are opened at first use by soname.
  **EXISTS:** `src/komira_compression/codec_libraries.mojo`, using `OwnedDLHandle`.
- A library declares the sonames it opens (`mojo_library(dlopen = [...])`), and its package requires
  the conda-forge package that ships each one.
  **On #685:** `tools/build/package/system_libs.bzl`, which also refuses a declaration that does not
  match the sources.
- kci accepts exactly those requirements, byte-equal (**merged into #704 from #763:**
  `src/kci_release_set/system_libs.mojo`).

None of these libraries is prefixed or linked; each is loaded from the environment's `lib/`.

## Validation in gamma (PROPOSED)

gamma's validations install what gamma published from the channel, as a consumer gets it, and run
each README with `mojo run` (`docs/ci.md`, Validations).

- **Link flags, on #704:** kci_validate already builds them from metadata
  (`src/kci_validate/container.mojo`, `native_link_args`): `-Xlinker -L<env>/lib`, then
  `-Xlinker -l<x>` for each `lib/lib<x>.so` row of a pin's `lib_files`. Today it reads only the single
  native package.
- **The change:** read every installed library's `lib_files`, and order the `-l` flags by the
  `depends` graph, dependents first. Refuse a library whose closure links C but whose package ships
  no `.so`.
- **komira_log:** with option (A), also link `libkomira_log_holder.so` for `mojo run`.
- **A new install check:** for each installed `.so`, `NEEDED` resolves inside the environment with
  `LD_LIBRARY_PATH` unset. This catches a missing `$ORIGIN` run path or a missing package requirement.

## What the evidence covers, and probe 3

**Proven:**

- **Probe 2** (komira branch `exp/native-probe-2`, `tests/native_probe2/`, never merged) and
  **#681's run test** (`:komira_native_run_test`, cases R1, B1, IR1 and IR2). Together they prove that,
  for **one** shared library holding aws-lc, s2n-tls, snappy and the shims, prefixing plus a
  version script plus `-Bsymbolic` gives no interposition in either direction beside a system
  `libcrypto.so.3` and `libssl.so.3`, in either load order.
- **The leaky control** (unprefixed, no version script, no `-Bsymbolic`) crashes the system's
  `SSL_CTX_new`.
- `mojo run -l` and `mojo build` with `$ORIGIN/../lib` work for that one library.
- **On #685:** `:installed_crypto_run_test` and `:installed_log_run_test` repeat R1 and B1 from
  packages installed by their requirements.

**Not proven:**

- several komira `.so` files in one process;
- a `DT_NEEDED` from one komira `.so` to another, found through `$ORIGIN`;
- the JIT loading more than one `-l` library;
- a single aws-lc per process when two packages reach it.

**Probe 3 (PROPOSED: a farm target, never merged).** Three libraries, each linked as above:
`libkomira_crypto_native.so.1` (aws-lc and the SHA-NI wrapper), `libkomira_http_core_native.so.1` (s2n-tls,
`NEEDED` crypto, RUNPATH `$ORIGIN`) and `libkomira_libc_native.so.1`. The cases:

| case | what it shows |
|---|---|
| R1 | `mojo run` with the three `-l` flags in dependency order: SHA-256, AES-GCM, s2n init and a TLS 1.3 client connection |
| R2 | R1 with the `-l` flags in reverse order |
| B1 | `mojo build` into `<prefix>/bin`, run path `$ORIGIN/../lib`, `LD_LIBRARY_PATH` unset; the program names only `libkomira_http_core_native` and crypto is found through that library's run path |
| B2 (must fail) | B1 with http_core's RUNPATH removed: the load fails naming `libkomira_crypto_native.so.1` |
| IR1, IR2 | R1 and B1 beside a system OpenSSL loaded `RTLD_GLOBAL`, before and after ours: no interposition |
| ONE | the aws-lc reached from komira_crypto's call and from s2n-tls is one copy (`dladdr` of a `komira_awslc_` function seen from both sides names one file) |
| LOG | option (A): the holder `.so` under `mojo run`, the archive under `mojo build` |

## What happens to each open PR

| PR | fate |
|---|---|
| #672 symbol prefixing | **Keep.** Merged; `tools/build/native/` on `main`. Every per-library `.so` relies on it. |
| #681 one `libkomira_native.so.1` | **Superseded.** Its export generator, call-site reader, link script, checks, `elfsyms dynsym` and run test survive, reworked from one library to one per owner. |
| #685 packer | **Reworked.** Survives: `native_archive` with `shared` and `per_library` kinds, a library's `lib_files`, `dlopen` with `system_libs.bzl` and its drift check, "welded tests link the archives", and `conda_prefix` installed run tests. Superseded: `members.bzl` (ownership is declared on each library), `conda_native_package` and the `komira_native` requirement. |
| #695 kci reads kind `native` | **Superseded.** There is no `native` kind; kci reads the `.so` rows of a library's `lib_files`. |
| #704 kci_validate, release-set native slot | **Reworked.** The native member and its slot go. `native_link_args` survives, taken over every library pin in dependency order. |
| #761 (merged into #704) | **Partly survives.** The library declarations stay; the `komira_native` member goes. |
| #763 (merged into #704) | **Survives:** kci accepts the conda-forge system-library requirements. **Generalized:** `-lkomira_native` becomes one `-l` per native package. |

## Open decisions for the CEO

1. **Per-package shared libraries, no static archives except per-library state.**
   Recommended: yes.
2. **komira_log's holder under `mojo run`:** (A), (B) or (C) above. Recommended: (A), confirmed by
   probe 3.
3. **The `.so` in the library's own package, or in a separate `<library>_native` package** that the
   SDK engine could also require. Recommended: the library's own package; split later only if
   something needs the C without the Mojo.
4. **Prefix brotli (and SQLite) before komira_parquet_codec (and komira_db_sqlite) ship.** Recommended:
   yes, by the mechanism in `tools/build/native/`. An unprefixed exported `BrotliDecoder*` would
   interpose on a system `libbrotlidec`.
5. **Order of work.** Recommended:
   1. probe 3;
   2. the per-library link rule and its checks;
   3. the packer;
   4. kci.

   #681 through #704 stay on hold until this plan is approved.

## Out of scope: the SDK engine library

The Python and TypeScript SDKs will load one komira engine shared library. It is not built yet
(`docs/index.md`: the shared-library ABI is "coming with `komira_so`"). It is a separate artifact with
its own design, and this plan does not decide it. The rule that builds a Mojo shared library,
`mojo_shared_lib`, links C archives into the library itself (**EXISTS:** `force_load` in
`tools/build/mojo/defs.bzl`). Symbol prefixing (#672) protects that library too: its aws-lc, s2n-tls
and snappy carry `komira_*` names, so it can share a process with a system OpenSSL, or with the
per-library `.so` files above, without binding to their functions.
