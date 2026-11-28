# The Python DataFrame surface: verbs, capabilities and refusals

Status: design, partly built; the pages under [python/docs/](../../python/docs/dataframe/overview.md) say what is built, one page per feature. This document gives each verb's designed spelling, and marks **not built** each one the skin does not define yet. This is the verb half of [the DataFrame surface](dataframe_surface.md):
that document gives the rules. This one has three parts:

- for each capability of the [surface capability matrix](../surface_capability_matrix.md), the verbs of
  each skin that reach it and the plan they build;
- the dtype names a dtype argument accepts;
- the refusal tables that section 5 of the rules document points to.

`km` is `import komira`, the pandas-shaped skin, and `kpl` is `komira.pl`, the polars-shaped skin. `df`
is a `km.DataFrame`, `s` a `km.Series`, `lf` a `kpl.LazyFrame` and `expr` a `kpl.Expr`.

## The capability map

This part has one section per capability of `CAPABILITIES` in
[tests/surface_capability_matrix.bzl](../../tests/surface_capability_matrix.bzl), the sections in name
order, for the matrix's `pandas` and `polars` columns. Each section gives the plan the verbs build, what
the engine does with it today, and each skin's spellings, one per line in byte order (the order
`LC_ALL=C sort` gives).

"Engine today" says what the engine does with the plan, from
[src/lowering/README.md](../../src/lowering/README.md) and [src/sdk_exec/README.md](../../src/sdk_exec/README.md):

- **cut**: lowering cuts the node.
- **refused at lower**: the terminal raises `LOWERING_UNCUTTABLE_NODE`, or `LOWERING_SCAN_NOT_TOTAL`
  for a remote scan.
- **in its node**: an expression, evaluated inside the node that holds it. This design makes no claim
  about which expression kinds lower.
- **not wired**: no door reaches it yet.
- **run by `run_plan_write`**: the plan door writes the plan's rows to a local file and answers `Count`.
- **contract**: a promise, not a node.

A cell of the matrix ledger is filled only by an end-to-end test of that surface (rules document,
section 11). A skin whose section says "none" has no spelling, and the cell stays empty by decision. A
spelling marked **not built** is designed, but the skin does not define it yet: calling it raises
Python's own `AttributeError`, or the refusal its line names.

The pandas-shaped skin leaves these cells empty by decision:

- `between`
- `json_extract`
- `subquery`

The polars-shaped skin leaves these empty:

- `between`
- `subquery`

Each is a section below that says "none" or "the cell stays empty".

### Grounding that no surface reaches

The matrix grounds `between` in `EXPR_BETWEEN`. No builder in this tree makes that kind.
`between_of` (`src/plan_expr/scalar_desugar.mojo`) builds two comparisons, and its comment says
`EXPR_BETWEEN` "carries no payload and no evaluator walks it". The SQL parser builds the same two
comparisons for `BETWEEN`. So the `between` cell is empty for every surface, SQL included.

The skins build the same comparisons, so their bytes match the Mojo surface's. A change to the matrix
ledger that grounds `between` in what the builders make would let all six surfaces fill the cell. That
change is the ledger's, not this design's.

`in_list` is different. `EXPR_IN_LIST` is made by `Expr.in_list_node`, and the optimizer folds an OR of
`=` on one column into it. So a skin's `isin` or `is_in` reaches it through the optimizer, as SQL's
`IN (...)` does.

### `aggregate`

Plan: AGGREGATE with no keys.

Engine today: cut.

pandas-shaped (`km`):

- `df.agg(total=("v", "sum"))`
- `df.sum()` and the other frame reductions
- a one-row frame (rules section 8, ruling 1)

polars-shaped (`kpl`):

- `lf.select(kpl.col("v").sum())`
- `lf.select(kpl.len())`

### `between`

Plan: the two comparisons `between_of` and the SQL parser build, not `EXPR_BETWEEN`.

