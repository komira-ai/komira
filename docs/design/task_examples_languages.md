# Task examples in SQL, Python, TypeScript and Mojo

Status: design, not built. The decisions at the end are open. This document adds SQL, TypeScript and
Mojo examples to the task pages of [docs/tasks/README.md](../tasks/README.md). It uses the framework
of [testing the code in our documents](documentation_tests.md): the same markers, the same checker
and the same kind of targets. Where that framework already has a rule, this document applies the
rule and does not make a new one. Counts are from main of this repository, and each count names how
it was taken. *[est]* marks an estimate.

It is a separate document, not a section of `documentation_tests.md`. That document's decisions
are already taken. This design needs its own ruling, and a separate page lets that ruling leave the
accepted text alone. `documentation_tests.md` lists TypeScript as held: it "needs a contract this doc
does not write". This document is that contract for task pages. Package READMEs and SDK pages in
TypeScript are not covered.

**Forms.** A *form* is one way to write a task's program: a language and the surface of komira it
uses. There are four forms here: `sql`, `python`, `typescript` and `mojo`. Mojo may get more than
one form: a session-and-SQL surface, and an untyped SDK whose code builds a physical plan directly.
The Mojo SDK's own design defines those forms. This one leaves room for them (sections 1, 5 and 6)
and decides neither.

## The answer

