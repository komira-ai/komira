# Conda packages of the Mojo libraries

A Mojo library published as a conda package (a `.conda`) installs one file,
`lib/mojo/<name>.mojoc`, into the prefix. The Mojo compiler's default import
path is that prefix's `lib/mojo`, where `std.mojoc` already sits, so a program
that imports the library compiles with no `-I` flag and no activation script.
Nothing here uploads anything: the build produces files, a digest and a
manifest; publishing is a separate, gated step.

> **A registry name and version, once claimed, is permanent in practice.**
> Lock files pin the sha256 of every file, so replacing or deleting a version
> breaks whoever locked it, and a registry that allows an overwrite makes
> permanence a policy, not a mechanism. The first upload to a public channel is
> a one-way door: it is gated by an approved list of names (below), a dry run
> that uploads nothing, a protected environment, and a one-package canary
> before the rest.

## One package, generated

No package is written by hand. [`BUCK`](BUCK) makes one call,
`conda_release(entries = APPROVED)`, and
[`conda_set.bzl`](../../tools/build/package/conda_set.bzl) declares a
[`conda_package`](../../tools/build/package/conda.bzl) for every row of
[`names.tsv`](names.tsv): **adding a row adds the package** (the generated
`names.bzl` is the copy of the list the macro reads at load time, below).
The same call declares the metapackage and the release set (next section).

`./buck2 build //packaging/conda:komira_encoding` writes `komira_encoding.conda`.
Everything about it is derived from the library, so the package cannot disagree
with it ([`conda.bzl`](../../tools/build/package/conda.bzl) lists each):

| fact | where it comes from |
|---|---|
| name | the library's import name (the `.mojoc` basename); the target is named for it; it must be in `names.tsv` and start with `komira_` |
| run requirements | the platform guard (`__linux`), exactly `mojo-compiler ==<pin>`, then each **direct** dependency of the library at the same version, sorted. Direct only: every package is released in lockstep, so the solver's closure is the build's |
| subdir | the target platform's constraints (a `select`), never an attribute. Only `linux-64` is written: a `.mojoc` cannot be cross-compiled, so another subdir needs a build for that platform |
| payload | the library's gated `.mojoc`, so the package cannot exist until the library's own welded tests pass |
| version | `<prefix>.<N>`, below |

A package is refused, at analysis or by the packing tool, when: its name or a
dependency is not in the approved list or lacks the prefix; its target is not
named for the import name; the library has no tests; the library links native
code (a `.mojoc` holds none, so a consumer would fail at its own link); or the
library opens a shared library by name at run time (`OwnedDLHandle`), whose
conda package this tool does not yet derive.

## The release set and the metapackage

A release is a SET: one package per approved name, all at one version, and one
metapackage. Three targets of this directory make it:

| target | what it is |
|---|---|
| `//packaging/conda:<name>` | the package of one approved library (generated) |
| `//packaging/conda:metapackage` | a package named by the one line of [`METAPACKAGE`](METAPACKAGE), with **no file** and run requirements that are exactly the platform guard and **every** approved library at exactly this version. Installing it installs the whole release; the name is a claim of its own and is reviewed like a row of the list |
| `//packaging/conda:release_set` | one directory: every package as `<name>.conda`, and `release_set.json` |

`release_set` is written only after `komira_pack conda-set` verified the set as
a whole, reading every package back (not only its manifest) and reporting every
problem it finds, not the first:

- every approved name has a package, and nothing else is in the set;
- one version, one subdir, one source commit and one approved-list digest across
  the set, and every package stamped (an unstamped build has no set at all);
- every requirement of a library is a library of the set at the set's own
  version, or the platform guard, or the compiler at its exact pin, and nothing
  outside the set;
- the metapackage pins exactly the guard and every library;
- each manifest agrees with its package's own bytes (sha256, size, name,
  version, depends, file name).

