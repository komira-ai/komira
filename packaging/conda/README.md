# Conda packages of the Mojo libraries

A Mojo library published as a conda package (a `.conda`) installs one file,
`lib/mojo/<name>.mojoc`, into the prefix. The Mojo compiler's default import
path is that prefix's `lib/mojo`, where `std.mojoc` already sits, so a program
that imports the library compiles with no `-I` flag and no activation script.
Nothing here uploads anything: the build produces files; publishing is a
separate, gated step that belongs to the release tool (kci).

> **A registry name and version, once claimed, is permanent in practice.**
> Lock files pin the sha256 of every file, so replacing or deleting a version
> breaks whoever locked it, and a registry that allows an overwrite makes
> permanence a policy, not a mechanism. The first upload to a public channel is
> a one-way door. That is why the list of what is published is a reviewed file
> of the release tool, behind a protected environment, and not something the
> build can grow by itself.

## Three layers, and who owns what

| layer | what it is | where |
|---|---|---|
| 1. Mojo packages | `mojo_library`: built, and consumed by other libraries through `deps`. Unchanged by anything here | `src/*/BUCK` |
| 2. packaging rules | `conda_package`: turns one library into a `.conda` directory (this page). A Python wheel rule is a design only, see below | `tools/build/package/conda.bzl`, `komira_pack` |
| 3. the release tool | declares **which artifacts exist and how to build them**, builds them through the rules above, and publishes the BUILT files | kci: a reviewed list of artifact declarations |

So there is **one list of published packages, and it is kci's declarations**,
not a file in Buck. Buck states how to make a package of any library; kci says
which of them ship.

## One package per library, generated

The `mojo_library` macro declares a package target for every library, named
`<name>_conda`. Nobody writes one:

```python
mojo_library(name = "komira_json", ...)           # also declares :komira_json_conda
mojo_library(name = "x", conda = False, ...)      # opts out: no package target
mojo_library(name = "x", conda_name = "other")    # published as `other`; the import
                                                  # name stays `x`
```

`./buck2 build //src/komira_json:komira_json_conda` writes a directory (below).
Everything about the package is derived from the library, so the package cannot
disagree with it ([`conda.bzl`](../../tools/build/package/conda.bzl) lists each):

| fact | where it comes from |
|---|---|
| name | `conda_name` of the library, else its import name (the `.mojoc` basename): lowercase letters, digits, `_`, starting with a letter |
| run requirements | the platform guard (`__linux`), exactly `mojo-compiler ==<compiler version>`, then each **direct** dependency of the library, by its published name, at the same version **and the same build string** (`name ==<version> <build string>`), sorted. Direct only: every package of a release is built in lockstep, so the solver's closure is the build's, and a second build of a dependency in the channel cannot be chosen |
| subdir | the target platform's constraints (a `select`), never an attribute. Only `linux-64` is written: a `.mojoc` cannot be cross-compiled, so another subdir needs a build for that platform. On any other target platform the package target still builds, as a refusal saying so |
| payload | the library's gated `.mojoc`, so the package cannot exist until the library's own welded tests pass |
| version | **the Mojo compiler version** the library is built with, below |
| build number, build string | the release iteration `N` and `h<8 hex of the source commit>_<N>`, below |

To list the package targets (a development helper; it is not the published
list): `tools/build/package/list_conda_targets.sh [pattern...]`, which prints
`buck2 uquery 'kind(conda_package, //src/...)'`.

### What a package is: a directory

```
<name>-<version>-<build string>.conda   the file the channel carries
manifest.json              the artifact manifest
metadata.json              everything else the build knows
```

`manifest.json` is **exactly** the artifact manifest that kci's
`kci_artifact_manifest` parses (`kci build` writes it and `kci publish` reads
it): seven string keys, in this order, compact, one trailing newline.

```json
{"artifact_type":"CONDA","name":"komira_json","version":"1.0.0","subdir":"linux-64","file":"komira_json-1.0.0-h0123abcd_57.conda","sha256":"<64 hex>","metadata":"metadata.json"}
```

