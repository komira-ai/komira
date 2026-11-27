# SQL conformance through `Session.sql`

The cases of the SQL conformance corpus,
[`src/tests/conformance/komira_sql_conformance`](../../../src/tests/conformance/komira_sql_conformance/README.md),
run on the real engine through the package's `Session.sql`, each answer held to the one the pinned
DuckDB committed beside its case ([design](../../../docs/design/typescript_package.md), "SQL
conformance, reused"). The runner is TypeScript, the package's own language.

```sh
./buck2 build //node:sql_conformance_test
```

Nothing of the corpus is copied here. `:sql_conformance_test` stages the corpus package's targets:

| staged at | target | what it is |
|---|---|---|
| `conformance/cases/` | `:cases_tree` | every `cases/<corpus>/` directory: `<case>.sql`, `<case>.tsv`, `tables.sql` |
| `conformance/tables/<corpus>/<table>.parquet` | `:<corpus>_tables[<table>.parquet]` | each corpus's tables, written as Parquet by the pinned DuckDB from its `tables.sql` |
| `conformance/refusals.tsv`, `conformance/differences.tsv` | `:refusals.tsv`, `:differences.tsv` | the lists of the cases komira does not answer as DuckDB does, which every runner of the corpus reads |

and beside them the addon, `//src/so:libkomira[runnable]`, and the fixture corpus below.

## A run

For each corpus, in name order, a new session registers every `<table>.parquet` as `<table>`
(no runner executes `CREATE TABLE`), then runs each case in name order:

- **The query.** The case's lines but its comment lines and blank lines, trimmed and joined with a
  space, as `sql_e2e`'s corpus reader joins them, so a parse refusal's position reads line 1.
- **The answer.** `toArrow()`'s Table is written as the corpus writes DuckDB's answers
  ([`render.ts`](render.ts)): a header line, then a line per row, TAB between cells, every line
  ending in LF. NULL is an empty cell and the empty string `""`; a cell holding a TAB, LF, CR or `"`
  is quoted with `"` doubled; a float is its shortest round-trip decimal (`0.1`, `1e+300`,
  `1.5e-07`), `nan`, `-nan`, `inf` or `-inf`, read from its bits so a NaN keeps its sign; a decimal
  has exactly its scale's digits; a date or timestamp is in ISO form with `(BC)` after the date of a
  year before 1; a BLOB's bytes outside printable ASCII, and `\`, `'` and `"`, are `\xHH`; a list is
  `[a, b]`; a repeated column name gets `_<n>`, as COPY names it. A column of a type no answer holds
  (a struct, a map, an interval, a union, a FLOAT16) is refused by name, never written as other text.
- **The order.** `-- order: rows` sorts the rows as the corpus's runner does: by the text of each
  column in turn, NULL first, text by its UTF-8 bytes. `-- order: query` keeps the engine's order.
- **The comparison.** The text, header included, must equal the committed `<case>.tsv` byte for
  byte. The header and the rows are compared apart, so a column named otherwise does not hide a
  wrong value.

A case is then held to exactly one of: DuckDB's answer; its line in `refusals.tsv`, the refusal
word for word (the message of the `KomiraError` `sql` rejects with, `<step>: <reason>`); its line in
`differences.tsv`, how its answer differs (`header: got "...", want "..."`, `line <n>: got "...",
want "..."` at the first row line that differs, or both, joined by `; `). A case that does otherwise,
a listed case that answers as DuckDB, and a line naming no case or no corpus are each a problem.
Every case runs, so one wrong answer is one problem, and the failure ends with the change to the
lists that would make them hold the run, one line each:

```
refusals.tsv: + agg_exact_floats/c01_sum_groupby	execute: ...
differences.tsv: - cast_boundaries/cmp_nan_eq_self	line 4: got "3", want "2"
```

After a change to the engine, apply those lines to the two lists in the corpus package and review
the diff: a removed line is a case komira now answers as DuckDB, an added one a new refusal or a new
difference.

### A FLOAT's spelling

DuckDB writes a FLOAT's shortest decimal, except where its formatter is unsure of it and writes the
float widened to a DOUBLE instead: a candidate on an end of the float's rounding interval, or two
candidates equally close (`1378041.75`, not `1378041.8`). `render.ts` finds those cases exactly. A
few floats a hair from an end are decided by the formatter's own rounding error, and the runner can
write one of them otherwise than DuckDB does (DuckDB writes `183701088` as `183701090.0`); such a
case would show as a difference to read, never as a silent pass.

## Tests

`:sql_conformance_test` runs the files below, each its own process. [`corpus.ts`](corpus.ts) and
[`render.ts`](render.ts) are measured: every one must be loaded and their lines and branches
together must each be at least 99% covered. [`staged.ts`](staged.ts) is where the target stages
what the runs read, and the run of a corpus on a session of the real engine.

| file | what it proves | the defect it catches |
|---|---|---|
| [`render.test.ts`](render.test.ts) | each spelling against the pinned DuckDB's own: DOUBLEs positional from 1e-4 to below 1e16 and `e` outside; FLOATs from their 32-bit value, the least subnormal and normal ones, a power of two, a carry into a new digit, a tie and an end of the interval from the DOUBLE; NaN, infinities and zeros with the sign of their bits; integers of every width; decimals at 128 and 256 bits and their scale; dates before the epoch, before year 1 and past 9999; timestamps of each unit, before the epoch, before year 1, with a zone and with none (null, left out, empty); times at 32 and 64 bits; BLOBs; quoting of text cells; lists with each element DuckDB quotes and NULL; dictionaries with chunked values and an index past them; a bool read past an array's offset; repeated column names; the `order: rows` sort; an answer over two batches and an empty one; the types refused by name | a value spelled otherwise than DuckDB writes it; a NaN's sign lost; a bit or slot read at the buffer's start rather than the array's; a type written as other text |
| [`corpus.test.ts`](corpus.test.ts) | over a stand-in session: a case's order line and query; a corpus read in name order with its tables, and a case with no answer, an answer with no case, another file, no case and no table refused together; a list's lines, and a malformed line, a case listed twice and no final LF refused; the difference of headers, of rows, of both, of an extra or missing row and of the final LF; every outcome against every state of the lists (answered, refused and differing, each unlisted, listed as such, listed otherwise and listed in the other list) with its problem and its changes; an error of a status other than -3 and any other error that is no refusal, an answer that cannot be written, and a thrown non-Error as problems that change no list; a table that cannot be registered as one problem with none of its corpus's cases run; a line naming no case or no corpus; the failure's text | a refusal or difference let through unlisted; a list line that went stale kept; a run failure taken for a refusal; a change to the lists left out of the failure |
| [`wrong_answer.test.ts`](wrong_answer.test.ts) | on the real engine, the fixture corpus [`fixtures/wrong_answer`](fixtures/wrong_answer/) (a table W, two cases whose committed answers are DuckDB's, and `wrong.tsv`, wrong in the one cell of `d` at `k = 2`) fails the run with exactly one problem, naming `wrong`, and the one line `differences.tsv` would need; the same corpus with that line listed is held | a runner that stopped comparing, that compares some cases only, or that reports a wrong answer under another case |
| [`sql_conformance.test.ts`](sql_conformance.test.ts) | on the real engine, every case of the 89 corpora answers as DuckDB, or is refused or differs exactly as the lists say; no line of the lists names a case or corpus that is not there; 6421 cases ran | a wrong answer, a new refusal, a changed refusal or difference, a fixed case still listed; a corpus or case left out of the run |
