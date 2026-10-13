# Native code in conda packages: each library ships its own

Status: plan, built in part (part of slice 9, #1391; slice 11, the beta wiring). Each item is marked **EXISTS** (with the
path on `main` that does it) or **PROPOSED**. "On #NNN" means the code is on that open pull request and not on `main`. Scope:
linux-64 (ELF) only; Mach-O (osx-arm64: install names, `@rpath`, exported-symbol lists, the two-level
namespace) is a later design. Related: [the staged pipeline](staged_pipeline.md) (build once, then
beta, gamma and prod), [gamma validation](gamma_validation.md) (its native rows point to this
doc's checks), [continuous publish](continuous_publish.md) (its slice S12 also plans an
installed `.so` check in beta's install job; slice 11 below wires this doc's install checks into
that job, so the two land as one set of rows), [release machines](release_machine.md),
the conda packaging README ([packaging/conda/README.md](../../packaging/conda/README.md)), symbol
prefixing ([tools/build/native/README.md](../../tools/build/native/README.md)).

**Supersedes** the one-library plan, one shared library for all of komira's C
(2026-10-07: `libkomira_native.so.1` in a package `komira_native`), and its four pull requests:
#681 (the library and its checks), #685 (the packer), #695 (kci reads the
`native` kind) and #704 (kci_validate and the release-set native slot, with #761 and #763 merged
into it). All four are closed unmerged; what each kept is in
"What happens to each open PR".

