# Native code in conda packages: each library ships its own

Status: plan, not built. It replaces the plan of one shared library for all of komira's C
(#681 and the PRs stacked on it). Each item is marked **EXISTS** (with the path that does it) or
**PROPOSED**. "On #NNN" means the code is on that open pull request and not on `main`. Scope:
linux-64 (ELF) only; Mach-O (osx-arm64: install names, `@rpath`, exported-symbol lists, the two-level
namespace) is a later design.

## Decision summary

1. A Mojo library that owns C ships it as **its own shared library, in its own conda package**, next
   to its `.mojoc`. No package holds everyone's C.
2. A library's `.so` has a `DT_NEEDED` on the `.so` of each library whose C it calls.
3. aws-lc, s2n-tls and snappy are symbol-prefixed to share a process with a system copy (**EXISTS:**
   [tools/build/native/README.md](../../tools/build/native/README.md)); brotli and SQLite are not yet
   (open decision 4).
4. Shared libraries only; no static archives except C holding per-library state (komira_log's
   holder). `mojo run` (the JIT) links no static archive, and a README run must pass.
5. System-library codecs stay out: opened by soname, required from conda-forge.
6. The SDK engine library is a separate artifact, out of scope (last section).

## What each library ships

Every owned C archive below **EXISTS** today as a `cxx_library` listed in
[tools/build/one_definition/libraries.bzl](../../tools/build/one_definition/libraries.bzl)
(`SRC_C_LIBRARIES` and `THIRD_PARTY_C_LIBRARIES`). Each artifact is **PROPOSED**, named
`lib<library>_native.so.1` plus the unversioned link name `lib<library>_native.so` (a symbolic link).
"glibc" means `NEEDED` on glibc only.

| library | native code it owns | artifact | `DT_NEEDED` |
|---|---|---|---|
| komira_crypto | aws-lc, prefixed `komira_awslc_`; `komira_crypto_sha256_hw` (the SHA-NI wrapper) | `libkomira_crypto_native.so.1` | glibc |
| komira_http_core | s2n-tls, prefixed `komira_s2n_`, built against the prefixed aws-lc | `libkomira_http_core_native.so.1` | `libkomira_crypto_native.so.1` |
| komira_compression | snappy (C API prefixed `komira_snappy_`; its C++ runtime static and local) | `libkomira_compression_native.so.1` | glibc; opens system codecs (below) |
| komira_libc / async / async_api / fs | `komira_libc_posix` / `komira_async_posix` / `komira_concurrency_pool_depth` / `komira_fs_posix` | `libkomira_<lib>_native.so.1` | glibc |
| komira_objectstore / metrics / scan_source / supervisor | `komira_objectstore_posix` / `komira_metrics_ea_flag` / `komira_scan_source_inmem_id` / `komira_supervisor_proc` | `libkomira_<lib>_native.so.1` | glibc |
| komira_log | `komira_log_holder` (per-library state) | `libkomira_log_holder.a`; with decision 2 (A) also `libkomira_log_holder_jit.so.1` and its link name `libkomira_log_holder_jit.so` | none |
| komira_parquet_codec | the brotli decoder, **unprefixed** today | once prefixed: `libkomira_parquet_codec_native.so.1` | glibc |
| komira_db_sqlite | SQLite, **unprefixed** today | none until it has welded tests (no conda package) | |

**One owner per C archive (PROPOSED).** A caller of another library's C goes through that owner's
`.so`, never a second copy. Vendored: komira_uuid declares aws-lc's `RAND_bytes` (**EXISTS:**
`src/komira_uuid/BUCK`, a dependency on `//third_party/aws-lc:crypto`), so it requires komira_crypto;
komira_http_client calls `komira_s2n_*` via komira_http_core; komira_objectstore links
`//src/komira_fs:komira_fs_posix`, so it requires komira_fs. First-party shims too:
`komira_on_pool_depth` (komira_async_api's) from komira_async and komira_column_kernels, and
`komira_libc_posix` from several. `callers` and the completeness lint count library sources only,
never `test_srcs` (welded tests link the archives). These callers already list the owner in their Mojo `deps`, but each still belongs in the owner's
`callers`, and the completeness lint covers them. Run requirements = Mojo dependencies plus owners of
the C called; that is how komira_http_core requires komira_crypto.

**Duplicate definitions.** The one-definition gate stays (**EXISTS:** `tools/build/one_definition/`)
for a strong symbol defined twice (the linker's duplicate-symbol error). A weak or common pair raises no
error and, per owner, no export generator sees both archives: the root completeness lint (PROPOSED),
which reads every archive, refuses one defined in two owners' archives.

## How each shared library is linked (PROPOSED, generalizing #681)

#681 links one library with `--whole-archive`, `-Bsymbolic`, `--gc-sections`, `-z defs` and a
generated version script (on #681: `tools/build/native/native_link.sh`, `native_exports.sh`,
`native_check.sh`, `callsites.c`). Per library:

| step | rule |
|---|---|
| contents, SONAME | the library's own archives, linked whole (dependencies' via `DT_NEEDED`); SONAME `lib<library>_native.so.1`, stable because a release pins every package to one version and build string, until symbol versioning is decided |
| `DT_RUNPATH` | `$ORIGIN` when the library has a komira `DT_NEEDED`, relaxing #681's `native_check.sh`, which refuses any run path; none otherwise. A program's `DT_RUNPATH` is not searched for its dependencies' dependencies (a `DT_RPATH` would be), so http_core's `.so` must find crypto's by its own |
| callers, declared | an owner's export list depends on its reverse dependencies, which a Buck2 target cannot discover, so each owner declares its `callers` (Mojo libraries and dependent owners' archives), as #681's `komira_native` rule does (`ctx.attrs.callers`). This replaces #685's central `members.bzl` |
| completeness lint | a root target reads every `mojo_library` from the build graph (as `//:src_layout` does) and every owner archive, runs the call-site reader, and refuses an `external_call` into an owner by a library its `callers` omits, and a cross-owner weak/common pair. Without it a new caller passes its welded tests (static archives) and fails only at a consumer's link |
| version script | generated before any link: the callers' `external_call` names, plus the dependent archives' undefined symbols (their `symtab`, minus what they define) that this owner defines (s2n-tls needs many aws-lc functions Mojo never calls); everything else `local: *`. Inputs are archives and sources, never a linked `.so`: generate every list, link each owner before its dependents (`-z defs` against the owners' `.so`), then validate. A consumer cannot call an aws-lc function no komira package calls; the exported surface is what komira tests. A new caller changes the owner's artifact in the same release |
| `-Bsymbolic` | each library binds its own references to its own definitions, so nothing loaded earlier can interpose on them |

**Checks, per library:**

1. every export starts `komira_`, and the exports equal the generated list;
2. after the dependents link, a separate action checks the other side: the callers' `external_call`
   names, united with the undefined `komira_` symbols in each dependent `.so`'s `dynsym`, are all
   exported (a subset check: `--gc-sections` may drop s2n-tls code the `.so` never reaches);
3. every **strong** undefined `komira_` symbol is exported by a declared `NEEDED` owner (replacing
   #681's "any strong undefined `komira_` is red", which http_core cannot meet). Weak undefined ones
   are allowed only if listed: aws-lc's four `komira_awslc_OPENSSL_memory_*` allocator hooks, undefined
   by design (**EXISTS:** `extra_symbols` in the native README; #681's `native_check.sh` exempts weak
   undefined symbols too). `-Bsymbolic` does not bind an undefined symbol, so any loaded object
   exporting such a definition would install allocator hooks into komira_crypto's aws-lc; probe 3's ONE
   and IR cases assert the hooks stay unbound;
4. `NEEDED` is glibc plus the declared komira owners, nothing else; SONAME and `DT_RUNPATH` as above.

## Linking from Mojo

A `.mojoc` holds no machine code (**EXISTS:** refusal text in `tools/build/mojo/defs.bzl`,
`_conda_facts`), so Mojo is compiled into the consumer and every native package of the closure is named
at its link. `DT_NEEDED` does not cover a call made from Mojo: komira_http_core's TLS init calls komira_async's `komira_ignore_sigpipe`
(`tls/s2n_shim.mojo` imports `ignore_sigpipe`), yet s2n-tls's `.so` has no reason to need komira_async's.
A program using komira_http_core needs eight owners (http_core, crypto, async, async_api, metrics,
compression, scan_source, libc) plus komira_log's holder. Below, `<env>` is the conda environment and
`-lA ... -lH` those owners, dependents first, each behind `-Xlinker`:

```sh
mojo run   -Xlinker -L<env>/lib -lA ... -lH -Xlinker -lkomira_log_holder_jit prog.mojo
mojo build -Xlinker -L<env>/lib -lA ... -lH -Xlinker -lkomira_log_holder \
    -Xlinker -rpath -Xlinker '$ORIGIN/../lib' prog.mojo -o <env>/bin/prog
```

Proven for one library (#681's run test): `mojo run -Xlinker -L<prefix>/lib -Xlinker -lkomira_native`,
and `mojo build` with run path `$ORIGIN/../lib` set through the build wrapper's `--runpath` (**EXISTS:**
`tools/build/mojo/mojo_wrapper.sh`, which forces `--enable-new-dtags` and drops every user `-rpath` in
any spelling). So the user-spelled `-Xlinker -rpath` with conda's `mojo` (and whether it writes
`DT_RUNPATH` or `DT_RPATH`) stays **unproven even after probe 3**, which builds through the same
wrapper. gamma today runs READMEs with `mojo run` only (#704's kci_validate never calls `mojo build`),
so the whole `mojo build` consumer path is unproven until gamma's proposed build row (below) exists. Probe 3 covers the multi-library form and whether a
program needs an owner its closure reaches but never calls (naming every owner is the safe rule).

**Where a user gets these flags (open decision 5).** kci_validate computes them from metadata and
injects them (on #704: `native_link_args`), so a README run passes with flags the README never shows,
and a user who copies the README fails with "Symbols not found". This per-package burden is the main
usability cost of decision 1. No build-time gate can catch a missing flag: the welded README gate
compiles the README's Mojo examples into one program linked against the closure's static archives
(**EXISTS:** `_readme_gate`, `_link_tail` in `tools/build/mojo/defs.bzl`) and runs no shell command, and
the build has no installed `.so`. The only check that can is gamma's installed-package README run.

**(a)** the packer writes the exact commands into each README as a fenced `sh` block, the readme tool
parses it, and gamma's run and build rows use those flags instead of its own `native_link_args` (or
refuse when they differ), so a missing flag fails gamma; **(b)** a pkg-config `.pc` per package with `Requires:`; **(c)** a
`komira link-flags <package>` helper. Recommended: (a) with that readme-tool and kci change, (b) when a
second consumer needs it; both read the metadata kci reads.

Welded tests and the welded README gate do not change: they link static archives (`_link_tail`), and
#685 records why they must not also link a shared copy (a test hook set in one copy is unread by the other).

## Per-library state: komira_log's holder

`src/komira_log/engine/_log_holder_shim.c` (**EXISTS**) has twelve `KOMIRA_SHIM_LOCAL` (hidden)
accessors: the engine holder (`komira_log_holder_set`, `_get`, `_get_engine`, `_clear`), the
configuration (`komira_log_config_holder_set`, `_get`, `komira_log_holder_get_config`), the layout
(`komira_log_layout_set`, `_get`) and the worker-id thread-local (`komira_log_tls_key_create`, `_set`,
`_get`, used by `engine/worker_id_tls.mojo`). The engine is a Mojo struct that only the image which
compiled it may read, so each image (a program or a Mojo shared library) that links the archive gets
its own cells and creates its own pthread key: **one engine per library**. As an ordinary shared `.so`,
two Mojo images would share the cells; the second install would do nothing and that image would read
the first's struct, the type confusion the file's header describes.

Other shims hold process state with no Mojo struct (komira_async's CAS gate and counters,
komira_libc's mmap counters, komira_objectstore's test fault hooks, and the like). Installed, each is
intentionally **one copy per process** in its owner's `.so`; welded tests keep a static copy per image,
and test hooks stay exercised only there (the two-copy hazard #685 named).

**Today (on #685):** `lib/libkomira_log_holder.a` is linked into each built program, and a closure
holding komira_log (most native libraries, through komira_async) must be built, not `mojo run`.

**Options (open decision 2):**

| option | what | requirements and cost |
|---|---|---|
| **(A)** | ship `libkomira_log_holder.a` for `mojo build` (`-lkomira_log_holder`, as on #685) and, for `mojo run` only, `libkomira_log_holder_jit.so.1` with its unversioned link name `libkomira_log_holder_jit.so`. A JIT process is one image | a second compile of the shim with all twelve accessors exported (a `.so` linked from the hidden archive exports nothing: "Symbols not found"); the export check lists the twelve for this artifact. No `libkomira_log_holder.so` exists, so `-lkomira_log_holder` can only pick the archive, and a built image (program or consumer Mojo shared library) never names the JIT object; each gets its own hidden cells and pthread key. Probe 3's LOG2 checks no built image has `NEEDED` on the JIT object; kci's install check refuses any installed `.so` that does |
| **(B)** | keep one slot per image, keyed by an address private to that image, shipped as an ordinary `.so` | a change to komira_log needing a Mojo-safety review; it must also decide whether the worker-id pthread key is per image |
| **(C)** | keep #685's rule: no `mojo run` for these libraries | gamma cannot validate them through `mojo run` |

Recommendation: **(A)**, pending probe 3.

## System codecs (dlopened)

As on #685 (`main`'s packer refuses every library that links C). Each codec is opened at first use
by soname, with `OwnedDLHandle`, by its owning library. **EXISTS:** zstd, bz2 and lzma in `src/komira_compression/codec_libraries.mojo`; `libz.so.1` in
`src/komira_zlib/zlib_ffi.mojo`; `liblz4.so.1` in `src/komira_lz4/codec.mojo`.

- A library declares the sonames it opens (`mojo_library(dlopen = [...])`) and its package requires the
  conda-forge package that ships each. **On #685:** `tools/build/package/system_libs.bzl` maps them;
  the packer (`komira_pack conda`, which reads the sources) refuses a declaration that does not match.
- kci accepts exactly those requirements, byte-equal (**merged into #704 from #763:**
  `src/kci_release_set/system_libs.mojo`).

Not proven: loading from the environment's `lib/` (#685's `packaging/conda/README.md` says it is
untested under a conda-installed `mojo run`, where the `dlopen` comes from JIT code in no ELF object).
Probe 3's DL case tests it.

## Validation in gamma (PROPOSED)

gamma installs what it published from the channel, as a consumer gets it, and today runs each README
with `mojo run` only (`docs/ci.md`, Validations). What kci must add:

| item | today | change |
|---|---|---|
| link flags | on #704, `native_link_args` (`src/kci_validate/container.mojo`): `-Xlinker -L<env>/lib`, then `-Xlinker -l<x>` per `lib/lib<x>.so` row of a pin's `lib_files`, single native package only | read every installed library's `lib_files`, order by the `depends` graph, dependents first; with option 5(a), use (or compare against) the README's flags |
| one owner | none | every C archive a closure links is shipped by exactly one package in its requirement closure. The packer records `native_links` (archives the closure links) and `native_owns` (archives its `.so` holds) beside `lib_files`; komira_uuid lists aws-lc in `native_links`, owns nothing, and passes because komira_crypto is in its closure |
| komira_log | none | option (A): also `-lkomira_log_holder_jit` under `mojo run` |
| `mojo build` run | none (`mojo run` only) | for each README program, also `mojo build ... -o <env>/bin/prog` with the README's flags, then run it with `LD_LIBRARY_PATH` unset: proves the user `-rpath` spelling, `DT_RUNPATH` vs `DT_RPATH`, the `-lkomira_log_holder` archive pick-up, and owners' `.so` found by run path |
| install check | none | each installed `.so`'s `NEEDED` resolves inside the environment with `LD_LIBRARY_PATH` unset (catches a missing `$ORIGIN` or package requirement) |

## What the evidence covers, and probe 3

**Proven.** Probe 2 (komira branch `exp/native-probe-2`, `tests/native_probe2/`, never merged) and
#681's `:komira_native_run_test` (R1, B1, IR1, IR2): for **one** `.so` holding aws-lc, s2n-tls, snappy
and the shims, prefixing plus a version script plus `-Bsymbolic` gives no interposition either way
beside a system `libcrypto.so.3`/`libssl.so.3`, in either load order, where the leaky control crashes
the system's `SSL_CTX_new`. On #685, `:installed_crypto_run_test` repeats R1 and B1 and
`:installed_log_run_test` B1, from installed packages.

**Not proven:** several komira `.so` files in one process; a `DT_NEEDED` between them found through
`$ORIGIN`; the JIT loading more than one `-l` library; one aws-lc per process when two packages reach
it; a system codec `dlopen`ed from the environment's `lib/` with `LD_LIBRARY_PATH` unset.

**Probe 3 (PROPOSED: a farm target, never merged).** Every owner of komira_http_core's closure, linked
as above (crypto with aws-lc and the SHA-NI wrapper; http_core with s2n-tls, `NEEDED` crypto,
`DT_RUNPATH` `$ORIGIN`), plus the holder archive and JIT object. R1 and B1 go through komira_http_core's
Mojo API and name every owner. Built cases go through `mojo_wrapper.sh`, so their run path is the
wrapper's `DT_RUNPATH`, not a user-spelled `-rpath`.

| case | what it shows |
|---|---|
| R1 | `mojo run`, closure `-l` flags in dependency order: SHA-256, AES-GCM, s2n init, a TLS 1.3 client connection |
| R2 | R1 with the `-l` flags reversed |
| B1 | R1's checks under `mojo build` into `<prefix>/bin`, same flags, run path `$ORIGIN/../lib`, `LD_LIBRARY_PATH` unset |
| B2 | a built program calling only `komira_s2n_*` by raw `external_call` (no komira Mojo import, like probe 2's knative module), naming only `-lkomira_http_core_native`: crypto found through http_core's `DT_RUNPATH` |
| R1-MISS (must fail) | R1 without `-lkomira_async_native`: fails, and the missing names include `komira_ignore_sigpipe`, the Mojo-to-C edge `DT_NEEDED` does not carry |
| B3 (must fail) | B2 with http_core's `DT_RUNPATH` removed: the load fails naming `libkomira_crypto_native.so.1` (relies on the program's path being `DT_RUNPATH`) |
| IR1, IR2 | R1 and B1 beside a system OpenSSL loaded `RTLD_GLOBAL`, before and after ours: no interposition; the `komira_awslc_OPENSSL_memory_*` hooks stay unbound |
| ONE | the aws-lc reached from komira_crypto and from s2n-tls is one copy (`dladdr` of a `komira_awslc_` function from both sides names one file); the weak hooks stay unbound |
| LOG1 | option (A): `-lkomira_log_holder_jit` under `mojo run`; the archive under `mojo build` |
| LOG2 | a built program and a Mojo shared library, both with `-lkomira_log_holder`: neither has `NEEDED` on the JIT object; each reads its own engine |
| DL | `libzstd.so.1` opened by komira_compression under `mojo run` and from a built program, `LD_LIBRARY_PATH` unset: the environment's copy loads |

## What happens to each open PR

| PR | fate |
|---|---|
| #672 symbol prefixing | **Keep.** Merged; `tools/build/native/` on `main`. Every per-library `.so` relies on it. |
| #681 one `libkomira_native.so.1` | **Superseded.** Its `native_archive` (`tools/build/native/defs.bzl`), export generator, `callers` attribute, call-site reader, link script, checks, `elfsyms dynsym` and run test survive, reworked to one library per owner. Kind `shared` becomes "in its owner's `.so`"; `per_library` becomes "ships a static archive". The undefined-symbol rule changes as in check 3 (strong only, listed weak hooks allowed). |
| #685 packer | **Reworked.** Survives: its extension of `native_archive` (forwarded providers, the `name` field), `lib_files`, `dlopen` with `system_libs.bzl` and its drift check, "welded tests link the archives", `conda_prefix` installed run tests. Superseded: `members.bzl` (by `callers` and the completeness lint), `conda_native_package`, the `komira_native` requirement. |
| #695 kci reads kind `native` | **Reworked.** Survives: the `lib_files` parser in `src/kci_release_set/conda_metadata.mojo` (`LibFile`, link rows, `has_lib_files`), which #704's `native_link_args` reads. Changes: the refusal of link rows on a library (on #704: "only the native package ships links") goes; each library package with C needs the `__glibc >=<floor>` requirement. Goes or generalizes to library packages: `_native_depends` in `src/kci_publish/verify.mojo` (guard plus exactly one `__glibc` floor, no Mojo), the `native` kind, `is_native`, the native case of `is_member_kind`. |
| #704 kci_validate, release-set native slot | **Reworked.** The native member and slot go. `native_link_args` survives over every library pin in dependency order, and with 5(a) defers to the README's flags. |
| #761 (merged into #704) | **Partly survives.** The library declarations stay; the `komira_native` member goes. |
| #763 (merged into #704) | **Survives:** kci accepts the conda-forge system-library requirements. **Generalized:** `-lkomira_native` becomes one `-l` per native package. |

## Open decisions for the CEO

1. **Per-package shared libraries, no static archives except per-library state.** Recommended: yes.
2. **komira_log's holder under `mojo run`:** (A), (B) or (C) above. Recommended: (A), confirmed by probe 3.
3. **The `.so` in the library's own package, or a separate `<library>_native` package** the SDK engine
   could also require. Recommended: the library's own; split only if something needs the C without the Mojo.
4. **Prefix brotli (and SQLite) before komira_parquet_codec (and komira_db_sqlite) ship.** Recommended:
   yes, by `tools/build/native/`. An unprefixed exported `BrotliDecoder*` would interpose on a system
   `libbrotlidec`.
5. **Where a user gets the link flags:** (a), (b) or (c) in "Linking from Mojo". Recommended: (a),
   which needs the readme tool to parse the README's command block and gamma's kci to use those flags
   in a `mojo run` and a new `mojo build` row; no build-time gate can check them.
6. **Order of work.** Recommended: probe 3; the link rule, checks and completeness lint; the packer;
   kci. #681 through #704 stay on hold until this plan is approved.

## Out of scope: the SDK engine library

The SDKs' engine shared library is not built yet (`docs/index.md`: the ABI is "coming with
`komira_so`") and has its own design. `mojo_shared_lib` links C archives into the library itself
(**EXISTS:** `force_load` in `tools/build/mojo/defs.bzl`), with no `-Bsymbolic` and a version script
only with `exports_exact = True` (default False). Prefixing (#672) does not separate it from the
per-library `.so` files (same `komira_awslc_`, `komira_s2n_`, `komira_snappy_` names), so by default its
calls can bind to an earlier-loaded per-library copy: two aws-lc instances interposing. Its design must
require that it hide its C (`exports_exact`, or a version script plus `-Bsymbolic`).