`release_set.json` (sorted compact JSON): `schema`, `artifact_type`
(`conda-release-set`), `version`, `subdir`, `source_commit`,
`approved_names_sha256`, `mojo_pin`, `metapackage`, `member_count`,
`upload_order` (channel file names: the libraries sorted by name, **the
metapackage last**) and `artifacts` in that order, each with `role` (`member` or
`metapackage`), `name`, `version`, `subdir`, `file_name` (the channel's),
`path` (inside the directory), `sha256`, `size`, `depends`, `source_commit`.
**An uploader of a set reads `release_set` (and `release_set[manifest]`) and
nothing else.**

Why a metapackage, and one package per library: a `.mojoc` needs the full
closure of its dependencies on the import path at the consumer's compile, and
the closure is the package set, so the solver does the closure (exact pins).
The metapackage is the one name a user installs; a registry that receives it
LAST makes it the switch (a user who asks for a library directly can see that
library when it lands). Versions are in lockstep, so every release is a whole
new set; a per-library version that moves only when the library's closure
changes is possible later and is not done.

### Publishing a set (nothing here uploads)

The upload step belongs to the release tooling, and for a set it must:

1. refuse a set whose `release_set.json` it cannot re-verify (the rules above,
   and the five checks of "What an uploader reads" below, which apply to every
   member and to the metapackage);
2. read the channel first: for each file, absent, present with the same sha256,
   or present with another sha256. **Any file present with another sha256 stops
   the whole publish before a byte is sent**;
3. upload the missing libraries (in parallel is fine: a library whose pins are
   not published yet is unsolvable, not broken), **never** with an overwrite
   flag, re-reading the channel after any error before trying again;
4. only when every library is present, read every one back from the channel and
   compare its sha256 with the manifest;
5. upload the metapackage last, and read it back.

A partial failure is repaired by running the same publish again: what is
present and identical is skipped. The registry is not known to offer
transactions or an atomic multi-file visibility (**unverified**), so the order
above, not the registry, is what the set relies on.

## What an uploader reads, and must do

**The output contract: an uploader reads `<package target>[release]` and
nothing else.** It is a copy of the package, made only after
`[release_check]` passed, so it does not exist for an unstamped build, a stamp
without its source commit, or a non-positive commit time. Its nested
sub-targets are `[release][file]` (the same file), `[release][manifest]` and
`[release][digest]`.

| sub-target | content |
|---|---|
| `[release]`, `[release][file]` | `<name>.conda` |
| `[release][digest]` | one line, `sha256:<hex>` of that file |
| `[release][manifest]` | JSON, sorted keys: `schema`, `artifact_type` (`conda`), `name`, `version`, `subdir`, `build`, `build_number`, `file_name` (the channel's file name), `sha256`, `size`, `payload_path`, `payload_sha256`, `depends`, `mojo_pin`, `stamped`, `source_commit`, `label`, `approved_names_sha256` |
| `[release_check]` | the marker of `komira_pack conda-check --require-stamped`, which reads the package back (zip, both zstd streams, both tars, every property below) and refuses an unstamped version, a stamp without a full 40-digit source commit in the manifest, and a commit time that is not positive |
| `[default]`, `[file]`, `[manifest]`, `[digest]` | **development outputs**, built whether or not the package was stamped. An unstamped one is `<prefix>.0`, and uploading it would claim `<prefix>.0` for good. An uploader never reads them |
| `[check]` | the marker of `komira_pack conda-check`; it takes the approved-names lint as an input, so a build of any package runs that lint |

Before the first byte goes to a registry, the publish job must do all of the
following, each of which is a stop (never a retry) when it fails:

1. **Refuse `stamped: false`.** A manifest that says so is not a release,
   whatever target it was read from.
2. **Re-derive the stamp from git.** At a clean, full-history checkout of
   `main` at the release commit, run
   [`tools/build/package/release_version.sh`](../../tools/build/package/release_version.sh)
   and require its `version=` to equal the manifest's `version`, and its
   `commit=` to equal the manifest's `source_commit`. The build cannot read git,
   and a release check cannot tell a derived stamp from a typed one:
   `-c komira.package_stamp=999999999` passes it, and would shadow every future
   version of that name. Only this comparison ties the stamp to history.
3. **Recompute the approval.** The manifest's `approved_names_sha256` is only a
   value the build wrote; recompute it from `names.tsv` at the release commit
   and require equality:
   `grep -vE '^(#|$)' packaging/conda/names.tsv | cut -f1 | LC_ALL=C sort | sha256sum`
   (the digest of the sorted names, one per line). Require the package's name
   to be in that list. `komira_pack conda-check` recomputes it from the list it
   is given and refuses a different digest, but the uploader must not trust a
   check that ran on the builder's own file.
4. **Build once, under the default isolation directory** (below), upload the
   file that build produced, and re-read its sha256 against
   `[release][digest]` before the upload.
5. **Treat "same name and version, different sha256" as a stop.** The registry
   never overwrites. It is never answered by building again.

The names lint covers `packaging/conda/BUCK` only. What stops a package from
being checked against another list is the rule itself: a `conda_package` that
states `names =` is refused outside the `tests` cell, so the one list is
`names.tsv`, and the lint is an input of every package's check. What is **not**
checked: that the library behind a package is the one on the list's label (the
name must equal the library's import name, nothing more); the release job's
rebuild from the release commit is the control for that.

## Reproducibility

The bytes are reproducible, so the file's sha256 is the package's identity.
Packing is a pure function of the payload: the same `.mojoc` always gives the
same package, no clock is read, the tars are the deterministic ones
`komira_pack` writes, the zstd streams are made of raw blocks (valid zstd that
no encoder version can change; a `.mojoc` is compressed already), the JSON is
sorted and compact, and `info/index.json` carries the commit time given at
stamping. The condition comes from the compiler, not the packing:

A `.mojoc` records the relative path of the sources it was compiled from
(`buck-out/<isolation dir>/art/...`: seven source files and the package
directory for `komira_encoding`, eight places in all), so **the same library
built under two `--isolation-dir` names is two different files**, and so are
two packages made from them. Measured, on the farm and with no cache: the
two `.mojoc` differ in exactly those eight bytes and nothing else, and the
header's content hash is equal. The wrapper's existing `-strip-file-prefix`
(which `mojo build` honours) does not change a `precompile` output, with the
absolute or the relative prefix; so this is **not fixed here**, it is a
documented gate on the release job, with a follow-up (below):

- **build once, under the default isolation directory** (no `--isolation-dir`),
  and upload the file that build produced;
- **never rebuild and retry**: a second build is a different file under the
  same name and version, which the registry refuses for good;
- **"same name and version, different sha256" is a stop**, never a rebuild;
- the release job's checkout location does not matter (the paths are relative to
  the checkout), the isolation directory does; reproducibility across two
  different farm workers is **unmeasured**.

`tools/build/tests/functional/conda.sh` pins what is true: two uncached builds
in fresh daemons under one isolation directory give one sha256.

The `.conda` is a zip of three stored members (`metadata.json`,
`pkg-*.tar.zst`, `info-*.tar.zst`); it is zip version 2.0 (zip32), not the zip64
of Modular's own packages, which no tool tried here required (conda-format
readers: `unzip`, `zstd`, `tar`, and pixi's rattler; conda, mamba and the
registry's own acceptance of a zip32 file are untried).

## Using a package

A consumer lists the komira channel and the Mojo compiler's channel. The
package requires `mojo-compiler ==1.0.0`; a project that already depends on
`mojo` is satisfied by that (the `mojo` package pulls exactly that compiler),
and a project without it gets the compiler from the second channel:

```toml
[workspace]
channels = ["<the komira channel>", "https://conda.modular.com/max", "conda-forge"]
platforms = ["linux-64"]

[dependencies]
komira_encoding = "==0.1.<N>"
```

`import komira_encoding` then compiles with no `-I` and no activation script.
`tools/build/tests/functional/conda.sh` does exactly this from a `file://`
channel.

## Version

The version is `<prefix>.<N>`, in lockstep across every package:

- the prefix is the one line of [`VERSION_PREFIX`](VERSION_PREFIX) (currently `0.1`);
  nothing else states it;
- `N` is `git rev-list --count --first-parent C`, where `C` is the newest
  commit at or below the release commit that touches anything but
  documentation (`docs/`, any `*.md`, `.github/`), so a change to what is
  published always raises it and a documentation commit never does. A release
  job gets it, and the commit time, from
  [`release_version.sh`](../../tools/build/package/release_version.sh) and passes
  them as `buck2 build -c komira.package_stamp=<N> -c komira.package_commit=<sha> -c komira.package_timestamp_ms=<ms>`.
  They are read in the macro, so only the packages are keyed by them, never a
  compile;
- a build with no stamp is `<prefix>.0`: it builds as a development output, and
  `[release_check]` (hence `[release]`) refuses it;
- the commit the stamp was derived from is `-c komira.package_commit=<sha>`
  (`release_version.sh` prints the whole `buck_args` line); a stamped package
  without it, or with one that is not 40 lowercase hex digits, is refused, and
  `[release_check]` refuses a package whose commit time is not positive. These
  prove the stamp is *accompanied* by a commit, not that it is the right one:
  see step 2 of the uploader's list above.

## The approved list

[`names.tsv`](names.tsv) is the only list of what may be published: a name not
in it is not published, and a listed package's direct dependencies must be
listed too. Adding a row is the approval to claim that name, so review it as
that. The sha256 of the sorted names is in every manifest
(`approved_names_sha256`), so an approval can be bound to the exact list (by an uploader that recomputes it:
step 3 above).
[`names_lint`](BUCK) checks its shape (rows of name, label and reason; the
prefix; the flat `//src/<name>:<name>` label; sorted and unique), that
[`names.bzl`](names.bzl) is exactly what
[`gen_conda_names.sh`](../../tools/build/package/gen_conda_names.sh) makes of it
(regenerate with `sh tools/build/package/gen_conda_names.sh packaging/conda/names.tsv > packaging/conda/names.bzl`),
that this directory declares no `conda_package` by hand and calls
`conda_release` once, and that no call names another list.

## Not done yet

- `linux-aarch64` and `osx-arm64` (they need their own payload build and an
  architecture guard);
- libraries that link native code, and libraries that open a shared library
  at run time (both refused by name rather than published incompletely);
- the upload step with its dry run and its approval gate (the set it reads is
  above; the step is not written);
- a per-library summary (a package's channel text is derived from its name);
- **a `.mojoc` that does not record the isolation directory** (follow-up, to
  be filed on the issue tracker): compile `precompile` from a private working
  directory with the sources staged at a fixed relative path (the wrapper must
  then absolutize every `-I` and the `-o`), or ask the compiler for a
  path-remapping option; then the gate in "Reproducibility" can be a test
  (two isolation directories, one sha256) instead of a rule for the release job;
- the rest of the libraries: the list holds the one canary. The generated set
  is exercised on a TEST list of the libraries that can be built
  (`tools/build/tests/conda_set`, not an approval).

How it is tested: [`conda.sh`](../../tools/build/tests/functional/conda.sh).

## Review log

The findings of the review of the first version of this change, each checked
against the code and the logs, and what was done.

| # | finding | verdict | what changed |
|---|---|---|---|
| 1 | `conda.sh` read the build output path once, early; under local execution the stamp section builds the same target with another configuration at the same path, so the install step installed the stamped file under the unstamped file's checksum | **correct**, measured | the script copies the built file, manifest, digest, check marker and library into its scratch directory right after the build and uses only the copies; the whole script was run in both modes (farm and local) |
| 2 | the default output of a package target is the unstamped `0.1.0`; only `[release_check]` refuses it, so an uploader reading the obvious target would claim the version for good | **correct** | `[release]` (nested `[file]`, `[manifest]`, `[digest]`) is joined on `[release_check]` and is the only artifact an uploader reads; it is in the output contract above; the unstamped outputs are named development outputs; an uploader refuses `stamped: false` |
| 3 | nothing ties the stamp to git; any `-c komira.package_stamp=<9 digits>` passes; a stamped package with timestamp 0 or below passes | **correct** | the manifest carries `source_commit`; a stamped package without a full commit id is refused by the packer, and `[release_check]` refuses a missing or malformed commit and a commit time that is not positive; `release_version.sh` prints the commit and passes it; the publish job re-derives `version` and `commit` at a clean full-history checkout and compares both with the manifest (step 2). The check cannot read git, so it cannot refuse a typed stamp: that comparison is the only control, and it is stated as one |
| 4 | the approval is only as strong as `approved_names_sha256`, which nothing consumes; `names` is overridable on any `conda_package`; the lint scans only `packaging/conda/BUCK` and is not an input of the package | **correct** | the check recomputes the digest from the list it is given and refuses a different one; the uploader's recomputation is a one-line command (step 3), pinned by a test; `names =` is refused outside the `tests` cell; `names_lint` is a dependency of every package of the real list, so a direct build runs it (a test reads the dependency graph). **Not done:** a package whose library is not the one on the list's label is not refused (the name must equal the library's import name, nothing more); the release job's rebuild from the release commit is the control |
| 5 | the same library built under two isolation directories gives two files; a release must be a gate, not a sentence | **correct**; the cause was measured | the cause is the compiler recording the source paths (above). A fix with the wrapper's `-strip-file-prefix` was tried, absolute and relative, on the farm without a cache, and does not change a `precompile` output. It is a gate on the release job (build once under the default isolation directory, never rebuild and retry, "same name, different sha256" is a stop) and a follow-up (Not done yet) |
| 6 | a consumer is not told which channels to list | **correct** | "Using a package" above, and `docs/releases.md`; the install test now takes the compiler from the `max` channel. `mojo-compiler ==1.0.0` is satisfied by an existing `mojo` dependency |
| 7 | test-only epoch values may trip a date gate | **correct, cheap** | the test uses small epoch values (decades before this project) and one day of milliseconds, no date of this project |

Not verified: that the registry accepts a zip32 `.conda`, and that conda,
mamba or micromamba install one (only pixi/rattler was tried).
