# komira.dev: install first, then the common tasks

Status: design, not built. It supersedes the design in komira-ai/komira#2285, which was organised by
SDK language and reference; this one is organised by what a reader is trying to do.

## What problem does this solve?

Someone who wants to read a CSV file, group it and write Parquet does not start from a package
reference. They type the question into a search box or ask an assistant, copy the first answer that
runs, and come back only when it fails. komira has no page that answers such a question. The user
docs today are [install.md](../install.md) (one tested program), the
[DataFrame pages](../../python/docs/dataframe/overview.md) (snippets that no target in the
repository runs) and the design docs. Nothing tells an assistant what komira can do or how to call
it.

komira.dev is built around four things, in this order:

1. **Getting started.** An install command for the reader's package manager and a first query
   with what it really prints, before anything else.
2. **The common tasks, ranked.** A catalogue of the tasks people ask about most, most asked first,
   filtered by category and status.
3. **One page per task.** The question as the title, a tested program and its real output, related
   tasks, and "Copy page as Markdown".
4. **Readable by machines.** Every page is also plain Markdown at a stable URL, and `llms.txt`
   lists them all, so an assistant that fetches komira.dev can quote a whole, tested answer.

## What a reader sees

### The home page

Install first, then the first query, then the tasks, then why (B24). Without a script, every tab's
content is shown one after another.

```text
+--------------------------------------------------------------------------------------+
| komira      Install  Common tasks  Guides  Releases  GitHub        [Copy page as MD] |
+--------------------------------------------------------------------------------------+
|  SQL and DataFrames over your files. No server.                                      |
|  Read CSV, JSON Lines and Parquet in place, query with SQL or a pandas-shaped API,   |
|  and get Arrow back.                                                                 |
|                                                                                      |
|  [pip] [uv] [poetry] [pdm] [pixi] [conda] [notebook] | [npm: not yet] | [mopm: Mojo] |
|  +--------------------------------------------------------------------------------+  |
|  | $ pip install komira                                                    [copy] |  |
|  +--------------------------------------------------------------------------------+  |
|  Linux x86_64 (glibc 2.35+, AVX2) or macOS 11+ on Apple silicon; CPython 3.11-3.14  |
|                                                                                      |
|  First query                                                                         |
|  +--------------------------------------------------------------------------------+  |
|  | import komira                                                                  |  |
|  | ...  (the program first writes weather.parquet: six days in three cities)      |  |
|  | with komira.Session() as s:                                                    |  |
|  |     s.register_parquet("weather", "weather.parquet")                           |  |
|  |     table = s.sql("SELECT city, count(*) AS days, avg(temp) AS mean,"          |  |
|  |                   " max(temp) AS hottest FROM weather GROUP BY city"           |  |
|  |                   " ORDER BY city").to_arrow()                                 |  |
|  |     for row in table.to_pylist():                                              |  |
|  |         print(row)                                                             |  |
|  +--------------------------------------------------------------------------------+  |
|  {'city': 'Lima', 'days': 2, 'mean': 19.0, 'hottest': 20}                            |
|  {'city': 'Oslo', 'days': 3, 'mean': 3.0, 'hottest': 5}                              |
|  {'city': 'Pune', 'days': 1, 'mean': 31.0, 'hottest': 31}                            |
|  An excerpt of a program tested on komira 0.1.<n>.  [Show the whole program]         |
|                                                                                      |
|  Common tasks                                                [all tasks ->]          |
|  [Read a CSV file] [Select columns, filter rows] [Add a computed column]             |
|  [Group by and sum] [First rows, count, columns] [Find and fill missing values]      |
|  ... the twelve most asked, each card: question, three lines of code, status         |
|                                                                                      |
|  Why komira   (three claims, each with a measured run and its method)                |
|  For AI assistants   llms.txt  llms-full.txt  every page as .md                      |
+--------------------------------------------------------------------------------------+
```

The first query is an excerpt of [python/examples/quickstart.py](../../python/examples/quickstart.py),
and the three printed rows are lines of
[quickstart.expected](../../python/examples/quickstart.expected). A pull request that reaches the
Python package runs the program from the installed wheel (`//python:wheel_install_test` and its
per-Python siblings) and compares every line it prints with that file. "Show the whole program"
opens the full file and its full output; the program writes its own `weather.parquet`, so a reader
can paste it into an empty directory and run it. No number on the page is written by hand.

### The install tabs

One tab per package manager. The reader's choice is kept in browser storage and in the URL
(`?pm=uv`, so a link can name it) and applies to every install line on the site; a page that has
no tab for that choice (a Python task page for a reader who chose mopm) shows pip. Every variant is
in the HTML and in the page's Markdown, so a crawler sees all of them. The tabs are rows of one
file, `site/install.tsv`. Its status column is about the install, not about tasks:

