# Packaging

Rules that turn a `mojo_binary` into something you can ship: a relocatable
bundle, a reproducible tarball of it, and an OCI image.

`load("@komira//tools/build/package:defs.bzl", "mojo_bundle")`

```python
mojo_bundle(
    name = "hello_bundle",
    binary = ":hello",              # a mojo_binary
    version = "0.1.0",
    data = {"share/greeting.txt": "greeting.txt"},
)
```

A bundle is a directory holding a program and everything it needs besides
glibc (2.34 or later) and the kernel. Package formats are built from it.

```
bin/hello                                 launcher
lib/glibc-hwcaps/x86-64-v3/libhello.so    the program
lib/                                      Mojo runtime, C++ runtime
share/                                    data
VERSION                                   name, version, platform, CPU level
SHA256SUMS                                every other file
```

`bin/hello` is a small C launcher built for the baseline x86-64 ISA, so it
starts on any x86-64 CPU. It reads the CPU's x86-64 level the way glibc's
loader does (cpuid, and whether the OS saves the AVX and AVX-512 registers).
Below the level the program was compiled for (the toolchain's `target_cpu`)
it prints one line and exits 126 (not 1, so a supervisor can tell a wrong
CPU from a failing program), before loading anything:

```
hello requires an x86-64-v3 CPU (Haswell or newer)
```

Otherwise it loads `libhello.so` by name. The loader looks in the launcher's
run path, `$ORIGIN/../lib`, and in the `glibc-hwcaps/x86-64-v<N>/`
directories under it that the CPU supports, so builds for other levels can
sit next to this one. If the library cannot be loaded the launcher prints
the loader's error and exits 127; when the file is in the bundle but the
loader did not search its `glibc-hwcaps/x86-64-v<N>/` directory (glibc older
than 2.33, or hwcaps masked with `GLIBC_TUNABLES` or `--glibc-hwcaps-mask`),
it says so. The run paths are `DT_RUNPATH`, so `LD_LIBRARY_PATH`, which the
loader searches first, can put a different `libhello.so` or runtime library
in place of the bundle's; that is accepted and checked ([bundle.sh](../tests/functional/bundle.sh)
`loader`). The launcher then calls the program's C entry point
`komira_main`, which runs `main` through the same standard-library function a
Mojo executable uses: arguments, environment, output and exit status are
those of the executable (tests//functional/bundle_parity compares the two).
`lib<name>.so` has run path `$ORIGIN/../..`, the bundle's `lib/`. Every run
path is relative to its file, so the bundle runs from wherever it is copied
and through a symlink. A program finds its data through `/proc/self/exe`:
`<its directory>/../share`. The runtime libraries in `lib/` are the vendor's
files, unchanged, and keep the vendor's run paths; [bundle_expected](../tests/functional/bundle_expected)
lists every run path in the bundle.

The bundle is built by copying files with fixed modes (0755 for `bin/`,
0644 otherwise); `VERSION` holds no time or revision, so the same sources
give the same bytes (checked across two uncached builds).

`[test_launcher]` is the launcher built with a test hook: it judges the
made-up CPU named by `$KOMIRA_TEST_CPU` (see [`cpu_models.h`](launcher/cpu_models.h))
instead of the real one. It exists for checks and is never part of a
bundle; the shipped launcher has no override.

A program built as `[shared]` is compiled from a generated file next to its
main module, which imports `main` from it; the main module's file name must
therefore be a Mojo identifier. Only linux x86_64 bundles are built today.

## Package formats

Each format is a rule over a bundle that produces files; nothing is pushed
or published by the build.

```python
load("@komira//tools/build/package:defs.bzl", "bundle_tarball", "oci_image")

bundle_tarball(name = "hello_tarball", bundle = ":hello_bundle")
oci_image(name = "hello_image", bundle = ":hello_bundle", repository = "komira/hello")
```

- `bundle_tarball` writes `hello-0.1.0-linux-x86_64.tar.gz`, the bundle under
  `hello-0.1.0/`.
- `oci_image` writes an OCI image layout directory (`hello_image.oci/`): the
  layers of a base image, then one layer holding the bundle at `/opt/hello/`,
  with entrypoint `/opt/hello/bin/hello` and platform linux/amd64.
  `[docker_archive]` is the same image as one tar for `docker load`, and
  `[digest]` a file holding the image manifest digest. The image is named
  `<repository>:<bundle version>`, so

  ```sh
  docker load < "$(buck2 build '//tools/build/examples:hello_image[docker_archive]' --show-full-simple-output)"
  docker run --rm komira/hello:0.1.0
  ```

  `[release]` is the image as a release set holds it: a directory with the
  layout (`hello_image.oci/`) and kci's artifact manifest, `manifest.json`
  (type `OCI`, name the bundle's program, `file` the layout directory,
  `sha256` the hex of `[digest]`). A BUILD step copies it into the release
  directory (`--out <release_dir>/<name>`), and kci's `verify_member` hashes
  every blob of the layout and requires its manifest digest to be the
  manifest's `sha256` (`src/kci_release_set`, which reads the real
  `hello_image[release]` in a welded test). The program's name must be a kci
  artifact name (`[a-z][a-z0-9_]*`), or building `[release]` fails naming it.

