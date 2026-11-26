# Changelog

What each release of the Python package `komira` added or changed, newest first. Installing it is
on [the install page](https://github.com/komira-ai/komira/blob/main/docs/install.md).

A change to the package never adds a line to this file. It adds one file, `python/changelog.d/<slug>.md`
(the slug is lower-case letters, digits and hyphens), holding one or more bullets: `- **Title.** text`,
a continuation line indented two spaces, no heading
([how to write one](https://github.com/komira-ai/komira/blob/main/python/README.md#changelog-entries)).
A release's version is `0.1.<n>`, given by the release workflow, so a pull request cannot know it: the
release assembles the entries, and the section `## 0.1.<n>` it ships, before the sections kept below,
lists the bullets of every file of `python/changelog.d/` in file-name order. So it lists every change
merged since the newest section kept in this file. A section is kept here by moving those bullets under a
`## <version>` heading of their own and deleting their files, in one change.

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