| Tab | Command | Install status |
|---|---|---|
| pip | `pip install komira` (in a venv, as [install.md](../install.md) shows) | tested |
| uv | `uv add komira`; one-off: `uv run --with komira python script.py` | untested |
| poetry | `poetry add komira` | untested |
| pdm | `pdm add komira` | untested |
| pixi | `pixi add --pypi komira` | untested |
| conda | `conda create -n komira python=3.12`, `conda activate komira`, `pip install komira` | untested |
| notebook | `%pip install komira` | untested |
| npm | none: the package is not published | not yet |
| mopm | the sequence `prod-add` runs in [ci.md](../ci.md), for one `komira-ai/<library>` | tested, libraries only |

- **tested** means a named test installs with that tool and runs a program. pip's is
  `//python:wheel_install_test`; mopm's is the `prod-add` job of the release workflow. The row
  names its test, and the generator refuses a `tested` row whose Buck2 target or workflow job does
  not exist. An
  `untested` tab shows its command with the words "not tested by komira yet"; each gains a test of
  its own later, uv first.
- **conda** is pip inside a conda environment. There is no conda-forge package, so
  `conda install komira` is never shown.
- **npm** shows "not published yet" and no command until the TypeScript package is published
  ([typescript_package.md](typescript_package.md)); its name is not decided. Then the npm row's
  status changes and pnpm, yarn and bun rows join it.
- **mopm** is for Mojo. There is no package named `komira` on mopm: the libraries are published one
  by one as `komira-ai/<name>` (`json`, `uuid`, `compression`, ...). The tab shows the tested
  sequence, including setting the project's Mojo version in `mopm.toml`, and links to the list.

### The catalogue: `/tasks/`

```text
+--------------------------------------------------------------------------------------+
| Common tasks                                         [ filter: group by          ]   |
| Category: [all] Read  Transform  Aggregate  Clean  Join  Write  Databases  ...       |
| Status:   [works] [partial] [specified]                                              |
+--------------------------------------------------------------------------------------+
|  1  How do I read a CSV file in Python?                          Read       works    |
|  2  How do I select columns and filter rows in Python?           Transform  works    |
|  4  How do I group by a column and sum another column?           Aggregate  works    |
| 11  How do I write a table to a CSV file?                        Write      partial  |
| 20  How do I load a database query result into a DataFrame?      Databases  specified|
| ...                                                                                  |
+--------------------------------------------------------------------------------------+
```

Ordered by rank, most asked first. The category chips are the distinct values of the category
column of `docs/tasks/tasks.tsv`; the text box matches the questions and their "Also asked as"
lines. The filters are a few lines of script over the list; without a script the page shows the
whole list grouped by category. The page lists only tasks that have a directory.

The ranking comes from public signals: how often pandas calls appear in published notebooks, the
canonical Stack Overflow questions, and the guides of DuckDB and polars. Many ranks have no count
behind them, so `tasks.tsv` records for each task how firm its rank is (`measured`, `sourced` or
`estimate`), and a later count can move a task without anyone mistaking a guess for a measurement.
The first tasks and their rows land with the examples, not with this design.

### A task page: `/tasks/<slug>/`

```text
+--------------------------------------------------------------------------------------+
| Common tasks > Aggregate                                       [Copy page as MD]     |
| # How do I group by a column and sum another column?                                 |
| GROUP BY the key and aggregate: SELECT region, sum(amount) ... GROUP BY region,      |
| or df.groupby("region").agg(...).                                                    |
|                                                                                      |
| [pip] [uv] ...   $ pip install komira                                                |
| +----------------------------------------------------------------------------------+ |
| | example.py: a whole program; it writes the orders.csv it reads                   | |
| +----------------------------------------------------------------------------------+ |
| Output                                                                               |
| +----------------------------------------------------------------------------------+ |
| | example.expected, with the tested version in place of <version>                  | |
| +----------------------------------------------------------------------------------+ |
| Tested on komira 0.1.<n>                                                             |
| Notes: an integer SUM is DECIMAL(38, 0) ...       Also asked as: pandas groupby sum  |
| Related: several aggregates at once; count rows per group; value counts              |
+--------------------------------------------------------------------------------------+
```

From top to bottom: the question as the H1, a one-sentence answer, the install line, the program,
its output, the notes, "Also asked as" (the keyword forms people type), and related tasks. A
`partial` page puts the part that works first and then says what does not work yet. A `specified`
page has no program: it says what komira lacks for the task and links the issue that tracks it
(B24).

## Where a task lives: `docs/tasks/<rank>-<slug>/`