`file` is the channel's file name, relative to the manifest; `sha256` is that
file's; `metadata` is `metadata.json`, the file next to the manifest. The
parser requires `metadata` on a CONDA manifest and refuses one that is not a
bare file name (no `/`, not `.` or `..`), so copying the manifest's directory
cannot separate the two. The parser refuses any other key, so every other fact
is in `metadata.json` (sorted compact JSON): `schema`, `kind` (`library` or
`metapackage`), `name`, `version`, `subdir`, `build` (the build string),
`build_number`, `file_name`, `size`, `depends`, `timestamp_ms`,
`source_commit`, `stamped`, `label`, and for a library `import_name`,
`mojo_pin`, `payload_path`, `payload_sha256`; for a metapackage `members`
(name, version, build, sha256 each). The manifest's `version` is the compiler
version; the build number, build string and source commit are metadata (kci's
manifest has no key for them).
`tools/build/package/manifest_probe` runs kci's parser and writer over a
manifest: the build gate `//tools/build/package/manifest_probe:conda_manifest_kci`
runs it over one real package on every `buck2 build //...`, and
`tools/build/tests/functional/conda_set.sh` runs it over every manifest the
build emits.

### A library that cannot be packaged

It keeps its package target, and the target **builds**: its directory holds one
file, `REFUSED`, with the reason. Refusing by failing would make
`buck2 build //...` red on every such library. What fails is asking for the
release (`[release]`, `[release][manifest]`, `[release_check]`), naming the
reason. The reasons:

- it links native code (a `.mojoc` holds none, so a consumer would fail at its
  own link);
- it has no tests (no test would gate its package);
- it depends on a library with no package (`conda = False`, or itself refused);
- its name is not a conda name;
- it opens a shared library by name at run time (`OwnedDLHandle`), whose conda
  package this tool does not derive yet.

The first four are known to the build when it analyses the library, so a
dependent of such a library is refused too. The last is found only when the
package is made (the tool reads the sources), so **a dependent of a library
that dlopens is not refused by the build**; the release tool must therefore
check that every dependency of a declared package is itself declared and has a
`[release]` (below).

### Sub-targets

| sub-target | content |
|---|---|
| `[release]` | the directory, a copy made only after `[release_check]` passed, so it does not exist for an unstamped build, a stamp without its source commit, a non-positive commit time, or a refused library. **An uploader reads this and nothing else.** Nested: `[release][manifest]`, `[release][metadata]` |
| `[release_check]` | the marker of `komira_pack conda-check --require-stamped`, which reads the package back (zip, both zstd streams, both tars, the manifest against the file, the metadata against the index) |
| default, `[manifest]`, `[metadata]` | **development outputs**, built whether or not stamped. An unstamped one has build number 0 and build string `h00000000_0`, and uploading it would claim that name for good. An uploader never reads them |
| `[check]` | the marker of `komira_pack conda-check` |

## The metapackage

