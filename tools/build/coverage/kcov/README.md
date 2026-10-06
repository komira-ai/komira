# kcov path tools

Two static executables for running a test under kcov in a build action and
getting a coverage report whose bytes depend only on the sources and the
tests. Both are built from one Zig file each with the pinned zig (`zig_exe`,
`tools/build/mojo/toolchain.bzl`), and run with no shell, PATH or network.

| target | what it does |
|---|---|
| `:debug_relocate` | overwrites a directory path in a file (a test binary) with a placeholder of the same length |
| `:cov_normalize` | rewrites one kcov Cobertura report to repository paths, in a canonical form |

## Why: the sandbox path in the debug info

A coverage build keeps the DWARF line tables, which kcov reads. They name the
directory the compile ran in (`DW_AT_comp_dir`, and every source path under
it). Under remote execution that is the action's own absolute sandbox
directory, which differs per action (for example `/worker/build/<hex>/root`);
locally it is a path in the checkout.
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

So a directory of length L becomes `/` and L-1 `_`, and kcov is run with
`--replace-src-path='^/_+:<source root>'` (the expression matches the
placeholder of any length, so no length needs to agree between actions) and
`--configure=cobertura-full-paths=1`. Without the latter kcov writes each file
name relative to the common prefix of that one report, so a report holding
only test files would get bare names, and they could not be mapped back to
the package.

The second `realpath` means the file names in the report are canonical: they
start with `realpath(<source root>)`, not with the string given to kcov. The
caller therefore canonicalizes the source root once (`realpath`) and passes
that same string both to `--replace-src-path` and as the `--map` ABS of
`cov_normalize`. Otherwise a working directory reached through a symbolic
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
the file is written; a directory with no occurrence counts 0. A count of 0
does not prove the file is free of the directory: a compressed debug section
(`SHF_COMPRESSED`) hides it from a byte search. A caller that expects the
directory (the `DW_AT_comp_dir` of a debug build) requires a count above 0.

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

## Tests

Each tool's cases run as a build action (`kcov_tool_cases` in
[defs.bzl](defs.bzl)) that exits non-zero on the first wrong result, and the
public target (`:debug_relocate`, `:cov_normalize`) depends on them. Buck2 runs
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