```text
docs/tasks/
  tasks.tsv                                  one row per task: directory, category, rank evidence
  004-group-by-a-column-and-sum-another-column/
    README.md                                the page: H1, answer, notes, related
    example.py                               a whole program, run from the installed wheel
    example.expected                         what it prints, compared line by line
```

- **`README.md`** is the page's text. Its H1 is the question, ending in `?`, and its first paragraph
  is the answer. It may have the sections `## Notes`, `## Also asked as`, `## What does not work
  yet` and `## Related tasks`. Related tasks are relative links to sibling directories, so the
  repository's link check (`//:docs`) already holds them, and GitHub shows the directory as a
  readable page too.
- **`example.py`** is a whole program: imports, the sample data it writes itself, the operation and
  what it prints. **`example.expected`** is its output, with `<version>` and `<cwd>` standing for
  the installed version and the run directory, as in `quickstart.expected`. The page shows the
  tested version in place of `<version>`.
- **The status follows from the files.** An example and no "What does not work yet" section:
  `works`. Both: `partial`. No example: `specified`.
- **The rank is a sort key.** Gaps between ranks are allowed, so a new task takes a free number and
  no other directory is renamed.
- **The slug is fixed when the task is created.** The generator reads it from the directory name,
  never from the H1, so rewording a question does not move its page.

Every `docs/tasks/*/example.py` runs in an empty directory from the wheel installed into an empty
environment, and its output must equal `example.expected` line for line, the way
`//python:wheel_install_test` runs the quickstart. The examples harness builds that test outside
this design; this design depends on its contract: it finds the programs by that glob, so no list
of them can go stale, and it fails on any changed line. A change in behaviour updates
`example.expected` in the same pull request (T19).

**TypeScript and Mojo join a page by adding files.** `example.ts` with `example.ts.expected`, and
`example.mojo` with `example.mojo.expected`, sit beside `example.py`, and the page's program gains
a language tab. The TypeScript test runs the program from the packed npm package, as
`//node:package_test` runs the addon. The Mojo test installs the `komira-ai/<name>` libraries the
program imports, as the README end-to-end check does, so a Mojo tab appears only on tasks the
published libraries can do. A TypeScript tab is shown once the npm row of `install.tsv` is no
longer `not yet`; before that, the example is tested but not shown. The status stays the Python
program's; another language adds a tab, nothing more.

## Built by the generator

`./buck2 build //site:dist` writes the whole site as a directory. The generator,
`//tools/build/site:generate`, is a Zig program with one Zig test target per scenario (B7). It reads
Markdown with the reader the README examples tool already uses
([tools/build/markdown](../../tools/build/markdown/BUCK)) and adds an HTML writer for a small subset:
headings, paragraphs, lists, tables, code blocks, code spans, emphasis and links. A page that uses
anything else, raw HTML included, is refused with its file and line, so the HTML and the Markdown
twin cannot say different things.

| Input | Becomes |
|---|---|
| `site/home.md`, `site/install.tsv` | the home page and the install tabs |
| `docs/tasks/**` | `/tasks/` (and its twin, the ranked list as a Markdown table), one page per task, and the task part of `llms.txt` |
| [python/docs/](../../python/docs/dataframe/overview.md) | `/guides/python/...`, unchanged in content |
| [python/CHANGELOG.md](../../python/CHANGELOG.md) | `/releases/` |

Every page, the home page and the catalogue included, is written as `index.html` and `index.md` in
its directory. The script a reader's browser runs (tabs, the remembered package manager, the
catalogue filters, Copy page as Markdown) is TypeScript with no runtime dependency, compiled by the
existing `tsc_build` rule from its own `tsconfig` with the DOM library, and tested on the pinned
Node at the 99% floor (T1).

All of these are declared inputs of `//site:dist`, so `pr / check` builds it whenever a change
reaches one: a task, a page, the generator. This adds no job (B9) and no preview deploy.

### What the generator refuses

Each refusal is a Zig test with a negative case (T15):

- a task directory with no row in `tasks.tsv`, or a row with no directory;
- a directory name that is not `<three-digit rank>-<slug>`, or two directories with one rank or
  one slug;
- an H1 that is not a question, or a README with no answer paragraph;
- `example.py` without `example.expected`, or the reverse;
- a `What does not work yet` section that is empty;
- a `specified` README that links no issue;
- a `tested` install row whose Buck2 target or workflow job does not exist;
- a page whose Markdown twin and HTML differ in any code block, by even one byte;
- a page using Markdown outside the subset.

## For machines: Markdown, `llms.txt`, stable URLs

- **Every page has a Markdown twin**, `index.md` beside its `index.html`, generated from the same
  source. Tabs become headed sections one level below the section that holds them (`### pip`,
  `### uv`), so the twin holds every variant. The HTML head names it with
  `<link rel="alternate" type="text/markdown">`. **Copy page as Markdown** copies the twin; without
  a script it is a link to it.
