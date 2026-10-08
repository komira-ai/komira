# komira_test_oracle

The shared Python of the plan conformance oracle: test-only, run with the
hermetic Python ([tools/build/python](../../../../tools/build/python/README.md),
pins in [third_party/python](../../../../third_party/python/README.md)). It
holds the datasets (seeded tables built in Python and written in every format
the suite scans, so that every scan of one table has one expected answer
whatever the format, and no input is written by komira) and the expected
answers of the ORACLE cases (DuckDB runs each case's SQL over those tables,
and the result is written as the canonical result text of the Mojo harness
`komira_plan_harness`).

```sh
./buck2 build komira//src/tests/helpers/komira_test_oracle:test_datasets
./buck2 build komira//src/tests/helpers/komira_test_oracle:test_render
./buck2 build komira//src/tests/helpers/komira_test_oracle:test_expected
```

## The datasets

[`datasets.py`](datasets.py) builds each table from a fixed seed
(`random.Random` with a constant integer) and constant special values: no
clock, no file read. [`gen_datasets.py`](gen_datasets.py) is a
`python_oracle` script ([Oracles](../../../../tools/build/python/README.md#oracles)):
the target `:datasets` runs it twice on the farm and exists only if both
runs wrote the same bytes. Every input it has is a checked-in file or the
pinned pyarrow wheel; the rule refuses, at analysis, an input built by any
target outside `third_party/`.

| dataset | rows | what it holds |
|---|---|---|
| `types` | 256 | the nullable type matrix: `int8` to `int64` and `uint8` to `uint64` (each with its minimum and maximum); `float32` and `float64` finite (`-0.0`, the least subnormal, the extremes) and, in `f32_special` and `f64_special`, NaN and both infinities; `decimal128(9,2)` and `decimal128(38,10)` at their extremes; strings (empty, Unicode up to 4-byte, `\N`, `NaN`, `NULL`, quotes, commas, newlines, CR, TAB, backslash, NUL); `bin` (valid UTF-8) and `bin_raw` (bytes that are not UTF-8); `date32` from 0001-01-01 to 9999-12-31; timestamps in `s`, `ms`, `us` and `ns`, each naive and zoned (`UTC` for `s` and `ms`, `+05:30` for `us` and `ns`); `bool`. Every column holds NULLs and values. |
| `nulls` | 1000 | NULL-heavy, for the three-valued logic, aggregation and join shards: `id` (not nullable), group keys `k` with NULLs, `b1` and `b2` whose first nine rows are every pair of true, false and NULL, `i32`, `v` (quarters, so sums are exact), `s` holding both `""` and NULL, and `all_null` |
| `join_left`, `join_right` | 40, 30 | a join pair: `id`, key `k` (NULL, a duplicated key, and a key the other side lacks: 9 on the left, 10 on the right), string key `k2` (with `""` and NULL), and a value column |

The output directory holds, per dataset, `<dataset>.schema` and one file per
format, and `index.tsv`: one line per data file with its dataset, format, row
count and the columns it holds. Each file is a sub-target of `:datasets`
(`:datasets[types.parquet]`), for a Mojo library's `test_data` or a
`py_test`'s `$(location ...)`.

| format | file | written by |
|---|---|---|
| Parquet | `.parquet` | pyarrow, snappy, row groups of 100 rows |
| ORC | `.orc` | pyarrow |
| CSV | `.csv` | [`formats.py`](formats.py): NULL is an empty unquoted field, every string and binary value is quoted, so `""` is the empty string |
| JSON Lines | `.jsonl` | [`formats.py`](formats.py): decimals, dates and timestamps are strings |
| Arrow IPC file | `.arrow`, `.lz4.arrow`, `.zstd.arrow` | pyarrow, bodies uncompressed, LZ4 frame, ZSTD; batches of 100 rows |
| Arrow IPC stream | `.arrows`, `.lz4.arrows`, `.zstd.arrows` | as the file format |

A format's file holds the columns it carries exactly; the others are left
out of that file only, each for a reason recorded in `datasets.py` and seen
with the pinned pyarrow on the farm. `nulls` and the join pair are whole in
every format.

| format | leaves out of `types` | because |
|---|---|---|
| ORC | `u8` to `u64`; every timestamp but `ts_ns` | ORC has no unsigned type; pyarrow reads every ORC timestamp back as `timestamp[ns]` (another unit, and instants before 1677 out of range), and an ORC instant holds no zone name, so `ts_ns_tz` comes back with `tz=UTC` |
| Parquet | `ts_s`, `ts_s_tz` | Parquet has no seconds unit: pyarrow writes milliseconds and reads back `timestamp[ms]` |
| JSON Lines | `f32_special`, `f64_special`, `bin_raw` | JSON has no NaN or infinity, and a JSON string is text, not bytes |

The `ns` timestamps start at the first whole second of the int64 range
(1677-09-21 00:12:44), not at -2^63 ns: pyarrow's CSV and JSON parsers
refuse that instant.

### The schema sidecar

`<dataset>.schema` is one line: the schema line of the canonical result text
of the Mojo harness `komira_plan_harness`, one `<name>:<type>` entry per
column, `?` when nullable, separated by TAB, as its `type_text.mojo` spells
an entry and its `escape.mojo` escapes a name. Types are spelt as
plan_vocabulary's ArrowType without `ARROW_TYPE_`, in lower case, with
`decimal128(<p>,<s>)` and `timestamp_<unit>(<zone>)`. Names and zones are
escaped alike: a backslash, TAB, LF, CR and other control bytes take their
escapes, each of `: , < > [ ] { } ( )` a backslash, and so does a `#` that
comes first (`+05\:30`, `\#a\{b\}`). The spelling lives in
[`schema_text.py`](schema_text.py) alone, and only flat types are spelt: no
dataset has a nested column, and a nested type is refused rather than spelt
by code nothing exercises.

## Expected answers

An ORACLE case is `oracle/<shard>/<case>.sql`: one SELECT after a header of
`--` lines ([`oracle_case.py`](oracle_case.py)): `-- order:` (`total`,
`none` or `keys=<c1>,<c2>`, required), `-- float:` (`ulps=<n>` or
`rel=<x>`, default `ulps=0`) and `-- not null:` (the columns declared not
nullable; every other column is nullable). DuckDB's result types carry no
nullability, so the declaration is hand-derived from the query semantics
document's type table, and a declared column that holds a NULL is refused.
The order policy is held to the query (`check_order_policy` in
[`sql_discipline.py`](sql_discipline.py), run on every case before it
runs): `total` needs an ORDER BY on the outermost query (a SELECT, or the
whole of a UNION), `keys=<c1>,<c2>` one whose leading keys are exactly
those columns, in order, each a bare column name; more keys may follow.
Otherwise the file would freeze the order DuckDB writes the rows in: a
window's partition order, or a subquery's ORDER BY, which SQL does not
keep. Every ORDER BY in the query, the outermost one included, must
also fix whatever order the answer depends on (the tie check, below);
under `keys=` a run of equal keys is compared as a multiset, so ties
within it are never compared.

[`gen_expected.py`](gen_expected.py) is the `python_oracle` `:expected`. It
hands DuckDB (the pinned wheel, 1.5.6) every dataset of `datasets.py` and
every HAND twin input of [`twin_inputs.py`](twin_inputs.py) as a pyarrow
table built in Python, never a file read back, runs with `threads = 1`,
`autoload_known_extensions` and `autoinstall_known_extensions` off and
`enable_external_access` off, set when the database opens (`CONFIG`), so
no query loads or downloads an extension, reads a file or reaches a Python
variable, and with `TimeZone = 'UTC'` and `Calendar = 'gregorian'`, set
right after and before any query (the wheel refuses `Calendar` in the
opening config): DuckDB's ICU takes its default zone from the process's
`TZ` and its default calendar from its locale, and under
`LC_ALL=th_TH.UTF-8` a year of a TIMESTAMPTZ is Buddhist (2026 is 2569).
`:test_connect` runs under that locale and `TZ=Asia/Kathmandu` and holds
the oracle's connection to the Gregorian year and the UTC hour. It writes `expect/<shard>/<case>.tsv` (a sub-target
`:expected[expect/<shard>/<case>.tsv]`) with, after the policy lines,
`# GENERATED by gen_expected.py (duckdb <version>, pyarrow <version>) from oracle/<shard>/<case>.sql`.
Before it runs a query it holds that same text to
[`sql_discipline.py`](sql_discipline.py), on DuckDB's own parse of it
(`json_serialize_sql`): every ORDER BY key states ASC or DESC and NULLS
FIRST or NULLS LAST (the query's, a window's OVER clause's, and a function's
own argument ordering, `first_value(x ORDER BY y) OVER (...)`, which DuckDB
keeps apart in `arg_orders`), every aggregate whose answer depends on the
order rows reach it (`_ORDER_SENSITIVE`: `first`/`arbitrary`, `last`,
`any_value`, `list`/`array_agg`, `string_agg`/`group_concat`/`listagg`,
the `arg_min`/`arg_max`/`min_by`/`max_by` family, `mode`, `approx_top_k`,
`approx_quantile`, `reservoir_quantile`) has an ORDER BY of its own, plain
or as a window function, and JSON's `json_group_array`,
`json_group_object` and `json_group_structure` (macros over `string_agg`
with none) are refused; `row_number`, `ntile`, `lead`, `lag`,
`first_value`, `last_value`, `nth_value` and `fill` have an ORDER BY in
their OVER clause or of their own; `list_sort`/`array_sort` and
`list_grade_up`/`array_grade_up`/`grade_up` name their direction and NULL
placement as cast literals (else DuckDB reads the session's
`default_order` and `default_null_order`), and `list_reverse_sort`, which
always reads `default_order`, is refused (`:test_sql_discipline` holds
these lists to every aggregate `duckdb_functions()` lists, each either on
them or on its list of order-free ones, and to the built-in macros that
reach one; ties among an ORDER BY's keys are not seen), every literal is
the operand of a CAST (a
literal that is itself a LIMIT or OFFSET count aside, not one inside a
subquery computing it), FROM names only what the oracle hands DuckDB (each
table reference, at any depth, is a table `gen_expected.py` registered,
named bare and with no `AT (...)` time-travel clause, or a CTE in scope,
which is the query that defines it but not
the CTE's own body; or a subquery, a join, a VALUES list, no FROM, or the table function
`range`, `generate_series` or `unnest`; so no `query()`, `read_text()`,
`glob()` or other table function, no catalog view such as `duckdb_tables`
or `pg_catalog.pg_settings`, no schema or catalog qualifier, no file path
read by a replacement scan, no PIVOT or SUMMARIZE), no call to a function
on the module's list of functions whose answer reads more than their
arguments (`_UNSTABLE`:
every scalar or aggregate function DuckDB marks VOLATILE or
CONSISTENT_WITHIN_QUERY but `error`; ICU's local-time clocks,
`current_setting` and `getvariable`; the functions DuckDB leaves
CONSISTENT that bind, plan or parse SQL text (`json_serialize_plan`,
`json_serialize_sql`, `json_deserialize_sql`), look a name up in the
catalog, the log manager or the loaded extensions (`make_type`,
`parse_duckdb_log_message`, `st_setcrs`), or answer with the running DuckDB (`version`, `vector_type`); and
the nine built-in scalar macros
that reach one, a session function, a table or another table function,
such as `ago`; `:test_sql_discipline` derives the functions and the macros
from `duckdb_functions()` and fails on a missing name or a macro listed
that it does not derive), to a `duckdb_` or
`pragma_` function, or to one-argument `age`, no SQL value keyword the
binder may turn into a call (`current_timestamp`, `localtime`, `user` and
the other eight names DuckDB's `GetSQLValueFunctionName` maps: a COLUMN_REF
in the parse, quoted or not, so it is refused in each of the four places
the binder tries the map: unqualified, qualified by `alias` in any case, in
a table function's arguments, and in a `COLUMNS(...)` expression; a column
so named is read as `t.current_date`), no `USING SAMPLE` or `TABLESAMPLE`,
no `COLLATE` (a collation such as `nocase` makes strings that differ
equal, so a sort, a GROUP BY or a DISTINCT under it keeps whichever
DuckDB reaches first, and the tie check's keys sort under it too:
`SELECT s COLLATE nocase AS s ... ORDER BY s` writes `a, A, a`), one
SELECT. DuckDB's
default placement is NULLS LAST, as the plan's is, so a key that leaves it
unstated, or a literal left uncast, computes the same rows today: only this
check notices.

Three more of its rules hold what a row's position decides. A window whose
frame has a ROWS bound (`ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT
ROW`) has an ORDER BY in its OVER clause, whatever the function; a RANGE or
GROUPS frame needs none, since with no ORDER BY every row of a partition is
a peer of every other and the frame is the partition or nothing. A LIMIT,
an OFFSET and a `DISTINCT ON` have an ORDER BY in the same query (one in a
subquery below does not count). One-argument `histogram(x)` takes `x` as a
CAST to a type other than FLOAT or DOUBLE: DuckDB keys a FLOAT or DOUBLE
histogram in a `std::map` ordered by `<`, under which NaN is equivalent to
every key and -0.0 to 0.0, so the answer follows the rows' order
(`histogram(f64_special)` over `types` is `{nan=222}` as built and a full
map with its rows reversed); `histogram` with bins and `histogram_exact`
take bins that read no column (at any depth), since DuckDB fixes a
group's bins from its first row.

**The row-order check.** `gen_expected.py` runs every case again with the
tables it names registered in other orders. A table's orders are each of
its rotations (its rows from `i` on, then the ones before) and the
reverse of each, `2n` for a table of `n` rows, the as-built order among
them. A case naming one table runs under that table's other `2n - 1`
orders; a case naming two or more runs under every combination of their
tables' own orders but the as-built one (the joint scheme), when there
are at most `JOINT_BUDGET` (5000) combinations. Above it (`nulls` joined to any
other table; `types` to any but `ints_nullable`) the case runs under the
`2n - 1` orders of its largest table, every table rotated by the same `i`
modulo its own size (the shared scheme), and its expected file carries a
`# row-order check: ...` comment line saying so. It refuses the case
unless each answer equals the first under the case's policy, as
`canon.compare` compares a result with its expectation: as a multiset
under `order: none`, row for row under `total`, in key order with each
run of equal keys as a multiset under `keys`, floats within the case's
tolerance. Every row of every table the case reads arrives first in some
order and last in some order, and so does every row of any subset of a
table (the rows a WHERE keeps, a group's rows); in the joint scheme it
does so under every order of each other table. The check sees any answer
that depends on which row of each table arrives first or which arrives
last, whatever the construct reads the rows in the tables' order: those
the rules above refuse, a construct no rule names, and the ties no rule
can see from the parse: a LIMIT
whose ORDER BY ties at the cut, the zero `min`, `max`, a quantile or a
GROUP BY or DISTINCT key keeps when a column holds both -0.0 and 0.0
(-0.0 equals 0.0, and each keeps one of them by its position;
`sort_rows`' zeros arrive 0.0, -0.0, 0.0, so the reversal alone keeps a
0.0 first, and the rotation that starts at the -0.0 is what moves them),
and one that needs two tables' orders together (a `min` over a join of
`sort_rows` and `ints_nullable` that keeps the -0.0 only with
`sort_rows` rotated by 2 and `ints_nullable` by 1). It cannot see a
construct that reads rows in an order an inner sort fixes (a
subquery's or a CTE's ORDER BY, a window's sort), whatever the tables'
order: that is the tie check's. Nor a
dependence on the order of rows in the middle that no rotation or
reversed rotation gives (there are `n!` orders), in the shared scheme
one on a combination of two tables' orders that no shared `i` gives, a
special value the column does not hold, or more than the order (the
thread count, fixed at 1; the DuckDB version). It reorders one
connection (re-registering only the tables whose order changed), and
costs 4 to 6.5 ms of queries per order on the farm: a case on one table
of 9 rows runs 17 orders (0.07 s for a case on `sort_rows`, 13 orders);
a case on `types` (256 rows, 511
orders) costs about 2 s and one on `nulls` (1000 rows, 1999 orders)
about 7 s, and a join of `join_left` and `join_right` (4799 joint
orders) 20 to 31 s, in each of the action's two runs.

**The tie check.** An ORDER BY whose keys tie leaves the tied rows in
the order they reached it, and when that order comes from an inner
sort (a subquery's or a CTE's ORDER BY, a window's sort) it is the same
whatever the tables' order, so the row-order check cannot see it: a
constant key over a subquery ordered by `id`, `row_number() OVER (ORDER
BY k)` over that subquery, `string_agg(... ORDER BY k)` or `arg_max(...
ORDER BY k)` within a group of equal `k`, an inner `ORDER BY k LIMIT 3`
tied at its cut. `gen_expected.py` finds every ORDER BY in the query
that can break a tie its answer shows (`tie_sites`) and runs the case
again with tiebreak keys after its keys, ascending (NULLS LAST) and
then descending (NULLS FIRST), one ORDER BY at a time, and, when there
are two or more, all of them at once each way. It refuses the case
unless every run equals the first under the case's policy (as the
row-order check compares), every float zero taken as 0.0 (DuckDB 1.5.6
returns a column it sorts on by position with -0.0 turned into 0.0).
Two rows an ORDER BY ties but its reader can tell apart come out in
opposite orders in the two runs, so if the answer depends on their
order, one run differs. The ORDER BYs and their tiebreak keys:

- a query node's ORDER BY (the outermost, a subquery's, a CTE's, a set
  operation's or one of its branches'): every output column of that
  node, by position, which is all its reader sees. The count is the
  select list's length, or, when a star or `unnest` in it may write
  more columns, DuckDB's own, read from the binder's refusal of a
  position past the last. `ORDER BY ALL` already orders by every output
  column and is left as written;
- a window's OVER clause ORDER BY, when the function reads row positions
  (`row_number`, `lag`, `lead`, `first_value`, `last_value`,
  `nth_value`, `ntile`, `fill`) or its frame counts rows (ROWS):
  `row(*COLUMNS(*))`, the whole row of the node's FROM, or with a
  GROUP BY its group expressions (each group is one row), and
  `grouping()` of them under grouping sets. The rank family and RANGE or
  GROUPS frames are left as written: they answer the same for every
  peer, and a tiebreak would split the peers;
- a window function's own ORDER BY (`row_number(ORDER BY k) OVER ()`,
  `lag(x ORDER BY y) OVER ()`, `string_agg(x, ',' ORDER BY y) OVER ()`):
  the same keys as an OVER clause ORDER BY, every row that reaches the
  window told apart. The function's arguments are not enough there:
  `row_number` has none, `lag(k ORDER BY k)` reads which row comes
  before the current one, not only `k`, and `lag`'s offset and default
  are not among its arguments. The rank family's own ORDER BY
  (`rank(ORDER BY k) OVER ()`) is left as written, as in an OVER clause:
  `rank`, `percent_rank` and `cume_dist`, the members DuckDB 1.5.6 takes
  one on (it refuses one on `dense_rank` and `rank_dense`);
- an aggregate's own ORDER BY (`string_agg(x, ',' ORDER BY y)`,
  `arg_max(x, y ORDER BY z)`): the function's arguments, all it reads
  of a row. A `COLUMNS(*)` argument is a key too: DuckDB expands the
  same star in the argument and the key together, one aggregate per
  column (`first(COLUMNS(*) ORDER BY t)` over `s, t` is `first(s ORDER
  BY t, s)` and `first(t ORDER BY t, t)`). The whole row,
  `row(*COLUMNS(*))`, cannot be that key: DuckDB 1.5.6 refuses a second,
  different star in one expression.

