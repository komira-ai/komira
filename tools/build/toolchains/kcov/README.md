# kcov

`komira//tools/build/toolchains/kcov:kcov` is kcov v42, the line coverage
tool of the Mojo coverage variant. It is built from source on the farm, with
two changes ([Patches](#patches)), and the target is a directory (`[bin]` is
its `bin/kcov`):

| path | what |
|---|---|
| `bin/kcov` | kcov, linked statically against everything except glibc and the unwinder |
| `lib/libgcc_s.so.1` | the unwinder, found through the `DT_RPATH` `$ORIGIN/../lib` of `bin/kcov` |
| `share/licenses/` | kcov's `COPYING` and `COPYING.externals`, and a `NOTICE` naming what else `bin/kcov` and `lib/` hold ([Licences](#licences)) |

Its checks are build actions that `:kcov` depends on, so no build that uses
kcov succeeds unless they pass ([Checks](#checks)). It is built and checked on
linux-x86_64 only. Every target here carries
`target_compatible_with = LINUX_X86_64` with the marker
`komira-limit:coverage-linux-x86-64` ([limits.tsv](../../platforms/limits.tsv)),
and the other rows of the [platform table](../../platforms/table.bzl) state
`none` for its pins. Line coverage of the sources is measured once, on one
platform.

## Why from source

kcov publishes no static build. The v42 release binary is dynamically
linked against `libdw`, `libelf`, `libbfd`, `libopcodes` and `libcurl`, which a
worker does not have. Supplying them from a distribution's packages would set
the glibc floor at that distribution's glibc and need a stub libcurl. Built
here from the tag's source:

- every library except the unwinder is linked from a static archive, and
  the glibc floor is the platform row's own (`zig_triple`,
  `x86_64-linux-gnu.2.34`). zig links against glibc 2.34's symbols, so the
  link fails if kcov or an archive calls a newer one, and check 2 reads
  the symbol versions of the result;
- nothing is taken from the worker: the compiler is the pinned zig, and
  every input is a sha256 pin;
- libcurl and libbfd are left out (see below), which also removes OpenSSL.

kcov lives under `toolchains/` because it is a pinned tool that rules run,
like zig and busybox, not code that komira ships.

## What is pinned

Every download is a role of the linux-x86_64 row of
[`platforms/table.bzl`](../../platforms/table.bzl), fetched here with
`pinned_file(**pinned_kwargs("linux-x86_64", <role>))`:

| role | target | what |
|---|---|---|
| `kcov_src` | `:kcov-v42.tar.gz` | the source archive of the kcov `v42` tag from github.com (GPL-2.0, `COPYING` in the archive) |
| `kcov_elfutils` | `:elfutils_0.194_linux-64.conda` | `libdw.a`, `libelf.a` and their headers |
| `kcov_zlib` | `:zlib_1.3.2_linux-64.conda` | `libz.a` and `zlib.h` |
| `kcov_bzip2` | `:bzip2_1.0.8_linux-64.conda` | `libbz2.a`, which `libdw.a` calls |
| `kcov_zstd` | `:zstd-static_1.5.7_linux-64.conda` | `libzstd.a`, which `libdw.a` calls |
| `kcov_lzma` | `:liblzma-static_5.8.3_linux-64.conda` | `liblzma.a`, which `libdw.a` calls |
| `libgcc` | `komira//tools/build/toolchains:libgcc_15.3.0_linux-64.conda` | `libgcc_s.so.1`: the Mojo toolchain's own pin, not a second one |

GitHub generates a tag archive on request. If its bytes ever change, the
sha256 check fails the build; it never builds from bytes nobody pinned.

## How it is built

[`kcov_build.sh`](kcov_build.sh) is one action of `:kcov_dist`
([`defs.bzl`](defs.bzl)). Its steps:

1. **Unpack.** The conda packages are unpacked with `:conda_payload`
   ([`conda_payload.zig`](conda_payload.zig)), which writes a package's
   payload tar for busybox `tar`. busybox cannot read a `.conda`: it handles
   neither the zip64 sizes nor the zstd payload. The zip walk is copied from
   [`mojo/tools/conda_unpack.zig`](../../mojo/tools/conda_unpack.zig) and
   that file is left unchanged, because it is an input of the Mojo compiler
   closure and editing it would re-key every Mojo action. `conda_unpack
   --only-libs` cannot be used either: it extracts members under `lib/` only,
   and kcov also needs the headers.
2. **Generate the sources kcov's CMake build would generate.** Upstream turns
   files into C++ byte arrays with `bin-to-c-source.py`; here the same format
   is written with busybox `od` and `sed`, because no Python is pinned. The
   generated sources are:
   - `library.cc`: the preload library `kcov_sowrapper`
     (`solib-parser/{phdr_data,lib}.c`, `zig cc -shared`);
   - `bash-redirector-library.cc` and `bash-cloexec-library.cc`: the two
     `engines/bash-*.c` helpers;
   - `kcov-system-library.cc`: `kcov_system_lib` (`system-mode-binary-lib.cc`,
     `utils.cc`, `system-mode/registration.cc`);
   - `python-helper.cc` and `bash-helper.cc`: the helper scripts;
   - `html-data-files.cc`: the eleven files of `data/`;
   - `version.c`: `v42`, which is what `git describe` gives at the tag and
     what the release binary prints. CMake run on this archive, which has
     no `.git`, would write `42`, taken from the first line of `ChangeLog`.

   The helper libraries are built for real rather than embedded empty, so
   kcov behaves as the release does: an empty array would make kcov write an
   empty file and preload it if it were ever run on a script.
3. **Compile and link kcov.** The Linux source list of kcov's
   `src/CMakeLists.txt` is used, with `parsers/dummy-disassembler.cc` (what
   upstream picks without libbfd) and `writers/dummy-coveralls-writer.cc`
   (what upstream's `KCOV_STATIC_BUILD` picks: the Coveralls upload is the one
   real use of libcurl). `utils.cc` still calls `curl_easy_init`,
   `curl_easy_escape` and `curl_easy_cleanup` to escape URLs in the HTML
   report, so [`shim/curl_shim.c`](shim/curl_shim.c) defines those three,
   percent-encoding as libcurl does. The flags are upstream's:
   `-std=c++17 -D_GLIBCXX_USE_NANOSLEEP -DKCOV_LIBRARY_PREFIX=/tmp
   -DKCOV_HAS_LIBBFD=0 -DKCOV_LIBFD_DISASM_STYLED=0 -DPACKAGE
   `-DPACKAGE_VERSION`. On top of those come `-O2 -g0 -fPIC`, zig's static
   libc++, and `-target` from the platform row. `KCOV_LIBRARY_PREFIX`
   appears only in the CMake files of v42, not in its sources, so the `/tmp`
   it names is compiled into nothing ([What kcov writes when it
   runs](#what-kcov-writes-when-it-runs)).
   - upstream's second program, `kcov-system-daemon`
     (`main-system-daemon.cc`, kcov's system-wide mode), is not built: the
     coverage variant runs kcov on one test binary at a time.
   - `libelf.a` and `libz.a` both define `crc32`, the same CRC-32 function,
     and lld refuses the duplicate. libelf's objects are linked without its
     `crc32.o`, and the script fails if that member ever disappears or is
     duplicated.

### The unwinder

kcov's solib handler calls `pthread_cancel` at the end of every run.
glibc's `pthread_cancel` dlopens `libgcc_s.so.1` and unwinds the cancelled
thread with it. A worker has no `libgcc_s.so.1`, so kcov aborts ("libgcc_s.so.1 must be
installed for pthread_cancel to work"). Shipping the library is not enough on
its own. The cancelled thread's C++ frames are unwound through the personality
routine of zig's libc++abi, and when that routine is linked against zig's
static libunwind it reads libgcc's unwind context as libunwind's, and kcov
crashes. So `bin/kcov` links `libgcc_s.so.1` itself, as an input ahead of
zig's own libraries, and takes its `_Unwind_*` symbols from it. That leaves
one unwinder, which glibc's dlopen then finds already loaded.

### The run path

The test runner sets `LD_LIBRARY_PATH` to the Mojo toolchain's `lib/` for the
program under test, and kcov runs with that environment. That `lib/` holds a
`libgcc_s.so.1` of its own. The loader searches a `DT_RPATH` before
`LD_LIBRARY_PATH` and a `DT_RUNPATH` after it, so `bin/kcov` needs a
`DT_RPATH`. zig 0.12 forwards `--disable-new-dtags` to lld only when it links
a shared library, so every executable it links gets a `DT_RUNPATH`.
[`elf_rpath.zig`](elf_rpath.zig) (`:elf_rpath`) changes the tag after the link
(29 to 15). That is the one byte `--disable-new-dtags` would have changed, and
the tool refuses a file that does not have exactly one `DT_RUNPATH` and no
`DT_RPATH`.

### Reproducible

The four helper libraries are stripped (`-s`), as `bin/kcov` is. zig builds
its C runtime objects and libc++ with debug information, whose compilation
directory is the worker's absolute path. Unstripped, that information makes
every build differ, and with it the key of every action that reads kcov. A
cache eviction would then re-run all of them.

### Patches

`kcov_build.sh` changes v42's source with `sed` before compiling it. Each
changed line holds `KOMIRA PATCH`, and the build fails when an expression
marks another number of lines than expected (a new kcov changed the code
there), so a patch is never silently lost. Both make a test run under kcov
as it runs in the release gate (test 43 of the
[tests README](../../tests/README.md#43-coverage-runs) holds each red on v42
as released):

1. **No CPU pin.** v42 pins itself and the traced program to the CPU it
   started on (`tie_process_to_cpu` in `engines/ptrace_linux.cc`:
   `sched_setaffinity` to one CPU, "Switching CPU while running will cause
   icache conflicts"), so every test under kcov ran on one CPU while the
   release gate gives it all the worker's: a test that counts cores, or
   parallel code, behaved differently and slowly. The function is now
   empty. On x86-64, the only platform kcov is built for, the instruction
   cache is coherent with stores, and kcov inserts its breakpoints before
   the program runs (`--skip-solibs`: no library is patched later; a
   shared library's driver runs without it, and kcov patches the library it
   loads when its preload library reports the load); while
   it runs, kcov only removes a breakpoint once hit, a one-byte write that
   another thread sees either before (a trap kcov handles, since it keeps
   the address in its map) or after.
2. **The test's exit status.** v42 sets its exit status from the exit of
   every traced process (`collector.cc`, `ev_exit`) and from a signal death
   of any process once the first has gone (`engines/ptrace.cc`), as the
   bare signal number. So a child the test left behind decided it: a test
   that failed and left a child exiting 0 later passed. Now only the first
   process (the test) sets it, and a death by signal N gives 128+N, as a
   shell reports it.

kcov still disables address randomization for the program
(`ADDR_NO_RANDOMIZE` through `personality`), and still waits for every
process the program started to exit before it writes the report.

### What kcov writes when it runs

From v42's `src/solib-handler.cc` (`SolibHandler::startup`), on every run
of an ELF program:

- `<out-dir>/libkcov_sowrapper.so`, the preload library (the array
  `__library`), written into the output directory given on the command line
  and left there after the run. kcov puts it on the program's `LD_PRELOAD`.
- the FIFO `kcov-solib.pipe`, through which that library reports the shared
  libraries the program loads: in `<out-dir>/` with `--cobertura-only`, in
  `<out-dir>/<binary>.<hash>/` otherwise. kcov unlinks it at exit.
- only if `mkfifo` fails there (a file system without FIFOs): a directory
  `$TMPDIR/kcov-solibXXXXXX` (`mkdtemp`; `/tmp` when `TMPDIR` is unset)
  holding the FIFO, removed at exit. This is the one place v42 reads
  `TMPDIR` and the one place `bin/kcov` can write outside `<out-dir>`.

So a run inside a build action's sandbox writes under `<out-dir>` only,
unless the FIFO cannot be made there; a coverage run should set `TMPDIR` to
its scratch directory so that the fallback also stays inside it.
[cov_run](../../coverage/kcov/README.md#cov_run) does: it runs kcov through
`gate_runner.sh`, whose `TMPDIR` is a directory made for that run under the
action's working directory, and its output directory is in the action's
scratch directory. The other
fixed `/tmp` paths of v42 (`/tmp/kcov-system.pipe`, `/tmp/kcov-data/`)
belong to the system-wide mode (`kcov_system_lib`, `kcov-system-daemon`),
which the coverage variant does not run. Check 7 requires that the traced
fixture initialised the preload library.

## Licences

**Decision.** kcov is accepted as an external, build-only tool of komira's
Apache-2.0 build system. The repository holds only the recipe: upstream's
source is fetched by its pinned hash and built on the build's own machines.
kcov is never vendored, never linked into komira's code, and never shipped
in a published package (the guard below enforces that). The two shim files
compiled into it (`shim/curl_shim.c`, `shim/curl/curl.h`) are MIT-licensed,
not Apache-2.0, because Apache-2.0 code cannot be combined into a GPL-2.0
program.

If a prebuilt kcov is ever distributed (a public build cache, a toolchain
bundle), its corresponding source and `COPYING` must ship with it. A remote
cache that holds `bin/kcov` must therefore stay private to the people who
build komira; making such a cache readable by others distributes kcov.

kcov's only interface to the rest of the build is the Cobertura report it
writes, so another tool that writes Cobertura (llvm-cov, for one) can
replace it without changing what reads the report.

kcov is GPL-2.0, and `bin/kcov` embeds the files of its `data/` (jQuery and
handlebars, MIT; tablesorter, GPL-2.0 or MIT) and links elfutils' `libdw`
and `libelf` statically. `lib/libgcc_s.so.1` is GCC's runtime library
(GPL-3.0 with the GCC Runtime Library Exception). `kcov_build.sh` copies
kcov's `COPYING` and `COPYING.externals` into `share/licenses/kcov/` and
writes `share/licenses/NOTICE`, which lists every component with the licence
its conda-forge package declares. Check 1 requires those files.

kcov is a separate program: it traces a test over ptrace and writes a
report, and neither the test nor komira's code links it. No target in
komira publishes the distribution; build actions use it. Publishing it (in
a release bundle, a package channel, or a cache others read) would carry
GPL-2.0's obligations to offer the source.

The build enforces that for the package formats
([package/README.md](../../package/README.md#kcov-is-never-packed)): a
`mojo_bundle`, `bundle_tarball`, `oci_image` or `conda_package` holding a
file whose sha256 is `KCOV_BIN_SHA256`, or whose bytes contain
`KCOV_USAGE_LINE` (`Usage: kcov [OPTIONS] out-dir in-file [args...]`), the
two constants of [`identity.bzl`](identity.bzl), fails the build naming the
file. The guard reads those constants and depends on no kcov target, so no
package build builds kcov. `:kcov_identity` ([Checks](#checks)) holds them
to the built `bin/kcov`: a kcov whose bytes or usage line change fails its
own build until the constant is updated. The guard reads whole files: kcov inside an archive or a
compressed stream in a package, and the files kcov writes when it runs (its
preload library `libkcov_sowrapper.so`, its report directories), are not
inspected. The build does not stop anyone copying kcov out of `buck-out`,
nor a remote cache readable by others from holding it.

## Checks

[`kcov_check.sh`](kcov_check.sh) runs as four validations that `:kcov` depends
on. Each row below names the defect the check catches and the planted defect
it was seen to fail on. Each validation's result names its count:
`:kcov_check` 9 checks (one per row), `:kcov_check_cases` 24,
`:kcov_identity` 2, `:kcov_reproducible` 1. The scripts run with
`set -o pipefail` (busybox `sh` has it), so a pipeline stage that fails, such
as a `cat` that cannot read its file, fails the check rather than leaving an
empty result.

`:kcov_check` checks the built kcov. Throughout, `LD_LIBRARY_PATH` names a
directory of decoys: files named `libz.so.1`, `libdw.so.1`, `libelf.so.1`,
`libgcc_s.so.1`, `libstdc++.so.6` and the like, none of them ELF, so the
loader fails loudly if it takes one.

| # | check | catches | planted, red |
|---|---|---|---|
| 1 | the distribution holds `bin/kcov`, `lib/libgcc_s.so.1` and the three licence files, nothing else, and kcov's licence files are the archive's | a library in `lib/`, which the loader searches before `LD_LIBRARY_PATH` and the system whatever its name; a missing or wrong licence file | a `libm.so.6` copied into `lib/`: `the distribution holds ... ./lib/libm.so.6`; `COPYING.externals` copied as `COPYING` |
| 2 | no `GLIBC_2.<n>` symbol version above the row's floor in `bin/kcov` (including the libraries it embeds) or `lib/` | kcov or a pinned library needing a newer glibc than the workers and users have | kcov linked for `x86_64-linux-gnu.2.38`: `needs GLIBC_2.38, above the floor GLIBC_2.34` |
| 3 | `bin/kcov` names the version `GCC_3.0`, so it imports from `libgcc_s.so.1` | a second unwinder (above). This sees one import, not where every `_Unwind_*` comes from; the run of check 6 ends in `pthread_cancel`, which a second unwinder crashes | `libgcc_s.so.1` left out of the link |
| 4 | the loader's list for `bin/kcov` (`LD_TRACE_LOADED_OBJECTS`) holds its own `lib/libgcc_s.so.1` and glibc libraries from outside the distribution and the decoys, nothing else | a library taken from `LD_LIBRARY_PATH`, the worker, or `lib/` under a glibc name | the `elf_rpath` step skipped: `the loader took a decoy ... decoy/libgcc_s.so.1`; a `libm.so.6` in `lib/` with check 1 and 2 let past: `bin/kcov loads libm.so.6 => .../bin/../lib/libm.so.6` |
| 5 | `kcov --version` prints `kcov v42` | the wrong source, or a kcov that does not start | the build's `version` set to `v41`: `kcov --version printed 'kcov v41', want 'kcov v42'` |
| 6 | kcov `--cobertura-only` on [`fixtures/cov_fixture.c`](fixtures/cov_fixture.c) (`zig cc -g -O0`) reports every `COV:hit` line hit and every `COV:miss` line missed, and its report, with the source directory written `@SRC@` and the timestamp 0, is [`fixtures/cov_fixture.cobertura.xml`](fixtures/cov_fixture.cobertura.xml) byte for byte | wrong hits, missing or extra lines, a changed report format | kcov's Cobertura writer reporting `hits + 1`: the markers pass and the golden fails |
| 7 | in that run, the loader's `LD_DEBUG=libs` record of kcov searched a `DT_RPATH` of `bin/kcov` and initialised its own `lib/libgcc_s.so.1` and glibc libraries from outside the distribution and the decoys, nothing else; the fixture's record initialised the preload library kcov wrote, `libkcov_sowrapper.so` | the same as 4, observed in the process that does the work; a preload library the loader cannot map, which it ignores with a warning while check 6 stays green | the array `__library` built from `glass.png`: `the fixture did not initialise the preload library` |
| 8 | kcov run as the coverage variant runs it: on `cov_fixture.c` and [`fixtures/cov_part.c`](fixtures/cov_part.c), compiled with their directory mapped to a placeholder `/_..._` that exists nowhere (the build directory is then deleted), with `--replace-src-path=^/_+:<root>` and `--configure=cobertura-full-paths=1`. Every COV line is reported as marked in its own file's class, no placeholder is left, and the report with the root written `@ROOT@` is [`fixtures/cov_fixture_relocated.cobertura.xml`](fixtures/cov_fixture_relocated.cobertura.xml) byte for byte | the regex mapping (kcov's `std::regex`, here zig's libc++ rather than the release binary's libstdc++), and file names relative to the common directory | `filter.cc` without its `regex_replace`: `cov_fixture.c is not in rout/cov.xml`; the Cobertura writer ignoring `cobertura-full-paths`: the same |
| 9 | the HTML report (kcov's default output) writes nine of the files of the archive's `data/` byte for byte (one check) | a generated byte array that does not hold its file | the array `icon_amber` built from `glass.png` |

The arrays of the bash and Python helpers and of `kcov_system_lib` are not
checked: the coverage variant runs none of those engines.

`:kcov_check_cases` runs the functions behind checks 2, 4 and 7, the two
tools, and the `identity` mode of `:kcov_identity`, on inputs whose answer is
known:

| case | catches | planted, red |
|---|---|---|
| a program needing `arc4random` (`GLIBC_2.36`) fails to link for the floor, over `arc4random`, and check 2's function names `GLIBC_2.36` in its 2.38 build and nothing in floor builds | a floor check that cannot see a version; a floor link that fails for another reason | the version strings filtered by length: `glibc_over says ''`; the floor link given a missing source: `failed to link for the floor, but not over arc4random` |
| check 2's function fails on a file that does not exist | a pipeline whose failing `cat` leaves an empty list, read as "nothing above the floor" | the scripts without `set -o pipefail`: `glibc_over exited 0 on a file that does not exist` |
| a probe linked like `bin/kcov` against its own `libkcovprobe.so.1`: with zig's `DT_RUNPATH` the decoy wins and both detectors see it; with an empty `LD_LIBRARY_PATH` its `LD_DEBUG` record names a `RUNPATH` search, which check 7's function does not take for an `RPATH` one; after `elf_rpath` the probe's own library loads, the `LD_DEBUG` record says `RPATH`, and one byte changed | a detector that misses a decoy; a check 7 that accepts a `DT_RUNPATH` search; a zig that starts writing `DT_RPATH` (then `elf_rpath` is no longer needed) | `elf_rpath` writing nothing: `after elf_rpath the loader still took the decoy`; the record matched as `PATH from file`: `rpath_record took a DT_RUNPATH search for a DT_RPATH one` |
| the functions of checks 4 and 7 are silent on the converted probe, and each names the `libm.so.6` a second probe loads from its own `lib/` | a closure check that accepts a library by its glibc name wherever it was found | the functions matching glibc by name only: `ldd_stray says ''` |
| the unconverted probe takes a decoy that is an ELF library (as the Mojo toolchain's `lib/` holds a real `libgcc_s.so.1`): the loader maps it without error, check 4's function still fails, and `ldd_stray` names the library of the probe's own name taken from the decoy directory | a detector that relies on the loader failing; a closure check that accepts its own library by name wherever it was found | `trace_loads` without its search for the decoy path: `trace_loads missed an ELF decoy`; own libraries matched by name only: `ldd_stray says ''` |
| `elf_rpath` exits 2 and leaves the file unchanged on a file with a `DT_RPATH`, one with no run path, a file that is not ELF, and the unconverted probe edited to `e_machine` aarch64, to `e_type` `ET_REL`, to two `PT_DYNAMIC` headers, or with its `DT_DEBUG` entry retagged `DT_RPATH` (both run paths) or `DT_RUNPATH` (two) | an edit of the wrong file | the tool before it checked the machine, the type and the headers: `elf_rpath exited 0 on machine, want 2`; without its `DT_RPATH` or second-`DT_RUNPATH` refusal: `elf_rpath exited 0 on both_paths` / `on two_runpaths` |
| `conda_payload` writes the payload of a stored `pkg-*.tar.zst` with 32-bit sizes (after another member) and with zip64 sizes, and exits 2 with no output on a zip with no payload member or a compressed one | the zip64 failure that made busybox unusable | zip64 sizes ignored: `conda_payload refused zip64.conda` |
| `kcov_check.sh identity`, in its own process, on a file standing for `bin/kcov` (its sha256 written in the script): accepted with that sha256 and a line it holds (a result of 2 checks); refused, naming `KCOV_BIN_SHA256` and the sha256 to write, with a sha256 one digit off; refused with a line it does not hold | an identity check that cannot refuse, so a stale `KCOV_BIN_SHA256` passes | the sha256 comparison skipped: `identity_sha: exited 0, want 1`; the line matched by its first word: `identity_line: exited 0, want 1` |

`:kcov_reproducible` builds the distribution a second time (`:kcov_dist_again`,
another action with its own scratch and output paths, usually on another
worker) and requires the same files, modes and bytes. It went red on a planted
defect that left `kcov_system_lib` unstripped.

`:kcov_identity` requires that `bin/kcov` is what the package guard
refuses: its sha256 is `KCOV_BIN_SHA256` of [`identity.bzl`](identity.bzl)
and it holds `KCOV_USAGE_LINE`. Planted, red: the sha256 changed in one hex
digit (`bin/kcov's sha256 is 57243a23..., but KCOV_BIN_SHA256 ... is
57243a24...`, naming the value to write); the line given as `Usage: kcov
[OPTIONS] <out-dir> ...` (`bin/kcov does not hold KCOV_USAGE_LINE`).

`:kcov_check[report]` holds the fixture's reports as kcov wrote them
(`cov.xml`, `cov_relocated.xml`) and normalized (`cov.normalized.xml`,
`cov_relocated.normalized.xml`).

## Changing kcov or a pin

- **Any change of kcov's bytes** (a pin, `kcov_build.sh`, the zig pin):
  `:kcov_identity` fails naming the new sha256; write it into
  `KCOV_BIN_SHA256` of [`identity.bzl`](identity.bzl). That re-keys only the
  package guard's actions.
- **A new kcov release.** Update the `kcov_src` pin, and `strip_prefix` and
  `version` in [`BUCK`](BUCK). If its usage line changed, `:kcov_identity`
  says so; update `KCOV_USAGE_LINE` and review the near misses of
  `kcov_guard.sh cases`, which are written for the current line. Compare `src/CMakeLists.txt` with the source
  list and the generated sources of `kcov_build.sh`. If the report format
  changed, the red checks 6 and 8 print the difference against the golden; review
  it before updating the golden.
- **A new conda package build.** Update its pin in the table. The build stops
  naming any file the script needs that the package lacks, and check 2 fails
  if the package raises the glibc floor.
- **A new zig.** The goldens of checks 6 and 8 may move with the compiler's line
  table. The `cases` probe shows whether zig now writes a `DT_RPATH` itself.
