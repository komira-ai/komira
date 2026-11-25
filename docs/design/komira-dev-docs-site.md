# komira.dev: the documentation site for the Komira SDK

Status: design, not built. These names are new, and none of them exists yet: `site/`, `//site:*`,
`//tools/build/site:*`, `//python:reference`, `//node:reference`, `//third_party/mopm:docs`,
`.github/workflows/site.yml`, and the two mopm generators of [section 6.3](#63-generated-mopm-references).
Every other file, target and rule the page names exists on `main`, and the
[audit](#13-the-audit-what-exists-today) says what each one holds today.

## 1. What problem does this solve?

People who want to use komira today find a Python install page, a long Python README, a README for
each of 262 Mojo libraries, 60 design documents, and nothing for TypeScript. The one user page,
[install.md](../install.md), is Python only. The page called
[getting-started.md](../getting-started.md) is for people working on komira itself. mopm, the Mojo
package manager komira publishes its libraries with, has eight pages on mopm.dev, some of them
stale, and several of its commands are documented only by their `--help` text.

komira.dev is one documentation site for the Komira SDK. It covers:
- getting started;
- the SQL, pandas and polars guides;
- the API reference for Python, TypeScript and Mojo;
- mopm: install, the manifest, publishing and the registry;
- the concepts: the engine, plans, Arrow, object stores and Iceberg;
- recipes.

Two properties hold everywhere on the site:
- **Every example is shown in Python, TypeScript and Mojo, side by side in tabs.** Every example is
  a real file that the pull-request check runs and compares, so a page cannot drift from the code.
  When an example does not exist yet in a language, its tab says so ("Not yet in TypeScript") and
  says what is missing. It never shows code that did not run.
- **The reference is generated from the code**: from the docstrings and type annotations in Python,
  the package's types in TypeScript, and `mojo doc` in Mojo. Nobody writes a reference page by hand.

This document describes the site as it will be when it is finished. It does not set an order of work.

## 2. What a reader sees

The home page follows B24: install first, then a demo, then the reasons to use komira.

1. **Install**, in three tabs: `pip install komira`, `npm install` of the TypeScript package, and
   `mopm add` of the Mojo libraries. A language whose package is not published yet shows that
   instead of an install line (see [section 5](#5-status-on-a-page)).
2. **Demo**: one example, the quickstart, with its three tabs and the output each language printed
   when the check ran it.
3. **Why komira**: in-process SQL over local and remote files, the same answers as DuckDB for the
   same SQL (B21), Arrow results with no copy, and one engine behind three languages.

The rest of the site is laid out like this:

| Section | Pages |
|---|---|
| Get started | Install (per language, with platforms and troubleshooting); your first query; reading results as Arrow, pandas and polars |
| Guides | SQL (the dialect, files as tables, `COPY ... TO`, errors); pandas (the pandas-shaped `DataFrame`, its verbs, what it refuses and why); polars (the polars-shaped `komira.pl`, which is specified and not built) |
| Concepts | The engine (in-process, threads, memory budget, cancellation); plans (SQL and frames both build a plan; `explain`); Arrow (results as Arrow C streams, zero copy into pyarrow and apache-arrow); object stores (locations, named credentials that never enter a plan); Iceberg (tables in your own catalog) |
| Recipes | Short tasks, one example each, listed in [section 3.6](#36-the-recipes) |
| Reference | Python, TypeScript, Mojo: one page per module or class, generated ([section 4](#4-the-reference)) |
| mopm | Install; the manifest (`mopm.toml`); building and testing; publishing; the registry (namespaces, versions, yank, tokens); the CLI reference ([section 6](#6-mopm-on-komiradev)) |
| Releases | What each release added, per language, from the changelogs |

The site does not hold the contributor and design documents. They stay in `docs/` in the repository,
where people who change komira read them, and the site links to them on GitHub where a concept page
needs the full design.

## 3. Examples in three languages

### 3.1 Where an example lives

Every example is a directory under `site/examples/`:

```text
site/examples/
  group-and-count/
    example.toml          # title, the data it reads, and the missing languages, if any
    example.py
    example.ts
    example.mojo
    expected.py.txt       # what example.py printed
    expected.ts.txt       # what example.ts printed
    expected.mojo.txt     # what example.mojo printed
    expected.tsv          # the result, in the one form all three languages are compared in
  _data/                  # the input files the examples share (Parquet, CSV, JSON), each small
  _support/               # the comparison printer in each language: canon.py, canon.ts, canon.mojo
```

A page includes an example by its name, never by pasting its code:

````markdown
```example group-and-count
```
````

The site generator replaces that block with the three tabs. A page has no other way to show
runnable code: a fenced block tagged `python`, `typescript` or `mojo` in a page is refused by the
generator, so code cannot reach a page without being run. Fences for shell commands
(`pip install komira`) and for output are allowed.

### 3.2 What part of the file is shown

An example file is a whole program. Its last lines hand the result to the comparison printer, and
those lines are not shown. Everything before a marker line is the part a reader sees and copies:

```python
import komira

with komira.Session() as s:
    s.register_parquet("readings", "readings.parquet")
    result = s.sql("SELECT sensor, count(*) AS n FROM readings GROUP BY sensor ORDER BY sensor")
    print(result.to_arrow())
# komira.dev: end of the shown part
import canon
canon.write(result)
```

The rules:
- The marker is exactly `# komira.dev: end of the shown part` in Python and Mojo and
  `// komira.dev: end of the shown part` in TypeScript, once per file. A file without it, or with it
  twice, fails the generator.
- The shown part is a program on its own: it reads its input files by relative name, because the
  runner runs it in a scratch directory holding a copy of `_data/`. There is no hidden setup above
  the shown part, so what a reader copies runs as it is.
- The lines after the marker only call `canon.write` on a variable the shown part bound. They take
  the output path from the command line (`--canonical <path>`), never from an environment variable
  (S2).

### 3.3 How an example runs

Each language runs its examples the way a user would run them, against the package as it is
installed:

| Language | How it runs |
|---|---|
| Python | The wheel built at this commit is installed into an empty virtual environment on the newest CPython of [python/pythons.bzl](../../python/pythons.bzl). The install is done the way `//python:analysis_job_test` installs the wheel to run [analysis_job.py](../../python/examples/analysis_job.py) today. Then `python example.py --canonical <path>` runs in the scratch directory. |
| TypeScript | The npm package built at this commit is laid out as `node_modules` the way `//node:package_test` lays it out, and the example runs on the pinned Node with types stripped, like the package's own tests. |
| Mojo | The example compiles against the libraries at this commit and runs as a test, the way [`readme_examples`](../../tools/build/readme_examples/BUCK) turns a README's ` ```mojo ` blocks into programs today. |

Each language has one Buck2 target that runs all of its examples, `//site:examples_python`,
`//site:examples_typescript` and `//site:examples_mojo`, and `//site:dist` depends on all three. So
the pull-request check, which already builds the affected targets, runs every example whose code or
data a change reaches. No new job is added (B9). The inputs under `_data/` stay small, each file
under 1 MiB, so the examples stay in the unit-test class and add no slow test.

The examples are hermetic (T12). They read local files only. An object-store example reads the
local object store; an Iceberg example uses a fake REST catalog on loopback with port 0, in the
same process. No example reaches a network, a cloud account or a fixed port.

### 3.4 How an output is compared

Two comparisons run for every example, and both must hold.

1. **What the reader is shown.** The standard output of the run must equal `expected.<lang>.txt`
   byte for byte. That file is what the page shows under the tab, so the output on a page is always
   one a real run printed (B24: demos replay real runs). The only allowed differences are two
   placeholders the runner substitutes before it compares: `<version>` and `<abi_version>`, the
   same pair the Python quickstart's check uses today. No regular expressions, and no other
   placeholders.
2. **That the three languages agree.** `canon.write` writes the result as text in one fixed form: a
   header line of column names and Arrow types, then one line per row, with values in a fixed
   spelling (integers in decimal, floats in their shortest round-trip form, NULL as `NULL`, strings
   escaped). The file each language wrote must equal `expected.tsv`. Rows are compared in order, so
   an example whose rows have no defined order must say `ORDER BY`. This check is what makes a tab
   in one language a true translation of the others: the three programs produced the same table.

When a change alters an output on purpose, `./buck2 run //site:examples_update -- <example>` writes
the new expected files, and they are committed in the same pull request as the change (T19). A
pull request that changes an output without its expected file fails the check and prints the first
difference.

### 3.5 A language that does not have the example yet

An example that cannot be written in a language yet says so in its `example.toml`:

```toml
title = "Count readings per sensor"
data = ["readings.parquet"]

[missing.typescript]
needs = "Session.sql"
reason = "The TypeScript package cannot run SQL yet."
```

The tab for that language then reads **Not yet in TypeScript**, followed by the reason. It never
shows a translated guess. Two checks keep the marker honest:
- **`needs` names a symbol of that language's reference** ([section 4](#4-the-reference)). When that
  symbol appears in the reference (the TypeScript package gains `Session.sql`), the example fails
  the build with `group-and-count: TypeScript now has Session.sql; write example.ts and remove
  [missing.typescript]`. A missing language therefore cannot outlive the gap that caused it.
- **A language is either missing or present, never both.** An `example.ts` next to a
  `[missing.typescript]` entry fails, and so does an example with neither.

There is a second way a tab can be empty: the code exists and runs, but the package it needs is not
published in a release a reader can install. The generator decides this from files the repository
already has, not from a list kept for the site:
- **Python.** The package is on PyPI.
- **TypeScript.** Until [node/package.json](../../node/package.json) stops being `"private": true`,
  every TypeScript tab on a released page reads **Not yet released for TypeScript**.
- **Mojo.** A Mojo example is released when every komira library it imports is in `PACKAGES` of
  [release/readme_e2e/packages.bzl](../../release/readme_e2e/packages.bzl), the libraries published
  on mopm. Otherwise the tab reads **Not yet on mopm** and names the unpublished library and its
  reason from [release/UNPUBLISHED.md](../../release/UNPUBLISHED.md).

On the `next` site, built from `main` ([section 8](#8-versions)), such a tab shows the code with an
**unreleased** label, since the code ran in the check.

### 3.6 The recipes

Each recipe is one example and a few paragraphs. The first set, with the state of each today:

| Recipe | State today |
|---|---|
| Query every Parquet file in a directory | Python runs it; Mojo through `sdk_exec.run_sql`, not on mopm; TypeScript has no `sql` |
| Read a CSV file with a delimiter and no header | Python (`register_csv`); TypeScript refuses `registerCsv` |
| Join two files | Python |
| Group and aggregate, in SQL and as a frame | Python (`groupby`, `agg`) |
| Stream a large result batch by batch | Python (`Result.to_reader`) |
| Hand a result to pandas or polars | Python (`to_pandas`, `to_polars`) |
| Limit memory and threads | Python (`Session(memory_limit=, threads=)`); TypeScript refuses both options by name |
| Cancel a long query | Python (Ctrl-C) |
| Write a result to Parquet with `COPY ... TO` | Python and Mojo through SQL |
| Tell a parse error from a bind error | Python (`ParseError`, `BindError`) |
| Show the plan of a query | Python (`DataFrame.explain`) |
| Read a table from an object store | specified |
| Read an Iceberg table from your catalog | specified |
| Call a Python function from a query (a UDF) | specified |

### 3.7 The checks and their negative cases

Each check of this section is a test with a case that fails on the defect it exists for (T15):

| Check | Its negative case |
|---|---|
| An example's output equals its expected file | an example whose expected file has one changed byte fails, naming the example, the language and the first differing line |
| The three canonical files equal `expected.tsv` | an example whose Mojo file sorts rows differently from the others fails |
| A page includes only examples that exist | a page naming `example no-such-example` fails |
| No untested code fence on a page | a page with a ` ```python ` block fails, naming the page and its line |
| A missing language has expired | an example marked `[missing.typescript] needs = "Session"`, which exists, fails |
| Missing and present are exclusive | an example with both `example.ts` and `[missing.typescript]` fails |
| The marker line is there once | a file with the marker twice, and one without it, both fail |

## 4. The reference

### 4.1 One model, three extractors

Each language has an extractor that writes the package's public API as one JSON document in a
shared form, the reference model. The site generator renders all three models with one set of
templates, so a Python class page and a TypeScript class page look the same and link the same way.

A model lists the public symbols: each one's dotted path, kind (module, class or struct, function,
method, property, constant, error), signature as the language spells it, one summary line, a body
of prose, its parameters (name, type, description), what it returns, and what it raises or throws.

| Language | Extractor | What it reads | What is public |
|---|---|---|---|
| Python | `//python:reference`, a program on the pinned CPython using only the standard library's `ast` | the package sources: docstrings, and the type annotations written inline. The package ships `py.typed` and no `.pyi` files, so the inline annotations are its type stubs. Should a `.pyi` file be added, its signature wins over the source's. The package is never imported. | the names in `komira.__all__` and their public members |
| TypeScript | `//node:reference`, a program on the pinned Node that uses the TypeScript compiler API of the pinned `typescript` in [node/devtools](../../node/devtools/README.md) | the package's types, the same declarations `tsc` writes to `dist/*.d.ts`, and their doc comments | the exports of [node/src/index.ts](../../node/src/index.ts) |
| Mojo | `//tools/build/site:mojo_reference`, a Zig program that converts the JSON of the existing [`mojo_doc_json`](../../tools/build/mojo/doc.md) rule | `mojo doc` output for each library: signatures, parameters and doc strings | every declaration `mojo doc` emits, which leaves out names starting with `_` |

The Python and TypeScript extractors are written in the language they read and tested in it (T11).
Each is part of its package's build, not build tooling under `tools/build`, so B7's Zig rule does not
apply to them; the [Decisions](#15-decisions) list states that reading. Neither adds a dependency:
the Python one uses the standard library, and the TypeScript one uses the compiler the package is
already built with.

The Mojo reference covers the libraries published on mopm. A library not on mopm has no reference
page on the released site, because a reader cannot install it, and has one on `next`.

### 4.2 One docstring form in all three languages

The docstrings today are plain prose. None of the 53 Python docstrings of the public surface has an
`Args:`, `Returns:` or `Raises:` section, and none of the 74 doc comments in `node/src` has a
`@param`, `@returns` or `@throws` tag ([the audit](#132-python)). A generator can only copy such prose.
It cannot fill in a parameter table.

Each language keeps its own spelling for the same three parts:

| Part | Python | TypeScript | Mojo |
|---|---|---|---|
| Parameters | `Args:` section | `@param name` | `Args:` section |
| Result | `Returns:` | `@returns` | `Returns:` |
| Errors | `Raises:` with the error class | `@throws {ErrorClass}` | `Raises:` |

The first line of every docstring is a one-sentence summary. Docstrings hold no examples. The
examples live in `site/examples/` and are tested ([section 3](#3-examples-in-three-languages)).
Docstrings also do not cite `docs/design/` paths, because the reader of a reference page cannot
follow them.

### 4.3 The checks on the reference

- **Complete.** The extractor fails when a public symbol has no summary line, when a parameter of
  its signature has no description, or when a described parameter is not in its signature. It holds
  at 100% for the Python and TypeScript packages, which are small (19 names in `komira.__all__`; 13
  exported names in `node/src/index.ts`, values and types). For Mojo it holds for every library an
  example imports. For the other published libraries it is reported in the census of
  [readme_api_coverage.md](../readme_api_coverage.md) and does not fail. Its negative cases: a
  function with an undescribed parameter fails, and so does a description of a parameter the
  function does not have.
- **Prose names real symbols.** A page or docstring that names a symbol in backticks with its
  package prefix (`komira.Session.sql`, `Session.registerParquet`) is checked against the model,
  and an unknown name fails the build with the page and line. So a renamed or removed function
  cannot leave a guide pointing at it. Its negative case is a page naming `komira.Session.query`.
- **Examples per symbol.** Each reference page lists the examples whose shown part uses the symbol,
  found the way the README API coverage lint finds a README's uses today. A symbol no example uses
  is listed in the census, and nothing fails.

## 5. Status on a page

The site uses one status vocabulary and no other:

| Mark | Meaning | Where it comes from |
|---|---|---|
| *(none)* | built, released, and every example on the page ran | the default |
| **specified** | designed and not built; B24's tag | `status = "specified"` at the top of the page or section. Such a page holds no example tab, and links its design document |
| **Not yet in TypeScript** (Python, Mojo) | this example has no code in that language | `[missing.<lang>]` in `example.toml`, with the reason |
| **Not yet released for TypeScript**, **Not yet on mopm** | the code runs in the check, and the package a reader would need is not published | derived ([section 3.5](#35-a-language-that-does-not-have-the-example-yet)) |
| **unreleased** | shown only on `next` | the `next` build |

The design index's labels ("design, not built", "design, partly built", "port, not built", "coming
with X") stay in `docs/` and are not copied to the site.

## 6. mopm on komira.dev

### 6.1 One source, in the mopm repository

mopm's documentation is written in the mopm repository, next to the code it describes, so a mopm
change and its docs land in one pull request (T19). komira.dev renders it under `/mopm/`. mopm.dev
remains the registry (search, package pages, versions and sign-in), and its `/docs/` pages redirect
to komira.dev's. The text exists once and is read in one place.

To get the text, each mopm release publishes its documentation, the Markdown pages and the generated
references of section 6.3, as one archive attached to the release. komira pins that archive by URL
and SHA-256 next to the mopm it builds with (`toolchains//:mopm_*`, named by MOPM in
[packages.bzl](../../release/readme_e2e/packages.bzl)), and bumps it the same way as other pins. So
the mopm section of a komira.dev release documents the mopm that release was built and tested with,
and says which version that is at the top of every page.

### 6.2 What mopm's documentation needs

The audit ([section 13.5](#135-mopm)) finds the mopm docs thin in four places. komira.dev expects:

| Page | What it holds | Today |
|---|---|---|
| Install | only the methods that exist: the install script and the release archives, for each platform mopm is released for. apt and Homebrew marked specified | `getting-started.md` presents apt and Homebrew next to the working methods |
| The manifest | every key of `mopm.toml`, generated ([6.3](#63-generated-mopm-references)) | `spec/mopm-toml.md` is titled draft, and its example uses `homepage` and `keywords`, which the parser refuses |
| Building and testing | `mopm new`, `build`, `run`, `test`, `add`, `lock`, `update`, with Mojo examples the mopm check runs | in `getting-started.md` and `mopm-test.md` |
| Publishing | a package and a workspace, `stage`, group status and abort, `--oidc` from CI | `publishing-a-workspace.md`; single-version yank has one sentence |
| The registry | namespaces and organisations, who may do what, renames, versions (MAJOR.MINOR.PATCH, no pre-release), yank and unyank, takedowns, tokens and their scopes, `whoami`, `health` | no page; parts are in `getting-started.md`, `why-and-design.md` and the unrendered `docs/design/namespaces.md` |
| The CLI reference | every command with its usage, flags and long help, generated | the registry commands are documented only by `--help` |
| Using komira's libraries from Mojo | `mopm add komira-ai/<library>`, the `komira-ai` namespace, which libraries are published and why the others are not | not written; [UNPUBLISHED.md](../../release/UNPUBLISHED.md) holds the reasons |

Stale text is fixed at its source in mopm. For example, `why-and-design.md` says there is no
`mopm search`, and the CLI has one. The last row is komira's own page and lives in this repository.

### 6.3 Generated mopm references

Two mopm pages are generated, so that they cannot drift from mopm's code:
- **The CLI reference** comes from the command table that already holds every generated command's
  summary, usage and long help (`src/cli/registry_commands.zig` in mopm), plus the usage of the
  hand-written commands.
- **The manifest reference** comes from the manifest reader's key lists (`src/core/manifest.zig`)
  and a description beside each key. A key the reader accepts and the page does not describe, or a
  key the page describes and the reader refuses, fails mopm's build.

Both generators are Zig programs in mopm, with Zig tests.

## 7. Build

### 7.1 One target

`./buck2 build //site:dist` writes the whole site for one version as a directory: HTML pages, one
stylesheet, a small script, the search index and the input files the examples read (so a reader can
download them). It builds on the farm like every target. Its parts:

| Target | What it does |
|---|---|
| `//site:examples_python`, `//site:examples_typescript`, `//site:examples_mojo` | run and compare every example ([section 3](#3-examples-in-three-languages)) |
| `//python:reference`, `//node:reference`, `//tools/build/site:mojo_reference` | the three reference models ([section 4](#4-the-reference)) |
| `//third_party/mopm:docs` | the pinned mopm documentation archive ([section 6](#6-mopm-on-komiradev)) |
| `//tools/build/site:generate` | the generator: Markdown pages, models, example results and mopm docs in; the site out |
| `//site:browser` | the script for the tabs and for search, TypeScript compiled by the existing `tsc_build` rule |
| `//site:dist_check` | the checks on the output ([7.3](#73-what-the-output-may-hold)) |

The generator is a Zig program under `tools/build/site`, with Zig tests, one test target per
scenario (B7). It reads Markdown with the Zig reader that the README examples tool and the doc link
check already share ([tools/build/markdown](../../tools/build/markdown/BUCK)), and adds an HTML
writer to it. It holds no Python (B5) and runs no shell action (B4).

### 7.2 The script a reader's browser runs

The site works without a script. With the script off, every tab's code is shown one after another,
and search is a link to the reference index. The script does three things: it switches tabs, it
remembers the reader's language in browser storage so every page opens on it, and it runs search.
It is TypeScript built by the pinned `tsc` and has no runtime dependency. Its tests run on the pinned
Node at the 99% floor (T1).

### 7.3 What the output may hold

`//site:dist_check` holds the output to the same limits mopm.dev's site holds itself to:
- only `.html`, `.css`, `.js`, `.json` and the example input files;
- no inline script or style, so the pages run under a Content Security Policy of `'self'`;
- asset names that carry a hash of their content and nothing from the clock or the commit, so two
  builds of one commit are byte-identical;
- a size budget per page, for the script and for the search index;
- no link to a page or anchor that the output does not contain.

Each limit has a negative case: an output with an inline `<script>`, a page over budget, and a dead
anchor each fail.

### 7.4 What the pull-request check does with it

`//site:dist` is an ordinary target, so the check builds it when a change reaches it: a page, an
example, a docstring or a doc comment, or the code an example runs. That is the whole of "CI tests the
docs". There is no new job and no preview deploy. A preview would be a cloud write from a pull request
(S3). A reader of a pull request who wants to see the pages builds `//site:dist` and opens the
directory.

## 8. Versions

komira has no release tags and no version of its own. Each package carries `0.1.<n>`, numbered by the
workflow that publishes it ([releases.md](../releases.md)). The docs follow what a reader can install,
so the site is versioned by release:

- **A released site is built from the commit a release was built from.** `pypi.yml` builds each
  release from a known commit, which it passes to the build as `-c komira.package_commit` beside
  the stamp `-c komira.package_stamp`. A deploy names the version and that commit. The workflow
  rebuilds the wheel at that commit with that stamp, and refuses to go on unless the SHA-256 matches
  the one PyPI lists for that version's wheel. This proves the site describes exactly what
  `pip install komira==0.1.<n>` gives. The check relies on the wheel build being reproducible from
  its commit and stamp. If it is not, the deploy refuses, which is the safe way to fail. Until komira
  has one release version shared by every artifact (listed as held in
  [releases.md](../releases.md#held)), a released site is named by the Python package's version,
  `0.1.<n>`. Each page's header shows what that commit published in each language: the
  Python version, the mopm libraries and their versions, and the TypeScript package's version once it
  is published.
- **The paths.** `komira.dev/` and the paths under it are the newest released site.
  `komira.dev/v/0.1.<n>/` keeps every released site that was deployed, unchanged. `komira.dev/next/`
  is built from `main`: it shows unreleased features with their label, and every page carries a
  banner pointing to the released site. Search engines are told not to index `next` and the old
  versions.
- **The version menu** lists the newest released site, `next`, and the ten newest earlier versions,
  then a link to the full list.
- **Changes per release.** The Releases section is generated from `python/CHANGELOG.md` and, once they
  exist, the TypeScript package's changelog and the mopm release notes, and links each version to its
  site.

## 9. Search

Search runs in the reader's browser over an index the generator builds, one per version. No search
service is involved and nothing is sent anywhere.
- **What is indexed**: every reference symbol (its path, kind, language and summary), every page
  heading, and the text of each section.
- **Matching**: words are split on spaces, punctuation, `_`, `.` and case changes, so `register_csv`,
  `registerCsv` and `register csv` all find the same symbol. Matching is by prefix and ignores case.
- **Ranking**: an exact symbol name first, then a symbol prefix, then a heading, then text. Results
  for the reader's chosen language come before other languages, and each result shows its language.
- **Size**: the index is split so a query loads only the parts its first letters need. Its total is
  within the budget `//site:dist_check` enforces.

## 10. Hosting and deploy

The site is static files served from an object-store bucket behind a CDN, the same shape as
mopm.dev. The repository holds no account id, bucket name, role or endpoint (S1). Those are settings
of the deploy environment.

**A deploy is a cloud action, and each one needs the owner's go.** Nothing deploys the site on a push,
a merge or a release (S3). This is a deliberate difference from mopm.dev, which deploys from `main`
by itself. If the owner later wants komira.dev to deploy on every release, that is the owner's ruling
to make, not something this design assumes.

- **The workflow.** `.github/workflows/site.yml` runs only on `workflow_dispatch`. Its inputs are
  `version` (a released `0.1.<n>`, or `next`), `commit` (the commit that version was built from;
  for `next`, the head of `main`) and `apply`, which defaults to `false`. Every step is
  one named command or Buck2 target (B4). It runs on a hosted runner with pinned actions and
  `permissions: {}` at the top (B10).
- **Dry run by default.** With `apply` false, the workflow builds `//site:dist` at the version's
  commit on the farm and prints the plan: the files it would add, change and remove under that
  version's path, against the manifest of hashes the live site holds. It writes nothing.
- **Apply.** With `apply` true, the job runs in a deployment environment whose required reviewer is
  the owner, so the run waits for the owner's approval. It then uploads with short-lived credentials
  from the workflow's identity token. The role trusts only this workflow on `main`. The upload never
  touches another version's path. Pointing `komira.dev/` at a version is its own step in the same
  run, so rolling back means pointing it at an earlier version.
- **The first setup is the owner's alone**: the komira.dev domain and its DNS, the certificate, the
  bucket, the CDN and the deploy role. Until those exist, the workflow's dry run works and its apply
  refuses, naming the setting that is missing.

## 11. What changes in this repository

| Today | On komira.dev |
|---|---|
| [docs/install.md](../install.md), held to the quickstart by `//python/smoke:install_page_shows_quickstart` | the site's Python install page; the check that holds it follows it |
| [python/examples/quickstart.py](../../python/examples/quickstart.py) and its expected output | the `quickstart` example; the PyPI README's copy stays held to it by `//python/smoke:readme_shows_quickstart` |
| [python/README.md](../../python/README.md), 590 lines of user and contributor material | a short PyPI description that links to komira.dev; its module and test tables move to a contributor page in `python/` |
| [node/README.md](../../node/README.md), an engineering document with no install line or example | the npm description: install, one example, a link to komira.dev; the engineering part stays for contributors |
| [README.md](../../README.md) | says what komira is and links to komira.dev for using it, and to `docs/` for working on it |
| docstrings and doc comments in prose | the sections of [4.2](#42-one-docstring-form-in-all-three-languages) |
| [docs/getting-started.md](../getting-started.md), a contributor guide under a user's title | keeps its content, under a contributor title |

## 12. The rules this design is held to

- **B24**: install, then demo, then why; unbuilt features marked specified; demos replay real runs;
  other products described only as "not completely open source".
- **B21**: guides state DuckDB parity as the rule and name each representation departure as the
  engine does. They never promise a result the engine refuses.
- **P10 and T19**: a change in behaviour changes its example's expected files in the same pull
  request. A renamed symbol fails the prose check until every page is updated.
- **T11 and T12**: each runner and extractor is tested in its own language. Examples are hermetic.
- **B9**: no new pull-request job; the site is targets the check already builds.
- **S1, S3**: nothing secret or account-specific is committed. Deploying is the owner's step and
  defaults to a dry run.
- **B5 and B7**: the generator is Zig; Python runs only as the Python package's own build.

## 13. The audit: what exists today

The audit read `docs/`, the READMEs, `python/` and its docstrings, `node/`, the Mojo libraries
under `src/`, and the mopm repository's `docs/`, `spec/` and `site/` at the head of its `main`.
Each count below names the command that gave it. Each problem names the file it was read in.

### 13.1 komira's user documents

| What exists | What is wrong or missing |
|---|---|
| [README.md](../../README.md) | It says "Supported today: Linux x86_64" and offers `pip install komira` for Linux x86_64, while [install.md](../install.md) and `python/README.md` say the wheel also installs on macOS 11 or newer on Apple silicon. |
| [docs/install.md](../install.md), the one user guide | It is Python only. Its list of what works names `read_parquet`, filters, column selection, computed columns, `sort_values` and `head`, and never mentions `read_csv`, `read_json`, `groupby`, `agg` or `drop_duplicates`, which `komira.__all__` exports (`grep -c 'groupby\|read_csv' docs/install.md` is 0). It explains `to_arrow` and `to_reader`, and leaves out `to_pandas` and `to_polars`. |
| [docs/getting-started.md](../getting-started.md) | Its title says getting started, and its content is for contributors: clone, buck2, the first build. |
| [docs/index.md](../index.md) | It lists authorities, almost all of them design or build documents, and contradicts itself: its Python package row says "design, partly built" and its SDK row says "design, not built" for the same document. It also says the TypeScript package is "design, not built", while `node/src` builds a package. |
| [docs/releases.md](../releases.md) | It names two channels, mopm and PyPI, and never mentions npm. Its conda section describes targets for a channel it says is no longer published to. |
| `docs/design/` | 60 documents (`git ls-files 'docs/design/*.md' \| wc -l`). They are the only place the concepts are explained: the engine, plans, Arrow, object stores and Iceberg. They are written for people building komira. |
| Guides, concepts, recipes | None exist: no SQL, pandas or polars guide, no concept page for a user, and no recipe. |

### 13.2 Python

| What exists | What is wrong or missing |
|---|---|
| `komira.__all__`: 19 names (counted with `ast` over `python/komira/__init__.py`): `Session`, `Result`, `DataFrame`, `Series`, `GroupBy`, `read_parquet`, `read_csv`, `read_json`, `abi_version`, `__version__` and nine error classes | No reference exists, generated or written. `python/README.md` is the reference today, mixed with contributor tables. |
| Docstrings: all 53 public classes, functions and methods have one. The count, made with `ast` over `python/komira/`, covers `Session`, `Result`, `DataFrame`, `Series`, `GroupBy`, `KomiraError`, `read_parquet`, `read_csv`, `read_json` and `abi_version`, and those classes' methods whose names do not start with `_` | Prose only: 0 `Args:`, 0 `Returns:`, 0 `Raises:`, 0 examples. Several cite `docs/design/` paths. |
| Inline type annotations on almost every function; `py.typed`; no `.pyi` (`find python -name '*.pyi'` finds none) | Nothing to fix for the reference: the inline annotations are the stubs. |
| [python/examples/quickstart.py](../../python/examples/quickstart.py) and its expected output, held to the README and the install page by Zig tests; [analysis_job.py](../../python/examples/analysis_job.py), run by `//python:analysis_job_test` | This is the only tested-example pattern for Python, and it covers two programs. The README's other code blocks are not run by any check the audit found. |
| [python/CHANGELOG.md](../../python/CHANGELOG.md) | One release recorded, `0.1.1512`, with no SQL. SQL, the frames, CSV and JSON, the memory limit and Python 3.11 and 3.12 are under "Unreleased". A site built from `main` would describe what `pip install` does not give, which is why the released site is built from the release's commit ([section 8](#8-versions)). |
| The private modules for credentials, Iceberg and UDFs | They are private and outside `__all__`. The site documents them only as specified concepts. |

### 13.3 TypeScript

| What exists | What is wrong or missing |
|---|---|
| `node/src`: TypeScript sources built to `dist/` with declarations by `//node:dist`; exports `Session`, `registerParquet`, `abiVersion`, `version`, four error classes and five types ([node/src/index.ts](../../node/src/index.ts)) | `Session` has no `sql` and there is no `Result`. `registerCsv` and `registerNdjson` check their arguments and then refuse, and so do the `threads` and `memoryLimit` options. |
| [node/package.json](../../node/package.json): `"private": true`, version `0.0.0`, and the name `@komira-ai/komira`, which the README calls a placeholder | Nothing is on npm. |
| 74 doc comments in `node/src` | Prose only: 0 `@param`, `@returns`, `@throws` or `@example` (`grep` over `node/src/*.ts`). No TypeDoc or API Extractor in the repository or its pins. |
| [node/README.md](../../node/README.md) | It documents the addon and the loader, with no install line and no example. There is no `node/examples/`. |

### 13.4 Mojo

| What exists | What is wrong or missing |
|---|---|
| 262 Mojo libraries under `src/`: 264 directories besides `src/tests/`, less `udf_abi` and `udf_python`, which hold only C. Each directory has a `README.md` | 220 of the 264 READMEs have a ` ```mojo ` example (`grep '^```mojo'` per README). [readme_api_coverage.md](../readme_api_coverage.md) records 401 of 6975 public symbols used by an example, in a dated census over 182 packages, fewer than the 264 directories today. The lint does not enforce. |
| README examples compiled and run as welded tests ([tools/build/mojo/README.md](../../tools/build/mojo/README.md#readme-examples)), and again against the installed package from mopm | This is the tested-example mechanism the site's Mojo runner reuses. It runs only Mojo. |
| `mojo_doc_json` ([doc.md](../../tools/build/mojo/doc.md)): `mojo doc` JSON, golden-checked | One library (`kg_code`, which reads the JSON to build graph nodes) and the example in `tools/build/examples` use it. Nothing renders it as pages. |
| Running SQL from Mojo: `sdk_exec.run_sql(ctx, text)` ([src/sdk_exec/README.md](../../src/sdk_exec/README.md)) | `sdk_exec` is not on mopm ([UNPUBLISHED.md](../../release/UNPUBLISHED.md): it depends on unpublished libraries). The `sdk` package exports nothing yet. A Mojo user cannot install a way to run SQL. |
| 66 libraries on mopm (`PACKAGES` in [packages.bzl](../../release/readme_e2e/packages.bzl)) and 196 not, each with its reason | No user page says which libraries can be installed or how. |

### 13.5 mopm

Read in the mopm repository at the head of its `main`.

| What exists | What is wrong or missing |
|---|---|
| mopm.dev: a static site in TypeScript with its own Markdown renderer, rendering eight docs pages (`DOC_PAGES` in `site/src/links.ts`) and package READMEs, deployed from `main` by its promote workflow | No API reference, though one is designed (`docs/design/mopm-dev.md`, which still says "proposal" and "not merged"). |
| `docs/why-and-design.md`, shown on mopm.dev | Stale: "There is no `mopm search`", while the CLI defines `search` in `src/cli/registry_commands.zig`. |
| `spec/mopm-toml.md`, the manifest page, titled "(draft)" | Its example uses `homepage` and `keywords` under `[package]`, and the parser refuses both (`src/core/manifest.zig`). The caveat is on other pages. |
| `docs/getting-started.md` install section | apt ("available once the repository is set up") and Homebrew ("planned") are listed next to the methods that work. |
| The registry commands: `yank`, `unyank`, `token create\|list\|revoke`, `search`, `package info\|versions\|version`, `namespace info`, `whoami`, `health` | Documented only by `--help`. Single-version yank has one sentence in `publishing-a-workspace.md`, and token scopes are explained nowhere. |
| `docs/design/namespaces.md`: namespaces, organisations, renames, who may do what | Not on mopm.dev, so there is no registry page a user can find. |
| `docs/tutorial-author-guide.md` | An authoring guide for the tutorial, not a user page. |

### 13.6 Build, CI and hosting

- No workflow in komira deploys a website, and nothing in either repository names komira.dev
  (`grep -rn 'komira.dev'` over both).
- No komira tool writes HTML. The Markdown reader in `tools/build/markdown` serves the README examples
  and the doc link check.
- `release.yml` and `pypi.yml` ignore pushes that change only `docs/**` or `**.md`. That does not
  matter to this design, since no release triggers a site deploy.
- Node, `tsc` and `apache-arrow` are pinned with SHA-256 (`third_party/node/pins.bzl`,
  `node/devtools`). The browser script and the TypeScript extractor need nothing more.

## 14. What this design leaves out

- The site's visual design: colours, type and layout. It follows these rules, and its look is a
  separate review of the built pages.
- Interactive notebooks or a sandbox that runs a reader's code. mopm.dev has a tutorial sandbox; this
  site does not run code for readers.
- Translations.
- Docs for the Excel SDK and for the job manager. They get sections when they ship.

## 15. Decisions

Each point below was decided in this design. A line says why.

1. **Examples are files, and pages include them by name.** This makes untested code on a page
   impossible, where extracting code from page fences would only make it unlikely.
2. **Two comparisons per example: printed output per language, and one canonical table across
   languages.** The first is what B24 asks of a demo. The second proves the three tabs compute the
   same thing.
3. **A missing language names the symbol it needs, and the build fails once that symbol exists.**
   An honest "not yet" then cannot go stale.
4. **Released tabs are decided from existing files** (`package.json`'s `private`, `PACKAGES`,
   `UNPUBLISHED.md`). A list kept only for the site would be a second source of truth.
5. **Each extractor is written in the language it reads, and the renderer is Zig.** Python's `ast`
   and the TypeScript compiler read their own languages exactly, and neither adds a dependency. The
   renderer is build tooling, so B7 makes it Zig.
6. **One docstring form with three spellings.** It gives the generator parameter and error tables
   in every language, and stays idiomatic in each.
7. **The reference completeness check is enforced for Python, TypeScript and the Mojo libraries the
   examples import, and reported for the rest.** Enforcing it on all 6975 Mojo symbols at once would
   block unrelated changes.
8. **mopm's docs are written in mopm and rendered on komira.dev, and mopm.dev's docs pages
   redirect.** The text stays next to the code it describes and is read in one place. mopm.dev stays
   the registry.
9. **Versions are named by the Python package's version until a shared release version exists.**
   It is the one version a reader of today's site can install.
10. **Every deploy waits for the owner, starting from a dry run.** A deploy is a cloud write, so S3
    applies. This is unlike mopm.dev.
11. **No preview deploys of pull requests.** A preview would be a cloud write from a pull request.
    Building `//site:dist` locally shows the same pages.
12. **Search is a static index in the browser.** No service to run or pay for, and nothing about a
    reader leaves the page.
