# Changelog

What each release of the Python package `komira` added or changed, newest first. Installing it is
on [the install page](../docs/install.md).

A release's version is `0.1.<n>`, given by the release workflow, so a pull request cannot know the
version it will ship in. A pull request that changes what the package does, or what it needs, adds
a line under `## Unreleased` (adding that heading above the newest release if it is not there), and
the release that ships it moves those lines under its own `## <version>` heading.
`//python/smoke:install_page_shows_quickstart` reads the newest version heading here: the output the
install page shows names it.

## Unreleased

- **Python 3.11 and 3.12.** The wheel installs on CPython 3.11, 3.12, 3.13 and 3.14: its
  `Requires-Python` is `>=3.11` (it was `>=3.13`), and its classifiers name the four. The package's
  tests and the install of each release run on all four.

## 0.1.1512

The first release, on PyPI and TestPyPI: one wheel, `komira-0.1.1512-py3-none-manylinux_2_35_x86_64.whl`.

- **Platforms.** Linux on x86_64 only, with glibc 2.35 or newer, an x86-64-v3 CPU (AVX2, BMI2,
  FMA) and the system `libstdc++`. Python 3.13 or newer.
- **Self-contained.** The wheel carries `libkomira` and the three Mojo runtime libraries it loads, and
  requires no other package.
- **What works.** `import komira`, `komira.__version__`, `komira.abi_version()` (1001: ABI 1.1), and
  `komira.Session()` with `register_parquet(name, path)`, `close()` and `closed`. The errors
  `KomiraError`, `LibraryLoadError` and `UnsupportedCpuError`.
- **What does not.** No query runs: no SQL, no results, no DataFrame API. Only Parquet files
  register.
