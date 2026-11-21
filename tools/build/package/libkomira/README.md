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

Nothing here publishes anything.