Engine today: in its node; the cell stays empty (see [Grounding](#grounding-that-no-surface-reaches)).

pandas-shaped (`km`):

- `s.between(lo, hi, inclusive="both")` (not built)

polars-shaped (`kpl`):

- `expr.is_between(lo, hi, closed="both")`

### `case_when`

Plan: `EXPR_WHEN`.

Engine today: in its node.

pandas-shaped (`km`):

- `s.case_when(caselist)` (not built)
- `s.mask(cond, other)`, `other` required (not built)
- `s.where(cond, other)`, `other` required (not built)

polars-shaped (`kpl`):

- `kpl.when(c).then(v).otherwise(w)`; `otherwise` required

### `cast`

Plan: `EXPR_CAST`.

Engine today: in its node.

pandas-shaped (`km`):

- `df.astype(dtype or {col: dtype})`
- `s.astype(dtype)`

polars-shaped (`kpl`):

- `expr.cast(dtype)`

### `computed_column`

Plan: PROJECT of literals, binary and unary ops (`build_with_columns_plan`).

Engine today: cut.

pandas-shaped (`km`):

- `&`
- `abs()` (not built)
- `df.assign(x=...)`
- `df.fillna`
- `df.isna()`
- `df.notna()`
- `df["x"] = ...`
- `isnull`, the alias of `isna`
- `notnull`, the alias of `notna`
- `round()` (not built)
- `s.isna()`
- `s.notna()`
- `|`
- `~`
- comparisons
- operator `%` (not built)
- operator `**` (not built)
- operator `*`
- operator `+`
- operator `-`
- operator `//` (not built)
- operator `/`
- unary `-`

polars-shaped (`kpl`):

- `&`
- `abs`
- `fill_nan` (not built)
- `fill_null`
- `is_nan` (not built)
- `is_not_null`
- `is_null`
- `kpl.lit`
- `lf.select(expr)`
- `lf.with_columns(expr)`
- `round` (not built)
- `|`
- `~`
- comparisons
- operator `%`
- operator `**` (not built)
- operator `*`
- operator `+`
- operator `-`
- operator `//`
- operator `/`
- unary `-`

### `distinct`

Plan: DISTINCT of whole rows; both skins build a `subset` of fewer columns, and pandas `keep=False` and polars `keep="none"` over one, as a PARTITION_BY (`ROW_NUMBER` or `COUNT` per value) under a FILTER, and pandas `duplicated` as that window `> 1` (dataframe_surface.md, rules section 7).

Engine today: whole rows served by lowering for the key coverage of the grouped sinks; a `subset` of fewer columns, and `duplicated`, are cut as a window (`LOWERING_WINDOW_UNSERVED` for a type the window sink does not serve).

pandas-shaped (`km`):

- `df.drop_duplicates()`
- `df.drop_duplicates(subset=..., keep="first"|"last"|False)`
- `df.duplicated(subset, keep)`, a bool `Series`
- `s.unique()`, refused by name (it gives an array of the rows)

polars-shaped (`kpl`):

- `lf.unique()`
- `lf.unique(subset=..., keep="any"|"none")`

### `errors`

Plan: contract.

Engine today: contract.

pandas-shaped (`km`):

- rules section 6

polars-shaped (`kpl`):

- rules section 6

### `filter`

Plan: FILTER.

Engine today: cut.

pandas-shaped (`km`):

- `df[pred]`, where `pred` is a boolean `Series` of `df`

polars-shaped (`kpl`):

- `lf.filter(pred)`

### `group_by`

Plan: AGGREGATE; pandas adds a SORT above it (`sort=True`) and a FILTER of missing keys below it (`dropna=True`).

Engine today: cut, for the group key types the sinks serve; a grouped sum or mean of a float column is refused when the plan runs, naming its step (the grouped sinks fold no float argument).

pandas-shaped (`km`):

- `.count()`
- `.max()`
- `.mean()`
- `.min()`
- `.size()`
- `.sum()`
- `df.groupby(keys).agg(...)`
- the others (rules section 8, ruling 4)

polars-shaped (`kpl`):

- `.len()`
- `.sum()` and the others
- `lf.group_by(keys).agg(...)`

### `in_list`

Plan: the OR of `=` that `col_expr.is_in` and the SQL parser build, which the optimizer folds into `EXPR_IN_LIST` (`Expr.in_list_node`); more than 64 values refused, as the Mojo builder refuses them.

Engine today: in its node.

pandas-shaped (`km`):

- `s.isin([...])`

polars-shaped (`kpl`):

- `expr.is_in([...])`

### `join_anti`

Plan: JOIN, `JOIN_ANTI`; left columns only.

Engine today: cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`).

pandas-shaped (`km`):

- `df[~df["k"].isin(o["k"])]`

polars-shaped (`kpl`):

- `how="anti"`

### `join_asof`

Plan: ASOF_JOIN.

Engine today: refused at lower.

pandas-shaped (`km`):

- `km.merge_asof(l, r, on=..., by=..., direction=...)`; `allow_exact_matches=False` refused (not built)

polars-shaped (`kpl`):

- `lf.join_asof(o, on=..., by=..., strategy="backward"|"forward"|"nearest")` (not built)

### `join_cross`

Plan: JOIN, `JOIN_CROSS`.

Engine today: cut; a cross join that names a key is refused (`LOWERING_JOIN_UNSERVED`).

pandas-shaped (`km`):

- `how="cross"`

polars-shaped (`kpl`):

- `how="cross"`

### `join_full`

Plan: JOIN, `JOIN_FULL`; pandas coalesces the `on=` keys.

Engine today: cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`).

pandas-shaped (`km`):

- `how="outer"`

polars-shaped (`kpl`):

- `how="full"`

### `join_inner`

Plan: JOIN, `JOIN_INNER`, under the skin's naming PROJECT (rules section 8, ruling 8).

Engine today: cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`).

pandas-shaped (`km`):

- `df.merge(o, left_on=..., right_on=..., how="inner")`
- `df.merge(o, on=..., how="inner")`

polars-shaped (`kpl`):

- `lf.join(o, on=..., how="inner")`

### `join_left`

Plan: JOIN, `JOIN_LEFT`.

Engine today: cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`).

pandas-shaped (`km`):

- `how="left"`

polars-shaped (`kpl`):

- `how="left"`

### `join_right`

Plan: JOIN, `JOIN_RIGHT`.

Engine today: cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`).

pandas-shaped (`km`):

- `how="right"`

polars-shaped (`kpl`):

- `how="right"`

### `join_semi`

Plan: JOIN, `JOIN_SEMI`; left columns only.

Engine today: cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`).

pandas-shaped (`km`):

- `df[df["k"].isin(o["k"])]` (rules section 8, ruling 16)