The base image is `komira//tools/build/toolchains:distroless_base` (distroless base-debian12,
which has glibc, CA certificates and no shell), declared with `oci_base`: the
digest of its linux/amd64 manifest, that manifest's bytes checked in, and one
pinned download per blob. The packing action does not use the network: it
takes no URLs, reads only those files and refuses unless the manifest hashes to its
digest and names exactly the downloaded blobs.

Both formats are written by `komira_pack` ([`komira_pack.zig`](pack/komira_pack.zig)), a
static executable built by the pinned zig and run with no shell. It holds
its output in memory until it exits, up to about three times the bundle's
size at peak, which sets the size of bundle a worker can pack. The
bytes
depend only on the bundle and the base: tar entries are sorted, with
directories listed, mtime and uid/gid 0 and modes 0755/0644; gzip headers
carry no time; JSON keys are sorted and every timestamp is
1970-01-01T00:00:00Z. Two uncached builds give the same tarball and the same
image digest ([bundle.sh](../tests/functional/bundle.sh)), and `docker run` of the loaded image prints
the greeting ([formats.sh](../tests/functional/formats.sh)).

## kcov is never packed

kcov ([`toolchains/kcov`](../toolchains/kcov/README.md)) is GPL-2.0 and a
build-only tool (the licence decision is recorded in [kcov's
README](../toolchains/kcov/README.md#licences)), so no published artifact may
hold it. Every package format runs [`kcov_guard.sh`](kcov_guard.sh) over what
it packs, as a build action whose output its published files depend on
([`kcov_guard.bzl`](kcov_guard.bzl)). The guard refuses a file whose sha256 is
`KCOV_BIN_SHA256` or whose bytes contain `KCOV_USAGE_LINE`, `Usage: kcov
[OPTIONS] out-dir in-file [args...]`, the two constants of
[`toolchains/kcov/identity.bzl`](../toolchains/kcov/identity.bzl). The
message names the target and each refused file by its path in the package.
kcov carries no `kcov v42` to search for (it prints `kcov %s` with the string
`v42`), and the usage line is one string literal of its source, contiguous in
every build of it.

The guard depends on no kcov target: a package build never builds kcov,
never compiles its source, and is not blocked by a kcov that fails to build or
a kcov pin that breaks. What holds the constants to the real binary is on the
kcov side: `//tools/build/toolchains/kcov:kcov_identity`, which gates `:kcov`,
fails when the built `bin/kcov` has another sha256 or lacks the line, naming
the constant to update. Between such a change and the update, the guard
refuses kcov by its usage line alone.

| format | what the guard reads | what waits for it |
|---|---|---|
| `mojo_bundle` | every file of the bundle | the bundle target (`[kcov_guard]` is built with it) |
| `bundle_tarball`, `oci_image` | the bundle, through the bundle's guard | the `komira_pack tar` and `komira_pack oci` actions |
| `conda_package` | every file `komira_pack conda` copies in: the `.mojoc`, the README, the licence files | the copies behind `[default]` and `[release]` (`[kcov_guard]` is the marker) |

The image's base layers (the pinned distroless blobs) and the files the
packers generate (`VERSION`, `SHA256SUMS`, the conda JSON) are not read: they
hold no file a build put there. `komira_pack conda-check` refuses any member
of a package's pkg tar other than the `.mojoc` and the README, so the guard's
list is the package's content. The metapackage (`release_set.bzl`) carries
only komira's `LICENSE` and is not guarded.

The guard reads whole files, following symlinks. It does not open an archive
or a compressed stream inside the package (a `.tar.gz`, `.zip` or `.xz` in a
bundle's `data` that holds kcov is accepted), and it does not know the files
kcov writes when it runs: its preload library (`libkcov_sowrapper.so`, which
`bin/kcov` carries inside it and which holds no usage line) and its report
directories. Keeping those out is review's job.

The sha256 is that of the one kcov komira builds (its pin, for
linux-x86_64); a kcov built otherwise (another version or CPU, patched or
stripped) is refused by the usage line alone.

`:kcov_guard` (the script) is gated by the validation `:kcov_guard_cases`, so
any build that packs anything also runs the guard on known inputs (15 cases),
and fails if one gets the wrong answer. The cases need no kcov: a fixture
file stands for `bin/kcov`, and its sha256, written into the script, is the
one they pass. Refused: a sha256 one digit short or in upper case, and an
empty line, before any file is read; the fixture renamed (by its sha256, as a
directory's file, as a file and under a destination path; the fixture holds
no usage line, so only the sha256 can refuse it); a file holding the usage
line after the fixture's bytes, and the line between NUL bytes (by the
line); two offenders named together; a symlink to the fixture and one to a
directory holding it (under the link's name). Accepted: near misses of the
line, the line split by a NUL or a newline, and the fixture with one byte
more. Three of the cases run the guard through its command line in its own
process, as the package rules do (the fixture's copy refused by the sha256,
the embedded line refused by the line, the near misses accepted, `<out>`
written only then), so a sha256 or line read from the wrong argument is red.
Planted, red: the sha256 comparison broken (`copy_in_dir: guard exited
0, want 1`), `KCOV_USAGE_LINE` shortened to `Usage: kcov` (`near_misses:
guard exited 1`) or emptied (`the fixture holds the usage line`); the
`guard` mode reading its line with a character added (`cli_line: guard
exited 0, want 1`) or a sha256 other than its argument (`cli_sha: guard
exited 0, want 1`). On the
examples: `hello_bundle` given
`data = {"share/kcov": "//tools/build/toolchains/kcov:kcov[bin]"}` (the only
state in which a package build depends on kcov) fails `share/kcov is kcov's
bin/kcov (sha256 57243a23...)`, and neither the tarball nor the image is
packed; a data file holding the usage line fails `share/marker.txt holds
kcov's usage line`, while one holding only near misses of it builds; a conda
package given `bin/kcov` as a licence file and a README holding the line
fails naming `info/licenses/KCOV` and `share/doc/komira_encoding/README.md`.

## Conda packages

`conda_package` ([`conda.bzl`](conda.bzl)) packages a Mojo library as a `.conda`
for linux-64: one file, `lib/mojo/<name>.mojoc`, where the compiler already
looks. The `mojo_library` macro declares it (`<name>_conda`) for every library,
so nobody writes one and no list of names lives in the build.
`komira_pack conda` writes the zip, the two tars and the JSON into a directory
(the `.conda`, `manifest.json` in kci's artifact-manifest format, whose
`metadata` names the `metadata.json` next to it),
`komira_pack conda-meta` writes the metapackage from the members' manifests, and
`komira_pack conda-check` reads either back and refuses what is wrong; nothing is
uploaded, and an uploader reads only the `[release]` sub-target, which exists only
after the release check (stamped, with its source commit) passed. The name, the run
requirements, the subdir and the version are derived, a library that cannot be
packaged keeps a target that builds as a refusal, and the bytes are reproducible.
`conda_manifest_kci` ([`manifest_probe/BUCK`](manifest_probe/BUCK)) is the build
gate between the two: it builds one real package and reads its manifest with
kci's parser, so `buck2 build //...` fails if the packer and kci disagree.
`conda_release_set_check` ([`release_set.bzl`](release_set.bzl); the target
`:release_set_check` in [`BUCK`](BUCK)) builds the stamped release path without a
release's `-c komira.package_*`, in any build that includes it (`buck2 build //...`
and the per-change check's unit that holds it). It packages each library of the
release set (today only `komira_encoding`) with the fixed test stamp of
`conda_package_test_stamped` in [`conda.bzl`](conda.bzl): build number 999999999,
a made-up source commit whose first 8 hex are `7e57c0de` (no 8-hex slice of it
repeats another or is `00000000`), commit time 86400000 ms. No release carries
it. The target builds each package's `[release]` (so its `[release_check]` runs)
and runs `komira_pack conda-meta --name komira_all` over those manifests. It
fails the build in these cases:

- a member or the metapackage does not carry build string `h7e57c0de_999999999`
  (written out, not derived from the commit) in its file name and manifest, or
  the stamp at the top level of its metadata.json; the message names the package;
- the metapackage does not require a member at its version and build string; the
  message names the member;
- `komira_pack conda-check --kind metapackage --require-stamped true` refuses the
  metapackage;
- its `libs`, its metapackage name, or the `--license`, `--summary` and `--home`
  it gives conda-meta differ from [`release_set.txt`](release_set.txt).

The welded test `test_release_artifacts_file` of `src/kci_artifact` holds
`release_set.txt` equal to `release/artifacts.textproto`'s metapackage, so a
library added to the release set and not here is red. `:release_set_kci` reads
the stamped metapackage's manifest with kci's parser. Not covered: the macro's
reading of `-c komira.package_*` (these packages are given the test stamp), and,
while the release set holds one library with no dependencies, one member's
lockstep pin on another and agreement across members.
[`list_conda_targets.sh`](list_conda_targets.sh) prints the package targets. The layout,
the version scheme and the metapackage: [packaging/conda](../../../packaging/conda/README.md). The version
a release carries comes from [`release_version.sh`](release_version.sh).
