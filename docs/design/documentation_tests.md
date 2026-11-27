# Testing the code in our documents

Status: accepted; the six decisions at the end were taken on 2026-11-27, each as recommended.
Built where a line says "exists": the task pages, and the first tier's tooling for package READMEs
(the include marker, `fill`, the freshness check, one welded test per example file, the exact
compare of an example's output, `migrate` and `migrate --verify`), proven on fixtures, with no
package README migrated yet. Task pages and package READMEs are one framework: the same commands
and the same rules, one row each of one rule table (piece 5). How every code block
in our documentation is run or accounted for. Counts are from main of this repository; *(not checked
here)* marks one from our other repositories, and *[est]* marks an estimate.

## The answer

1. **One model by default: source-first.** The example is a real file; a test runs that file; the
   page holds a marker and, under it, the file's contents, filled in by a tool and held equal to
   the file by a check. This is the model for every kind of document that shows code, package
   READMEs included. The inline model (the fence is the program, setup hidden in comments) is what
   Mojo READMEs do today, and it is migrated away.
2. **A generic core, at five small pieces:** the block reader, the example directory, the runner
   contract, the exact output compare, and the include and freshness check. Tabs, status words,
   the site, install managers and each language's wrapper stay with their owners.
3. **No third-party runner as the base.** None runs a Mojo example as a welded Buck2 test, and those
   that check "the page equals the file" are tied to their own site stack. We use
   [lychee](https://github.com/lycheeverse/lychee) for outside links (scheduled, not in the gate),
   the `llms.txt` page shape, and each language's own interpreter.
4. **Two tiers.** The first tier is what the examples gate needs and can be accepted alone. The
   second is bookkeeping that can follow, or not.

| Tier | Pieces |
|---|---|
| First | the block reader; the example directory with probes; the runner; the exact compare; include freshness and `fill`. Languages: Mojo (READMEs) and Python (task pages, SDK pages) |
| Second | the ledger of unchecked blocks and its tree guard; `record` as a patch; reruns against the published packages; the site step (claim guard, banner, plain `.md` copy, `llms.txt`) |
| Held | install cases (`sh`), tutorial steps, TypeScript: each needs a contract this doc does not write (below) |

Without the second tier, a failing compare prints the whole actual stdout, and the author pastes it
into the expected file and reads the diff. Unrun blocks are not listed one by one; the reader
prints their count.

## What exists today

Fences are counted by opening fence lines at any indentation; another fence rule moves a count by a
few percent. The task row is `ls -d python/docs/tasks/*/ | wc -l` and
`ls python/docs/tasks/*/probe_*.py | wc -l`.

| Fact (main) | Count |
|---|---|
| Package READMEs `src/<pkg>/README.md` / with Mojo examples | 265 / 221 |
| `mojo` fences in them, all run by the README gate / of them `mojo module` | about 660 / 49 |
| Of those fences, with a `mojo-hidden` comment / hidden lines in all | about 490 / about 1,400 |
| Example body lines: median / 90th percentile / largest | 19 / 44 / 145 |
| Other fences in package READMEs: `text` / `sh` | 29 / 6 |
| `readme = False` rows in `src/**/BUCK`; READMEs nested deeper under `src/` | 3; 11 |
| Python task directories in `python/docs/tasks/` / probes | 80 / 43 |
| Whole repository: Markdown files / fenced blocks / `python` / `sh` | 488 / about 1,000 / about 65 / about 100 |

Three mechanisms exist in this repository.

- **Inline Mojo README examples** ([README gate](../../tools/build/mojo/README.md#readme-examples)).
  The Zig tool `//tools/build/readme_examples:tool` cuts each `mojo` fence, with the `mojo-hidden`
  lines above it, into a program; each runs as a welded test, `[tests][readme]`; `release-check`
  refuses a released README with no example; `release/readme_e2e` runs the README the staged set
  holds against the installed `.conda` ([scenarios](../../tools/build/readme_e2e/README.md)).
- **Source-first Python task pages** ([docs/tasks/README.md](../tasks/README.md)). Each
  `python/docs/tasks/<rank>-<slug>/` holds `example.py`, `expected_output.txt`, `page.md` and
  optional probe pairs. `tasks-check` holds the catalogue to the directories and each page to the
  same include rules a README is held to (piece 5); `//python/docs/tasks:pages[check]` and
  `[fill]` are the same `check` and `fill` a README has; one wheel test per directory and per probe
  runs the file against the built wheel; four fixtures prove those runs can fail.
- **The Python quickstart pair**: `python/smoke/src/readme.zig` holds the quickstart blocks of
  [python/README.md](../../python/README.md) and [docs/install.md](../install.md) equal to
  `python/examples/quickstart.{py,expected}`.
- **Source-first package READMEs** (exists as tooling; no package README uses it yet). A library
  that lists `readme_examples = glob(["examples/*.mojo"])` runs each file as its own welded test
  and holds its README to the files with the tool's `check`; `fill` is the patch that mends a stale
  README; an example with `examples/<name>.expected_output.txt` has its stdout held to that file
  byte for byte; `migrate` and `migrate --verify` turn an inline README into files and includes, and prove
  them the same programs (piece 5 and the migration section below;
  [README gate](../../tools/build/mojo/README.md#source-first-readmes)). The fixture is the README
  of `src/anomaly` migrated, in
  [`tests//functional/readme_examples/source_first`](../../tools/build/tests/functional/readme_examples/source_first/BUCK).

What is missing: README examples cannot be copied and run (their imports are hidden), and the
README gate does not map a failure back to `README.md:<line>` (`program.mapReport` exists; only
`tools/build/readme_e2e/verify.zig` calls it). `doc_links` still reads Markdown through a second,
Mojo reader. Python SDK reference pages (`python/docs/`) run nothing. Unrun blocks are silent.
mopm.dev draws `<!-- ... -->` comments of a README as text *(not checked here)*.

## What we take from whom

| Project | What we take |
|---|---|
| Dart excerpter, kotlinx-knit, Azure SDK snippets, Qdrant | The page is filled from tested files, and a check fails when filling would change it |
| rustdoc, mdBook | The model for Rust (our Rust fences in Markdown run nowhere and are ledger rows); mdBook's anchors are the region option weighed below |
| Go testable examples | Ordered check levels: compile, run, compare output |
| Documenter.jl | A failing example fails the docs build; a mode that rewrites the expected output |
| Zig `doctest`, Sphinx-Gallery | An expected failure that turns red when it starts to pass: our probe |
| Sybil | Find, run and judge are separate steps; finding zero examples is a failure |
| trycmd / snapbox, pytest-examples | Accepting new output is a patch a person reviews |
| AWS code examples | A directory per task, a tree per language |
| Instruqt, freeCodeCamp | A step check must fail on the start state before it may pass |
| LLVM lit | Named result classes; its automatic retry is what we refuse |
| polars, LanceDB, Bluehawk; Elasticsearch | The warning: the link between page and test must be enforced, and a harness tied to one markup dies with it |

Not taken: scrut, cram, prysk and byexample (licences, or a silent whole-file skip); the pytest
plugins (pytest in a Buck2 action, and their own reader); Doc Detective, Innovation Engine, Quarto,
Jupyter Book and Modo.

## Source-first for every kind that shows code

| Kind | Example files | "Tested" means |
|---|---|---|
| Mojo package README | `src/<pkg>/examples/<name>.mojo` | each file compiles and runs against the library, welded, on the library's platforms, and again against the installed `.conda` |
| Python SDK reference pages | `python/docs/<page>/<name>.py` | each file runs against the built wheel in an empty directory |
| Task pages (exists for Python) | `python/docs/tasks/<rank>-<slug>/example.py` | the file runs; stdout equals `expected_output.txt`; probes fail with their line |
| Install and getting started (held) | one directory per manager | the command file runs as written, then the verify line, then the first script |
| Tutorial lessons, CLI docs (mopm; held) | one directory per step | a `seed` case must fail the step check, a `solution` case must pass |
| Runbooks, config, design docs | none | only the reader is shared; their fences are ledger rows or each repository's own checks |

**What stays inline.** Only what is not a program: a one-line shell command a reader types
(`mopm add komira-ai/anomaly`), `text` sketches, and diagrams. Of the six `sh` fences of package
READMEs, the `sh komira-link` block is held by `link-check` today; the others are counted in the
first tier and become ledger rows in the second. A one-line command gains nothing from a
file, and running it would need the network. Every `mojo` and `python` fence is an include.

### The two models for a README, side by side

| | Source-first (proposed) | Inline (today) |
|---|---|---|
| What the reader sees | a complete program with its imports and `def main()`, to copy and run | a snippet; its imports are hidden, so a copy does not run |
| Test header on the package page | none: nothing is hidden | the `mojo-hidden` comments, which mopm.dev draws as text today |
| What the author does | edit `examples/<name>.mojo`, run `fill`; forgetting `fill` fails the freshness check, naming the README line | edit the README; nothing else |
| Tooling | a real file: the formatter, the language server and real line numbers work | none in a fence; a failure names a generated file today |
| Packaging | the filled README ships, and its fences are the files byte for byte; the files themselves do not travel in the `.conda` until mopm's layout gains a path for them (below) | the README ships with its hidden comments |
| Reuse | one file shown by the README, the site and a task page | each copy is separate |
| Costs | two places to look; blocks about 3 lines longer at the median (19 to 22) and at the 90th percentile (44 to about 50), about 8% more README bytes *[est]*; a migration of about 660 examples; two new tool verbs (`fill`, `migrate`); one test target per file, whose per-file compile time is not measured; a mopm.dev renderer change before the package page is clean | none new; the hidden-line and copy-paste costs stay |

The estimates come from a scan of today's package READMEs that adds, per `mojo` fence, its hidden
lines, `def main() raises:` and a four-space indent per body line. The largest README,
`src/so/README.md`, is 57,979 bytes and would be about 59,400 *[est]*, under the 64 KiB a mopm
registry accepts for a readme (mopm's `spec/mopm-toml.md`, *not checked here*). The pages' growth
is the honest price of a program that runs as shown.

## The pieces

### 1. Block reader

Exists: `tools/build/markdown/markdown.zig` (38 tests) reads fences, HTML comments and links with no
I/O; `examples.zig` refuses near misses of `mojo` and reports every refusal at once; `markers.zig`
spells the include and `not-tested` markers once (`MARKERS`), and `include.zig`'s rule table
(`KINDS`) has a row per kind of document, `readme` and `task` (piece 5). New: `blocks --json` (the
same data for programs that are not Zig), near-miss refusals for every known word, an `sdk` row, and
the rest of a fence-word table per kind: `include` for `mojo` and `python` (exists), `inline` for
`sh` and `text`, `ledger` for other known words, `ignored` for `mermaid` and fences with no word.
`doc_links` moves onto this reader, so one reader remains.

### 2. Example directory, with probes

Cases are found by file name, never by reading a file: Starlark can `glob` in analysis but cannot
read a file, so one test target per example file comes from the `glob`, with no dynamic action.
Each language's files live in its own tree (`.py` files only under `python/`, as
`//:python_closure` requires; a task's languages join by slug, as `docs/tasks/catalogue.json` does
today).

- A case is `<name>.<ext>`, judged by exit 0 (a README example asserts in its own code), or with
  `<name>.expected_output.txt` beside it (a task page's `example.py` uses `expected_output.txt`).
  Exists for both: a README example with `examples/<name>.expected_output.txt` passes only when its
  stdout is that file byte for byte (`gate mojo --stdout`, then the tool's `compare-output`,
  `output.zig`); one with none passes on exit 0, as before.
- A probe is `probe_<name>.<ext>` with `probe_<name>.error.txt`, one line: it must fail with that
  line. When the feature lands, the probe runs to the end and goes red, and the page must change.
- The example writes its own sample data into its working directory, so a page hides no input.
- A file in the directory with no role, or a file no page shows, is refused.

### 3. Runner contract

| | |
|---|---|
| In | the example file (read-only), an environment, limits: a build phase (Mojo) and a run phase, each with a time limit, and a stdout size cap |
| Environment | Mojo: the library's `.mojoc` and its closure (welded), or the installed `.conda` prefix (e2e). Python: the hermetic CPython with the built wheel and its pinned libraries |
| Working directory | fresh, empty and writable |
| Out | exit, stdout, stderr, a one-line summary (Python: the last stderr line; Mojo: the first `error:` line), and a class: `ran`, `hang`, `output-too-big`, `signal`, `oom`, `refused`. A hang is a class, never exit 124, which already means "the compile watchdog killed the compiler" |
| Rules | no network; writes only inside the working directory; the runner judges nothing |

### 4. Exact output compare

Pass, or a diff naming `<name>.expected_output.txt:<line>` followed by the whole actual stdout.
Exact, byte for byte, as both built compares are: no final newline is ignored (a missing or extra
one is named, as a line `missing`), and `\n` is the only line end. A case that exits non-zero is red whatever it
printed. A probe passes only with class `ran`, a non-zero exit, and a summary equal to its
`.error.txt` line; a hang or a signal is red. No `...` line, no regex. Three filters exist for the
quickstart only (`<cwd>`, `<version>`, `<abi_version>`); a new one needs a user and a fixture.
Authors print floats at fixed precision, sort rows, and print no times, paths or versions.

### 5. Include, `fill` and freshness

The marker is `<!-- include <path> -->` at the start of the line directly before a fence, the same
marker task pages use today. `<path>` is relative to the page, with no `..`: `examples/<name>.mojo`
from a README, `example.py` from a task page. The fence word is the extension's (`.mojo` is `mojo`,
`.py` is `python`, `.txt` is `text`); the body is the file less one final newline; a file with
`\r`, a BOM or a trailing space is refused. The fence may be longer than three backticks when the
file holds a backtick run.

- `fill` rewrites every included fence body from its file, and touches nothing else. It is a build
  output, a patch the author applies with `git apply`.
- The freshness check fails when `fill` would change one byte, when an included file is missing,
  when a `mojo` or `python` fence has no marker, or when a `text` fence directly after an included
  fence (blank lines only between) is neither an include nor marked `<!-- not-tested: <why> -->`.
  Other `text` fences stay inline; none of the 29 in package READMEs directly follows a `mojo`
  fence today.
- A Markdown viewer that hides HTML comments (GitHub) shows the filled fence and nothing else. A
  renderer that draws comments as text must drop every comment that starts with a marker word;
  mopm.dev's renderer gets that change, tested against a shared vector file (below).
- Ship-time rule: the contents are in the Markdown. A marker alone renders nothing, so a README
  whose fence is empty or stale never ships: the freshness check is welded into the library.

Exists for both kinds, from one rule table (`KINDS` in `include.zig` of the README examples tool):
every rule above is one code path, and a row says only what differs.

| Kind | `--kind` | Files an include names | Fence word | Shown by every page | A code fence that shows no file |
|---|---|---|---|---|---|
| Package README | `readme` | `examples/<name>.mojo`, `examples/<name>.expected_output.txt` | `mojo`, `text` | each listed `.mojo` | refused (`mojo`, `mojo module` too) |
| Task page | `task` | `<name>.py`, `<name>.txt` of its own directory | `python`, `text` | `example.py`, `expected_output.txt` | refused (`python`) unless `<!-- not-tested: <reason> -->` |

`check --kind <kind>` is the freshness check of one or more pages, and `fill --kind <kind>` the
patch; both are run by one Starlark implementation (`tools/build/readme_examples/pages.bzl`) as the
sub-targets `[check]` and `[fill]`: a library's `[tests][readme][check]` and `[tests][readme][fill]`,
and `//python/docs/tasks:pages[check]` and `:pages[fill]`. `tasks-check` adds the catalogue's rules
and runs the same page rules, plus a page's first line. Common to both kinds, the check also refuses
the inline model's `mojo-hidden` comments, a comment that misspells a marker (`<!--include`,
`<!-- Include`, `<!-- not-tested -->`, text after the `-->`), an include that is not on the line
just before a fence, a file shown twice, a required file no include shows, and a not-tested marker
that does not stand on the line just before a fence. A file shown must end in a line feed. A
README lists an expected output only beside its `.mojo`, and the macro adds every
`examples/*.expected_output.txt` of the package to `readme_examples`, so none is left unchecked by a
glob. A README's `python` fences stay inline until a README shows `.py` files (none of today's
package READMEs holds one).

#### Marker comments

The words `include` and `not-tested` (and `mojo-hidden`, readable in published versions and refused
in new text) are a public format: additions only. A **marker comment** is an HTML comment block (a
line that starts, after at most three spaces, with `<!--`, to the first line that holds `-->`)
whose first word is exactly one of:

| word | the comment | written by |
|---|---|---|
| `include` | `<!-- include <path> -->`, the whole line, directly before the fence that shows the file | `migrate`, the author |
| `not-tested:` | `<!-- not-tested: <reason> -->`, the whole line, directly before a fence no run checks | the author |
| `mojo-hidden` | one line, or a block to its `-->`: hidden lines of the inline model | published READMEs only |

The first word is the text after `<!--` and any whitespace, up to whitespace or `-->`; it is
compared byte for byte. A renderer that draws comments as text drops every line of a marker
comment and keeps every other comment as it does today. A comment that does not start its line, a
comment inside a fence, and one whose first word differs in any byte (`Include`, `includes`,
`not-tested` without the colon, `not tested:`) are not marker comments. The freshness check refuses
a misspelt marker in a source-first README (`Include`, `not-tested` without the colon,
`not tested:`, `<!--include`), so a renderer that keeps one shows what the author wrote. No case
holds a comment indented four spaces or more, which CommonMark reads as code (the tool's reader
takes any indent as the comment's; nothing here depends on the difference).

The cases are
[`tools/build/readme_examples/marker_comments.json`](../../tools/build/readme_examples/marker_comments.json):
for each, a document (`markdown`) and the same document with its marker comments' lines removed
(`shown`). The tool's own renderer rule (`dropMarkers`) passes every case in its unit tests;
mopm.dev's renderer is held to the same file *(not checked here)*. A new word or case is added to
the file, never changed or removed.

### Whole file or a named region?

**Recommendation: the whole file.** The fence shows exactly the program that ran. The first draft of
this design refused part-shown includes for task pages; for READMEs, where a full program is longer
than today's snippet, the answer is the same, at the cost of the lines below.

| | Whole file | Named region (`# region: body` lines in the file, `<!-- include x.mojo region=body -->`) |
|---|---|---|
| Reader | copies the block and it runs | copies a snippet that does not run, as today |
| Length | about 3 lines more at the median, about 6 at the 90th percentile; the largest example, 145 lines, gains about 3 *[est]* | as today |
| File | a plain program | carries region comment lines, part of the file the reader never sees |
| Tool | one rule: body equals file | a region grammar per language, nesting and overlap refusals, and a check that every region is shown |
| Prior art | the fill-and-check tools above, used without regions | mdBook anchors, Bluehawk |

The region option reopens what source-first closes: a shown text that is not what ran. The extra
lines are an import or two and `def main() raises:`, which a reader needs anyway to run it. A region
word can be added later, additively, if a named page needs one; none does now.

## A README under source-first: `src/anomaly`

Files in the package directory, one per fence of today's README (lines 23, 42, 70 and 90). Example
files are named for what they show, lower-case with underscores; the README shows them in the order
it chooses:

```text
src/anomaly/README.md
src/anomaly/examples/validate_series.mojo
src/anomaly/examples/step_change.mojo
src/anomaly/examples/online_monitor.mojo
src/anomaly/examples/store_sweep.mojo
src/anomaly/BUCK
```

`src/anomaly/examples/validate_series.mojo`, the first example of today's README with its hidden
import made visible:

```mojo
from std.testing import assert_equal
from anomaly import SERIES_OK, SERIES_REJECT_UNORDERED, Series, series_reject_reason_name


def main() raises:
    var good = Series("latency/p50")
    good.append(Int64(1), 10.0)
    good.append(Int64(2), 11.0)
    assert_equal(good.validate(), SERIES_OK)

    var bad = Series("latency/p50")
    bad.append(Int64(2), 10.0)
    bad.append(Int64(2), 11.0)
    assert_equal(bad.validate(), SERIES_REJECT_UNORDERED)
    assert_equal(String(series_reject_reason_name(bad.validate())), "ORDINALS_NOT_STRICTLY_INCREASING")
```

The README, as committed: the marker, then the fence `fill` wrote, equal to the file.

````markdown
A series is checked before anything computes on it:

<!-- include examples/validate_series.mojo -->
```mojo
from std.testing import assert_equal
from anomaly import SERIES_OK, SERIES_REJECT_UNORDERED, Series, series_reject_reason_name


def main() raises:
    var good = Series("latency/p50")
    ...the rest of the file, byte for byte...
```
````

`src/anomaly/BUCK` lists them in analysis:

```python
mojo_adopted_library(
    name = "anomaly",
    lib = ":lib",
    readme = "README.md",
    readme_examples = glob(["examples/*.mojo"]),
    ...
)
```

What each person sees:

- **On GitHub:** the sentence and the complete program; the comment is not drawn.
- **On the package page** (mopm.dev): the same, once its renderer drops marker comments.
- **The author:** edits `step_change.mojo`, builds; the freshness check names
  `src/anomaly/README.md:<line>`, `fill` gives the patch, the author applies it.
- **A failure:** names `src/anomaly/examples/validate_series.mojo:<line>`, a file the author can
  open.

## How the tests run the files

- **Welded, as today** (exists). `[tests][readme]` becomes one test per file of `readme_examples`,
  compiled against `:lib` and run; the library exists only if every one passed and the freshness
  check passed. No dynamic action: the list is the `glob`. Each file is staged at its repository
  path, so a failure names `src/<pkg>/examples/<name>.mojo:<line>`.
- **Both platforms.** On linux-x86_64 in the pull request's check; on darwin-arm64 for the libraries
  of the macOS set, in the macOS part of the check, as the README gate builds them today.
- **Against the installed package.** `release/readme_e2e` keeps reading the README the staged set
  holds. Its filled fences are the files byte for byte, so each runs as a whole program (the
  `mojo module` path) against the installed `.conda`, with nothing from the source tree. Shipping
  the files themselves in the `.conda` is an additive path in mopm's package layout (beside
  `<import name>.bins/`); it is not needed for this test.
- **The zero-examples guard** becomes (exists): every listed file is shown by exactly one marker,
  and every `mojo` fence of the README is an include; `release-check` still refuses a released README with
  no example, as today. A README with no example (44 of 265 today) lists none and is refused only
  when released, as today; a `readme = False` library has neither and is not checked.

## The migration of today's READMEs

**The tool** (exists: `migrate.zig`; a library still on the inline model has the result as
`[tests][readme][migrated]`, proven by `migrate --verify` in the same build). A `migrate`
subcommand of the README examples tool turns each fence into a file and a marker. A `mojo` fence becomes the program the gate already runs, with one move: the leading run of
`from` and `import` lines (hidden or shown) goes above `def main() raises:`, and the rest of the
hidden lines and the body follow, indented four spaces. Mojo accepts an import in either place, so
the migrated example is the same program as today's. A `mojo module` fence becomes its hidden lines
and its body as they are. The README gets the marker and the filled fence; the hidden comment goes.
Files are named `example_<n>.mojo` in README order; authors rename them to say what they show later,
each rename a marker edit.

The fence word already decides the form: a `mojo` fence's body runs inside `def main()` today, so
it cannot declare a `struct` or a function, and an example that does is a `mojo module` fence
already. The tool infers nothing from the code. It refuses an example indented in a list item (a
marker starts its line; none of today's are) and an example line that ends in a space or a tab (a
shown file may not; none do).

**The proof, for each migrated README.**

- The same program: `migrate --verify` also compares each migrated file with the program `generate`
  writes today for that fence, and refuses any difference except the blank padding lines and the
  moved imports.
- Every migrated example still runs: the welded test, now per file, must pass.
- A broken example still goes red: the tool's fixtures hold the migrated files of `src/anomaly` with
  one assert changed, and that test must fail naming the file and line; it runs with every build of
  the tool (exists: `changed_assert` of the fixture package, built by the pull request's check,
  passes only when the run fails with `.../changed_assert/example_1.mojo:9:`; the tool's
  `expect-failure` judges it).
- The rendered README differs only where hidden lines became visible: `migrate --verify` takes the
  old README and the new one and refuses any difference except the added markers, the formerly
  hidden lines, the moved imports, `def main() raises:`, and the four-space indent.

**Order and batch size.** First the tool and its fixtures; then one package (`src/anomaly`) to show
the result; then batches of about 20 packages per pull request, about 11 of them, one directory
each so a batch reverts cleanly. `src/so` goes last, for its size. The inline path is deleted, and
`mojo-hidden` refused in new text, when no README uses it.

**What does not move.** The 3 `readme = False` rows are libraries that share a package directory
with the library whose README it is (`sdk_exec`, `gcp_firestore`); they keep no README. The 11
deeper READMEs are test fixtures, conformance suites and test helpers, not package READMEs; their
fences become ledger rows.

## Second tier

- **Ledger of unchecked blocks.** `ledger.tsv` per docset: doc, language, sha256 of the block body,
  reason. A known-language fence that is neither included nor checked needs a row; editing the
  block makes the row stale, which fails the build. A `max = N` line stops growth. A **tree guard**,
  like `//:readme_e2e_complete`, gives every Markdown file with a known-language fence a docset or a
  ledger row.
- **`record`.** Runs a case three times on each platform and refuses any difference; its output is a
  patch touching only expected files.
- **Published reruns.** The same cases against the package on its registry after publish. A pass on
  the build and a fail on the published package shows "needs the next release".
- **Site step.** Reads the run results as Buck2 inputs, checks a page's status word (a `gap` needs a
  failing probe), and emits the HTML, a plain `.md` copy and `llms.txt` from the same bytes.

## A worked task page (exists)

`python/docs/tasks/22-read-json-file-write-records-database/` holds `example.py`,
`expected_output.txt`, `page.md` and a probe, `probe_native_insert.py`, which writes the rows with
one komira `INSERT ... SELECT` and must fail with the one line of `probe_native_insert.error.txt`.
The page shows the two files through include markers; its Postgres variant is a fence marked
`<!-- not-tested: needs a Postgres server, which the check does not have -->`. If `example.py`
changes and the page does not, `tasks-check` names `page.md:<line>` and `:pages[fill]` is the patch
that mends it; if the output changes, the wheel test names `expected_output.txt:<line>`; when komira gains `INSERT`, the probe goes red and
the page and the catalogue status change together.

## What each check proves

Every row has a negative case that must go red and name the line.

| Check | Tier | Defect it catches | Negative case |
|---|---|---|---|
| Reader refusals | 1 | `Mojo`, `py`, an unclosed fence | one fixture per rule, asserting the exact text |
| Count guard | 1 | a reader or a list that finds nothing and passes | a README with no included example fails |
| Case run and line map | 1 | API drift, a removed symbol | a wrong call fails and names `<file>:<line>` |
| Hermetic run | 1 | an example that works only on the author's disk or network | a read outside the directory fails; a socket fails (Linux) |
| Classes | 1 | a hang or crash counted as a pass | an endless loop is `hang`; a self-kill is `signal` |
| Exact compare | 1 | a changed number, column, error text or row order | one byte differs (exists: `refuses_wrong_expected_output` for a task, `wrong_expected_output` of `tests//functional/readme_examples/expected_output` for a README) |
| Freshness | 1 | a file edited without `fill`; a hand-edited fence; typed output | one changed byte; a deleted file; an unmarked `mojo` fence |
| Probe | 1 | a `gap` page after the feature landed | a probe that runs, or fails with another line (exist) |
| Migration | 1 | a migrated README that changed more than its hidden lines | `migrate --verify` over a README with one extra edit |
| Ledger and tree guard | 2 | a skip that grows unseen; an unregistered doc | a stale, duplicate or missing row; an unregistered file |
| Record | 2 | output with times or paths | a case printing the time is refused |
| Published rerun | 2 | docs ahead of the release | the `readme_e2e` scenarios stay |
| Site step | 2 | a red or untested page published | a tree with one red case fails the site build |

None of this proves the prose true or a recorded output right. Engine results are held by the
[conformance tests](../../src/tests/conformance/komira_sql_conformance/README.md) against DuckDB;
the human check is the review of the diff.

## What is not built

- No third-party runner, markup language or notebook format; no wildcard or regex match, no retry,
  no skip word; no region includes.
- No state shared between examples, no merged compile, no live services in cases.
- No view or tab engine and no status words in the core; no committed run results or host names.

Not checked: whether uv, poetry, pdm, pixi and conda can be pointed at a loopback index; a
network-off platform on the farm; whether buildrules can pin a Zig tool for our other repos.

Measured: one example file as its own test (`mojo_build_test` then `mojo_gated_test` of
`tests//functional/readme_examples/source_first`, against `komira//src/anomaly:anomaly`) takes about
35 to 60 seconds on the farm, the compile most of it, read from the pull request check's progress
lines, which name the oldest running action every 7 seconds (a bound, not a per-action timer).
Four files and the failing fixture ran in parallel in about 90 seconds of wall time. About 660 files
cold would be about 6 to 11 farm-hours of action time *[est]*, cached after the first build. That
is today's cost, not an added one: the inline gate already compiles one program per example.

## Decisions taken

Taken on 2026-11-27, each as recommended below.

1. **Source-first for READMEs too?** Recommendation: yes. A README is the first code most people
   copy, and only a whole tested file shown as it ran can be copied and run.
2. **Whole file or a named region in the fence?** Recommendation: the whole file, about 3 lines
   longer per example; a region shows code that did not run as shown.
3. **What does a failing example block?** README and SDK-page examples are welded: they block the
   library and the release, as today. Task cases are tests in the pull request's check; the
   recommendation is that they block only the site build after merge, so a docs mistake never holds
   a fix.
4. **A page that works on main and not on the published wheel: banner or hide?** This needs the
   published rerun (second tier). Recommendation: show it with "needs the next release", written by
   the build from the two results; it clears itself on release (komira-ai/komira#2306).
5. **Are the marker words a public format?** `include` and `not-tested` already appear on task
   pages, and READMEs would carry them for as long as old versions exist. Recommendation: yes, those
   two words, additions only, with this page as the spec and a shared vector file the mopm.dev
   renderer must pass; `mojo-hidden` stays readable in published versions and is refused in new
   text.
6. **Offer the core outside komira?** Recommendation: no. It lives here; buildrules pins the built
   binary for our other repositories; it becomes a project of its own only when an outside user asks.
