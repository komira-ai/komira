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
in place of the bundle's; that is accepted and checked ([bundle.sh](../checks/bundle.sh)
`loader`). The launcher then calls the program's C entry point
`komira_main`, which runs `main` through the same standard-library function a
Mojo executable uses: arguments, environment, output and exit status are
those of the executable (checks//bundle_parity compares the two).
`lib<name>.so` has run path `$ORIGIN/../..`, the bundle's `lib/`. Every run
path is relative to its file, so the bundle runs from wherever it is copied
and through a symlink. A program finds its data through `/proc/self/exe`:
`<its directory>/../share`. The runtime libraries in `lib/` are the vendor's
files, unchanged, and keep the vendor's run paths; [bundle_expected](../checks/bundle_expected)
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

The base image is `komira//tools/build/toolchains:distroless_base` (distroless base-debian12,
which has glibc, CA certificates and no shell), declared with `oci_base`: the
digest of its linux/amd64 manifest, that manifest's bytes checked in, and one
pinned download per blob. The packing action does not use the network: it
takes no URLs, reads only those files and refuses unless the manifest hashes to its
digest and names exactly the downloaded blobs.

Both formats are written by `komira_pack` ([`komira_pack.zig`](pack/komira_pack.zig)), a
static executable built by the pinned zig and run with no shell. It holds
its output in memory until it exits, up to about three times the bundle's
size at peak, which sets the size of bundle a `light` worker can pack. The
bytes
depend only on the bundle and the base: tar entries are sorted, with
directories listed, mtime and uid/gid 0 and modes 0755/0644; gzip headers
carry no time; JSON keys are sorted and every timestamp is
1970-01-01T00:00:00Z. Two uncached builds give the same tarball and the same
image digest ([bundle.sh](../checks/bundle.sh)), and `docker run` of the loaded image prints
the greeting ([formats.sh](../checks/formats.sh)).