polars-shaped (`kpl`):

- `how="semi"`

### `json_extract`

Plan: `EXPR_JSON_EXTRACT`.

Engine today: in its node.

pandas-shaped (`km`): none; the cell stays empty by decision.

polars-shaped (`kpl`):

- `expr.str.json_path_match(path)` (not built)

### `limit`

Plan: LIMIT, offset 0 unless `slice`.

Engine today: cut; a limit or an offset above a sort is cut as that range of the sort (SINK_TOPN), an offset over no sort is refused.

pandas-shaped (`km`):

- `df.head(n)`

polars-shaped (`kpl`):

- `lf.head(n)`
- `lf.limit(n)`
- `lf.slice(offset, n)` on an ordered frame

### `math_functions`

Plan: `EXPR_MATH_FN`, `EXPR_MATH_FN2`.

Engine today: in its node.

pandas-shaped (`km`):

- NumPy ufuncs on a `Series` (`np.sqrt(s)`, `np.log(s)`) (not built)
- `**` (not built)

polars-shaped (`kpl`):

- `expr.arccos` (not built)
- `expr.arcsin` (not built)
- `expr.arctan` (not built)
- `expr.ceil` (not built)
- `expr.cos` (not built)
- `expr.exp` (not built)
- `expr.floor` (not built)
- `expr.log(base)` (not built)
- `expr.log10` (not built)
- `expr.log1p` (not built)
- `expr.pow` (not built)
- `expr.sin` (not built)
- `expr.sqrt` (not built)
- `expr.tan` (not built)
- the NumPy ufuncs of the same names (not built)

### `nested_access`

Plan: `EXPR_STRUCT_FIELD`.

Engine today: in its node.

pandas-shaped (`km`):

- `s.struct.field(name)` (not built)

polars-shaped (`kpl`):

- `expr.struct.field(name)` (not built)

### `null_semantics`

Plan: contract.

Engine today: contract.

pandas-shaped (`km`):

- aggregates that skip NaN (not built)
- rules section 8, rulings 2, 3, 5, 7, 10, 11
- ruling 6 (NaN missing in float columns) for `dropna`
- ruling 6 for `fillna`
- ruling 6 for `isna`
- ruling 6 for `notna`

polars-shaped (`kpl`):

- `fill_nan` (not built)
- `is_nan` (not built)
- ruling 6 for `drop_nulls`
- ruling 6 for `fill_null`
- ruling 6 for `is_not_null`
- ruling 6 for `is_null`
- the same rulings

### `output_dtypes`

Plan: contract.

Engine today: contract.

pandas-shaped (`km`):

- `df.materialize().to_arrow()`
- `df.materialize().to_pandas()`

polars-shaped (`kpl`):

- `lf.collect().to_arrow()`
- `lf.collect().to_polars()`

### `output_nan_null`

Plan: contract.

Engine today: contract.

pandas-shaped (`km`):

- `to_arrow` keeps NULL and NaN apart
- `to_pandas` with NumPy dtypes shows a NULL float as NaN, which is pandas' own form

polars-shaped (`kpl`):

- a NULL and a NaN stay distinct in `to_arrow`
- a NULL and a NaN stay distinct in `to_polars`

### `project`

Plan: PROJECT of column references and aliases.

Engine today: cut.

pandas-shaped (`km`):

- `df.add_prefix`
- `df.add_suffix`
- `df.rename(columns=...)`
- `df[["a", "b"]]`

polars-shaped (`kpl`):

- `lf.rename(...)`
- `lf.select("a", "b")`
- `lf.select(kpl.col("a").alias("b"))`

### `regexp`

Plan: `EXPR_REGEXP`.

Engine today: in its node.

pandas-shaped (`km`):

- `s.str.contains(p, regex=True)`
- `s.str.extract(p, expand=False)` (one group)
- `s.str.fullmatch`
- `s.str.match`
- `s.str.replace(p, v, regex=True)` (every match)

polars-shaped (`kpl`):

- `expr.str.contains(p)` (not built): raises `UnsupportedOperation` unless `literal=True`
- `expr.str.extract(p, group_index)` (not built)
- `expr.str.replace(p, v)` (first match) (not built)
- `expr.str.replace_all(p, v)` (not built)

### `scan_arrow_ipc`

Plan: SCAN, `SOURCE_ARROW`.

Engine today: refused at lower.

pandas-shaped (`km`):

- `km.read_feather(path)` (not built)

polars-shaped (`kpl`):

- `kpl.scan_ipc(path)` (not built)

### `scan_avro`

Plan: SCAN, `SOURCE_AVRO`.

Engine today: refused at lower.

pandas-shaped (`km`):

