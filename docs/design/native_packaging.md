# Native code in conda packages: each library ships its own

Status: plan, not built. Each item is marked **EXISTS** (with the path on `main` that does it) or
**PROPOSED**. "On #NNN" means the code is on that open pull request and not on `main`. Scope:
linux-64 (ELF) only; Mach-O (osx-arm64: install names, `@rpath`, exported-symbol lists, the two-level
namespace) is a later design. Related: [the staged pipeline](staged_pipeline.md) (build once, then
beta, gamma and prod), [gamma validation](gamma_validation.md), [release machines](release_machine.md),
the conda packaging README ([packaging/conda/README.md](../../packaging/conda/README.md)), symbol
prefixing ([tools/build/native/README.md](../../tools/build/native/README.md)).

**Supersedes** the plan of one shared library for all of komira's C, `libkomira_native.so.1` in a
package `komira_native`: #681 (the library and its checks), #685 (the packer), #695 (kci reads the
`native` kind) and #704 (kci_validate and the release-set native slot, with #761 and #763 merged
into it). They stay on hold until this plan is approved and are then closed; what each keeps is in
"What happens to each open PR".

## Why: what `main` refuses today

- **139 libraries cannot be published** (#1187, which lists them; the build computed the list at
  filing). Each one's closure links native code: a vendored C or C++ library (aws-lc, s2n-tls,
  snappy, brotli, SQLite) or a small first-party C shim. A `.mojoc` holds no machine code, so the
  build refuses their conda packages (**EXISTS:** `_conda_facts` in
  [tools/build/mojo/defs.bzl](../../tools/build/mojo/defs.bzl): "links native code"). Every cloud SDK
  package is in the list, and so are eleven `kci_*` libraries, `kci_cli` among them
  (`kci_release_set` computes the set hash with `komira_crypto`'s SHA-256).
- **Two more open a system library at run time** and link no native code: `komira_lz4`
  (`liblz4.so.1`, `src/komira_lz4/codec.mojo`) and `komira_zlib` (`libz.so.1`,
  `src/komira_zlib/zlib_ffi.mojo`) (#1188). The packer refuses them when it reads the sources
  (**EXISTS:** `tools/build/package/pack/conda.zig`: "opens a shared library at run time
  (OwnedDLHandle); its conda package must depend on the package shipping that library, which this
  tool does not derive yet"). `komira_compression` opens zstd, bz2 and lzma the same way
  (`src/komira_compression/codec_libraries.mojo`) and also links snappy, so it is in both lists.
- The released set today is 41 member libraries plus the metapackage `komira_all`
  (`release/artifacts.textproto`, held equal to `tools/build/package/release_set.txt`), none with
  native code.

## Decision summary

1. A Mojo library that owns C ships it as **its own shared library, in its own conda package**, next
   to its `.mojoc`. No package holds everyone's C.
2. A library's `.so` has a `DT_NEEDED` on the `.so` of each library whose C it calls.
3. aws-lc, s2n-tls and snappy are symbol-prefixed so they can share a process with a system copy
   (**EXISTS:** [tools/build/native/README.md](../../tools/build/native/README.md), #672); brotli and
   SQLite are not yet (open question 4).
4. Shared libraries only; no static archive in a package except C holding per-library state
   (komira_log's holder). `mojo run` (the JIT) links no static archive, and a README run must pass.
5. System-library codecs stay out: opened by soname, required from conda-forge.
6. **Built once, promoted unchanged.** Each `.so` is built inside its library's `.conda` by the
   `build` job; beta, gamma and prod handle those files and no other (the staged pipeline's rule 1).
7. The SDK engine library is a separate artifact, out of scope (last section).

## What exists on `main`, and what is proposed

| piece | on `main` | proposed here |
|---|---|---|
| symbol prefixing | **EXISTS** for aws-lc (`komira_awslc_`), s2n-tls (`komira_s2n_`), snappy (`komira_snappy_`): `tools/build/native/defs.bzl` (`prefix_header`, `prefixed_archive_check`), `elfsyms.c`, `archive_check.sh` | brotli and SQLite prefixed the same way before their owners ship |
| one-definition gate | **EXISTS:** `tools/build/one_definition/` (`:one_definition`, a `mojo_shared_lib` that links every library of `SRC_C_LIBRARIES` and `THIRD_PARTY_C_LIBRARIES` in `libraries.bzl` whole-archive, so a strong symbol defined twice fails the link; then dlopens it and resolves every name in `exports`). `tools/build/lint/includes.bzl` refuses a `cxx_library` under `src/` that the list omits | kept as is. Its limits stand: a weak or common second definition links silently; a library whose symbols are all hidden (`komira_log_holder`) cannot be seen by the exports check; a `cxx_library` declared through a `.bzl` macro or the prelude's own `load` escapes the list; `THIRD_PARTY_C_LIBRARIES` has no completeness check. The completeness lint below covers the weak/common pair |
| owner table | partial: `tools/core_split/c_symbols.tsv` maps 24 first-party C symbols to their owning package | the `callers` attribute and the completeness lint, generated from the build graph, not a hand table |
| release-set check | **EXISTS:** `conda_release_set_check` (`tools/build/package/release_set.bzl`, target `//tools/build/package:release_set_check`): stamped packages, the metapackage, the stamp check, and an order check refusing a member that requires a member listed after it, with **one exemption for `komira_native`** (`_ORDER_CHECK`, fixture `release_order_exempts_komira_native` in `tools/build/package/BUCK`). #1140 (open) extends it to refuse a requirement on a library the set omits | the `komira_native` exemption goes (slice 9): each library's `.so` is in its own package, ordered like any member |
| set hash | **EXISTS:** `src/kci_release_set/set_hash.mojo`: one line per artifact (name, platform, version, build, subdir, type, sha256 of the `.conda`), the revision and the platform; recomputed from the bytes before any publish (`src/kci_cli/dispatch.mojo`, step 4b) | unchanged; it already covers each `.so` because the `.so` is inside a `.conda` (section "Built once") |
| conda metadata kinds | **EXISTS:** `library` and `metapackage` only (`src/kci_release_set/conda_metadata.mojo`) | no new kind. `lib_files`, `native_owns`, `native_links`, `dlopen` fields on `library` (slices 6, 8) |
| kind `native`, `lib_files`, `native_link_args` | on #695 and #704 only | `lib_files` survives on `library`; the kind goes |
| dlopen declarations | the packer refuses any `OwnedDLHandle` (above). `mojo_library(dlopen = ...)` and `tools/build/package/system_libs.bzl` on #685 only; kci's acceptance of the requirements (`src/kci_release_set/system_libs.mojo`) on #704 only (from #763) | slice 2, ahead of the shared libraries |
| beta stage, `beta_install` | design only ([staged_pipeline.md](staged_pipeline.md), merged; its follow-up #1184 on gamma is open). `kci.yml` runs `build → gamma → validate → prod` | native checks land in `beta_install`, repeated by gamma's `validate` (section "Built once") |

## What each library ships

Every owned C archive below **EXISTS** as a `cxx_library` in
[tools/build/one_definition/libraries.bzl](../../tools/build/one_definition/libraries.bzl). Each
artifact is **PROPOSED**, named `lib<library>_native.so.1` plus the unversioned link name
`lib<library>_native.so` (a symbolic link). "glibc" means `NEEDED` on glibc only.

| library | native code it owns | artifact | `DT_NEEDED` |
|---|---|---|---|
| komira_crypto | aws-lc, prefixed `komira_awslc_`; `komira_crypto_sha256_hw` (the SHA-NI wrapper) | `libkomira_crypto_native.so.1` | glibc |
| komira_http_core | s2n-tls, prefixed `komira_s2n_`, built against the prefixed aws-lc | `libkomira_http_core_native.so.1` | `libkomira_crypto_native.so.1` |
| komira_compression | snappy (C API prefixed `komira_snappy_`; its C++ runtime static and local) | `libkomira_compression_native.so.1` | glibc; opens system codecs (below) |
| komira_libc / async / async_api / fs | `komira_libc_posix` / `komira_async_posix` / `komira_concurrency_pool_depth` / `komira_fs_posix` | `libkomira_<lib>_native.so.1` | glibc |
| komira_objectstore / metrics / scan_source / supervisor | `komira_objectstore_posix` / `komira_metrics_ea_flag` / `komira_scan_source_inmem_id` / `komira_supervisor_proc` | `libkomira_<lib>_native.so.1` | glibc |
| komira_log | `komira_log_holder` (per-library state) | `libkomira_log_holder.a`; with question 2 (A) also `libkomira_log_holder_jit.so.1` and its link name `libkomira_log_holder_jit.so` | none |
| komira_parquet_codec | the brotli decoder, **unprefixed** today | once prefixed: `libkomira_parquet_codec_native.so.1` | glibc |
| komira_db_sqlite | SQLite, **unprefixed** today | none until it has welded tests: its BUCK file has no `test_srcs`, so no conda package | |

`//third_party/sha1collisiondetection:sha1dc` is in `THIRD_PARTY_C_LIBRARIES` but only a conformance
test (`src/tests/conformance/komira_git_conformance`) links it; `komira_git` is Mojo, so no package
ships it. The other libraries of #1187 own no C: they reach these owners through their
closure and ship only a `.mojoc`, with a run requirement on each owner.

**One owner per C archive (PROPOSED).** A caller of another library's C goes through that owner's
`.so`, never a second copy. Callers on `main`, by `external_call` name (library sources, not tests):
`komira_awslc_*` from komira_crypto, komira_http_core and komira_uuid; `komira_s2n_*` from
komira_http_core and komira_http_client; `komira_snappy_*` from komira_compression;
`komira_on_pool_depth` (komira_async_api's) from komira_async and komira_column_kernels; komira_libc's
shims from several; komira_objectstore links `//src/komira_fs:komira_fs_posix`. `callers` and the
completeness lint count library sources only, never `test_srcs` (welded tests link the archives).

**komira_uuid is the exception to "callers already depend on the owner".** It declares
`komira_awslc_RAND_bytes` itself and depends on `//third_party/aws-lc:crypto` directly, by design
(`src/komira_uuid/BUCK`: "so the package does not depend on `komira_crypto`"). In a static link that
is the same archive; shipped, it would be a second aws-lc unless its package requires komira_crypto.
Slice 5 makes the dependency `//src/komira_crypto:komira_crypto` (a Mojo dependency, so the run
requirement comes from the existing `depends` path), and the completeness lint refuses a `src/`
library depending on a vendored archive its owner holds.

## How each shared library is linked (PROPOSED, generalizing #681)

#681 links one library with `--whole-archive`, `-Bsymbolic`, `--gc-sections`, `-z defs` and a
generated version script (on #681: `native_archive` in `tools/build/native/defs.bzl`,
`native_link.sh`, `native_exports.sh`, `native_check.sh`, `callsites.c`). Per library:

| step | rule |
|---|---|
| contents, SONAME | the library's own archives, linked whole (dependencies' via `DT_NEEDED`); SONAME `lib<library>_native.so.1`, stable because a release pins every package to one version and build string, until symbol versioning is decided |
| `DT_RUNPATH` | `$ORIGIN` when the library has a komira `DT_NEEDED`, relaxing #681's `native_check.sh`, which refuses any run path; none otherwise. A program's `DT_RUNPATH` is not searched for its dependencies' dependencies (a `DT_RPATH` would be), so http_core's `.so` must find crypto's by its own |
| callers, declared | an owner's export list depends on its reverse dependencies, which a Buck2 target cannot discover, so each owner declares its `callers` (Mojo libraries and dependent owners' archives), as #681's `komira_native` rule does (`ctx.attrs.callers`). This replaces #685's central `members.bzl` |
| completeness lint | a root target reads every `mojo_library` from the build graph (as `//:src_layout` does) and every owner archive, runs the call-site reader, and refuses: an `external_call` into an owner by a library its `callers` omits; a weak or common symbol defined in two owners' archives (the one-definition gate's blind spot); a `src/` library depending on a vendored archive another library owns. Without it a new caller passes its welded tests (static archives) and fails only at a consumer's link |
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
   by design (**EXISTS:** `extra_symbols` in the native README). `-Bsymbolic` does not bind an
   undefined symbol, so any loaded object exporting such a definition would install allocator hooks
   into komira_crypto's aws-lc; probe 3's ONE and IR cases assert the hooks stay unbound;
4. `NEEDED` is glibc plus the declared komira owners, nothing else; SONAME and `DT_RUNPATH` as above;
5. the highest `GLIBC_` symbol version is at or below the package's declared `__glibc` floor.

`elfsyms` (**EXISTS:** `tools/build/native/elfsyms.c`, modes `armap` and `symtab`) gains a `dynsym`
mode, as on #681.

## Linking from Mojo

A `.mojoc` holds no machine code, so Mojo is compiled into the consumer and every native package of
the closure is named at its link. `DT_NEEDED` does not cover a call made from Mojo: komira_http_core's
TLS init calls komira_async's `ignore_sigpipe` (`src/komira_http_core/tls/s2n_shim.mojo` imports it
from `komira_async.reactor.graceful_shutdown`), yet s2n-tls's `.so` has no reason to need
komira_async's. A program using komira_http_core needs eight owners (http_core, crypto, async,
async_api, metrics, compression, scan_source, libc) plus komira_log's holder. Below, `<env>` is the
conda environment and `-lA ... -lH` those owners, dependents first, each behind `-Xlinker`:

```sh
mojo run   -Xlinker -L<env>/lib -lA ... -lH -Xlinker -lkomira_log_holder_jit prog.mojo
mojo build -Xlinker -L<env>/lib -lA ... -lH -Xlinker -lkomira_log_holder \
    -Xlinker -rpath -Xlinker '$ORIGIN/../lib' prog.mojo -o <env>/bin/prog
```

Proven for one library (#681's run test): `mojo run -Xlinker -L<prefix>/lib -Xlinker -lkomira_native`,
and `mojo build` with run path `$ORIGIN/../lib` set through the build wrapper's `--runpath`
(**EXISTS:** `tools/build/mojo/mojo_wrapper.sh`, which drops every user `-rpath` in any spelling and
adds its own). So the user-spelled `-Xlinker -rpath` with conda's `mojo` (and whether it writes
`DT_RUNPATH` or `DT_RPATH`) stays **unproven even after probe 3**, which builds through the same
wrapper. The install validations run READMEs with `mojo run` only, so the whole `mojo build` consumer
path is unproven until the proposed build row (below) exists.

**Where a user gets these flags (open question 5).** On #704, kci_validate computes them from
metadata and injects them (`native_link_args`), so a README run passes with flags the README never
shows, and a user who copies the README fails with "Symbols not found". This per-package burden is
the main usability cost of decision 1. No build-time gate can catch a missing flag: the welded README
gate compiles the README's Mojo examples into one program linked against the closure's static
archives (**EXISTS:** `_readme_gate`, `_link_tail` in `tools/build/mojo/defs.bzl`) and runs no shell
command, and the build has no installed `.so`. Only an installed-package README run can.

**(a)** the packer writes the exact commands into each README as a fenced `sh` block, the readme tool
parses it, and the install validations use those flags instead of computing their own (or refuse when
they differ), so a missing flag fails `beta_install`; **(b)** a pkg-config `.pc` per package with
`Requires:`; **(c)** a `komira link-flags <package>` helper. Recommended: (a), (b) when a second
consumer needs it; both read the metadata kci reads.

Welded tests and the welded README gate do not change: they link static archives (`_link_tail`), and
#685 records why they must not also link a shared copy (a test hook set in one copy is unread by the
other).

## Per-library state: komira_log's holder

`src/komira_log/engine/_log_holder_shim.c` (**EXISTS**) has twelve `KOMIRA_SHIM_LOCAL` (hidden)
accessors: the engine holder (`komira_log_holder_set`, `_get`, `_get_engine`, `_clear`), the
configuration (`komira_log_config_holder_set`, `_get`, `komira_log_holder_get_config`), the layout
(`komira_log_layout_set`, `_get`) and the worker-id thread-local (`komira_log_tls_key_create`, `_set`,
`_get`, used by `engine/worker_id_tls.mojo`). The engine is a Mojo struct that only the image which
compiled it may read, so each image (a program or a Mojo shared library) that links the archive gets
its own cells and creates its own pthread key: **one engine per library**. As an ordinary shared
`.so`, two Mojo images would share the cells; the second install would do nothing and that image would
read the first's struct, the type confusion the file's header describes.

Other shims hold process state with no Mojo struct (komira_async's CAS gate and counters,
komira_libc's mmap counters, komira_objectstore's test fault hooks, and the like). Installed, each is
intentionally **one copy per process** in its owner's `.so`; welded tests keep a static copy per
image, and test hooks stay exercised only there (the two-copy hazard #685 named). The split this
allows (two copies of one counter) is impossible in today's static links, where an archive member
loads whole or not at all; it becomes possible only with several link units, so probe 3's ONE case
is its first test.

**On #685:** `lib/libkomira_log_holder.a` is linked into each built program, and a closure holding
komira_log (most native libraries, through komira_async) must be built, not `mojo run`.

**Options (open question 2):**

| option | what | requirements and cost |
|---|---|---|
| **(A)** | ship `libkomira_log_holder.a` for `mojo build` (`-lkomira_log_holder`, as on #685) and, for `mojo run` only, `libkomira_log_holder_jit.so.1` with its unversioned link name `libkomira_log_holder_jit.so`. A JIT process is one image | a second compile of the shim with all twelve accessors exported (a `.so` linked from the hidden archive exports nothing: "Symbols not found"); the export check lists the twelve for this artifact. No `libkomira_log_holder.so` exists, so `-lkomira_log_holder` can only pick the archive, and a built image never names the JIT object; each gets its own hidden cells and pthread key. Probe 3's LOG2 checks no built image has `NEEDED` on the JIT object; the install check refuses any installed `.so` that does |
| **(B)** | keep one slot per image, keyed by an address private to that image, shipped as an ordinary `.so` | a change to komira_log needing a Mojo-safety review; it must also decide whether the worker-id pthread key is per image |
| **(C)** | keep #685's rule: no `mojo run` for these libraries | no install validation can run their READMEs through `mojo run` |

Recommendation: **(A)**, pending probe 3.

## System codecs (dlopened)

Each codec is opened at first use by soname, with `OwnedDLHandle`, by its owning library
(**EXISTS**):

| library | soname | conda-forge requirement (from #685's `system_libs.bzl`) |
|---|---|---|
| komira_compression | `libzstd.so.1`, `libbz2.so.1.0`, `liblzma.so.5` | `zstd >=1.5.2,<2`, `bzip2 >=1.0.8,<2`, `xz >=5.2.5,<6` |
| komira_zlib | `libz.so.1` | `libzlib >=1.2.13,<2` |
| komira_lz4 | `liblz4.so.1` | `lz4-c >=1.9.3,<2` |

No other library under `src/` (tests aside) calls `OwnedDLHandle`.

- **PROPOSED (slice 2, from #685):** `mojo_library(dlopen = [...])` declares the sonames;
  `tools/build/package/system_libs.bzl` maps each to its requirement; the packer writes the
  requirement into `depends`, records `dlopen` in `metadata.json`, and refuses a library whose sources
  open a soname its declaration omits (replacing today's blanket refusal). The build refuses a
  declaration the map lacks.
- **PROPOSED (slice 2, from #763):** kci accepts exactly those requirements, byte-equal to the map,
  as the only non-komira, non-compiler requirements of a library package.
- **komira_lz4 and komira_zlib (#1188) go first, in slice 2.** They link no native code, so nothing in
  the shared-library work blocks them, and they prove the conda-forge requirement path end to end
  (pinned, installed from conda-forge, checked by kci) before the larger slices depend on it.
  `komira_compression` follows only with its own `.so` (slice 7), because it also links snappy.

Not proven: loading from the environment's `lib/` with `LD_LIBRARY_PATH` unset. The `dlopen` under
`mojo run` comes from JIT code in no ELF object, so no run path applies, and the runner image may ship
its own copies, which would make a passing check prove nothing. Probe 3's DL case tests it, and the
install validation reads `/proc/self/maps` to show the copy it loaded lies under the environment.

## Built once, promoted unchanged

The staged pipeline ([staged_pipeline.md](staged_pipeline.md), design, not built) rules that each
commit is built **once** and every stage promotes **the same files, by sha256**. Native artifacts add
no exception:

- **Where they are built.** Each `.so` is a build action of `<lib>_conda[release]`, so the `build`
  job (on the farm, with the release stamp) links it, runs checks 1 to 5 on it, and packs it into the
  library's `.conda`. No later job compiles or links anything: `beta`, `beta_install`, `gamma`,
  `validate` and `prod` download the run's `kci-release-<revision>` artifact.
- **How the set hash covers them.** The set hash has one line per artifact with the sha256 of its
  `.conda` (**EXISTS:** `set_hash.mojo`), and the `.so` is inside that file, so any change to a `.so`
  changes the hash and every later stage refuses the set before any effect (`KCI-E-SET-HASH`, exit 3).
  #704's separate native slot in the set is not needed and goes. Inside the package, `metadata.json`
  gains `lib_files` rows `{path, sha256, kind}` (`kind` `shared`, `link` for the unversioned
  symbolic link, or `static` for the holder archive), the way `doc_files` carries `{path, sha256}`
  today, so a check after install can name which file differs.
- **How beta exercises them.** Beta's farm job (`beta`, a `TEST` step) builds and tests the e2e
  suites from source; those suites link static archives, so its payload comparison (each library's
  buck2 payload sha256 against `payload_sha256`, which is the `.mojoc`) **does not reach any `.so`**.
  The `.so` files are exercised by `beta_install`, the hosted job that installs the built files from
  the run's local channel (`komira_pack conda-index`) with the pinned pixi:
  1. install pinned to the release's version, build string and `.conda` sha256 (**EXISTS:**
     `src/kci_validate/readback.mojo`, check 2);
  2. each installed `lib_files` row's sha256 equals the row (extends check 3, payload);
  3. the install check: each installed `.so`'s `NEEDED` resolves inside the environment with
     `LD_LIBRARY_PATH` unset; none names `libkomira_log_holder_jit.so.1`; `/proc/self/maps` shows the
     dlopened codecs loaded from the environment;
  4. every installed README run under `mojo run` with the owners' flags (question 5) and, new, built
     with `mojo build` into `<env>/bin` and run with `LD_LIBRARY_PATH` unset;
  5. one program per owner of komira_http_core's closure beside a system OpenSSL (probe 3's IR1),
     installed from conda-forge as an extra requirement of that validation only.
  gamma's `validate` repeats 1 to 4 against the real channel after publishing (the bytes a consumer
  gets); prod publishes the same files. The staged pipeline moves the installed-bytes checks from
  gamma to `beta_install` so they run before anything is published; the native checks follow them.
- **What this rules out.** A fix to a `.so` (a run path, a missing export) is a new commit and a new
  build; no stage re-links, re-packs or strips. A release whose `.so` fails at install is stopped at
  `beta_install`, not repaired downstream.

## What the evidence covers, and probe 3

**Proven.** Probe 2 (komira branch `exp/native-probe-2`, `tests/native_probe2/`, never merged) and
#681's `:komira_native_run_test` (R1, B1, IR1, IR2): for **one** `.so` holding aws-lc, s2n-tls,
snappy and the shims, prefixing plus a version script plus `-Bsymbolic` gives no interposition either
way beside a system `libcrypto.so.3`/`libssl.so.3`, in either load order, where the leaky control
crashes the system's `SSL_CTX_new`. On #685, `:installed_crypto_run_test` repeats R1 and B1 and
`:installed_log_run_test` B1, from installed packages.

**Not proven:** several komira `.so` files in one process; a `DT_NEEDED` between them found through
`$ORIGIN`; the JIT loading more than one `-l` library; one aws-lc per process when two packages reach
it; a system codec `dlopen`ed from the environment's `lib/` with `LD_LIBRARY_PATH` unset.

**Probe 3 (PROPOSED: a farm target on a scratch branch, never merged).** Every owner of
komira_http_core's closure, linked as above (crypto with aws-lc and the SHA-NI wrapper; http_core
with s2n-tls, `NEEDED` crypto, `DT_RUNPATH` `$ORIGIN`), plus the holder archive and JIT object. R1
and B1 go through komira_http_core's Mojo API and name every owner. Built cases go through
`mojo_wrapper.sh`, so their run path is the wrapper's `DT_RUNPATH`, not a user-spelled `-rpath`.

| case | what it shows |
|---|---|
| R1 | `mojo run`, closure `-l` flags in dependency order: SHA-256, AES-GCM, s2n init, a TLS 1.3 client connection |
| R2 | R1 with the `-l` flags reversed |
| B1 | R1's checks under `mojo build` into `<prefix>/bin`, same flags, run path `$ORIGIN/../lib`, `LD_LIBRARY_PATH` unset |
| B2 | a built program calling only `komira_s2n_*` by raw `external_call` (no komira Mojo import), naming only `-lkomira_http_core_native`: crypto found through http_core's `DT_RUNPATH` |
| R1-MISS (must fail) | R1 without `-lkomira_async_native`: fails, and the missing names include `komira_ignore_sigpipe`, the Mojo-to-C edge `DT_NEEDED` does not carry |
| B3 (must fail) | B2 with http_core's `DT_RUNPATH` removed: the load fails naming `libkomira_crypto_native.so.1` |
| IR1, IR2 | R1 and B1 beside a system OpenSSL loaded `RTLD_GLOBAL`, before and after ours: no interposition; the `komira_awslc_OPENSSL_memory_*` hooks stay unbound |
| ONE | the aws-lc reached from komira_crypto and from s2n-tls is one copy (`dladdr` of a `komira_awslc_` function from both sides names one file); the weak hooks stay unbound |
| LOG1 | option (A): `-lkomira_log_holder_jit` under `mojo run`; the archive under `mojo build` |
| LOG2 | a built program and a Mojo shared library, both with `-lkomira_log_holder`: neither has `NEEDED` on the JIT object; each reads its own engine |
| DL | `libzstd.so.1` opened by komira_compression under `mojo run` and from a built program, `LD_LIBRARY_PATH` unset: the environment's copy loads |

## Implementation: ordered slices

Each slice is one pull request unless noted, lands on `main` in this order, and starts with a check
that is red before it (on `main`, or on a planted defect named in the slice) and green after. "Go"
marks a slice that needs the project owner's explicit go before it runs or merges: an upload, a new
channel, a new package name, or a change to what a release publishes.

| # | slice | red before it | go |
|---|---|---|---|
| 1 | **Probe 3**, a farm target on a scratch branch; results recorded in this doc (cases, `Commands:` line with `local: 0`) | R1-MISS and B3 must fail and are shown failing; the other cases are the findings | none (nothing uploaded, nothing merged) |
| 2 | **dlopen declarations** (#1188): `mojo_library(dlopen)`, `system_libs.bzl`, the packer writes the requirement and `dlopen`, kci accepts exactly the map's requirements; `komira_lz4` and `komira_zlib` declared | the packer fixture `fx_dlopen_conda` (`tools/build/tests/functional/conda.sh`) is refused today; new fixtures: a source opening an undeclared soname refused, a declaration missing from the map refused, kci refusing a requirement off the map (mutant: kci accepts any `depends`) | **Go** to add `komira_lz4` and `komira_zlib` to `release/artifacts.textproto` (new package names on the channel) |
| 3 | **`elfsyms dynsym`** and the per-library link rule (`native_archive` reworked from #681, `callers`, version-script generator, checks 1 to 5) over **komira_crypto only**, no package change | planted: an unprefixed export, a missing caller name, an extra `NEEDED`, a strong undefined `komira_` symbol, a `GLIBC_` above the floor: each red | none |
| 4 | the rule over every owner in the table above, including http_core's `NEEDED` and `DT_RUNPATH` | planted: http_core without `DT_RUNPATH` (B3's check at build time), a caller dropped from `callers` | none |
| 5 | **completeness lint** at the root; `komira_uuid` depends on `komira_crypto` | red on `main`: komira_uuid's direct aws-lc dependency; planted: a weak pair across two owners, a new `external_call` with no `callers` entry | none |
| 6 | **the packer**: `lib_files` (`shared`, `link`, `static`), `native_owns`, `native_links`; the `.so` into the library's `.conda`; `_conda_facts` stops refusing a library whose every linked archive has an owner in its closure; komira_log's holder archive and (with 2A) JIT object; brotli prefixed before komira_parquet_codec is packaged (question 4) | `_conda_facts` refuses komira_crypto today; planted: a `.so` whose `lib_files` sha256 differs, an archive with no owner in the closure, a holder JIT object named in a built `.so`'s `NEEDED` | none (builds only; nothing declared) |
| 7 | **kci reads `lib_files`**: the generalised `native_link_args` (every pin, dependency order, or the README's flags with 5a), readback of `lib_files` sha256, the install check, the `mojo build` README row; the `__glibc` floor on each library with C; the `native` kind and `_native_depends` never land | kci fixtures: a missing owner flag, a `.so` with an unresolved `NEEDED`, a `lib_files` sha256 mismatch, a JIT object in a built image's `NEEDED`: each refused (mutant per check) | none |
| 8 | **README link commands** (question 5a): the packer writes the `sh` block; the readme tool parses it; the install validation uses it or refuses a difference | planted README without an owner's `-l`: the install validation red | none |
| 9 | **the release set**: drop the `komira_native` exemption from `_ORDER_CHECK` and its fixture; declare the first native batch (the owners and their dependents up to the cloud SDKs) in `release/artifacts.textproto` and `release_set.txt` | the fixture `release_order_exempts_komira_native` becomes a must-fail; `release_set_check` red on a batch member listed before an owner it requires | **Go**: new package names on the channel, a change to what gamma and prod publish |
| 10 | **staged-pipeline wiring**: the native rows of slices 7 and 8 run in `beta_install` (once the staged pipeline's switch, its P4, lands) and in gamma's `validate`; until then in `validate` only | a planted `.so` change after `build` (a hash mismatch) refused before any effect, at each stage (mutant: skip step 4b for that stage) | **Go**: it changes the release (inherits the staged pipeline's P4 go) |
| 11 | **gamma_validation.md** rewritten: the `komira_native` rows become per-library rows | doc links lint | none |

Slices 1 and 2 are independent; 3 to 8 are a chain; 9 needs 6 to 8; 10 needs 9 and the staged
pipeline's P4. Issue #1187 closes when slice 9 has declared every library it lists that can ship
(SQLite's owner excepted until it has welded tests).

## What happens to each open PR

| PR | fate |
|---|---|
| #672 symbol prefixing | **Merged.** `tools/build/native/` on `main`. Every per-library `.so` relies on it. |
| #681 one `libkomira_native.so.1` | **Superseded.** Its `native_archive` (in `tools/build/native/defs.bzl`), export generator, `callers` attribute, call-site reader, link script, checks, `elfsyms dynsym` and run test survive into slices 3 and 4, reworked to one library per owner. Kind `shared` becomes "in its owner's `.so`"; `per_library` becomes "ships a static archive". The undefined-symbol rule changes as in check 3. |
| #685 packer | **Superseded; parts survive** into slices 2 and 6: its extension of `native_archive` (forwarded providers, the `name` field), `lib_files`, `dlopen` with `system_libs.bzl` and its drift check, "welded tests link the archives", `conda_prefix` installed run tests. Dropped: `members.bzl` (by `callers` and the completeness lint), `conda_native_package`, the `komira_native` requirement. |
| #695 kci reads kind `native` | **Superseded; parts survive** into slice 7: the `lib_files` parser (`LibFile`, link rows, `has_lib_files`), read on a `library`. Dropped: the refusal of link rows on a library, the `native` kind, `is_native`, the native case of `is_member_kind`, `_native_depends` in `src/kci_publish/verify.mojo`. |
| #704 kci_validate, release-set native slot | **Superseded; parts survive** into slices 2 and 7: `native_link_args` over every library pin in dependency order (deferring to the README's flags with 5a); the system-library acceptance from #763 (`src/kci_release_set/system_libs.mojo`). Dropped: the native member and slot (the set hash already covers each `.so`), `-lkomira_native`, #761's `komira_native` member (its library declarations return in slice 9). |
| #1140 release set refuses an undeclared requirement | **Independent, wanted:** with per-library packages, a member requiring an owner the set omits is exactly what it refuses. |

## Open questions for the project owner

1. **Per-package shared libraries, no static archives except per-library state.** Recommended: yes.
2. **komira_log's holder under `mojo run`:** (A), (B) or (C) above. Recommended: (A), confirmed by
   probe 3.
3. **The `.so` in the library's own package, or a separate `<library>_native` package** the SDK
   engine could also require. Recommended: the library's own; split only if something needs the C
   without the Mojo. A separate package doubles the new package names slice 9 asks a go for.
4. **Prefix brotli (and SQLite) before komira_parquet_codec (and komira_db_sqlite) ship.**
   Recommended: yes, by `tools/build/native/`. An unprefixed exported `BrotliDecoder*` would
   interpose on a system `libbrotlidec`.
5. **Where a user gets the link flags:** (a), (b) or (c) in "Linking from Mojo". Recommended: (a).
6. **komira_lz4 and komira_zlib ahead of the shared libraries** (slice 2, #1188). Recommended: yes;
   they need only the dlopen declaration, and their go is two new package names.
7. **Where the native install checks run before the staged pipeline is built.** Recommended: in
   gamma's `validate` from slice 7, moving to `beta_install` with the staged pipeline's P4; no
   library with native code is declared (slice 9) before those checks run somewhere.
8. **The `__glibc` floor** each library with C declares (check 5 holds the `.so` to it). Recommended:
   the floor of the oldest supported runner image, one value for every package, stated in
   `packaging/conda/README.md`.
9. **The first native batch** (slice 9): the owners plus every dependent of #1187 in one go, or the
   owners and kci first. Recommended: owners plus `kci_*` first (kci publishes kci), then the rest
   in one batch; each batch is a go.

## Out of scope: the SDK engine library

The SDKs' engine shared library is not built yet (`docs/index.md`: the ABI is "coming with
`komira_so`") and has its own design. `mojo_shared_lib` links C archives into the library itself
(**EXISTS:** `force_load` in `tools/build/mojo/defs.bzl`), with no `-Bsymbolic` and a version script
only with `exports_exact = True` (default False). Prefixing (#672) does not separate it from the
per-library `.so` files (same `komira_awslc_`, `komira_s2n_`, `komira_snappy_` names), so by default
its calls can bind to an earlier-loaded per-library copy: two aws-lc instances interposing. Its design
must require that it hide its C (`exports_exact`, or a version script plus `-Bsymbolic`). The same
holds for any Mojo shared library a user loads beside komira's packages (the UDF runtime spike, #1167,
loads native libraries `RTLD_LOCAL`, which keeps their symbols out of the global scope but does not
stop their own references binding to an earlier global definition without `-Bsymbolic`).
