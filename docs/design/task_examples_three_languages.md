# Task examples in Python, TypeScript and Mojo

Status: design, not built. The decisions at the end are open. This document adds TypeScript and Mojo
to the task pages of [docs/tasks/README.md](../tasks/README.md). It uses the framework of
[testing the code in our documents](documentation_tests.md): the same markers, the same checker and
the same kind of targets. Where that framework already has a rule, this document applies the rule
and does not make a new one. Counts are from main of this repository, and each count names how it
was taken. *[est]* marks an estimate.

It is a separate document, not a section of `documentation_tests.md`. That document's decisions
are already taken. This design needs its own ruling, and a separate page lets that ruling leave the
accepted text alone. `documentation_tests.md` lists TypeScript as held: it "needs a contract this doc
does not write". This document is that contract for task pages. Package READMEs and SDK pages in
TypeScript are not covered.

## The answer

Each item is the recommendation. The owner rules on the open ones in
[Decisions for the owner](#decisions-for-the-owner).

1. **One tree per language, joined by slug, as main has it.** `python/docs/tasks/`,
   `node/docs/tasks/` and, once a Mojo library a user can install runs a query,
   `src/<mojo sdk>/docs/tasks/`. Each task directory is `<rank>-<slug>/` and holds
   `example.<ext>`, `expected_output.txt` and `page.md`. The open komira.dev design
   (komira-ai/komira#2352) is the one that changes. It moves to main's names and layout.
2. **One page per language.** Each page shows its own language's program and output through the
   include markers that exist. The site joins a task's pages by slug into one page with one tab per
   language, in the fixed order Python, TypeScript, Mojo. A language that does not show the task
   says so in the catalogue, with a reason. There is no page in that tree to hold the reason, so the
   catalogue holds it.
3. **One expected output per language.** Each tree keeps its own `expected_output.txt`. A shared
   file would need one table printer reached from all three languages. Only Mojo has one
   (`format_table` in `src/sdk`), and every Python example's output would have to change.
4. **One runner per language, each with targets that must fail.** Python stays as it is. TypeScript
   gets a new verb of the Node tool that installs the packed package the way the install test does,
   type-checks `example.ts`, runs it from an empty directory and compares what it prints. Mojo gets
   a rule that builds `example.mojo` against the SDK library's closure and compares its output in
   the pull request's check. After merge, the release runs the same file against the installed
   `.conda`.
5. **The catalogue records each language.** A non-gap entry gains `languages`, with one status per
   language: `works`, `partial` or `not-shown` with a reason. The entry's `status` is held equal to
   the best of them.
6. **The checker gets a profile per language** in `tools/build/readme_examples`. A profile names the
   tree, the example and probe file names, and the fence word. Every rule that holds today stays,
   and applies to each profile.
7. **Out of scope: which API the TypeScript and Mojo examples use, and what the Mojo SDK is.** The
   layout, checker, runners and catalogue are the same whatever is decided. What changes is how
   many tasks each language shows, and where the Mojo tree sits.
8. **The first slice** makes rank 75 hold and test its Python and TypeScript examples, with Mojo
   recorded as not shown and why.

## What exists today

| Fact (main) | Count, and how it was taken |
|---|---|
| Catalogue entries: `works` / `partial` / `gap` | 45 / 35 / 20, counted from `docs/tasks/catalogue.json` |
| Python task directories | 80, `ls -d python/docs/tasks/*/`: one per non-gap entry |
| Python examples that call no frame API | 16, by a text search of `example.py` for `komira.read_`, `.pl.`, `df.`, pandas and polars (a search, not a run) |
| TypeScript or Mojo task directories | 0 |

- **The Python tree** is built ([docs/tasks/README.md](../tasks/README.md)).
  - `tasks-check` of `//tools/build/readme_examples:tool` holds the catalogue against the tree.
  - `//python/docs/tasks:<rank>-<slug>` runs each `example.py` from the built wheel. The wheel is
    installed in an empty environment, the program runs from an empty directory, and the output is
    compared byte for byte (`python/task_examples.bzl`, `python/tests/run_task_example.py`).
  - Four `refuses_*` targets prove that the runs can fail.
- **The Python-only places in the checker.**
  - `tasks.zig`: `FILES` and the probe suffix `.py`. A file outside the list is refused with "a task
    directory holds only example.py, expected_output.txt, page.md and probe_&lt;name&gt;.py with
    probe_&lt;name&gt;.error.txt". The catalogue's `KEYS` refuses any key it does not list.
  - `task_page.zig`: `EXTENSIONS` (`.py` to `python`, `.txt` to `text`), `SHOWN`, and the rule
    that an unmarked `python` fence is refused, with the word `python` spelled out in the code.
  - `tasks-check` takes no language argument.
- **No `.py` file outside `python/`.** The graph check `//:python_closure` refuses a `.py` file
  anywhere outside the Python surface (`tests/python_closure_allowlist.bzl`: `python`,
  `tools/build/examples/python_binding`, `.github/workflows/pypi.yml`). It also refuses a target
  outside that surface whose closure holds a `.py` source.
- **TypeScript.**
  - `//node:install_test` is `npm_install_test` (`tools/build/node/defs.bzl`), run by
    `node_act install-test` (`tools/build/node_tools/node_act.zig`). It copies the test files into
    an empty project and installs the packed package and the pinned tarballs of `apache-arrow` and
    its closure with `npm install --offline --ignore-scripts --engine-strict`. Then it runs
    `node --test` on Node 22, 24 and 26.
  - Its pass rule needs a registered `node:test` test in each file, so a plain program cannot run
    through it as it is.
  - Node strips the types of a `.ts` file outside `node_modules` itself, with no flag.
  - The public API is `Session`, `registerParquet`, `sql` and `Result`. `Result.toArrow()` gives an
    `apache-arrow` `Table`. `registerCsv` and `registerNdjson` check their arguments and then reject
    with `UnsupportedOperation`. A CSV file is read in the SQL text as `read_csv('<path>')`.
  - The package is not published: `release/npm_publish.txt` says `publish: off`, and the name
    `@komira-ai/komira` is a placeholder until the npm name is ruled
    ([typescript_package.md](typescript_package.md)).
- **Mojo.**
  - README examples run as welded tests in each library's build. For a package of
    `release/readme_e2e/packages.bzl`, the release also runs them against the installed `.conda`
    ([readme_e2e](../../tools/build/readme_e2e/README.md)).
  - `mojo_binary(expected_stdout = "...")` compares a program's output with a string, not a file.
  - `sdk_exec` runs SQL over Parquet, CSV and local Iceberg (`run_sql`, `EngineContext`).
  - `src/sdk/table_display.mojo` has `format_table(batch: RecordBatch, max_rows: Int = 20) -> String`.
  - `sdk` and `sdk_exec` are unpublished because they depend on unpublished libraries, and so is
    the engine closure `sdk_exec` imports ([release/UNPUBLISHED.md](../../release/UNPUBLISHED.md)).
    `arrow` has no blocker there; it is not yet in `release/readme_e2e/packages.bzl`. No library
    a user can install runs a query.

## 1. Where the examples live, and what they are called

| | A tree per language (main) | One directory per task (komira-ai/komira#2352) | One page directory, examples in language trees |
|---|---|---|---|
| Files | `python/docs/tasks/75-join-value-falls-two-bounds/example.py`, and the same directory name under `node/docs/tasks/` with `example.ts` | `docs/tasks/<rank>-<slug>/` with `example.py`, `example.ts`, `example.mojo` and an expected file for each | the examples as main has them; `docs/tasks/<rank>-<slug>/page.md` includes them across trees |
| `//:python_closure` | holds: `.py` only under `python/` | refused: a `.py` under `docs/` and a target that reads it, unless `docs/tasks` joins the Python surface | refused: the page check's closure holds the Python tree's `.py` files |
| Include markers | as they are: a file name of the task directory | as they are | a new path form (`/` and `..` are refused today), and a checker that reads three packages at once |
| Who owns a test | each package's own BUCK, beside the package it installs | one BUCK that depends on the wheel, the npm package and the Mojo libraries | each package's BUCK, plus a fourth for the pages |
| Expected file names | `expected_output.txt` in each tree | three names in one directory (`example.ts.expected`, ...) | as main |
| Prior art | the AWS code examples: a directory per task, a tree per language ([documentation_tests.md](documentation_tests.md#what-we-take-from-whom)) | | mdBook-style cross-tree includes |

**Recommendation: a tree per language.** It is the rule `docs/tasks/README.md` and
`documentation_tests.md` (piece 2) already state. It is the only one of the three that
`//:python_closure` accepts without widening the Python surface. It keeps the file names that
exist. The layout:

```text
docs/tasks/catalogue.json                     the one catalogue, as today
python/docs/tasks/<rank>-<slug>/
    example.py  expected_output.txt  page.md  [probe_<name>.py  probe_<name>.error.txt]
node/docs/tasks/<rank>-<slug>/
    example.ts  expected_output.txt  page.md  [probe_<name>.ts  probe_<name>.error.txt]
src/<mojo sdk>/docs/tasks/<rank>-<slug>/
    example.mojo  expected_output.txt  page.md  [probe_<name>.mojo  probe_<name>.error.txt]
```

The Mojo tree sits in the package of the library its examples import. That library is named by the
Mojo SDK decision (section 7). If it is `src/sdk`, the tree is `src/sdk/docs/tasks/`. It is not a new
directory directly under `src/`, where each directory is a library komira ships
([docs/architecture.md](../architecture.md)). If `//:src_layout` reads the nested package as one of
its own, slice 5 adds its row to that module map.

**What komira-ai/komira#2352 changes**, so the two documents agree. The site generator reads what
the checker already holds:

- The catalogue is `docs/tasks/catalogue.json`, not a new `docs/tasks/tasks.tsv`.
- The pages come from the three trees, not from `docs/tasks/<rank>-<slug>/`.
- Directory names are `<rank>-<slug>` with no padding (`4-group-by-column-and-sum`), with the slug
  from the catalogue.
- The page is `page.md`, not `README.md`. Its title and include markers follow the page rules.
- The output is `expected_output.txt`, compared byte for byte. It is not `example.expected`, and it
  has no `<version>` or `<cwd>` filters. Those exist for the quickstart only.
- The stored status words are `works`, `partial` and `gap`, and each language has its own (section
  5). The site may show a gap under another word. That is display, and the stored word stays.
- A tab is drawn for every language. A language with no example draws its not-shown reason from the
  catalogue. The generator refuses a task whose tabs differ from the catalogue's three records, so a
  tab can be neither dropped nor added outside the catalogue.
- komira-ai/komira#2352's rule that a TypeScript tab waits for the npm row of its install table to leave
  "not yet" stays, for every language. A language's tab is drawn only once its package is published.
  Until then the tab shows the line "not published yet". Its examples are still tested in every pull
  request, so they are right on the day the package ships.
- The deploy's run of the task programs on the released artifact, and its rule that a failing task
  is left out and listed, apply to each language's released package: the wheel, the npm package and
  the Mojo `.conda`.

## 2. The page

Each page shows one language. The page rules of `task_page.zig` apply as they are, with the file
names and fence word of the tree's profile (section 6):

````markdown
# How do I join where a value falls between two bounds?

One-line answer.

<!-- include example.ts -->
```typescript
...example.ts, byte for byte...
```

Output:

<!-- include expected_output.txt -->
```text
...expected_output.txt, byte for byte...
```

## Notes
...
````

- The first line is `# ` and the catalogue's question, the same on every language's page.
- Every page includes its own example (`example.py`, `example.ts` or `example.mojo`) and
  `expected_output.txt`. The fences are `python`, `typescript` or `mojo`, then `text`.
- A fence that shows no file has `<!-- not-tested: <reason> -->` on the line before it. Today only
  `python` fences need an include or that marker. Under this design, every code word of every
  profile needs one, so a TypeScript page cannot slip in an
  unchecked Python fence. A `text` fence that directly follows code needs one too, as today.
- The answer line, the notes and the related links are the page's own. They differ by language
  (`None` in Python, `null` in TypeScript). Related links point to the same tree (`../<dir>/page.md`).
- **The fixed order** is the order of the profile table: Python, TypeScript, Mojo. The site draws a
  task's tabs in that order. How a tab looks is the site's matter.
- **A language that does not show a task** has no directory and no page in its tree. Its line is the
  catalogue's `not-shown` record (section 5): one reason, and the issues that would lift it. The
  site draws that reason in the tab. Nothing is left out without saying so: the checker refuses a
  non-gap entry with no record for a language. A page in one tree says nothing about the other
  languages. Only the catalogue and the site, which joins the pages, hold that statement, and the site
  generator's refusal (section 1) keeps the two the same.

Another option was a stub directory in each tree for every task the language does not show, holding
a `page.md` of one marker line (`<!-- not-shown: <reason> -->`). It is not recommended. It needs a new
marker word in a public format, and about 160 stub directories *[est: 80 non-gap tasks × 2
languages]* before the first TypeScript example lands. A tree would also hold directories with no
example, which the checker refuses today.

## 3. Expected output

| | One `expected_output.txt` per tree (recommended) | One file that all three print byte for byte |
|---|---|---|
| Python | as today: `to_pylist()` dict reprs (`{'id': 1, 'name': 'Ana'}`), `None`, `7.0`, dtype names (`int64 float64`). Each of the 7 lines of rank 1's `expected_output.txt` (read by hand) is Python `print` output of a dict, a list or dtype names | every one of the 80 outputs rewritten to the shared form, and every example changed to print through the printer |
| TypeScript | whatever the example prints from the `Table` it reads. `Result` has no printer. `apache-arrow` gives an Int64 value as a `bigint` *[inferred, not measured here]*. What `console.log` of a row prints is not measured here either; the first slice fixes the form the TypeScript examples use | the shared printer bound in the Node package |
| Mojo | `print(format_table(batch))` or values | `format_table` as it is |
| Prints that are not tables (column lists, types, counts) | each language's own | still each language's own, so a task that prints anything but a table cannot share a file |
| New public API | none | a printer on `Result` in Python and Node, reached through a new libkomira call over the Mojo `format_table`: a public interface change in three places |

**What a shared printer would be.** It would be one formatter, `format_table` of `src/sdk`. It
prints an ASCII box with a row of column names, a row of type labels (`str`, `i64`) and a footer
line `N rows`. Python and Node would reach it through the C ABI they already call. One
implementation gives the same bytes in all three languages.

**Recommendation: one file per tree.** It changes no example that exists and adds no public API. It
holds each program to what that language really prints, and what a reader copies and runs prints the
same. A shared printer can be added later without moving a file. If it is, a check could then hold
the trees' output files equal for tasks that print only tables.

## 4. What runs each example

The runner contract of `documentation_tests.md` (piece 3) and the exact compare (piece 4) apply to
every language:

- a fresh, empty, writable working directory;
- no network;
- stdout compared byte for byte, with no filters;
- a failure named `<tree>/<dir>/expected_output.txt:<line>` or `<tree>/<dir>/example.<ext>:<line>`.

| | Python (exists) | TypeScript | Mojo |
|---|---|---|---|
| Package and macro | `python/task_examples.bzl`, `task_examples` | `node/task_examples.bzl`, `npm_task_examples` | `tools/build/mojo/task_examples.bzl`, `mojo_task_examples` |
| One target per directory / per probe | `//python/docs/tasks:<rank>-<slug>` / `<rank>-<slug>__probe_<name>` | `//node/docs/tasks:<rank>-<slug>` / `__probe_<name>` | `//src/<mojo sdk>/docs/tasks:<rank>-<slug>` / `__probe_<name>` |
| The aggregate in the check's roots | `:examples` | `:examples` | `:examples` |
| What the user gets | the built wheel in an empty environment of the hermetic CPython 3.13 | the packed npm package and the pinned `apache-arrow` closure, installed offline into an empty project | pull request: the SDK library's `.mojoc` and its closure; release: the installed `.conda` |
| Before the run | none | `tsc --noEmit`, strict, over `example.ts` against the installed package's `.d.ts` | the compile, with the pinned Mojo |
| Platforms in the pull request's check | linux-x86_64 | linux-x86_64, the pinned Node 24 | linux-x86_64 |
| After merge | `:examples_macos_arm64`, reporting | proposed: `:examples_macos_arm64`, in the macOS job that runs `//node:install_test_macos_arm64` today, reporting | the release's README e2e machinery, against the staged set |

**TypeScript.** `node_act` gets a verb `run-task-example`, written in Zig like the rest of the tool.
It does the install step of `install-test`: an empty project, the package tarball, the pinned
tarballs, and `npm install --offline --ignore-scripts --engine-strict`. Then it does three things:

1. It copies `example.ts` into the project, so that its import of the package by name resolves to
   the project's `node_modules`.
2. It type-checks the file with the TypeScript compiler of `//node/devtools:modules`. A type error is
   named `example.ts:<line>:<col>`. Node strips types without checking them, so without this step a
   page could show a program that runs but does not compile in a reader's editor.
3. It runs `node <project>/example.ts` with a new empty directory as the working directory and the
   environment `install-test` already cleans. It compares the output with `expected_output.txt`.

A thrown error is named `example.ts:<line>: threw <name>: <message>`, the line taken from the first
stack frame in the file. The examples run on one Node line, as Python's run on one CPython. The
install test keeps covering the three lines.

**Mojo.** In the pull request's check, `mojo_task_examples` builds each `example.mojo` against the
SDK library and its closure. This is the compile the welded tests of source-first README examples
use. It runs the program from an empty directory through the gate and compares the output with
`expected_output.txt`. `mojo_binary`'s `expected_stdout` takes a string, and Starlark cannot read a
file, so the compare is a step of the rule that reads the file, as the Python and Node runners do.

The run "as a user gets the libraries" is the release's: the README e2e phases `install`, `link`,
`compile` and `run` against the staged set, with the exact compare added. A pull request cannot
stage a release set (rule B9), so that run belongs to the release. Decision 4 of
`documentation_tests.md` (a page that works on main and not on the published package says "needs
the next release") covers the time between the two.

**Probes.** A probe is `probe_<name>.<ext>` with `probe_<name>.error.txt`, one line, in each
language:

- **Python:** `<Type>: <message>` of the exception, as today.
- **TypeScript:** `<name>: <message>` of the error the import of the file rejects with. The runner
  imports the file inside a catch and writes that line, so nothing parses a stack trace. A probe is
  type-checked like an example, so a probe that does not compile fails as a type error, not as the
  line in its `.error.txt`. That rules out a probe that "fails" on a typo, a bad import path or a
  method that does not exist. The runner also refuses a probe whose error is a `SyntaxError` or a
  module that cannot be found, whatever its `.error.txt` says. So a TypeScript probe tries what the
  typed API accepts and the engine refuses: SQL, or a frame verb refused by name at run time.
- **Mojo:** a probe must compile. Its line is the message of the error `main` raises. A probe that
  does not compile is refused, naming its first `error:` line, so a Mojo probe too fails only at run
  time, for the reason it was written for.

**Targets that must fail.** Each passes only when its run fails with the exact line. Each takes
fixture files from its package's `tests/fixtures/`, as Python's do:

| Language | Targets |
|---|---|
| Python (exist) | `refuses_wrong_expected_output`, `refuses_example_that_raises`, `refuses_probe_that_runs`, `refuses_probe_with_another_error` |
| TypeScript | `refuses_wrong_expected_output`, `refuses_example_that_throws`, `refuses_example_that_does_not_typecheck`, `refuses_probe_that_runs`, `refuses_probe_with_another_error`, `refuses_probe_with_syntax_error` |
| Mojo | `refuses_wrong_expected_output`, `refuses_example_that_raises`, `refuses_example_that_does_not_compile`, `refuses_probe_that_runs`, `refuses_probe_with_another_error`, `refuses_probe_that_does_not_compile` |

Each tree's root files name its `:pages`, `:examples` and `:refuses_*` targets, as
`ci/roots/komira/python/docs/tasks:*` do. Adding a task directory still adds no root file.

## 5. The catalogue

`docs/tasks/catalogue.json` stays the one catalogue. A non-gap entry gains one key, `languages`:

```json
{
  "rank": 75,
  "slug": "join-value-falls-two-bounds",
  "category": "Join",
  "question": "How do I join where a value falls between two bounds?",
  "status": "works",
  "languages": {
    "python": {"status": "works"},
    "typescript": {"status": "works"},
    "mojo": {"status": "not-shown", "reason": "no Mojo library a user can install runs a query yet"}
  }
}
```

- `languages` has exactly the profile names as keys (`python`, `typescript`, `mojo`).
- Each value has a `status` of `works`, `partial` or `not-shown`, and an optional `issues` list
  in today's `komira-ai/<repo>#<n>` form. A language's `issues` are those that block that language
  only: a missing verb in its SDK, or its package unpublished. The entry's own `issues` stay as
  today: the issues that block the task as komira does it, required for a gap and allowed for a
  partial entry. An issue may appear in both.
- A `not-shown` value also has a `reason`: one line, not empty.
- A gap entry has no `languages`. No language shows a gap.
- **What "works" means.** A language's `works` means its example does the whole task. `partial`
  means the example does part of it, and its page says which part. The entry's `status` is held
  equal to the best of its languages:
  - `works` when any language works;
  - `partial` when the best is partial;
  - an entry whose languages are all `not-shown` is refused, because it is a gap.

  So `status` keeps today's meaning, "komira does the task", and the site design still reads it
  correctly. An entry can be `works` while Python is `partial`, for example when the SQL example in
  TypeScript does the whole task and the Python page shows a frame verb that is missing. "Works in
  every language" is the term for the publishing bar (decision 4).
- **The bar as a report.** The output of each `:pages` target, today `<directory> <status>` per
  directory, gains a line per entry with its three language statuses. It also gains a last line
  counting the entries that meet decision 4's bar and those that do not. It is a report, not a
  gate. It fails no pull request, and the site's deploy reads it.
- **Probes** follow the language. A probe in a tree is allowed when that language's status is
  `partial`, and refused when it is `works`. This replaces today's rule in `tasks.zig`, which reads
  the entry's status. Under the old rule, a Python `partial` page with probes would be refused as
  soon as a TypeScript `works` made the entry `works`.
- **Compatibility.** The catalogue is read only by this repository's checker and, once built, its
  site generator. It ships in no package. The slice that adds `languages` fills it for every non-gap
  entry in the same commit, and the checker requires it from that commit on. No reader ever sees a
  catalogue with only part of it filled. The change only adds (rule B8): no key is removed
  or re-meant, and the one new key is required only from the commit that fills it.

## 6. The checker

`tools/build/readme_examples` gets one table, `PROFILES`, in a new `profiles.zig`. The literals of
`tasks.zig` and `task_page.zig` move into it:

| Profile | Tree | Example | Probe | Code fence word | Near misses refused |
|---|---|---|---|---|---|
| `python` | `python/docs/tasks` | `example.py` | `probe_<name>.py` | `python` | `py` |
| `typescript` | `node/docs/tasks` | `example.ts` | `probe_<name>.ts` | `typescript` | `ts` |
| `mojo` | none until the Mojo tree lands | `example.mojo` | `probe_<name>.mojo` | `mojo` | `Mojo` |

Every profile has `expected_output.txt` (`text`), `page.md` and `probe_<name>.error.txt`.

- **The new flag.** `tasks-check` takes `--profile <name>`, and it is required. Each tree's `:pages`
  target passes its own. `task_pages_check` and the helpers `task_dirs` and `task_probes` move to a
  shared `.bzl`, with the probe extension as an argument.
- **What stays strict, for every profile.**
  - Directory names are `<rank>-<slug>`, and the rank matches the entry.
  - A gap has no directory.
  - A directory holds exactly the three files and probe pairs, and nothing else. A `.py` in the
    Node tree is refused as an extra file, and so is an `example.ts` in the Python tree.
  - A probe's error file is one line ended by a line feed.
  - The page's title is the question.
  - The page includes the profile's example and `expected_output.txt`, each byte for byte.
  - A file name in an include has no `/`.
  - A shown file has no carriage return.
  - A `text` fence after code needs an include or `not-tested`.
- **New page rules, for every profile.** Each code word of every profile needs an include or
  `not-tested`; today only `python` does. The near-miss words of the table are refused by name,
  naming the word to use. Today no fence word is refused.
- **New catalogue rules** (section 5), checked by every tree's run, because every run reads the
  whole catalogue:
  - the form of `languages`;
  - `status` equal to the best language status;
  - an entry with every language not shown is refused.
- **New rules for a tree's own language.** Each tree's run checks its own profile's language:
  - every directory's entry has that language `works` or `partial`;
  - every entry with that language `works` or `partial` has a directory;
  - a probe needs that language `partial`.

  For a profile with no tree (Mojo today), every run refuses an entry that marks that language as
  shown. The Mojo row gets its tree in the same pull request that adds the tree's BUCK file. That
  BUCK file's `:pages` names the Mojo library its examples import. Its analysis fails when that
  library is not a package of `release/readme_e2e/packages.bzl`, so no Mojo tab is shown for a
  library a reader cannot install. Until the row names a tree, nothing reads a stray directory under
  `src/`. The site draws tabs only from the trees the profile table names, so such a directory is
  never shown.
- **Why each tree runs its own check, not one check over all three:** the Python tree's files cannot
  be read by a target outside `python/` (`//:python_closure`). Each run checks the whole catalogue
  and its own language, and no claim goes unchecked. A language is shown only when its tree's run
  has found the directory. The catalogue file and the checker tool are declared inputs of every
  tree's `:pages`. A pull request that changes only the catalogue, or only `tools/build/readme_examples`,
  reaches every tree's `:pages` through the build graph and runs them all.
- **Its tests.** The checker's unit tests (`tasks_test.zig`, `task_page_test.zig`) gain the cases in
  [What each check proves](#what-each-check-proves). One profile fixture per rule, each asserting
  the exact refusal text.

## 7. Out of scope here, and decided elsewhere

Two choices are made elsewhere. This design holds for either answer:

- **Which API the TypeScript and Mojo examples use:** SQL only for now, or frame APIs too. The
  TypeScript package today runs SQL. A DataFrame builder is "explicitly later" in
  [typescript_package.md](typescript_package.md).
- **What the Mojo SDK is:** a new public library with a session and `sql` over `sdk_exec`, that plus
  a frame API, or the engine libraries used directly. It also decides when its closure is published.

| | SQL only | Frame APIs too |
|---|---|---|
| Layout, file names, page rules, checker, runners, catalogue keys | as above | as above |
| How many tasks each language shows | fewer: a task whose example needs a frame is `not-shown` or `partial` in TypeScript and Mojo (rank 60's Python example calls no SQL: a text search of its `example.py` for `sql` and `SELECT` finds none) | more, once the frame API exists |
| Probes | a probe can only try SQL, since a frame call that does not exist is a type or compile error, not a run failure | a probe can try a frame verb that is refused by name at run time |
| A shared printer (section 3) | less useful: each example prints a few rows | more useful: printing a frame wants one form |
| The Mojo tree's path | `src/<the library that holds the session>/docs/tasks/` | the same |

The Mojo profile's tree is set only when that library is published (it is in
`release/readme_e2e/packages.bzl`). A page shows only what a reader can install and run. A Mojo
example built against the unpublished `sdk_exec` in this repository would pass the pull request's
check and fail for every reader.

## 8. The slices, in order

1. **One task in Python and TypeScript, Mojo marked not shown.** The task is rank 75,
   `join-value-falls-two-bounds`. Its status is `works`. Its Python example is SQL only, over two
   small CSV files, and prints only integers and strings, with no probes. The slice holds:
   - `PROFILES` with `python` and `typescript` (and `mojo` with no tree);
   - `--profile`;
   - the catalogue rules;
   - `languages` filled for all 80 non-gap entries. For Python it copies today's `status`. For
     TypeScript it is `not-shown`, "no TypeScript example yet", except rank 75. For Mojo it is
     `not-shown`, "no Mojo library a user can install runs a query yet";
   - `node_act run-task-example`, `node/task_examples.bzl` and the six TypeScript `refuses_*`
     targets with their fixtures;
   - `node/docs/tasks/75-join-value-falls-two-bounds/`. It runs the same two joins over the same
     two CSV files, but reads them with `read_csv('<file>')` in the SQL text where the Python
     example calls `register_csv`, since `registerCsv` is refused. Its page says so in its notes;
   - the form the TypeScript examples print rows in. It is chosen by running rank 75, printing the
     values the example reads with `console.log` and no helper the page hides. It is written into
     "Writing an example whose output is stable" of `docs/tasks/README.md` for the batches that
     follow;
   - its root files;
   - `docs/tasks/README.md` brought up to date.

   If review asks for the checker change to land first (P7), this is two pull requests: the profile
   and catalogue rules, then the runner and the task.
2. **The site design follows main.** komira-ai/komira#2352 moves to the names of section 1. This is
   a document only and can land beside slice 1.
3. **TypeScript examples in batches**, for tasks the Python tree already shows. Each batch adds its
   directories and changes the `typescript` record of the same entries. No batch touches the Python
   tree.
4. **The Mojo SDK** (section 7): its design, then publishing its closure. That work is not planned
   here.
5. **The Mojo tree.** This comes once the library of slice 4 is published:
   - the `mojo` profile's tree;
   - `mojo_task_examples` and its six `refuses_*` targets;
   - the first Mojo task;
   - the compare phase in the release's README e2e machinery;
   - the `mojo` records of the tasks it shows.
6. **A shared printer**, only if decision 3 is ruled that way.

## What each check proves

Every row has a negative case that must go red and name the line or the entry.

| Check | Defect it catches | Negative case |
|---|---|---|
| Profile: files | an example of another language, or a stray file, in a tree | a `.py` in the Node tree; an `example.ts` with no `expected_output.txt` |
| Profile: fences | an unchecked program on a page | an unmarked `typescript` fence; an unmarked `python` fence on a TypeScript page; a `ts` fence |
| Profile: include | a page that shows another program than the one that ran | one changed byte of `example.ts` in the page |
| Catalogue: `languages` | a language left out without a word | a non-gap entry with no `mojo`; a `not-shown` with no reason; an unknown language key |
| Catalogue: status | an entry whose word disagrees with its languages | `status` `works` with every language `partial`; every language `not-shown` on a non-gap entry |
| Tree against catalogue | a tab with no tested example, or a tested example the catalogue hides | `typescript` `works` with no directory, the catalogue the only file changed; a directory with `typescript` `not-shown`; `mojo` shown while the profile has no tree |
| Probes per language | a probe rule that reads the wrong status | a Python `partial` directory with probes whose entry is `works` through TypeScript passes; a probe in a `works` language is refused |
| Mojo tree's library | a Mojo tab for a library a reader cannot install | a Mojo `:pages` naming a library that is not in `release/readme_e2e/packages.bzl` fails analysis |
| TypeScript run | changed output, a throw, a type error, a probe that passes, fails another way or fails on a syntax error | the six `refuses_*` targets |
| Mojo run | changed output, a raise, a compile error, a probe that passes, fails another way or does not compile | the six `refuses_*` targets |

## Decisions for the owner

1. **Where the examples live.** (a) One tree per language, joined by slug, as main and
   `documentation_tests.md` have it; komira-ai/komira#2352 moves to main's names. (b) One
   `docs/tasks/<rank>-<slug>/` per task with every language's files, as komira-ai/komira#2352 has
   it. That needs `docs/tasks` added to the Python surface of `//:python_closure` and three expected
   file names in one directory. It also changes the rule that `docs/tasks/README.md` and
   `documentation_tests.md` (piece 2) state today. **Recommendation: (a).**
2. **Where a language that does not show a task says so.** (a) In the catalogue, as a `not-shown`
   record with a reason. (b) In a stub `page.md` of one new marker line in that language's tree.
   **Recommendation: (a).** No new marker word, and no directory without an example.
3. **Expected output.** (a) One file per tree, each language printing in its own way. (b) One file
   all three print byte for byte, through a printer bound into Python and Node over the Mojo
   `format_table`. **Recommendation: (a)**, with (b) open as a later addition that moves no file.
4. **The publishing bar for komira.dev.** (a) Every non-gap task works in all three languages.
   (b) Every non-gap task is shown in all three languages, or not shown with a reason that names an
   issue. A reason with no issue, such as "no TypeScript example yet", never meets the bar.
   **Recommendation: (b).** The `:pages` report counts it (section 5), and a language limit stays tracked
   work, not a silent hole. (b) still means Mojo must show every task its published library can do.
5. **The Mojo run in the pull request's check.** (a) Against the SDK library and its closure as the
   build holds them. The run against the installed `.conda` comes at release. (b) Against an
   installed staged set in every pull request. **Recommendation: (a).** Staging a release set in a
   pull request is a release dry run, which rule B9 refuses. Either way, the Mojo tree exists only
   once its library is published (section 6), so (a) never shows a page a reader cannot run.
