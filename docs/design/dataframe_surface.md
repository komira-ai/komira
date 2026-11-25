# The Python DataFrame surface: skins, verbs and refusals

Status: design, not built. Nothing under `python/` exists yet. The verbs, the plan each one builds and
its matrix row are in [dataframe_surface_verbs.md](dataframe_surface_verbs.md). This document gives
the rules those verbs follow.

## What problem does this solve?

The first release of the Python package (`import komira`) is SQL-first: a `Session`, `sql()`, and a
`Result` read through Arrow. The DataFrame surfaces come next. Several pull requests build them: the plan
builder, the plan encoder, the frame core, group-by, joins and windows, the polars-shaped skin, and the
verbs pandas users reach for first (`fillna`, `dropna`, `concat`, `rename`, `astype`). Each of those
pull requests needs the same answers first:

- which verbs each skin has, and which plan each verb builds;
- what a skin does with a pandas or polars name it does not support;
- where pandas and polars answer differently from the plan, which answer each skin gives.

This document answers them by porting the earlier, never-published SDK's DataFrame surface design and
mapping it to the matrix rows. Where the port keeps that design's answer, this document states it once.
Every point where the port differs from the earlier SDK is listed, with its reason, in
[section 12](#12-rulings-that-differ-from-the-earlier-sdk). The [Python package design](python_package.md) fixes
the rest, and this document uses its names: the package
layout; the two skins and their modules; `Session` and `Result`; and `KomiraError`,
`UnsupportedOperation` and their fields.

The evidence that the surface is missing today:

- komira has no Python package.
- The Mojo side already has plan builders for five DataFrame verbs that the earlier, never-published
  Python SDK did not have: `with_columns`, `rename`, `drop_nulls`, `concat` and a frame alias
  ([src/sdk/README.md](../../src/sdk/README.md); the files are `src/sdk/dataframe_*.mojo`).
- The plan shapes that a pandas-shaped and a polars-shaped frontend emit for seventeen programs are
  pinned, without Python, by [komira_pandas_door_e2e](../../src/tests/e2e/komira_pandas_door_e2e/).
- The pandas and polars rows of the [surface capability matrix](../surface_capability_matrix.md) are
  empty: no `pandas_e2e` or `polars_e2e` package exists.

These are fixed before this design and not reopened here:

- the first release is SQL-first;
- there are two skins, each building a logical plan and submitting it through `libkomira`'s plan
  entry, never as SQL text;
- Python UDFs run in zygote worker processes;
- the client optimizes, and a job manager accepts only a serialized optimized plan.

The surface implements the pinned versions pandas 3.0.6 and polars 1.44.2
([third_party/python/README.md](../../third_party/python/README.md)).

## The decisions

### 1. Two skins over one builder

- **The pandas-shaped skin** is the top level of `komira`, beside the first release's names. It has
  frames with subscripts and bound columns: `df[df["x"] > 3]`,
  `df.groupby("k").agg(total=("v", "sum"))`, `.materialize()`.
- **The polars-shaped skin** is the submodule `komira.pl`, the package's one public submodule. It has lazy
  frames and unbound expressions: `pl.scan_parquet(...)`, `.filter(pl.col("x") > 3)`,
  `.group_by("k").agg(pl.col("v").sum())`, `.collect()`.

Here `komira` is written `km` and `komira.pl` is written `kpl`.

Both skins build one private node tree, and one private encoder turns the tree into plan bytes. Neither
skin has an intermediate form of its own. So a program that means the same thing in both skins builds
the same bytes. A test holds this (section 11), and
[komira_pandas_door_e2e](../../src/tests/e2e/komira_pandas_door_e2e/) already checks it on the Mojo
side for `groupby(sort=False)` against `group_by`.

The public names of each module:

| module | names it adds |
|---|---|
| `komira` | `DataFrame`, `Series`, `GroupBy`, `col` (pandas 3's `pd.col`), `concat`, `merge_asof`, `from_arrow`, `add_sql_binding`; the readers `read_parquet`, `read_csv`, `read_json`, `read_feather`, `read_orc`, `read_avro` |
| `komira.pl` | `LazyFrame`, `LazyGroupBy`, `Expr`, `col`, `lit`, `when`, `len`, `concat`, `concat_str`, `from_arrow`; the readers `scan_parquet`, `scan_csv`, `scan_ndjson`, `scan_ipc`, `scan_orc`, `scan_avro` |

The names `files`, `iceberg`, the credential classes, `AMBIENT`, `ANONYMOUS` and `read_table`'s catalog
argument belong to [credentials_and_writes.md](credentials_and_writes.md), and are reserved here.

- `komira.__all__` gains the names of the first row, and `komira.pl.__all__` holds the second. Every
  other module of the package stays private.
- There is no eager frame class. A frame is a plan, and running it gives the first release's `Result`.
- The polars-shaped readers keep polars' lazy word `scan_*`. polars' eager `read_*` names are refused
  in `komira.pl` with the `scan_*` spelling (the refusal tables). `scan_orc` and `scan_avro` are komira's
  own: polars has no lazy reader for either.

### 2. Every frame is lazy

No verb runs a query. A verb returns a new frame, or a new expression, holding a larger plan. A query
runs only at a **terminal**:

| terminal | pandas-shaped | polars-shaped |
|---|---|---|
| run, and return the rows as a `Result` | `DataFrame.materialize()` | `LazyFrame.collect()` |
| run, and write the rows to a file | `to_parquet`, `to_csv`, `to_json(orient="records", lines=True)` | `sink_parquet`, `sink_csv`, `sink_ndjson` |
| render the plan without running it | `explain()` | `explain()` |

- **Each skin has one verb that runs a frame, and it returns `Result`**, the class `sql()` returns. A
  `Result` is read once, through `to_arrow`, `to_reader`, `to_pandas`, `to_polars` or
  `__arrow_c_stream__`. So `df.materialize().to_pandas()` and `lf.collect().to_polars()` are the full
  spellings.
  - The pandas skin keeps the earlier SDK's word `materialize`.
  - Each skin's word is refused on the other skin's frame, by a message that names the right word.
  - A frame has no `to_pandas` of its own. The refusal tables point at the terminal.
- **Calling a terminal twice runs the plan twice.** A frame is a plan, and a plan can run again. A
  `Result` can be read only once. Nothing is cached.
- **No dunder runs a query.** `len(df)`, `bool(df)`, `iter(df)`, `df.__array__()` and
  `df.__arrow_c_stream__()` raise `UnsupportedOperation`, and the message names the terminal.
  `repr(df)` prints the column names and types, and runs nothing.
- **A reduction is lazy too.** `df["v"].sum()` is not a number: it is a `Series` aggregate. A
  `Series` aggregate works inside `assign`, inside `df[...]` and inside `agg`. The number comes from a
  terminal: `df.agg(total=("v", "sum")).materialize()`. This is a departure from pandas (section 8,
  ruling 1).
- **`explain()` returns the engine's render of the plan** (`komira_plan_render`) as text. No SQL text
  exists anywhere on this path (section 3).
- **The schema is known at every step.** A reader reads the file's schema when it is called, through
  `libkomira`'s schema calls. Every verb derives its output schema by the plan's rules. So `columns`,
  `dtypes` (pandas) and `schema` (polars) run nothing. A column that does not exist is refused at the
  verb that names it, not at the terminal.

The frames are immutable, except for one pandas idiom:

- `df["x"] = expr` replaces the frame's plan with the plan of `df.assign(x=expr)`.
- A `Series` taken from `df` before that assignment is **stale**. Using it afterwards raises
  `UnsupportedOperation`. Real pandas would use the old values, aligned by index. A lazy frame has
  neither old values nor an index.
- No other verb changes a frame in place. `inplace=True` is refused wherever pandas offers it.

### 3. The plan, the encoder and the door

- A frame's plan is a tree of the private node classes. Each verb appends nodes, and nothing renders SQL
  text.
- SQL the user writes is a different entry of `libkomira`, `komira_sql_stream`, where the library turns
  the text into a logical plan. A frame never goes through it.
- At a terminal, the encoder writes the tree as a `komira.plan.v1.WirePlanEnvelope`
  ([src/plan_proto/plan.proto](../../src/plan_proto/plan.proto)), using the generated protobuf modules
  under `komira/plan/v1/`. The session sends the bytes through the plan entry, `komira_plan_stream`.
  - The plan entry decodes the bytes with `plan_wire`, binds the scans, optimizes, lowers, runs, and
    returns an Arrow C stream.
  - A write terminal sets the envelope's `write_target`.
  - protobuf becomes a required dependency of the package with this surface, beside pyarrow, as the
    Python package design says. Its range is the plan encoder pull request's.
- **The encoder writes every node's `output_schema`.** The decoder rebuilds each node through its
  `LogicalPlan` factory and refuses a schema the factory does not derive
  (`PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED` in `src/plan_wire/plan_wire_codec.mojo`). So the builder derives
  output types by the plan's rules ([query_semantics_types.md](query_semantics_types.md)). If the Python
  derivation and the Mojo one disagree, the query is refused by name, never answered wrongly.
- **A verb that has a Mojo builder builds that builder's plan.** The builders are in `src/sdk` and
  `src/plan_expr/col_expr.mojo`, and the bytes test of section 11 holds the two plans equal.
  - The Mojo builders are the reference, because the Mojo surface and the plan decoder already share
    them.
  - Where a ruling of section 8 makes a skin answer its library's question and the Mojo builder answers
    another, the skin's plan is the builder's plan plus the nodes that ruling names, and nothing else.
    The cases are pandas `dropna` (ruling 6), `concat` (ruling 15), and `//` and `%` (ruling 9).
- **A UDF enters the plan as the plan already designs it** ([optimized_plan_udfs.md](optimized_plan_udfs.md)).
  - The envelope's `udfs` list holds a `UdfRef`.
  - A scalar UDF is called by `WireUdfApply`, a frame UDF by `WireMapBatchesNode`, and an aggregate UDF
    by `AGG_UDF`.
  - The verbs are the libraries' own (`map_elements`, `map_batches`, `Series.map`, `DataFrame.apply`)
    and are in the verb tables.
  - Until the UDF worker path lands, each of these verbs raises `UnsupportedOperation` naming the verb.
  - The UDF verbs' `return_dtype` and null mode are the UDF design's.

### 4. Readers, sessions and in-memory data

- **A reader's scan carries the file.** `km.read_parquet(path)` and the other readers build a scan
  that holds the path, the schema, and the footer facts the plan's scan needs, as the
  [komira_pandas_door_e2e](../../src/tests/e2e/komira_pandas_door_e2e/) leaves do. They register no
  table name. The Python package design's sentence "a frame's plan scans tables the session has under a
  name the user gave" is read here as: no automatic names. A frame needs no registered name, because
  its scan names the file itself. Which `libkomira` call returns the footer facts is the ABI design's.
  A missing file raises at the reader.
- **Readers take the session as a keyword.** `km.read_parquet(path, *, session=None)` uses the
  process's default session when `session` is `None`, as `km.sql` does. `Session` gains no reader
  methods, so there is one way to read a file.
- **Frames of two sessions never meet.** A verb that combines them (`merge`, `join`, `concat`, `isin`)
  raises `UnsupportedOperation`. So does adding a frame with `add_sql_binding`, or passing it to a `sql` call, on a session that is not the frame's own.
- **`from_arrow(data, *, session=None)`** makes a frame of any object that exports the Arrow C stream
  (`__arrow_c_stream__`): a `pyarrow.Table`, a polars `DataFrame`, or a pandas `DataFrame`. The stream
  is read once, when `from_arrow` is called, and registered with the session. This needs the engine's
  in-memory table, which plan bytes do not carry. Until that lands, the scan raises at the terminal.
- **A frame is a source for SQL.** `Session.add_sql_binding(name, frame)`, or `s.sql(query, name=frame)`
  for one statement, names a frame's plan so that the SQL reads it as a view (the `view` capability). `km.add_sql_binding(name, frame)` does the same on
  the default session. This is the one SQL binding of every kind of source
  ([credentials_and_writes.md decision 2](credentials_and_writes.md#2-binding-a-sql-name-on-the-session-or-for-one-call)),
  and it replaces the `register_view` of earlier drafts. The readers take objects or paths directly and
  read no SQL binding.

### 5. Attributes never fall through

The earlier SDK's `DataFrame.__getattr__` turned every unknown attribute name into a column reference.
So a pandas method komira lacked, such as `df.fillna`, raised a "no column" error, which is a
`TypeError`. `hasattr(df, "fillna")` raised instead of returning `False`. And a real column could hide
behind a method of the same name. komira's skins do not do this:

- **A name a skin does not define raises `AttributeError`.** So `hasattr` and `getattr(obj, name,
  default)` behave as Python promises, and IPython, pickle and copy probes are not affected.
- **No attribute is a column.** A column is named only as `df["x"]` (or `km.col("x")` inside `assign`)
  in the pandas-shaped skin, and as `kpl.col("x")` in the polars-shaped skin. `df.x` raises
  `AttributeError`. When `x` is a column of the frame, the message says to write `df["x"]`. So a column
  called `count`, `rename` or `head` never collides with a verb, and a verb added in a later release
  never changes what an attribute meant.
- **`__getattr__` exists only to make the error useful, and it never returns a value.**
  - A name that starts with `_` raises a bare `AttributeError` at once.
  - A name in the skin's **refusal table** ([dataframe_surface_verbs.md](dataframe_surface_verbs.md#the-refusal-tables))
    raises an `AttributeError` that says why the verb is missing and what to write instead.
  - A column name raises the `df["x"]` hint.
  - Any other name gets Python's own message.
- **`__dir__` lists only the defined members**, so completion never offers a name that would raise.
- **`__setattr__` refuses every name that does not start with `_`.** `df.x = 1` raises
  `AttributeError`, naming `df["x"] = ...` (pandas-shaped) or `with_columns` (polars-shaped). It does
  not set an attribute the plan never sees.
- **The modules do the same.** `komira` and `komira.pl` each define a module `__getattr__` (PEP 562)
  over their own refusal table. So `km.pivot_table` and `kpl.read_parquet` raise `AttributeError` with
  the replacement, while `km.Timestamp` raises Python's own.

The rule covers every public class of both skins: the frames, the group-bys, `Expr`, `Series`, and the
`.str`, `.dt` and `.struct` namespaces.

### 6. How a skin refuses

Each kind of failure has one class:

| failure | raised as | when |
|---|---|---|
| a name the skin does not define | `AttributeError` (section 5) | at the attribute lookup |
| an unknown column | `KeyError`; the message names the column, the closest existing name, and the frame's columns | at the verb or subscript that names it |
| a defined verb given an argument, or a frame, it cannot honour | `UnsupportedOperation`; the message names the verb, the argument and its value, and the spelling that works, if there is one | at that call, before anything runs |
| a plan the engine cannot run yet, or a failure while it runs | `KomiraError` (or `UnsupportedOperation`), with the engine's `step` and `code` and its message unchanged | at the terminal |

A wrong argument type or value is Python's `TypeError` or `ValueError`, as the Python package design
says.

That design says `except komira.KomiraError` catches komira's errors and nothing else. `AttributeError`
and `KeyError` join `TypeError`, `ValueError` and `ImportError` as the Python protocol errors outside
that class. Python itself and its tools (`hasattr`, `getattr` with a default, `dict`-like lookups)
expect them, and pandas raises `KeyError` for a missing column.

These rules decide which failure a case gets:

- **A skin refuses only what the surface cannot mean.** Examples: a pandas index, `inplace=True`,
  positional slices on an unordered frame, and a choice among tied rows by row order (section 7).
- **What the engine cannot run yet is the engine's to refuse.** That covers a join kind lowering cannot
  cut, a group key type with no sink, and a source with no reader. The skin builds the plan, and the
  terminal raises with the engine's step (`lower`, `execute`) and code (`LOWERING_UNCUTTABLE_NODE`, for
  example). So when the engine gains a capability, the skins reach it with no Python change, and no list
  in Python can disagree with the engine about what runs. The earlier SDK checked some engine limits in
  Python, such as NULL placement and `head(0)`, and those checks went stale when the engine moved.
- **No near miss.** A verb gives the library's answer, a departure that section 8 lists, or a refusal.
  So `merge(how="semi")`, which pandas does not have, is not invented. pandas `groupby().count()` is
  pandas' count of non-missing values per column, never `count(*)`.
- **No fallback to pandas or polars.** A skin never imports pandas or polars to compute a verb. It
  imports them only in `Result.to_pandas` and `Result.to_polars`.
- **The message is a sentence a user can act on.** It names the construct as the user wrote it, says
  why, and gives a spelling that works. It names no file, line, wire message or internal identifier of
  komira. A test checks the full text of each message (section 11).

### 7. Row order

A plan whose root is not a sort promises no row order
([query_semantics.md](query_semantics.md) §4.8), and ties within a sort come out in an unspecified
order (§4.7). Both libraries keep the input order instead. So each skin tracks one fact per frame:
whether the frame is **ordered**.

- **A sort makes a frame ordered:** `sort_values`, `sort`, `nlargest`, `top_k` and the others.
- **These verbs keep it ordered:**
  - filters;
  - a projection, rename or `with_columns`/`assign` that keeps every sort key;
  - `head`, `limit` and `slice`.

  The skin keeps the sort at the root of the plan: it places a filter or projection below the sort,
  and a limit above it.
- **Every other verb makes the frame unordered:** group-by, join, merge, `concat`, `unique`,
  `drop_duplicates`, and a projection that drops a sort key.

The rules that follow from this:

- `head(n)` and `limit(n)` on an unordered frame return some `n` rows. That is a departure from both
  libraries, which return the first `n` rows in input order.
- `tail(n)`, `slice(offset, n)` with an offset, and the group-wise `head(n)` (`topn_per_group`) need an
  ordered frame. On an unordered frame they raise `UnsupportedOperation`.
- Cumulative, rolling and shifted windows take their order from somewhere explicit:
  - polars: `over(..., order_by=...)`, or the frame's sort when the frame is ordered;
  - pandas: the frame's sort (`df.sort_values(o).groupby(k)[c].cumsum()`).

  With no order, they raise `UnsupportedOperation`. The verbs are `cumsum` and `cum_sum`, `cum_count`,
  `cummin`/`cum_min`, `cummax`/`cum_max`, `rolling`, and `rolling_*`.
- `rank` orders by the ranked values. `method="min"` and `method="dense"` are supported. `method="first"`
  (pandas) and `method="ordinal"` (polars) break ties by row order, so they are refused. pandas'
  default `method="average"` and `method="max"` have no plan function yet, so they are refused too.
- **Ties picked by row order.** pandas `drop_duplicates(subset=...)` and `nlargest`/`nsmallest`, and
  polars `unique(subset=...)` and `top_k`/`bottom_k`, choose which of several tied rows to return.
  - The library's default choice is accepted, and the skin returns any one of the tied rows. This is a
    departure from pandas' `keep="first"`, listed for users. polars' default `keep="any"` already
    promises no particular row.
  - An explicit choice that needs row order is refused: `keep="first"` and `keep="last"` in polars, and
    `keep="last"` in pandas. So are the choices that need a window first: `keep=False` in
    `drop_duplicates`, and `keep="all"` in `nlargest`.
- `sort(maintain_order=True)`, `sort_values(kind="stable")` and `unique(maintain_order=True)` are
  refused. No sort in the plan is stable.

### 8. Where the libraries and the plan differ: the rulings

Each ruling says what each skin answers:

- The polars skin answers polars 1.44.2's question.
- The pandas skin answers pandas 3.0.6's question with its default NumPy-backed numeric dtypes.
- The plan answers [query semantics](query_semantics.md).

Where a library's answer can be built from plan nodes, the skin builds it. Where it cannot, the skin
either refuses the call or gives the plan's answer. The second case is a **departure**, listed in the
ruling. Section 7's departures belong to this list as well.

Each ruling is marked **carried** (the earlier SDK's answer) or **differs** (a ruling of section 12, by
its number).

1. **There is no index.** Carried, except the integer subscript (D9) and `value_counts` (D16).
   - `loc`, `iloc`, `at`, `iat`, `index`, `set_index`, `reset_index`, `sort_index`, `reindex`, and
     pandas' index `join` are refused (use `merge`).
   - A slice subscript `df[0:5]` raises `UnsupportedOperation`.
   - An integer subscript `df[0]` is a column label, as in pandas: it names the column `0`, or raises
     `KeyError`.
   - `ignore_index=` and `to_csv(index=...)` are accepted and have no effect, because there is no index
     to ignore or to write.
   - The results of pandas verbs that put values in an index carry those values as columns instead.
     These are departures:
     - `df.agg(total=("v", "sum"))` gives a one-row frame with one column per output name, where pandas
       gives a frame indexed by the output names.
     - `df.sum()` and the other frame reductions give a one-row frame, where pandas gives a `Series`
       indexed by column.
     - `s.value_counts()` gives a frame with the value column and `count`, where pandas gives a
       `Series` named `count` indexed by value.
     - `s.sum()` and the other `Series` reductions are lazy aggregates (section 2), where pandas gives
       a number.
2. **pandas sorts its groups; polars does not.** Carried; the NULL placement of the sort differs (D4).
   - pandas `groupby(sort=True)`, the default, puts a sort on the group keys above the aggregate, with
     missing keys last.
   - `groupby(sort=False)` and polars `group_by` add no sort.
   - [komira_pandas_door_e2e](../../src/tests/e2e/komira_pandas_door_e2e/) pins this sort-above-
     aggregate structure, over a key with no NULLs. Its fixtures write `nulls_first: true`. The skin
     writes `nulls_first: false` (ruling 5), and the bytes test pins that.
3. **pandas drops missing group keys by default.** Differs (D5). `groupby(dropna=True)`, the default, filters out the
   rows whose key is missing, below the aggregate. `dropna=False`, and polars, keep the NULL group. The
   earlier SDK returned the NULL group under pandas' default, which was a silent difference.
4. **Per-column group reductions need a type that reduction is defined for.** Differs (D6).
   - `groupby().sum()`, `mean()`, `median()`, `std()` and `var()`, and the polars `group_by().sum()` and
     its siblings, reduce every non-key column. They need every one of those columns to be numeric or
     boolean. Otherwise they raise `UnsupportedOperation`, naming the first column that is not. pandas
     would concatenate strings for `sum`, or raise for `mean`.
   - `count()`, `size()`, `min()`, `max()` and `nunique()` take every type.
5. **NULL placement in a sort is always written down.** Differs (D4).
   - Each sort key carries an explicit `nulls_first` ([query_semantics.md](query_semantics.md) §4.2),
     set to the library's default. pandas puts missing values last in both directions
     (`na_position="last"`). polars puts nulls first in both directions (`nulls_last=False`).
   - An explicit `na_position` or `nulls_last` is honoured per key. No sort is refused for its NULL
     placement.
   - A window's ORDER BY cannot carry a placement yet
     ([komira-ai/komira#1227](https://github.com/komira-ai/komira/issues/1227)). So a window whose
     library default differs from the plan's raises at the terminal until that lands.
6. **Missing values.** Differs (D7).
   - polars keeps NULL and NaN apart, as the plan does: `is_null` and `drop_nulls` test NULL only, and
     `is_nan` and `fill_nan` test NaN only.
   - pandas with NumPy dtypes treats NaN as missing. So the pandas skin reads a float column as "NULL
     or NaN is missing" in every missing-value verb (`isna`, `notna`, `dropna`, `fillna`) and in every
     aggregate. `sum`, `mean`, `min`, `max`, `count`, `std` and the rest skip NaN, as pandas'
     `skipna=True` does.
   - The skin builds this from plan nodes: `x IS NULL OR isnan(x)` and
     `CASE WHEN isnan(x) THEN NULL ELSE x END`. So the pandas `dropna` plan over a float column is
     `drop_nulls_predicate`'s plan plus the `isnan` test.
   - The earlier SDK refused `isna` instead. That left pandas users no way to ask pandas' own question,
     which pandas answers without ambiguity.
7. **NULL keys match nothing**, in both skins ([query_semantics.md](query_semantics.md) §3.1). Carried.
   - polars agrees by default. `join(nulls_equal=True)` is refused until the plan has null-safe
     equality ([komira-ai/komira#1218](https://github.com/komira-ai/komira/issues/1218)).
   - pandas `merge` matches missing keys to each other, and `isin` finds a NaN in a column holding a
     NaN. Both are departures: in the pandas skin, a row with a missing key finds no partner. The tests
     of `merge` and `isin` hold this.
8. **Join output columns are each library's own.** Differs (D8). The plan's join keeps the left names, and suffixes
   a colliding right name with `_right` ([query_semantics.md](query_semantics.md) §3.14). Each skin
   adds a projection over the join, so that the output columns are its library's:
   - pandas: `on=` keys appear once (coalesced for an outer join), and other collisions get
     `suffixes=("_x", "_y")`, which the skin accepts.
   - polars: `on=` keys appear once except where polars keeps both, and collisions get
     `suffix="_right"`, which the skin accepts.

   The merge and polars join tasks pin each `how` against the pinned libraries. The plan design asks
   for this ("a frontend renames or projects first"). The earlier SDK showed the plan's names instead,
   which match neither library.
9. **Arithmetic is Python's.** Carried, except `//` and `%` (D10). In both skins:
   - `/` is true division: the left operand is cast to DOUBLE ([query_semantics.md](query_semantics.md)
     §5.1).
   - `//` floors and `%` takes the sign of the divisor, as Python, pandas and polars do.
     - The plan's division and remainder truncate (§5.1, §5.2). So does the Mojo surface:
       `src/plan_expr/col_expr_division.mojo` builds DuckDB's `//` and `%`.
     - The skins add the floor correction to the truncating node:
       `q - (CASE WHEN r <> 0 AND (r < 0) <> (b < 0) THEN 1 ELSE 0 END)` for `//`, and
       `r + (CASE WHEN r <> 0 AND (r < 0) <> (b < 0) THEN b ELSE 0 END)` for `%`. Here `q` and `r` are
       the plan's quotient and remainder of `a` by `b`. These two verbs are the bytes test's stated
       exception: the Python plan is the Mojo plan wrapped in this correction.
   - Integer division and remainder by zero give NULL (§5.3). polars agrees. pandas departs: it gives
     inf or NaN.
   - Integer overflow raises an error naming the operation (§5.5). Both libraries wrap, so both skins
     depart: an error is safer than a wrapped value.
10. **A sum of nothing is 0.** Differs (D11). pandas (`min_count=0`) and polars both answer 0 for the sum of an empty
    or all-missing group, where the plan answers NULL (§2.2). So both skins build `coalesce(sum(x), 0)`.
    - `mean`, `min` and `max` of nothing stay NULL, which `to_pandas` shows as NaN.
    - The integer sum type is INT64 (UINT64 for unsigned) through the DataFrame doors. A total outside
      it is an error naming the column ([query_semantics_rulings.md](query_semantics_rulings.md) §8.1,
      §8.2).
11. **Counting rows and counting values are different verbs.** Carried, except `groupby().count()` (D6).
    - `count(*)` is polars `kpl.len()` and `group_by(k).len()`, and pandas `size()` and
      `agg(n=("c", "size"))`.
    - Counting non-missing values is polars `col("c").count()`, and pandas `count()` and
      `agg(n=("c", "count"))`. pandas counts NaN as missing (ruling 6).
    - polars' deprecated `pl.count()` is refused, because it names both questions.
12. **Unaliased outputs take the library's name.** Carried.
    - polars names `col("a") * 2` after its leftmost column (`a`), and an unaliased aggregate after its
      input column. That is the rule `select_aggregates.name_unaliased` and `agg_output_naming` apply on
      the Mojo side.
    - Two outputs with one name are refused at the verb.
13. **Float aggregates are not bit-reproducible** (carried) across runs and worker counts (§2.10), except a float
    sum or mean, ungrouped or per group, which the engine folds in source position order. Tests compare float sums and means with a
    stated tolerance. Neither library promises more for parallel input.
14. **Types.** New with the verbs that take a dtype (D17).
    - A dtype argument (`astype`, `cast`, `return_dtype`) is a `pyarrow.DataType`, or a name from the
      fixed table in the verbs document. komira adds no dtype classes of its own.
    - pyarrow and protobuf are the package's required dependencies, and pandas and polars are optional.
    - Results arrive as Arrow and convert through the `Result` terminals.
15. **`concat` matches columns by name, and needs one type per column.** New with the verb (D17).
    - The Mojo builder matches by position and takes the first input's names.
    - polars `how="vertical"` needs equal names in equal order, so the polars skin refuses anything
      else.
    - pandas aligns by name. So the pandas skin reorders an input whose column set equals the first
      input's, with a projection the skin adds. It refuses a different set, where pandas would fill the
      missing columns with NaN.
    - Types must be equal in both skins. pandas would upcast a mismatch, so that refusal is a pandas
      departure.
    - With equal names in equal order, the plan is the Mojo builder's.
16. **`isin` with another frame's column is a semi join.** Carried, except `isin` with a list (D12). `df[df["k"].isin(o["k"])]` builds a
    `JOIN_SEMI`, and `df[~df["k"].isin(o["k"])]` builds a `JOIN_ANTI`. Each returns `df`'s columns. That
    form is accepted only as the whole predicate of a subscript. Anywhere else, `isin` with another
    frame's column raises `UnsupportedOperation`: inside `&` or `|`, in `assign`, or as a value. Placed
    there, it would need a subquery inside an expression, which neither library has. `isin` with a list
    is an expression and works everywhere.

### 9. Verbs the Mojo surface has and the Python skins lack

The five `src/sdk/dataframe_*` builders, and the Python verbs that build each one's plan:

| Mojo builder | pandas-shaped | polars-shaped | plan |
|---|---|---|---|
| `build_with_columns_plan` | `assign(...)`, `df["x"] = ...` | `with_columns(...)` | one PROJECT: input columns in order; a derived column with an existing name replaced in place; new ones appended in order; two derived columns with one name refused |
| `build_rename_plan` | `rename(columns=...)`, `add_prefix`, `add_suffix` | `rename(mapping)`; a callable mapping is applied to the known names when the verb is called | one PROJECT of every column, the renamed ones aliased; an unknown name or a duplicate output refused; no node when nothing changes |
| `drop_nulls_predicate` | `dropna(subset=None, how="any")`, with NaN missing in float columns (section 8, ruling 6) | `drop_nulls(subset=None)` | a FILTER of `IS NOT NULL` over the subset (every column when none is given); `subset=[]` adds no node |
| `concat_schema_check`, `concat_align_names` | `km.concat(frames)` | `kpl.concat(frames, how="vertical")` | a UNION ALL of inputs of one schema, after the Mojo type check (section 8, ruling 15) |
| `with_alias_impl` | none | none | not carried to Python (below) |

The frame alias is not carried. `with_alias` prefixes every column with `name.` so that a self-join can
tell its sides apart. The Python skins already own their join output names (section 8, ruling 8), and
neither library has a frame alias. `add_prefix` covers the renaming half.

### 10. Where the matrix tests live

The matrix lint requires a surface's tests in `src/tests/e2e/<surface>_e2e` and nowhere else
([surface_capability_matrix.md](../surface_capability_matrix.md)). The Python closure check admits
Python only inside its surface entries.

So `src/tests/e2e/pandas_e2e` and `src/tests/e2e/polars_e2e` hold `python_binding_test` targets, and
those two paths join the Python surface entries in the pull request that adds the first cell. That entry
is a ruling the owner approves, as the Python package design's entry was.

The alternative was to move the Python surfaces' packages under `python/`. That would change the matrix
lint and its tests, and would put two surfaces' tests somewhere other than the other four surfaces'.

### 11. How is it tested?

Every test is in the package's own language or in Mojo, and runs in the pull request's check. There is
no timing assertion and no shell test.

1. **Node structure, per verb** (`python/tests/`, `python_binding_test` targets).
   - Each verb's tree equals a hand-written one.
   - Each refusal raises its class, and its full message is checked by equality.
2. **The attribute rule, per class and module.**
   - For every name in each refusal table, `hasattr` is `False` and the `AttributeError` message equals
     the table's text.
   - A name in no table raises Python's own `AttributeError`.
   - `df.<column>` raises, naming `df["<column>"]`.
   - `__dir__` holds only defined members, and `__setattr__` refuses.
   - A column called `count` is reachable as `df["count"]`, while `df.count()` still counts.
   - A frame survives `copy.copy`, and `hasattr(df, "_repr_html_")` is `False`.
3. **Python bytes equal Mojo plans.**
   - A `python_oracle` build action runs a program in a skin and writes the envelope it encodes.
   - A Mojo test decodes the envelope with `plan_wire`, and compares it field by field with the plan the
     `src/sdk` and `col_expr` builders build, plus the nodes of the ruling that names any difference
     (section 3).
   - This is the [komira_pandas_door_e2e](../../src/tests/e2e/komira_pandas_door_e2e/) comparison,
     with Python writing the bytes instead of protoc. It covers every verb of section 9 and every shape
     that package pins.
4. **The skins agree.**
   - One program per verb that means the same in both skins gives equal bytes.
   - Where the skins differ on purpose, the test holds the difference to exactly the ruling's nodes: the
     group sort, the missing group, NaN as missing, join names, `concat` reordering.
5. **End to end, against the library itself.**
   - For each matrix cell, a test runs one program through the skin, and the same program through the
     real pinned pandas or polars. The answers must be equal.
   - Rows are compared as a multiset unless the frame is ordered, and float aggregates with a tolerance.
   - A departure of sections 7 and 8 is tested to give the departure, and only that.
   - The library is the independent oracle the matrix requires, because the surface promises its
     library's answer, not DuckDB's.

### 12. Rulings that differ from the earlier SDK

The two surfaces are a port of the earlier SDK's pandas-shaped frame and polars-shaped module, over its
plan builder and the plan protobuf, and of its DataFrame surface design. Everything this document does
not list here is carried from that design. These are the points where the port answers differently,
each with the earlier answer and the reason.

The first three follow from decisions made before this design (the plan entry, rule S2, the Python
package design). D4 to D18 are this design's own.

| | point | earlier SDK | here | why |
|---|---|---|---|---|
| D1 | the route | a frame could be rendered to SQL text and re-parsed, chosen by a switch | a frame is only a plan for `komira_plan_stream`; `explain()` renders the plan, not SQL | the SDK builds logical plans; SQL text has its own entry, `komira_sql_stream` |
| D2 | the executed frame | `materialize()` gave a `MaterializedFrame`, `collect()` a polars-shaped `DataFrame` | both give the first release's `Result`, read once (section 2) | one result class for every query, as the Python package design fixes |
| D3 | table names | readers registered each file under an automatic name (`t1`, `t2`) and a public `session()` accessor reached the default session | a reader's scan carries its file and registers no name; readers take `session=` (section 4) | the package design drops automatic names and the accessor |
| D4 | NULL placement in a sort | a sort the engine could not place as the library does was refused, on a column holding NULLs | every sort key carries the library's placement explicitly, and nothing is refused for it (section 8, ruling 5) | the plan honours an explicit placement per key; the refusal answered an engine limit that no longer holds |
| D5 | pandas `groupby(dropna=True)` | the NULL group was returned | it is filtered out below the aggregate (ruling 3) | pandas drops it by default; returning it was a silent difference |
| D6 | per-column group reductions | `groupby().sum()` and `groupby().count()` were refused | supported when the column types allow, and `count()` is pandas' count of non-missing values (rulings 4 and 11) | both are well defined; refusing them hid pandas' answers |
| D7 | missing values | pandas `isna` was refused, and polars `is_null` and `is_nan` were refused | pandas: NaN is missing in float columns; polars: `is_null` and `is_nan` are answered (ruling 6) | users had no way to ask either library's own question |
| D8 | join output names | the plan's names: both keys, `_right` on collisions; `suffix`/`suffixes` refused | each library's own names and suffixes, through a projection (ruling 8) | the plan's names match neither library |
| D9 | an integer subscript `df[0]` | refused as positional | a column label, as in pandas (ruling 1) | in pandas `df[0]` is the column `0` |
| D10 | `//` and `%` | `//` built true division (a known defect), `%` the plan's truncated remainder | Python's floor division and modulo, by a correction over the plan's node (ruling 9) | Python, pandas and polars all floor |
| D11 | the sum of an empty or all-missing group | the plan's NULL | 0 (ruling 10) | both libraries answer 0 |
| D12 | `isin` and `is_in` with a list | refused | an expression, the OR of `=` the Mojo surface builds (ruling 16; the `in_list` row) | the Mojo surface and SQL already build and run it |
| D13 | attributes | `DataFrame.__getattr__` made any unknown name a column; `df.x` was the column `x` | no attribute is a column; `__getattr__` only raises `AttributeError` (section 5) | `hasattr` raised, a column hid behind a verb of its name, and a verb added later would change what an attribute meant |
| D14 | engine limits | some were checked in Python (NULL placement, `head(0)`) | refused by the engine at the terminal, with its step and code (section 6) | the Python checks went stale when the engine moved |
| D15 | `len(df)` and `bool(df)` | ran the query | raise `UnsupportedOperation` naming the terminal (section 2) | no dunder runs a query |
| D16 | ties chosen by row order | `drop_duplicates(subset=...)` was refused | the library's default is accepted and returns any tied row; an explicit order-dependent choice is refused (section 7) | the default asks a question the plan can answer, with a listed departure |
| D17 | verbs the earlier SDK lacked | absent: `with_columns`/`assign` over the Mojo builder's rules, `rename`, `dropna`/`drop_nulls`, `concat`, `fillna`, `astype`/`cast`, `value_counts`, `nlargest`/`top_k`, `tail`, `merge_asof`/`join_asof`, `from_arrow`, binding a frame by name (`add_sql_binding`) | carried from the Mojo builders where one exists (section 9), with rulings 14 and 15 | the Python skins lacked the verbs the Mojo surface has |
| D18 | where the matrix tests live | no matrix | `src/tests/e2e/pandas_e2e` and `polars_e2e` (section 10) | the matrix lint's package rule |

## What must always hold?

- No verb runs a query. Only the terminals of section 2 do.
- No attribute lookup on a skin's class or module returns a column, or a value it did not define.
- A defined verb gives its library's answer, a departure that sections 7 and 8 list, or
  `UnsupportedOperation`.
- A verb with a Mojo builder encodes that builder's plan, plus only the nodes of the ruling that names
  the difference.
- Nothing on the DataFrame path writes SQL text, reads an environment variable, or imports pandas or
  polars to compute. (The library's credential chains read the providers' own variables when a remote
  URL is read: [credentials_and_writes.md](credentials_and_writes.md#7-the-ambient-credential-and-the-only-environment-komira-reads).)
- Every capability a skin reaches has a matrix row, and every verb names its capability in
  [dataframe_surface_verbs.md](dataframe_surface_verbs.md).

## What is decided elsewhere

| question | where |
|---|---|
| the package layout, module names, `Session`, `Result`, the error classes and their fields | [the Python package design](python_package.md) |
| the plan entry's C ABI, the schema calls and the Arrow C stream export | the ABI design for running a query (`src/so`) |
| which plans the engine runs today | [src/lowering/README.md](../../src/lowering/README.md), [src/sdk_exec/README.md](../../src/sdk_exec/README.md) |
| the UDF verbs' `return_dtype`, null mode, code capture and workers | [optimized_plan_udfs.md](optimized_plan_udfs.md), [udf_runtime_interface.md](udf_runtime_interface.md) |
| what each plan node returns | [query semantics](query_semantics.md) |
| sources, credentials and binding them, remote prefixes, and a write terminal's `compression=` and what it returns | [credentials_and_writes.md](credentials_and_writes.md) |
| catalogs and `read_table` | the catalog designs |

## What are the limits and open questions?

- The pandas skin answers pandas' NumPy-dtype question, in which NaN is missing. Under `pd.ArrowDtype`,
  pandas keeps NULL and NaN apart. A skin option for that is a later, additive decision.
- polars' NaN handling in `min`, `max` and `sort`, and the rounding mode of `round`, are to be measured
  against polars 1.44.2 by the polars core task. Where they differ from the plan, that task builds
  polars' answer or refuses. It never ships the difference silently.
- **`between` has no grounding any surface reaches.** The matrix grounds it in `EXPR_BETWEEN`. No
  builder makes that kind: `between_of` (`src/plan_expr/scalar_desugar.mojo`) builds two comparisons,
  and so does SQL's `BETWEEN`. So the cell stays empty for every surface until the ledger grounds the
  capability in what the builders make
  ([dataframe_surface_verbs.md](dataframe_surface_verbs.md#grounding-that-no-surface-reaches)).
- `subquery` has no spelling in either library, and `json_extract` has none in pandas. So the
  polars-shaped skin leaves 2 of its 52 cells empty by decision, and the pandas-shaped skin leaves 3
  (counted from the verbs document's table).
- The early engine refuses at `lower` most of what the skins can build:
  a distinct over an explicit column list, and sources other than Parquet or one JSON Lines file; a whole-row distinct runs only
  over one fixed-width or string column, or several dictionary-encoded string columns. These plans raise at the terminal with the engine's code
  until the engine runs them.

## Where is the code?

The code goes in `python/komira/`, which is not built yet: the node tree, the encoder, the pandas-shaped
skin, and `komira/pl/`. The Mojo builders it mirrors are in [src/sdk](../../src/sdk/README.md) and
`src/plan_expr/col_expr.mojo`. The wire format is in [src/plan_proto](../../src/plan_proto/plan.proto)
and `src/plan_wire`.
