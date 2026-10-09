# llvm_branch

`komira//tools/build/toolchains/llvm_branch:llvm_branch` is the LLVM part of
branch coverage for Mojo: the linker that instruments a test's LLVM bitcode,
the profile runtime the instrumented test is linked with, and the tool that
reads the profile the test writes. The branch coverage runs of
[`coverage/branch`](../../coverage/branch/README.md) use it.

| target | what |
|---|---|
| `:lld24` | a directory: `bin/lld` of the pinned Mojo package (LLD 24, the LLVM the Mojo compiler is built on), with `lib/libstdc++.so.6` and `lib/libgcc_s.so.1`, which it loads |
| `:llvm23` | a directory: `bin/llvm-profdata` and `bin/llvm-nm` of LLVM 23.1.3, the libraries they load under `lib/`, and `runtime/libclang_rt.profile-x86_64.a`, the compiler-rt 23.1.3 profile runtime |
| `:llvm_branch` | both directories, gated by the checks below; `LlvmBranchInfo` ([`defs.bzl`](defs.bzl)) has `lld`, `profdata` (each a command line with its directory as a hidden input), `runtime`, `lld_dir` and `tools_dir`; sub-targets `[lld]`, `[tools]` and `[runtime]` |

Every file in both directories is a regular file. Both programs find their
libraries through their `DT_RPATH` `$ORIGIN/../lib`, which the loader
searches before `LD_LIBRARY_PATH`, so a test runner's `LD_LIBRARY_PATH` does
not change what they load.

It is built and checked on linux-x86_64 only. Every target here but `:shell_lint` carries
`target_compatible_with = LINUX_X86_64` with the marker
`komira-limit:coverage-linux-x86-64` ([limits.tsv](../../platforms/limits.tsv)),
and the other rows of the [platform table](../../platforms/table.bzl) state
`none` for its pins. It lives under `toolchains/`, like
[kcov](../kcov/README.md), because it is a set of pinned tools that rules
run, not code that komira ships.

## How branch coverage uses it

A coverage build compiles a test to LLVM bitcode. `bin/lld` runs over that
bitcode as an LTO link with `-r`, `--lto-O0` and
`--lto-newpm-passes=pgo-instr-gen,instrprof,default<O0>`, which adds IR
profile counters. zig links the result with the profile runtime (whole
archive), the test runs and writes a raw profile, and `llvm-profdata merge`
turns it into an indexed profile ([coverage/branch](../../coverage/branch/README.md)).
Still to come: `bin/lld` reads that back with `pgo-instr-use`, so that every
branch of the IR carries its counts. `:raw_version_check` runs all of it but
`pgo-instr-use` on a C fixture.

## Why LLVM 23 tools are safe next to LLVM 24

Only the LLVM 24 `lld` ever reads or writes Mojo's bitcode: it instruments
it, and it reads the counts back in. The LLVM 23 pieces never see bitcode:

- the profile runtime only writes out the counters and data the
  instrumented code laid out, into the raw profile file;
- `llvm-profdata` only reads that raw profile and writes an indexed profile,
  which the LLVM 24 `pgo-instr-use` reads (a newer LLVM reads the indexed
  profiles of older ones).

What couples them is the raw profile format, below. The Mojo package ships
`lld` but no profile runtime and no `llvm-profdata`, so those come from an
LLVM release that conda-forge publishes.

## The version coupling

The instrumented module defines `__llvm_profile_raw_version`: the raw
profile version of the LLVM that instrumented it (the low 32 bits; the high
32 bits are variant flags, `0x01000000` for IR instrumentation). The runtime
writes that value into the raw profile's header, and `llvm-profdata` accepts
a raw profile only when its version is exactly its own. LLVM changes the
version whenever it changes the raw format, so equal versions mean the
runtime's layout is the one the reader expects.

The runtime defines `__llvm_profile_raw_version` too, weakly, as its own
version with no variant flags, so that a program without instrumented code
still links. If the instrumenter's definition were lost (dropped or made
local in the `-r` link), the runtime's would be written instead, and a
version check would compare the runtime with `llvm-profdata` and say nothing
about LLVM 24. `:raw_version_check` therefore also requires that the
instrumented object defines the symbol strongly, that the runtime defines it
only weakly, and that the raw profile's flags carry the IR bit, which only
the instrumenter's definition sets.