Each run's columns are compared by position under the case's names: an
unaliased column DuckDB names after its expression
(`string_agg(s, ',' ORDER BY s)`) is named after the run's rewritten
ORDER BY, while the keys change neither the count nor the types of the
columns.

A tie that cannot change the answer passes: a unique inner key
(`rank() OVER (ORDER BY id)`, `ORDER BY k, id`) gives the same rows
with the tiebreak, as does a tie among rows its reader cannot tell
apart. Under `order: total`, rows equal in every column but the sign of
a zero tie in every sort, so two such rows next to each other are
refused too, even where a key the output does not hold tells them apart
(`SELECT f ... ORDER BY id`: output the key). What it does not see: a
dependence only on an order between the two extremes (the third of
three tied rows kept by a filter that wants the middle one), or on two
ORDER BYs turned opposite ways at once (each is run alone and all are
run the same way); two windows over rows equal in every column of their
FROM (no key tells such rows apart, so no tiebreak moves them, yet
which of them each window puts first can pair its answers differently);
a tie between -0.0 and 0.0, or among strings a
collation makes equal (sql_discipline.py refuses `COLLATE`; no table
the oracle registers carries one); an order an aggregate with no ORDER
BY reads that the rules above accept (a float sum's rounding, which
the case's float policy is for; which zero `min` keeps). It also
refuses more than it must: a position-reading window over the default
RANGE frame whose frame end the tiebreak moves (`nth_value` and
`last_value` over tied peers that hold the same value); a
position-reading window, or a window with its own ORDER BY, in a
QUALIFY, or in a query with aggregates and no GROUP BY, where DuckDB
1.5.6 does not bind `row(*COLUMNS(*))` (the refusal says the tie
check's run failed; compute the window in a subquery's select list); an
outer query that names an inner column by its automatic name, which the
tiebreak rewrites (the run fails; alias the column); a `COLUMNS(c ->
...)` lambda argument to an ordered aggregate, which DuckDB 1.5.6
refuses beside the `COLUMNS(*)` key ("Multiple different STAR/COLUMNS");
and a float
column an inner ORDER BY passes on, whose -0.0 the tiebreak run turns
into 0.0, when the answer reads the sign (`1 / f`). It costs two runs
per ORDER BY, two more when there are several, and one binder probe per
ORDER BY over a star.

[`render.py`](render.py) writes a pyarrow table as the harness's text, flat
types only (bool, the integers, float16/32/64, string and large_string,
binary, large_binary and fixed_size_binary, decimal128 and decimal256, the
dates, times, timestamps and durations as their stored integers, null),
cell for cell as `render.mojo` does, with one difference the format allows:
a NaN is written bare (`NaN`, which matches any NaN), the harness's
expected-side default, because the bits of a computed NaN depend on the
machine. A float's decimal half is what Mojo's float writer prints, the
shortest round-trip digits in Python's `repr` layout. The schema line is
[`schema_text.py`](schema_text.py)'s. [`canon.py`](canon.py) reads the text
back: it refuses what `parse.mojo` refuses, checks each cell against its
column's type, and compares two files as `compare.mojo` does.

Every case here is the twin of a HAND case of komira_plan_conformance (the
same plan over the same input) and its expectation must equal the HAND one:
a check on the oracle SQL, the HAND derivation and the query semantics
document at once. `twins/hand/` holds copies of those HAND expectations and
`twins/inputs/` copies of their JSON Lines inputs; the copies are compared by
`:test_expected`, not tied to the originals by a build edge, so a change to
a HAND case is copied here by hand.

| shard | cases |
|---|---|
| `filter_3vl` | `and_or_truth_table`, `not_truth_table`, `filter_not_and`, `compare_null_literal`, `compare_null_value`, `filter_ne_drops_null` |
| `agg_grouping` | `count_star_vs_count_col`, `sum_all_null_group_is_null`, `min_max_all_null_group`, `empty_input_no_keys`, `empty_input_with_keys` |
| `sort_topn_limit` | `asc_nulls_first`, `desc_nulls_last`, `multi_key_mixed`, `neg_zero_ties_zero`, `topn_two_keys`, `limit_over_sort` |

What the twins found: DuckDB 1.5.6 returns a float sort key with `-0.0`
turned into `0.0` (`ORDER BY f` gives the row whose `f` is `-0.0` the value
`0.0`), while a sort keeps its input's values. `neg_zero_ties_zero` sorts on
`f + 0.0`, which orders as `f` does (it maps only `-0.0`, to the `0.0` it
ties with) and leaves `f` untouched. A sort on a float column with `-0.0` in
it needs the same key.

## Tests

| target | what it proves | the defect it catches |
|---|---|---|
| `:datasets` | `gen_datasets.py` writes the same bytes in two runs, and writes exactly the files `outs` declares | a seed that is not fixed (a clock, a process id, a hash order); a dataset or format added to one of `datasets.py` and the BUCK file but not the other |
| `:test_datasets` | in a process of its own, rebuilds every table from its seeds and, for every dataset and format: the file, taken as the format, container and codec its name says (a table written out in the test, not read from `formats.py`), decodes with pyarrow to the table's columns (names in order, types with their parameters, nullability where the format keeps it, row count, and values: NULL positions equal, floats by their bits, so NaN, `-0.0` and `0.0` are told apart); each sidecar equals the line written out by hand in the test; each format leaves out exactly the columns listed by hand; the tables hold the special values (every integer and float extreme, the least decimal step at each scale, the first and last instant of every timestamp column), NULL pairs and join keys listed by hand; LZ4 and ZSTD IPC bodies hold frames of their codec; Parquet row groups and IPC batches are of 100 rows | a writer that turns NULL into a value (the CSV empty string), loses `-0.0` or a NaN, drops a type parameter or a column, or ignores its codec; one format's bytes under another's name; formats that disagree; a wrong unit scale in the generator; a sidecar that drifts from the harness's spelling; a generator change that drops the special values a shard relies on |
| `:expected` | each ORACLE case's query passes `sql_discipline.py` and DuckDB's answer renders; two runs write the same bytes; exactly the declared files are written | an ORDER BY key with no stated NULL placement or direction, an uncast literal, a call to a listed clock or random function, a SQL value keyword, a sample, a FROM that names a table not registered (each case names one, so passing no names turns it red) or reads one `AT (...)`; a query DuckDB refuses; a not-null declaration a NULL contradicts; an answer that differs between two runs on one worker (an unseeded draw, a clock, a hash order in the generator); a window ROWS frame with no OVER ORDER BY, a LIMIT, OFFSET or DISTINCT ON with no ORDER BY, a FLOAT or DOUBLE histogram, bins read from a column; an `order: total` case whose outermost query has no ORDER BY, or a `keys=<cols>` case whose outermost ORDER BY is not led by exactly those columns (a window's partition order or a subquery's ORDER BY frozen into the file); an answer that changes with any table's rows rotated or a rotation reversed, every combination of the tables' orders within the budget (the row-order check, under the case's policy), so any answer that depends on which row of each table arrives first or last; a case with an ORDER BY, at any depth, whose ties the answer shows (the tie check: a constant key or a tied one over an inner sort; a position-reading window, an ordered aggregate or an inner LIMIT whose ORDER BY ties rows an inner sort ordered; under `total`, rows that differ only in a zero's sign). Not a dependence on an order of rows in the middle that no rotation gives, or, above the budget, on two tables' orders together, or a special value a column does not hold: the two runs execute the same plan in the same order (`threads = 1`), so such an order is the same twice |
| `:test_sql_discipline` | `sql_discipline.py` refuses a query that breaks one rule, naming where DuckDB's parse keeps the offence, and accepts the ORDER BY and literal queries with the rule kept: ORDER BY keys of the query, an OVER clause, an aggregate and a window function's `arg_orders`; uncast literals, the LIMIT and OFFSET counts, a literal in a subquery computing a count (through a list and through dicts only); random(), now(), current_localtime(), current_localtimestamp(), `USING SAMPLE` and `TABLESAMPLE`; the macros ago(), pg_postmaster_start_time() and pg_conf_load_time(), current_schema(), a `duckdb_` and a `pragma_` table function, one-argument age() (two-argument accepted); current_setting() and getvariable(); json_serialize_plan() (with `optimize := true` its answer holds `now()`), json_serialize_sql(), json_deserialize_sql(), make_type(), parse_duckdb_log_message(), st_setcrs(), version() and vector_type(), each hand-listed name a function of the running DuckDB, and no aggregate marked unstable (`list_aggregate` calls one by a string); `_UNSTABLE` holds every scalar or aggregate function the running DuckDB marks VOLATILE or CONSISTENT_WITHIN_QUERY (`error` aside), and `_MACROS` exactly the built-in scalar macros reaching one, a session function, a table or a table function outside the allowlist, directly or through another macro (a value keyword in a macro's table function argument binding qualified); each allowed table function is a built-in table function, not a table macro; FROM: `query()`, `query_table()`, `json_execute_serialized_sql()`, `read_text()`, `read_blob()`, `glob()` and a qualified `range()`, the catalog views `duckdb_tables`, `duckdb_databases`, `duckdb_logs` and `pg_catalog.pg_settings`, a registered table qualified by a schema or a catalog or read `AT (VERSION => ...)` or `AT (TIMESTAMP => ...)`, a quoted file path, UNPIVOT and SUMMARIZE are refused, also at a join's side, in a FROM or WHERE subquery and in a table function's argument; a CTE outside its query or in its own body is refused; the registered tables in any case, no FROM, VALUES, `range`, `generate_series`, `unnest`, a CTE named like a dataset or a catalog view, chained, read from a subquery or recursively, are accepted; each SQL value keyword in both cases, quoted, `alias.`- and `ALIAS.`-qualified, in a WHERE, in a table function's argument and in a `COLUMNS(...)` expression, and the same names table-qualified, also in `* REPLACE` (accepted); a ROWS frame with no OVER ORDER BY (bounded at either end, partitioned, named, in a subquery, with the function's own ORDER BY) refused, and with one, unbounded, RANGE and GROUPS accepted; LIMIT, OFFSET, LIMIT percent and DISTINCT ON with no ORDER BY in their query (at the top, after a UNION ALL, in a FROM or WHERE subquery) refused, with one, and plain DISTINCT, accepted; one-argument `histogram` with no CAST or a CAST to DOUBLE, FLOAT8, REAL, an unbound name or TRY_CAST to DOUBLE, and as a window, refused, and to BIGINT, VARCHAR, a list or struct of DOUBLE accepted; bins from a column, also inside a subquery, refused, constant bins and a subquery reading no column accepted; `COLLATE` in the select list, an ORDER BY key, a WHERE, a GROUP BY and a FROM subquery refused, a column named `collation` and the word in a string accepted; two statements, a non-SELECT | a frame rule that reads only `start` or only `end`, takes the function's own ORDER BY for the OVER clause's, or refuses RANGE and GROUPS frames; a LIMIT rule that forgets LIMIT percent or takes an ORDER BY of another query; a DISTINCT rule that refuses plain DISTINCT; a histogram key list missing DOUBLE, FLOAT or an unbound name, or refusing a safe type; a bins rule off or blind to a column inside a subquery; a check that reads `orders` but not `arg_orders`; a LIMIT exemption inherited by the subquery below it; a random rule that looks only at function calls; a clock rule that reads FUNCTION nodes only, so `current_timestamp` (a COLUMN_REF) passes; a list missing a macro DuckDB expands into a clock, or a function a DuckDB upgrade marks unstable; a hand-listed name dropped or renamed by a DuckDB upgrade; an upgrade that marks an aggregate unstable, which `list_aggregate` would reach by name; a FROM rule that admits a registered table without looking at its AT clause; a FROM that runs SQL text, reads the worker's files or the catalog, or reaches past the registered tables by a qualifier, a replacement scan or a CTE scope that is shared, global or open in the CTE's own body; a keyword rule that skips `COLUMNS(...)` or compares `alias` with case; a COLLATE rule off or read from the text; a check that refuses for the wrong reason or refuses a kept rule |
| `:test_row_order` | the order set: for every table size and every size to 12, each order is a permutation, every row arrives first under some rotation and last under some rotation, and the same under the reversed rotations; `table_orders(n)` is the as-built order then `2n - 1` others, all distinct; `case_order_set` is `row_orders` of the one table a query names (a CTE, no table: none), with no note; for two and three tables within the budget (`groups` and `bool_pairs`, those and `ints_nullable`, `join_left` and `join_right`, 4799) exactly every combination of each table's own orders but the as-built one, each once; for `types` and `groups` (7167) `row_orders` of `types` and a note; the budget inclusive (251 orders fit a budget of 251, not 250); each table read back under four orders, on a connection `connect(order)` opens and on one `register()` reorders in turn, and under a joint order that names two tables, is the as-built rows in that order (compared as Arrow arrays, floats by their bits); `row_order_diffs` reports the queries DuckDB answers by the rows' order on these tables (a FLOAT histogram over NaN, two ROWS frames, LIMIT and DISTINCT ON with no ORDER BY, bins from a column, each also refused by `sql_discipline.py`; a LIMIT tied at its cut, `min`/`max` and a GROUP BY key over `types`' zeros, and over `sort_rows`' zeros `min`/`max`, a GROUP BY key, a DISTINCT key, `ORDER BY f ... LIMIT 1` and `median`, accepted by it, the last five also required not reported under the reversal alone; and a `min` over `sort_rows` joined to `ints_nullable`, required not reported under the shared orders), under the case's policy (`SELECT id FROM groups` under `total` and not `none`; tied keys under `total` and not `keys`), and none of the order-free queries (RANGE, GROUPS and EXCLUDE frames with no ORDER BY, a ROWS frame with one, a VARCHAR histogram, constant bins, LIMIT and DISTINCT ON under an ORDER BY, sums over `nulls`' 1999 orders); `main()` refuses a planted `order: total` case whose ORDER BY ties and writes the same query under `order: keys=a`, refuses the two-table `min` naming a joint order, and writes a case over the budget with its `# row-order check:` note and one within it without | the check off or run on the as-built connection; an order set where some row never comes first or last (the former reversal and one shuffle: the four `sort_rows` zero queries other than `median` pass under it); orders sized by the smallest table; the joint scheme off (one shared `i`), missing a table or a combination, holding the as-built order, or with the budget ignored, exclusive or without its note; `connect(order)` or `register()` ignoring its order, or a joint order's table; the check registering only its first order, or not re-registering a table whose order changed; every case compared as a multiset, or row for row; `main()` not calling the check |
| `:test_order_policy` | `check_order_policy` refuses under `total` the window query with no top-level ORDER BY, a subquery's ORDER BY under a SELECT with none, and a UNION ALL whose branches alone are ordered; under `keys` the same subquery under `keys=id`, an ORDER BY led by another column, too short, in another order, qualified (`s.a`) or an expression; it accepts an outermost ORDER BY under `total` (a table, a CTE, a UNION ALL, the window query), `keys` led by exactly its columns with more after, and `none` with no ORDER BY; `main()` refuses the three queries found accepted before the rule (the window and the subquery under `total`, the subquery under `keys=id`) without writing them, and writes the two with an outermost ORDER BY; `main()` refuses, saying the ORDER BY does not fix the order, nine `total` cases whose outermost ORDER BY ties rows that differ behind an inner sort (a constant key over a subquery ordered by `id`; `ORDER BY a` over that subquery, over the same CTE, over one ordered by `id` ascending (only the descending run sees it), and with the tied rows differing in the second output column only; `ORDER BY k` over a window's `rank()` sort; a LIMIT tied at its cut; zeros differing only in sign under a constant key, and under `ORDER BY id` with `id` not in the output, the documented over-refusal), and writes six (a second key that breaks the tie; tied rows that are the same row; a UNION ALL; `neg_zero_ties_zero`'s expression key over -0.0 and 0.0; a LIMIT without a tie at its cut; the tied subquery under `keys=a`); under `total` and under `none` it refuses ties of inner ORDER BYs behind an inner sort (`row_number()` over a tied `k` fed by a subquery ordered by `id` DESC, and by an unused `rank()` over `id` DESC; `string_agg()` and `arg_max()` whose own ORDER BY ties; an inner LIMIT tied at its cut, also through stars with the tied rows differing only in the second column a star writes; a window with a constant key over GROUP BY groups; a window over ROLLUP groups only `grouping()` tells apart; two inner LIMITs whose ties show only together; a window function's own ORDER BY tied over that subquery: `row_number(ORDER BY k) OVER ()`, `lag(k ORDER BY k) OVER ()` and `lag(k, 1, id ORDER BY k) OVER ()`; `first`, `last` and `string_agg` over a `COLUMNS(*)` argument whose own ORDER BY ties) and writes each with a unique inner key, the rank family and a RANGE `sum` over a tied key, `rank`, `percent_rank` and `cume_dist` with their own ORDER BY over a tied key, unaliased columns named after their own ORDER BY (`string_agg(s, ',' ORDER BY s)`, `row_number(ORDER BY s) OVER ()`), `ORDER BY ALL`, and, under `none`, a tied subquery whose order is not compared; it refuses a `COLLATE` query | the `total` half off; a `keys` half that takes any ORDER BY, or the keys as a set; an ORDER BY taken from below the outermost query; `main()` not calling the rule; the tie check off, run one way only (ascending or descending), adding only the first output column, comparing the zero signs DuckDB rewrites, without its zero-sign rule, or comparing every case row for row or as a multiset; the tie check on the outermost ORDER BY only; the window, ordered-aggregate or inner-LIMIT perturbation off; a window function's own ORDER BY keyed by its arguments (none for `row_number`, not `lag`'s offset or default); an ordered aggregate's `COLUMNS(*)` argument left out of its keys; the rank family's own ORDER BY split, or every window's own ORDER BY exempted; a run compared by column name; a GROUP BY window keyed by the whole row or by nothing, `grouping()` left out; an output width taken from a select list holding a star; the all-at-once runs left out; the rank family's peers split; `ORDER BY ALL` given keys; the COLLATE rule off |
| `:test_connect` | on `gen_expected.connect()`'s connection: the three settings are off; a case calling inet's `html_escape` (an extension DuckDB autoloads, not in the wheel) through `run_query` is a catalog error, as is spatial's `st_area`, and the loaded and installed extension lists are unchanged; `read_text` is a permission error; `SET enable_external_access = true` is refused; every registered table is readable | any of the three settings dropped from `CONFIG` (autoload on turns the html_escape error into a failed load; external access on lets `read_text` read); a setting that blocks the oracle's own registered tables |
| `:test_render` | `render.py`'s text of a table of every flat type (a value, a NULL and a value per column) equals cells spelt by hand; float decimals equal CPython's `repr` over 3000 seeded doubles and Mojo's own float32 and float64 vectors; the header and escaped names; slices and chunks; `canon.py` refuses each malformed file it is fed and normalizes hand floats; compare under total, none and keys; every dataset renders, parses and is a fixed point | a NULL written as anything but `\N` (the empty cell is a string's value); a float without its bits, a NaN with bits, a non-shortest decimal; a wrong escape, decimal scale or temporal conversion; a parser that accepts a cell of the wrong type |
| `:test_expected` | every case has one generated file and one HAND twin; each file parses, is in canonical form, carries its `.sql`'s policy and the `GENERATED` line with the pinned versions; each equals its HAND twin under the HAND policy; each twin input equals its JSON Lines copy | an oracle answer that differs from the hand derivation (or the reverse); a float written without bits; a file whose policy drifts from its case; a twin input that drifts from the corpus's dataset |

