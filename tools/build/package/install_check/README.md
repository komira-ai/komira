# Install check

`conda_install_check` (`install_check.bzl`) installs a conda package of this
repository into an empty directory and loads its shared library from there, on
the farm, as the build's own action.

```python
load("@komira//tools/build/package/install_check:install_check.bzl", "conda_install_check")

conda_install_check(
    name = "libkomira_install",
    package = ":komira_so_libkomira_conda",
    lib = "libkomira.so",
    symbols = ["komira_abi_version"],
    version_symbol = "komira_abi_version",
    min_version = 1000,
)
```

Two actions run in two processes:

1. `komira_pack conda-install` writes the `.conda`'s files into the prefix, as
   an installer does, and holds them to the package's own `info/paths.json`
   (every path present once, each file's sha256 and size, a link a `softlink`).
   It then writes the Mojo runtime libraries into the prefix's `lib/`: the
   platform row's `runtime_libs`, taken from the toolchain. They stand for what
   the package's `mojo-compiler` requirement installs beside it; this action
   resolves no requirement. A runtime library the package itself ships is
   refused as a second owner of the path.
2. `dlopen_probe` loads `<prefix>/lib/<lib>` with `RTLD_NOW`, resolves each
   symbol, calls `version_symbol` (an `int32_t (*)(void)`) and requires at least
   `min_version`, then reads `/proc/self/maps`: every mapped file whose name
   starts with one of the platform row's `runtime_libs` must lie under the
   prefix, and `lib` and each `require` library must be mapped there. A runtime
   library taken from the host, or from anywhere else, fails the check. The
   action runs with `LD_LIBRARY_PATH` empty and the probe refuses it set.

The marker (the rule's output) lists what the probe loaded from the prefix;
`[prefix]` is the install, for looking at.

What it does not cover: a package manager's solver (the published files are
installed with one, and loaded again, in the release's install job), a `.so`
without `-z now` that fails only at a call, and macOS.
