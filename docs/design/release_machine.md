# Release machines: from a program to a shipped artifact

## What is a release machine, and what does this repository cover?

A release machine ships one thing. It is one authored description that names
the targets to build, the gates that must pass before the result may leave,
and when it fires (a git event or a schedule). What it ships is either a
deployment of a service or a published artifact (an OCI image, a conda
package, a Python wheel, an npm package) placed on a release channel. Both
are release machines. Publishing artifacts is a main part of what they do, not
something outside them.

A release machine is built before it ships, and the build is its test gate:
each test the machine declares runs as a build action, and the artifact that
would be shipped cannot be produced until those tests have passed. A machine
whose targets do not build completely is blocked.

Two layers produce a shipped artifact, and this document is about the first:

1. **The build rules** (`tools/build/package`) turn a `mojo_binary` into
   things a machine other than the build machine can run: a bundle (a
   directory holding the program and everything it needs besides glibc and
   the kernel), a tarball of that bundle, and an OCI image of it. The rules
   only write files. They never push, because a build whose result depends on
   a registry cannot be reproduced; that is a property of the build, not of
   the release machine.
2. **The release machine** runs the build, then stages and publishes what it
   made, deploys it where it is a service, and validates the outcome in the
   cell it deployed to. Its driver is `kci` (`kci run --stage <S>`, the
   `src/kci_*` libraries). Today it builds and publishes; a DEPLOY step is
   refused, and its design is [the DEPLOY step](deploy_step.md).

Conda packages of Mojo libraries ([releases](../releases.md)) and release
channels (`src/kci_release_channel`: a channel is a publish destination and
nothing else, with a name, a visibility, one repository per artifact type,
and the one identity allowed to push to each) exist. Held, and described
here only so the build outputs below make sense:

- Python wheels of Mojo libraries: the artifact manifest reads a `PYTHON`
  type, but no rule builds a wheel.
- Copying an image between registries by digest, so that the bytes a later
  channel serves are the bytes an earlier one validated: the library exists
  (`komira_oci`), and no kci step calls it yet.
- A version shared by every artifact of a release, and the steps of cutting
  it. See [releases](../releases.md) for what a version of komira is today.

The per-rule reference, with every attribute and failure message, is
[tools/build/package/README.md](../../tools/build/package/README.md); this
document explains how the parts fit and why.

## How does it work?

Three rules, each over the output of the one before.

```
mojo_binary ──► mojo_bundle ──┬─► bundle_tarball   <name>-<version>-linux-x86_64.tar.gz
                              └─► oci_image        <name>.oci  (+ [docker_archive], [digest])
```

`mojo_bundle(binary = ..., version = ..., data = {...})` produces a directory:

```
bin/<name>                                    launcher
lib/glibc-hwcaps/x86-64-v<N>/lib<name>.so     the program
lib/                                          Mojo runtime, C++ runtime
share/                                        data
VERSION                                       name, version, platform, CPU level
SHA256SUMS                                    every other file
```

`bundle_tarball` writes the bundle under `<name>-<version>/`. `oci_image` writes
an OCI image layout: the layers of a base image, then one layer holding the
bundle at `/opt/<name>/`, with entrypoint `/opt/<name>/bin/<name>`, platform
linux/amd64, named `<repository>:<bundle version>`. Its `[docker_archive]`
sub-target is the same image as one tar for `docker load`, and `[digest]` is a
file holding the image manifest digest.

### What does the launcher do?

