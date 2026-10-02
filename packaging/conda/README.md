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

## One package

```python
load("@komira//tools/build/package:conda.bzl", "conda_package")

conda_package(
    name = "komira_encoding",        # the library's import name
    lib = "//src/komira_encoding:komira_encoding",
    summary = "One line for the channel page.",
)
```

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

## What a publisher reads

Sub-targets of every package target:

| sub-target | content |
|---|---|
| `[default]`, `[file]` | `<name>.conda` (a stable Buck name; the channel's file name is in the manifest) |
| `[digest]` | one line, `sha256:<hex>` of that file |
| `[manifest]` | JSON, sorted keys: `schema`, `artifact_type` (`conda`), `name`, `version`, `subdir`, `build`, `build_number`, `file_name`, `sha256`, `size`, `payload_path`, `payload_sha256`, `depends`, `mojo_pin`, `stamped`, `label`, `approved_names_sha256` |
| `[check]` | the marker of `komira_pack conda-check`, which reads the package back (zip, both zstd streams, both tars, every property below); the three files above are copies made after it passed |
| `[release_check]` | the same check, also refusing a version that was never stamped |

The bytes are reproducible: the file's sha256 is the package's identity. The
`.conda` is a zip of three stored members (`metadata.json`, `pkg-*.tar.zst`,
`info-*.tar.zst`); the tars are the deterministic ones `komira_pack` already
writes; the zstd streams are made of raw blocks, valid zstd that no encoder
version can change (a `.mojoc` is compressed already); the JSON is sorted and
compact; no clock is read. `info/index.json` carries the commit time given at
stamping instead of the build time.

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
  them as `buck2 build -c komira.package_stamp=<N> -c komira.package_timestamp_ms=<ms>`.
  They are read in the macro, so only the packages are keyed by them, never a
  compile;
- a build with no stamp is `<prefix>.0`: it builds, and `[release_check]`
  refuses it.

## The approved list

[`names.tsv`](names.tsv) is the only list of what may be published: a name not
in it is not published, and a listed package's direct dependencies must be
listed too. Adding a row is the approval to claim that name, so review it as
that. The sha256 of the sorted names is in every manifest
(`approved_names_sha256`), so an approval can be bound to the exact list.
[`names_lint`](BUCK) checks its shape (rows of name, label and reason; the
prefix; the flat `//src/<name>:<name>` label; sorted and unique), that this
directory declares one `conda_package` per row, and that none names another
list.

## Not done yet

- `linux-aarch64` and `osx-arm64` (they need their own payload build and an
  architecture guard);
- libraries that link native code, and libraries that open a shared library
  at run time (both refused by name rather than published incompletely);
- an aggregate of every package's manifest, and the upload step with its dry
  run and its approval gate;
- the rest of the libraries: the list holds the one canary.

How it is tested: [`conda.sh`](../../tools/build/tests/functional/conda.sh).