`komira` (the name is the release tool's) is a package with **no file** whose
run requirements are the platform guard and every member at exactly its
version and build string. Installing it installs the whole release; a registry that receives it
LAST makes it the switch for users.

Buck cannot enumerate targets, and does not know which libraries are published.
So it is **not** a Buck target: the release tool, which has the list, passes the
members' manifests to the packer.

```sh
komira_pack conda-meta --name komira --member-manifest <dir>/manifest.json ... \
    --license Apache-2.0 --summary "..." --home <url> \
    --extra-file info/licenses/LICENSE=LICENSE --label <what made it> --out-dir <dir>
komira_pack conda-check --dir <dir> --kind metapackage --name komira --expect-subdir linux-64 \
    --member-manifest <dir>/manifest.json ... [--mojo-pin <compiler version>] [--require-stamped true] --out <marker>
```

It reads each member (its manifest against the manifest contract, its file
against the manifest's sha256, its metadata), requires one release (one
version, build string, subdir, source commit and commit time; no member twice; no member that
is itself a metapackage; a name that is not a member's), and writes the same
directory a library does (the same manifest contract). `conda-check` re-derives
the requirements from the member manifests it is given, independently of the
writer.

Why one package per library plus a metapackage: a `.mojoc` needs the full
closure of its dependencies on the import path at the consumer's compile, and
the closure is the package set, so the solver does the closure (exact pins).
Versions are in lockstep, so every release is a whole new set.

## What the release tool does with them

The release tool (kci) owns the list. For each declared artifact it runs the
build system on the declaration's build rule, collects the manifests, builds the
metapackage with `conda-meta`, and publishes. What its publish step must do is
its own requirements; the ones that depend on how this directory is built:

1. **Refuse `stamped: false`** (in the metadata) and an unstamped file: a
   development output is not a release.
2. **Re-derive the stamp from git.** At a clean, full-history checkout of
   `main` at the release commit, run
   [`tools/build/package/release_version.sh`](../../tools/build/package/release_version.sh)
   and require its `version=` to equal the manifest's `version` (and the pinned
   compiler's), its `build=` to equal the metadata's `build`, its
   `build_number=` to equal the metadata's `build_number`, and its `commit=` to
   equal the metadata's `source_commit`. The build cannot read git,
   and a release check cannot tell a derived stamp from a typed one:
   `-c komira.package_stamp=999999999` passes it, and would shadow every future
   version of that name.
3. **Check the set**: every declared artifact built; every requirement of a
   package is another declared package at the same version and build string (or
   the guard, or the compiler at its pin); one version, one build string, one
   subdir, one source commit; the metapackage pins exactly the declared
   libraries.
4. **Build once, under the default isolation directory** (below), upload the
   file that build produced, and compare its sha256 with the manifest.
5. **Same name, same version, same build string, different sha256, is a stop.**
   The registry never overwrites; it is never answered by building again.
6. Members first, the metapackage last, every file read back from the channel.

## Reproducibility

The bytes are reproducible, so the file's sha256 is the package's identity.
Packing is a pure function of the payload: the same `.mojoc` always gives the
same package, no clock is read, the tars are the deterministic ones
`komira_pack` writes, the zstd streams are made of raw blocks (valid zstd that
no encoder version can change; a `.mojoc` is compressed already), the JSON is
sorted and compact, and `info/index.json` carries the commit time given at
stamping. The condition comes from the compiler, not the packing:

A `.mojoc` records the relative path of the sources it was compiled from
(`buck-out/<isolation dir>/art/...`), so **the same library built under two
`--isolation-dir` names is two different files**, and so are two packages made
from them. Measured, on the farm and with no cache: the two `.mojoc` differ in
those path bytes and nothing else, and the header's content hash is equal. The
wrapper's existing `-strip-file-prefix` does not change a `precompile` output,
so this is **not fixed here**, it is a documented gate on the release job, with
a follow-up (below):

- **build once, under the default isolation directory** (no `--isolation-dir`),
  and upload the file that build produced;
- **never rebuild and retry**: a second build is a different file under the
  same name and version, which the registry refuses for good;
- the release job's checkout location does not matter (the paths are relative to
  the checkout), the isolation directory does; reproducibility across two
  different farm workers is **unmeasured**.

`tools/build/tests/functional/conda.sh` and `conda_set.sh` pin what is true: two
uncached builds in fresh daemons under one isolation directory give one sha256
for a package, and for every package of the set and the metapackage made from
them.

The `.conda` is a zip of three stored members (`metadata.json`,
`pkg-*.tar.zst`, `info-*.tar.zst`); it is zip version 2.0 (zip32), not the zip64
of Modular's own packages, which no tool tried here required (conda-format
readers: `unzip`, `zstd`, `tar`, and pixi's rattler; conda, mamba and the
registry's own acceptance of a zip32 file are untried).

## Using a package

A consumer lists the komira channel and the Mojo compiler's channel. The
package requires `mojo-compiler ==<compiler version>` (its own version); a project that already depends on
`mojo` is satisfied by that (the `mojo` package pulls exactly that compiler),
and a project without it gets the compiler from the second channel:

```toml
[workspace]
channels = ["<the komira channel>", "https://conda.modular.com/max", "conda-forge"]
platforms = ["linux-64"]

[dependencies]
komira_encoding = "==<compiler version>"   # or: komira = "==<compiler version>" for every library
```

`import komira_encoding` then compiles with no `-I` and no activation script.
`tools/build/tests/functional/conda.sh` and `conda_set.sh` do exactly this from
a `file://` channel.

## Version

**The version of every package is the version of the Mojo compiler the
repository pins** (CEO decision), so `mojo-compiler ==<version>` and the
package's own version are one number, and a compiler bump re-versions and
rebuilds every package (expected). The compiler's version is stated once, in
the platform table's pin of the linux-64 compiler
([`table.bzl`](../../tools/build/platforms/table.bzl); the pin names it in its
asset name and in its URL, and `conda.bzl` refuses a pin whose two disagree).
`conda.bzl` derives `MOJO_COMPILER_VERSION` from it, the toolchain downloads
that same pin, and `release_version.sh` reads it from git. Nothing else states
it, and `komira_pack conda-check` refuses a package whose version is not the
compiler version it is given.

Repeated releases at one compiler version are told apart by the conda **build
number** and **build string**, in lockstep across every package of a release:

- the build number `N` is `git rev-list --count --first-parent C`, where `C` is
  the newest commit at or below the release commit that touches anything but
  documentation (`docs/`, any `*.md`, `.github/`), so a change to what is
  published always raises it and a documentation commit never does. A release
  job gets it, the commit and its time from
  [`release_version.sh`](../../tools/build/package/release_version.sh) and passes
  them as `buck2 build -c komira.package_stamp=<N> -c komira.package_commit=<sha> -c komira.package_timestamp_ms=<ms>`.
  They are read in the macro, so only the packages are keyed by them, never a
  compile;
- the build string is `h<first 8 hex of the source commit>_<N>` and the file is
  `<name>-<version>-<build string>.conda`. A requirement between packages is
  `name ==<version> <build string>`, so a package is installed with the build of
  its dependencies it was released with, never a newer or older build of the same
  version in the channel. pixi (rattler) honours the build string in a package's
  `depends`: `conda_set.sh` installs the metapackage from a channel holding two
  builds of one member and only the pinned build is installed (an unpinned
  requirement takes the newer one, and a requirement on a missing build fails to
  solve);
- a build with no stamp has build number 0 and build string `h00000000_0`: it
  builds as a development output, and `[release_check]` (hence `[release]`)
  refuses it;
- the stamp is tied to git: a stamped package carries its `source_commit` (40
  lowercase hex digits), its build string must be `h<8 hex of that commit>_<N>`,
  and `[release_check]` refuses a package whose commit time is not positive.
  These prove the stamp is *accompanied* by a commit, not that it is the right
  one: the release job compares `release_version.sh`'s output with the package
  at a clean full-history checkout (step 2 above).

Two builds with the same name, version and build string but different bytes are
a stop for the release tool; a new release is a new `N` (which gives a new build
string).

## Wheels: versioning (design only; no code)

A wheel is versioned the same way: **`<compiler version>.post<N>`**, the PEP 440
post-release of the compiler version, with `N` the same number as the conda build
number, and it depends on `mojo-compiler==<compiler version>` (PyPI has no build
strings, so the post-release is what tells two releases of one compiler version
apart). A compiler bump gives a new base version and every wheel is rebuilt.
Nothing writes a wheel yet.

## A Python wheel rule (design only; no code)

The conda rules do not cover the Python front end. A wheel is a different
artifact with a different licence question: a self-contained wheel would carry
the Modular Mojo runtime, where a conda package only depends on it. So the
rule, when it is written:

- **explicit, and off by default.** Unlike the conda package, a library does not
  get a wheel unless it asks (`wheel = True`, or a `python_wheel` target for the
  front end); there are few wheels, and each is a reviewed decision.
- **front end only.** The wheel is the Python package that drives komira, not a
  per-library artifact.
- **same contract as the conda rule**: `[release]` is a directory holding the
  `.whl`, `manifest.json` in the artifact-manifest contract for a PYTHON
  artifact (`artifact_type`, `name`, `version`, `file`, `sha256`, `metadata`,
  where `metadata` is the wheel's `METADATA`), gated on a stamp tied to git, built
  reproducibly, read back by an independent check.
- **declared in kci** like every other artifact (a `PYTHON_WHEEL` declaration
  whose build rule is that target); nothing in Buck lists it as published.

## Not done yet

- `linux-aarch64` and `osx-arm64` (they need their own payload build and an
  architecture guard);
- libraries that link native code, and libraries that open a shared library
  at run time (both refused by name rather than published incompletely);
- the upload step and the release tool's list (kci's; the files it reads are
  above);
- the Python wheel rule (design above);
- **a `.mojoc` that does not record the isolation directory** (follow-up):
  compile `precompile` from a private working directory with the sources staged
  at a fixed relative path (the wrapper must then absolutize every `-I` and the
  `-o`), or ask the compiler for a path-remapping option; then the gate in
  "Reproducibility" can be a test (two isolation directories, one sha256)
  instead of a rule for the release job;
- the build does not refuse a dependent of a library that dlopens (above).

How it is tested: [`conda.sh`](../../tools/build/tests/functional/conda.sh) (one
package, the generated targets, the refusals, the packer and its check, the
stamp) and [`conda_set.sh`](../../tools/build/tests/functional/conda_set.sh)
(the set, the metapackage, kci's parser over the emitted manifests, the
two-daemon sha equality, a pixi install).

Not verified: that the registry accepts a zip32 `.conda`, and that conda, mamba
or micromamba install one (only pixi/rattler was tried).
