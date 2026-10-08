# Native code in conda packages: each library ships its own

Status: plan, not built. It replaces the plan of one shared library for all of komira's C
(#681 and the PRs stacked on it). Each item is marked **EXISTS** (with the path that does it) or
**PROPOSED**. "On #NNN" means the code is on that open pull request and not on `main`.

Platform scope: linux-64 (ELF) only. SONAME, RUNPATH, version scripts and `-Bsymbolic` below are ELF
terms. Mach-O (osx-arm64: install names, `@rpath`, exported-symbol lists, the two-level namespace) is
a later design.

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
  `local: *`. Consequence: an owner's export list, and so its artifact's bytes, depend on its
  reverse dependencies, and a consumer's own Mojo code cannot call an aws-lc function that no komira
  package calls. That is intended: the exported surface is what komira tests. Adding a caller
  changes the owner's artifact in the same release.
- **`-Bsymbolic`:** each library binds its own references to its own definitions, so nothing
  loaded earlier can interpose on them.
- **The checks, per library:**
  - every export starts `komira_`;
  - the exports equal the generated list, and an independent list agrees with it: #681's call-site
    reader (the `external_call` names) united with the undefined dynamic symbols of each dependent
    komira `.so`, read from that `.so`'s own `dynsym`. The cross-`.so` imports are an input to the
    check, not an exception to it: komira_crypto's list includes the aws-lc names s2n-tls needs
    because http_core's linked `.so` says so;
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

Other shims hold process state too: komira_async's CAS gate and shutdown flag, komira_async_api's
pool depth, komira_metrics's EA flag, komira_scan_source's in-memory id counter. They hold no Mojo
struct, so sharing them is safe, and it is intended: installed, each is **one copy per process**
(in its owner's `.so`), while welded tests keep a static copy per image, as today.

**Today:**

- #685 ships the holder as `lib/libkomira_log_holder.a` and links it into each built program.
- It also states that a program whose closure holds komira_log must be built, not run with
  `mojo run`. komira_async depends on komira_log, so this covers most libraries with native code.

**Options (open decision 2):**

- **(A)** Ship `libkomira_log_holder.a` for `mojo build` (linked as `-lkomira_log_holder`, as on
  #685), and also `libkomira_log_holder_jit.so.1`, used only by `mojo run`. A JIT process is one
  image. Requirements:
  - The `.so` needs a **second compile of the shim with exported accessors**: the shipped archive's
    accessors are `KOMIRA_SHIM_LOCAL` (hidden), so a `.so` linked from it exports nothing and the JIT
    fails with "Symbols not found". The per-library export check lists the three accessors for this
    one artifact.
  - The **link name differs** (`komira_log_holder_jit`), and no `libkomira_log_holder.so` exists, so
    `-lkomira_log_holder` can only pick the archive. A `mojo build` image never names the JIT object
    by accident; two built images (a program and a consumer's Mojo shared library) each get their own
    hidden cells.
  - The two builds stay out of one image because each path names only one: `mojo run` cannot link
    the archive, and `mojo build` flags name only `-lkomira_log_holder`. Probe 3's LOG2 checks that
    a built image has no `NEEDED` on the JIT object; kci's install check refuses any installed
    `.so` with `NEEDED` on it.
- **(B)** Change the holder to keep one slot per image, keyed by an address private to that image,
  and ship it as an ordinary `.so`. This is a change to komira_log and needs a Mojo-safety review.
- **(C)** Keep #685's rule: no `mojo run` for these libraries. Then gamma cannot validate them
  through `mojo run`.

Recommendation: **(A)**, pending probe 3.

## System codecs (dlopened)

These stay as they are on #685. That code is not on `main`; `main`'s packer refuses every library that
links C.

- Each codec is opened at first use by soname, with `OwnedDLHandle`, by the library that owns it.
  **EXISTS:** zstd, bz2 and lzma in `src/komira_compression/codec_libraries.mojo`; `libz.so.1` in
  `src/komira_zlib/zlib_ffi.mojo`; `liblz4.so.1` in `src/komira_lz4/codec.mojo`.
- A library declares the sonames it opens (`mojo_library(dlopen = [...])`), and its package requires
  the conda-forge package that ships each one.
  **On #685:** `tools/build/package/system_libs.bzl` maps the declarations; the packer
  (`komira_pack conda`, which reads the sources) refuses a declaration that does not match them.
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
  `depends` graph, dependents first.
- **One owner, checked:** every C archive a package's closure links is shipped by exactly one package
  in its requirement closure. kci cannot infer "links C" from conda metadata, so the packer records
  it (PROPOSED keys in the komira metadata file, beside `lib_files`): `native_links`, the archives
  the library's closure links, and `native_owns`, the archives its own `.so` holds. komira_uuid
  lists aws-lc in `native_links` and owns nothing; it passes because komira_crypto is in its
  requirement closure.
- **komira_log:** with option (A), also link `-lkomira_log_holder_jit` for `mojo run`.
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
- **On #685:** `:installed_crypto_run_test` repeats R1 and B1, and `:installed_log_run_test` repeats
  B1 only (`mojo run` cannot link the holder archive), from packages installed by their
  requirements.

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
| B1 | R1's checks under `mojo build` into `<prefix>/bin`, the three `-l` flags, run path `$ORIGIN/../lib`, `LD_LIBRARY_PATH` unset |
| B2 | a built program that calls only http_core entry points (s2n init, a TLS connection) and names only `-lkomira_http_core_native`: crypto is found through http_core's run path |
| B3 (must fail) | B2 with http_core's RUNPATH removed: the load fails naming `libkomira_crypto_native.so.1` |
| IR1, IR2 | R1 and B1 beside a system OpenSSL loaded `RTLD_GLOBAL`, before and after ours: no interposition |
| ONE | the aws-lc reached from komira_crypto's call and from s2n-tls is one copy (`dladdr` of a `komira_awslc_` function seen from both sides names one file) |
| LOG1 | option (A): `-lkomira_log_holder_jit` under `mojo run`; the archive under `mojo build` |
| LOG2 | a built program and a Mojo shared library, both linked with `-lkomira_log_holder`: neither has `NEEDED` on the JIT object, and each reads its own engine |

## What happens to each open PR

| PR | fate |
|---|---|
| #672 symbol prefixing | **Keep.** Merged; `tools/build/native/` on `main`. Every per-library `.so` relies on it. |
| #681 one `libkomira_native.so.1` | **Superseded.** Its `native_archive` with `shared` and `per_library` kinds (`tools/build/native/defs.bzl`), export generator, call-site reader, link script, checks, `elfsyms dynsym` and run test survive, reworked from one library to one per owner. |
| #685 packer | **Reworked.** Survives: #685's extension of `native_archive` (forwarded providers, the `name` field), a library's `lib_files`, `dlopen` with `system_libs.bzl` and its drift check, "welded tests link the archives", and `conda_prefix` installed run tests. Superseded: `members.bzl` (ownership is declared on each library), `conda_native_package` and the `komira_native` requirement. |
| #695 kci reads kind `native` | **Reworked.** Survives, generalized from the `native` kind to library packages: the `lib_files` parser in `src/kci_release_set/conda_metadata.mojo` (`LibFile` and link rows, `has_lib_files`) and its PUBLISH checks in `src/kci_publish/verify.mojo`; #704's `native_link_args` reads it. Goes: the `native` kind and `is_native`. |
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
`tools/build/mojo/defs.bzl`). Symbol prefixing (#672) separates its aws-lc, s2n-tls and snappy from
a system OpenSSL only. Against the per-library `.so` files above it does nothing: both carry the same
`komira_awslc_`, `komira_s2n_` and `komira_snappy_` names. `mojo_shared_lib` links with no
`-Bsymbolic` and adds a version script only with `exports_exact = True` (default False), so by
default the engine exports those names and its own calls can bind to an earlier-loaded per-library
copy: two aws-lc instances interposing. The engine is safe beside the per-library `.so` files only
if it hides its C (`exports_exact`, or a version script plus `-Bsymbolic`, as each per-library `.so`
does). Its design must require that.