- `km.read_avro(path)` (komira's verb; pandas has none) (not built)

polars-shaped (`kpl`):

- `kpl.scan_avro(path)` (komira's verb; polars reads Avro only eagerly) (not built)

### `scan_az`

Plan: SCAN with the `azure` scheme.

Engine today: as `scan_s3`: SQL over a bound name reads through the session's `StoreScanFs`, and a Mojo caller can hand over an `AzureScanFs`; the plan entry refuses the scan.

pandas-shaped (`km`):

- a reader given an `az://` path (not built): the readers take a local path

polars-shaped (`kpl`):

- a reader given an `az://` path (not built): the readers take a local path

### `scan_csv`

Plan: SCAN of the `komira.csv` binding, `source_kind` the binding's columnar or row layout (the hand-built `read_csv` shape of `komira_pandas_door_e2e` leaves it UNSET).

Engine today: cut (`SOURCE_CSV`, one local file); a file with no header row (`header=None`, `has_header=False`) is refused at lower (`LOWERING_UNCUTTABLE_NODE`).

pandas-shaped (`km`):

- `km.read_csv(path, sep=",", header="infer")`

polars-shaped (`kpl`):

- `kpl.scan_csv(path, separator=",", has_header=True)`

### `scan_gs`

Plan: SCAN with the `gcs` scheme.

Engine today: cut, and read through `GcsScanFs` only when a Mojo caller hands `run_sql_with` or `run_plan_with` the opener; not wired from libkomira: its plan entry refuses the scan as for `scan_s3`, and `komira_add_sql_binding` refuses a `gs://` location (`STORAGE_URL_REFUSED`).

pandas-shaped (`km`):

- a reader given a `gs://` path (not built): the readers take a local path

polars-shaped (`kpl`):

- a reader given a `gs://` path (not built): the readers take a local path

### `scan_in_memory`

Plan: SCAN of a table the session registered from the Arrow C stream (rules section 4).

Engine today: not wired from a skin: the plan wire has no in-memory source, and its encoder refuses one (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`). A table registered with libkomira's `komira_register_arrow_stream` is read by SQL, cut as `SOURCE_BATCH`.

pandas-shaped (`km`):

- `km.from_arrow(data)` (not built)

polars-shaped (`kpl`):

- `kpl.from_arrow(data)` (not built)

### `scan_jsonl`

Plan: SCAN, `SOURCE_NDJSON`.

Engine today: cut (`SOURCE_JSONL`, one local file).

pandas-shaped (`km`):

- `km.read_json(path, lines=True)`; `lines=False` refused

polars-shaped (`kpl`):

- `kpl.scan_ndjson(path)`

### `scan_orc`

Plan: SCAN, `SOURCE_ORC`.

Engine today: refused at lower.

pandas-shaped (`km`):

- `km.read_orc(path)` (not built)

polars-shaped (`kpl`):

- `kpl.scan_orc(path)` (komira's verb; polars has none) (not built)

### `scan_parquet`

Plan: SCAN, `SOURCE_PARQUET`, local files (one file, a glob or a directory; Hive columns detected).

Engine today: cut, for one file or several listed files, Hive columns included; a Hive scan that lists its files lazily (a directory or a partition predicate) is refused at lower (`LOWERING_SCAN_NOT_TOTAL`).

pandas-shaped (`km`):

- `km.read_parquet([paths])`, a list (not built)
- `km.read_parquet(directory)`, a directory (not built)
- `km.read_parquet(glob)`, a glob (not built)
- `km.read_parquet(path)`, one local file

polars-shaped (`kpl`):

- `kpl.scan_parquet([paths])`, a list (not built)
- `kpl.scan_parquet(directory)`, a directory (not built)
- `kpl.scan_parquet(glob)`, a glob (not built)
- `kpl.scan_parquet(path)`, one local file

### `scan_s3`

Plan: SCAN with the `s3` scheme.

Engine today: cut. The skins' plan entry (`komira_plan_stream`) reads through `LocalOnlyScanFs`, which refuses the scan at step `execute` (`SCAN_FS_UNSERVED`). SQL reads Parquet objects of a name bound with `Session.add_sql_binding` and `komira.files` (`komira_add_sql_binding`) through the session's `StoreScanFs`, and a Mojo caller of `run_sql_with` or `run_plan_with` can hand over an `S3ScanFs`.

pandas-shaped (`km`):

- a reader given an `s3://` path (not built): the readers take a local path

polars-shaped (`kpl`):

- a reader given an `s3://` path (not built): the readers take a local path

### `sort`

Plan: SORT, every key with an explicit `nulls_first` (rules section 8, ruling 5).

Engine today: cut.

pandas-shaped (`km`):

- `df.sort_values(by, ascending=True, na_position="last")`

polars-shaped (`kpl`):

- `lf.sort(by, descending=False, nulls_last=False)`

### `string_functions`

Plan: `EXPR_STRING_OP`, `EXPR_STRING_FN`, `EXPR_STRING_FN_N`, `EXPR_SUBSTRING`.

Engine today: in its node.

pandas-shaped (`km`):

- `+` of strings, which builds an arithmetic `add`, not a concatenation
- `s.str.contains(p, regex=False)`
- `s.str.endswith`
- `s.str.len`
- `s.str.lower`
- `s.str.pad`
- `s.str.replace(p, v, regex=False)`
- `s.str.slice`
- `s.str.startswith`
- `s.str.strip` (not built), refused by name
- `s.str.upper`

polars-shaped (`kpl`):

- `expr.str.contains(p, literal=True)`
- `expr.str.ends_with`
- `expr.str.len_bytes` (not built)
- `expr.str.len_chars`
- `expr.str.pad_end` (not built)
- `expr.str.pad_start` (not built)
- `expr.str.replace(p, v, literal=True)` (not built)
- `expr.str.slice` (not built)
- `expr.str.starts_with`
- `expr.str.strip_chars` (not built)
- `expr.str.to_lowercase`
- `expr.str.to_uppercase`
- `kpl.concat_str(exprs, separator=...)` (not built)

### `subquery`

Plan: neither library has a subquery inside an expression; a broadcast aggregate is a window.

Engine today: none: no surface reaches it.

pandas-shaped (`km`): none; the cell stays empty by decision.

polars-shaped (`kpl`): none; the cell stays empty by decision.

### `temporal_extract`

Plan: `EXPR_EXTRACT` with the matching unit; pandas `dayofweek` is ISO minus one (Monday 0), polars `weekday` is ISO (Monday 1).

Engine today: in its node.

pandas-shaped (`km`):

- `s.dt.day`
- `s.dt.dayofweek`
- `s.dt.dayofyear`
- `s.dt.floor(freq)` for one fixed unit
- `s.dt.hour`
- `s.dt.microsecond`
- `s.dt.minute`
- `s.dt.month`
- `s.dt.quarter`
- `s.dt.second`
- `s.dt.year`

polars-shaped (`kpl`):

- `expr.dt.day` (not built) (the skin has no `expr.dt`)
- `expr.dt.hour` (not built) (the skin has no `expr.dt`)
- `expr.dt.microsecond` (not built) (the skin has no `expr.dt`)
- `expr.dt.millisecond` (not built) (the skin has no `expr.dt`)
- `expr.dt.minute` (not built) (the skin has no `expr.dt`)
- `expr.dt.month` (not built) (the skin has no `expr.dt`)
- `expr.dt.ordinal_day` (not built) (the skin has no `expr.dt`)
- `expr.dt.quarter` (not built) (the skin has no `expr.dt`)
- `expr.dt.second` (not built) (the skin has no `expr.dt`)
- `expr.dt.truncate(every)` for one fixed unit (not built) (the skin has no `expr.dt`)
- `expr.dt.week` (not built) (the skin has no `expr.dt`)
- `expr.dt.weekday` (not built) (the skin has no `expr.dt`)
- `expr.dt.year` (not built) (the skin has no `expr.dt`)

### `topn`

Plan: TOPN; ties at the boundary as in rules section 7.

Engine today: cut (SINK_TOPN).

pandas-shaped (`km`):

- `df.nlargest(n, columns)` (not built)
- `df.nsmallest(n, columns)` (not built)
- `df.sort_values(...).head(n)`, which reaches the same `SINK_TOPN` as a LIMIT over a SORT

polars-shaped (`kpl`):

- `lf.bottom_k(k, by=...)`
- `lf.top_k(k, by=...)`

### `topn_per_group`

Plan: PARTITION_TOPN.

Engine today: refused at lower.

pandas-shaped (`km`):

- `df.sort_values(o).groupby(k).head(n)` (not built)

polars-shaped (`kpl`):

- `lf.sort(o).group_by(k).head(n)` (not built)

### `udf_agg`

Plan: `AGG_UDF` over an AGGREGATE `UdfRef`.

Engine today: not wired, as `udf_map`; lowering refuses `AGG_UDF` (`LOWERING_UNCUTTABLE_NODE`) and a call in a group key or an aggregate's argument (`LOWERING_UDF_UNSERVED`).

pandas-shaped (`km`):

- `df.groupby(k).agg(out=("c", f))` (not built)

polars-shaped (`kpl`):

- `lf.group_by(k).agg(expr.agg_udf(f, return_dtype=...))` (komira's verb) (not built)

### `udf_filter`

Plan: a boolean `WireUdfApply` in a FILTER.

Engine today: not wired, as `udf_map`; lowering refuses a call in a predicate (`LOWERING_UDF_UNSERVED`) and a filter of the UDF kind (`LOWERING_UNCUTTABLE_NODE`).

pandas-shaped (`km`):

- `df[df["x"].map(f)]` (not built)

polars-shaped (`kpl`):

- `lf.filter(expr.map_elements(f, return_dtype="bool"))` (not built)

### `udf_map`

Plan: a `UdfRef` called by `WireUdfApply`.

Engine today: not wired: libkomira's plan entry refuses an envelope that carries `UdfRef` entries at step `decode` (`PLAN_WIRE_UDFS_DROPPED`). Lowering, for a Mojo caller of `plan_envelope_from_bytes`, cuts a call that is a whole projection column (`OP_UDF_APPLY`) and refuses one inside a larger expression (`LOWERING_UDF_UNSERVED`).

pandas-shaped (`km`):

- `df.apply(f, axis=1)` (not built)
- `s.apply(f)` (not built)
- `s.map(f)` (not built)

polars-shaped (`kpl`):

- `expr.map_batches(f, return_dtype=...)` (not built)
- `expr.map_elements(f, return_dtype=...)` (not built)

### `union`

Plan: UNION of one schema (`concat_schema_check`; rules section 8, ruling 15).

Engine today: cut.

pandas-shaped (`km`):

- `km.concat(frames)`

polars-shaped (`kpl`):

- `kpl.concat(frames, how="vertical")`

### `view`

Plan: VIEW_REF.

Engine today: not wired.

pandas-shaped (`km`):

- `km.add_sql_binding(name, df)`, then `km.sql(...)` (not built)
- `km.sql(..., name=df)` (not built)

polars-shaped (`kpl`):

- `km.add_sql_binding(name, lf)`, then `km.sql(...)` (not built)
- `km.sql(..., name=lf)` (not built)

### `window`

Plan: PARTITION_BY (`select_broadcasting_aggregates` for a broadcast); rules section 7 for the order.

Engine today: cut; a key or argument type the window sink does not serve is refused (`LOWERING_WINDOW_UNSERVED`).

pandas-shaped (`km`):

- `.cumsum()` on an ordered frame
- `.rank(method="min"|"dense")`
- `.rolling(n, min_periods=1).mean()` on an ordered frame
- `df.groupby(k)[c].transform("sum")`
- a `Series` aggregate used inside `assign`

polars-shaped (`kpl`):

- `cum_count` with an order (`order_by=` or an ordered frame)
- `cum_max` with an order (`order_by=` or an ordered frame)
- `cum_min` with an order (`order_by=` or an ordered frame)
- `cum_sum` with an order (`order_by=` or an ordered frame)
- `expr.over(keys)`
- `rank(method="min"|"max"|"dense"|"average")`
- `rolling_max` with an order (`order_by=` or an ordered frame)
- `rolling_mean` with an order (`order_by=` or an ordered frame)
- `rolling_min` with an order (`order_by=` or an ordered frame)
- `rolling_sum` with an order (`order_by=` or an ordered frame)
- an aggregate beside a row-wise value in `select`, `with_columns` or `filter` (a broadcast)

### `write_csv`

Plan: the envelope's `write_target`, CSV.

Engine today: run by `run_plan_write`: libkomira's plan entry writes a local CSV file, the bytes SQL's `COPY ... TO` writes, and answers `Count`.

pandas-shaped (`km`):

- `df.to_csv(path)`; `index=` has no effect, `sep=","` and `header=True` taken, other values refused

polars-shaped (`kpl`):

- `lf.sink_csv(path)`; options other than the writer's one value refused

### `write_jsonl`

Plan: the envelope's `write_target`, JSON Lines.

Engine today: run by `run_plan_write`: libkomira's plan entry writes a local JSON Lines file, the bytes SQL's `COPY ... TO` writes, and answers `Count`.

pandas-shaped (`km`):

- `df.to_json(path, orient="records", lines=True)`; other forms refused

polars-shaped (`kpl`):

- `lf.sink_ndjson(path)`

### `write_parquet`

Plan: the envelope's `write_target`, Parquet.

Engine today: run by `run_plan_write`: libkomira's plan entry writes a local Parquet file, the bytes SQL's `COPY ... TO` writes, and answers `Count`.

pandas-shaped (`km`):

- `df.to_parquet(path)`

polars-shaped (`kpl`):

- `lf.sink_parquet(path)`; `compression` zstd by default

## Verbs that reach a capability through another row

These verbs have no capability of their own. Each one builds the plan of the capability named:

| verb | pandas-shaped | polars-shaped | capability |
|---|---|---|---|
| frame rename | `rename(columns=)`, `add_prefix`, `add_suffix` | `rename(mapping)` | `project` |
| drop rows with a missing value | `dropna(subset=None, how="any")` | `drop_nulls(subset=None)` | `filter` (`drop_nulls_predicate`) |
| find missing values | `df.isna()`, `df.notna()`, `s.isna()`, `s.notna()` (NaN missing in a float column) | `is_null()`, `is_not_null()`; `is_nan()` not built | `computed_column` |
| fill missing values | `fillna(v)` or `fillna({col: v})` | `fill_null(v)`; `fill_nan(v)` not built | `computed_column` |
| count values per key | `df.groupby(c).size().sort_values("size", ascending=False)`: `s.value_counts()` is refused by name, since pandas gives a `Series` indexed by value and a komira `Series` has no index (rules section 8, ruling 1) | `lf.group_by(c).len()` | `group_by`, `sort` |
| distinct count | `nunique()` | `n_unique()` | `aggregate`, `group_by` |
| median, standard deviation, variance | `median()`, `std()`, `var()` (`ddof=1`); other `ddof` refused | `median()`, `std()`, `var()` (`ddof=1`) | `aggregate`, `group_by` |
| last rows of an ordered frame | `tail(n)` | `tail(n)` | `topn` (rules section 7) |
| copy | `df.copy()` returns an equal frame | none: frames are values | none |
| render the plan | `explain()` | `explain()` | none |
| frame columns and types | `columns`, `dtypes` | `columns`, `schema` | none |

## dtypes

A dtype argument is either a `pyarrow.DataType`, or one of these names, each meaning the pyarrow type of
the same name:

- `bool`
- `int8`, `int16`, `int32`, `int64`
- `uint8`, `uint16`, `uint32`, `uint64`
- `float32`, `float64`
- `string`, `binary`
- `date32`

The pandas-shaped skin also takes pandas' spellings of those: `"Int64"` and the other capitalised
integer and float names (`"UInt8"`, `"Float64"`, ...), `"boolean"`, and `"str"`, and Python's types `bool`, `int` (int64), `float` (float64) and
`str` (string). `"object"` and `"category"` are refused by name, because neither
names one Arrow type.

## The refusal tables

Each entry is a name that a skin does not define, together with the text of the `AttributeError` it
raises (rules section 5). In a message, `<name>` stands for the name that was looked up. A name in no
table raises Python's own `AttributeError`. A test checks every entry by its full text. Each table
has one row per name, the rows in name order ignoring case.

A verb that does exist but refuses some arguments, or an unordered frame, is not listed here. It raises
`UnsupportedOperation` at the call.

### Module `komira`

| name | message |
|---|---|
| `crosstab` | `komira.<name>() is not supported yet: the plan has no node for it` |
| `get_dummies` | `komira.<name>() is not supported yet: the plan has no node for it` |
| `Index` | `komira frames have no index` |
| `melt` | `komira.<name>() is not supported yet: the plan has no node for it` |
| `merge_ordered` | `merge_ordered() fills by row order, which a frame does not have; use merge() then sort_values()` |
| `MultiIndex` | `komira frames have no index` |
| `NamedAgg` | `use a tuple: agg(out=("column", "func"))` |
| `pivot_table` | `komira.<name>() is not supported yet: the plan has no node for it` |
| `RangeIndex` | `komira frames have no index` |
| `to_datetime` | `komira.<name>() is not supported; cast a column with s.astype(...)` |
| `to_numeric` | `komira.<name>() is not supported; cast a column with s.astype(...)` |

### Module `komira.pl`

| name | message |
|---|---|
| `count` | `komira.pl.count() is refused: it named both questions in polars; say komira.pl.len() for rows or komira.pl.col(name).count() for non-null values` |
| `DataFrame` | `komira.pl has no eager frame: a LazyFrame runs at .collect(), which returns a Result` |
| `read_avro` | `komira.pl frames are lazy: use komira.pl.scan_<format>(...) and run it with .collect()` |
| `read_csv` | `komira.pl frames are lazy: use komira.pl.scan_<format>(...) and run it with .collect()` |
| `read_ipc` | `komira.pl frames are lazy: use komira.pl.scan_<format>(...) and run it with .collect()` |
| `read_ndjson` | `komira.pl frames are lazy: use komira.pl.scan_<format>(...) and run it with .collect()` |
| `read_parquet` | `komira.pl frames are lazy: use komira.pl.scan_<format>(...) and run it with .collect()` |

In the `read_*` message, `<format>` is the format of the name looked up (`parquet`, `csv`, `ndjson`,
`ipc`, `avro`).

### `DataFrame` and `Series`

| name | on | message |
|---|---|---|
| `at` | both | `.<name> selects by index label or position, and komira frames have no index: filter with df[pred], or sort_values(...).head(n)` |
| `bfill` | both | `.<name>() is not supported yet` |
| `cat` | `Series` | `the .<name> accessor is not supported: komira has no categorical or sparse dtype` |
| `collect` | `DataFrame` | `.collect() is the polars-shaped skin's word; this frame runs at .materialize()` |
| `compute` | `DataFrame` | `.compute() is dask's word; this frame runs at .materialize()` |
| `describe` | `DataFrame` | `.<name>() reports on a pandas object; run with materialize(), then call to_pandas().<name>()` |
| `diff` | both | `.<name>() is not supported yet` |
| `empty` | `DataFrame` | `.<name> needs a query to run: count rows with df.agg(n=(column, "size")).materialize()` |
| `eval` | `DataFrame` | `.<name>() takes an expression as text, which komira does not parse; write df[df["a"] > 1]` |
| `expanding` | both | `.<name>() is not supported yet` |
| `explode` | `DataFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `ffill` | both | `.<name>() is not supported yet` |
| `iat` | both | `.<name> selects by index label or position, and komira frames have no index: filter with df[pred], or sort_values(...).head(n)` |
| `iloc` | both | `.<name> selects by index label or position, and komira frames have no index: filter with df[pred], or sort_values(...).head(n)` |
| `index` | both | `komira frames have no index` |
| `info` | `DataFrame` | `.<name>() reports on a pandas object; run with materialize(), then call to_pandas().<name>()` |
| `interpolate` | both | `.<name>() is not supported yet` |
| `item` | both | `.<name> needs the rows: run the frame with materialize(), then convert the Result with to_pandas()` |
| `items` | both | `.<name> needs the rows: run the frame with materialize(), then convert the Result with to_pandas()` |
| `iterrows` | both | `.<name> needs the rows: run the frame with materialize(), then convert the Result with to_pandas()` |
| `itertuples` | both | `.<name> needs the rows: run the frame with materialize(), then convert the Result with to_pandas()` |
| `join` | `DataFrame` | `DataFrame.join joins on the index, which komira frames do not have; use merge(other, on=...)` |
| `loc` | both | `.<name> selects by index label or position, and komira frames have no index: filter with df[pred], or sort_values(...).head(n)` |
| `melt` | `DataFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `memory_usage` | `DataFrame` | `.<name>() reports on a pandas object; run with materialize(), then call to_pandas().<name>()` |
| `pct_change` | both | `.<name>() is not supported yet` |
| `pivot` | `DataFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `pivot_table` | `DataFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `plot` | both | `.plot needs the rows: use materialize().to_pandas().plot` |
| `query` | `DataFrame` | `.<name>() takes an expression as text, which komira does not parse; write df[df["a"] > 1]` |
| `reindex` | both | `komira frames have no index` |
| `reset_index` | both | `komira frames have no index` |
| `sample` | both | `.sample() is not supported: it picks rows at random, and a plan names no random rows` |
| `set_index` | both | `komira frames have no index` |
| `shape` | `DataFrame` | `.<name> needs a query to run: count rows with df.agg(n=(column, "size")).materialize()` |
| `shift` | both | `.<name>() is not supported yet` |
| `size` | `DataFrame` | `.<name> needs a query to run: count rows with df.agg(n=(column, "size")).materialize()` |
| `sort_index` | both | `komira frames have no index` |
| `sparse` | `Series` | `the .<name> accessor is not supported: komira has no categorical or sparse dtype` |
| `stack` | `DataFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `T` | `DataFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `to_arrow` | `DataFrame` | `a komira DataFrame is a plan: run it with .materialize(), then call .<name>() on the Result` |
| `to_dict` | `DataFrame` | `.<name>() is pandas' own: run with materialize(), then call to_pandas().<name>()` |
| `to_excel` | `DataFrame` | `.<name>() is pandas' own: run with materialize(), then call to_pandas().<name>()` |
| `to_list` | both | `.<name> needs the rows: run the frame with materialize(), then convert the Result with to_pandas()` |
| `to_markdown` | `DataFrame` | `.<name>() is pandas' own: run with materialize(), then call to_pandas().<name>()` |
| `to_numpy` | both | `.<name> needs the rows: run the frame with materialize(), then convert the Result with to_pandas()` |
| `to_pandas` | `DataFrame` | `a komira DataFrame is a plan: run it with .materialize(), then call .<name>() on the Result` |
| `to_polars` | `DataFrame` | `a komira DataFrame is a plan: run it with .materialize(), then call .<name>() on the Result` |
| `to_records` | `DataFrame` | `.<name>() is pandas' own: run with materialize(), then call to_pandas().<name>()` |
| `to_sql` | `DataFrame` | `.<name>() is pandas' own: run with materialize(), then call to_pandas().<name>()` |
| `to_string` | `DataFrame` | `.<name>() is pandas' own: run with materialize(), then call to_pandas().<name>()` |
| `tolist` | both | `.<name> needs the rows: run the frame with materialize(), then convert the Result with to_pandas()` |
| `transpose` | `DataFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `unique` | `Series` | `.<name>() gives the distinct values as an array in pandas, which needs the rows, and a komira Series is part of a plan: select the column as a frame and drop its duplicates, as df[[column]].drop_duplicates(), then run it with materialize()` |
| `unstack` | `DataFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `value_counts` | `Series` | `.<name>() gives a Series indexed by the values in pandas, and a komira Series has no index: count the rows per value with df.groupby(column).size(), and sort them with sort_values("size", ascending=False)` |
| `values` | both | `.<name> needs the rows: run the frame with materialize(), then convert the Result with to_pandas()` |

### `GroupBy`

| name | message |
|---|---|
| `cumcount` | `.<name>() is not supported yet; use min() or max() of an ordered key` |
| `filter` | `GroupBy.filter() is not supported yet; aggregate, then filter the result` |
| `first` | `.<name>() is not supported yet; use min() or max() of an ordered key` |
| `get_group` | `.<name> needs a query to run; aggregate with .size() and materialize()` |
| `groups` | `.<name> needs a query to run; aggregate with .size() and materialize()` |
| `indices` | `.<name> needs a query to run; aggregate with .size() and materialize()` |
| `last` | `.<name>() is not supported yet; use min() or max() of an ordered key` |
| `ngroups` | `.<name> needs a query to run; aggregate with .size() and materialize()` |
| `nth` | `.<name>() is not supported yet; use min() or max() of an ordered key` |
| `ohlc` | `.<name>() is not supported: komira has no time index` |
| `resample` | `.<name>() is not supported: komira has no time index` |

### `LazyFrame`, `LazyGroupBy` and `Expr`

| name | on | message |
|---|---|---|
| `apply` | `Expr` | `Expr.apply is not a polars verb; use map_elements(f, return_dtype=...)` |
| `cache` | `LazyFrame` | `.<name>() is not supported: komira runs a plan only at .collect()` |
| `collect_async` | `LazyFrame` | `.<name>() is not supported: komira runs a plan only at .collect()` |
| `explode` | `LazyFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `fetch` | `LazyFrame` | `a LazyFrame is a plan: run it with .collect(), then convert the Result` |
| `first` | `Expr`, `LazyGroupBy` | `.<name>() is not supported yet; use .min() or .max() of an ordered key` |
| `last` | `Expr`, `LazyGroupBy` | `.<name>() is not supported yet; use .min() or .max() of an ordered key` |
| `materialize` | `LazyFrame` | `.materialize() is the pandas-shaped skin's word; this frame runs at .collect()` |
| `profile` | `LazyFrame` | `.<name>() is not supported: komira runs a plan only at .collect()` |
| `sort_by` | `Expr` | `Expr.sort_by() is not supported: the plan carries no order inside an expression; sort the frame instead` |
| `to_arrow` | `LazyFrame` | `a LazyFrame is a plan: run it with .collect(), then convert the Result` |
| `to_pandas` | `LazyFrame` | `a LazyFrame is a plan: run it with .collect(), then convert the Result` |
| `to_polars` | `LazyFrame` | `a LazyFrame is a plan: run it with .collect(), then convert the Result` |
| `unpivot` | `LazyFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `with_column` | `LazyFrame` | `with_column() is not a polars verb; use with_columns()` |