Each item is the recommendation. The owner rules on the open ones in
[Decisions for the owner](#decisions-for-the-owner).

1. **One tree per form, joined by slug.** Main's rule is one tree per language; only Python's
   exists. A tree sits in the
   package whose runner runs its examples:
   - `python/docs/tasks/` for Python;
   - `python/docs/sql_tasks/` for SQL, run by a command in the Python package;
   - `node/docs/tasks/` for TypeScript;
   - one tree per Mojo form, in the package of the Mojo library it imports.

   Each task directory is `<rank>-<slug>/` and holds `example.<ext>`, `expected_output.txt` and
   `page.md`, as today. The open komira.dev design (komira-ai/komira#2352) is the one that changes.
   It moves to main's names and layout.
2. **One page per form, and one tab per form.** Each page shows its form's program and output
   through the include markers that exist. The site joins a task's pages by slug into one page, with
   tabs in a fixed order: SQL first, then Python, TypeScript, and the Mojo forms. A form that does
   not show the task says so in the catalogue, with a reason.
3. **One expected output per form.** Each tree keeps its own `expected_output.txt`. A shared file
   would need one table printer reached from every form.
4. **One runner per form, each with targets that must fail.**
   - Python stays as it is.
   - SQL is run as a reader would run it: a `komira sql <file>` command in the Python package.
     komira has no such command today.
   - TypeScript gets a new verb of the Node tool. It installs the packed package the way the install
     test does, type-checks `example.ts`, runs it from an empty directory and compares what it
     prints.
   - Each Mojo form gets a rule that builds its example against the library's closure in the pull
     request's check. After merge, the release runs it against the installed `.conda`.
5. **The catalogue records each form.** A non-gap entry gains `forms`, with one status per form:
   `works`, `partial`, or `not-shown` with a reason. The entry's `status` is held equal to the best
   of them. A new form is a new key.
6. **The checker gets a profile per form** in `tools/build/readme_examples`. A profile names the
   tree, the example and probe file names, and the fence word. Every rule that holds today stays and
   applies to each profile. Two forms of one language are two profiles with one fence word.
7. **Out of scope: which API the TypeScript and Mojo examples use, and what the Mojo SDK and its
   forms are.** The layout, checker, runners and catalogue are the same whatever is decided.
8. **The first slice** makes rank 75 hold and test its Python and TypeScript examples. Mojo is
   recorded as not shown and why, and so is SQL until its command exists. The SQL command and rank
   75's SQL example come next.

## What exists today

| Fact (main) | Count, and how it was taken |
|---|---|
| Catalogue entries: `works` / `partial` / `gap` | 45 / 35 / 20, counted from `docs/tasks/catalogue.json` |
| Python task directories | 80, `ls -d python/docs/tasks/*/`: one per non-gap entry |
| Python examples that hold SQL text | 79 of the 80, `grep -l "sql(" python/docs/tasks/*/example.py` |
| Python examples that call no frame API | 16, by a text search of `example.py` for `komira.read_`, `.pl.`, `df.`, pandas and polars (a search, not a run). How many more could be written as SQL alone is not counted here |
| SQL, TypeScript or Mojo task directories | 0 |

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
  outside that surface whose closure holds a `.py` source or a Python rule. A test that installs the
  wheel is such a target.
- **No command runs a `.sql` file.**
  - The Python package declares no command; `python/` has no `[project.scripts]` or entry point by
    a text search.
  - The Node package's `package.json` has no `bin`.
  - The only Mojo programs a package declares (`bins` in a `src/*/mopm.toml`) are a benchmark's.
  - A reader runs SQL today only through an SDK's `sql()`. The engine parses `COPY ... TO`
    (`src/sql/sql_parser.mojo`), and three Python examples use it to write files.
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

| | A tree per form (main's rule, extended) | One directory per task (komira-ai/komira#2352) | One page directory, examples in form trees |
|---|---|---|---|
| Files | `python/docs/tasks/75-join-value-falls-two-bounds/example.py`, and the same directory name under each other form's tree | `docs/tasks/<rank>-<slug>/` with `example.sql`, `example.py`, `example.ts`, `example.mojo` and an expected file for each | the examples as main has them; `docs/tasks/<rank>-<slug>/page.md` includes them across trees |
| `//:python_closure` | holds: `.py` and the wheel's tests only under `python/` | refused: a `.py` under `docs/` and a target that reads it, unless `docs/tasks` joins the Python surface | refused: the page check's closure holds the Python tree's `.py` files |
| Two forms of one language (Mojo) | two trees, so every directory still holds one example | two files of one extension in one directory, with new names for both and their expected files | as the first column |
| Include markers | as they are: a file name of the task directory | as they are | a new path form (`/` and `..` are refused today), and a checker that reads several packages at once |
| Who owns a test | the BUCK of the package whose runner runs it | one BUCK that depends on the wheel, the npm package and the Mojo libraries | each package's BUCK, plus one more for the pages |
| Prior art | the AWS code examples: a directory per task, a tree per language ([documentation_tests.md](documentation_tests.md#what-we-take-from-whom)) | | mdBook-style cross-tree includes |

**Recommendation: a tree per form.** It is the rule `docs/tasks/README.md` and
`documentation_tests.md` (piece 2) already state for languages, and a form is the same idea for a
language with two surfaces. It is the only one of the three that `//:python_closure` accepts
without widening the Python surface. It keeps the file names that exist, and every task directory
keeps exactly one example, so the directory rules of `tasks.zig` hold as they are. The layout:

```text
docs/tasks/catalogue.json                     the one catalogue, as today
python/docs/sql_tasks/<rank>-<slug>/          form sql
    example.sql   expected_output.txt  page.md  [probe_<name>.sql   probe_<name>.error.txt]
python/docs/tasks/<rank>-<slug>/              form python
    example.py    expected_output.txt  page.md  [probe_<name>.py    probe_<name>.error.txt]
node/docs/tasks/<rank>-<slug>/                form typescript
    example.ts    expected_output.txt  page.md  [probe_<name>.ts    probe_<name>.error.txt]
src/<mojo library>/docs/tasks/<rank>-<slug>/  form mojo, and one tree like it per further Mojo form
    example.mojo  expected_output.txt  page.md  [probe_<name>.mojo  probe_<name>.error.txt]
```

- **The SQL tree** sits under `python/` only because its runner, under decision 6's recommendation,
  is a command of the Python package. Its test installs the wheel, which `//:python_closure` allows
  only there. If the owner rules for another runner, the tree moves to that runner's package. That
  move is one directory and one BUCK file, with no change to its files.
- **A Mojo tree** sits in the package of the library its examples import. The Mojo SDK's design
  names that library and its forms. A second Mojo form is a second tree in its own library's package,
  or `docs/<form>_tasks/` beside the first when both forms import one library. None of these trees
  is a new directory directly under `src/`, where each directory is a library komira ships
  ([docs/architecture.md](../architecture.md)). If `//:src_layout` reads a nested package as one of
  its own, the slice that adds the tree adds its row to that module map.

**What komira-ai/komira#2352 changes**, so the two documents agree. The site generator reads what
the checker already holds:

- The catalogue is `docs/tasks/catalogue.json`, not a new `docs/tasks/tasks.tsv`.
- The pages come from the form trees, not from `docs/tasks/<rank>-<slug>/`.
- Directory names are `<rank>-<slug>` with no padding (`4-group-by-column-and-sum`), with the slug
  from the catalogue.
- The page is `page.md`, not `README.md`. Its title and include markers follow the page rules.
- The output is `expected_output.txt`, compared byte for byte. It is not `example.expected`, and it
  has no `<version>` or `<cwd>` filters. Those exist for the quickstart only.
- The stored status words are `works`, `partial` and `gap`, and each form has its own (section 5).
  The site may show a gap under another word. That is display, and the stored word stays.
- A tab is drawn for every form, in the order of the profile table. A form with no example draws its
  not-shown reason from the catalogue. The generator refuses a task whose tabs differ from the
  catalogue's form records, so a tab can be neither dropped nor added outside the catalogue.
- komira-ai/komira#2352's rule that a TypeScript tab waits for the npm row of its install table to
  leave "not yet" stays, for every form. A form's tab is drawn only once the package that runs it is
  published. Until then the tab shows the line "not published yet". Its examples are still tested in
  every pull request, so they are right on the day the package ships.
- The deploy's run of the task programs on the released artifact, and its rule that a failing task
  is left out and listed, apply to each form's released package: the wheel (Python and SQL), the npm
  package and the Mojo `.conda`.

## 2. The page

Each page shows one form. The page rules of `task_page.zig` apply as they are, with the file names
and fence word of the tree's profile (section 6):

````markdown
# How do I join where a value falls between two bounds?

One-line answer.

<!-- include example.sql -->
```sql
...example.sql, byte for byte...
```

Output:

<!-- include expected_output.txt -->
```text
...expected_output.txt, byte for byte...
```

## Notes
...
````

- The first line is `# ` and the catalogue's question, the same on every form's page.
- Every page includes its own example (`example.sql`, `example.py`, `example.ts` or `example.mojo`)
  and `expected_output.txt`. The fences are `sql`, `python`, `typescript` or `mojo`, then `text`.
- A fence that shows no file has `<!-- not-tested: <reason> -->` on the line before it. Today only
  `python` fences need an include or that marker. Under this design, every code word of every
  profile needs one, so a TypeScript page cannot slip in an unchecked Python or SQL fence. A `text`
  fence that directly follows code needs one too, as today.
- The SQL page says in a sentence how to run the file, with the command of decision 6 as inline
  code (`komira sql example.sql`), not a fence. A one-line command a reader types stays inline, as
  `documentation_tests.md` rules for package READMEs.
- The answer line, the notes and the related links are the page's own. They differ by form (`None`
  in Python, `null` in TypeScript). Related links point to the same tree (`../<dir>/page.md`).
- **The fixed order** is the order of the profile table: SQL, Python, TypeScript, then the Mojo forms
  in the order the Mojo SDK's design lists them. How a tab looks is the site's matter.
- **Why SQL is a tab of its own, and first.** SQL is the one form every SDK runs as written. 79 of
  the 80 Python examples already hold SQL text (the count above), so a SQL page is the shortest
  correct answer for most tasks, and a reader who knows SQL needs no SDK to read it. As a tab of its
  own it has its own runner, output and status. A SQL block at the top of every SDK page would be
  shown four times and tested by none of them. The SDK examples keep their own SQL text, and the SQL
  example need not match it.
- **A form that does not show a task** has no directory and no page in its tree. Its line is the
  catalogue's `not-shown` record (section 5): one reason, and the issues that would lift it. The
  site draws that reason in the tab. Nothing is left out without saying so: the checker refuses a
  non-gap entry with no record for a form. A page in one tree says nothing about the other forms.
  Only the catalogue and the site, which joins the pages, hold that statement, and the site
  generator's refusal (section 1) keeps the two the same.

Another option was a stub directory in each tree for every task the form does not show, holding a
`page.md` of one marker line (`<!-- not-shown: <reason> -->`). It is not recommended. It needs a new
marker word in a public format, and about 240 stub directories *[est: 80 non-gap tasks × 3 forms
beyond Python; 320 with two Mojo forms]* before the first new example lands. A tree would also hold directories with no example,
which the checker refuses today.

## 3. Expected output

| | One `expected_output.txt` per tree (recommended) | One file that every form prints byte for byte |
|---|---|---|
| SQL | what the command of decision 6 prints for each statement, in one table form | the same form |
| Python | as today: `to_pylist()` dict reprs (`{'id': 1, 'name': 'Ana'}`), `None`, `7.0`, dtype names (`int64 float64`). Each of the 7 lines of rank 1's `expected_output.txt` (read by hand) is Python `print` output of a dict, a list or dtype names | every one of the 80 outputs rewritten to the shared form, and every example changed to print through the printer |
| TypeScript | whatever the example prints from the `Table` it reads. `Result` has no printer. `apache-arrow` gives an Int64 value as a `bigint` *[inferred, not measured here]*. What `console.log` of a row prints is not measured here either; the first slice fixes the form the TypeScript examples use | the shared printer bound in the Node package |
| Mojo | `print(format_table(batch))` or values | `format_table` as it is |
| Prints that are not tables (column lists, types, counts) | each form's own | still each form's own, so a task that prints anything but a table cannot share a file |
| New public API | none for Python, TypeScript and Mojo; the SQL command and its output form (decision 6) are new public interface of their own | a printer on `Result` in Python and Node, reached through a new libkomira call over the Mojo `format_table`: a public interface change in three places |

**What a shared printer would be.** It would be one formatter, `format_table` of `src/sdk`. It
prints an ASCII box with a row of column names, a row of type labels (`str`, `i64`) and a footer
line `N rows`. Python and Node would reach it through the C ABI they already call. One
implementation gives the same bytes in every form.

**The SQL command prints tables in that form.** The command needs one table form, and
`format_table`'s is the one komira has and tests. Reached through libkomira, it is the first part
of a shared printer. The SQL tree's outputs are then what a later shared printer would print in the
other forms too.

**Recommendation: one file per tree.** It changes no example that exists. It holds each program to
what that form really prints, and what a reader copies and runs prints the same. A shared printer
can be added later without moving a file. If it is, a check could then hold the trees' output files
equal for tasks that print only tables.

## 4. What runs each example

The runner contract of `documentation_tests.md` (piece 3) and the exact compare (piece 4) apply to
every form:

- a fresh, empty, writable working directory;
- no network;
- stdout compared byte for byte, with no filters;
- a failure named `<tree>/<dir>/expected_output.txt:<line>` or `<tree>/<dir>/example.<ext>:<line>`.

| | SQL | Python (exists) | TypeScript | Mojo (each form) |
|---|---|---|---|---|
| Package and macro | `python/task_examples.bzl`, `task_examples`, which gains a command form | `python/task_examples.bzl`, `task_examples` | `node/task_examples.bzl`, `npm_task_examples` | `tools/build/mojo/task_examples.bzl`, `mojo_task_examples` |
| One target per directory / per probe | `//python/docs/sql_tasks:<rank>-<slug>` / `__probe_<name>` | `//python/docs/tasks:<rank>-<slug>` / `<rank>-<slug>__probe_<name>` | `//node/docs/tasks:<rank>-<slug>` / `__probe_<name>` | `//src/<mojo library>/docs/tasks:<rank>-<slug>` / `__probe_<name>` |
| The aggregate in the check's roots | `:examples` | `:examples` | `:examples` | `:examples` |
| What the user gets | the built wheel in an empty environment, and its `komira` command | the built wheel in an empty environment of the hermetic CPython 3.13 | the packed npm package and the pinned `apache-arrow` closure, installed offline into an empty project | pull request: the library's `.mojoc` and its closure; release: the installed `.conda` |
| How it runs | `komira sql example.sql`, as the page tells a reader | `example.py` in the environment | `node example.ts` | the built program |
| Before the run | none | none | `tsc --noEmit`, strict, over `example.ts` against the installed package's `.d.ts` | the compile, with the pinned Mojo |
| Platforms in the pull request's check | linux-x86_64 | linux-x86_64 | linux-x86_64, the pinned Node 24 | linux-x86_64 |
| After merge | with the Python examples on the macOS arm64 wheel, reporting | `:examples_macos_arm64`, reporting | proposed: `:examples_macos_arm64`, in the macOS job that runs `//node:install_test_macos_arm64` today, reporting | the release's README e2e machinery, against the staged set |

**SQL.** komira has no program that runs a `.sql` file, so a stranger has no way to run a SQL
example as written (see "What exists today"). Decision 6 is the owner's. The recommendation is a
`komira sql <file>` command in the Python package, the one package published today:

- It runs the file's statements in order in one session, from the working directory.
- It prints each result in the table form of section 3, with a blank line between results.
- On the first error it writes one line, `<code>: <message>`, to stderr and exits non-zero.
- The test runs it exactly as the page tells a reader to: from the installed wheel, in an empty
  directory, with nothing else on the path.
- A SQL example makes its own input files, as every example does, with `COPY ... TO` over a query
  of literal rows. Where the engine cannot write the input the task needs, the SQL form is
  `not-shown` for that task with that reason. A task directory never holds a hidden input file.

The command is a public interface (a command, its output and its exit codes). It is named here only
so the design can be complete. The pull request that builds it is the place to set it, and the
owner rules on it there.

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

**Mojo.** In the pull request's check, `mojo_task_examples` builds each `example.mojo` against its
form's library and that library's closure. This is the compile the welded tests of source-first
README examples use. It runs the program from an empty directory through the gate and compares the
output with `expected_output.txt`. `mojo_binary`'s `expected_stdout` takes a string, and Starlark
cannot read a file, so the compare is a step of the rule that reads the file, as the other runners
do. Each Mojo form's tree uses the same rule with its own library.

The run "as a user gets the libraries" is the release's: the README e2e phases `install`, `link`,
`compile` and `run` against the staged set, with the exact compare added. A pull request cannot
stage a release set (rule B9), so that run belongs to the release. Decision 4 of
`documentation_tests.md` (a page that works on main and not on the published package says "needs
the next release") covers the time between the two.

**Probes.** A probe is `probe_<name>.<ext>` with `probe_<name>.error.txt`, one line, in each form:

- **SQL:** the command's error line, `<code>: <message>`.
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

| Form | Targets |
|---|---|
| SQL | `refuses_wrong_expected_output`, `refuses_example_that_fails`, `refuses_probe_that_runs`, `refuses_probe_with_another_error` |
| Python (exist) | `refuses_wrong_expected_output`, `refuses_example_that_raises`, `refuses_probe_that_runs`, `refuses_probe_with_another_error` |
| TypeScript | `refuses_wrong_expected_output`, `refuses_example_that_throws`, `refuses_example_that_does_not_typecheck`, `refuses_probe_that_runs`, `refuses_probe_with_another_error`, `refuses_probe_with_syntax_error` |
| Mojo (each form) | `refuses_wrong_expected_output`, `refuses_example_that_raises`, `refuses_example_that_does_not_compile`, `refuses_probe_that_runs`, `refuses_probe_with_another_error`, `refuses_probe_that_does_not_compile` |

Each tree's root files name its `:pages`, `:examples` and `:refuses_*` targets, as
`ci/roots/komira/python/docs/tasks:*` do. Adding a task directory still adds no root file.

## 5. The catalogue

`docs/tasks/catalogue.json` stays the one catalogue. A non-gap entry gains one key, `forms`:

```json
{
  "rank": 75,
  "slug": "join-value-falls-two-bounds",
  "category": "Join",
  "question": "How do I join where a value falls between two bounds?",
  "status": "works",
  "forms": {
    "sql": {"status": "not-shown", "reason": "no command a reader can run a .sql file with yet"},
    "python": {"status": "works"},
    "typescript": {"status": "works"},
    "mojo": {"status": "not-shown", "reason": "no Mojo library a user can install runs a query yet"}
  }
}
```

- `forms` has exactly the profile names as keys, today `sql`, `python`, `typescript` and `mojo`.
- **A new form is a new key.** It comes with its profile row, and with a record in every non-gap
  entry, in one commit. A second Mojo form becomes, for example, `mojo_plan`, named by the Mojo
  SDK's design. Its records start as `not-shown` with the reason it cannot be shown yet. Nothing in
  this design changes for it. If the Mojo SDK's design keeps one Mojo form, the `mojo` key is all
  there is.
- Each value has a `status` of `works`, `partial` or `not-shown`, and an optional `issues` list in
  today's `komira-ai/<repo>#<n>` form. A form's `issues` are those that block that form only: a
  missing verb in its SDK, or its package unpublished. The entry's own `issues` stay as today: the
  issues that block the task as komira does it, required for a gap and allowed for a partial entry.
  An issue may appear in both.
- A `not-shown` value also has a `reason`: one line, not empty.
- A gap entry has no `forms`. No form shows a gap.
- **What "works" means.** A form's `works` means its example does the whole task. `partial` means
  the example does part of it, and its page says which part. The entry's `status` is held equal to
  the best of its forms:
  - `works` when any form works;
  - `partial` when the best is partial;
  - an entry whose forms are all `not-shown` is refused, because it is a gap.

  So `status` keeps today's meaning, "komira does the task", and the site design still reads it
  correctly. An entry can be `works` while Python is `partial`, for example when the SQL form does
  the whole task and the Python page shows a frame verb that is missing. "Works in every form" is
  the term for the publishing bar (decision 4).
- **The bar as a report.** The output of each `:pages` target, today `<directory> <status>` per
  directory, gains a line per entry with its form statuses. It also gains a last line counting the
  entries that meet decision 4's bar and those that do not. It is a report, not a gate. It fails no
  pull request, and the site's deploy reads it.
- **Probes** follow the form. A probe in a tree is allowed when that form's status is `partial`, and
  refused when it is `works`. This replaces today's rule in `tasks.zig`, which reads the entry's
  status. Under the old rule, a Python `partial` page with probes would be refused as soon as a
  TypeScript `works` made the entry `works`.
- **Compatibility.** The catalogue is read only by this repository's checker and, once built, its
  site generator. It ships in no package. The slice that adds `forms` fills it for every non-gap
  entry in the same commit, and the checker requires it from that commit on. No reader ever sees a
  catalogue with only part of it filled. The change only adds (rule B8): no key is removed or
  re-meant, and the one new key is required only from the commit that fills it.

## 6. The checker

`tools/build/readme_examples` gets one table, `PROFILES`, in a new `profiles.zig`. The literals of
`tasks.zig` and `task_page.zig` move into it. One row per form:

| Profile | Tree | Example | Probe | Code fence word | Near misses refused |
|---|---|---|---|---|---|
| `sql` | `python/docs/sql_tasks` | `example.sql` | `probe_<name>.sql` | `sql` | `SQL` |
| `python` | `python/docs/tasks` | `example.py` | `probe_<name>.py` | `python` | `py` |
| `typescript` | `node/docs/tasks` | `example.ts` | `probe_<name>.ts` | `typescript` | `ts` |
| `mojo` | none until its tree lands | `example.mojo` | `probe_<name>.mojo` | `mojo` | `Mojo` |

Every profile has `expected_output.txt` (`text`), `page.md` and `probe_<name>.error.txt`. A second
Mojo form is one more row, with its own tree, the same file names and the same fence word. Two rows
may share a fence word; no two rows share a tree.

- **The new flag.** `tasks-check` takes `--profile <name>`, and it is required. Each tree's `:pages`
  target passes its own. `task_pages_check` and the helpers `task_dirs` and `task_probes` move to a
  shared `.bzl`, with the probe extension as an argument.
- **What stays strict, for every profile.**
  - Directory names are `<rank>-<slug>`, and the rank matches the entry.
  - A gap has no directory.
  - A directory holds exactly the three files and probe pairs, and nothing else. A `.py` in the Node
    tree is refused as an extra file, and so is an `example.ts` in the Python tree or an
    `example.py` in the SQL tree.
  - A probe's error file is one line ended by a line feed.
  - The page's title is the question.
  - The page includes the profile's example and `expected_output.txt`, each byte for byte.
  - A file name in an include has no `/`.
  - A shown file has no carriage return.
  - A `text` fence after code needs an include or `not-tested`.
- **New page rules, for every profile.** Each code word of every profile needs an include or
  `not-tested`; today only `python` does. The near-miss words of the table are refused by name,
  naming the word to use. Today no fence word is refused. A `sql` fence on a Python page, which
  today passes unchecked, then needs a marker too. No Python page has one today
  (`grep -l '^```sql' python/docs/tasks/*/page.md` finds none).
- **New catalogue rules** (section 5), checked by every tree's run, because every run reads the
  whole catalogue:
  - the form of `forms`;
  - `status` equal to the best form status;
  - an entry with every form not shown is refused.
- **New rules for a tree's own form.** Each tree's run checks its own profile's form:
  - every directory's entry has that form `works` or `partial`;
  - every entry with that form `works` or `partial` has a directory;
  - a probe needs that form `partial`.

  For a profile with no tree (Mojo today), every run refuses an entry that marks that form as
  shown. A Mojo row gets its tree in the same pull request that adds the tree's BUCK file. That BUCK
  file's `:pages` names the Mojo library its examples import. Its analysis fails when that library
  is not a package of `release/readme_e2e/packages.bzl`, so no Mojo tab is shown for a library a
  reader cannot install. Until the row names a tree, nothing reads a stray directory under `src/`.
  The site draws tabs only from the trees the profile table names, so such a directory is never
  shown.
- **Why each tree runs its own check, not one check over all of them:** the Python tree's files
  cannot be read by a target outside `python/` (`//:python_closure`). Each run checks the whole
  catalogue and its own form, and no claim goes unchecked. A form is shown only when its tree's run
  has found the directory. The catalogue file and the checker tool are declared inputs of every
  tree's `:pages`. A pull request that changes only the catalogue, or only
  `tools/build/readme_examples`, reaches every tree's `:pages` through the build graph and runs them
  all.
- **Its tests.** The checker's unit tests (`tasks_test.zig`, `task_page_test.zig`) gain the cases in
  [What each check proves](#what-each-check-proves). One profile fixture per rule, each asserting
  the exact refusal text.

## 7. Out of scope here, and decided elsewhere

Two choices are made elsewhere. This design holds for either answer:

- **Which API the TypeScript and Mojo examples use:** SQL only for now, or frame APIs too. The
  TypeScript package today runs SQL. A DataFrame builder is "explicitly later" in
  [typescript_package.md](typescript_package.md).
- **What the Mojo SDK is, and its forms.** One choice is a public library with a session and `sql`
  over `sdk_exec`. Another is an untyped SDK whose code builds a physical plan directly instead of a
  logical one. It may be both, as two forms. Its design also decides when the libraries are
  published.

| | SQL only | Frame APIs too |
|---|---|---|
| Layout, file names, page rules, checker, runners, catalogue keys | as above | as above |
| How many tasks each form shows | fewer: a task whose example needs a frame is `not-shown` or `partial` in TypeScript and Mojo (rank 60's Python example calls no SQL: a text search of its `example.py` for `sql` and `SELECT` finds none) | more, once the frame API exists |
| The SQL form | carries most of the tasks, and a TypeScript or Mojo example often runs the same statements | the same; the SDK forms show more than the SQL form |
| Probes | a probe can only try SQL, since a frame call that does not exist is a type or compile error, not a run failure | a probe can try a frame verb that is refused by name at run time |
| A shared printer (section 3) | less useful: each example prints a few rows | more useful: printing a frame wants one form |

| | One Mojo form | Two Mojo forms (session and SQL; physical-plan builder) |
|---|---|---|
| Trees | one, in its library's package | two, one per form (section 1) |
| Profiles and catalogue keys | `mojo` | `mojo` and one more, named by the Mojo SDK's design |
| Runner | `mojo_task_examples` against the library | the same rule, each tree against its own library |
| Tabs | one Mojo tab | two, in the order that design lists the forms |

A Mojo profile's tree is set only when its library is published (it is in
`release/readme_e2e/packages.bzl`). A page shows only what a reader can install and run. A Mojo
example built against the unpublished `sdk_exec` in this repository would pass the pull request's
check and fail for every reader.

## 8. The slices, in order

1. **One task in Python and TypeScript, with SQL and Mojo marked not shown.** The task is rank 75,
   `join-value-falls-two-bounds`. Its status is `works`. Its Python example is SQL only, over two
   small CSV files, and prints only integers and strings, with no probes. The slice holds:
   - `PROFILES` with `python` and `typescript`, and `sql` and `mojo` with no tree;
   - `--profile`;
   - the catalogue rules;
   - `forms` filled for all 80 non-gap entries:
     - Python copies today's `status`;
     - TypeScript is `not-shown`, "no TypeScript example yet", except rank 75;
     - SQL is `not-shown`, "no command a reader can run a .sql file with yet";
     - Mojo is `not-shown`, "no Mojo library a user can install runs a query yet";
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

   SQL is not in this slice because nothing a reader can install runs a `.sql` file today. If review
   asks for the checker change to land first (P7), this is two pull requests: the profile and
   catalogue rules, then the runner and the task.
2. **The SQL command and rank 75's SQL example**, once decision 6 is ruled:
   - the command;
   - the SQL tree's `sql` profile row and its tree;
   - the SQL runner and its four `refuses_*` targets;
   - `python/docs/sql_tasks/75-join-value-falls-two-bounds/`;
   - rank 75's `sql` record set to `works`.

   This is the first task with every form a reader can run today.
3. **The site design follows main.** komira-ai/komira#2352 moves to the names of section 1. This is
   a document only and can land beside slices 1 and 2.
4. **SQL and TypeScript examples in batches**, for tasks the Python tree already shows. Each batch
   adds its directories and changes the records of the same entries. No batch touches the Python
   tree.
5. **The Mojo SDK and its forms** (section 7): its design, then publishing its closure. That work
   is not planned here.
6. **A Mojo tree per form.** Each comes once its library from slice 5 is published:
   - the profile's tree (and, for a second form, its profile row and catalogue key);
   - `mojo_task_examples` and its six `refuses_*` targets;
   - the first task in that form;
   - the compare phase in the release's README e2e machinery;
   - the records of the tasks it shows.
7. **A shared printer for the other forms**, only if decision 3 is ruled that way.

## What each check proves

Every row has a negative case that must go red and name the line or the entry.

| Check | Defect it catches | Negative case |
|---|---|---|
| Profile: files | an example of another form, or a stray file, in a tree | a `.py` in the Node tree; an `example.py` in the SQL tree; an `example.ts` with no `expected_output.txt` |
| Profile: fences | an unchecked program on a page | an unmarked `typescript` fence; an unmarked `python` fence on a TypeScript page; an unmarked `sql` fence on a Python page; a `ts` or `SQL` fence |
| Profile: include | a page that shows another program than the one that ran | one changed byte of `example.ts` in the page |
| Catalogue: `forms` | a form left out without a word | a non-gap entry with no `mojo`; a `not-shown` with no reason; a key no profile names |
| Catalogue: status | an entry whose word disagrees with its forms | `status` `works` with every form `partial`; every form `not-shown` on a non-gap entry |
| Tree against catalogue | a tab with no tested example, or a tested example the catalogue hides | `typescript` `works` with no directory, the catalogue the only file changed; a directory with `typescript` `not-shown`; `mojo` shown while the profile has no tree |
| Probes per form | a probe rule that reads the wrong status | a Python `partial` directory with probes whose entry is `works` through TypeScript passes; a probe in a `works` form is refused |
| Mojo tree's library | a Mojo tab for a library a reader cannot install | a Mojo `:pages` naming a library that is not in `release/readme_e2e/packages.bzl` fails analysis |
| SQL run | changed output, a failing statement, a probe that passes or fails another way | the four `refuses_*` targets |
| TypeScript run | changed output, a throw, a type error, a probe that passes, fails another way or fails on a syntax error | the six `refuses_*` targets |
| Mojo run | changed output, a raise, a compile error, a probe that passes, fails another way or does not compile | the six `refuses_*` targets, for each form |

## Decisions for the owner

1. **Where the examples live.**
   - (a) One tree per form, joined by slug: main's tree per language, with a language of two
     surfaces getting two trees. komira-ai/komira#2352 moves to main's names.
   - (b) One `docs/tasks/<rank>-<slug>/` per task with every form's files, as komira-ai/komira#2352
     has it. That needs `docs/tasks` added to the Python surface of `//:python_closure`, and new
     names for the files of a second form of one language. It also changes the rule that
     `docs/tasks/README.md` and `documentation_tests.md` (piece 2) state today.

   **Recommendation: (a).**
2. **Where a form that does not show a task says so.**
   - (a) In the catalogue, as a `not-shown` record with a reason.
   - (b) In a stub `page.md` of one new marker line in that form's tree.

   **Recommendation: (a).** No new marker word, and no directory without an example.
3. **Expected output.**
   - (a) One file per tree, each form printing in its own way.
   - (b) One file every form prints byte for byte, through a printer bound into Python and Node over
     the Mojo `format_table`.

   **Recommendation: (a)**, with (b) open as a later addition that moves no file. The SQL command of
   decision 6 prints in `format_table`'s form, which starts (b) without making it a rule.
4. **The publishing bar for komira.dev.**
   - (a) Every non-gap task works in every form.
   - (b) Every non-gap task is shown in every form, or not shown with a reason that names an issue.
     A reason with no issue, such as "no TypeScript example yet", never meets the bar.

   **Recommendation: (b).** The `:pages` report counts it (section 5), and a form's limit stays
   tracked work, not a silent hole. (b) still means each Mojo form must show every task its
   published library can do.
5. **The Mojo run in the pull request's check.**
   - (a) Against the library and its closure as the build holds them. The run against the installed
     `.conda` comes at release.
   - (b) Against an installed staged set in every pull request.

   **Recommendation: (a).** Staging a release set in a pull request is a release dry run, which
   rule B9 refuses. Either way, a Mojo tree exists only once its library is published (section 6),
   so (a) never shows a page a reader cannot run.
6. **What runs a SQL example, as a stranger would run it.** komira has no command that runs a `.sql`
   file today.
   - (a) A `komira sql <file>` command in the Python package. It runs the statements in order and
     prints each result in `format_table`'s table form. The test runs it from the installed wheel
     exactly as the page tells a reader to. The SQL tree is `python/docs/sql_tasks/`.
   - (b) No new program. The harness runs `example.sql` through the Python SDK's `sql()`, and the
     page tells a reader to paste the statements into any SDK's `sql()`. What the test prints is
     then the harness's printer, which no reader runs.
   - (c) A standalone SQL shell, a native program built from the engine and released on its own,
     as DuckDB's is. Its tree sits in its own package. It is a new release artifact on three
     platforms, and the engine closure it needs is unpublished.

   **Recommendation: (a).** It is the smallest program a stranger can run after one install from
   the one published package, and its test runs what the reader runs. (c) can follow, reusing the
   same tree and outputs if it prints the same form. (b) shows output no reader can get by the
   route the page gives.
