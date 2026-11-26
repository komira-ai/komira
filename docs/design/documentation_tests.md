# Testing the code in our documents

Status: design, not built. How every code block in our documentation is run or accounted for; today
only Mojo README examples run ([README gate](../../tools/build/mojo/README.md#readme-examples)),
plus the Python quickstart pair. Counts are from main of this repository; *(not checked here)* marks
one from our other repositories.

## The answer

1. **A generic core, at five small pieces and nowhere else:** the block reader, the example
   directory, the runner contract, the exact output compare, and the include and freshness check.
   Everything else (tabs, status words, the site, install managers, the Mojo wrapper) stays with its
   owner.
2. **No third-party runner as the base.** None runs a Mojo block as a welded Buck2 action, and
   those that check "the page equals the file" are tied to their own site stack. We use
   [lychee](https://github.com/lycheeverse/lychee) for outside links (scheduled, not in the gate),
   the `llms.txt` page shape, and each language's own interpreter.
3. **What is new for us is the task page:** a real source file, its recorded output, one section per
   language, and a status the test run writes.
4. **Two tiers.** The first tier is what the komira.dev examples gate needs and can be accepted on
   its own. The second tier is bookkeeping that can follow, or not.

| Tier | Pieces |
|---|---|
| First | the block reader; the example directory with probes; the runner; the exact compare; include freshness. Languages: inline Mojo (exists) and Python (inline and source-first) |
| Second | the ledger of unchecked blocks and its tree guard; `record` and `fill` as patches; reruns against the published packages; the site step (claim guard, banner, plain `.md` copy, `llms.txt`) |
| Held | install cases (`sh`), tutorial steps, TypeScript: each needs a contract this doc does not write (below) |

Without the second tier, a failing compare prints the whole actual stdout after the filters, and the
author pastes it into `expected_output.txt` and reads the diff; a stale page is fixed by hand at the
line `check` names. Unrun blocks are not listed one by one; the reader prints their count.

## What exists today

Fences are counted by opening fence lines at any indentation; another fence rule moves a count by a
few percent.

| Fact (origin/main) | Count |
|---|---|
| Whole repository: Markdown files / fenced blocks | 488 / about 1,000 |
| `src/<pkg>/README.md`: files / fenced blocks / `text` fences | 264 / about 700 / 29 |
| `mojo` fences in `src/*/README.md`, all run by the README gate | 656, in 220 of 264 READMEs |
| READMEs that run nothing: `readme = False` rows in `src/**/BUCK`; READMEs nested below `src/<pkg>/` | 3; 11 |
| Whole repository: `python` fences; of them run or compared | about 45; the quickstart blocks of [python/README.md](../../python/README.md) and [docs/install.md](../install.md) only |
| Whole repository: `sh` fences (none run as written) | about 100 |
| Markdown files under `docs/design`; their `mojo` and `python` fences; fences in `node/README.md` | 61; 4 and 22; 0 |
| Zig in the reader and README tool (`wc -l` of `tools/build/markdown/markdown.zig` and the non-test `tools/build/readme_examples/*.zig`) | about 1,500 lines |
| Fenced blocks across all our repositories, and the share no check reads *(not checked here)* | about 2,700; about 73% |

Separate mechanisms exist. **Run the block:**
[tools/build/readme_examples](../../tools/build/readme_examples/BUCK) (Zig) cuts each `mojo` fence
into a program, run as a welded test (`[tests][readme]`), and `release/readme_e2e` runs them again
against the staged `.conda` of its 66 packages
([scenarios](../../tools/build/readme_e2e/README.md)). **The page equals a file:** the Python
quickstart (`python/smoke/src/readme.zig`, `python/examples/quickstart.{py,expected}`) and mopm's
`docs/examples.md`. **Doc facts equal source facts** and **blocks parse with the real loader:** in
our Rust repositories *(these two and mopm: not checked here)*.

What it lacks: only Mojo runs, and its path compares no printed output (a block passes when `main`
returns); Python runs only as the quickstart pair. The README gate does not map failures back:
`program.mapReport` turns `readme_<pkg>_<line>.mojo:<n>` into `README.md:<n>`, but only
`tools/build/readme_e2e/verify.zig` calls it, not `tools/build/mojo/readme.bzl`. `doc_links` still
reads through a second, Mojo reader (`tools/build/inspect/BUCK`). Unrun blocks are silent. Case 38
of [tools/build/tests/README.md](../../tools/build/tests/README.md), the gate's end-to-end case, is
stale. mopm.dev draws `<!-- mojo-hidden ... -->` as text *(not checked here)*. Docs on main run
ahead of the published wheel with no marker (komira-ai/komira#2306). A non-ASCII character crashed
the old Mojo generator (komira-ai/komira#855); whether the Zig path still fails is not checked.

## What we take from whom

Only the rows we act on; each claim was checked against the project's own docs or source.

| Project | What we take |
|---|---|
| rustdoc doctests, mdBook test | The model for Rust (our Rust fences in Markdown run nowhere today and are ledger rows). Hidden setup lines; an expected failure is a class of case |
| Go testable examples | Ordered check levels: compile, run, compare output |
| Documenter.jl | A docs build fails on a failing example; a mode that rewrites the expected output; filters as data |
| Zig `doctest`, Sphinx-Gallery | An expected failure that turns red when it starts to pass: our probe |
| Sybil | Find, run and judge are separate steps; finding zero blocks is a failure |
| Dart excerpter, kotlinx-knit, Azure SDK snippets, Qdrant | A check mode that fails when regenerating the page would change it; a skip never removes that check |
| trycmd / snapbox, pytest-examples | Accepting new output is a patch a person reviews |
| AWS code examples | A directory per task, a folder per language |
| Instruqt, freeCodeCamp | A step check must fail on the start state before it may pass on the solution |
| LLVM lit | Named result classes; its automatic retry is what we refuse |
| polars, LanceDB, Bluehawk; Elasticsearch | The warning: the link between page and test must be enforced, not a convention, and a harness tied to one markup dies with it |
| lychee; llms.txt | Used as they are |

Not taken: scrut, cram, prysk and byexample (licences, or a silent whole-file skip); the pytest
plugins (pytest in a Buck2 action, and their own reader); Doc Detective, Innovation Engine, Quarto,
Jupyter Book and Modo. A page shows the whole tested file, never mdBook's tested-file excerpt.

## Two models, by document kind

- **Inline: the page is the source.** The fence is the program and asserts in its own code; no
  output is compared. For package READMEs and SDK reference pages: short, "this call works".
- **Source-first: a real file is the source.** The page includes the file and its recorded output.
  For task pages, install pages, tutorial steps and CLI docs: whole scripts with printed output.

| Kind | Model | "Tested" means |
|---|---|---|
| Mojo package README | inline (exists) | each block compiles and runs on the farm on both platforms, and again against the installed `.conda` |
| Python SDK reference pages (`python/docs/`, 23 files) | inline | each block is one program, run against the built wheel, sharing no state with other blocks; a refused call is shown with `try`/`except` and an assert |
| komira.dev task pages | source-first | the file runs in an empty directory; stdout equals `expected_output.txt`; the page shows those two files; a section exists only if its case passed |
| Install and getting started (held) | source-first, one case per manager | the command file the page shows runs as written, then the verify line, then the first script |
| Tutorial lessons, CLI docs (mopm; held) | source-first | a `seed` case must fail the step check and a `solution` case must pass; the CLI prints its expected file |
| Runbooks, config, facts pages; design docs | per repository; links | only the reader is shared; design-doc links resolve and their fences are ledger rows |

## The pieces

### 1. Block reader

Exists: `tools/build/markdown/markdown.zig` (38 tests in `markdown_test.zig`) reads fences, HTML
comments and links with no I/O, and `tools/build/readme_examples/examples.zig` reports every refusal
of a README at once and refuses near misses of `mojo` (`Mojo`, `mojo,`). New: `blocks --json` (the
same data for programs that are not Zig), near-miss refusals for every known word (`py`,
`typescript`), and the fence-word table below. A front end turns one fence into program text plus a
line map (Mojo: today's `def main() raises:` wrapper; inline Python: the body as is); the runner
never sees Markdown. `doc_links` moves onto this reader, so one reader remains.

**Fence words** are one data file in the core, keyed by (docset kind, word). A docset is the set
of pages one Buck2 macro registers, and the macro names its kind: `readme`, `sdk`, `tasks`. Each
pair has a treatment: `run` (`mojo` in `readme`, `python` in `sdk`), `include` (`python` in
`tasks`), `checked` (a repository test parses it), `ledger` (every other known word: `ts`, `sql`,
`rust`, `toml`, `proto`, ...; only counted until the ledger exists), or `ignored` (`mermaid`, and
fences with no word, whose count is printed per docset). A `text` fence after code is an output
fence (piece 5).

### 2. Example directory, with probes

Source-first cases are found by file name, never by reading a file: Starlark can `glob` in analysis
but cannot read a file, so one test target per case comes from the `glob`. (Inline blocks are in a
page's bytes, so an inline page stays one target whose dynamic action runs one program per block,
labelled `<target>:README.md:<line>`, as the README gate does today.) Each language's cases live in
its own tree, which mirrors the page tree: task page `docs/tasks/<rank>-<slug>/page.md` has its
Python case in `python/docs/tasks/<rank>-<slug>/`, because no `.py` file may live outside `python/`
(`//:python_closure`, `PYTHON_SURFACE` in
[tests/python_closure_allowlist.bzl](../../tests/python_closure_allowlist.bzl)). A task's languages
join by slug.

| Extension | Folder word | Case directory for `docs/<path>/page.md` | Runner |
|---|---|---|---|
| `.py` | `python` | `python/docs/<path>/` | Python |
| `.mojo` | `mojo` | `docs/<path>/mojo/` | Mojo, with a build phase |
| `.ts` | `typescript` | `node/docs/<path>/` | none: refused until its environment is written down (Node version, module kind, where the addon sits) |
| `.sh` | `sh` | none: refused (held) | none |

Held, each until its own contract is written: **install cases** need an ordered `steps` field
(command file, verify line, first script in one directory, with the step whose stdout is compared),
a loopback package index per manager, a page path for `docs/install.md`, and a ruling that a shown
`.sh` command file is page content and not a new script under rules B4 and T11. **Tutorial steps**
(mopm) need `seed` and `solution` roles and a step check.

- A case is `example.<ext>` with `expected_output.txt`, or a probe `probe_<name>.<ext>` (it must
  fail) with `probe_<name>.error.txt` (one line, the failure text). Its id is `<folder
  word>/<stem>`, for example `python/probe_native`.
- The example writes its own sample data into its working directory: nothing a page cannot show.
- `example.toml` is optional, one per case directory, a list of `[[case]]` tables: `name` (a case
  id), `why`, and `expect = "none"` (judged by exit 0 alone). It never changes which cases exist. A
  probe needs a `why`.
- `lint` refuses: a duplicate id; a file with no role; a `name` that matches no case; a probe with
  no `why`; a case directory with no page at its mirrored path (a rank changed on one side only is
  named by its slug); a passing case no page shows; an empty expected file without `expect`.

A probe is how a page that says "komira cannot do this yet" stays true: it runs the call we want and
must fail with its recorded text. When the feature lands, the probe passes, the case goes red with
"expected to fail; the feature exists now", and the author must change the page.

### 3. Runner contract

One Zig binary for every language; a language adds only its environment.

| | |
|---|---|
| In | the case directory (read-only), the case, an environment artifact, limits: `prepare` (Mojo only) then `run`, each with a time limit, and a stdout size cap |
| Environment | a directory holding `env.json` (`vars`, the `argv` that starts a case, an optional `prepare` argv for a build phase) and a tree. It is an attribute of the macro: Python is a pinned interpreter plus hash-pinned wheels (the wheel under test and every library a page imports); Mojo is the `.mojoc` closure of one package's `deps` |
| Working directory | fresh, empty and writable; the case file sits read-only at `./.case/<folder>/<file>`, so tracebacks are the same on every run |
| Out | `result.json`: `exit`, `stdout`, `stderr`, a one-line `summary`, a class, and a fingerprint (package, interpreter and library versions, platform). `summary` is a cut, not a judgement: for Python the last non-empty line of stderr; for source-first Mojo the first `error:` line |
| Classes | `ran`, `hang`, `output-too-big`, `signal`, `oom`, `refused` (the case could not start, or stdout is not UTF-8). A hang is a class, never an exit code: exit 124 already means "the compile watchdog killed the compiler" in our rules |
| Child environment | `TZ=UTC`, `PYTHONHASHSEED=0`, `PYTHONUTF8=1`, `COLUMNS=80`, `NO_COLOR=1`, a UTF-8 locale. These set the child process; they are not our configuration (rule S2) |

The runner decides nothing; the compare is the only judge. No network except loopback: on Linux
the action runs with the network off; on macOS nothing confines the child, so the "no socket" and
"no write outside" fixtures run on Linux only and say so.

### 4. Exact output compare

Pass, or a diff naming `expected_output.txt:<line>` and the first differing line, followed by the
whole actual stdout after the filters. Exact after the filters; `\n` line ends; one final newline
ignored; nothing else implicit. A main case that exits non-zero is red whatever it printed; its
stderr is never compared. A probe passes only with class `ran`, a non-zero exit, and a `summary`
(filtered like stdout) equal to its `.error.txt` line; its stdout is ignored, and a hang or a signal
is red, not an expected failure.

Filters are a closed list of three, always on, applied to the actual output only: `cwd` (the working
directory, also in its symlink-resolved and JSON-escaped forms, becomes `<cwd>`), `version` and
`abi` (`<version>`, `<abi_version>`). Their one user is the Python quickstart:
`python/smoke/src/readme.zig` puts the version and ABI version in today, and puts the directory into
the expected side for `<cwd>`; the core moves all three to the actual side. No `...` line, no regex.
Authors print floats at fixed precision, put `ORDER BY` on every query, and print no times or
addresses. A case runs on one pinned Python (error text differs across 3.11 to 3.14) on each of the
package's platforms (linux-x86_64, darwin-arm64) against one expected file; a case that prints
differently on the two is changed. One test target per case, keyed by its files, runner, environment
and package, so a cached pass is real.

### 5. Include and freshness

The marker is `<!-- include <case path> -->` at column 0 on the line directly before a fence at
column 0, with no blank line between. Its first segment is the folder word, resolved through the
table of piece 2: `<!-- include python/example.py -->` on `docs/tasks/22-x/page.md` names
`python/docs/tasks/22-x/example.py`. No `..`, no absolute path. The fence word is the extension's;
the body is the file less one final newline; a file with `\r`, a BOM or a trailing space is refused.

- `check` fails when filling would change one byte, when a file is missing, or when a page of a
  `tasks` docset has a fence of a language word with no marker. Inline docsets (`readme`, `sdk`)
  carry no markers; their fences are the programs.
- On a `tasks` page, a `text` fence after a code fence or an include (blank lines only between) must
  be an include or have `<!-- not-tested: <why> -->` on the line directly before it; the page shows
  "not tested". A page cannot show output no run made. On inline pages the same rule waits for the
  ledger, so the 29 `text` fences of `src/*/README.md` become rows rather than refusals.
- Hidden lines exist for the inline model only, as `<lang>-hidden` where `<lang>` is the fence word;
  today that is `mojo-hidden`, unchanged. Source-first pages have none: a reader can copy the page
  and it runs.
- A page that ships inside a wheel or a `.conda` carries no markers: in `python/BUCK` the wheel's
  description is `README.md` followed by the assembled changelog (`:changelog[description]`), so a
  marker would enter the package metadata. The quickstart pairs stay a pair list (page, fence index,
  file), checked as today.

## Second tier

- **Ledger of unchecked blocks.** `ledger.tsv` per docset: doc, language, sha256 of the block body,
  reason. A known-language fence that is neither run nor checked needs a row. The key is the
  content hash, so moving a block keeps its row and editing it makes the row stale, which fails the
  build. A `max = N` line fails the build when rows exceed it; the pull request check reports a
  `max` that rose against the base. A **tree guard**, like `//:readme_e2e_complete`, lists every
  Markdown file with a known-language fence; each belongs to a docset or to a file-level ledger row.
- **`record` and `fill`.** `[record]` on a case runs it three times on each platform and refuses any
  difference, a failed run, a trailing space or `\r`; its output is a patch touching only expected
  files. `[fill]` gives a patch for page fences. A person applies each with `git apply` and reads
  the diff. A second `record` gives an empty patch.
- **Published reruns.** The same cases against the package on its registry after publish (not
  welded; it needs the network). A pass on the build and a fail on the published package shows
  "needs the next release" on the page, and the banner clears itself on release.
- **Site step.** The site build depends on every case and page target and reads the run results as
  Buck2 inputs, so it cannot publish a stale record. It checks the page's `claim` (`gap` needs the
  main case passed and a probe failing as expected), and emits the HTML, a plain `.md` copy and
  `llms.txt` from the same bytes. Deploying stays a separate step someone runs.

## Worked examples

**A. A Mojo README with hidden setup (inline, unchanged).** From `src/anomaly/README.md`, hidden
marker on line 22, fence on line 23 (the block's second half, an unordered series, is cut here):

````markdown
<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from anomaly import SERIES_OK, SERIES_REJECT_UNORDERED, Series, series_reject_reason_name

var good = Series("latency/p50")
good.append(Int64(1), 10.0)
good.append(Int64(2), 11.0)
assert_equal(good.validate(), SERIES_OK)
```
````

One case per fence, labelled `<target>:README.md:23`. The program keeps README line numbers, so the
gate's rule calls `map` and an error reads `src/anomaly/README.md:<n>`. The asserts are the check.
New refusal: a `python-hidden` marker above a `mojo` fence (a hand-typed `text` fence after it
becomes a refusal only with the ledger). The 656 examples need no edit.

**B. A task page, "read a JSON file and write the records to a database" (source-first, Python).**
komira reads JSON Lines and has no database write, so the page shows komira reading and filtering
and Python's `sqlite3` writing (hand-worked, not run). The page is
`docs/tasks/22-read-json-write-database/page.md`; `python/docs/tasks/22-read-json-write-database/`
holds `example.py`, `expected_output.txt`, `probe_native.py`, `probe_native.error.txt` and
`example.toml`.

````markdown
---
title: How do I read a JSON file and write the records to a database?
claim: gap
---

<!-- include python/example.py -->
```python
import sqlite3
from pathlib import Path
import komira
Path("events.jsonl").write_text('{"id": 1, "name": "Ana", "score": 9}\n'
                                '{"id": 2, "name": "Bo", "score": 3}\n')
with komira.Session() as s:
    s.register_json("events", "events.jsonl")
    rows = s.sql("SELECT * FROM events WHERE score >= 5 ORDER BY id").to_arrow().to_pylist()
db = sqlite3.connect("app.db")
db.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)")
db.executemany("INSERT INTO events VALUES (:id, :name, :score)", rows)
print(db.execute("SELECT * FROM events ORDER BY id").fetchall())
```

<!-- include python/expected_output.txt -->
```text
[(1, 'Ana', 9)]
```
````

`probe_native.py` writes the rows with one komira `INSERT`, and must fail; `example.toml` gives its
`why`. If `example.py` changes and the page does not, `check` names the stale page line; if the
output changes, the compare names `expected_output.txt:1`; when `INSERT` lands, the probe goes red
and the `gap` page must change. A TypeScript section is two files under
`node/docs/tasks/22-read-json-write-database/`, refused today because no TypeScript runner exists.

## What each check proves

Every row has a negative fixture: a small tree with one defect, run as part of the tool's welded
`doc_negative` target, which must go red and name the line. These replace the stale case 38.

| Check | Tier | Defect it catches | Negative case |
|---|---|---|---|
| Reader refusals | 1 | `Mojo`, `py`, an unclosed fence, a hidden marker touching no block or the wrong fence | one fixture per rule, asserting the exact text |
| Count guard | 1 | a reader that finds nothing and passes | a page whose only fence is `ptyhon` fails |
| Case run and line map | 1 | API drift, a removed symbol; a failure naming a generated file | a wrong call fails and names `doc:line` |
| Hermetic run | 1 | an example that works only on the author's disk or network | a read outside the directory fails (both platforms); a socket or an outside write fails (Linux) |
| Classes | 1 | a hang or crash counted as a pass | an endless loop is `hang`; a self-kill is `signal`; non-UTF-8 stdout is `refused` |
| Exact compare and filters | 1 | a changed number, column, error text or row order; a filter hiding a real change | one byte differs; `...` as a line is compared literally; a changed value beside a placeholder is red |
| Include freshness, unproduced output | 1 | a hand-edited fence; hand-typed output | one changed byte; a deleted file; typed output after a fence |
| Probe | 1 | a `gap` page after the feature landed | the probe passing is red |
| Canary | 1 | a runner that stops judging | one case per environment that must fail with a named text |
| Ledger and tree guard | 2 | a skip that grows unseen; an unregistered doc | a stale, duplicate or missing row; `max` raised; an unregistered file with a `python` fence |
| Record and accept | 2 | output with times or paths; a patch that rewrites code | a case printing the time is refused; the patch touches only expected files; a second run is empty |
| Published rerun | 2 | docs ahead of the release; a dependency missing from the wheel | the `readme_e2e` scenarios stay; each language adds its own |
| Site step | 2 | a red or untested page published; a false `claim` | a tree with one red case fails the site build |

None of this proves the prose true or a recorded output right: a record is what the code printed.
Engine results are held by the [conformance
tests](../../src/tests/conformance/komira_sql_conformance/README.md) against DuckDB; the human check
is the review of the expected-file diff.

## What is not built

- No third-party runner, markup language, notebook format or browser test; no wildcard or regex
  match, no automatic retry, no skip word.
- No inline expected output in READMEs, no state shared between blocks, no merged compile, no live
  services in cases (a Postgres variant is a `not-tested` fence).
- No view or tab engine and no status words in the core; no committed run results, run URLs or host
  names; no bot that commits. No Mojo docstring examples or Rust doctests on the farm.

Not checked: the redirect of uv, poetry, pdm, pixi and conda to a loopback index; a network-off
platform on the farm; whether buildrules can pin a Zig tool for our other repos; per-example Mojo
compile time.

## Decisions to take

1. **Offer the core outside komira?** Recommendation: no. It lives here, buildrules pins the built
   binary for our other repositories, and it becomes its own project only when an outside user asks.
2. **What does a failing task example block?** In the first tier a task case is an ordinary test
   target: the pull request check runs the cases its change reaches, as it runs any test, and a red
   one fails it. The question is the release. Recommendation: README and SDK-reference failures
   block the library and the release, as README failures do today; task failures block only the
   site build (second tier), so a docs mistake never holds a fix.
3. **A page that works on main and not on the published wheel: banner or hide?** This needs the
   published rerun (second tier); the first tier alone tests main only. Recommendation: show it with
   "needs the next release", written by the build from the two results; the banner clears itself on
   release (komira-ai/komira#2306).
4. **Are the marker words a public format?** They are irreversible once public: old READMEs carry
   them for as long as old versions exist. Recommendation: yes, three words (`<lang>-hidden`,
   `include`, `not-tested`), additions only, with this page as the spec and a shared vector file
   that the mopm.dev renderer must pass.
