# kcov path tools

Static executables for building a test with debug info and running it
under kcov in a build action, with a coverage report whose bytes depend only
on the sources and the tests. Each is built from one Zig file with the pinned
zig (`zig_exe`, `tools/build/mojo/toolchain.bzl`), and runs with no shell,
PATH or network. [`cov_run.sh`](#cov_run), a busybox script, runs one test
under kcov with them.

| target | what it does |
|---|---|
| `:debug_relocate` | overwrites a directory path in a file (a test binary) with a placeholder of the same length |
| `:cov_normalize` | rewrites one kcov Cobertura report to repository paths, in a canonical form |
| `:cov_zig` | the `zig` of a coverage build's link directory: keeps a link's debug info and relocates the action's directories out of it |
| `:cov_link` | that link directory (`cov_link_dir`): `cov_zig`, `debug_relocate` and the Mojo toolchain's zig, what a coverage build of a `mojo_library` links through ([Coverage builds](../../mojo/README.md#coverage-builds)) |
| `:cov_run` | the directory a coverage run runs from (`cov_run_dir`): [`cov_run.sh`](#cov_run), kcov (`komira//tools/build/toolchains/kcov:kcov`), `cov_normalize` and `limit`, the seconds a run may take (450; only a fixture of the tests cell may set another `limit_s`) |

## Why: the sandbox path in the debug info

A coverage build keeps the DWARF line tables, which kcov reads. A compiler
that records the directory the compile ran in (`DW_AT_comp_dir`, and a
source path under it) writes the action's own absolute sandbox directory,
which differs per action under remote execution; locally it is a path in the
checkout. In a Mojo coverage binary only zig's C runtime units do: the
pinned Mojo records no compilation directory and names its sources by
relative paths ([Names in a coverage binary](#names-in-a-coverage-binary)).
Left in, it makes the binary differ from one action to the next (no cache hit,
no reproducible bytes), and it trips the wrapper's check that no output names
the action's directory. So the coverage build rewrites it.

The rewrite has to satisfy two things at once:

- **Same length.** Every offset in an ELF file points at a byte position: the
  string tables, the section headers and the line programs all refer into each
  other. Inserting or removing bytes would move all of that, so the
  replacement has exactly the original's length, and the file's length never
  changes.
- **A path that never exists.** kcov v42 resolves each source path with
  `realpath` *before* it applies `--replace-src-path`, and resolves the
  result again *after* (`filter.cc`, `mangleSourcePath`: `realpath`, then the
  regular expression, then `realpath`; a path that does not resolve is kept
  as written). A placeholder that resolves on the machine kcov runs on
  (`/proc/self/cwd/...` resolves to kcov's working directory) would be changed
  by the first `realpath`, no longer match the expression, and the line would
  be dropped from the report without any error. A placeholder of `/`
  followed by `_` characters names nothing, so `realpath` fails and kcov keeps
  it as written.

So a directory of length L becomes `/` and L-1 `_`. A name under the
placeholder could be mapped with `--replace-src-path='^/_+:<source root>'`
(the expression matches the placeholder of any length, so no length needs to
agree between actions), as kcov's own check 8 does
([kcov](../../toolchains/kcov/README.md)); in a Mojo binary that is only the
C runtime, which is not measured, and the Mojo names are relative (see the
table below), so [cov_run](#cov_run) uses the one replacement kcov allows
for something else. kcov is run with
`--configure=cobertura-full-paths=1`. Without the latter kcov writes each file
name relative to the common prefix of that one report, so a report holding
only test files would get bare names, and they could not be mapped back to
the package.

The second `realpath` means the file names in the report are canonical: they
start with `realpath(<source root>)`, not with the string given to kcov. The
caller therefore canonicalizes the source root once (`realpath`) and passes
that same string to kcov and as the `--map` ABS of `cov_normalize`. Otherwise a working directory reached through a symbolic
link gives file names no map covers, and `cov_normalize` refuses every one.

## debug_relocate

```
debug_relocate <file> <dir>...
```

For each `<dir>` in order, every occurrence of its bytes in `<file>` that is
followed by `/` (a path under it) or NUL (the end of a string, such as
`DW_AT_comp_dir`) is rewritten to `/` and `_` up to the same length.
Occurrences are found left to right and do not overlap; the byte before an
occurrence is not looked at. It prints `<count> <dir>` per directory, before
the file is written; a directory with no occurrence counts 0. A caller that
expects the directory (the `DW_AT_comp_dir` of a debug build) requires a
count above 0.

- An ELF file with a section whose flags hold `SHF_COMPRESSED` is refused
  (exit 1, untouched): a compressed section's bytes are not the strings it
  holds, so a byte search could miss the directory there and a count of 0
  would claim a clean file. So is an ELF file whose section headers cannot be
  read (not little-endian, or past the end of the file), which cannot be
  shown free of one. A file that does not start with the ELF magic is
  searched as bytes.
- Relocating is idempotent: the placeholder never holds the directory it
  replaced, so a second run with the same directory rewrites nothing and
  does not write the file.

- An occurrence followed by any other byte, or by the end of the file, is
  refused (exit 1) with its offset: it is a longer name that only starts with
  `<dir>` (`/root2`), and rewriting part of it would produce a path that names
  something else. The file is then left untouched, whatever else was found.
- `<dir>` must be absolute, without a trailing `/`, and at least 8 bytes long;
  otherwise it is bad usage (exit 2). A short directory would match by chance.
- The file is rewritten through a temporary file in its directory and renamed
  over it, with its permission bits set exactly (not through the umask). If a
  step fails the temporary file is removed. A file with no occurrence is not
  written.
- A symbolic link is refused (exit 1): the rename would replace the link with
  a regular file and leave the file it names as it was. Pass the file itself.
- Exit 1 always means the file is unchanged, including when printing the
  counts fails.

## cov_zig

```
<dir>/zig <zig arguments...>
```

`mojo_wrapper.sh` runs every link of `mojo build` as `<zig_dir>/zig cc
-target <t> -Wl,--strip-debug ...`. A coverage build passes `:cov_link` as
`<zig_dir>`, so the wrapper is the same file for every compile; `cov_zig`
finds its directory from `argv[0]` and runs `real/zig` and `debug_relocate`
from there.

A `cc` or `c++` that links (an `-o` output, and none of `-c`, `-S`, `-E`,
`-M`, `-MM`, `-fsyntax-only`):

- drops every `-Wl,--strip-debug`, so the line tables the compiler wrote
  reach the binary;
- appends `-Wl,--build-id=none -Wl,--compress-debug-sections=none`. Not
  `-Wl,-O1`: zig 0.12 ignores a linker optimization level and warns that it
  did;
- runs `real/zig`, and exits with its status if the link fails (128 + N for
  signal N);
- runs `debug_relocate <output> <dirs>`: the working directory (`getcwd`),
  then `$PWD` when it is another absolute path to it (LLVM records that
  spelling when it names the same directory), then an absolute
  `$BUCK_SCRATCH_PATH` outside the working directory (zig's cache, where it
  builds its C runtime objects, is there). A `$PWD` or `$BUCK_SCRATCH_PATH`
  that is relative, under 8 bytes, or the working directory or under it is
  left out without an error; a working directory under 8 bytes is
  `debug_relocate`'s usage error, so the link fails;
- fails (exit 1) when `debug_relocate` refuses, passing its message on, or
  when the output has a `.debug_info` or `.debug_line` section and the working
  directory, `getcwd` and `$PWD` counted together, was found 0 times. In a
  Mojo binary the only units that record a directory are zig's C runtime's
  (`crt1`, `crti`, `crtn`, as `DW_AT_comp_dir`), so a count of 0 means they
  record one nobody relocated (the binary would differ by machine) or have no
  debug info. An output that is not an ELF64 little-endian file is refused
  too.

A link at a release optimization level (`-O1` to `-O4`, `-Ofast`, `-Os`,
`-Oz`) is refused before `real/zig` runs: zig 0.12 then gives lld `-O2` or
`-O3` (`link/Elf.zig`), which merges string tails in `.debug_str`, and since
`debug_relocate` does not look at the byte before an occurrence, a string
that is the tail of a relocated directory would be rewritten with it. `-O0`
and `-Og` are Debug for zig, and a bare `-O` reaches clang without changing
the mode; Mojo's links pass none of the refused levels.

Anything else (a compile, another subcommand) runs `real/zig` unchanged.
Exit status: `real/zig`'s, 1 for a refused output, 2 when `argv[0]` names no
directory or `real/zig` cannot be run.

The wrapper's check that no output holds the action's working directory
(exit 4) stays on: it runs after `cov_zig`, on the relocated binary, so a
relocation that did not happen fails there; test 41 plants one ([tests README](../../tests/README.md#41-coverage-builds)).

## Names in a coverage binary

What the line tables of a `mojo_library` coverage binary name, and what the
step that runs kcov over it has to map. Read from the binaries of
`komira_retry` and of test 41's `covlib` with `readelf --debug-dump`:

| units | directory | file names | maps to |
|---|---|---|---|
| the test (`producer: Mojo`) | none | `tests` + `test_<x>.mojo` | the package's `tests/` |
| the library | none | `<import>` + the file: the package is compiled from the parent of its staged sources (`[src]`, which ends in `src/<import>`), by that name | the package's `<import>/` |
| the Mojo standard library | none | `oss/modular/mojo/stdlib/std/...` | nothing in the repository: not measured |
| zig's C runtime (`crt1`, `crti`, `crtn`) | the placeholder `/___...` | `buck-out/v2/art/komira/tools/build/coverage/kcov/__cov_link__/<hash>/cov_link/real/lib/libc/...`, where `<hash>` is the configuration of `:cov_link` | nothing in the repository: not measured |

Every Mojo name is relative and no Mojo unit records a directory, so kcov
resolves them against its own working directory: [cov_run](#cov_run) starts
it in a directory where the test's and the library's names resolve to copies
of the sources, and measures only those. The runtime's `<hash>` is the same in
every checkout whose execution platforms are configured the same (a
repository that mounts komira as a cell and copies its platforms); no test
compares a binary across two checkouts.

## cov_normalize

```
cov_normalize --in <report.xml> --out <file> --map <ABS>=<REPO>...
              [--exclude <PREFIX>]... --must-contain <REPO_PATH>... [--forbid <S>]...
```

Reads the report kcov writes with `cobertura-full-paths=1`, where every
`<class filename=...>` is absolute. Each file name is:

1. dropped if it starts with an `--exclude` prefix (generated sources, for
   example), even when a map also covers it; the count is printed;
2. else rewritten by the longest `--map` ABS it starts with, ABS replaced by
   REPO (a directory relative to the repository root, or empty for the root);
3. else refused (exit 1), naming it. An unmapped file is a report the caller
   did not expect; passing it through would give the coverage check a path
   that names nothing.

ABS and the exclude prefixes are absolute and end with `/`, so they match
whole directory names. A mapped path must be a clean relative path (no empty,
`.` or `..` segment, no control byte) in UTF-8 (covcheck decodes a name
lossily, so another byte would name a different file there).

The output is the subset of Cobertura that covcheck (`tools/build/coverage`)
reads, with bytes that depend only on the coverage:

- the XML declaration, `<coverage timestamp="0">` with no rate attributes,
  `<sources><source>.</source></sources>` and one `<package name="">`;
- one `<class>` per repository path, sorted bytewise. Classes mapping to the
  same path (one file reached through two paths) are merged;
- `<line number hits>` sorted by number, a number once. Hits are clamped to 0
  or 1: how often a line ran varies between runs, whether it ran does not. A
  line's `branch="true"` and `condition-coverage="NN% (k/n)"`, or
  `branch="false"`, are kept; when two are merged, `true` wins over `false`
  over none, two `true` with the same n keep the larger k, and different n are
  refused;
- attribute values escaped (`&amp; &lt; &gt; &quot; &apos;`).

It also refuses, writing nothing:

- a `--must-contain` path with no class, or whose class has no line. The
  caller names the test's own source: kcov drops a source it cannot open
  without any error, so a wrong source root otherwise gives a report with no
  files and no failure, and an empty class is no evidence that kcov read it;
- an output containing a `--forbid` string, as given or escaped the way the
  output writes it (`a&b` is `a&amp;b` in the bytes). That no sandbox path
  leaves the action comes first from the mapping: every output path is
  relative and clean, so it cannot be an absolute path. `--forbid` with the
  action's own working directory is the backstop against one inside a path;
- a malformed report, with the same refusals as covcheck's reader (an unknown
  entity, a mismatched tag, a `<line>` number of 0, a branch line without
  `condition-coverage`, and so on). The `<lines>` inside a `<method>` repeat
  the class's and are not read.

The output is written through a temporary file renamed over `--out`, so a
failed write leaves no file, partial or temporary.

Exit status, both tools: 0 done, 1 refused, 2 bad usage.

## cov_run

```
busybox sh <cov_run dir>/cov_run.sh <busybox> <gate_runner> <compiler_dir> <label>
    <test_binary> <share> <src_dir> <xml_out> <marker_out>
    <src_repo> <test> <test_repo> <import> [--solib <file> [--solib-src <path>]...]
    [--gen <file>]... [--env NAME=VALUE]...
```

The action `mojo_cov_run` of a coverage build
([Coverage builds](../../mojo/README.md#coverage-builds)) runs one test's
coverage binary under kcov and writes its report in repository paths. The
same script runs a README's examples (`<test>` is the program's name in its
line tables, `cov/tests/readme/readme_<import>.mojo`, and `<test_repo>`
`buck-out/readme/<package>/readme_<import>.mojo`, which is no repository
file) and, from a library's `<name>_cov_gate`, each `mojo_test` it names in
`coverage_tests` (`<test>` the test's main as its package names it). The
header of [`cov_run.sh`](cov_run.sh) has every argument; in order:

0. **Where the binary names the sources.** The binary must name the
   library's sources by `<import>/`, where the run stages them, or the
   action fails before kcov runs. It fails when a string of the binary
   holds `buck-out/` and, inside an artifact (after buck2's `__<target>__/`
   directory), the path component `src/<import>` (the library's `[src]`:
   the name a package compiled from `[src]` itself would give its sources),
   and when the binary holds the library's code (a string with
   `<import>::`, how a function or type of it is named) but no whole string
   `<import>` or `<import>/...` (the line tables' directory, or a file
   named with it). kcov would drop sources named elsewhere without an
   error, and `lost/` (below) only catches names under the staged path. A
   test that calls none of its library holds neither string and passes:
   there is nothing of the library to measure.
1. **A root of copies.** `bin/kcov` and kcov's `lib/` (its `DT_RPATH`
   `$ORIGIN/../lib` reaches them), `bin/<test>`, and `share/` holding the
   test's declared data, its source at its path in the package
   (`tests/test_x.mojo`, the name its line tables use) and the library's
   staged sources at `<import>/` (the name the line tables use for them;
   a shared library's driver names none of them, so with `--solib` they
   sit at the `[src]` path, out of the way of its sources, which are data).
   Copies, never links: kcov resolves each name with `realpath`. A second copy of
   the same sources, `lost/`, sits beside it. The one exception: each
   generated source (`--gen`) is moved to `gen/`, outside `share/` and
   `lost/`, and linked from both, so `realpath` takes its name out of every
   `--include-path` and it is not measured.
2. **kcov as the gate's program.** `gate_runner.sh`, the release gate's
   runner byte for byte, runs `bin/kcov` (staged where a test binary would
   be, so `share/` is the working directory) with the test binary and kcov's
   flags as its arguments. So the test runs with the gate's PATH,
   LD_LIBRARY_PATH, TMPDIR, TEST_TMPDIR, HOME, `test_env` and data, under
   kcov, and gate_runner reports a failure as for a gated test (what
   differs is below). The flags:
   `--cobertura-only --skip-solibs --configure=cobertura-full-paths=1`;
   `--include-path` of exactly the staged `<import>/` directory and the test
   source, under `share/` and under `lost/`;
   `--replace-src-path='^(?!/):<lost>/'`. No argument grows with the
   library's generated sources (`--include-path` grows only with a shared
   library's `--solib-src` paths, below): kcov v42 reads every argument before the program as a path
   while it looks for the program (`configuration.cc`, through
   `peek_file` in `utils.cc`) and fails `Too long string!` on one of 2048
   bytes or more, and it keeps only the last `--exclude-path` given, so a
   list of generated sources there (two absolute paths each) failed every
   run of a library with about ten of them. An argument that is still too
   long (a deep action directory) fails the run, saying so, before kcov
   starts.
3. **Exactly one report** (`--cobertura-only` writes `<out>/cov.xml`).
4. **`cov_normalize`** maps `<share>/<import>/` to the package's
   directory of those sources (with a repository prefix for a cell that is
   not its repository's root: `tools/build/tests/` for the tests cell) and
   the test's directory to the package's, requires the test's own source in
   the report, and forbids the action's directories in the output. Then the
   marker.

komira's kcov exits with the test's status, 128+N when signal N killed it,
as a shell reports it; kcov v42 as released returns the status of the last
traced process to exit, so a child the test left behind decided it
([Patches](../../toolchains/kcov/README.md#patches)). A test that fails under
kcov fails the action (its output from `gate_runner.sh`, then `COVERAGE RUN
FAILED`), although its release gate passed. gate_runner's banner is left
out: it would say the release gate's test failed. With coverage on, the
conda package (`<name>_conda`) waits for every coverage run; the library
and its dependents do not
([The build gate](../README.md#the-build-gate)).

**A shared library's driver** (`--solib`; a `mojo_shared_lib`'s
`gate_srcs` entry): the test is a driver that loads `<file>`, the library's
coverage build, from `share/`, where the run stages it as data, as the
release gate does. kcov runs without `--skip-solibs`, so it preloads its
library (`libkcov_sowrapper.so`, which reports each shared library the
driver loads) and measures what the driver runs of the loaded library. The
library's line tables name its sources by their paths in the package (as a
test's), so each is given as `--solib-src <path>`, staged at that path in
`share/` and in `lost/`, added to `--include-path`, and mapped with
`share/` itself to the package's repository directory (`<test_repo>`
without `<test>`); the report must hold the first (the library's `main`),
so a run in which kcov did not measure the library fails (`no class for
... (--must-contain)`) rather than reporting none of its lines. What also
differs from a library test's run: the driver's environment holds
`LD_PRELOAD` (kcov's library). An `--include-path` too long for kcov (many
`--solib-src` paths) fails the run before kcov starts, as any too-long
argument does (above). A shared library none of whose sources is a source
file (every one generated) gives no `--solib-src`, so nothing could show
that kcov measured it: the run is refused, saying so (`--solib with no
--solib-src`), rather than passing unchecked; nothing waits for it.

A possible race, not seen: kcov learns of a library the driver loads
through its preload library, which writes the load to kcov's FIFO, and
sets its breakpoints in that library when it reads it. Code of the library
that ran before kcov had patched it would not be recorded, so its lines
would read as not run (fewer hits, never a failed run). covso's driver
calls into the library right after loading it, and nine fresh runs of it,
and the run after each change of `cov_run.sh` since, gave its golden
report byte for byte.

**The run is bounded.** kcov waits for every process the test started
before it writes the report, so a test that leaves a child running would
hold the action open. `gate_runner.sh` runs in a session of its own
(`setsid`), which kcov, the test and its children join, and a watcher kills
that whole process group when the run has not ended after the limit, 450 s
(the file `limit` of the `cov_run_dir`, its `limit_s`): the action fails
with `The test left processes running or did not finish within 450 s under
kcov`, after the output the test wrote. A process of the group still
running (not a zombie) 10 s after that kill fails the action instead with
`processes of the coverage run survived the kill`, naming it. That scan reads /proc, so it first
requires /proc to show the run's shell under its own pid (`/proc/$$/stat` and `/proc/self/stat`
both start with `$$`): a /proc of another PID namespace, or one hiding processes, would list none
of the group, and the action fails instead with `/proc is not readable as this run's own`. The slowest run measured took
119.6 s of worker time; the limit is over three times that and under 600
s, buck2's default timeout of a test action. Only a fixture of the tests
cell may set another `limit_s` (test 43 uses 20 s). kcov refused by the executor (a line of
its own starting `Can't set me as ptraced: `, `Can't set personality: `,
`Can't get personality: ` or `Can't attach to `) is named as such, and
kcov's own error (`kcov: error: `) as kcov's, not the test's.

**What differs from the release gate.** The test is traced (TracerPid is
kcov's) and runs without address randomization (kcov sets
`ADDR_NO_RANDOMIZE`); its working directory `share/` also holds its own
source and the library's sources under `<import>/` (the line tables name
them relative to it); kcov shares its TMPDIR (kcov writes there only when it
cannot make its FIFO); its environment also holds `KCOV_SOLIB_PATH`, which
kcov always sets (with `--skip-solibs` it preloads nothing: no `LD_PRELOAD`),
and nothing of `cov_run.sh`'s own (its tools get `LC_ALL=C` per command
before the test and exported after it, since `gate_runner.sh` passes on what
it does not set);
and the run ends when every process the test started has exited, since
kcov follows each fork, where the gate waits for the test alone (so the run
is bounded, above). Its CPUs are the gate's: kcov v42 pins itself and the test to one
CPU, and komira's build patches that out (test 43's `covenv` checks it).

**Why `lost/`.** kcov drops a source file it cannot open without any error,
so sources staged anywhere but where the line tables name them would leave
the report silently without them; requiring the test's own source does not
catch a lost library file. A name that resolves from `share/` is absolute
after kcov's first `realpath`, and the replacement, which matches only a
relative name, leaves it alone. A name that does not resolve stays relative,
becomes `<lost>/<name>`, which exists, so kcov keeps it, and the report
names it under `lost/`, which no `--map` covers: `cov_normalize` refuses it
as unmapped, naming the file. With `^/_+:<share>` in that one replacement
slot instead, the same mistake gives a green run whose report has no
library file (test 43 shows both). The other names a binary holds, the
standard library's and the C runtime's, are outside `--include-path` and
never reach the report; were one to, it would be unmapped too. `lost/` holds
copies at `<import>/` and the test's path only, so it catches a
mis-staged tree, not a binary naming the sources by another directory: that
is step 0's check (test 43's `lostdir`). A Mojo naming them by an absolute
directory is the hermetic check's (test 41).

## Tests

`cov_run.sh` is tested end to end in the tests cell, as test 43
([tests README](../../tests/README.md#43-coverage-runs),
[the checks](../../tests/coverage_runs.md#test-43-coverage-runs)): per-test
reports equal to golden files, covcheck reading them, the gate's
environment (and CPUs) under kcov, a traced test failing its run, the
test's own exit status (not a child's, 128+N for a signal) without the
gate's banner, a test leaving a child running stopped at the limit, lost
sources refused, sources named by another directory refused before kcov
runs, and kcov refused by the executor named as such.

Each tool's cases run as a build action (`kcov_tool_cases` in
[defs.bzl](defs.bzl)) that exits non-zero on the first wrong result, and the
public target (`:debug_relocate`, `:cov_normalize`, `:cov_zig`) depends on
them; `:cov_link` takes the public targets, so a coverage build is gated by
their cases. The cases of `cov_zig` also take `:debug_relocate` and the pinned zig
(`helpers`). Buck2 runs
a dependency's validations with any build that uses it, so the tool cannot be
built, or used, unless its cases pass. The public target and the cases both
take the executable as an `exec_dep` on the same execution platform, so the
cases test the very binary the public target hands out.

The cases that need a write to fail set a file size limit (`ulimit -f`, with
`SIGXFSZ` ignored, which the tool inherits), so the write fails with `EFBIG`
part way; a probe first checks that the shell can do this.

`debug_relocate_cases.sh`:

| case | proves | a defect it catches |
|---|---|---|
| followed by NUL | the string is rewritten, same length, `1 <dir>` printed | a placeholder one byte short |
| followed by `/` | a path under the directory is rewritten | |
| followed by `x` | exit 1 naming offset 39, and the file byte for byte unchanged although an earlier occurrence was rewritable | no check on the following byte |
| at the end of the file | refused the same way | |
| two directories, several occurrences | each counted and rewritten; permission bits 757 kept (other-write, which umask 022 clears) | stopping after the first occurrence; no `chmod` after the temporary file |
| 7-byte, relative, trailing-`/` directory, none | exit 2 with usage, file unchanged | no length floor |
| 8-byte directory | accepted and rewritten | a floor of 9 (`<=` for `<`) |
| no occurrence | `0 <dir>`, exit 0, unchanged | |
| second directory refused | exit 1 naming the second directory's offset, nothing printed, file unchanged although the first had been rewritten in memory | writing after each directory |
| symbolic link | exit 1, the link still a link, its target unchanged | the link replaced by a regular file |
| failed write | exit 1, file unchanged, no temporary file left | exiting without removing the temporary file |
| failed stdout | exit 1 and the file unchanged | printing the counts after the rename |
| compressed section | an ELF64 file whose second section has `SHF_COMPRESSED` (0x800) is refused, exit 1 naming the section, nothing printed, untouched, although its directory is rewritable | no check (red-first: it failed before the check existed); a mask other than 0x800 |
| uncompressed ELF | the same file with flags 0x2 is relocated as any file | refusing every ELF file |
| idempotent | the relocated file again: `0 <dir>`, exit 0, same bytes, same inode | a placeholder that holds the directory; writing a file with no occurrence |
| section headers past the end | refused, exit 1, untouched | reading section headers without a bounds check (ReleaseSafe panics, exit 134) |
| compressed section, `e_shnum` 0 | an ELF64 file whose `e_shnum` is 0 and whose section 0 `sh_size` holds the count (3): the compressed section is found and refused; with flags 0x2 it is relocated | the count in section 0 not read (planted: red) |
| compressed section, ELF32 | an ELF32 file (40-byte section headers, 32-bit flags) with a compressed section: refused, untouched; with flags 0x2 it is relocated | ELF32 files not looked at (planted: red) |
| compressed section, ELF32, `e_shnum` 0 | an ELF32 file whose `e_shnum` is 0 and whose section 0 holds the count (3) in its 32-bit `sh_size` (offset 0x14 of its header): the compressed section is found and refused; with flags 0x2 it is relocated | the ELF32 count in section 0 not read (planted: red) |

`cov_zig_cases.sh` runs `cov_zig` from a directory whose `real/zig` is a
stand-in (a script that records its arguments and copies a given ELF file to
the `-o` output) and, in the last two cases, the pinned zig itself. The
fixtures put the working directory where a C runtime unit's
`DW_AT_comp_dir` would be:

| case | proves | a defect it catches |
|---|---|---|
| link | `-Wl,--strip-debug` dropped, the two flags appended after the compiler's arguments, the rest in order; the working directory in the output rewritten to its placeholder | strip kept; a flag missing; no relocation |
| joined `-o` | `-oout` is a link output too | |
| compile | `-c`: the arguments unchanged, the output not relocated | a compile taken for a link |
| other subcommand | passes through unchanged | |
| failed link | real/zig's exit status (7), nothing relocated | the status dropped |
| debug info elsewhere | a `.debug_line` section without the working directory: exit 1 | no zero-count check; debug sections not seen |
| no debug section | no section and no directory: exit 0 | |
| relocation refused | the directory followed by `x`: exit 1, debug_relocate's message passed on | debug_relocate's status ignored |
| compressed section | exit 1 naming `SHF_COMPRESSED` | |
| not ELF | exit 1 | |
| logical directory | reached through a symbolic link: `$PWD` and an absolute `$BUCK_SCRATCH_PATH` outside it are relocated too | `$PWD` ignored |
| logical only | the output names only `$PWD`, not `getcwd`: relocated, exit 0 | a zero count of `getcwd` alone failing the link (red-first: it did) |
| scratch only | the output names only an absolute `$BUCK_SCRATCH_PATH` outside the working directory, given: it is relocated, and the link fails with `has debug sections but holds the working directory`, exit 1 | the zero count summing every directory given, not only the working directory's spellings (planted: red) |
| release level | `-O1` to `-O4`, `-Ofast`, `-Os`, `-Oz` on a link: exit 1 naming the level, `real/zig` not run; `-O0`, `-Og`, `-O` and a `-c -O2` compile pass | no refusal (red-first); refusing a Debug level (red-first: `-Og` was refused) |
| pinned zig | a C file compiled with `-g` and linked through `cov_zig` with `-Wl,--strip-debug`: `.debug_line` kept, the placeholder present, the directory absent, no compressed section | the flags rejected by zig 0.12 |
| pinned zig, release | the same link through zig directly has no `.debug_line`, so the previous case's line tables are `cov_zig`'s doing | |

`cov_normalize_cases.sh` runs `fixtures/kcov_full_paths.xml` (a made-up kcov
report with absolute paths, in both the sandbox and the placeholder form):

| case | proves | a defect it catches |
|---|---|---|
| golden | the output equals `fixtures/kcov_full_paths.golden.xml` byte for byte: longest prefix wins although a shorter map is given first, merging, sorting, clamping, method lines skipped, exclusion, entities, `--forbid` of the sandbox path not tripping on a clean output (the forbid case shows it can trip) | first-match mapping, last-wins merging, unsorted lines, no escaping, no exclusion, method lines read |
| rerun | other hit counts, timestamp, rates and `<source>` give the same bytes | |
| no exclusion | without `--exclude` the generated file is kept, so the golden case's drop is the exclusion's | |
| exclusion over a longer map | an exclusion drops a file a longer map covers | longest of map or exclusion wins |
| branch merge | `true` beats `false` in either order, `false` beats none | the first branch kept |
| branch count mismatch | two `true` lines with different n: exit 1 | the first n kept |
| unmapped | exit 1 naming the file, nothing written | unmapped names passed through |
| must-contain | a missing test source: exit 1, nothing written | no `--must-contain` check |
| must-contain, no line | a test source whose class has no line: exit 1 | an empty class taken as read |
| forbid | a forbidden string, given as the path holds it (`a&b`) and as the bytes hold it (`a&amp;b`): exit 1 | no `--forbid` check; only the escaped form looked for |
| `..` mapping | an unclean mapped path: exit 1 | |
| not UTF-8 | a mapped path with byte 0xff: exit 1 | a name covcheck would decode into another |
| malformed | unknown entity, line 0, mismatched tag, branch without condition: exit 1 naming the line | |
| usage | no `--must-contain`, a map without `=` or without a trailing `/`, an unknown flag, a map ABS, `--in` or `--out` given twice: exit 2 | |
| failed write | exit 1 and the output's directory empty | a partial `--out` left behind |
