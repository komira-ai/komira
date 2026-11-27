# The Python DataFrame surface: verbs, capabilities and refusals

Status: design, partly built; the pages under [python/docs/](../../python/docs/dataframe/overview.md) say what is built, one page per feature. The tables here give each verb's designed spelling, and mark **not built** each one the skin does not define yet. This is the verb half of [the DataFrame surface](dataframe_surface.md):
that document gives the rules. This one has three parts:

- for each capability of the [surface capability matrix](../surface_capability_matrix.md), the verbs of
  each skin that reach it and the plan they build;
- the dtype names a dtype argument accepts;
- the refusal tables that section 5 of the rules document points to.

`km` is `import komira`, the pandas-shaped skin, and `kpl` is `komira.pl`, the polars-shaped skin. `df`
is a `km.DataFrame`, `s` a `km.Series`, `lf` a `kpl.LazyFrame` and `expr` a `kpl.Expr`.

## The capability map

The table has one row per capability of `CAPABILITIES` in
[tests/surface_capability_matrix.bzl](../../tests/surface_capability_matrix.bzl), in its order: 52 rows,
for the matrix's `pandas` and `polars` columns.

The last column says what the engine does with the plan today, from
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
section 11). A dash means the surface has no spelling, and the cell stays empty by decision. A spelling
marked **not built** is designed, but the skin does not define it yet: calling it raises Python's own
`AttributeError`, or the refusal its row names.