`:raw_version_check` measures, on every build in which an input changed (a
new Mojo package is a new `lld`, so the check runs again), that the raw
profile written by code that Mojo's LLD 24 instrumented has version 11 with
the IR flag, and that `llvm-profdata` 23.1.3 accepts it (its report holds
`raw profile version 11, variant flags 0x01000000`). When they part, it
fails, naming both versions:

```
llvm_branch raw_version RED: raw profile version 12 not accepted by llvm-profdata 23.1.3, which expects 11: warning: .../pg.profraw: raw profile version mismatch: Profile uses raw profile format version = 12; expected version = 11 ...
```

The runtime (compiler-rt) and `llvm-profdata` are both pinned at LLVM
23.1.3. `:raw_version_check` is also what proves that pair compatible: the
runtime writes the profile that `llvm-profdata` merges.

### Updating

- **A new Mojo.** `:lld24_check` requires `LLD 24.` (`lld` in `BUCK`); a
  Mojo built on another LLVM fails it. Before changing `lld`, build
  `:raw_version_check`: if it fails, pin the profile runtime and
  `llvm-profdata` of an LLVM release whose raw version is the one the new
  `lld` writes (the LLVM release the Mojo LLVM branched from, or a later
  one with the same version), set `RAW_PROFILE_VERSION` in
  [`defs.bzl`](defs.bzl) to that version (every branch coverage run
  requires it of each raw profile, and `:raw_version_check` requires
  `llvm-profdata` to accept it), and re-run the branch coverage of a Mojo
  test end to end
  ([coverage/branch](../../coverage/branch/README.md)).
- **New LLVM 23 pins.** Change the `llvm_branch_*` roles of
  [`table.bzl`](../../platforms/table.bzl) and `profdata` in `BUCK`. A
  package whose libraries change needs the members of `:llvm23` and the
  library list of `check.sh` (`LIBS23`) changed with it.

## What is pinned

The roles of the linux-x86_64 row of
[`platforms/table.bzl`](../../platforms/table.bzl), fetched here with
`pinned_file(**pinned_kwargs("linux-x86_64", <role>))`, all from conda-forge:

| role | target | taken from it |
|---|---|---|
| `llvm_branch_tools` | `:llvm-tools-23_23.1.3_linux-64.conda` | `bin/llvm-profdata-23`, `bin/llvm-nm-23` |
| `llvm_branch_libllvm` | `:libllvm23_23.1.3_linux-64.conda` | `lib/libLLVM.so.23.1` |
| `llvm_branch_libxml2` | `:libxml2-16_2.15.4_linux-64.conda` | `lib/libxml2.so.16`, which `libLLVM` loads |
| `llvm_branch_libiconv` | `:libiconv_1.18_linux-64.conda` | `lib/libiconv.so.2`, which `libxml2` loads |
| `llvm_branch_zstd` | `:zstd_1.5.7_linux-64.conda` | `lib/libzstd.so.1`, which `libLLVM` loads |
| `llvm_branch_rt` | `:compiler-rt23_linux-64_23.1.3_noarch.conda` | `lib/clang/23/lib/linux/libclang_rt.profile-x86_64.a` |

and the toolchain's own pins, fetched here again because those targets are
private to [`toolchains/BUCK`](../BUCK) (the same sha256 and size, so nothing
new is downloaded): `mojo_compiler` (`bin/lld`), `libstdcxx`
(`libstdc++.so.6`), `libzlib` (`libz.so.1`), and `libgcc`
(`libgcc_s.so.1`, through its public target).

The `llvm-tools` package of the same build is not pinned: it holds only the
links `bin/llvm-profdata -> llvm-profdata-23` and so on. Nothing in the
closure loads `liblzma`.

`libxml2.so.16` holds a conda install-prefix placeholder in one string, the
default path of its XML catalog, which conda would rewrite on install and
this unpack does not. Neither program reads an XML catalog; the string
names a path that exists nowhere.

## How it is unpacked

[`unpack.sh`](unpack.sh) is one action per directory. For each package,
`conda_payload` ([`../kcov/conda_payload.zig`](../kcov/conda_payload.zig))
writes the payload tar, and busybox `tar` extracts only the members named
in `BUCK`. A member that is a link in its package (most library sonames)
is followed within the package, and the file it resolves to is written; a
link to an absolute path or out through `..` fails the action, as does a
missing or empty member.