- **`/llms.txt`** follows the llmstxt.org layout: an H1 `komira`, a one-paragraph summary with the
  install line, a line telling assistants to check PyPI for the current version, then the sections
  `Install`, `Common tasks` (one line per task in rank order: the question, the answer, the link to
  its `index.md`), `Guides` and `Optional`. A `partial` task is marked "(partial)" and a `specified`
  one "(specified)", so an assistant does not recommend what does not run. **`/llms-full.txt`** is
  every task page's Markdown in rank order.
- **The question is the title**, in the words people use, not komira's: "How do I read a JSON file
  into a table?". The slug is the question's words when the task is created.
- **Stable URLs.** `/tasks/<slug>/` carries no rank, and a slug never changes, so re-ranking or
  rewording a task never breaks a link. If a slug ever must change, that pull request adds the
  first redirect, served as a real 301, never as a page that redirects by script.
- **`sitemap.xml`** lists every page, and **`robots.txt`** admits every crawler.
- **Whether this works is measured, not assumed.** Little evidence shows that `llms.txt` changes
  what assistants recommend. A fixed set of task questions, asked of the main assistants after each
  site deploy, records whether komira is named and whether its code runs. It is run by hand, not by
  the build.

## Hosting and deploy

The site is static files: no server code and no database. It is served from an object-store bucket
behind a CDN. Which provider is the owner's choice; the repository holds no account, bucket, role or
endpoint (S1), only the deploy environment does.

- **What is deployed.** The deploy names a PyPI version, `0.1.<n>`, and a commit to build the pages
  from. It downloads that version's Linux wheel from PyPI, checks it against the SHA-256 PyPI
  lists, and runs every task program on it with the harness. A task whose program fails on that
  wheel (a feature on `main` that is not released yet) is left out of this deploy and listed in the
  dry run, so the site shows only what `pip install komira` gives today, and each page says
  "Tested on komira 0.1.<n>". There is one site, for one release; older versions and a site of
  `main` are left out until a reader needs them.
- **A deploy waits for the owner** (S3). `.github/workflows/site.yml` runs only on
  `workflow_dispatch`, with the inputs `version`, `commit` and `apply` (default `false`). Without
  `apply` it builds `//site:dist` on the farm and prints the tasks left out and the files it would
  add, change and remove, then stops. With `apply` it runs in an environment whose required reviewer
  is the owner, and uploads with short-lived credentials from the workflow's identity token. Every
  step is one named command or target (B4), on a hosted runner, with pinned actions and
  `permissions: {}` at the top (B10). Unlike the packages, the site does not publish itself from
  `main` (B12); deploying on each release would be the owner's ruling to make.
- **The first setup is the owner's alone**: the komira.dev domain and its DNS, the certificate, the
  bucket, the CDN and the deploy role. Until they exist, the dry run works and `apply` refuses,
  naming the missing setting.

## What changes in this repository

| Path | What |
|---|---|
| `docs/tasks/` | new: one directory per task, written with the examples |
| `site/` | new: `home.md`, `install.tsv`, the browser script, `BUCK` with `//site:dist` |
| `tools/build/site/` | new: the generator and its Zig tests |
| `.github/workflows/site.yml` | new: the dispatch-only deploy |
| [tests/public_boundary_hosts.tsv](../../tests/public_boundary_hosts.tsv) | a `komira.dev` row, landing with the first URL that names the host (the public-boundary check refuses a URL host not listed there, and a row no URL uses) |
| [docs/install.md](../install.md) | unchanged: it stays the authority for the Python install, and the site links to it |

## What this design leaves out

A generated API reference for Python, TypeScript and Mojo (its own design, once the catalogue is
up); the look of the site, which is a review of the built pages; search beyond the catalogue's
filter; comparison pages; translations; and a sandbox that runs a reader's code.

## Decisions

1. **The first query is an excerpt of the tested quickstart**, with its real printed rows. A
   shorter program written for the home page would be one more file to test, and the earlier draft
   of one had output worked out by hand.
2. **A task's status follows from its files.** A list of statuses kept by hand would drift from
   what the tests run.
3. **`specified` pages are published, with no code.** An assistant is asked those questions anyway,
   and "komira cannot do this yet" is a true answer. Code from another library on komira's site
   would be code komira does not test.
4. **The site shows only what the released wheel runs.** Examples on `main` may use features PyPI
   does not have yet; running them on the PyPI wheel at deploy time keeps "Tested on komira 0.1.<n>"
   true without rebuilding the wheel.
5. **Every deploy waits for the owner, starting from a dry run.** A deploy is a cloud write (S3).
