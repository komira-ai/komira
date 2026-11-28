# Design: pivots whose output columns are decided by the data

Status: design, not built; the decision of section 2 is the owner's. Nothing in this document exists in the
code yet, and every "today" names the file it rests on. No komira code was built or run to write it.
pandas, polars and Spark are cited from their source at a named release tag: pandas `v3.0.6` and polars
`py-1.44.2`, the versions komira's skins implement
([third_party/python/README.md](../../third_party/python/README.md)), and Spark `v4.0.0`. The only program
run was DuckDB 1.1.3, and each behaviour observed with it says so. That version is older than the pinned
oracle (1.5.6, [third_party/duckdb/README.md](../../third_party/duckdb/README.md)), so the slice that
relies on a behaviour checks it against 1.5.6 (section 5).

## 1. The problem

A **pipeline breaker** (a sort, an aggregate, a distinct, a window) must see every input row before it
emits one. Every breaker komira has still has an output schema that is known when the plan is built: an
aggregate's columns are its group keys, then its measures, typed from the input's types
(`src/plan_ir/schema_propagation.mojo`, header). The data decides the rows, never the columns.

A pivot whose values are not listed is different. In
`df.pivot_table(index="region", columns="product", values="amount")` there is one output column per
distinct value of `product`. The output **schema** is a set of values in the data, unknown until the data
is read. Everything after the pivot needs it: resolving `pivoted["pen"]`, type checking, optimising, and
lowering to operators with fixed layouts. Every plan node komira has carries its schema, and the decoder
checks it (`PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED`, `src/plan_wire/plan_wire_codec.mojo:835`).

komira refuses every pivot today:

- the pandas-shaped `DataFrame.pivot`, `pivot_table` and `unstack`, and `komira.pivot_table`, `crosstab`
  and `get_dummies` raise `AttributeError: ... is not supported yet: the plan has no node for it`
  (`python/komira/_refusals.py:62`, `:102`);
- SQL `PIVOT` is refused at the parser in every form, values listed or not:
  `SQL not supported: PIVOT (reshaping a relation between long and wide form).`
  (`src/sql/sql_parser.mojo:1027`, tested at `src/sql/tests/test_sql_parser_statements.mojo:565`);
- the task pages show the workaround a user writes today, one `sum(CASE WHEN product = 'pen' ...)` per
  column, with the values spelled out by hand
  ([python/docs/tasks/51-make-pivot-table/page.md](../../python/docs/tasks/51-make-pivot-table/page.md),
  [53](../../python/docs/tasks/53-reshape-long-data-wide/page.md),
  [54](../../python/docs/tasks/54-cross-tabulate-two-columns/page.md)).

### Which operations are of this kind