`bin/lld` is taken this way rather than through `conda_closure`, which
would carry the whole compiler with it, and
[`mojo/tools/conda_unpack.zig`](../../mojo/tools/conda_unpack.zig) is not
changed: it is an input of the Mojo compiler closure, and editing it would
re-key every Mojo action.

## Checks

Each is a build action that `:llvm_branch` depends on through
`ValidationInfo` ([`check.sh`](check.sh)), so no build that uses
`:llvm_branch` succeeds unless they pass. Each mutant below was planted and
made the build fail with the message shown, then removed.

| target | proves | catches | mutant planted |
|---|---|---|---|
| `:lld24_check` | `:lld24` holds `bin/lld` and its two libraries, regular files, nothing else; with a decoy `LD_LIBRARY_PATH` the loader resolves `bin/lld`'s libraries to its own `lib/` and glibc only; `lld -flavor gnu --version` prints `LLD 24.` | a Mojo built on another LLVM; a library taken from the worker | `lld = "25"`: `does not print 'LLD 25.'` |
| `:llvm23_check` | `:llvm23` holds exactly its files; the loader resolves the libraries of `llvm-profdata` and `llvm-nm` to its `lib/` and glibc only; `llvm-profdata --version` prints `LLVM version 23.1.3`; the runtime is an ar archive defining `__llvm_profile_runtime` and `__llvm_profile_write_file` | a library missing from `lib/` (the worker has some, e.g. `libz.so.1`, so the tool would run there and nowhere else); another tool version; another runtime | `profdata = "23.1.4"`; `libz.so.1` left out: `loads 'libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1'`; the runtime member pointed at `libclang_rt.ctx_profile-x86_64.a`: `does not define __llvm_profile_runtime` |
| `:raw_version_check` | [`fixtures/profile_fixture.c`](fixtures/profile_fixture.c), compiled to bitcode by zig, instrumented by `bin/lld` with the passes above, linked with the runtime and run, writes a raw profile with the 64-bit magic; the instrumented object defines `__llvm_profile_raw_version` strongly and the runtime only weakly, and the profile's flags carry the IR bit `0x01000000`; `llvm-profdata` merges it, its version is `RAW_PROFILE_VERSION` of [`defs.bzl`](defs.bzl) (11), and `show` reports 3 functions and `classify`'s counters 2 and 3; the same profile with its version raised by one is refused as LLVM's `raw profile version mismatch`, with llvm-profdata expecting the measured version | the version coupling (above); a profile whose version is the runtime's default rather than the instrumenter's; a runtime that writes no or another profile; a check of the version that cannot fail, or that takes any other refusal for a version refusal; a `RAW_PROFILE_VERSION` that is not the version written and read | the profile's version raised before the merge: `raw profile version 12 not accepted by llvm-profdata 23.1.3, which expects 11`; the merge's failure ignored: `llvm-profdata accepted raw version 12: the version check cannot fail`; the doctored profile also cut to 24 bytes: `the doctored profile was refused, but not for its version: ... (file header is corrupt)`; the instrumented object's `__llvm_profile_raw_version` renamed in its string table: `does not define __llvm_profile_raw_version strongly (llvm-nm class '')`, and with that check bypassed: `variant flags 0x00000000 lack the IR-instrumentation bit`; the runtime lookup pointed at `__llvm_profile_write_file`: `does not define __llvm_profile_raw_version once and weakly (llvm-nm classes 'T')`; `RAW_PROFILE_VERSION = 12`: `llvm-profdata accepts raw version 11, but RAW_PROFILE_VERSION of defs.bzl ... is 12` |
| `:shell_lint` | shellcheck over `check.sh` and `unpack.sh` | | |

`unpack.sh` fails on a member that is not in its package (the profdata
member renamed `llvm-profdata-22`: `bin/llvm-profdata-22 is not a member of
tools`).

## Licences

- LLVM, of which `lld`, `llvm-profdata`, `llvm-nm`, `libLLVM` and the
  compiler-rt profile runtime are parts, is Apache-2.0 WITH LLVM-exception.
  The licence text is in each conda package's `info/licenses/`. The profile
  runtime is linked into instrumented test binaries; the LLVM exception
  covers that, and no product links it.
- `libxml2` is MIT, `zstd` BSD-3-Clause, `zlib` Zlib, `libiconv`
  LGPL-2.1 (loaded as a shared library by the tools, linked into nothing),
  and `libstdc++`/`libgcc_s` GPL-3.0 with the GCC Runtime Library Exception.
- Nothing here is packed into a release artifact: these are build tools.