What none of it catches: the independence check reads the oracle's declared
inputs only. A script that opens an absolute path on the worker is not
stopped ([Oracles](../../../../tools/build/python/README.md#oracles)); review
holds `gen_datasets.py` and `gen_expected.py` to reading nothing but their data directory. The two runs of one action see
the same worker, so a dependence on the worker (its time zone, its CPU
count) shows up only as a difference between workers.

What these files will turn red in komira's own readers, though the files are
right (pyarrow reads them as the tables):

- komira_csv decides NULL after stripping a cell's quotes
  (`is_null_cell` in [`string_column_simd.mojo`](../../../komira_csv/string_column_simd.mojo),
  quotes skipped in [`csv_scanner_phase1.mojo`](../../../komira_csv/csv_scanner_phase1.mojo)),
  so it reads the quoted empty string `""` as NULL, and under its default
  null strings (`""`, `NULL`, `NA`, `NaN`, `null`) also the quoted strings
  `"NULL"`, `"NaN"` and `"null"` that `types.str` holds. A CSV scan of
  `types`, `nulls` and the join pair is red on those cells until the reader
  is fixed.
- komira_jsonl materializes no binary, unsigned or timestamp column, so a
  JSON Lines scan of those `types` columns is red until it does.

The mutants each test was seen red against are in the pull request that
added it.
