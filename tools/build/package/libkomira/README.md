# libkomira package

The conda package that ships `libkomira`, the shared library with komira's flat
C API (`src/so`), and the check that installs it.

- `komira_so_libkomira_conda` is the package of the `so` Mojo library
  with `lib/libkomira.so` added (`conda_package(shared_lib = ...)`,
  [`../conda.bzl`](../conda.bzl)). Its metadata lists the library in
  `lib_files`. The Mojo runtime the library is linked against is not in the
  package: it comes from the `mojo-compiler` requirement. A release declares
  this target or the plain `so_conda`, not both (they are the same name,
  version and build with different contents). `release/artifacts.textproto` is
  where a release declares its packages, and it must name only one of them.
- `libkomira_install` installs that package into an empty prefix with the Mojo
  runtime beside it and loads the library from there with `RTLD_NOW`
  ([`../install_check`](../install_check/README.md)). Build it to run the check:

```sh
./buck2 build komira//tools/build/package/libkomira:libkomira_install
```

- `libkomira_elf_report` writes a markdown table read from the built files: size,
  SONAME, RUNPATH and `DT_NEEDED` of libkomira, of each native owner and of the Mojo
  runtime libraries, the highest `GLIBC_`, `GLIBCXX_` and `CXXABI_` version each
  needs, which owners libkomira reaches, and the `manylinux_2_<N>` tag the glibc floor
  allows (it says so on its first line if the floor promised by the platform row is
  exceeded). The table in [`src/so/README.md`](../../../../src/so/README.md) is its output.

```sh
./buck2 build komira//tools/build/package/libkomira:libkomira_elf_report
```

- `libkomira_dist_load` is the proof that the native directory a language package
  carries, `//src/so:libkomira[dist]` (libkomira, its native owners and the three Mojo
  runtime libraries in `lib/`), loads as it is from wherever it is copied
  ([`dist.bzl`](dist.bzl)). It copies the directory to another path and runs
  [`dist_load.c`](dist_load.c) there with no library path, no Python package and nothing
  of Modular's: the C caller opens the host's C++ runtime, then `libkomira.so` with
  `RTLD_NOW | RTLD_LOCAL`, requires `komira_abi_version()` to be the version of
  `komira.h`, and requires libkomira, every owner and each runtime library to be mapped
  from the copy. `libkomira_dist_load_refuses_missing_runtime` is the same check on the
  directory with `libMSupportGlobals.so` left out (`picked_dir`): it passes only if the
  load fails with the loader's error naming that file.

```sh
./buck2 build komira//tools/build/package/libkomira:libkomira_dist_load
```

- `dist_opens` holds what the native directory takes from the host
  ([`opens.bzl`](opens.bzl)). The wheel and the npm packages install no conda
  requirement, so every library libkomira's Mojo closure opens at run time
  (`mojo_library(dlopen = [...])`, collected up the closure as `MojoInfo.opens`)
  must be one the hosts of each platform of `DIST_NATIVE_NEEDS`
  ([`packaged.bzl`](packaged.bzl)) provide: the platform's row of `HOST_LIBS` in
  [`../system_libs.bzl`](../system_libs.bzl). On macOS that is libz, libbz2 and
  liblzma. macOS ships no libzstd and no liblz4. The check fails at analysis
  with one line per soname a platform lacks, naming the libraries that declare
  it, for example:

  ```text
  darwin-arm64: libkomira's closure opens libzstd.so.1 at run time (`dlopen` of compression), which a darwin-arm64 host does not provide and the native directory does not carry
  ```

  It is a Linux target. The declarations are the same for every platform, so
  the macOS row is judged in the pull request's check, before any macOS wheel
  is built. It is reached from every library in libkomira's closure, so a
  change that adds a `dlopen` there selects it. Its output lists, per platform,
  the sonames taken from the host and the libraries that open them.
  `dist_opens_cases()` fails loading the package when the refusal or the
  closure merge gets one of its cases wrong.

```sh
./buck2 build komira//tools/build/package/libkomira:dist_opens
```

- `libkomira_variants` is the native directory with libkomira at every CPU level
  of the linux-x86_64 row (`isa_variants` in
  [`../../platforms/table.bzl`](../../platforms/table.bzl), and
  [`docs/design/isa_variants.md`](../../../../docs/design/isa_variants.md)):

  ```text
  VARIANTS                          one line per level, lowest first: name, path, cpuinfo flags
  libkomira.so                      x86-64-v2, the floor: run path $ORIGIN/lib:$ORIGIN
  variants/x86-64-v3/libkomira.so   x86-64-v3, the build the tests run: run path also $ORIGIN/../../lib
  lib/                              the eleven native owners and the three Mojo runtime libraries, one copy
  ```

  The manifest is written from the platform row ([`variants.bzl`](variants.bzl)). The
  host's C++ runtime (`libstdc++.so.6`, `libgcc_s.so.1`) is not in it.
  `libkomira_variants_manifest` is that `VARIANTS` file alone, with no variant linked: the
  Python loader's selector test (`//python/tests:variants_test`) reads it as the shipped
  manifest.
- `libkomira_variants_load_x86_64_v2` and `libkomira_variants_load_x86_64_v3` copy
  that directory to another path and load the level they name by its VARIANTS line,
  from a C caller (`variants_load.c`) with no library path: it answers
  `komira_abi_version()` as `komira.h` states, it is the only libkomira mapped, and
  the libraries it loads are the copy's `lib/`. Every linux x86_64 worker implements
  x86-64-v3, so both levels run there. Two checks must refuse, each with the exact
  line: `libkomira_variants_load_refuses_missing_runtime` (`lib/` without
  `libMSupportGlobals.so`) and `libkomira_variants_load_refuses_missing_variant`
  (VARIANTS names a file the directory does not hold; the load fails and does not
  fall back to the floor).

```sh
./buck2 build komira//tools/build/package/libkomira:libkomira_variants_load_x86_64_v2 \
    komira//tools/build/package/libkomira:libkomira_variants_load_x86_64_v3
```

Nothing here publishes anything.