**Stages**, as the glossary of [staged_pipeline.md](staged_pipeline.md) names them (its follow-up
#1184, merged, holds the [glossary](staged_pipeline.md#glossary)): **beta** builds once, publishes
the packages to the `beta` conda channel, installs from it and runs the README examples and the
package test tiers; **gamma** is only real resources in the gamma cloud accounts (deploys and
real-cloud validations) and names no conda
channel; **prod** promotes the same bytes to the prod channel. Every check of an installed native
package below is therefore beta's, in its install job `beta_validate` (staged_pipeline.md and
continuous_publish.md both use that name; `kci.yml` runs it since the staged pipeline's switch M2,
#1296, which renamed the job `validate`).

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
  `src/komira_zlib/zlib_ffi.mojo`) (#1188). Before slice 3 the packer refused them when it read the
  sources ("opens a shared library at run time (OwnedDLHandle); its conda package must depend on the
  package shipping that library, which this tool does not derive yet"); slice 3 declares their sonames,
  and their packages now build, requiring `lz4-c` and `libzlib`, but neither is released.
  `komira_compression` opens zstd, bz2 and lzma the same way
  (`src/komira_compression/codec_libraries.mojo`) and also links snappy, so it is in both lists.
- The released set today is its member libraries plus the metapackage `komira_all`
  (`release/artifacts.textproto`, held equal to `tools/build/package/release_set.txt`), none with
  native code (no member's directory holds a C or C++ source or opens a library at run time).

## Decision summary

1. A Mojo library that owns C ships it as **its own shared library, in its own conda package**, next
   to its `.mojoc`. No package holds everyone's C.
2. A library's `.so` has a `DT_NEEDED` on the `.so` of each library whose C it calls.
3. aws-lc, s2n-tls, snappy, brotli and SQLite are symbol-prefixed so they can share a process with
   a system copy (**EXISTS:** [tools/build/native/README.md](../../tools/build/native/README.md),
   #672; brotli and SQLite by #1356, open question 4).
4. Shared libraries only; no static archive in a package except C holding per-library state
   (komira_log's holder). `mojo run` (the JIT) links no static archive, and a README run must pass.
5. System-library codecs stay out: opened by soname, required from conda-forge.
6. **Built once, promoted unchanged.** Each `.so` is built inside its library's `.conda` by the
   `build` job; beta, gamma and prod handle those files and no other (the staged pipeline's rule 1).
   Installed `.so` files are checked once, in beta's install job.
7. The SDK engine library is a separate artifact, out of scope (last section).

## What exists on `main`, and what is proposed

| piece | on `main` | proposed here |
|---|---|---|
| symbol prefixing | **EXISTS** for aws-lc (`komira_awslc_`), s2n-tls (`komira_s2n_`), snappy (`komira_snappy_`), brotli (`komira_brotli_`), SQLite (`komira_sqlite3_`): `tools/build/native/defs.bzl` (`prefix_header`, `prefixed_archive_check`), `elfsyms.c`, `prefix_tool` (Zig) | kept as is |
| one-definition gate | **EXISTS:** `tools/build/one_definition/` (`:one_definition`, a `mojo_shared_lib` that links every library of `SRC_C_LIBRARIES` and `THIRD_PARTY_C_LIBRARIES` in `libraries.bzl` whole-archive, so a strong symbol defined twice fails the link; then dlopens it and resolves every name in `exports`). `tools/build/lint/includes.bzl` refuses a `cxx_library` under `src/` that the list omits | kept as is. Its limits stand: a weak or common second definition links silently; a library whose symbols are all hidden (`komira_log_holder`) cannot be seen by the exports check; a `cxx_library` declared through a `.bzl` macro or the prelude's own `load` escapes the list; `THIRD_PARTY_C_LIBRARIES` has no completeness check. The completeness lint below covers the weak/common pair |
| owner table | partial: `tools/core_split/c_symbols.tsv` maps 24 first-party C symbols to their owning package | the `callers` attribute and the completeness lint, generated from the build graph, not a hand table |
| release-set check | **EXISTS:** `conda_release_set_check` (`tools/build/package/release_set.bzl`, target `//tools/build/package:release_set_check`): stamped packages, the metapackage, the stamp check, and an order check refusing a member that requires a member listed after it, with no exemption (the one for the one-library plan's package went with slice 2). It does not refuse a requirement on a package the set omits: the `install-set` validation (`CONDA_INSTALL_ENV` of `komira_all`, `release/machine.textproto`; on `main` it runs in `beta_validate` after beta's publish (since M2, #1296), and the `beta` channel holds only the build's packages) fails to install such a set before anything promotes, so no build-time duplicate is planned | the one-library plan's exemption is gone (slice 2), since it served only the superseded plan: each library's `.so` is in its own package, ordered like any member |
| set hash | **EXISTS:** `src/kci_release_set/set_hash.mojo`: one line per artifact (name, platform, version, build, subdir, type, sha256 of the `.conda`), the revision and the platform; recomputed from the bytes before any publish (`src/kci_cli/dispatch.mojo`, step 4b) | unchanged; it already covers each `.so` because the `.so` is inside a `.conda` (section "Built once") |
| glibc floor | **EXISTS:** `os_floor` `glibc-2.34` in `tools/build/platforms/table.bzl` (rows `linux-x86_64` and `linux-arm64`; read by `os_floor_version`), the floor zig links against (`zig_triple` `x86_64-linux-gnu.2.34`, `aarch64-linux-gnu.2.34`). The packer writes only the platform guard `__linux` (`guardFor` in `tools/build/package/pack/conda.zig`), no `__glibc` requirement | the packer writes `__glibc >=2.34` from that cell on each library with C (slice 8); per-library check 5 reads the same cell; kci accepts it (**EXISTS** since #1391, slice 9: `src/kci_release_set/glibc_floor.mojo`). No second floor |
| conda metadata kinds | **EXISTS:** `library` and `metapackage` only (`src/kci_release_set/conda_metadata.mojo`); kci reads `lib_files` on a `library` since #1391 (slice 9, the reader side) | no new kind. The packer writes `lib_files`, `native_owns`, `native_links`, `dlopen` fields on `library` (slices 3, 8) |
| kind `native`, `native_link_args` | on #695 and #704 only, both closed unmerged (`lib_files` on `library` is on `main`, above) | `lib_files` survives on `library`; the kind goes |
| dlopen declarations | **EXISTS:** `mojo_library(dlopen = ...)` (`tools/build/mojo/dlopen.bzl`), the map `tools/build/package/system_libs.bzl`, the packer writing each declared requirement and `dlopen` and refusing sources that open an undeclared soname (`tools/build/package/pack/conda_dlopen.zig`), and kci's acceptance of exactly the map's requirements (`src/kci_release_set/system_libs.mojo`, `closure.mojo`); `komira_lz4` and `komira_zlib` declare their sonames | slice 3 (done); releasing the two is slice 4 |
| beta stage, `beta_validate` | **EXISTS** since the switch M2 (#1296): `kci.yml` runs `build → beta → beta_validate → prod` (`gamma` and `validate` before M2); the rest of [staged_pipeline.md](staged_pipeline.md) (merged, with its [glossary](staged_pipeline.md#glossary) from #1184) is design only | native install checks run only in `beta_validate` (section "Built once"); gamma runs none |

## What each library ships

Every owned C archive below **EXISTS** as a `cxx_library` in
[tools/build/one_definition/libraries.bzl](../../tools/build/one_definition/libraries.bzl). Each
artifact is **PROPOSED**, named `lib<library>_native.so.1` plus the unversioned link name
`lib<library>_native.so` (a symbolic link). "glibc" means `NEEDED` on glibc only: in probe 3
(#1304) that is `libpthread.so.0` and `libc.so.6`, plus `ld-linux-x86-64.so.2` where the library uses
thread-local storage (async, http_core); async_api, metrics and scan_source had no `NEEDED` at all.

| library | native code it owns | artifact | `DT_NEEDED` |
|---|---|---|---|
| komira_crypto | aws-lc, prefixed `komira_awslc_`; `komira_crypto_sha256_hw` (the SHA-NI wrapper) | `libkomira_crypto_native.so.1` | glibc |
| komira_http_core | s2n-tls, prefixed `komira_s2n_`, built against the prefixed aws-lc | `libkomira_http_core_native.so.1` | `libkomira_crypto_native.so.1` |
| komira_compression | snappy (C API prefixed `komira_snappy_`; its C++ runtime static and local) | `libkomira_compression_native.so.1` | glibc; opens system codecs (below) |
| komira_libc / async / async_api / fs | `komira_libc_posix` / `komira_async_posix` / `komira_concurrency_pool_depth` / `komira_fs_posix` | `libkomira_<lib>_native.so.1` | glibc |
| komira_objectstore / metrics / scan_source / supervisor | `komira_objectstore_posix` / `komira_metrics_ea_flag` / `komira_scan_source_inmem_id` / `komira_supervisor_proc` | `libkomira_<lib>_native.so.1` | glibc |
| komira_log | `komira_log_holder` (per-library state) | `libkomira_log_holder.a`; with question 2 (A) also `libkomira_log_holder_jit.so.1` and its link name `libkomira_log_holder_jit.so` | none |
| komira_parquet_codec | the brotli decoder, prefixed `komira_brotli_` | `libkomira_parquet_codec_native.so.1` | glibc |
| komira_db_sqlite | SQLite, prefixed `komira_sqlite3_` | `libkomira_db_sqlite_native.so.1`, built and checked; shipped by no package until the library has welded tests (its BUCK file has no `test_srcs`, so no conda package) | glibc |

`//third_party/sha1collisiondetection:sha1dc` is in `THIRD_PARTY_C_LIBRARIES` but only a conformance
test (`src/tests/conformance/komira_git_conformance`) links it; `komira_git` is Mojo, so no package
ships it. The other libraries of #1187 own no C: they reach these owners through their
closure and ship only a `.mojoc`, with a run requirement on each owner.

**One owner per C archive (PROPOSED).** A caller of another library's C goes through that owner's
`.so`, never a second copy. Callers on `main`, by `external_call` name (library sources, not tests):
`komira_awslc_*` from komira_crypto and komira_uuid (komira_http_core reaches aws-lc only through
s2n-tls's archive); `komira_s2n_*` from komira_http_core and komira_http_client; `komira_snappy_*`
from komira_compression; `komira_on_pool_depth` (komira_async_api's) from komira_async and
komira_column_kernels; komira_libc's shims from several; komira_fs's shims (`komira_free`,
`komira_fs_enoent`, `komira_fs_errno_name`) from komira_objectstore. `callers` and the completeness
lint count library sources only, never `test_srcs` (welded tests link the archives).

**Three libraries reached an owner they did not depend on (fixed by #1325, slice 7).** A package's run requirements come from
its Mojo dependencies (the packer writes one `name ==version build` row per direct dependency,
`runRequirements` in `tools/build/package/pack/conda.zig`), so a `.so` whose `NEEDED` names an owner
outside the library's Mojo closure installs without that owner. Before #1325, walking every
`mojo_library` under `src/` (its `external_call` names in library sources, its `cxx_library` and
vendored-archive dependencies, and the archives those archives need) against its Mojo closure found:

| library | owner it reaches | how, before #1325 | Mojo closure held the owner |
|---|---|---|---|
| komira_uuid | komira_crypto | declares `komira_awslc_RAND_bytes` and depended on `//third_party/aws-lc:crypto` directly, by design (its BUCK said "so the package does not depend on `komira_crypto`") | no; now a dependency |
| komira_http_core | komira_crypto | its own archive: `//third_party/s2n-tls:s2n` has `exported_deps = ["//third_party/aws-lc:crypto"]`, so its `.so` has `NEEDED` on `libkomira_crypto_native.so.1`; its Mojo deps were komira_async, komira_clock, komira_collections, komira_libc and s2n | no; now a dependency |
| komira_objectstore | komira_fs | depended on `//src/komira_fs:komira_fs_posix` directly and calls three of its functions | no; now depends on `//src/komira_fs:komira_fs` |

(`komira_search_e2e`, an end-to-end suite under `src/tests/e2e`, also links `komira_fs_posix` without
komira_fs; it is never packaged.) In a static link each is the same archive. Shipped, they differ:
komira_uuid has no C of its own, so no `.so`, and without komira_crypto it carries a second aws-lc;
komira_objectstore's `.so` (its own shim) needs glibc only, because its calls into komira_fs come from
Mojo `external_call`s (`local_fs_conditional_store.mojo`), which no `NEEDED` records; only
komira_http_core's `.so` has a `NEEDED` (on crypto's) that no requirement installs. A single
environment holding the whole set (beta's install job) hides all three, and the release-order check
and the `install-set` validation refuse wrong requirements (a member listed before what it requires,
a requirement on a package the set omits), not missing ones.

**Rule (EXISTS since #1325, slice 7):** every owner a library reaches is in its Mojo closure, so the
requirement comes from the one existing `depends` path and nothing derives requirements a second
way. #1325 added the three Mojo dependencies (`komira_uuid` and `komira_http_core` on
`//src/komira_crypto:komira_crypto`, `komira_objectstore` on `//src/komira_fs:komira_fs`), removed
komira_uuid's direct dependency on `//third_party/aws-lc:crypto` and komira_objectstore's on
`//src/komira_fs:komira_fs_posix`, and gave every `mojo_library` outside `src/tests/` two
validations (`tools/build/mojo/native_reach.bzl`; [tools/build/mojo/README.md](../../tools/build/mojo/README.md),
"Native reach"): `native_reach_archives` refuses a linked archive whose owner (`THIRD_PARTY_OWNERS`
in `tools/build/one_definition/libraries.bzl` for a vendored one) is outside the closure, and
`native_reach_calls` (a Zig tool) refuses a string literal in library sources starting with such an
owner's prefix. The calls check is the only one that covers komira_uuid and komira_objectstore, by
construction: their reach is a Mojo call, which no `.so` records. Still open from slice 7: the
weak/common pair across two owners and the `callers` entry for a new `external_call` (slice 5). The packer
(slice 8) checks the `NEEDED` kind of reach on each built package: every komira owner in the `.so`'s
`NEEDED` is in the library's closure (planted: komira_http_core packed with its crypto dependency
removed must go red), and beta's install job loads each package with C installed alone (install
check 4), which catches komira_http_core's gap and neither of the other two.

## How each shared library is linked (PROPOSED, generalizing #681)

#681 links one library with `--whole-archive`, `-Bsymbolic`, `--gc-sections`, `-z defs` and a
generated version script (on #681: `native_archive` in `tools/build/native/defs.bzl`,
`native_link.sh`, `native_exports.sh`, `native_check.sh`, `callsites.c`). Per library:

| step | rule |
|---|---|
| contents, SONAME | the library's own archives, linked whole (dependencies' via `DT_NEEDED`); SONAME `lib<library>_native.so.1`, stable because a release pins every package to one version and build string (`runRequirements` writes `name ==version build`), until symbol versioning is decided. **Limit:** that holds inside one environment only. Two images built against different releases in one process (the SDK engine beside a program, or a user's Mojo shared library) share whichever `.so.1` loaded first, and an export the other image needs may be missing from it; symbol versioning is what would close this |
| `DT_RUNPATH` | `$ORIGIN` when the library has a komira `DT_NEEDED`, relaxing #681's `native_check.sh`, which refuses any run path; none otherwise. A program's `DT_RUNPATH` is not searched for its dependencies' dependencies (a `DT_RPATH` would be), so http_core's `.so` must find crypto's by its own |
| callers, declared | an owner's export list depends on its reverse dependencies, which a Buck2 target cannot discover, so each owner declares its `callers` (Mojo libraries and dependent owners' archives), as #681's rule for the one library does (`ctx.attrs.callers`). This replaces #685's central `members.bzl` |
| completeness lint | a root target reads every `mojo_library` from the build graph (as `//:src_layout` does) and every owner archive, runs the call-site reader, and refuses: an `external_call` into an owner by a library its `callers` omits; a weak or common symbol defined in two owners' archives (the one-definition gate's blind spot); a `src/` library depending on a vendored archive or `cxx_library` another library owns; a library whose Mojo closure lacks an owner it reaches (by a call, a direct archive dependency, or an archive its own archive needs; this last refusal **EXISTS** since #1325, per library rather than at the root: `native_reach_archives` and `native_reach_calls`, section "Three libraries reached an owner"). Without it a new caller passes its welded tests (static archives) and fails only at a consumer's link |
| version script | generated before any link: the callers' `external_call` names, plus the dependent archives' undefined symbols (their `symtab`, minus what they define) that this owner defines (s2n-tls needs many aws-lc functions Mojo never calls); everything else `local: *`. Inputs are archives and sources, never a linked `.so`: generate every list, link each owner before its dependents (`-z defs` against the owners' `.so`), then validate. A consumer cannot call an aws-lc function no komira package calls; the exported surface is what komira tests. A new caller changes the owner's artifact in the same release. Probe 3 (#1304) exported `komira_*` by wildcard instead, wider than this list and never narrower (crypto: 2837 `komira_awslc_` names), so the generated list is first linked in slice 5 |
| `-Bsymbolic` | each library binds its own references to its own definitions, so nothing loaded earlier can interpose on them |

**Checks, per library** (build time; "check N" means one of these, "install check N" a row of
beta's install job below; each with the planted defect slice 5 shows red, and check 7's real case in
slice 6):

1. every export starts `komira_`, and the exports equal the generated list (planted: an unprefixed
   export; a prefixed export not in the list);
2. after the dependents link, a separate action checks the other side: the callers' `external_call`
   names, united with the undefined `komira_` symbols in each dependent `.so`'s `dynsym`, are all
   exported (a subset check: `--gc-sections` may drop s2n-tls code the `.so` never reaches; planted:
   a caller name missing);
3. every **strong** undefined `komira_` symbol is exported by a declared `NEEDED` owner (replacing
   #681's "any strong undefined `komira_` is red", which http_core cannot meet). Weak undefined ones
   are allowed only if listed: aws-lc's four `komira_awslc_OPENSSL_memory_*` allocator hooks, undefined
   by design (**EXISTS:** `extra_symbols` in the native README). `-Bsymbolic` does not bind an
   undefined symbol, so any loaded object exporting such a definition would install allocator hooks
   into komira_crypto's aws-lc; probe 3's ONE and IR cases assert the hooks stay unbound (planted: a
   strong undefined `komira_` symbol no `NEEDED` owner exports);
4. `NEEDED` is glibc plus the declared komira owners, nothing else, with glibc named as its files:
   `libc.so.6`, `libpthread.so.0` and `ld-linux-x86-64.so.2` (probe 3's owners need the last one when
   they use thread-local storage; three need nothing); SONAME and `DT_RUNPATH` as above (planted: an
   extra `NEEDED`);
5. the highest `GLIBC_` symbol version is at or below the platform row's `os_floor` (`glibc-2.34`,
   read through `os_floor_version`), the floor the packer writes as `__glibc` (planted: a `.so`
   referencing a `GLIBC_2.38` symbol, linked outside the zig triple);
6. `DT_FLAGS` carries `DF_SYMBOLIC`, read as a bit: zig links with `-z now` by default, so every
   probe 3 owner has `FLAGS 0xa` (`DF_SYMBOLIC | DF_BIND_NOW`) (planted: the link without
   `-Bsymbolic`; probe 3 would see it but is never merged, so the build must);
7. every **strong** undefined symbol is either `GLIBC_`-versioned or a `komira_` symbol of check
   3, and every weak undefined one is on an explicit list: the four hooks, `sdallocx` (jemalloc's
   sized free, which aws-lc references weak and `:crypto_symbols` in `third_party/aws-lc/BUCK`
   already allows) and the C runtime's `__gmon_start__`. That is komira_crypto's list in probe 3
   (#1304); the zig C runtime adds no `_ITM_*TMCloneTable` pair. Slice 5 records it from its own
   first green link. No other name may stay unresolved, whatever flags the link used (planted in
   slice 5: a komira_crypto object referencing an undefined name that is neither `komira_` nor
   `GLIBC_`, linked without `-z defs`; in slice 6, the real case: snappy's `.so` linked without its
   static, local C++ runtime and without `-z defs`, leaving `_Znwm` undefined with `NEEDED` on glibc
   only, which checks 1 to 6 pass and the load fails at run time).

`elfsyms` (**EXISTS:** `tools/build/native/elfsyms.c`, modes `armap` and `symtab`) gains a `dynsym`
mode, as on #681, which also prints the dynamic section's `NEEDED`, SONAME, `RUNPATH`, `FLAGS` and
each symbol's version, for checks 4 to 7. The one-definition gate's existing negative,
`tools/build/tests/negative/shared_lib` `:duplicate_definition`, covers strong duplicates only,
which is the limit the table above states.

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

Proven for one library by #681's run test (2026-10-07: `mojo run -Xlinker -L<prefix>/lib -Xlinker -lkomira_native`)
and for the eight owners by probe 3's R1, R2 and B1 (#1304): `mojo run` with the `-l` flags in either
order, and `mojo build` with run path `$ORIGIN/../lib` set through the build wrapper's `--runpath`
(**EXISTS:** the compile wrapper's `cc` shim, `tools/build/mojo/tools/cc_shim.zig`, which drops every user `-rpath` in any spelling and
adds its own). So the user-spelled `-Xlinker -rpath` with conda's `mojo` (and whether it writes
`DT_RUNPATH` or `DT_RPATH`) stays **unproven after probe 3**, which built through the same
wrapper. The install validations run READMEs with `mojo run` only, so the whole `mojo build` consumer
path is unproven until the proposed build row (below) exists.

**A built program keeps `NEEDED` only on the owners it references** (probe 3, #1304): the link drops
the others, so B1's program needs http_core, crypto, async and libc and not compression, async_api,
metrics or scan_source, and LOG1's built program needs only libc's. Naming every owner at a
`mojo build` link is therefore harmless, and a missing `-l` there fails at link time, not at load.
Under `mojo run` a missing `-l` fails in the JIT (R1-MISS: "Symbols not found").

**Where a user gets these flags (open question 5).** On #704, kci_validate computes them from
metadata and injects them (`native_link_args`), so a README run passes with flags the README never
shows, and a user who copies the README fails with "Symbols not found". This per-package burden is
the main usability cost of decision 1. No build-time gate can catch a missing flag: the welded README
gate compiles the README's Mojo examples into one program linked against the closure's static
archives (**EXISTS:** `readme_gate` in `tools/build/mojo/readme.bzl`, `_link_tail` in `tools/build/mojo/defs.bzl`) and runs no shell
command, and the build has no installed `.so`. Only an installed-package README run can.

**(a)** the packer writes the exact commands into each README as a fenced `sh` block, the readme tool
parses it, and the install validations use those flags instead of computing their own (or refuse when
they differ), so a missing flag fails `beta_validate`; **(b)** a pkg-config `.pc` per package with
`Requires:`; **(c)** a `komira link-flags <package>` helper. Recommended: (a), (b) when a second
consumer needs it; both read the metadata kci reads.

**EXISTS (slice 10): option (a).** `komira_pack readme-link` appends a `## Linking` section to the
packaged README of every library whose closure ships a native file, after the source README's
last line (so every line keeps its number, and a README run's report names the repository's
line); the source README never carries it, and the packer refuses one holding a fence that
names the block's marker. The block is fenced `sh komira-link` and holds the two commands above with
`-L$CONDA_PREFIX/lib`, the owners ordered dependents first (by the number of shared libraries in
each owner's own closure, then by name) and the static holder archive on the `mojo build` line only.
Before the packer reads the file, the README examples tool's `link-check` must parse it back to the
arguments the packer wrote. kci's install validation reads the block with the same tool (`link`),
refuses it unless it is, word for word, what kci computes from the release's `depends` and
`lib_files`, and runs the README with the block's `mojo run` arguments (`src/kci_validate/readme_link.mojo`).
The `mojo run` line names no holder: the JIT object of question 2's option (A) is not built yet. So a
README whose closure ships a static archive (its block's `mojo build` line links one the `mojo run`
line does not: komira_log's holder, and so every library depending on komira_log) is run built: kci
runs the block's `mojo build` command into `<env>/bin` and executes that program instead of `mojo run`
(`run_readme` in `src/kci_validate/native_rows.mojo`, install checks 5 and 6 below).

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

Recommendation: **(A)**, confirmed by probe 3's LOG1 and LOG2 (#1304).

## System codecs (dlopened)

Each codec is opened at first use by soname, with `OwnedDLHandle`, by its owning library
(**EXISTS**):

| library | soname | conda-forge requirement (from #685's `system_libs.bzl`) |
|---|---|---|
| komira_compression | `libzstd.so.1`, `libbz2.so.1.0`, `liblzma.so.5` | `zstd >=1.5.2,<2`, `bzip2 >=1.0.8,<2`, `xz >=5.2.5,<6` (question 10: the library-only names) |
| komira_zlib | `libz.so.1` | `libzlib >=1.2.13,<2` |
| komira_lz4 | `liblz4.so.1` | `lz4-c >=1.9.3,<2` |

No other library under `src/` (tests aside) calls `OwnedDLHandle`.

- **EXISTS (slice 3, #1305, from #685):** `mojo_library(dlopen = [...])` declares the sonames
  (komira_lz4 and komira_zlib declare theirs; komira_compression its three, with slice 12); `tools/build/package/system_libs.bzl` maps each to its
  requirement, and analysis refuses a declaration the map lacks. The packer writes the requirement
  into `depends`, records `dlopen` in `metadata.json`, and marks the package REFUSED, so its release
  fails, when its sources open a soname its declaration omits or it declares one it never opens
  (`pack/conda_dlopen.zig`; this replaced the blanket refusal).
- **EXISTS (slice 3; kci's half since #1235, from #763):** kci accepts exactly those requirements,
  byte-equal to the map (`src/kci_release_set/system_libs.mojo`),
  plus the `__glibc` floor (slice 9), as the only non-komira, non-compiler requirements of a library
  package.
- **komira_lz4 and komira_zlib (#1188) go first, in slices 3 and 4.** They link no native code, so
  nothing in the shared-library work blocks them, and they prove the conda-forge requirement path end
  to end (pinned, installed from conda-forge, checked by kci) before the larger slices depend on it.
  `komira_compression` follows only with its own `.so` (slice 8), because it also links snappy.

**Loading from the environment's `lib/` with `LD_LIBRARY_PATH` unset (probe 3, #1304).** A built
program finds each codec through its own run path, `$ORIGIN/../lib`. Under `mojo run` the `dlopen`
comes from JIT code that lies in no ELF object; glibc attributes such a caller to the main program,
and an installed `<env>/bin/mojo` carries `DT_RPATH $ORIGIN/../lib`, so the loader's record reads
`search path=<env>/bin/../lib (RPATH from file <env>/bin/mojo)` and the codec comes from `<env>/lib`
(probe 3's DL case, both ways). That rests on `mojo` keeping a `DT_RPATH`: a `DT_RUNPATH` would also
apply to a `dlopen` attributed to the main program, but not to libraries its dependencies load. The
pinned `mojo`'s `DT_RPATH` also lists `$ORIGIN/mojo.runfiles/...` entries. When the environment lacks
the codec, both ways load the runner image's copy and the program still passes (DL-MISS), so a
passing README run proves nothing about the requirement. **komira_lz4 and komira_zlib carry this
hazard exactly as komira_compression does,** so their release waits on the loaded-from row
of beta's install job (install check 5: the `/proc/self/maps` row of earlier drafts), which slice 4
brings in for these two packages with a planted defect. The alternative, releasing them before
beta's install job exists with only probe 3's evidence, is question 6.

## Built once, promoted unchanged

The staged pipeline ([staged_pipeline.md](staged_pipeline.md), design, not built) rules that each
commit is built **once** and every stage promotes **the same files, by sha256**. Native artifacts add
no exception:

- **Where they are built.** Each `.so` is a build action of `<lib>_conda[release]`, so the `build`
  job (on the farm, with the release stamp) links it, runs checks 1 to 7 on it, and packs it into the
  library's `.conda`. No later job compiles or links anything: `beta`, `beta_validate`, `gamma`
  and `prod` download the run's `kci-release-<revision>` artifact.
- **How the set hash covers them.** The set hash has one line per artifact with the sha256 of its
  `.conda` (**EXISTS:** `set_hash.mojo`), and the `.so` is inside that file, so any change to a `.so`
  changes the hash and every later stage refuses the set before any effect (`KCI-E-SET-HASH`, exit 3).
  #704's separate native slot in the set is not needed and goes. Inside the package, `metadata.json`
  gains `lib_files` rows `{path, sha256, kind}` (`kind` `shared`, `link` for the unversioned
  symbolic link, or `static` for the holder archive), the way `doc_files` carries `{path, sha256}`
  today, so a check after install can name which file differs.
- **How beta exercises them.** Beta's farm job (`build`, its `TEST` step `test`) builds and tests
  the package tiers and, once the engine port lands, the e2e suites from source; those suites link
  static archives, so its payload comparison (each library's buck2 payload sha256 against
  `payload_sha256`, which is the `.mojoc`) **does not reach any `.so`**. The `.so` files are
  exercised by `beta_validate`, the hosted job that installs the built files with the pinned pixi
  from the `beta` conda channel (staged_pipeline.md's glossary; the channel in that role was named
  `gamma` before the switch M2, #1296). Every row runs with `LD_LIBRARY_PATH` unset:
  1. install pinned to the release's version, build string and `.conda` sha256 (**EXISTS:**
     `src/kci_validate/readback.mojo`, check 2);
  2. each installed `lib_files` row's sha256 equals the row (extends check 3, payload);
  3. each installed `.so`'s `NEEDED` resolves inside the environment; none names
     `libkomira_log_holder_jit.so.1`;
  4. **load every `.so`:** a program kci generates from `lib_files` (no README involved) calls
     `dlopen(path, RTLD_NOW)` on every installed `shared` row and refuses any failure, so an
     undefined symbol that lazy binding would defer to its first call is found now (for a `.so`
     linked without `-z now`: zig's default is `-z now`, so probe 3's owners carry `DF_BIND_NOW` and
     fail at load under either flag; `RTLD_NOW` keeps the row independent of how a `.so` was
     linked). It runs twice: once in the environment holding the whole set, and once per package
     with C in an environment holding only that package and its own requirements, which is what
     catches a `NEEDED` owner the package does not require (komira_http_core above; komira_uuid and
     komira_objectstore reach their owner from Mojo, which only slice 7's `native_reach_calls` covers);
  5. **the loaded-from row:** each README program (row 6) runs with the loader's record on
     (`LD_DEBUG=libs`, the record `tests//functional/runtime_libs:loader_trace` already reads for
     `runtime_libs`), and every komira `.so` and every codec its library's closure declares (the
     `metadata.json` `dlopen` sonames of the library and every library it depends on) it loaded must
     lie under `<env>/lib`, both paths resolved as realpath does first (the compiler reaches the
     environment's libraries through its own DT_RPATH `$ORIGIN/../lib`, so the loader names them
     `<env>/bin/../lib/<so>`). A library no package declares is out of scope: the Mojo compiler and
     its JIT load libz and libzstd themselves, from wherever the toolchain finds them, and that says
     nothing about the package. A declared codec loaded from outside the environment stays red. Like row 4 it runs in the whole set and per package alone: in the whole set
     another package may install a codec this package forgot to require, so a missing requirement
     is red only where nothing else installed ships that codec, which only the per-package run
     ensures. This replaces reading `/proc/self/maps`, which would need code in the program under
     test;
  6. every installed README run under `mojo run` with the owners' flags (question 5: the README's
     own `sh komira-link` block, which kci refuses unless it is what the closure needs; slice 10),
     except a README whose closure ships a static archive (komira_log's holder; the block's `mojo build`
     line links it and its `mojo run` line cannot, the JIT loading no archive): that one runs as the
     block's `mojo build` into `<env>/bin` and the built program executed, in the whole set and alone,
     until question 2's JIT object exists; and, new,
     when the library's closure links native files (its block is not empty), built with `mojo build` and
     the block's build words into `<env>/bin` and run. **Decision (slice 11): a README whose closure links
     no native file is not built.** Its block is empty, so there are no build words to check, and its
     built program would load no komira `.so`; with no run path to `<env>/lib`, a codec it opens would
     come from the system's search path, a red row 5 that says nothing about the package. Building
     every README would add one `mojo build` per package of the set to `beta_validate` for that;
  7. one program per owner of komira_http_core's closure beside a system OpenSSL (probe 3's IR1),
     installed from conda-forge as an extra requirement of that validation only.

  **Every owner is called, not only loaded.** Row 4 loads each `.so` but calls nothing; row 6 calls
  an owner's C only if its README does. Before slice 10, komira_metrics's README imported only
  `histogram` and `metrics_set` (its only `external_call` is in `explain_analyze_collect.mojo`), and
  komira_scan_source's README had no Mojo import, so a broken metrics `.so` or a missing
  `-lkomira_metrics_native` would have passed. **EXISTS (slice 10):** each owner's shared library
  has a README check (`[readme_calls]`, a validation, `native_so readme` in `tools/build/native/`):
  the welded README gate compiles each example's program a second time to an object
  (`[tests][readme][objects]`, for every library with a C library among its `deps`), in which every
  C function the example reaches is an undefined symbol, and the check refuses an owner none of
  whose README objects references one of its exports. The linked programs cannot be read for this,
  as this paragraph first proposed: `mojo build` strips their symbol tables. The check found seven
  owners whose README reached none of their C, not two: komira_metrics, komira_scan_source,
  komira_compression (no example), komira_async, komira_http_core, komira_objectstore and
  komira_parquet_codec, each of which gained an example that calls it (the armed flag, the id
  counter, snappy, the signal shim, s2n-tls, the file shim, the Brotli decoder); the other six
  owners' READMEs already called theirs (komira_db_sqlite's examples call SQLite, for one).
  Planted: komira_metrics's README without its example (build red); the installed README without `-lkomira_metrics_native` (row 6's `readme` row red,
  `src/kci_validate/tests/test_readme_link.mojo`); still to plant with slice 9's row 4: a metrics
  `.so` with an unresolved symbol, linked without `-z now` (row 4 red under `RTLD_NOW`, green under
  `RTLD_LAZY`, which is why the flag is fixed).

  Gamma runs none of these: it touches only real cloud resources. Prod publishes the same files.
- **What this rules out.** A fix to a `.so` (a run path, a missing export) is a new commit and a new
  build; no stage re-links, re-packs or strips. A release whose `.so` fails at install is stopped at
  `beta_validate`, not repaired downstream.

## What the evidence covers, and probe 3

**Proven.** Probe 2 (komira branch `exp/native-probe-2`, `tests/native_probe2/`, never merged) and
#681's run test of the one library (R1, B1, IR1, IR2): for **one** `.so` holding aws-lc, s2n-tls,
snappy and the shims, prefixing plus a version script plus `-Bsymbolic` gives no interposition either
way beside a system `libcrypto.so.3`/`libssl.so.3`, in either load order, where the leaky control
crashes the system's `SSL_CTX_new`. On #685, `:installed_crypto_run_test` repeats R1 and B1 and
`:installed_log_run_test` B1, from installed packages.

**Proven by probe 3** (#1304, results below), on linux-x86_64: several komira `.so` files in one
process; a `DT_NEEDED` between them found through `$ORIGIN`; the JIT loading more than one `-l`
library; one aws-lc per process when two packages reach it; a system codec `dlopen`ed from the
environment's `lib/` with `LD_LIBRARY_PATH` unset, under `mojo run` and from a built program.

**Still not proven:** a user-spelled `-Xlinker -rpath` with conda's `mojo` (section "Linking from
Mojo"); the generated version script (probe 3 exported `komira_*` by wildcard); an environment
installed from `.conda` packages (probe 3 assembled its environment as a build output); linux-arm64.

**Probe 3 (the plan; built as draft #1304, a farm target on a never-merged branch).** Every owner of
komira_http_core's closure, linked as above (crypto with aws-lc and the SHA-NI wrapper; http_core
with s2n-tls, `NEEDED` crypto, `DT_RUNPATH` `$ORIGIN`), plus the holder archive and JIT object. R1
and B1 go through komira_http_core's Mojo API and name every owner. Built cases go through
the compile wrapper (`mojo_compile`), so their run path is the wrapper's `DT_RUNPATH`, not a user-spelled `-rpath`.

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
| DL | `libzstd.so.1` opened by komira_compression, `liblz4.so.1` by komira_lz4 and `libz.so.1` by komira_zlib, each under `mojo run` and from a built program, `LD_LIBRARY_PATH` unset, on a runner image that also ships its own copy: the loader's record names the environment's copy |
| DL-MISS (must fail) | DL with the environment's codec removed: the loader's record names the image's copy, so the loaded-from row goes red rather than passing on the system library |

### Probe 3 results

Draft #1304 (never merged; `tests/native_probe3/` on its branch) built eight owners
(`libkomira_<lib>_native.so.1` for crypto, http_core, compression, async, async_api, metrics,
scan_source and libc), komira_log's holder archive and JIT object, and the codecs from conda-forge
into one environment. Every link passed `-z defs` on the first try. Each case is a farm target whose
action fails unless the case met its expectation; a must-fail case passes only when its run phase
exits with the named status and prints every line of its failure signature, and its `<case>_raw`
twin, which expects success, is red. All 18 cases and the report ran fresh: `Commands: 19 (cached:
0, remote: 19, local: 0)`, BUILD SUCCEEDED.

| case | expected | result |
|---|---|---|
| R1, R2 | pass | PASS: `mojo run` with the eight owners and `-lkomira_log_holder_jit`, in dependency order and reversed: SHA-256 and AES-256-GCM known answers, s2n init, a TLS 1.3 handshake over a socketpair |
| B1 | pass | PASS: R1's checks from a program built into `<env>/bin`, run path `$ORIGIN/../lib`, `LD_LIBRARY_PATH` unset |
| B2 | pass | PASS: only `-lkomira_http_core_native`; the program's `NEEDED` is http_core alone, and crypto is found through http_core's `DT_RUNPATH $ORIGIN` |
| R1-MISS | fail | FAIL with its signature: `JIT session error: Symbols not found: [ komira_ignore_sigpipe ]`, the only missing name, exit 1 |
| B3 | fail | FAIL with its signature: `error while loading shared libraries: libkomira_crypto_native.so.1: cannot open shared object file`, exit 127 |
| IR1 to IR4 | pass | PASS: R1 (`mojo run`) and B1 (built) beside the system `libcrypto.so.3`/`libssl.so.3`, loaded before ours (`LD_PRELOAD`) and after (`dlopen` `RTLD_GLOBAL`), the order checked by the program: the global `SHA256`, `EVP_*`, `RAND_bytes` are the system's, the system `SSL_CTX_new` works, and the four hooks resolve to 0 |
| ONE | pass | PASS: `komira_awslc_SHA256` through crypto's handle, http_core's handle and the global scope is one address, in crypto's `.so`; http_core exports no `komira_awslc_` name |
| LOG1 | pass | PASS: `-lkomira_log_holder_jit` under `mojo run`; the archive under `mojo build`, with no `NEEDED` on the JIT object |
| LOG2 | pass | PASS: a built program and a Mojo shared library, each with the archive: neither needs the JIT object, and each installs and reads its own engine |
| DL | pass | PASS: lz4, zlib and zstd round trips under `mojo run` and from a built program, each codec opened from `<env>/lib` (`LD_DEBUG=libs`) while the image ships its own copy |
| DL-MISS | fail | FAIL with its signature, both ways: the programs pass on the image's copies, and `LOADED_FROM <soname> OUTSIDE` names each of the three |

Each must-fail case was also shown red against a failure that is not its own (an empty http_core
`.so` for B3, a missing certificate for R1-MISS, only lz4 missing for DL-MISS), and ONE and LOG2
against their defect (a second aws-lc linked into http_core; the JIT object linked into built
images); #1304 lists the `Commands:` line of each. Its findings changed this doc: the `mojo run`
search path (section "System codecs"), check 7's weak list, check 4's glibc files, `DT_FLAGS` `0xa`,
the owners a built program keeps (section "Linking from Mojo") and the version-script note.

## Implementation: ordered slices

Each slice is one pull request unless noted, lands on `main` in this order, and starts with a check
that is red before it (on `main`, or on a planted defect named in the slice) and green after. "Go"
marks a slice that needs the project owner's explicit go before it runs or merges: an upload, a new
channel, a new package name, or a change to what a release publishes.

| # | slice | red before it | go |
|---|---|---|---|
| 1 | **Probe 3**, a farm target on a scratch branch. **Done:** draft #1304 (never merged); results recorded in this doc by #1313 (section "Probe 3 results", with its `Commands:` line, `local: 0`) | R1-MISS, B3 and DL-MISS must fail and are shown failing; the other cases are the findings | none (nothing uploaded, nothing merged) |
| 2 | **Drop the `komira_native` exemption** (done by #1361, merged 2026-10-11), which served only the superseded plan: the skip in `_ORDER_CHECK` (`tools/build/package/release_set.bzl`), the fixture `release_order_exempts_komira_native` (`tools/build/package/BUCK`; its `release_order/requires_komira_native.json` stays, under the must-refuse fixture `release_order_refuses_a_komira_native_requirement_listed_later`), the mentions in `release_set.bzl` and `tools/build/package/README.md` | the fixture turned must-refuse ("a requires komira_native, listed after it") passes on `main`, where the skip exempts it: red | none |
| 3 | **dlopen declarations** (#1188): `mojo_library(dlopen)`, `system_libs.bzl`, the packer writes the requirement and `dlopen`, kci accepts exactly the map's requirements; `komira_lz4` and `komira_zlib` declare their sonames (in the build only, not in the release) | the packer fixture `fx_dlopen_conda` (`tools/build/tests/functional/conda.sh`) is refused today; new fixtures: a source opening an undeclared soname refused, a declaration missing from the map refused, kci refusing a requirement off the map; mutants: kci accepts any `depends`, the packer omits the `depends` row (a package without `lz4-c` must be refused at the build) | none (nothing declared in the release) |
| 4 | **komira_lz4 and komira_zlib released** (**declared** with slice 12, in one change that merges after slice 11; the loaded-from row is slice 11's): the loaded-from row (install check 5) in `kci_validate` for packages with `dlopen`, run by `beta_validate`; the two declared in `release/artifacts.textproto` and `release_set.txt`. Needs slice 1's DL case green, slice 3, and the staged pipeline's P4 (question 6 for the alternative) | planted: a komira_lz4 package without its `lz4-c` requirement (and komira_zlib without `libzlib`), installed alone on an image that ships its own `liblz4.so.1`/`libz.so.1`: the README run passes, the per-package loaded-from row is red (red only because nothing else installed ships the codec; the whole-set run may stay green if another package pulls it in) | **Go**: two new package names on the channel |
| 5 | **`elfsyms dynsym`** and the per-library link rule (`native_archive` reworked from #681, `callers`, version-script generator, checks 1 to 7) over **komira_crypto only**, no package change | the planted defect of each of checks 1 to 7 (above), each red | none |
| 6 | the rule over every owner in the table above, including http_core's `NEEDED` and `DT_RUNPATH` | planted: http_core without `DT_RUNPATH` (B3's check at build time), a caller dropped from `callers`, snappy's `.so` without its C++ runtime (check 7's real case: `_Znwm` undefined) | none |
| 7 | **completeness lint**: **done in part** by #1325 (the per-library `native_reach_archives` and `native_reach_calls` validations, and the three missing Mojo dependencies: komira_uuid and komira_http_core on komira_crypto, komira_objectstore on komira_fs); open: the weak/common pair and the `callers` entry | was red on `main` before #1325: those three libraries; #1325's planted cases are the `native_reach_case` targets in `tools/build/tests/negative/native_reach`; still to plant: a weak pair across two owners, a new `external_call` with no `callers` entry, a library depending on another owner's `cxx_library` | none |
| 8 | **the packer**: `lib_files` (`shared`, `link`, `static`), `native_owns`, `native_links`; the `.so` into the library's `.conda`; `__glibc >=2.34` written from the platform row's `os_floor` beside `__linux`; every `NEEDED` owner in the library's closure; `_conda_facts` stops refusing a library whose every linked archive has an owner in its closure; komira_log's holder archive and (with 2A) JIT object; brotli prefixed before komira_parquet_codec is packaged (question 4) | `_conda_facts` refuses komira_crypto today; planted: a `.so` whose `lib_files` sha256 differs, an archive with no owner in the closure, a holder JIT object named in a built `.so`'s `NEEDED`, komira_http_core packed with its crypto dependency removed; mutant: the packer writes a constant `__glibc` instead of reading `os_floor` (a fixture platform row with another floor goes red) | none (builds only; nothing declared) |
| 9 | **kci reads `lib_files`** (in part on `main`, #1391: the `lib_files` reader, the `__glibc` acceptance in PUBLISH, and in `src/kci_validate/native_install.mojo` install checks 2, 3 and 5 and a `DF_SYMBOLIC` row (per-library check 6 on the installed bytes), run by `beta_validate` since slice 11, which also added install checks 4, 6 and 7 in `src/kci_validate/native_rows.mojo`; the rest of this row is open): the generalised `native_link_args` (every pin, dependency order, or the README's flags with 5a), readback of `lib_files` sha256, install checks 3, 4, 6 and 7 (the generated load program, whole set and per package alone; the `mojo build` README row; the system OpenSSL row), and install check 5 extended from slice 4's `dlopen` packages to every package; kci accepts the one `__glibc` requirement, equal on every package of the set; the `native` kind and `_native_depends` never land | kci fixtures, each refused, with a mutant per check: a missing owner flag, a `.so` with an unresolved `NEEDED`, a `lib_files` sha256 mismatch, a JIT object in a built image's `NEEDED`, a `.so` with an unresolved symbol, linked without `-z now` (red only under `RTLD_NOW`), a package missing an owner requirement installed alone, two different `__glibc` values in one set, an unprefixed export planted in crypto's `.so` (install check 7: the system OpenSSL's `SSL_CTX_new` crashes, as in probe 2's leaky control) | none |
| 10 | **README link commands and every owner called** (question 5a; **done**: section "Where a user gets these flags" and the "Every owner is called" paragraph say what landed, including the five further owners the README check found): the packer writes the `sh` block; the readme tool parses it; the install validation uses it or refuses a difference; the build refuses an owner whose README program references none of its exports; komira_metrics's and komira_scan_source's READMEs gain an example reaching their C | planted: a README without an owner's `-l` (install validation red); komira_metrics's README without its new example (build red) | none |
| 11 | **beta wiring** (**EXISTS**: `src/kci_validate/native_rows.mojo`, called by `run_install_env`): install checks 2 to 7 run in `beta_validate` for every native package (one whose `metadata.json` has `lib_files` or `dlopen` rows, so a package that forgot its codec requirement is still native; a release with none gets no row); row 6 builds the READMEs whose closure links native files (install check 6's decision). They live in kci's CONDA_INSTALL_ENV validation, which `beta_validate` already runs, so `kci.yml` does not change and the rows do not wait for the staged pipeline's P4 (which rewrites the job, not the rows): this takes question 7's alternative. Slices 4 and 12 declared native packages (#1592), so the rows run from the first `beta_validate` after this slice lands. Row 7 checks every owner, which includes komira_http_core's closure | nothing on `main` can be red (`beta_validate` runs none of these rows); shown by mutants on the new job: a `.so` changed after `build` is refused by step 4b (mutant: skip step 4b in `beta_validate`), and a planted `.so` with an unresolved symbol makes row 4 red | **Go**: it changes the release (given) |
| 12 | **the release set**: declare the first native batch (the owners and their dependents up to the cloud SDKs, question 9) in `release/artifacts.textproto` and `release_set.txt`. **Declared** (with slice 4): the owners, the `kci_*` libraries and their closure, the cloud SDKs among it; `release_set_check` gives each native library its `native` target. Not declared: komira_db_sqlite and komira_parquet_codec (no `native` yet), and kci_build, kci_publish (their library targets are `<name>_lib`, so no artifact named for the package passes the artifacts test's `<name>_conda` rule) with kci_validate and kci_cli, which require them. Taken back out once, because `beta_validate`'s README check refuses a member whose package ships no README or whose README holds no ` ```mojo ` example (kci_cloud_gcp and kci_composites had no README; komira_arrow, komira_arrow_ipc, komira_column_kernels, komira_join_assembly, komira_plan_expr, komira_plan_ir, komira_plan_stats and komira_secret_env had no ` ```mojo ` example), with the 19 members that require one of them; all 29 are declared again now that each of the 10 ships a README with a runnable ` ```mojo ` example, which its library's build runs as the welded `[tests][readme]` test | `release_set_check` red on a batch member listed before an owner it requires | **Go**: new package names on the channel, a change to what beta and prod publish |
| 13 | **gamma_validation.md** rewritten (done by #1361, merged 2026-10-11): its `komira_native` rows are replaced by a pointer to this doc's beta install checks, and `gamma_validation_decisions.md` likewise; its stage and channel text (gamma publishing to and installing from a `gamma` conda channel, which was `kci.yml`'s before M2) is rewritten to #1184's glossary, replacing its "Vocabulary" note, since #1184 does not edit this file | `komira_native` joins the root `retired_names` lint (root `BUCK`), which refuses a retired name outside a dated history note: red while either doc still carries it (the doc links lint cannot go red on a content rewrite); every mention left in this doc moves onto a dated history line. Slice 2's exemption in `tools/build/package` was deleted with this slice; the lint entry landed in a follow-up that first moved this doc's remaining mentions onto dated history lines or reworded them (#1313, merged, recorded probe 3 but left them in place). `retired_names` reads the whole doc tree; its `unchecked` list leaves out one file, `tools/build/package/release_order/requires_komira_native.json`, the metadata of the must-refuse fixture that keeps the exemption gone (JSON holds no comment, so no date) | none |

Slices 1, 2 and 3 are independent; 4 needs 1, 3 and P4; 5 to 10 are a chain (5 needs nothing
earlier); 11 needs 9, 10 and P4; 12 needs 11; 13 needs 2. **No library with native code or a
dlopened codec is declared before beta's install job runs its rows** (question 7). Issue #1187
closes when slice 12 has declared every library it lists that can ship (SQLite's owner excepted
until it has welded tests).

## What happens to each open PR

| PR | fate |
|---|---|
| #672 symbol prefixing | **Merged.** `tools/build/native/` on `main`. Every per-library `.so` relies on it. |
| #681 one shared library for all of komira's C | **Superseded.** Its `native_archive` (in `tools/build/native/defs.bzl`), export generator, `callers` attribute, call-site reader, link script, checks, `elfsyms dynsym` and run test survive into slices 5 and 6, reworked to one library per owner. Kind `shared` becomes "in its owner's `.so`"; `per_library` becomes "ships a static archive". The undefined-symbol rule changes as in check 3. |
| #685 packer | **Superseded; parts survive** into slices 3 and 8: its extension of `native_archive` (forwarded providers, the `name` field), `lib_files`, `dlopen` with `system_libs.bzl` and its drift check, "welded tests link the archives", `conda_prefix` installed run tests. Dropped: `members.bzl` (by `callers` and the completeness lint), `conda_native_package`, the requirement on the one library's package. |
| #695 kci reads kind `native` | **Superseded; parts survive** into slice 9: the `lib_files` parser (`LibFile`, link rows, `has_lib_files`), read on a `library`. Dropped: the refusal of link rows on a library, the `native` kind, `is_native`, the native case of `is_member_kind`, `_native_depends` in `src/kci_publish/verify.mojo`. |
| #704 kci_validate, release-set native slot | **Superseded; parts survive** into slices 3 and 9: `native_link_args` over every library pin in dependency order (deferring to the README's flags with 5a); the system-library acceptance from #763 (`src/kci_release_set/system_libs.mojo`). Dropped: the native member and slot (the set hash already covers each `.so`), the one library's `-l` flag, #761's member for its package (its library declarations return in slice 12). |
| #1140 release set refuses an undeclared requirement | **Closed unmerged.** A member requiring an owner the set omits is refused by the `install-set` validation (in `beta_validate` under staged_pipeline.md), which cannot install `komira_all` from a channel holding only the build's packages, before anything promotes; a build-time duplicate is not wanted. Neither refuses a missing requirement (section "Three libraries reach an owner"): slice 7's lint, slice 8's packer check and install check 4's per-package run do. |

## Open questions for the project owner

1. **Per-package shared libraries, no static archives except per-library state.** Recommended: yes.
2. **komira_log's holder under `mojo run`:** (A), (B) or (C) above. Recommended: (A), confirmed by
   probe 3.
3. **The `.so` in the library's own package, or a separate `<library>_native` package** the SDK
   engine could also require. Recommended: the library's own; split only if something needs the C
   without the Mojo. A separate package doubles the new package names slice 12 asks a go for.
4. **Prefix brotli (and SQLite) before komira_parquet_codec (and komira_db_sqlite) ship.**
   Recommended: yes, by `tools/build/native/`. An unprefixed exported `BrotliDecoder*` would
   interpose on a system `libbrotlidec`.
5. **Where a user gets the link flags:** (a), (b) or (c) in "Linking from Mojo". Recommended: (a).
6. **komira_lz4 and komira_zlib: wait for beta's install job, or accept the risk.** Recommended:
   wait. Their go (slice 4) needs probe 3's DL case green and the loaded-from row running in
   `beta_validate` (the job exists since M2, #1296; slice 11 wired the rows into it). The alternative is to declare
   them after slice 3 with only probe 3's evidence: today's installed README run would pass even if
   the runner's own `liblz4.so.1` or `libz.so.1` were the copy loaded, so a package missing its
   conda-forge requirement could ship. Choosing it means accepting that risk until P4.
7. **Where the native install checks run before the staged pipeline is built.** Recommended:
   nowhere in a release; they run only in beta's install job (slice 11, after P4), and no library
   with native code or a dlopened codec is declared (slices 4 and 12) before then. Gamma no longer
   installs packages, so the earlier draft's interim home (gamma's `validate`) is gone. The
   alternative is an interim run in today's `beta_validate` job (EXISTS since M2, #1296) before P4:
   earlier releases, and a job that P4 rewrites. **Taken by slice 11:** the rows run in today's
   `beta_validate` as part of kci's CONDA_INSTALL_ENV validation, so P4 rewrites the job without
   touching them.
8. **Keep the glibc floor at 2.34?** The floor already exists: `os_floor` `glibc-2.34` in
   `tools/build/platforms/table.bzl`, which zig links against. Recommended: keep it; the packer
   writes it as `__glibc >=2.34` (slice 8) and per-library check 5 reads the same cell. Changing it is a change
   to that table row, for every built binary, not a packaging decision.
9. **The first native batch** (slice 12): the owners plus every dependent of #1187 in one go, or the
   owners and kci first. Recommended: owners plus `kci_*` first (kci publishes kci), then the rest
   in one batch; each batch is a go.
10. **conda-forge names for the system codecs.** #685's map requires `zstd`, `bzip2` and `xz`, which
    also install the command-line tools. conda-forge publishes `liblzma` (library only, ships
    `liblzma.so.5`), the way `libzlib` is used for zlib; whether a library-only package exists for
    zstd and lz4 is not checked here. Recommended: require the library-only name wherever one
    exists, and have slice 3 check every name in the map against conda-forge's repodata (the
    package's files must include the soname) and record the result in `system_libs.bzl`.

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