`bin/<name>` is a small C program built for the baseline x86-64 ISA, so it
starts on any x86-64 CPU. It reads the CPU's x86-64 level, and below the level
the program was compiled for (the toolchain's `target_cpu`) it prints one line
and exits 126, before loading anything. Otherwise it loads `lib<name>.so` by
name, searching `$ORIGIN/../lib` and the `glibc-hwcaps/x86-64-v<N>/`
directories under it that the CPU supports, then calls the program's
`komira_main`, which runs `main` through the same standard-library function a
Mojo executable uses. A library that cannot be loaded exits 127.

### What is the base image?

`oci_image`'s `base` defaults to `komira//tools/build/toolchains:distroless_base`,
declared with `oci_base`: the digest of its linux/amd64 manifest, that
manifest's bytes checked in, and one pinned download per blob. The packing
action does not use the network. It reads only those files and refuses unless
the manifest hashes to its digest and names exactly the downloaded blobs.

## Why is it built this way?

### Why are the outputs reproducible?

**Decision.** The bundle, the tarball and the image are functions of the bundle
sources and the base image alone.

**Because.** `VERSION` holds no time or revision. Files are copied with fixed
modes (0755 under `bin/`, 0644 otherwise). The tarball has sorted entries,
mtime and uid/gid 0, and no time in its gzip header. The image's JSON keys are
sorted and every timestamp is 1970-01-01T00:00:00Z. A digest that changes only
because a build ran again cannot be used to tell whether the content changed.
A release machine publishes by digest, so this is what lets it recognise an
artifact it has already published.

### Why a launcher instead of linking the program as an executable?

**Decision.** The program is a shared library behind a baseline-ISA launcher.

**Because.** The launcher can run on any x86-64 CPU, so it can check the CPU's
level before loading the program and say what is needed, exiting 126 so that a
supervisor can tell a wrong CPU from a failing program. The `glibc-hwcaps`
directories let builds for other levels sit next to this one.

### Why is `komira_pack` a static executable?

**Decision.** Tar and OCI files are written by `komira_pack`, a static
executable built by the pinned zig and run with no shell.

**Because.** The bytes it writes depend only on the bundle and the base, and the
tool that writes them is itself a pinned build output.

## What must always hold?

- Two uncached builds of the same sources give the same tarball and the same
  image digest.
- A bundle runs from wherever it is copied, and through a symlink: every run
  path is relative to its file.
- The launcher refuses a CPU below the program's level with exit 126, and the
  shipped launcher has no override. The test launcher, which judges a made-up
  CPU named by `$KOMIRA_TEST_CPU`, is never part of a bundle.
- A program run through its bundle behaves as the executable does: arguments,
  environment, output and exit status.
- Only linux x86_64 bundles are built.

## What does this repository's release machine say?

[`release/machine.textproto`](../../release/machine.textproto) (format
`kci.machine`, read by `src/kci_release_machine`) is komira's own release machine:
its stages in order, and the steps of each. `kci run --stage <S>` runs one
stage. Three stages today: `build` (one BUILD step), `gamma` and `prod` (one
PUBLISH step each, to prefix.dev `komira-ai/gamma` and `komira-ai/prod`). Three
fields of a stage carry what the CI workflow must agree with:

| field | meaning |
|---|---|
| `stage.environment` | the GitHub environment the stage's job runs in (default: the stage's name). A trusted-publishing channel's push identity must name it, or kci refuses the publish. |
| `stage.farm_connected` | the stage's job joins the build farm's tailnet (the `farm-connect` action), which needs the job's ID token. A farm-connected stage may not publish: the job that holds a farm network node never holds a publishing token. |
| `step.validation` | a check of what a PUBLISH step published, by kind (`CONDA_INSTALL_SMOKE`: `image` pinned by digest, `install` (repeated), `compiler_channel`, `extra_channel`, `program` under `release/`, `wait_for_index_seconds`). A FULL run runs it after its step; `--only validation:<name>` runs it alone against what is published; `--only step:<name>` runs the step without it. A failure is exit 7, never a skip. |

The workflow that runs the stages, `.github/workflows/kci.yml`, is held to this
file by `kci run` itself at start-up under GitHub Actions and by a welded test
([docs/ci.md](../ci.md#kciyml-the-release)).

A second validation kind, `CONDA_INSTALL_ENV`, runs on the machine that runs
kci, with no container. It takes the same fields as `CONDA_INSTALL_SMOKE`
except `image` and `program`, plus an optional `smoke: README` (the one word,
and the default): what it runs is each installed library's README examples
(`share/doc/<name>/README.md`, whose bytes the release pins). An install of a
metapackage is checked member by member: kci reads the members from the built
metapackage's own requirements (each at the release's version and build, the
list equal to the release's libraries, never empty) while `pixi.toml` names
only the metapackage. `kci run` then takes `--pixi` and `--pixi-sha256`, the
pinned pixi and its sha256. gamma's two validations are of this kind:
`install-komira-encoding` (the library alone) and `install-set` (`komira_all`
alone). Before anything is published, `--channel file:///<dir>` points such a
run at a local channel that `komira_pack conda-index` wrote from the release
directory; it is accepted only on a run that selects nothing but
`CONDA_INSTALL_ENV` validations, and never under GitHub Actions.
Its one result that is not a pass or a failure: when no declared host answers
at all (no network), the validation is `INDETERMINATE`, exit 5, never a pass,
and its row carries a `skip_reason`.

## Where is the code?

| path | holds |
|---|---|
| `tools/build/package/defs.bzl` | `mojo_bundle`, `bundle_tarball`, `oci_base`, `oci_image` |
| `tools/build/package/launcher/` | the launcher and its CPU-level tables |
| `tools/build/package/pack/komira_pack.zig` | the tar and OCI writer |
| `tools/build/examples/BUCK` | `hello_bundle`, `hello_tarball`, `hello_image` |

## How is it tested?

End-to-end tests in `tools/build/tests/functional` build the example targets:
`bundle.sh` (layout, run paths, relocation, loader behaviour, reproducibility),
`bundle_parity` (the bundle against the plain executable), and `formats.sh`
(the tarball, the image, the digest, and `docker run` of the loaded image).
`tools/build/package:level_test` runs the launcher's level function against
made-up CPUs. See [tools/build/tests/README.md](../../tools/build/tests/README.md).

## What are its limits and open questions?

- Only linux x86_64.
- `komira_pack` holds its output in memory until it exits, up to about three
  times the bundle's size at peak, which sets the largest bundle a `light`
  worker can pack.
- A program finds its data through `/proc/self/exe`:
  `<its directory>/../share`.
- `LD_LIBRARY_PATH` is searched before the bundle's run paths, so it can put a
  different library in place of the bundle's.
