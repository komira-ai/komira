# libkomira package

The conda package that ships `libkomira`, the shared library with komira's flat
C API (`src/komira_so`), and the check that installs it.

- `komira_so_libkomira_conda` is the package of the `komira_so` Mojo library
  with `lib/libkomira.so` added (`conda_package(shared_lib = ...)`,
  [`../conda.bzl`](../conda.bzl)). Its metadata lists the library in
  `lib_files`. The Mojo runtime the library is linked against is not in the
  package: it comes from the `mojo-compiler` requirement. A release declares
  this target or the plain `komira_so_conda`, not both (they are the same name,
  version and build).
- `libkomira_install` installs that package into an empty prefix with the Mojo
  runtime beside it and loads the library from there with `RTLD_NOW`
  ([`../install_check`](../install_check/README.md)). Build it to run the check:

```sh
./buck2 build komira//tools/build/package/libkomira:libkomira_install
```

Nothing here publishes anything.
