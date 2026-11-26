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
- `page.md` is the task's page: its first line is `# ` and the question, then a one-line answer,
  the program in the page's first `python` fence, its output in the first `text` fence, notes, and
  the related tasks by rank.

## What the pull request's check holds

Two kinds of target in `python/docs/tasks/BUCK`, both in the pull request's check:

- `//python/docs/tasks:pages` holds the catalogue to the tree: every entry has the keys above with
  their forms, every `gap` names its issues, every directory is named after an entry that is not a
  `gap` (its slug finds the entry and its rank is the entry's), holds exactly the three files, and
  its page's title is the question and its first `python` and `text` fences are `example.py` and
  `expected_output.txt` byte for byte. It is `tasks-check` of the Zig tool
  `//tools/build/readme_examples:tool`, which reads the page through the shared Markdown module.
- `//python/docs/tasks:<rank>-<slug>`, one per directory, installs the built wheel into an empty
  virtual environment of the hermetic CPython 3.13, with its pinned pyarrow and protobuf and nothing
  else, no network and no library path, runs `example.py` there from a new empty directory, and
  holds what it prints to `expected_output.txt` byte for byte. A difference fails the target with
  the task and the first line that differs, and both texts in the log.
  `//python/docs/tasks:refuses_wrong_expected_output` runs rank 1's example against an expected
  output that differs in one line, and passes only when the run fails with that line;
  `//python/docs/tasks:refuses_example_that_raises` runs an example that raises, and passes only
  when the run fails naming the task and the error.

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