| capability | pandas-shaped (`km`) | polars-shaped (`kpl`) | plan | engine today |
|---|---|---|---|---|
| `scan_parquet` | `km.read_parquet(path)`, one local file; a glob, a directory or a list not built | `kpl.scan_parquet(path)`, the same | SCAN, `SOURCE_PARQUET`, local files (one file, a glob or a directory; Hive columns detected) | cut, for one file or several listed files, Hive columns included; a Hive scan that lists its files lazily (a directory or a partition predicate) is refused at lower (`LOWERING_SCAN_NOT_TOTAL`) |
| `scan_csv` | `km.read_csv(path, sep=",", header="infer")` | `kpl.scan_csv(path, separator=",", has_header=True)` | SCAN of the `komira.csv` binding, `source_kind` the binding's columnar or row layout (the hand-built `read_csv` shape of `komira_pandas_door_e2e` leaves it UNSET) | cut (`SOURCE_CSV`, one local file); a file with no header row (`header=None`, `has_header=False`) is refused at lower (`LOWERING_UNCUTTABLE_NODE`) |
| `scan_jsonl` | `km.read_json(path, lines=True)`; `lines=False` refused | `kpl.scan_ndjson(path)` | SCAN, `SOURCE_NDJSON` | cut (`SOURCE_JSONL`, one local file) |
| `scan_orc` | `km.read_orc(path)`, not built | `kpl.scan_orc(path)` (komira's verb; polars has none), not built | SCAN, `SOURCE_ORC` | refused at lower |
| `scan_avro` | `km.read_avro(path)` (komira's verb; pandas has none), not built | `kpl.scan_avro(path)` (komira's verb; polars reads Avro only eagerly), not built | SCAN, `SOURCE_AVRO` | refused at lower |
| `scan_arrow_ipc` | `km.read_feather(path)`, not built | `kpl.scan_ipc(path)`, not built | SCAN, `SOURCE_ARROW` | refused at lower |
| `scan_in_memory` | `km.from_arrow(data)`, not built | `kpl.from_arrow(data)`, not built | SCAN of a table the session registered from the Arrow C stream (rules section 4) | not wired from a skin: the plan wire has no in-memory source, and its encoder refuses one (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`). A table registered with libkomira's `komira_register_arrow_stream` is read by SQL, cut as `SOURCE_BATCH` |
| `scan_s3` | a reader given an `s3://` path, not built: the readers take a local path | the same | SCAN with the `s3` scheme | cut. The skins' plan entry (`komira_plan_stream`) reads through `LocalOnlyScanFs`, which refuses the scan at step `execute` (`SCAN_FS_UNSERVED`). SQL reads Parquet objects of a name bound with `Session.add_sql_binding` and `komira.files` (`komira_add_sql_binding`) through the session's `StoreScanFs`, and a Mojo caller of `run_sql_with` or `run_plan_with` can hand over an `S3ScanFs` |
| `scan_gs` | a reader given a `gs://` path, not built: the readers take a local path | the same | SCAN with the `gcs` scheme | cut, and read through `GcsScanFs` only when a Mojo caller hands `run_sql_with` or `run_plan_with` the opener; not wired from libkomira: its plan entry refuses the scan as for `scan_s3`, and `komira_add_sql_binding` refuses a `gs://` location (`STORAGE_URL_REFUSED`) |
| `scan_az` | a reader given an `az://` path, not built: the readers take a local path | the same | SCAN with the `azure` scheme | as `scan_s3`: SQL over a bound name reads through the session's `StoreScanFs`, and a Mojo caller can hand over an `AzureScanFs`; the plan entry refuses the scan |
| `filter` | `df[pred]`, where `pred` is a boolean `Series` of `df` | `lf.filter(pred)` | FILTER | cut |
| `project` | `df[["a", "b"]]`, `df.rename(columns=...)`, `add_prefix`, `add_suffix` | `lf.select("a", "b")`, `lf.select(kpl.col("a").alias("b"))`, `lf.rename(...)` | PROJECT of column references and aliases | cut |
| `computed_column` | `df.assign(x=...)`, `df["x"] = ...`; operators `+ - * /`, unary `-`, comparisons, `& \| ~`; `df.fillna`; not built: `// % **`, `abs()`, `round()`, `isna`, `notna` | `lf.with_columns(expr)`, `lf.select(expr)`; operators `+ - * / // %`, unary `-`, comparisons, `& \| ~`; `kpl.lit`, `abs`, `fill_null`, `is_null`, `is_not_null`; not built: `**`, `round`, `fill_nan`, `is_nan` | PROJECT of literals, binary and unary ops (`build_with_columns_plan`) | cut |
| `cast` | `df.astype(dtype or {col: dtype})`, `s.astype(dtype)` | `expr.cast(dtype)` | `EXPR_CAST` | in its node |
| `case_when` | `s.case_when(caselist)`, `s.where(cond, other)`, `s.mask(cond, other)`; `other` required; not built | `kpl.when(c).then(v).otherwise(w)`; `otherwise` required | `EXPR_WHEN` | in its node |
| `in_list` | `s.isin([...])` | `expr.is_in([...])` | the OR of `=` that `col_expr.is_in` and the SQL parser build, which the optimizer folds into `EXPR_IN_LIST` (`Expr.in_list_node`); more than 64 values refused, as the Mojo builder refuses them | in its node |
| `between` | `s.between(lo, hi, inclusive="both")`, not built | `expr.is_between(lo, hi, closed="both")` | the two comparisons `between_of` and the SQL parser build, not `EXPR_BETWEEN` | in its node; the cell stays empty (see [Grounding](#grounding-that-no-surface-reaches)) |
| `string_functions` | `s.str.lower`, `upper`, `len`, `slice`, `startswith`, `endswith`, `contains(p, regex=False)`, `replace(p, v, regex=False)`, `pad`; `+` of strings builds an arithmetic `add`, not a concatenation; not built: `strip` (refused by name) | `expr.str.to_lowercase`, `to_uppercase`, `len_chars`, `starts_with`, `ends_with`, `contains(p, literal=True)`; not built: `strip_chars`, `len_bytes`, `slice`, `replace(p, v, literal=True)`, `pad_start`, `pad_end`, `kpl.concat_str(exprs, separator=...)` | `EXPR_STRING_OP`, `EXPR_STRING_FN`, `EXPR_STRING_FN_N`, `EXPR_SUBSTRING` | in its node |
| `regexp` | `s.str.contains(p, regex=True)`, `match`, `fullmatch`, `extract(p, expand=False)` (one group), `replace(p, v, regex=True)` (every match) | not built: `expr.str.contains(p)` (raises `UnsupportedOperation` unless `literal=True`), `extract(p, group_index)`, `replace(p, v)` (first match), `replace_all(p, v)` | `EXPR_REGEXP` | in its node |
| `temporal_extract` | `s.dt.year`, `quarter`, `month`, `day`, `hour`, `minute`, `second`, `microsecond`, `dayofweek`, `dayofyear`, `floor(freq)` for one fixed unit | not built (the skin has no `expr.dt`): `expr.dt.year`, `quarter`, `month`, `day`, `hour`, `minute`, `second`, `millisecond`, `microsecond`, `weekday`, `ordinal_day`, `week`, `truncate(every)` for one fixed unit | `EXPR_EXTRACT` with the matching unit; pandas `dayofweek` is ISO minus one (Monday 0), polars `weekday` is ISO (Monday 1) | in its node |
| `math_functions` | not built: NumPy ufuncs on a `Series` (`np.sqrt(s)`, `np.log(s)`), `**` | not built: `expr.sqrt`, `exp`, `log(base)`, `log10`, `log1p`, `sin`, `cos`, `tan`, `arcsin`, `arccos`, `arctan`, `floor`, `ceil`, `pow`; the NumPy ufuncs of the same names | `EXPR_MATH_FN`, `EXPR_MATH_FN2` | in its node |
| `nested_access` | `s.struct.field(name)`, not built | `expr.struct.field(name)`, not built | `EXPR_STRUCT_FIELD` | in its node |
| `json_extract` | - | `expr.str.json_path_match(path)`, not built | `EXPR_JSON_EXTRACT` | in its node |
| `join_inner` | `df.merge(o, on=..., how="inner")` (or `left_on=`, `right_on=`) | `lf.join(o, on=..., how="inner")` | JOIN, `JOIN_INNER`, under the skin's naming PROJECT (rules section 8, ruling 8) | cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`) |
| `join_left` | `how="left"` | `how="left"` | JOIN, `JOIN_LEFT` | cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`) |
| `join_right` | `how="right"` | `how="right"` | JOIN, `JOIN_RIGHT` | cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`) |
| `join_full` | `how="outer"` | `how="full"` | JOIN, `JOIN_FULL`; pandas coalesces the `on=` keys | cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`) |
| `join_semi` | `df[df["k"].isin(o["k"])]` (rules section 8, ruling 16) | `how="semi"` | JOIN, `JOIN_SEMI`; left columns only | cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`) |
| `join_anti` | `df[~df["k"].isin(o["k"])]` | `how="anti"` | JOIN, `JOIN_ANTI`; left columns only | cut; a key pair the probe does not compare is refused (`LOWERING_JOIN_UNSERVED`) |
| `join_cross` | `how="cross"` | `how="cross"` | JOIN, `JOIN_CROSS` | cut; a cross join that names a key is refused (`LOWERING_JOIN_UNSERVED`) |
| `join_asof` | `km.merge_asof(l, r, on=..., by=..., direction=...)`; `allow_exact_matches=False` refused; not built | `lf.join_asof(o, on=..., by=..., strategy="backward"\|"forward"\|"nearest")`, not built | ASOF_JOIN | refused at lower |
| `aggregate` | `df.agg(total=("v", "sum"))`, `df.sum()` and the other frame reductions; a one-row frame (rules section 8, ruling 1) | `lf.select(kpl.col("v").sum())`, `lf.select(kpl.len())` | AGGREGATE with no keys | cut |
| `group_by` | `df.groupby(keys).agg(...)`, `.size()`, `.count()`, `.sum()`, `.mean()`, `.min()`, `.max()` and the others (rules section 8, ruling 4) | `lf.group_by(keys).agg(...)`, `.len()`, `.sum()` and the others | AGGREGATE; pandas adds a SORT above it (`sort=True`) and a FILTER of missing keys below it (`dropna=True`) | cut, for the group key types the sinks serve; a grouped sum or mean of a float column is refused when the plan runs, naming its step (the grouped sinks fold no float argument) |
| `window` | `df.groupby(k)[c].transform("sum")`; on an ordered frame `.cumsum()`, `.rolling(n, min_periods=1).mean()`; `.rank(method="min"\|"dense")`; a `Series` aggregate used inside `assign` | `expr.over(keys)`; with an order (`order_by=` or an ordered frame) `cum_sum`, `cum_count`, `cum_min`, `cum_max`, `rolling_sum`, `rolling_mean`, `rolling_min`, `rolling_max`; `rank(method="min"\|"max"\|"dense"\|"average")`; an aggregate beside a row-wise value in `select`, `with_columns` or `filter` (a broadcast) | PARTITION_BY (`select_broadcasting_aggregates` for a broadcast); rules section 7 for the order | cut; a key or argument type the window sink does not serve is refused (`LOWERING_WINDOW_UNSERVED`) |
| `sort` | `df.sort_values(by, ascending=True, na_position="last")` | `lf.sort(by, descending=False, nulls_last=False)` | SORT, every key with an explicit `nulls_first` (rules section 8, ruling 5) | cut |
| `topn` | `df.nlargest(n, columns)`, `df.nsmallest(n, columns)`, not built; `df.sort_values(...).head(n)` reaches the same `SINK_TOPN` as a LIMIT over a SORT | `lf.top_k(k, by=...)`, `lf.bottom_k(k, by=...)` | TOPN; ties at the boundary as in rules section 7 | cut (SINK_TOPN) |
| `topn_per_group` | `df.sort_values(o).groupby(k).head(n)`, not built | `lf.sort(o).group_by(k).head(n)`, not built | PARTITION_TOPN | cut (SINK_PARTITION_TOPN), reached today from SQL's `rn <= K` over ROW_NUMBER or RANK |
| `limit` | `df.head(n)` | `lf.head(n)`, `lf.limit(n)`; `lf.slice(offset, n)` on an ordered frame | LIMIT, offset 0 unless `slice` | cut; a limit or an offset above a sort is cut as that range of the sort (SINK_TOPN), an offset over no sort is refused |
| `distinct` | `df.drop_duplicates()`; `subset=` of fewer than every column not built (raises `UnsupportedOperation`) | `lf.unique()`, `lf.unique(subset=..., keep="any"\|"none")` | DISTINCT of whole rows; the polars skin builds a `subset` of fewer columns, and `keep="none"`, as a PARTITION_BY (`ROW_NUMBER` or `COUNT` per value) under a FILTER (dataframe_surface.md, rules section 7) | whole rows served by lowering for the key coverage of the grouped sinks; the polars `subset` and `keep="none"` are cut as a window (`LOWERING_WINDOW_UNSERVED` for a type the window sink does not serve) |
| `union` | `km.concat(frames)` | `kpl.concat(frames, how="vertical")` | UNION of one schema (`concat_schema_check`; rules section 8, ruling 15) | cut |
| `subquery` | - | - | neither library has a subquery inside an expression; a broadcast aggregate is a window | - |
| `view` | `km.add_sql_binding(name, df)`, then `km.sql(...)`; or `km.sql(..., name=df)`; not built (`Session.add_sql_binding` binds `komira.files` sources, not frames, and `Session.sql` takes SQL text only) | `km.add_sql_binding(name, lf)`, then `km.sql(...)`; or `km.sql(..., name=lf)`; not built | VIEW_REF | not wired |
| `udf_map` | `s.map(f)`, `s.apply(f)`, `df.apply(f, axis=1)`; not built | `expr.map_elements(f, return_dtype=...)`, `expr.map_batches(f, return_dtype=...)`; not built | a `UdfRef` called by `WireUdfApply` | not wired: libkomira's plan entry refuses an envelope that carries `UdfRef` entries at step `decode` (`PLAN_WIRE_UDFS_DROPPED`). Lowering, for a Mojo caller of `plan_envelope_from_bytes`, cuts a call that is a whole projection column (`OP_UDF_APPLY`) and refuses one inside a larger expression (`LOWERING_UDF_UNSERVED`) |
| `udf_filter` | `df[df["x"].map(f)]`, not built | `lf.filter(expr.map_elements(f, return_dtype="bool"))`, not built | a boolean `WireUdfApply` in a FILTER | not wired, as `udf_map`; lowering refuses a call in a predicate (`LOWERING_UDF_UNSERVED`) and a filter of the UDF kind (`LOWERING_UNCUTTABLE_NODE`) |
| `udf_agg` | `df.groupby(k).agg(out=("c", f))`, not built | `lf.group_by(k).agg(expr.agg_udf(f, return_dtype=...))` (komira's verb), not built | `AGG_UDF` over an AGGREGATE `UdfRef` | not wired, as `udf_map`; lowering refuses `AGG_UDF` (`LOWERING_UNCUTTABLE_NODE`) and a call in a group key or an aggregate's argument (`LOWERING_UDF_UNSERVED`) |
| `write_parquet` | `df.to_parquet(path)` | `lf.sink_parquet(path)`, not built | the envelope's `write_target`, Parquet | run by `run_plan_write`: libkomira's plan entry writes a local Parquet file, the bytes SQL's `COPY ... TO` writes, and answers `Count` |
| `write_csv` | `df.to_csv(path)`; `index=` has no effect | `lf.sink_csv(path)`, not built | the envelope's `write_target`, CSV | run by `run_plan_write`: libkomira's plan entry writes a local CSV file, the bytes SQL's `COPY ... TO` writes, and answers `Count` |
| `write_jsonl` | `df.to_json(path, orient="records", lines=True)`; other forms refused | `lf.sink_ndjson(path)`, not built | the envelope's `write_target`, JSON Lines | run by `run_plan_write`: libkomira's plan entry writes a local JSON Lines file, the bytes SQL's `COPY ... TO` writes, and answers `Count` |
| `null_semantics` | rules section 8, rulings 2, 3, 5, 7, 10, 11; ruling 6 (NaN missing in float columns) for `dropna` and `fillna`; not built: `isna`, `notna`, aggregates that skip NaN | the same rulings; ruling 6 for `is_null`, `is_not_null`, `fill_null` and `drop_nulls`; not built: `is_nan`, `fill_nan` | contract | contract |
| `errors` | rules section 6 | rules section 6 | contract | contract |
| `output_dtypes` | `df.materialize().to_pandas()`, `to_arrow()` | `lf.collect().to_polars()`, `to_arrow()` | contract | contract |
| `output_nan_null` | `to_pandas` with NumPy dtypes shows a NULL float as NaN, which is pandas' own form; `to_arrow` keeps NULL and NaN apart | a NULL and a NaN stay distinct in `to_polars` and `to_arrow` | contract | contract |

The pandas-shaped skin leaves 3 cells empty by decision: `between`, `json_extract` and `subquery`. The
polars-shaped skin leaves 2 empty: `between` and `subquery`. The counts are the dash and "stays empty"
entries of the table above.

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

## Verbs that reach a capability through another row

These verbs have no capability of their own. Each one builds the plan of the row named:

| verb | pandas-shaped | polars-shaped | row |
|---|---|---|---|
| frame rename | `rename(columns=)`, `add_prefix`, `add_suffix` | `rename(mapping)` | `project` |
| drop rows with a missing value | `dropna(subset=None, how="any")` | `drop_nulls(subset=None)` | `filter` (`drop_nulls_predicate`) |
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
table raises Python's own `AttributeError`. A test checks every entry by its full text.

A verb that does exist but refuses some arguments, or an unordered frame, is not listed here. It raises
`UnsupportedOperation` at the call.

### Module `komira`

| name | message |
|---|---|
| `Index`, `MultiIndex`, `RangeIndex` | `komira frames have no index` |
| `pivot_table`, `melt`, `crosstab`, `get_dummies` | `komira.<name>() is not supported yet: the plan has no node for it` |
| `merge_ordered` | `merge_ordered() fills by row order, which a frame does not have; use merge() then sort_values()` |
| `to_datetime`, `to_numeric` | `komira.<name>() is not supported; cast a column with s.astype(...)` |
| `NamedAgg` | `use a tuple: agg(out=("column", "func"))` |

### Module `komira.pl`

| name | message |
|---|---|
| `read_parquet`, `read_csv`, `read_ndjson`, `read_ipc`, `read_avro` | `komira.pl frames are lazy: use komira.pl.scan_<format>(...) and run it with .collect()` |
| `count` | `komira.pl.count() is refused: it named both questions in polars; say komira.pl.len() for rows or komira.pl.col(name).count() for non-null values` |
| `DataFrame` | `komira.pl has no eager frame: a LazyFrame runs at .collect(), which returns a Result` |

In the `read_*` message, `<format>` is the format of the name looked up (`parquet`, `csv`, `ndjson`,
`ipc`, `avro`).

### `DataFrame` and `Series`

| name | on | message |
|---|---|---|
| `loc`, `iloc`, `at`, `iat` | both | `.<name> selects by index label or position, and komira frames have no index: filter with df[pred], or sort_values(...).head(n)` |
| `index`, `set_index`, `reset_index`, `sort_index`, `reindex` | both | `komira frames have no index` |
| `join` | `DataFrame` | `DataFrame.join joins on the index, which komira frames do not have; use merge(other, on=...)` |
| `sample` | both | `.sample() is not supported: it picks rows at random, and a plan names no random rows` |
| `shift`, `diff`, `pct_change`, `ffill`, `bfill`, `interpolate`, `expanding` | both | `.<name>() is not supported yet` |
| `to_pandas`, `to_polars`, `to_arrow` | `DataFrame` | `a komira DataFrame is a plan: run it with .materialize(), then call .<name>() on the Result` |
| `iterrows`, `itertuples`, `items`, `values`, `to_numpy`, `to_list`, `tolist`, `item` | both | `.<name> needs the rows: run the frame with materialize(), then convert the Result with to_pandas()` |
| `shape`, `size`, `empty` | `DataFrame` | `.<name> needs a query to run: count rows with df.agg(n=(column, "size")).materialize()` |
| `to_dict`, `to_records`, `to_excel`, `to_sql`, `to_string`, `to_markdown` | `DataFrame` | `.<name>() is pandas' own: run with materialize(), then call to_pandas().<name>()` |
| `pivot`, `pivot_table`, `melt`, `stack`, `unstack`, `explode`, `transpose`, `T` | `DataFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `describe`, `info`, `memory_usage` | `DataFrame` | `.<name>() reports on a pandas object; run with materialize(), then call to_pandas().<name>()` |
| `query`, `eval` | `DataFrame` | `.<name>() takes an expression as text, which komira does not parse; write df[df["a"] > 1]` |
| `collect` | `DataFrame` | `.collect() is the polars-shaped skin's word; this frame runs at .materialize()` |
| `compute` | `DataFrame` | `.compute() is dask's word; this frame runs at .materialize()` |
| `cat`, `sparse` | `Series` | `the .<name> accessor is not supported: komira has no categorical or sparse dtype` |
| `value_counts` | `Series` | `.<name>() gives a Series indexed by the values in pandas, and a komira Series has no index: count the rows per value with df.groupby(column).size(), and sort them with sort_values("size", ascending=False)` |
| `plot` | both | `.plot needs the rows: use materialize().to_pandas().plot` |

### `GroupBy`

| name | message |
|---|---|
| `first`, `last`, `nth`, `cumcount` | `.<name>() is not supported yet; use min() or max() of an ordered key` |
| `filter` | `GroupBy.filter() is not supported yet; aggregate, then filter the result` |
| `ngroups`, `groups`, `indices`, `get_group` | `.<name> needs a query to run; aggregate with .size() and materialize()` |
| `ohlc`, `resample` | `.<name>() is not supported: komira has no time index` |

### `LazyFrame`, `LazyGroupBy` and `Expr`

| name | on | message |
|---|---|---|
| `materialize` | `LazyFrame` | `.materialize() is the pandas-shaped skin's word; this frame runs at .collect()` |
| `to_pandas`, `to_polars`, `to_arrow`, `fetch` | `LazyFrame` | `a LazyFrame is a plan: run it with .collect(), then convert the Result` |
| `with_column` | `LazyFrame` | `with_column() is not a polars verb; use with_columns()` |
| `unpivot`, `explode` | `LazyFrame` | `.<name>() is not supported yet: the plan has no node for it` |
| `cache`, `profile`, `collect_async` | `LazyFrame` | `.<name>() is not supported: komira runs a plan only at .collect()` |
| `apply` | `Expr` | `Expr.apply is not a polars verb; use map_elements(f, return_dtype=...)` |
| `sort_by` | `Expr` | `Expr.sort_by() is not supported: the plan carries no order inside an expression; sort the frame instead` |
| `first`, `last` | `Expr`, `LazyGroupBy` | `.<name>() is not supported yet; use .min() or .max() of an ordered key` |
