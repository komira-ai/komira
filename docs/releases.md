# Releases

What komira publishes today, and how another repository pins a version of it.

## What exists today

Komira has no release tags and no version number of its own, and this
repository does not yet contain the step that uploads to a package registry.
A version of komira is a commit. What the build produces from a program is
described in [release machines](design/release_machine.md): a relocatable
bundle, a reproducible tarball of it, and an OCI image layout. The build rules
only write these files; publishing them is the step a release machine runs
after the build and its gates.

The `version` that a bundle carries is an attribute of that bundle's
`mojo_bundle` target. It names the program, not komira: two bundles in one
repository can carry different versions, and the build checks only that the
string is a plain version (`0.1.0`, `1.2.3+build.4`).

## Conda packages

Every Mojo library has a conda package target, `<name>_conda`, declared by the
`mojo_library` macro (`conda = False` opts out); nobody writes one. The package
is a directory: one file, `lib/mojo/<name>.mojoc`, which the compiler finds on
its default import path, packed as a `.conda`, with the artifact manifest that
kci reads and a metadata file. The build writes it and uploads nothing. Which
packages are published is the release tool's reviewed list of artifact
declarations, not a file in the build, and a name and version in a registry are
permanent in practice, so the first upload is gated. A library that cannot be
packaged still has a target that builds, holding the reason. The layout, the
versioning (the package version is the Mojo compiler version, the release
iteration is the conda build number) and the metapackage are in
[packaging/conda](../packaging/conda/README.md).

An uploader reads only a package target's `[release]` sub-target, which exists
only for a stamped build that carries its source commit; the unstamped
build-number-0 files the other sub-targets produce are for development and
claim a permanent name if uploaded. Before uploading, the publish job
re-derives the version, build number, build string and commit with
`release_version.sh` at a clean full-history checkout and compares them with
the manifest and metadata; that
and the rest of the publish step are in the README.

A project that uses a package lists the komira channel and Modular's `max`
channel (or already depends on `mojo`, which pulls the same pinned compiler,
`mojo-compiler ==<the package's version>`); the snippet is in the README.

## Pinning komira from another repository

A repository that builds Mojo with komira's rules names komira as its `komira`
cell and pins it to a commit, either as a git external cell or as a git
submodule. [Using komira from another
repository](../tools/build/README.md#using-komira-from-another-repository)
has the configuration, the two files to copy, and what keeps the consumer's
cache entries equal to a standalone checkout's.

Pin by the 40-hex `commit_hash`, not by a branch or a tag: a branch moves,
and upgrading komira is then one change to that line. Buck2 fetches the whole
repository once per commit.

## Held

These parts of a release machine's publish step are not described here
because the libraries that implement them are not part of this repository
yet:

- The upload of conda packages, their other platforms (linux-aarch64 and
  macOS) and Python wheels of the Mojo libraries.
- Package channels, and the rules for which writers each channel admits.
- Copying and promoting a container image between registries by digest.
- A release version shared by every artifact, and the procedure for cutting
  one.

Each lands with its own section when its code does.