| operation | version read | columns decided by the data? |
|---|---|---|
| `DataFrame.pivot_table`, `DataFrame.pivot`, `pandas.crosstab`, `DataFrame.unstack`, `pandas.get_dummies` | pandas 3.0.6 (`pandas/core/frame.py`, `reshape/pivot.py`, `reshape/encoding.py`) | **yes**: pandas has no argument that lists the values |
| `LazyFrame.pivot(on, on_columns, *, index, values, aggregate_function, maintain_order, separator, column_naming)` | polars 1.44.2 (`py-polars/src/polars/lazyframe/frame.py:8505`) | **no**: `on_columns` is required, because "A Polars `LazyFrame` always need to know the schema of a computation statically" (polars user guide, [`docs/source/user-guide/transformations/pivot.md`](https://github.com/pola-rs/polars/blob/py-1.44.2/docs/source/user-guide/transformations/pivot.md) at `py-1.44.2`) |
| `PIVOT t ON c USING agg(x) GROUP BY g`, with no `IN` | DuckDB ([PIVOT statement](https://duckdb.org/docs/stable/sql/statements/pivot)) | **yes**: "DuckDB will find the distinct values in each `ON` clause column" |
| `PIVOT t ON c IN (...) ...`, and the standard `FROM t PIVOT (agg FOR c IN (...))` | DuckDB; Spark ([PIVOT clause](https://spark.apache.org/docs/latest/sql-ref-syntax-qry-select-pivot.html)) | **no**: the values are listed, so it is an ordinary aggregate |
| `df.groupBy(g).pivot(c)` with no values | Spark 4.0.0 | **yes**, and Spark answers it the way section 3 does (section 3.6) |
| a CSV, JSON or Parquet file whose schema is inferred or read from its footer, and `SELECT *` over it | all | **no**: the schema is read at the source when the reader is called, before any plan exists (`komira_parquet_schema`, `komira_csv_binding`; [dataframe_surface.md](dataframe_surface.md) section 2) |
| `melt` / `UNPIVOT`, `explode`, `groupby().size()`, every ordinary breaker | all | **no**: their columns follow from their arguments |

## 2. The decision

Two routes were weighed, and the owner chose **Route A**:

- **Route A, in the SDK** (section 3). The engine and the C ABI do not change. A pivot verb runs a first
  plan when it is called, takes the plan's small result, and builds a new logical plan over that result
  with the distinct values as constants. Later lazy steps chain onto the new plan.
- **Route B, in the engine** (section 4). A new kind of breaker: a plan runs up to the pivot, and the rest
  of the plan is bound, optimised and lowered after it.

## 3. Route A

### 3.1 What the user sees

```python
sales = komira.read_parquet("sales.parquet")
wide = sales.pivot_table(index="region", columns="product", values="amount", aggfunc="sum")  # runs now
wide.columns                      # ['region', 'ink', 'pen'], and nothing runs
wide[wide["pen"] > 5].materialize()
```

- **The pivot verb runs a query when it is called.** It is the one kind of verb that does. The rule "No
  verb runs a query" ([dataframe_surface.md](dataframe_surface.md) section 2) gains this named exception:
  a verb whose output columns are the data's values runs its input. The verb's docstring and its page say
  so first.
- **After the call, the frame is an ordinary lazy frame.** `columns`, `dtypes` and `repr` answer without
  running, as on every frame. A column that does not exist is refused at the verb that names it
  (`KeyError`, [dataframe_surface.md](dataframe_surface.md) section 6). So the frame never has to answer
  `columns` before the pivot has run: a pivoted frame does not exist until it has.
- **A failure of the input shows at the pivot call**, as the engine's `KomiraError` with its `step` and
  `code`. Examples: a missing file, or a key of a type the grouped aggregate does not serve yet
  (`LOWERING_SINK_UNSERVED`; the key types are listed in `src/lowering/cut_aggregate.mojo`, header).
- **The pivot is a snapshot.** Running `wide` twice reads the pivot's held result twice and does not read
  the input again, so a change to the input file after the call is not seen. That is how a registered
  table behaves: "later changes to whatever the rows were copied from are not seen" (`register_arrow`,
  `src/so/sources.mojo`), and the open `Session.register` of komira-ai/komira#2467 copies a frame's rows
  at the call for the same reason.

### 3.2 The steps, reading the big input once

`df.pivot_table(values="amount", index="region", columns="product", aggfunc="sum")` does four things, on
the frame's own session:

1. **The long form.** Build `L` = `df` grouped by `index + [columns]`, with the measure built by the
   skin's own aggregate. A pandas-shaped `sum` is `coalesce(sum(x), 0)`, as in pandas (ruling 10 of
   [dataframe_surface.md](dataframe_surface.md)), and every pandas-shaped aggregate skips NaN as missing,
   as pandas does (ruling 6). With `dropna=True` (the default), `L` does what pandas'
   `pivot_table` does for it (`pivot.py`, `__internal_pivot_table`): rows whose key is NULL are dropped
   before grouping (`groupby(dropna=True)`), and long-form rows whose measures are all NULL are dropped
   after it (`agged.dropna(how="all")`). After those two steps no wide column can be all NULL, so pandas'
   third step (`table.dropna(how="all", axis=1)`) has nothing left to drop. Run `L` through
   `komira_plan_stream`. This is the only read of the input, and its result has one row per distinct
   (`index`, `columns`) pair.
2. **Hold it.** Register the Arrow result with the session under a private name that no user name can
   take, through `komira_register_arrow_stream` (ABI 1.9). That call exists; the Python
   `Session.register` that binds it is open as komira-ai/komira#2467. Make a frame over it (`from_arrow`, below).
3. **The values.** Run a second, small plan over the held table: the distinct `product` values in
   ascending order, at most `pivot_limit + 1` of them, built as a plan and never as SQL text. If it
   returns more than `pivot_limit` values, the verb raises (section 3.3). Otherwise the values, in order,
   are `D`. The engine computes `D`; the SDK does no computing of its own.
4. **The wide plan.** Return the frame
   `held.groupby("region", sort=True).agg(**{name(d): max(CASE WHEN product = d THEN amount END) for d in D})`.
   Each (`index`, `d`) has at most one row in `L`, so `max` picks that row. The verb's `fill_value` wraps
   each measure in `coalesce`. Without it, a missing cell is NULL, as pandas leaves NaN, even for
   `aggfunc="count"`.

So the input is read once, and the two later plans read only `L`. Every plan is an ordinary plan the
engine runs today. The one piece that is designed but not built is a frame over a registered table
(`from_arrow`, [dataframe_surface.md](dataframe_surface.md) section 4). The plan wire refuses an in-memory
source today (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`, `src/plan_wire/plan_wire_codec.mojo:813`). The
plan needs a scan that names a table the session registered, and the plan door binds that name to the
session's table at entry. A scan of an in-memory source is already bound to its registry at execution
(`src/plan_ir/scan_binding_bind_pass.mojo`, header), and it lowers to `SOURCE_BATCH`
(`src/lowering/cut_scan.mojo`). The scan source is additive on the wire (rule B8), and no C ABI symbol
changes: `komira_plan_stream` already takes the session. It is slice 1.

**Names, order and types.**

- **Names.** A decided column is named by the value rendered as text, by komira's cast to VARCHAR
  ([query_semantics.md](query_semantics.md)). pandas keeps a label's own type (the integer `2024` stays an
  integer label), and komira's column names are strings. This departure is listed in section 6.
- **A clash.** A value equal to an `index` column's name is refused at the verb by name. pandas keeps the
  index apart, so it has no such clash.
- **Order.** Columns come in ascending order of the value, as pandas' `sort=True` gives. Rows are sorted
  by `index`, because `groupby(sort=True)` puts that sort above the aggregate (ruling 2 of
  [dataframe_surface.md](dataframe_surface.md)). `index` stays columns of the result, as ruling 1 of that
  document does for every verb that puts values in an index.
- **Types.** Every decided column has the measure's type, nullable.

### 3.3 The cap on distinct values

- **Spark** collects at most `spark.sql.pivotMaxValues` values, default 10000: "When doing a pivot without
  specifying values for the pivot column this is the maximum number of (distinct) values that will be
  collected without error" (`SQLConf.scala`, v4.0.0, `DATAFRAME_PIVOT_MAX_VALUES`). Its
  `collectPivotValues` fetches `maxValues + 1` values and raises "The pivot column <pivotColumn> has more
  than <maxValues> distinct values, this could indicate an error. If this was intended, set <config> to at
  least the number of distinct values of the pivot column." (`_LEGACY_ERROR_TEMP_1324`,
  `error-conditions.json`, v4.0.0).
- **DuckDB**'s setting `pivot_limit`, default 100000, is "the maximum number of pivot columns in a pivot
  statement" ([configuration](https://duckdb.org/docs/stable/configuration/overview)).
- **komira**:
  - The cap is the session's `Session(pivot_limit=...)`, DuckDB's name, with Spark's default of 10,000.
  - Step 3 asks for at most `pivot_limit + 1` values. Above the cap the verb raises
    `UnsupportedOperation`: `pivot_table(columns='product'): 'product' has more than 10000 distinct values; raise Session(pivot_limit=...) or filter the frame first`.
  - The cap bounds the number of columns, not the size of `L`, which the session's `memory_limit` bounds
    as it bounds every run.

### 3.4 The other pandas verbs

Signatures are pandas 3.0.6's, unchanged:

- **`pivot_table`**:
  `DataFrame.pivot_table(values=None, index=None, columns=None, aggfunc="mean", fill_value=None, margins=False, dropna=True, margins_name="All", observed=True, sort=True, **kwargs)`
  and `komira.pivot_table(data, ...)`. Slice 2 takes one `values` column, one `columns` column, `index`
  as a column or a list of columns, and `aggfunc` as `"sum"`, `"mean"`, `"count"`, `"min"`, `"max"` or
  `len`. It refuses the following at the call with `UnsupportedOperation`, naming the argument
  ([dataframe_surface.md](dataframe_surface.md) section 6):
  - a list for `values`, `columns` or `aggfunc`, for which pandas builds `MultiIndex` columns that a
    komira frame cannot hold;
  - `margins=True`;
  - `sort=False`, which asks for the order of first appearance, a row-order choice (section 7 of that
    document);
  - `index=None`;
  - `dropna=False`, under which pandas keeps NULL keys: a NULL `columns` value would need a column with
    no name, and pandas' NaN label has no komira spelling;
  - `observed=False` (it acts only on categorical keys, which komira has none of) and any `**kwargs`
    (pandas passes them to `aggfunc`).
- **`crosstab`**:
  `komira.crosstab(index, columns, values=None, rownames=None, colnames=None, aggfunc=None, margins=False, margins_name="All", dropna=True, normalize=False)`
  takes two `Series` of one frame. Without `values` it is `pivot_table` with `aggfunc=len` and
  `fill_value=0`, as pandas builds it (`pivot.py:1103`). `normalize` other than `False` is refused in its
  first slice.
- **`pivot`**: `DataFrame.pivot(*, columns, index=<no_default>, values=<no_default>)`.
  - `L` also counts the rows of each cell.
  - A cell with two rows raises pandas' own `ValueError: Index contains duplicate entries, cannot reshape`.
  - `index` is required, since komira frames have no index to default to.
- **`unstack`**: `DataFrame.unstack(level=-1, fill_value=None, sort=True)`.
  - pandas moves an index level into the columns. komira frames have no index, so the levels are taken
    from the group keys of the `groupby` that made the frame: for
    `df.groupby(["region", "product"])["amount"].sum().unstack()`, the frame is already `L`.
  - A frame does not record its group keys today: `GroupBy` holds `_keys`, but its result is a plain
    `DataFrame` (`python/komira/_groupby.py`, `_aggregate`; the slots in `python/komira/_frame.py`).
    Slice 5 adds a private slot, `_group_keys`, set by a `groupby` aggregate. Every later verb clears it,
    except a sort, which keeps the rows' groups. So
    `df.groupby([a, b])[v].sum().sort_values(v).unstack()` works, and an `unstack` after a filter or a
    projection is refused.
  - `level` names one of those keys (`-1` is the last), and the rest stay as rows.
  - On a frame that is not the result of a `groupby` on two or more keys, it is refused by name. The
    message names `pivot_table`.
- `get_dummies` follows the same route: the values come from one small distinct plan, and the frame is a
  projection with one `CASE` per value. It is not in this document's slices.

### 3.5 The polars skin and SQL

- **polars.** `komira.pl` mirrors polars 1.44.2, whose only pivot on a lazy frame takes the values:
  `LazyFrame.pivot(on, on_columns, *, index=None, values=None, aggregate_function=None, maintain_order=False, separator="_", column_naming="auto")`.
  - It builds an ordinary aggregate with one `CASE` measure per listed value, lazily.
  - It runs nothing at the call and needs no part of section 3.2.
  - `komira.pl` adds no pivot without `on_columns`, no `to_dummies` and no `unstack`: polars has none of
    them on `LazyFrame`.
- **SQL with the values listed.** DuckDB's `PIVOT t ON c IN (...) USING ...` and the standard
  `FROM t PIVOT (agg FOR c IN (...))` bind to the same ordinary aggregate. The answer is DuckDB's
  (rule B21), with DuckDB's names. DuckDB 1.1.3 gave the following, which the oracle test checks against
  1.5.6:
  - `v` for one measure;
  - `v_alias` for several measures;
  - the values joined by `_` for several `ON` columns;
  - a numeric suffix for a name that equals an earlier one without case: `pen_1` beside `Pen`, and
    `region_1` beside the group column `region`.
- **SQL's unlisted `PIVOT` statement is refused by name.** `Session.sql` hands the statement text to one
  `komira_sql_stream` call ([libkomira_run_abi.md](libkomira_run_abi.md) section 3), and the SQL parser
  and binder are the engine's (`src/sql`). An SDK has no parser with which to find the pivot in a
  statement and run Route A's first query for it.
  - The parser's refusal becomes specific: `SQL not supported: PIVOT without an IN list (the output columns would come from the data). List the values: PIVOT t ON c IN ('a', 'b') ...`.
  - This is a parity gap ([query_semantics.md](query_semantics.md), "PARITY GAP"): refused, not answered
    differently.
  - DuckDB itself refuses the statement form in a view: `PIVOT statements with pivot elements extracted from the data cannot be used in views.`
    (DuckDB 1.1.3).

### 3.6 What Route A costs and cannot do

- **Cost.** The big input is read once, as in Route B. Two more plans then run over `L`, which has one
  row per (`index`, `columns`) pair. `L` is copied once into the session.
- **What it cannot do:**
  - **Hand the whole pipeline to a job manager as one unit.** The plan after the pivot exists only after
    the first plan has run on the user's machine, and it reads a table held in that session. The first
    plan, the long form, can go anywhere a plan can.
  - **Optimise across the pivot.** A filter on an `index` column written after the pivot is not moved
    below it, so `L` is computed for rows the filter later drops. Writing the filter before the pivot
    avoids it.
  - **Defer the pivot.** `explain()` of a pivoted frame shows the plan over the held table, not the input.
    A pipeline built ahead of time runs its pivot part when it is built.
  - **Release `L` early.** The C ABI has no call that drops a registered table, so `L` lives as long as
    its session. Each pivot call adds one table. Registering the same private name again replaces it,
    but a frame may still read it. A later ABI call to drop a table would let a frame free its own when
    it is collected.
  - **Run on unbounded input.** There is none in the DataFrame surface today. If there were, step 1
    would never finish; Spark refuses pivot on a streaming input
    (`pivot is not supported on a streaming DataFrames/Datasets`, `_LEGACY_ERROR_TEMP_3063`, v4.0.0).
- **Prior art.** This is what Spark does. Its `pivot(pivotColumn)` is
  `pivot(pivotColumn, collectPivotValues(df, pivotColumn))`, which runs
  `df.select(pivotColumn).distinct().limit(maxValues + 1).sort(pivotColumn).collect()` before the rest is
  planned (`RelationalGroupedDataset.scala`, v4.0.0). DuckDB does the same inside one statement: the
  statement "must be translated into multiple queries", with the values held in a temporary `ENUM`
  ([DuckDB internals, PIVOT](https://duckdb.org/docs/stable/internals/pivot)). Spark reads the input
  twice. Route A reads it once, because its first query is the long form rather than the distinct values
  of the input.

## 4. Route B, not taken

An engine-level breaker would be a plan node whose output schema is unknown until it has run. Everything
above it would be an unbound plan, bound, optimised and lowered only after the node had run. It would
change every layer:

- `plan_ir`: a node with an undecided schema, and a plan above it with no schemas;
- the wire: a new arm, and a decode of a subtree whose schemas cannot be checked;
- the binder: binding late, against the decided schema;
- `sdk_exec`: a driver that runs part of a plan, holds the result across two lowerings, then binds,
  optimises and lowers the rest;
- the executor: a held result charged to the memory budget, and spilled;
- distributed runs: two optimized plans per pivot, or a plan that gives rise to another plan;
- the C ABI: progress, at least, whose total would be unknown up front.

It would unlock:

- SQL's unlisted `PIVOT` in one statement, as DuckDB answers it;
- pivots that stay lazy, with `explain()` of the whole pipeline;
- a pivoted pipeline handed to a job manager as one unit;
- optimisation across the pivot;
- the same mechanism for other operators whose columns come from their data (`get_dummies`,
  `str.split(expand=True)`);
- run-time re-planning in general, which [optimized_plan.md](optimized_plan.md) section 8.3 allows today
  only for the narrow adaptive changes it lists.

Revisit it when users need one of those things, most likely SQL parity for the unlisted `PIVOT`
statement, or a pivot inside a plan that must run under a job manager as one unit.

## 5. Slices

Each slice is one pull request, and each names its tests by the behaviour they hold. The Python tests
compare against the pinned pandas 3.0.6, polars 1.44.2 or DuckDB 1.5.6 as oracles
([dataframe_surface.md](dataframe_surface.md) section 11). pandas has no oracle test family under
`python/tests` yet (`_FAMILIES` in `python/tests/BUCK` lists `plan`, `run`, `duckdb`, `pl` and `pl_oracle`), so slice 2 adds
one. Every test writes its files in its own scratch directory and talks to no network.

| # | slice | what works after it | tests, beyond the happy path |
|---|---|---|---|
| 1 | `from_arrow` and a frame over a table the session registered: the wire scan source naming a session table, bound at the plan door (depends on `Session.register`, komira-ai/komira#2467) | `komira.from_arrow(table)` and `komira.pl.from_arrow(table)` as [dataframe_surface.md](dataframe_surface.md) section 4 designs them | an unknown or replaced name; a frame of another session; an empty table; the cross-version tests rule B8 names, for the new scan source |
| 2 | `DataFrame.pivot_table` and `komira.pivot_table` on Route A, with `Session(pivot_limit=)` | `read_parquet("sales.parquet").pivot_table(index="region", columns="product", values="amount", aggfunc="sum")`, then `wide[wide["pen"] > 5].materialize()`, equal to pandas | an empty input; one value; exactly `pivot_limit` values and `pivot_limit + 1`; a NULL key; a value whose cells are all NULL (`mean`) and one whose cells sum to 0; a missing cell for each `aggfunc`, with and without `fill_value`; a NaN in a float `values` column; `dropna=False` and `observed=False` refused; a value equal to an `index` name; a non-string value as a name; the input read once (counted at the scan's opener); each refused argument by full text |
| 3 | `komira.crosstab` | pandas' `crosstab` of two `Series` | a pair that never occurs counts 0; `normalize` refused |
| 4 | `DataFrame.pivot` | pandas' `pivot` | a duplicate cell raises pandas' message; `index` missing is refused |
| 5 | `DataFrame.unstack` | `df.groupby([a, b])[v].sum().unstack()` | `level` by name and by position; after a sort it works; after a filter, a projection, or on a frame that is not a `groupby` on two or more keys it is refused |
| 6 | SQL: the listed `PIVOT` forms as an aggregate, and the unlisted statement refused by name | `Session.sql` answers DuckDB's rows and names for the listed forms | each naming rule above, against DuckDB 1.5.6; the refusal by full text |
| 7 | `komira.pl.LazyFrame.pivot` | polars' lazy `pivot` | each argument against polars; nothing runs at the call |

The failure and boundary cases above are the complete set for Route A, because they are the inputs that
change the decided column set's size (empty, one, the cap, the cap plus one), its names (NULL, a clash, a
value that is not a string), its cells (missing, all NULL, filled), and the one read of the input.

## 6. Names and behaviours komira invents

Everything else a user sees is pandas', polars', DuckDB's or Spark's, as cited above.

| name or behaviour | where | why |
|---|---|---|
| a pivot verb runs a query when it is called | `pivot_table`, `pivot`, `crosstab`, `unstack` | Route A; the one named exception to "No verb runs a query" |
| a pivoted frame is a snapshot of its input at the call | the same | the held long form, as `Session.register` copies rows at the call |
| `Session(pivot_limit=...)`, default 10,000, and its refusal message | Python `Session` | the cap; the name is DuckDB's setting and the default is Spark's |
| non-string pivot values become string column names | pandas-shaped pivots | komira's column names are strings |
| a value equal to an `index` column's name is refused | pandas-shaped pivots | pandas keeps the index apart and has no clash |
| `unstack` takes its levels from the frame's `groupby` keys, kept through a sort and cleared by every other verb | `DataFrame.unstack` | komira frames have no index |
| `dropna=False` and `observed=False` refused | `pivot_table`, `crosstab` | a NULL label has no column name; komira has no categorical keys |
| `pivot` requires `index` | `DataFrame.pivot` | there is no index to default to |
| the refusal text of the unlisted `PIVOT` statement | SQL | a parity gap, refused by name |
| the private name of a held long form | the session's tables | never visible, and taken by no user name |
