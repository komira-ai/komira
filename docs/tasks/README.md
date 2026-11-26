# Common tasks

The data-analysis tasks people do most often, ranked, with what komira can do for each today and,
where it can, a complete example that runs in the pull request's check.

## The catalogue

[catalogue.json](catalogue.json) lists the top 100, one entry per task, in rank order. It names no
language: each language's examples join it by slug. An entry has exactly these keys:

| Key | What it is |
|---|---|
| `rank` | 1 for the most common task; the entry at index i has rank i + 1 |
| `slug` | the task's name, lowercase letters, digits and single hyphens; unique, and the one key every language's examples use |
| `category` | Read, Transform, Aggregate, Clean, Join, Write, Time, Strings, Databases, Cloud storage, Nested/JSON, Reporting/export or Performance |
| `question` | "How do I ...?" |
| `status` | `works` (komira does the task), `partial` (komira does part of it, or one form of it, and the page says which) or `gap` (komira cannot do it yet) |
| `issues` | the komira issues that block the task, as `komira-ai/<repo>#<n>`; required for a `gap`, allowed for a `partial` |

The ranking, and the evidence of how often each task is asked, come from public sources: call counts
of pandas functions in Kaggle notebooks, the canonical Stack Overflow questions, and the guides of
DuckDB and Polars. Ranks past about 50 are less certain than those before.

## The examples, one tree per language

Each language keeps its examples under its own package, in one directory per task named
`<rank>-<slug>` after its catalogue entry. A `gap` task has no directory: it is listed, not shown.

| Language | Directories | What each holds |
|---|---|---|
| Python | [python/docs/tasks/](../../python/docs/tasks/) | `example.py`, `expected_output.txt`, `page.md` |

A TypeScript tree (under `node/`) or a Mojo tree (under `src/`) joins the same tasks by slug, with no
change to the catalogue or to another language's tree.

In the Python tree:

- `example.py` is a complete program. It makes its own small input files in the directory it runs
  in, and uses no network.
- `expected_output.txt` is exactly what `example.py` prints.
- `probe_<name>.py` with `probe_<name>.error.txt` (optional, for a `gap` or `partial` task only) is
  a probe: a program written the way the task would be done if komira could, and the one line it
  fails with today, `<Type>: <message>`. A probe must fail with exactly that line. The day it runs
  to the end, its target goes red, and the page, the catalogue status and the probe change together.
  A page need not show a probe.
- `page.md` is the task's page: its first line is `# ` and the question, then a one-line answer,
  the program, its output, notes, and the related tasks by rank.

A page shows a file through an include marker, on the line directly before a fence, both at the
start of their lines:

````markdown
<!-- include example.py -->
```python
...example.py, byte for byte...
```
````

The fence's word is fixed by the file's extension (`.py` is `python`, `.txt` is `text`), and the
marker names a file of the task directory by its file name. Every page includes `example.py` and
`expected_output.txt`. A fence that shows no file says why on the line before it, as
`<!-- not-tested: <reason> -->`, and the page should say so in its prose too. A `python` fence
needs an include or that marker, and so does a `text` fence that directly follows code or an
include with only blank lines between, so a page never shows output that no run printed. The
marker words are spelled once, in `MARKERS` of `tools/build/readme_examples/task_page.zig`.

## What the pull request's check holds

These targets in `python/docs/tasks/BUCK` are all in the pull request's check:

- `//python/docs/tasks:pages` holds the catalogue to the tree:
  - every entry has the keys above with their forms, and every `gap` names its issues;
  - every directory is named after an entry that is not a `gap`: its slug finds the entry and its
    rank is the entry's;
  - every directory holds the three files and nothing but probe pairs, and a probe's error file is
    one line;
  - every page follows the marker rules above, each include equal to its file byte for byte.

  It is `tasks-check` of the Zig tool `//tools/build/readme_examples:tool`, which reads the page
  through the shared Markdown module. A stale include is named as `page.md:<line>`, with the first
  line of the file that differs.
- `//python/docs/tasks:<rank>-<slug>`, one per directory, runs `example.py`:
  - it installs the built wheel into an empty virtual environment of the hermetic CPython 3.13,
    with its pinned pyarrow and protobuf and nothing else, no network and no library path;
  - it runs `example.py` there from a new empty directory;
  - it holds what the program prints to `expected_output.txt` byte for byte. A difference is named
    as `expected_output.txt:<line>`, and an exception as `example.py:<line>`, with both texts or the
    traceback in the log.
- `//python/docs/tasks:<rank>-<slug>__probe_<name>`, one per probe, runs the probe the same way. It
  is red when the probe runs to the end, or raises another line than its `.error.txt`.
- Four targets prove that these runs can fail. Each passes only when its run fails with the exact
  line:
  - `refuses_wrong_expected_output`: rank 1's example against an expected output that differs in
    one line;
  - `refuses_example_that_raises`: an example that raises;
  - `refuses_probe_that_runs`: a probe that runs to the end;
  - `refuses_probe_with_another_error`: a probe that raises another line.

**Platforms.** The pull request's check runs every example on linux-x86_64. macOS arm64 is not in
the pull request's check: a pull request builds no macOS wheel and runs no macOS test (rule B9; the
one exception, the macOS part of the check, builds the libraries of the macOS set only). Every
example runs on the macOS arm64 wheel after merge, as `//python/docs/tasks:examples_macos_arm64`,
in the step `build the macOS Python harness tests` of `release-macos.yml` on the farm's Macs, which
reports and does not block.

## Writing an example whose output is stable

The comparison is byte for byte, and there is no word to skip or normalize a line. So an example
prints only what is the same on every run and every machine:

- no times, durations, dates of today, process ids, random values or sizes in memory;
- no paths, host names or addresses: name a file by the name the example gave it, never by where it
  ended up;
- nothing whose order is not promised: sort a query's rows with `ORDER BY` or `sort_values` before
  printing them, and print a set or a dictionary built from data in sorted order;
- floats with a fixed number of digits (`f"{x:.2f}"`, or `round` in the query) unless the value is
  exact in binary, as 0.5 and 7.0 are;
- no versions: not komira's, not pyarrow's, not Python's.
