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

Nothing here publishes anything.
