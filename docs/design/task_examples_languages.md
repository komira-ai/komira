# Task examples in SQL, Python, TypeScript and Mojo

Status: design, not built. One question is for the owner, at the end. This document adds SQL,
TypeScript and Mojo examples to the task pages of [docs/tasks/README.md](../tasks/README.md). It
uses the framework of [testing the code in our documents](documentation_tests.md): the same
markers, the same checker and the same kind of targets. Where that framework already has a rule,
this document applies the rule and does not make a new one. Counts are from main of this
repository, and each count names how it was taken. *[est]* marks an estimate.

It is a separate document, not a section of `documentation_tests.md`. That document's decisions
are already taken, and a separate page leaves the accepted text alone. `documentation_tests.md`
lists TypeScript as held: it "needs a contract this doc does not write". This document is that
contract for task pages. Package READMEs and SDK pages in TypeScript are not covered. The Mojo SDK
itself is the subject of the Mojo SDK design (komira-ai/komira#2496, open); this
document uses what that design proposes and says where the two meet.

## The gate this design serves

The owner's gate for publishing komira.dev: "we need to have the examples working in all 3
languages: python, typescript, and mojo". He added SQL to it later. So every task page has to show
a tested example in SQL, Python, TypeScript and Mojo. What the gate means for a task that one of
them cannot do yet is the first question at the end. The count of such tasks is in
[What each form can show](#what-each-form-can-show).

## Words used here

- **Task**: one entry of `docs/tasks/catalogue.json`, a question such as "How do I read a CSV
  file?", with a rank and a short name (its *slug*, `read-csv-file`).
- **Form**: one way to write a task's program, a language and the part of komira it uses. There are
  five: `sql`, `python`, `typescript`, `mojo` (the Mojo session) and `mojo_plan` (the Mojo plan
  builder, section 7).
- **Tree**: the folder that holds one form's examples, one sub-folder per task, named
  `<rank>-<slug>`. `python/docs/tasks/` is the Python tree.
- **Page**: the `page.md` in a task's folder: the question, the program, what it prints, and notes.
- **Tab**: on the site, one task has one page with a tab per form; clicking a tab shows that form's
  page.
- **Probe**: a program written the way a task would be done if komira could do it, with the one
  error line it fails with today. When it starts to work, its test fails, so the page is updated.
- **Profile**: the checker's settings for one form: its tree, its file names, its fence word.
- **Welded test**: a test built into a library's own build, so the library is not produced at all
  if the test fails.
- **Slice**: one step of the work, landed as one pull request or a few. Section 8 lists them in
  order.
- **Shown / not shown**: a task is shown in a form when that form's tree has its folder and the
  folder's program passes its test. Otherwise the catalogue records it as not shown, with a reason.

## The answer

1. **One tree per form, joined by slug.** A tree sits in the package whose runner runs its
   examples: Python in `python/docs/tasks/` (exists), TypeScript in `node/docs/tasks/`, Mojo in
   `src/komira/docs/tasks/` (the package the Mojo SDK design, komira-ai/komira#2496, proposes),
   the Mojo plan builder in `src/komira/docs/mojo_plan_tasks/`, and SQL in
   `python/docs/sql_tasks/`, beside the Python lines that run it. Each task folder keeps exactly `example.<ext>`,
   `expected_output.txt` and `page.md`, as today. The open komira.dev design
   (komira-ai/komira#2352) moves to these names.
2. **One page per form.** Each page shows its form's program and output through the include markers
   that exist. The site joins a task's pages into one page with a tab per form. A form that does not
   show a task says so in the catalogue, with a reason.
3. **One expected output per form.** Each tree keeps its own `expected_output.txt`, because each
   language prints in its own way.
4. **One test per example, in its own form, each with targets that must fail.** Python stays as it
   is. TypeScript gets a new verb of the Node tool: it installs the packed package the way the
   install test does, type-checks `example.ts`, runs it from an empty folder and compares what it
   prints with `expected_output.txt`. Mojo gets a rule that builds `example.mojo`, runs it and
   compares the output the same way. A `.sql` file has no program of its own: a few lines of the Python
   SDK and the same in TypeScript run its statements through `sql()`, the page shows those lines,
   and both runs compare what they print with the one `expected_output.txt`.
5. **The catalogue records each form.** A non-gap entry gains `forms`, with one status per form:
   `works`, `partial`, or `not-shown` with a reason. A new form is a new key.
6. **The checker gets a profile per form** in `tools/build/readme_examples`. Every rule that holds
   today stays and applies to each profile.
7. **Which API the TypeScript and Mojo examples use is decided elsewhere.** The layout, checker,
   runners and catalogue are the same whatever is decided.
8. **The first slice** makes rank 75 hold and test its Python and TypeScript examples, with SQL and
   Mojo recorded as not shown and why.

## What exists today

| Fact (main) | Count, and how it was taken |
|---|---|
| Catalogue entries: `works` / `partial` / `gap` | 45 / 35 / 20, counted from `docs/tasks/catalogue.json` |
| Python task folders | 80, `ls -d python/docs/tasks/*/`: one per non-gap entry |
| Python examples that hold SQL text | 79 of the 80, `grep -l "sql(" python/docs/tasks/*/example.py`; rank 60's holds none |
| Python examples that call no frame API | 16, by a text search of `example.py` for `komira.read_`, `.pl.`, `df.`, pandas and polars (a search, not a run) |
| SQL, TypeScript or Mojo task folders | 0 |

- **The Python tree** is built ([docs/tasks/README.md](../tasks/README.md)).
  - `tasks-check` of `//tools/build/readme_examples:tool` holds the catalogue against the tree.
  - `//python/docs/tasks:<rank>-<slug>` runs each `example.py` from the built wheel. The wheel is
    installed in an empty environment, the program runs from an empty folder, and the output is
    compared byte for byte (`python/task_examples.bzl`, `python/tests/run_task_example.py`).
  - Four `refuses_*` targets prove that the runs can fail.
- **What `docs/tasks/README.md` says today, and what this design changes in it.** It says a
  TypeScript tree (under `node/`) or a Mojo tree (under `src/`) "joins the same tasks by slug, with
  no change to the catalogue or to another language's tree". This design changes the catalogue (a
  `forms` record per task, section 5) and the Python tree's check (a `--profile` flag, section 6).
  It also names the Mojo tree's path. Slice 1 rewrites those lines of the README to match.
- **The Python-only places in the checker.**
  - `tasks.zig`: `FILES` and the probe suffix `.py`. A file outside the list is refused with "a task
    directory holds only example.py, expected_output.txt, page.md and probe_&lt;name&gt;.py with
    probe_&lt;name&gt;.error.txt". The catalogue's `KEYS` refuses any key it does not list.
  - `task_page.zig`: `EXTENSIONS` (`.py` to `python`, `.txt` to `text`), `SHOWN`, and the rule
    that an unmarked `python` fence is refused, with the word `python` spelled out in the code.
  - `tasks-check` takes no language argument.
- **Python files outside `python/`.** The graph check `//:python_closure` allows Python only in its
  surface (`tests/python_closure_allowlist.bzl`: `python`, `tools/build/examples/python_binding`,
  `.github/workflows/pypi.yml`), plus a list of findings allowed today that may only shrink.
  - 10 `.py` files exist outside `python/` (`git ls-files '*.py' | grep -v '^python/'`): fixture
    generators, oracle helpers and one test peer. One is in the surface; the check passes on main,
    so the others are on that list.
  - A new `.py` file outside the surface is refused.
  - So is a new target outside it whose closure holds a `.py` source or a Python rule. A test that
    installs the wheel is such a target.
- **No command runs a `.sql` file.**
  - The Python package declares no command; `python/` has no `[project.scripts]` or entry point by
    a text search.
  - The Node package's `package.json` has no `bin`.
  - The only Mojo programs a package declares (`bins` in a `src/*/mopm.toml`) are a benchmark's.
  - A reader runs SQL only through an SDK's `sql()`, and the owner has ruled that it stays so: no
    new program runs a `.sql` file. The engine parses `COPY ... TO`
    (`src/sql/sql_parser.mojo`), and three Python examples use it to write files.
- **The one `files` source.** Python has `komira.files(location, ...)` (`python/komira/_sources.py`),
  which `Session.add_sql_binding` binds to a SQL name. It reads Parquet today. The Mojo SDK
  design proposes the same `files` for Mojo, Parquet only until its slice 6 adds CSV and JSON.
  TypeScript has no `files` yet: it has `registerParquet`. Every form that runs SQL text can read a
  CSV or JSON file in the SQL itself, `read_csv('<file>')`, without `files`.
- **TypeScript.**
  - `//node:install_test` is `npm_install_test` (`tools/build/node/defs.bzl`), run by
    `node_act install-test` (`tools/build/node_tools/node_act.zig`). It copies the test files into
    an empty project and installs the packed package and the pinned tarballs of `apache-arrow` and
    its closure with `npm install --offline --ignore-scripts --engine-strict`. Then it runs
    `node --test` on Node 22, 24 and 26.
  - Its pass rule needs a registered `node:test` test in each file, so a plain program cannot run
    through it as it is.
  - Node runs a `.ts` file outside `node_modules` by stripping its types, with no flag, from Node
    22.18 ([typescript_package.md](typescript_package.md), "Tests in `.ts`"). The package accepts
    Node 22.12 and later (`engines` in `node/package.json`). So on Node 22.12 to 22.17,
    `node example.ts` needs `--experimental-strip-types`.
  - The public API is `Session`, `registerParquet`, `sql` and `Result`. `Result.toArrow()` gives an
    `apache-arrow` `Table`. `registerCsv` and `registerNdjson` check their arguments and then reject
    with `UnsupportedOperation`. A CSV file is read in the SQL text as `read_csv('<path>')`.
  - The package is not published: `release/npm_publish.txt` says `publish: off`, and the name
    `@komira-ai/komira` is a placeholder until the npm name is ruled
    ([typescript_package.md](typescript_package.md)).
- **Mojo.**
  - README examples run as welded tests in each library's build. For a package of
    `release/readme_e2e/packages.bzl`, the release also runs them against the installed `.conda`
    ([readme_e2e](../../tools/build/readme_e2e/README.md)). That run judges an example by its exit
    status only; nothing compares what it prints.
  - `mojo_binary(expected_stdout = "...")` compares a program's output with a string, not a file.
  - `sdk_exec` runs SQL over Parquet, CSV and local Iceberg (`run_sql`, `EngineContext`).
  - `src/sdk/table_display.mojo` has
    `def format_table(batch: RecordBatch, max_rows: Int = 20) raises -> String`.
  - `sdk` and `sdk_exec` are unpublished because they depend on unpublished libraries, and so is
    the engine closure `sdk_exec` imports ([release/UNPUBLISHED.md](../../release/UNPUBLISHED.md)).
    `arrow` has no blocker there; it is not yet in `release/readme_e2e/packages.bzl`. No library
    a user can install runs a query.
  - The Mojo packages are not built for linux-arm64 (the Mojo SDK design, komira-ai/komira#2496,
    its platform row). This is listed with the gate's exceptions (question 1).

## What each form can show

How many of the 80 tasks Python shows could each other form show, with what exists or is designed
today. A range is given where only a run of each example would give the exact number. Every number
here comes from one text search over the 80 Python examples, run from the repository's root:

```sh
cd python/docs/tasks && for f in */example.py; do r=${f%%-*}
  grep -q -E 'komira\.read_|\.pl\.|df\.|pandas|polars' "$f" || echo "$r sql-only"
  grep -q 'sql(' "$f" || echo "$r no-sql"
  grep -q -E 's3://|gs://|az://|credential' "$f" && echo "$r cloud"
  grep -q '^import sqlite3' "$f" && echo "$r sqlite3"
done | sort -n
```

Today it prints 16 `sql-only` lines (the examples that use no frame API), `60 no-sql`, `31 cloud`,
`93 cloud`, and `22`, `89` and `90 sqlite3`. Those last six are the tasks SQL cannot show for a
reason other than work not yet done: rank 60's example holds no SQL; ranks 31 and 93 read cloud
storage with a credential, which SQL text cannot name; ranks 22, 89 and 90 store rows with Python's
`sqlite3`.

| Form | Shown today | Not shown when its first examples land, and why |
|---|---|---|
| Python | 80 (45 `works`, 35 `partial`) | 0. The 35 `partial` ones do part of their task |
| SQL | 0 | between 6 and 69. At least the 6 of the search above. At most 69: of the 16 `sql-only` examples, 5 are among those 6 (22, 31, 89, 90, 93), so 11 can be written as SQL as they stand; each of the other 63 must be rewritten to see whether SQL can do it *[est]* |
| TypeScript | 0 | between 6 and 69, the same 6 (the package has no credentials and no database writes yet), and the same rewrite for the rest *[est]* |
| Mojo, the session | 0 | the same range as SQL, between 6 and 69: it runs SQL text, so it reads CSV and JSON through `read_csv('<file>')` as SQL and TypeScript do. Ranks 31 and 93 need a credential, which the session gets only with the Mojo SDK design's slice 7 (remote files) |
| Mojo, the plan builder | 0 | all 80 until the builder exists (the Mojo SDK design) |

Rank 75 reads two CSV files. Its Mojo session example reads them with `read_csv('<file>')` in the
SQL text, as its TypeScript example does, so it can be shown as soon as `komira` is published.

## 1. Where the examples live, and what they are called

The layout is one tree per form, joined by slug:

```text
docs/tasks/catalogue.json                    the one catalogue, as today
python/docs/tasks/<rank>-<slug>/             form python
    example.py    expected_output.txt  page.md  [probe_<name>.py    probe_<name>.error.txt]
node/docs/tasks/<rank>-<slug>/               form typescript
    example.ts    expected_output.txt  page.md  [probe_<name>.ts    probe_<name>.error.txt]
src/komira/docs/tasks/<rank>-<slug>/         form mojo (the session)
    example.mojo  expected_output.txt  page.md  [probe_<name>.mojo  probe_<name>.error.txt]
src/komira/docs/mojo_plan_tasks/<rank>-<slug>/   form mojo_plan (the plan builder)
    example.mojo  expected_output.txt  page.md  [probe_<name>.mojo  probe_<name>.error.txt]
python/docs/sql_tasks/<rank>-<slug>/         form sql
    example.sql   expected_output.txt  page.md  [probe_<name>.sql   probe_<name>.error.txt]
```

Why this layout, and not the other two:

- **One folder per task holding every form's files** (komira-ai/komira#2352's layout) would put
  `example.py` under `docs/`. `//:python_closure` refuses a new `.py` file there, and refuses a
  target there that installs the wheel. It would also need new file names for a second Mojo form.
- **One page folder that includes examples from the form trees** would need a new include path form
  (`/` and `..` are refused today), and a checker reading several packages at once. The Python
  tree's files can be read only from inside `python/`.
- **One tree per form** is what `docs/tasks/README.md` and `documentation_tests.md` (piece 2)
  already say for languages, the way the AWS code examples are laid out
  ([documentation_tests.md](documentation_tests.md#what-we-take-from-whom)). Every folder keeps one
  example, so the folder rules of `tasks.zig` hold as they are, and each tree's tests live in the
  BUCK file of the package they install.

Where each tree sits:

- **The Mojo tree** sits in the package of the library its examples import, `komira`
  (`src/komira/`), as the Mojo SDK design (komira-ai/komira#2496) proposes (its decision D1). If that name
  changes, the path follows it. If `//:src_layout` reads the nested package as one of its own, the
  slice that adds the tree adds its row to [docs/architecture.md](../architecture.md).
- **The plan builder** (section 7) is a second tree in the same package,
  `src/komira/docs/mojo_plan_tasks/`, with its own tab.
- **The SQL tree** is `python/docs/sql_tasks/`, beside `run_sql.py`, the Python lines that run it.
  Its per-task runs install the wheel, which `//:python_closure` allows only under `python/`, and
  they are declared from a glob of the tree's own folders, which only the tree's own BUCK file can
  read. The Node run reads the same files from another package through a filegroup that holds no
  Python.

**What komira-ai/komira#2352 changes**, so the two documents agree. The site generator reads what
the checker already holds:

- The catalogue is `docs/tasks/catalogue.json`, not a new `docs/tasks/tasks.tsv`.
- The pages come from the form trees, not from `docs/tasks/<rank>-<slug>/`.
- Folder names are `<rank>-<slug>` with no padding (`4-group-by-column-and-sum`), with the slug from
  the catalogue.
- The page is `page.md`, not `README.md`. Its title and include markers follow the page rules.
- The output is `expected_output.txt`, compared byte for byte. It is not `example.expected`, and it
  has no `<version>` or `<cwd>` filters. Those exist for the quickstart only.
- The stored status words are `works`, `partial` and `gap`, and each form has its own (section 5).
  The site may show a gap under another word. That is display, and the stored word stays.
- A tab is drawn for every form. A form that does not show a task draws its not-shown reason from
  the catalogue. The generator refuses a task whose tabs differ from the catalogue's form records,
  so a tab can be neither dropped nor added outside the catalogue.
- komira-ai/komira#2352's rule that a TypeScript tab waits for the npm row of its install table to
  leave "not yet" stays, for every form. A form's tab shows its example only once the package that
  runs it is published. Until then the tab shows the line "not published yet". Its examples are
  still tested in every pull request, so they are right on the day the package ships.
- The deploy's run of the task programs on the released artifact, and its rule that a failing task
  is left out and listed, apply to each form's released package: the wheel, the npm package, the
  Mojo `.conda`; the SQL form runs on the wheel and the npm package.

## 2. The page

Each page shows one form. The page rules of `task_page.zig` apply as they are, with the file names
and fence word of the tree's profile (section 6):

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

- The first line is `# ` and the catalogue's question, the same on every form's page.
- Every page includes its own example (`example.sql`, `example.py`, `example.ts` or `example.mojo`)
  and `expected_output.txt`. The fences are `sql`, `python`, `typescript` or `mojo`, then `text`.
- A fence that shows no file has `<!-- not-tested: <reason> -->` on the line before it. Today only
  `python` fences need an include or that marker. Under this design, every code word of every
  profile needs one, so a TypeScript page cannot slip in an unchecked Python or SQL fence. A `text`
  fence that directly follows code needs one too, as today.
- The SQL page shows the statements and their output, then the two run files through include
  markers, as section 4 says.
- The TypeScript page says it needs Node 22.18 or later, where Node runs a `.ts` file as written.
- The answer line, the notes and the related links are the page's own. They differ by form (`None`
  in Python, `null` in TypeScript). Related links point to the same tree (`../<folder>/page.md`).
- **A form that does not show a task** has no folder and no page in its tree. Its line is the
  catalogue's `not-shown` record (section 5): one reason, and the issues that would lift it. The
  site draws that reason in the tab. Nothing is left out without saying so: the checker refuses a
  non-gap entry with no record for a form. A page in one tree says nothing about the other forms;
  the catalogue and the site, which joins the pages, hold that, and the site generator's refusal
  (section 1) keeps the two the same.
- **Tab order.** The design proposes SQL first, then Python, TypeScript, the Mojo session and the
  Mojo plan builder: SQL is the one
  form every SDK runs as written (79 of the 80 Python examples hold SQL text), and a reader who
  knows SQL needs no SDK to read it. The order is the site's to set, and the order of the profile
  table carries whatever it sets.

The reason lives in the catalogue, not in a stub page. A stub folder in each tree for every task
the form does not show, holding a `page.md` of one marker line, would need a new marker word in a
public format, and about 240 stub folders *[est: 80 tasks × 3 forms beyond Python]* before the first
new example lands. A tree would also hold folders with no example, which the checker refuses today.

## 3. Expected output, and how each form prints a table

Each tree keeps its own `expected_output.txt`, and each form prints the way a reader of that
language would:

| Form | What it prints |
|---|---|
| SQL | what `run_sql.py` and `run_sql.ts` print, the same bytes from both: per statement, a line of column names, then a line per row, tab-separated, a null as `NULL` (section 4) |
| Python | as today: `to_pylist()` dict reprs (`{'id': 1, 'name': 'Ana'}`), `None`, `7.0`, dtype names (`int64 float64`). Each of the 7 lines of rank 1's `expected_output.txt` (read by hand) is Python `print` output of a dict, a list or dtype names |
| TypeScript | the values the example reads from the `Table`, with `console.log`. `Result` has no printer. `apache-arrow` gives an Int64 value as a `bigint` *[inferred, not measured here]*. Slice 1 fixes the exact form by running rank 75 |
| Mojo | `print(result)`, as the Mojo SDK design (komira-ai/komira#2496) proposes (§1 there): `Result` prints itself through `sdk`'s `format_table` |

For Mojo, `format_table` (`src/sdk/table_display.mojo`) prints an ASCII box with a row of column names, a row
of type labels (`str`, `i64`) and a footer line `N rows`. Its unit test
`test_exact_table_alignment` (`src/sdk/tests/test_table_display_direct.mojo`) holds that text
exactly.

One output file that every form prints byte for byte is not part of this design. It would need a
printer on Python's and Node's `Result`, an API komira would invent, and every Python output would
change. If that is wanted later, it is proposed then, and no file moves.

## 4. What runs each example

The runner contract of `documentation_tests.md` (piece 3) and the exact compare (piece 4) apply to
every form:

- a fresh, empty, writable working folder;
- no network;
- stdout compared byte for byte with `expected_output.txt`, with no filters;
- a failure named `<tree>/<folder>/expected_output.txt:<line>` or `<tree>/<folder>/example.<ext>:<line>`.

| | Python (exists) | TypeScript | Mojo | SQL |
|---|---|---|---|---|
| Rule | `task_examples` in `python/task_examples.bzl` | `npm_task_examples` in `node/task_examples.bzl` | `mojo_task_examples` in `tools/build/mojo/task_examples.bzl` | `task_examples` in `python/task_examples.bzl`, running `run_sql.py`; and one Node target |
| One target per folder / per probe | `//python/docs/tasks:<rank>-<slug>` / `<rank>-<slug>__probe_<name>` | `//node/docs/tasks:<rank>-<slug>` / `__probe_<name>` | `//src/komira/docs/tasks:<rank>-<slug>` / `__probe_<name>` | `//python/docs/sql_tasks:<rank>-<slug>` / `__probe_<name>`; `//node/docs:sql_tasks` for all |
| The one target in the check's root files | `:examples` | `:examples` | `:examples` | `:examples` |
| What the user gets | the built wheel in an empty environment of the hermetic CPython 3.13 | the packed npm package and the pinned `apache-arrow` closure, installed offline into an empty project | pull request: the `komira` library and its closure as the build holds them; release: the installed `.conda` | the built wheel, and the packed npm package, each as for its own form |
| Before the run | none | `tsc --noEmit`, strict, over `example.ts` against the installed package's `.d.ts` | the compile, with the pinned Mojo | none |
| Platforms in the pull request's check | linux-x86_64 | linux-x86_64, the pinned Node 24 | linux-x86_64 | linux-x86_64 |
| After merge | `:examples_macos_arm64`, reporting | proposed: `:examples_macos_arm64`, in the macOS job that runs `//node:install_test_macos_arm64` today, reporting | the release's README e2e machinery, against the staged set | with its package's other macOS tests |

**TypeScript.** `node_act` gets a verb `run-task-example`, written in Zig like the rest of the tool.
It does the install step of `install-test`: an empty project, the package tarball, the pinned
tarballs, and `npm install --offline --ignore-scripts --engine-strict`. Then it does three things:

1. It copies `example.ts` into the project, so that its import of the package by name resolves to
   the project's `node_modules`.
2. It type-checks the file with the TypeScript compiler of `//node/devtools:modules`. A type error is
   named `example.ts:<line>:<col>`. Node strips types without checking them, so without this step a
   page could show a program that runs but does not compile in a reader's editor.
3. It runs `node <project>/example.ts` with a new empty folder as the working folder and the
   environment `install-test` already cleans, and compares the output with `expected_output.txt`.

A thrown error is named `example.ts:<line>: threw <name>: <message>`, the line taken from the first
stack frame in the file. The examples run on one Node line, the pinned 24, as Python's run on one
CPython. The install test keeps covering Node 22, 24 and 26.

**Mojo.** This design owns the Mojo task runner, for both Mojo forms; the Mojo SDK design
(komira-ai/komira#2496) uses it. The README e2e checks only that a program exits cleanly, and task
pages need the printed table compared too. The compare is part of slice 5. So:

- In the pull request's check, `mojo_task_examples` builds each `example.mojo` against `komira` and
  its closure, the same compile the welded tests of README examples use. It runs the program from
  an empty folder and compares the output with `expected_output.txt`. `mojo_binary`'s
  `expected_stdout` takes a string, and Starlark cannot read a file, so the compare is a step of the
  rule, which reads the file, as the Python and Node runners do.
- At release, the README e2e's phases `install`, `link`, `compile` and `run` build and run the same
  file against the installed `.conda` from the staged set, with this compare added as a phase. That
  is the run "as a user gets the libraries". A pull request cannot run it: staging a release set in
  a pull request is a release dry run, which rule B9 of [AGENTS.md](../../AGENTS.md) bars (a pull
  request runs only the build and the unit tests).
  Decision 4 of `documentation_tests.md` (a page that works on main and not on the published package
  says "needs the next release") covers the time between the two.
- A Mojo example prints with `print(result)`, as the Mojo SDK design's examples do. `print(result)`
  writes `format_table`'s text, and `format_table` is declared `raises`; what `print(result)` does
  when formatting fails is the sentence on it in that design's section on `Result`. An example's
  `expected_output.txt` holds only what a successful print writes. An example also makes its own
  input with `COPY ... TO`, as that design's README example does.

**SQL.** No program of its own runs a `.sql` file: the owner has ruled that the SDKs' `sql()` runs
it. So the SQL form is run by a few lines of an SDK, and the page shows those same lines. There are
two such files, each kept once for the whole SQL tree:

- `python/docs/sql_tasks/run_sql.py`, which the Python run executes exactly as written:

  ```python
  import komira

  with komira.Session() as s:
      for statement in filter(str.strip, open("example.sql").read().split(";\n")):
          table = s.sql(statement).to_arrow()
          print("\t".join(table.column_names))
          for row in table.to_pylist():
              print("\t".join("NULL" if v is None else str(v) for v in row.values()))
  ```

- `node/docs/run_sql.ts`, the same in TypeScript, which the Node run executes exactly as written:

  ```typescript
  import { readFileSync } from "node:fs";
  import { Session } from "@komira-ai/komira";

  const s = new Session();
  for (const statement of readFileSync("example.sql", "utf8").split(";\n").filter((q) => q.trim())) {
    const table = await (await s.sql(statement)).toArrow();
    const names = table.schema.fields.map((f) => f.name);
    console.log(names.join("\t"));
    for (const row of table) {
      console.log(names.map((n) => { const v: unknown = row[n]; return v == null ? "NULL" : String(v); }).join("\t"));
    }
  }
  s.close();
  ```

Both are sketches until slice 2 runs them; slice 2 fixes their exact text. What they do is fixed
here:

- **One statement at a time.** `sql()` takes one statement (Python's `Session.sql`, and Node's
  `sql`). The file is split at each `;` that ends a line, and each statement is passed without its
  `;`. So a SQL example ends each statement with `;` at the end of a line, never ends a line inside
  a statement with `;`, and ends with a line feed. The `sql` profile of the checker refuses an
  `example.sql` whose last line is not a `;`-ended line followed by a line feed.
- **Column names are unique** in each result. Python's `to_pylist()` keeps one of two columns of
  the same name, and JavaScript keeps both, so the two runs would differ and the Node run fails.
- **Errors.** Neither file catches an error. The run that executes it catches the error and takes its
  message: Python's exception text, and the `message` of Node's `KomiraError`. Both are the
  engine's `<step>: <reason>`. That line is what a probe's `.error.txt` holds.
- **The Node file is ESM.** It uses top-level `await`, so the project `node_act` writes for it has
  `"type": "module"` in its `package.json`, and `tsc` checks it with `module` `nodenext`, as the
  package's own `tsconfig.json` does.
- **What is printed.** For each statement, a line of column names, then a line per row, values
  separated by a tab and a null written `NULL`. A `COPY ... TO` prints its answer the same way.
- **One expected file, held by both runs.** The Python run and the Node run each copy the task's
  `example.sql` into a fresh empty folder, run their file there, and compare what it prints with the
  task's one `expected_output.txt`. Both must match it byte for byte. For that, a SQL example selects
  only integers and strings, and casts any other value to text in the query (`CAST(x AS VARCHAR)`),
  so the engine writes it the same for both. Python writes `True` and `7.0` where JavaScript writes
  `true` and `7`; the Node run fails on any such difference, naming the line.
- **The runs.**
  - Python: `//python/docs/sql_tasks:<rank>-<slug>`, one per folder, from `task_examples` with
    `python/tests/run_task_example.py` in a SQL mode: it installs the wheel as for `example.py`,
    copies `example.sql`, and runs `run_sql.py`.
  - TypeScript: `//node/docs:sql_tasks`, one target over every folder, from the `run-task-example`
    verb of `node_act` in a SQL mode: it installs the npm package as for `example.ts`, type-checks
    `run_sql.ts`, then for each folder copies `example.sql` and runs it. A failure names the folder's
    `expected_output.txt:<line>`. It reads the SQL tree through a filegroup of its `.sql` and `.txt`
    files, which holds no `.py` file, so `//:python_closure` allows it.
- **What the page tells a reader.** The SQL page shows `example.sql` and its output, then: "Save
  the statements as `example.sql` and run them, from that folder, with these lines", followed by
  the two files, each through the include marker that exists, `<!-- include run_sql.py -->` and
  `<!-- include run_sql.ts -->`, in a `python` and a `typescript` fence. The `sql` profile names
  these two shared files: its `:pages` target is given them as inputs, and an include of either
  name on a SQL page is held to that file byte for byte, as an include of a task's own file is.
  A file name still has no `/`, so no new marker or path form is needed, and every SQL page must
  show both. The reader copies what the test ran.
- **Where the two files live.** `run_sql.py` sits at the top of the SQL tree, beside the folders it
  runs, in the one place a file the wheel's test runs may be. `run_sql.ts` must be under `node/`,
  where the Node rules and the package are, so it is `node/docs/run_sql.ts`, beside the target
  `//node/docs:sql_tasks` that runs it.
- A SQL example makes its own input files with `COPY ... TO` over a query of literal rows. Where
  the engine cannot write the input a task needs, the SQL form is not shown for that task, with
  that reason. A task folder never holds a hidden input file.
- No libkomira call changes, and no SDK gains a method: the lines use `sql()` and the Arrow table
  each SDK already returns.

**Probes.** A probe is `probe_<name>.<ext>` with `probe_<name>.error.txt`, one line, in each form:

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
- **SQL:** the engine's error message, `<step>: <reason>`, without the SDK's error type name, so the
  Python run and the Node run hold the probe to one line.

**Targets that must fail.** Each passes only when its run fails with the exact line. Each takes
fixture files from its package's `tests/fixtures/`, as Python's do:

| Form | Targets |
|---|---|
| Python (exist) | `refuses_wrong_expected_output`, `refuses_example_that_raises`, `refuses_probe_that_runs`, `refuses_probe_with_another_error` |
| TypeScript | `refuses_wrong_expected_output`, `refuses_example_that_throws`, `refuses_example_that_does_not_typecheck`, `refuses_probe_that_runs`, `refuses_probe_with_another_error`, `refuses_probe_with_syntax_error` |
| Mojo (each form) | `refuses_wrong_expected_output`, `refuses_example_that_raises`, `refuses_example_that_does_not_compile`, `refuses_probe_that_runs`, `refuses_probe_with_another_error`, `refuses_probe_that_does_not_compile` |
| SQL | `refuses_wrong_expected_output`, `refuses_example_that_fails`, `refuses_probe_that_runs`, `refuses_probe_with_another_error`, in `python/docs/sql_tasks`; `refuses_sql_output_that_differs` (a statement selecting a boolean, which Python and JavaScript print differently) and `refuses_sql_wrong_expected_output`, in `node/docs` |

Each tree's root files name its `:pages`, `:examples` and `:refuses_*` targets, as
`ci/roots/komira/python/docs/tasks:*` do. Adding a task folder still adds no root file.

**The one `files` source.** The owner asked for one files source passed into every SDK. A task
example binds its input with `files` in every form whose SDK has it for the task's file kind:
Python's `komira.files` and Mojo's `files`, both Parquet only today (Mojo's until the Mojo SDK
design's slice 6). For any other kind, the example reads the file in the SQL text,
`read_csv('<file>')`, which needs no `files`; Python's older examples use `register_csv`. Each batch of slice 4 moves the examples it touches to `files` as each kind lands. TypeScript
has no `files` yet; its examples read files in the SQL text until it does.

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
    "sql": {"status": "not-shown", "reason": "no SQL example yet"},
    "python": {"status": "works"},
    "typescript": {"status": "works"},
    "mojo": {"status": "not-shown", "reason": "no Mojo library a user can install runs a query yet"}
  }
}
```

- `forms` has exactly the profile names as keys: `sql`, `python`, `typescript`, `mojo` and,
  once its profile row lands, `mojo_plan`.
- **A new form is a new key.** It comes with its profile row, and with a record in every non-gap
  entry, in one commit. The plan builder's key is `mojo_plan` (section 7). Its records start as
  `not-shown`, with the reason that the builder does not exist yet.
- Each value has a `status` of `works`, `partial` or `not-shown`, and an optional `issues` list in
  today's `komira-ai/<repo>#<n>` form. A form's `issues` are those that block that form only: a
  missing verb in its SDK, or its package unpublished. The entry's own `issues` stay as today: the
  issues that block the task as komira does it, required for a gap and allowed for a partial entry.
  An issue may appear in both.
- A `not-shown` value also has a `reason`: one line, not empty. The checker does not require it to
  name an issue; question 1 is whether the gate does.
- A gap entry has no `forms`. No form shows a gap.
- **What "works" means.** A form's `works` means its example does the whole task. `partial` means
  the example does part of it, and its page says which part. The entry's `status` is held equal to
  the best of its forms:
  - `works` when any form works;
  - `partial` when the best is partial;
  - an entry whose forms are all `not-shown` is refused, because it is a gap.

  So `status` keeps today's meaning, "komira does the task". An entry can be `works` while Python
  is `partial`, for example when the SQL form does the whole task and the Python page shows a frame
  verb that is missing.
- **The gate as a report.** The output of each `:pages` target, today `<folder> <status>` per
  folder, gains a line per entry with its form statuses. It also gains a last line per form
  counting its `works`, `partial` and `not-shown` entries: the numbers of
  [What each form can show](#what-each-form-can-show), measured. It is a report, not a gate. It
  fails no pull request, and the site's deploy reads it.
- **Probes** follow the form. A probe in a tree is allowed when that form's status is `partial`, and
  refused when it is `works`. This replaces today's rule in `tasks.zig`, which reads the entry's
  status. Under the old rule, a Python `partial` page with probes would be refused as soon as a
  TypeScript `works` made the entry `works`.
- **Compatibility.** The catalogue is read only by this repository's checker and, once built, its
  site generator. It ships in no package. The slice that adds `forms` fills it for every non-gap
  entry in the same commit, and the checker requires it from that commit on. No reader ever sees a
  catalogue with only part of it filled. The change only adds (rule B8, formats change only by adding): no key is removed or
  re-meant, and the one new key is required only from the commit that fills it.

## 6. The checker

`tools/build/readme_examples` gets one table, `PROFILES`, in a new `profiles.zig`. The literals of
`tasks.zig` and `task_page.zig` move into it. One row per form:

| Profile | Tree | Example | Probe | Code fence word | Near misses refused |
|---|---|---|---|---|---|
| `sql` | none until slice 2 (then `python/docs/sql_tasks`) | `example.sql` | `probe_<name>.sql` | `sql` | `SQL` |
| `python` | `python/docs/tasks` | `example.py` | `probe_<name>.py` | `python` | `py` |
| `typescript` | `node/docs/tasks` | `example.ts` | `probe_<name>.ts` | `typescript` | `ts` |
| `mojo` | none until `komira` is published (then `src/komira/docs/tasks`) | `example.mojo` | `probe_<name>.mojo` | `mojo` | `Mojo` |
| `mojo_plan` | added with the plan builder (then `src/komira/docs/mojo_plan_tasks`) | `example.mojo` | `probe_<name>.mojo` | `mojo` | `Mojo` |

Every profile has `expected_output.txt` (`text`), `page.md` and `probe_<name>.error.txt`. The plan
builder is the fifth row, with its own tree, the same file names and the same fence word. Two rows
may share a fence word; no two rows share a tree.

- **The new flag.** `tasks-check` takes `--profile <name>`, and it is required. Each tree's `:pages`
  target passes its own. `task_pages_check` and the helpers `task_dirs` and `task_probes` move to a
  shared `.bzl`, with the probe extension as an argument.
- **What stays strict, for every profile.**
  - Folder names are `<rank>-<slug>`, and the rank matches the entry.
  - A gap has no folder.
  - A folder holds exactly the three files and probe pairs, and nothing else. A `.py` in the Node
    tree is refused as an extra file, and so is an `example.ts` in the Python tree.
  - A probe's error file is one line ended by a line feed.
  - The page's title is the question.
  - The page includes the profile's example and `expected_output.txt`, each byte for byte.
  - A file name in an include has no `/`.
  - A shown file has no carriage return.
  - A `text` fence after code needs an include or `not-tested`.
- **New page rules, for every profile.** Each code word of every profile needs an include or
  `not-tested`; today only `python` does. The near-miss words of the table are refused by name,
  naming the word to use. Today no fence word is refused. No Python page has a `sql` fence today
  (`grep -l '^```sql' python/docs/tasks/*/page.md` finds none), so the rule changes no page.
- **New catalogue rules** (section 5), checked by every tree's run, because every run reads the
  whole catalogue:
  - the form of `forms`;
  - `status` equal to the best form status;
  - an entry with every form not shown is refused.
- **New rules for a tree's own form.** Each tree's run checks its own profile's form:
  - every folder's entry has that form `works` or `partial`;
  - every entry with that form `works` or `partial` has a folder;
  - a probe needs that form `partial`.

  For a profile with no tree (SQL and Mojo today), every run refuses an entry that marks that form
  as shown. A row gets its tree in the same pull request that adds the tree's BUCK file. For a Mojo
  tree, that BUCK file's `:pages` names the Mojo library its examples import, and its analysis
  fails when that library is not a package of `release/readme_e2e/packages.bzl`, so no Mojo tab
  shows an example for a library a reader cannot install. Until a row names a tree, nothing reads
  a stray folder; the site draws tabs only from the trees the profile table names, so such a folder
  is never shown.
- **Why each tree runs its own check, not one check over all of them:** the Python tree's files
  cannot be read by a target outside `python/` (`//:python_closure`). Each run checks the whole
  catalogue and its own form, and no claim goes unchecked. A form is shown only when its tree's run
  has found the folder. The catalogue file and the checker tool are declared inputs of every tree's
  `:pages`, so a pull request that changes only the catalogue, or only
  `tools/build/readme_examples`, runs every tree's `:pages`.
- **Its tests.** The checker's unit tests (`tasks_test.zig`, `task_page_test.zig`) gain the cases in
  [What each check proves](#what-each-check-proves): one fixture per rule, each asserting the exact
  refusal text.

## 7. Decided elsewhere

- **Which API the TypeScript and Mojo examples use.** The TypeScript package today runs SQL; a
  DataFrame builder is "explicitly later" in [typescript_package.md](typescript_package.md). The
  Mojo SDK design's session runs SQL over `files`.
- **The Mojo SDK's forms.** The Mojo SDK design (komira-ai/komira#2496) has three: the session
  (`files` and SQL), first; the plan builder, whose code writes the physical plan directly, in the
  same package, second; and a typed SDK, later, with its own design. Task pages show two of them,
  each with its own tab:
  - the session: form `mojo`, tree `src/komira/docs/tasks/`;
  - the plan builder: form `mojo_plan`, tree `src/komira/docs/mojo_plan_tasks/`, with the same Mojo
    runner.

  The typed SDK has no form here; its own design would add one, as a new profile row, tree and
  catalogue key.

| | SQL only | Frame APIs too |
|---|---|---|
| Layout, file names, page rules, checker, runners, catalogue keys | as above | as above |
| How many tasks each form shows | the ranges of [What each form can show](#what-each-form-can-show) | more, once a frame API exists |
| Probes | a probe can only try SQL, since a frame call that does not exist is a type or compile error, not a run failure | a probe can try a frame verb that is refused by name at run time |

A Mojo profile's tree is set only when its library is published. A page shows only what a reader
can install and run. A Mojo example built against the unpublished `sdk_exec` in this repository
would pass the pull request's check and fail for every reader.

## 8. The slices, in order

1. **One task in Python and TypeScript, with SQL and Mojo recorded as not shown.** The task is rank
   75, `join-value-falls-two-bounds`. Its status is `works`. Its Python example is SQL only, over two
   small CSV files, and prints only integers and strings, with no probes. The slice holds:
   - `PROFILES` with `python` and `typescript`, and `sql` and `mojo` with no tree;
   - `--profile`;
   - the catalogue rules;
   - `forms` filled for all 80 non-gap entries:
     - Python copies today's `status`;
     - TypeScript is `not-shown`, "no TypeScript example yet", except rank 75;
     - SQL is `not-shown`, "no SQL example yet";
     - Mojo is `not-shown`, "no Mojo library a user can install runs a query yet";
   - `node_act run-task-example`, `node/task_examples.bzl` and the six TypeScript `refuses_*`
     targets with their fixtures;
   - `node/docs/tasks/75-join-value-falls-two-bounds/`. It runs the same two joins over the same
     two CSV files, but reads them with `read_csv('<file>')` in the SQL text where the Python
     example calls `register_csv`, since `registerCsv` is refused. Its page says so in its notes;
   - the form the TypeScript examples print rows in, chosen by running rank 75 and written into
     "Writing an example whose output is stable" of `docs/tasks/README.md`;
   - its root files;
   - `docs/tasks/README.md` brought up to date, including the lines on other trees quoted in
     [What exists today](#what-exists-today).

   If review asks for the checker change to land on its own first (rule P7 of AGENTS.md: one
   subject per pull request, refactors apart from behaviour changes), this is two pull requests: the profile and catalogue rules, then the
   runner and the task.
2. **The SQL tree and rank 75's SQL example:** the `sql` profile's tree `python/docs/sql_tasks/`,
   `run_sql.py` and `run_sql.ts`, the SQL modes of the Python runner and of `node_act`, their
   `refuses_*` targets, rank 75's `example.sql`, and rank 75's `sql` record set to `works`.
3. **The site design follows main.** komira-ai/komira#2352 moves to the names of section 1. This is
   a document only and can land beside slices 1 and 2.
4. **SQL and TypeScript examples in batches**, for tasks the Python tree already shows. Each batch
   adds its folders, changes the records of the same entries, and moves the examples it touches to
   `files` where `files` reads their input. No batch touches the Python tree except for that move.
5. **The Mojo tree**, after the Mojo SDK design's slice 1 publishes `komira`: the `mojo` profile's
   tree, `mojo_task_examples` and its six `refuses_*` targets, the compare phase in the release's
   README e2e, the byte-for-byte compare of each output with its `expected_output.txt`, and the
   Mojo examples of the tasks it can show, rank 75 among them.
6. **The plan builder's tree** (`mojo_plan`), once the Mojo SDK design's builder exists: its profile
   row, tree, records and examples, with the runner of slice 5.

## What each check proves

Every row has a negative case that must go red and name the line or the entry.

| Check | Defect it catches | Negative case |
|---|---|---|
| Profile: files | an example of another form, or a stray file, in a tree | a `.py` in the Node tree; an `example.ts` with no `expected_output.txt` |
| Profile: fences | an unchecked program on a page | an unmarked `typescript` fence; an unmarked `python` fence on a TypeScript page; an unmarked `sql` fence on a Python page; a `ts` or `SQL` fence |
| Profile: include | a page that shows another program than the one that ran | one changed byte of `example.ts` in the page |
| SQL page's run lines | a page that shows other run lines than the ones the tests ran | one changed byte of the `run_sql.py` fence on a SQL page; a SQL page without the `run_sql.ts` include; an `example.sql` that does not end with a `;` line and a line feed |
| Catalogue: `forms` | a form left out without a word | a non-gap entry with no `mojo`; a `not-shown` with no reason; a key no profile names |
| Catalogue: status | an entry whose word disagrees with its forms | `status` `works` with every form `partial`; every form `not-shown` on a non-gap entry |
| Tree against catalogue | a tab with no tested example, or a tested example the catalogue hides | `typescript` `works` with no folder, the catalogue the only file changed; a folder with `typescript` `not-shown`; `mojo` shown while the profile has no tree |
| Probes per form | a probe rule that reads the wrong status | a Python `partial` folder with probes whose entry is `works` through TypeScript passes; a probe in a `works` form is refused |
| Mojo tree's library | a Mojo tab for a library a reader cannot install | a Mojo `:pages` naming a library that is not in `release/readme_e2e/packages.bzl` fails analysis |
| TypeScript run | changed output, a throw, a type error, a probe that passes, fails another way or fails on a syntax error | the six `refuses_*` targets |
| Mojo run | changed output, a raise, a compile error, a probe that passes, fails another way or does not compile | the six `refuses_*` targets, for each Mojo form |
| SQL run | changed output, a failing statement, a probe that passes or fails another way | the four `refuses_*` targets |
| SQL in two SDKs | a SQL example whose output depends on the SDK that ran it | `refuses_sql_output_that_differs` |

## Question for the owner

1. **What the gate means for a task a form cannot show yet.** The gate is that the examples work in
   SQL, Python, TypeScript and Mojo.
   - **Option 1:** every task that Python shows, and that the language can show at all, works in
     that language before the site publishes; the tasks a form can never show are listed by rank
     with the reason. Today that list is the 6 of [What each form can show](#what-each-form-can-show)
     (ranks 22, 31, 60, 89, 90 and 93) for SQL; for TypeScript and the Mojo session, ranks 31 and
     93 are on it only until each has credentials. Cost: nothing publishes until every other task
     works in every form. Up to 63 tasks need their SQL written first, and some may need a frame
     API in TypeScript or Mojo, which has no design yet.
   - **Option 2:** a task may also be left out of one form when a tracked issue says why. This is an
     exception to the gate. Cost: the site publishes with holes, and you grant each one. The
     checker today would accept any reason; if this is granted, the checker is changed to refuse a
     reason that names no issue.

   Under either option, the list of exceptions also says that the Mojo packages are not built for
   linux-arm64.

   The exact counts do not exist until the examples are written; the ranges are bounds.

   **Recommendation:** option 1 as the target. The `:pages` report (section 5) gives the count of
   tasks not shown per form, measured, as each batch lands. Grant exceptions, if any, once you see
   those counts, not before.
