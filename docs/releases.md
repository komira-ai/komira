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

A Mojo library builds into a conda package for linux-64 with `conda_package`:
one file, `lib/mojo/<name>.mojoc`, which the compiler finds on its default
import path. The build writes the file, its sha256 and a manifest; it uploads
nothing. A package may be published only if its name is in the approved list,
and a name and version in a registry are permanent in practice, so the
first upload is gated. The layout, the version scheme (`<prefix>.<N>`) and the
list are in [packaging/conda](../packaging/conda/README.md).

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
