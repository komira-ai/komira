# Time zone conversion

Status: proposed. Nothing in this document is built. The rule data source (section 1) waits for the owner's ruling
before slice (a) starts. Slices (b1) and (b2) need no rule data and can go first.

This design covers converting a timestamp between IANA time zones: SQL `ts AT TIME ZONE zone` and
`timezone(zone, ts)` in both directions; pandas `Series.dt.tz_localize` and `Series.dt.tz_convert`; and polars
`Expr.dt.replace_time_zone` and `Expr.dt.convert_time_zone`. It covers catalogue rank 78, "How do I convert time
zones?" ([komira-ai/komira#2342](https://github.com/komira-ai/komira/issues/2342)). It also says how the same layers
serve rank 82, Unix time ([komira-ai/komira#2344](https://github.com/komira-ai/komira/issues/2344)), and the mixing of
TIMESTAMP with TIMESTAMPTZ ([komira-ai/komira#1221](https://github.com/komira-ai/komira/issues/1221)).

The work has three layers, and no pull request mixes two of them (section 8 orders the pull requests):

1. **Rule data and a lookup.** A zone name gives a `Zone` the engine can evaluate, with no network and no host
   files at run time.
2. **A zone-aware value through the plan.** A literal, an expression result and a column can be an instant tagged
   with a zone, and every operator that reads a timestamp handles it on purpose.
3. **The conversions.** SQL `AT TIME ZONE` and `timezone()`, then the Python verbs, sit on the two layers below them.

"DuckDB" means v1.5.6, the oracle pinned by [query semantics](query_semantics.md). The oracle runs with
`TimeZone = 'UTC'` (`tools/build/sql/defs.bzl:199`).

## What exists today

Read on main with `git grep` and `git show`. Paths are relative to the repository root.

| Layer | What is there | Where |
|---|---|---|
| Rule evaluation | `src/datetime` reads TZif files (RFC 8536 versions 1 to 3, RFC 9636 version 4) into a `Zone`. It evaluates the POSIX TZ footer past the last listed transition and converts an instant to local time (`offset_at`, `local_fields`). It converts local time to an instant (`resolve`, `to_utc`), where the caller must name a gap and a fold policy: `GapPolicy.SHIFT_FORWARD`, `SHIFT_BACKWARD` or `REFUSE`, and `FoldPolicy.EARLIER`, `LATER` or `REFUSE`. Leap-second zones are refused. | `src/datetime/README.md:1-20`; `src/datetime/src/datetime/zone.mojo:15-37`, `:321` |
| Rule data | None bundled. `load_zone(dir, name)` reads a zoneinfo directory that the caller names. `parse_tzif(bytes, name)` takes bytes. Neither caches anything. | `src/datetime/BUCK:4-12`; `src/datetime/src/datetime/zoneinfo.mojo:62`; `src/datetime/src/datetime/tzif.mojo:194` |
| A pinned tz release | IANA tz 2026e as the compiled TZif tree of the PyPI `tzdata` 2026.5 sdist. The archive is fetched at build time and checked by sha256. It is test data of `//src/tests/conformance/komira_datetime_conformance` only: "no library or binary depends on this target". | `third_party/tzdata/BUCK:1-56` |
| Conformance of the rules | Six named zones have every change equal to `zdump`'s over the release. Every zone of the release loads, and every footer agrees with its file. | `src/tests/conformance/komira_datetime_conformance/BUCK:1-25` |
| Zone on a column | `Field._tz`, an IANA string. `""` means a naive timestamp. It is carried through column references, aliases, `date_trunc` and min/max, and is on the wire as `WireField.tz = 7`. The values are always UTC ticks, as in Arrow. | `src/arrow/schema.mojo:59-65`; `src/plan_expr/expr_walk.mojo:587-638`; `src/plan_proto/plan.proto:200` |
| Zone on a literal | None. `ScalarValue` has one timestamp member, `ts_micros`, with no unit and no zone, and every timestamp literal is typed `TIMESTAMP_US` with no zone. On the logical plan wire it is `WireScalar.ts_micros = 12`, also with no zone. The physical plan format writes it positionally, under a version its reader requires exactly. | `src/plan_expr/scalar_value.mojo:85-87`; `src/plan_expr/expr_walk.mojo:810-811`; `src/plan_proto/plan.proto:340`; `src/pplan_wire/pplan_wire_codec.mojo:130`, `:513`, `:546`, `:776` |
| A zone expression | None. No expression takes a zone argument (`WireExtract` has a unit and a child only). | `src/plan_proto/plan.proto:688-700` |
| Kernels | `batch_eval`, the extract and trunc kernels, sort, and join build and probe all read the int64 ticks and never the zone. So field extraction answers on the UTC wall clock, which is §6.9 of query semantics with the session zone fixed at UTC. | `src/kernels/temporal_extract.mojo:1-25`; `src/op_sort/sort_buffer_cells.mojo:139-151` (timestamps as 64-bit cells; the file has no zone code) |
| Join keys | `join_key_params_equal` requires `a.tz == b.tz`, so a `UTC` column does not join an `America/New_York` one. §6.9 says two zoned timestamps compare as instants whatever their zones. The code and the rule disagree. | `src/kernels/join_key_envelope.mojo:415-419`; `docs/design/query_semantics.md:572` |
| Readers and writers | The Parquet reader produces `"UTC"` or `""` only, from `isAdjustedToUTC`, and the writer writes `isAdjustedToUTC` for any zone, so a zone name collapses to UTC. The Arrow IPC reader and writer carry the string as it is, with no check. CSV gives naive columns. | `src/parquet/decode_helpers.mojo:507-515`; `src/parquet_writer/record_batch_schema.mojo:27`; `src/arrow_ipc/ipc_flatbuf.mojo:1895-1898` |
| SQL | `AT TIME ZONE` is refused at parse time: "SQL not supported: AT TIME ZONE. `AT` is an operator on the expression before it, ...". `timezone`, `timezone_hour` and `timezone_minute` are refused by `_R_TZFN`. A `TIMESTAMPTZ '...'` literal binds to UTC micros when it has an offset, and is refused without one ("there is no session timezone here"). `to_timestamp` and `make_timestamptz` are refused by `_R_TSMINT`, which names the missing zone-aware value. There is no `SET` and no session settings store. | `src/sql/sql_parser.mojo:1692-1703`; `src/sql/sql_fn_table.mojo:1195-1276`, `:3965-3967`; `src/sql/sql_bind_timestamp.mojo:225-240`; `src/sql/sql_fn_table.mojo:2285-2300` |
| Python | `.dt.tz`, `.dt.tz_localize` and `.dt.tz_convert` are refused with ".dt.{name} is not supported: a komira timestamp carries no time zone to convert". `.dt.floor` refuses `ambiguous=` and `nonexistent=`. The polars skin has no `expr.dt` at all. A `timestamp[us, tz=ZONE]` dtype does exist and its zone is carried through the plan. | `python/komira/_refusals.py:164-166`; `python/komira/_accessors.py:412-416`; `docs/design/dataframe_surface_verbs.md:58`; `python/komira/_ops/_dtype.py:260-274` |
| Shipping data with a program | A bundle can ship files under `share/`, which `runtime_paths` finds from the executable. The wheel ships `.py` files and `komira/_lib` only. Inside the wheel, `runtime_paths` points at the Python interpreter's prefix, not the wheel. | `tools/build/package/README.md:1-40`; `src/runtime_paths/src/runtime_paths/paths.mojo:76-109`; `python/BUCK:149-166` |

So the brief's starting point needs one correction. The engine reads no zone rule and the shipped programs carry no
rule data, but the evaluator exists, is tested against `zdump`, and has the gap and fold policies a conversion needs.
What is missing is (i) rule data that the engine and the wheel carry, plus a lookup by name; (ii) a zone-aware
literal and expression in the plan; (iii) the SQL and Python surfaces.

The Python refusal text is also stale. It says a komira timestamp carries no time zone, but a column does carry one.
And a zoned Series with a zone other than UTC (one a UDF can return, `python/tests/test_udf_types.py:640`) answers
`.dt.hour` on the UTC wall clock, where pandas answers on the zone's wall clock. Slice (d1) fixes both.

## 1. Where the rules come from

The answer must be the same on every host, with no network at run time and no environment variable (rule S2). The
same SQL must give the same answer on Linux and macOS, in the wheel, in a bundle and on a worker.

### Options

| | A: the pinned release compiled into a library | B: the pinned release shipped as files | C: the host's zoneinfo |
|---|---|---|---|
| Where the bytes are | a generated Mojo library (`src/tzdb`), one hex literal per distinct TZif file, committed with a freshness gate | `share/tzdata/` in a bundle and `komira/_tzdata/` in the wheel | `/usr/share/zoneinfo` or wherever the host keeps it |
| Same answer on every host | yes: the bytes are part of the library | yes, if every deployment carries the tree | no: each distribution and each macOS release ships its own tz release, and slim container images ship none |
| Run-time path | none | the wheel has to pass a path into libkomira (a new C ABI entry point or session option: a public interface change); a bundle uses `runtime_paths` | needs a host path, which unit tests may not read (rule T12) |
| Failure mode | none at run time | a missing or partial tree makes every zone unknown, at run time | a missing zone or a different rule, silently |
| Refresh | bump `third_party/tzdata`, regenerate, review the diff | bump and rebuild | none possible |
| Size | about 207 KB of data in the library (measured, below); about 0.45 MB of committed generated source | about 350 KB of files per install | 0 |
| Tests | hermetic: the table is in the library under test | the tree is staged as test data | not hermetic |

**Recommendation: A.** It is the only option with no run-time failure mode and no new public interface, and it
keeps the bundle, the wheel and the workers equal by construction. It follows the committed generated-source
mechanism ([generated sources](generated_sources.md), option A there: committed output, a `_fresh` gate, `_parts/`
under the 1000-line limit, `# @generated` files outside coverage). It also follows the hex-literal spelling of
`src/crypto/src/crypto/cert/root_store_data.mojo`, whose header measures that spelling against one statement per
byte. B is the fallback if the owner rules the committed bytes too large. C is rejected: an answer that depends on
the host is not the oracle's answer.

**Owner's ruling needed before slice (a): A or B.**

### Size, measured

Measured on the pinned archive (`tzdata-2026.5.tar.gz`, 200,404 bytes, sha256 equal to `third_party/tzdata/BUCK:29`),
extracted and counted with `find`, `stat` and `sha256sum`:

- 598 zone names (`src/tzdata/zones`), one TZif file each. The 598 files total 349,825 bytes.
- 345 distinct files, totalling 206,817 bytes. The other names are backward links whose files are byte-identical
  copies. The table stores each distinct file once, plus a name-to-file index.
- New York's file is 1,744 bytes, London's 1,599 and UTC's 111. zic writes the "slim" form: the version 1 block is
  empty, and the footer string carries the rules after the last listed transition (`third_party/tzdata/BUCK:12-14`).

Hex doubles the 206,817 bytes in source, so the generated parts hold about 414 KB of hex plus the index, split into
files under 1000 lines. That size is inferred from the byte count, not measured.

### Pinning, refreshing, licence

- **Pin.** The table is generated from `//third_party/tzdata:files`, the existing pin. The generated header names
  the tz release (`2026e`), the archive's sha256, and each input's sha256, as the header rules require
  ([protobuf, gRPC and codegen](protobuf_grpc_and_codegen.md)). `third_party/tzdata` stops being test-only: its
  visibility grows to the generator.
- **Refresh.** This is the procedure in `third_party/tzdata/BUCK:23-26`, plus regenerating the table and the SQL
  corpus answers (section 5). The refresh is one pull request, and its diff is the changed zones' bytes.
- **Generator.** A Zig tool under `tools/build` (rule B7) that reads the extracted tree and writes `generated/tzdb/`,
  with Zig tests: one name per file, links stored once, and a name missing from the tree failing loudly.
- **Licence.** The tz data is in the public domain. The PyPI package around it is Apache-2.0
  (`third_party/tzdata/BUCK:11-12`). The bytes come from that package's tree, so the wheel's licence audit
  ([wheel licence audit](wheel_licence_audit.md)) gains its Apache-2.0 notice.
- **Linux and macOS.** One table, one parser and no host input, so the answers are equal on both. The macOS part of
  the check builds the library's welded tests like any other.

### The lookup (slice (a))

A new library `src/tzdb` depends on `//src/datetime:datetime` and the generated table. Its public Mojo API is the
four functions below, each with a README example (rule T18). Each has a named user:

- `zone(name: String) raises -> Zone`: an exact match on a tz name. Otherwise it raises
  `unknown time zone "<name>": the tz release 2026e has no zone of that name`. A link answers its target's rules
  under the name asked for. No cache: a caller that converts many rows keeps the `Zone`. Used by the engine's zone
  resolution (slice (c1)) for every zone in a plan, `"UTC"` included.
- `fixed_offset_zone(text: String) raises -> Zone`: Arrow's `+HH:MM` / `-HH:MM` zone form (Arrow's `Schema.fbs`
  names it next to IANA names), built with `posix_zone`. Its one use is a column whose own zone is in that form
  (an Arrow IPC file, or a UDF result such as `python/tests/test_udf_types.py:640`'s `+05:30`), when a Python door
  reads that column's wall clock (section 4). No door accepts it as a verb or SQL argument.
- `canonical_name(name: String) -> Optional[String]`: the case-insensitive match that DuckDB v1.5.6 does
  (`extension/icu/icu_extension.cpp:300-332` at v1.5.6). The SQL binder uses it; the Python doors do not, since
  pandas and polars match exactly.
- `release() -> String`: `"2026e"`, which the unknown-zone messages above and in section 3 name.

`Zone.resolve` builds `List`s on every call (`zone.mojo:278-295`). The conversion kernel calls it once per row, so
slice (a) adds a resolve that allocates nothing. It returns the kind, both candidate instants and, for a gap, the
transition instant, which pandas' `shift_forward` needs (section 4). A test holds it equal to `Zone.resolve` around
every transition of the six named zones' goldens.

## 2. The zone-aware value in the plan

### The type

A zoned timestamp is an Arrow timestamp whose `Field._tz` is not empty: an instant stored as UTC ticks in its unit,
with the zone as metadata, as Arrow defines it ("its epoch is ... in the UTC timezone, regardless of the
Timestamp's own timezone", `format/Schema.fbs`). This is what komira already carries. There is no new type id.
SQL's TIMESTAMPTZ is a zoned timestamp. The SQL door tags every TIMESTAMPTZ it makes with `"UTC"`, its session
zone (section 3).

### The literal

`ScalarValue` gains `ts_tz: String`, empty for a naive timestamp. `WireScalar` gains `string ts_tz = <next free
number>`, optional. Typing a timestamp literal (`expr_walk.mojo:810-811`) declares `TIMESTAMP_US` with that zone. An
old plan has no `ts_tz` and decodes as naive, which is what its producer meant. The physical plan format
(`src/pplan_wire`) writes the scalar positionally and reads exactly one version (`pplan_wire_codec.mojo:130`,
`:776`). It gains `ts_tz` at the end of the scalar under version 3, and its reader keeps reading version 2 as naive.
A `TIMESTAMPTZ '...+02'` literal becomes a zoned literal tagged `"UTC"`, instead of a naive literal holding UTC
micros.

Every reader of `ts_micros` keeps reading the same ticks. Slice (b1) takes each of them through a zoned literal and
names a test for it:

- the literal arms of `batch_eval`: `predicate_compare`, `literal_arm_domain`, `eval_in_list` (IN lists) and
  `temporal_literal_value`;
- `dispatch_project/lower_untyped_expr_ops.mojo` and `column_kernels/compiler_helpers.mojo`;
- the pruning by bounds in `iceberg_scan/prune.mojo` and `search/source.mojo`, where a zoned literal against a zoned
  column's statistics compares ticks, as a naive one does today.

A zoned literal against a zoned column compares instants. A zoned literal against a naive column is a §6.11 mix.

Retyping the SQL literal changes what some queries do today. `naive_col > TIMESTAMPTZ '...+00'` answers today (the
literal is naive). Once the literal is zoned, it is a §6.11 mix, which is refused until komira-ai/komira#1221 is
served. So the literal's new type lands in the same slice as #1221's conversion (b2), and no query that answers
today starts refusing. Slice (b2) holds itself to that claim with the corpus cases over zoned columns that answer
today (`cases/cross_timestamp_us_utc` and every other case with a TIMESTAMPTZ literal), which must stay green. It
also covers these other SQL readers of a TIMESTAMPTZ:

- **Explicit casts.** DuckDB's ICU extension casts TIMESTAMP (and `_S`, `_MS`, `_NS`, DATE) to TIMESTAMPTZ and back
  through the session zone (`extension/icu/icu-timezone.cpp:197-201`, `:296-299` at v1.5.6). At UTC that is a
  localize or a to-local in `"UTC"`, so `CAST(x AS TIMESTAMPTZ)` and `CAST(tstz AS TIMESTAMP)` lower to
  `EXPR_ZONE_CONVERT`. The binder refuses every timestamp cast target today (`src/sql/sql_bind_timestamp.mojo:24-100`).
- **Interval arithmetic.** A TIMESTAMPTZ plus an INTERVAL is calendar arithmetic in the session zone. At UTC it is
  the naive arithmetic on the same ticks, so an expression that adds an interval to a literal keeps answering once
  the literal is zoned.
- **`typeof`.** It already names a TIMESTAMPTZ literal `TIMESTAMP WITH TIME ZONE` (`src/sql/sql_bind_names.mojo:265-269`).
- **Rendering.** §6.10 renders a zoned timestamp with the session offset, `+00`. No timestamp rendering kernel exists
  yet (§6.10, "Current behaviour"); the one that comes appends `+00` to a zoned value.
- **`date_diff` and `date_sub` of a TIMESTAMPTZ** stay refused by name (`src/sql/sql_bind_fn_nested.mojo:288-366`).
  Their own issue serves them.

### The expression

There is one new expression kind, `EXPR_ZONE_CONVERT`, with a new wire message:

```text
WireZoneConvert {
  WireExpr child = 1;
  string zone = 2;        // the zone the wall clock is read or written in; "" only for a retag
  string result_tz = 3;   // the result's Field._tz; "" for a naive result
  ZoneGapPolicy gap = 4;  // used by a localize only
  ZoneFoldPolicy fold = 5;
}
```

Its child's type and `result_tz` pick one of three shapes. Each conversion has exactly one spelling:

| child | `result_tz` | meaning | result |
|---|---|---|---|
| naive | non-empty | **localize**: read the child as a wall clock in `zone`, and settle a gap or a fold by the policies | the instant, tagged `result_tz`, in the child's unit |
| zoned | empty | **to local**: the wall clock in `zone` that shows the child's instant | naive, in the child's unit |
| zoned | non-empty, with `zone` empty | **retag**: the same instant under another zone tag | the child's ticks unchanged, tagged `result_tz` |

Every other combination is refused when the plan is checked, and each has a test: a naive child with an empty
`result_tz` (nothing to convert); a zoned child with both `zone` and `result_tz` non-empty; a zoned child with both
empty; and a retag or to-local whose gap or fold policy is not the default `GAP_ERROR`/`FOLD_ERROR`, since neither
reads a policy. `zone` always names the zone whose wall clock is read or written. For pandas
`tz_localize(None)` that is the column's own zone, which the door copies from the dtype.

The policies are plan vocabulary. Each value exists because a door uses it (section 3 and section 4):

- `ZoneGapPolicy`: `GAP_ERROR`; `GAP_NULL`; `GAP_OFFSET_BEFORE` (read in the offset before the gap: DuckDB, and
  `datetime`'s `SHIFT_FORWARD`); `GAP_TRANSITION` (the transition instant: pandas `shift_forward`);
  `GAP_BEFORE_TRANSITION` (the transition minus one tick of the child's unit: pandas `shift_backward`).
- `ZoneFoldPolicy`: `FOLD_ERROR`, `FOLD_NULL`, `FOLD_EARLIER` and `FOLD_LATER` (the later one is DuckDB's).

`zone` is a constant string in the plan. A zone that varies by row is out of scope; it can come later as an
additive optional child.

Zone names are resolved by the engine, once per expression, when lowering binds the expression to its kernel
(`src/lowering`, before any row is read). The codec checks only the shape. An unknown name is refused at lowering,
by name. The job manager never resolves a zone: it does not decode the plan body (rule B21). The kernels'
library, `batch_eval`, gains the BUCK dependency on `//src/tzdb`. So does the SQL binder, which refuses an unknown
name at bind, before a plan exists.

`"UTC"` needs no rule data (`datetime.utc_zone()`). So slice (b1) serves the three shapes for `"UTC"` alone and
refuses any other zone by name ("is not served yet"). Slice (c1) replaces that path with `tzdb.zone`, `"UTC"`
included, so there is one way to get a zone. Retagging and localizing in `"UTC"` are the whole of what #1221 and
`to_timestamp` need (section 6), so they need no rule data.

### Through the engine

- **Binder and typing.** `walk_expr_field` gains the `EXPR_ZONE_CONVERT` arm, which declares the table above. The
  existing arms keep carrying `_tz` as they do now (column reference, alias, `date_trunc`, min/max).
- **batch_eval.** There is one kernel per shape, over every timestamp unit. Localize splits each tick count into
  whole seconds and a sub-second rest (floor division, so instants before the Unix epoch are right), resolves the
  seconds in the zone (offsets are whole seconds), and adds the rest back. To local adds `offset_at` to the seconds.
  Retag copies the ticks. NULL in gives NULL out, and a policy of `*_NULL` sets the validity bit. A result outside
  int64 is an error that names the zone and the value. The `*_ERROR` policies raise `datetime`'s messages: "zone
  America/New_York: local time 2027-03-14T02:30:00 does not exist (the clock skipped it)" and "... is ambiguous (the
  clock showed it twice)" (`zone.mojo:332-344`).
- **Extract and `date_trunc`.** These are unchanged: they read the UTC wall clock. A door that wants a zone's wall
  clock (pandas and polars, section 4) puts a to-local in front of them. The plan has one meaning, and the doors
  compose it.
- **Comparison, joins, sort, group keys and DISTINCT.** A zoned timestamp is its ticks, and two zoned timestamps
  compare as instants whatever their zones (§6.9). Slice (b1) changes `join_key_params_equal` to treat any two
  non-empty zones as equal for the timestamp family. A naive key against a zoned key stays refused (§6.11) unless
  the frontend converted one side. Sort and DISTINCT already order and compare the 64-bit ticks. The hash aggregate's
  refusal of a timestamp column in a multi-column key (`docs/design/lowering_and_pipeline.md:587`) does not depend
  on the zone. When it is lifted, the key is the ticks and the output field keeps the input's zone. UNION branches
  that differ only in zone: the SQL door has tagged both `"UTC"`. A plan built by a Python door with two different
  zones is refused at the union as today (`src/lowering/cut_union.mojo:78`).
- **Readers and writers.** These are unchanged. Arrow IPC already round-trips any zone string. Parquet writes only
  `isAdjustedToUTC`, so a frame converted to `America/New_York` reads back from Parquet as `UTC`: the same instants,
  under Parquet's only zone. The page for rank 78 says so.

### Compatibility (rule B8)

Everything is additive: one expression kind, one message, two policy enums, one optional `WireScalar` field, and
the scalar's `ts_tz` in a new physical plan version whose reader still reads the old one. Nothing is renumbered or
re-meant.

- **An old plan on the new engine.** No `ts_tz` means naive and no `EXPR_ZONE_CONVERT` appears, so every plan a
  released producer emitted decodes and runs as before. A version 2 physical plan reads as before.
- **A new plan on an old engine.** The old decoder refuses an unknown expression kind by name: it cannot run the
  expression, and it does not drop it. An old engine ignores `ts_tz` and reads a zoned literal as naive: the same
  ticks, so the same comparisons. An old physical plan reader refuses version 3 by name, as it refuses every
  version but its own.
- **Tests.** Slice (b1) names a test that decodes a plan written by the last release's producer (committed plan
  goldens) on the new engine, and one that decodes a new plan with the last release's decoder. It names the same
  pair for the physical plan format.

## 3. SQL semantics (DuckDB)

### Measured

Measured with the DuckDB CLI on this host, v1.1.3, under `SET TimeZone = 'UTC'`. **This is not the pinned v1.5.6.**
Slice (c2) commits the same rows as corpus cases, and the `sql_oracle` action reads them again on v1.5.6, so these
values are a plan, not the authority. v1.5.6's source sets no wall-time option on the ICU calendar
(`extension/icu/icu-timezone.cpp:106-139` at v1.5.6 has no `setRepeatedWallTimeOption` or
`setSkippedWallTimeOption`), so it uses ICU's defaults, which are the rule these rows show.

| zone | `TIMESTAMP` (local) | `AT TIME ZONE` gives (UTC) | what happened |
|---|---|---|---|
| America/New_York | 2027-03-14 01:59:59 | 2027-03-14 06:59:59+00 | last second before the gap, EST |
| America/New_York | 2027-03-14 02:00:00 | 2027-03-14 07:00:00+00 | gap start: read in EST, shows 03:00 EDT |
| America/New_York | 2027-03-14 02:30:00 | 2027-03-14 07:30:00+00 | inside the gap: read in EST, shows 03:30 EDT |
| America/New_York | 2027-03-14 03:00:00 | 2027-03-14 07:00:00+00 | first time after the gap |
| America/New_York | 2026-11-01 00:59:59 | 2026-11-01 04:59:59+00 | before the fold, EDT |
| America/New_York | 2026-11-01 01:30:00 | 2026-11-01 06:30:00+00 | inside the fold: the later instant (EST) |
| America/New_York | 2026-11-01 02:00:00 | 2026-11-01 07:00:00+00 | after the fold |
| Europe/London | 2027-03-28 01:30:00 | 2027-03-28 01:30:00+00 | gap: read in GMT |
| Europe/London | 2026-10-25 01:30:00 | 2026-10-25 01:30:00+00 | fold: the later instant (GMT) |
| Australia/Sydney | 2026-10-04 02:30:00 | 2026-10-03 16:30:00+00 | gap: read in AEST |
| Australia/Sydney | 2027-04-04 02:30:00 | 2027-04-03 16:30:00+00 | fold: the later instant (AEST) |
| Australia/Lord_Howe | 2026-10-04 02:15:00 | 2026-10-03 15:45:00+00 | 30-minute gap: read in +10:30 |
| Australia/Lord_Howe | 2027-04-04 01:45:00 | 2027-04-03 15:15:00+00 | 30-minute fold: the later instant (+10:30) |
| Asia/Kathmandu | 2026-12-01 00:00:00 | 2026-11-30 18:15:00+00 | +05:45 |

`timezone(zone, ts)` gave the same value as `ts AT TIME ZONE zone` on every row. In the other direction, a
TIMESTAMPTZ `AT TIME ZONE` gives a TIMESTAMP. For example, 2026-11-01 05:30:00+00 and 06:30:00+00 both give
2026-11-01 01:30:00 in New York: a fold maps two instants to one wall clock. 2027-03-14 07:00:00+00 gives 03:00:00.
`SELECT TIMESTAMP '2026-12-01 12:00:00' AT TIME ZONE 'Mars/Olympus'` failed with
`Not implemented Error: Unknown TimeZone 'Mars/Olympus'`. v1.5.6 adds a "!" and a list of candidate zones
(`icu_extension.cpp:339-354` at v1.5.6).

### The rules komira follows

- **`ts AT TIME ZONE zone` is `timezone(zone, ts)`.** DuckDB documents `AT TIME ZONE` as "syntactic sugar for the
  (two argument) `timezone` function" (DuckDB documentation, "Timestamp with time zone functions"). The parser gains
  `AT TIME ZONE` as a postfix operator with PostgreSQL's precedence, whose grammar DuckDB's parser uses: above the
  binary arithmetic and comparison operators, below unary minus and `::`. It desugars to the `timezone` call.
- **TIMESTAMP to TIMESTAMPTZ** (`timezone(zone, <TIMESTAMP>)`): a localize with `GAP_OFFSET_BEFORE` and `FOLD_LATER`,
  `result_tz = "UTC"`. `GAP_OFFSET_BEFORE` is `datetime`'s `SHIFT_FORWARD` and `FOLD_LATER` its `LATER`. Every row
  above follows that pair.
- **TIMESTAMPTZ to TIMESTAMP** (`timezone(zone, <TIMESTAMPTZ>)`): a to-local. A zoned column of any zone is a
  TIMESTAMPTZ here, as in DuckDB, where the type has no zone.
- **Units.** DuckDB's TIMESTAMPTZ is microseconds. A `TIMESTAMP_S`, `_MS` or `_NS` argument is cast to microseconds
  first, by the §6.8 rule (DuckDB truncates a nanosecond input: measured on v1.1.3, `.123456789` gives `.123456`).
- **NULL.** A NULL `ts` gives NULL. A NULL zone constant gives a NULL column of the result type, as DuckDB returns
  constant NULL (`icu-timezone.cpp:458-461` at v1.5.6).
- **Unknown zone: refused by name at bind**, before the plan is built: `SQL not supported: unknown time zone
  'Mars/Olympus': the tz release 2026e has no zone of that name`. DuckDB's message differs in wording; the rule is
  that a name DuckDB does not know is refused, never read as UTC. A test asserts the full text.
- **Names.** `tzdb.canonical_name` matches case-insensitively, as v1.5.6 does. v1.5.6 also maps `UTC+H` and `UTC-H`
  to `Etc/GMT-H` and `Etc/GMT+H`, with the sign inverted (`icu_extension.cpp:218-297` at v1.5.6). Read from that
  source, not run: it keeps only the hours of `UTC+05:30` and `UTC+0530`, mapping both to `Etc/GMT-5`. komira's binder
  does the same mapping, the dropped minutes included, because the rule is DuckDB's answer. Slice (c2) commits
  corpus cases for whole hours, a colon form, a four-digit form and a lower-case name, so the oracle's v1.5.6 answer
  is the one held. The numeric zones that DuckDB refuses (`'+05:30'`, `'0200'`) are refused too: Arrow's `+HH:MM`
  form is for column zones, not this door.
- **Names that ICU has and the tz release lacks.** On v1.1.3, `pg_timezone_names()` lists 40 names outside the 598
  of tz 2026e: the three-letter IDs ICU keeps for Java (`PST`, `IST`, `CST`, ...) and `SystemV/*`, among others.
  Measured by `comm` of the two sorted lists; slice (c2) measures v1.5.6's list. They are refused by name: `unknown
  time zone 'PST': ...`. One name, `America/Coyhaique`, is in tz 2026e and not in v1.1.3's ICU.
- **Rule data drift.** komira answers from tz 2026e, and DuckDB from the tz data in its ICU build. Where the two
  disagree for a date, the answers differ, and no code can close that gap. Corpus cases use zones and dates where
  both agree; a refresh that makes them disagree fails the `sql_oracle` check of the refreshed case, and the case
  moves. Query semantics records this as the one known departure of the section. It is not an Arrow representation
  limit, so it is the owner's to accept (rule B21).
- **The session `TimeZone`.** It is fixed at UTC, the oracle's setting (§6.9). `SET TimeZone` is not parsed
  (no `SET` statement, `sql_parser.mojo:145-170`) and `current_setting` is refused (`_R_SESSION`). Under UTC, a
  TIMESTAMPTZ literal with no offset reads its digits as UTC, as DuckDB does with `TimeZone = 'UTC'`. So the refusal
  `TIMESTAMPTZ '<text>' WITHOUT A UTC OFFSET` (`sql_bind_timestamp.mojo:380-387`) is lifted in slice (b2): the literal
  is localized in `"UTC"` at bind time.
- **`timezone(ts)`, `timezone_hour(ts)`, `timezone_minute(ts)`** with one argument, and as `date_part` specifiers:
  the UTC offset in the session zone, which is always 0 under UTC. They answer BIGINT 0 for a TIMESTAMPTZ. For a
  TIMESTAMP they answer what the oracle measures (the `_R_TZFN` text records 0 on v1.5.3). Slice (c2) takes them
  out of `_R_TZFN` with the rest.

## 4. Python surface

The verbs are those of the pinned pandas 3.0.6 and polars 1.44.2 ([DataFrame surface](dataframe_surface.md)). There
are no others. Each maps onto `EXPR_ZONE_CONVERT`:

| verb | input | plan | refused, by name |
|---|---|---|---|
| pandas `s.dt.tz_localize(tz, ambiguous="raise", nonexistent="raise")` | naive | localize in `tz`, `result_tz = tz` | `ambiguous="infer"` and a bool array; `nonexistent=<timedelta>`. A zoned input with `tz` not None raises pandas' `TypeError` |
| pandas `s.dt.tz_localize(None)` | zoned | to local in the column's zone | |
| pandas `s.dt.tz_convert(tz)` | zoned | retag to `tz` | a naive input raises pandas' `TypeError` |
| pandas `s.dt.tz_convert(None)` | zoned | to local in `"UTC"` | |
| polars `e.dt.replace_time_zone(tz, *, ambiguous="raise", non_existent="raise")` | naive | localize in `tz` | `ambiguous=<Expr>` |
| polars `e.dt.replace_time_zone(tz, ...)` | zoned | to local in the column's zone, then localize in `tz` | |
| polars `e.dt.replace_time_zone(None)` | zoned | to local in the column's zone | |
| polars `e.dt.convert_time_zone(tz)` | zoned | retag to `tz` | |
| polars `e.dt.convert_time_zone(tz)` | naive | localize in `"UTC"` with `result_tz = tz`: polars converts a naive column "as if converting from UTC" (polars documentation; `crates/polars-expr/src/dispatch/temporal.rs` at `py-1.44.2` sets the zone on any Datetime) | |

The arguments map onto the policies:

| pandas | polars | policy |
|---|---|---|
| `ambiguous="raise"` | `ambiguous="raise"` | `FOLD_ERROR` |
| `ambiguous="NaT"` | `ambiguous="null"` | `FOLD_NULL` |
| | `ambiguous="earliest"` / `"latest"` | `FOLD_EARLIER` / `FOLD_LATER` |
| `nonexistent="raise"` | `non_existent="raise"` | `GAP_ERROR` |
| `nonexistent="NaT"` | `non_existent="null"` | `GAP_NULL` |
| `nonexistent="shift_forward"` | | `GAP_TRANSITION` |
| `nonexistent="shift_backward"` | | `GAP_BEFORE_TRANSITION` |

pandas documents `shift_forward` as shifting "the nonexistent time forward to the closest existing time". Its own
example localizes 02:30 in a 02:00 to 03:00 gap to 03:00:00, and `shift_backward` to 01:59:59.999999999 in
nanoseconds (pandas documentation, `Series.dt.tz_localize`). That is the transition instant, not DuckDB's 03:30, so
the two are separate policies. pandas has no spelling for DuckDB's choice, and polars has no shift at all.

In both skins, a zone passed to a verb must match a tz name exactly. A name the tz release lacks raises
`UnsupportedOperation` naming it, at the call, before anything runs (§6 of the DataFrame surface). A column's own zone
may also be Arrow's `+HH:MM` form. When a verb or a field reads that column's wall clock, the engine resolves it
with `tzdb.fixed_offset_zone`.

Two things change along with the verbs:

- **Fields of a zoned Series.** In pandas and polars, `.dt.hour`, `.dt.day` and the other fields, and `.dt.floor`,
  read the column's own zone's wall clock. So on a zoned column whose zone is not `"UTC"`, the doors lower them as a
  to-local in that zone, then the extract. `.dt.floor` then localizes the floored wall clock back with its
  `ambiguous=` and `nonexistent=` mapped as above. That removes the `.dt.floor` refusal at
  `python/komira/_accessors.py:412-416`. On a `"UTC"` column the plan is unchanged.
- **Refusal rows.** The `("tz", "tz_localize", "tz_convert")` row of `python/komira/_refusals.py:164-166` goes.
  `.dt.tz` stays refused, with a true message: pandas returns a `tzinfo` object, which would need zone rules on the
  Python side, and the dtype string already names the zone.

The polars skin has no `expr.dt` namespace today (`docs/design/dataframe_surface_verbs.md:58`). Slice (d2) adds it
with these two verbs and the fields that the pandas skin already has. Every other polars `dt` name raises Python's
`AttributeError`, as section 5 of the DataFrame surface requires.

A zoned result that reaches Python as a pyarrow timestamp with an IANA zone needs zone rules on the Python side to
become `datetime` objects with a `tzinfo`. That is pyarrow's work: komira hands over the Arrow column. The task page
says so, and its example prints naive wall clocks (section 6).

## 5. Testing without a service

Every test is hermetic: the rules are in the library or staged as test data, and no host zoneinfo is read (rule T12).
The golden values are read off the pinned oracles: DuckDB v1.5.6 through `sql_oracle`, pandas 3.0.6 and polars 1.44.2
in the hermetic venv. None is hand-copied from komira's own output.

- **(a) `tzdb`.** The table's 598 names equal the extracted `src/tzdata/zones`. Each name's bytes equal the
  extracted file, compared byte for byte in `komira_datetime_conformance`, which already stages the tree. A link
  answers its target's rules. The non-allocating resolve equals `Zone.resolve` at, one second before and one second
  after every transition in `goldens/named.txt`. Unknown names, case-folded names and Arrow fixed-offset names are
  tested, and each refusal is asserted by its full text.
- **(b1) The plan.** Mojo tests of both codecs: `ts_tz` and `WireZoneConvert` round-trip; an old plan decodes as
  before; the last release's decoder on a new plan, as named in section 2. The kernels in `"UTC"` cover each unit,
  instants before the Unix epoch with a sub-second part, NULLs, int64 overflow, and each plan-check refusal of
  section 2's shapes. Each reader of `ts_micros` listed in section 2 has a zoned-literal test. For joins, a `"UTC"`
  key joins an `"America/New_York"` key on instants, and a naive key against a zoned one is refused.
- **(b2) SQL types.** Corpus cases for the §6.11 mixes (comparison, join, CASE, UNION), the casts both ways, a
  TIMESTAMPTZ literal with and without an offset, and a TIMESTAMPTZ plus an INTERVAL. Every existing case with a
  TIMESTAMPTZ literal or column stays green.
- **(c1) Zone resolution.** Lowering resolves a known zone, refuses an unknown one by its full text, and resolves a
  column's `+05:30` zone; the kernels give the policy test's values below.
- **(c2) SQL.** A new corpus `time_zones` in `src/tests/conformance/komira_sql_conformance`, whose answers the pinned
  DuckDB writes and holds byte for byte (`sql_oracle`). It has the table above as cases in both directions, with the
  zones New York, London, Sydney, Lord Howe (a 30-minute change), Kathmandu (+05:45) and UTC. At each change there is
  a case one second before it, at it, inside it, at its end and one second after it. There are also NULL `ts`, NULL
  zone, a zone column refused by name, the units `_S`, `_MS` and `_NS`, case-folded names, and `UTC+3`,
  `UTC+05:30` and `UTC+0530`. komira is held
  to the same answers by the corpus runners (README, "Runners") and by a Mojo runner, as `sdk_exec` does for
  `order_by_limit`. The unknown-zone refusal is a `src/sql` test asserting the full text.
- **A test that fails on a wrong gap or fold rule.** A Mojo kernel test applies every policy to New York's 02:30 gap
  and its 01:30 fold. The expected instants are worked out from the zone's offsets, not from engine code:
  `GAP_OFFSET_BEFORE` 07:30Z, `GAP_TRANSITION` 07:00Z, `GAP_BEFORE_TRANSITION` one tick before 07:00Z, `FOLD_EARLIER`
  05:30Z and `FOLD_LATER` 06:30Z. The `*_NULL` policies give NULL, and the `*_ERROR` policies raise their full
  message. Each policy has a different expected value at one of these rows, so a swapped policy or a swapped offset
  fails a row. The corpus holds the SQL door to DuckDB's pair on the same rows.
- **(d1, d2) Python.** Plan tests (`python/tests/plan`) assert the node each verb builds and every refusal's full text.
  Run tests (`python/tests/run`, and `python/tests/pl_oracle` for polars) compare komira with the pinned pandas and
  polars on the same rows, both directions and every argument value in section 4. pandas and polars read zones
  through Python's `zoneinfo`, so those tests take the PyPI `tzdata` 2026.5 wheel as a test-only pin: the same release
  as `third_party/tzdata`, so both oracles read the same rules.
- **(e) The task.** `python/docs/tasks/78-convert-time-zones/` holds `example.py`, `expected_output.txt` and
  `page.md` with the `<!-- include example.py -->` and `<!-- include expected_output.txt -->` markers. Its target
  `//python/docs/tasks:78-convert-time-zones` runs the example in the hermetic venv and compares the output byte for
  byte, and `//python/docs/tasks:pages` checks the page and the catalogue. That is the one way task examples are shown
  and tested ([documentation tests](documentation_tests.md)). There is no second runner.

The failure and boundary cases listed cover each way a conversion can go wrong: the three local-time kinds (unique,
gap, fold); each policy; changes that are not one hour (Lord Howe) and offsets that are not whole hours (Kathmandu);
both hemispheres; NULL in each argument; each unit; instants before the Unix epoch; int64 overflow; unknown,
case-folded and offset names; and the plan-version pairs.

## 6. The catalogue

- **Rank 78, "How do I convert time zones?"** This is a gap today, with no directory under `python/docs/tasks`.
  Slice (e) adds the directory and the page, and sets the status in `docs/tasks/catalogue.json` in the same change.
  `tasks-check` refuses a directory named after a gap entry (`docs/tasks/README.md:71-73`). The status becomes
  `works` once SQL and pandas are served. If a form stays refused when (e) lands (for example the polars verbs), the
  status is `partial` with a probe, `probe_<name>.py` and its one-line `.error.txt`, for that form. The same change
  fixes the "(rank 78, gap; no page yet)" line of `python/docs/tasks/79-add-days-date-take-difference-dates/page.md:57`.
  The example writes its own input and converts both ways in SQL and in pandas. It prints only naive wall clocks (a
  to-local result), so its output does not depend on the venv having zone rules.
- **Rank 82, Unix time (komira-ai/komira#2344).** `to_timestamp(seconds)` returns TIMESTAMPTZ in DuckDB, which is the
  missing value `_R_TSMINT` names. After slice (b1), `to_timestamp(x)` is the existing tick relabel (`make_timestamp`'s
  route, `sql_bind_timestamp.mojo:99-129`) followed by a localize in `"UTC"`, plus DuckDB's rounding of a DOUBLE,
  which the #2344 work measures. `epoch(tstz)` and `epoch_ms(tstz)` read a zoned operand's ticks like a naive one's.
  None of them needs rule data. **Slice (b1) unblocks `to_timestamp`.** Rank 82's page and probe change with #2344,
  not here.
- **komira-ai/komira#1221, mixing TIMESTAMP and TIMESTAMPTZ.** With the session zone fixed at UTC, DuckDB's implicit
  conversion is a localize or a to-local in `"UTC"`. The binder inserts it on the naive side of a comparison, join,
  CASE or UNION, which lifts the §6.11 refusal. Slice (b2) does this together with the zoned literal, so §6.11's mark
  moves from PARITY GAP to MATCHES there.

## 7. Out of scope

- **A session `TimeZone` other than UTC, and `SET TimeZone`.** komira has no session settings store (`_R_SESSION`),
  the oracle runs at UTC, and a session zone would change the extraction, truncation, rendering and interval
  arithmetic of every TIMESTAMPTZ. That is its own design. Under it, TIMESTAMPTZ plus INTERVAL is the naive
  arithmetic on the same ticks (slice (b2)); calendar arithmetic in another zone waits for that design.
- **A zone that varies by row** (`ts AT TIME ZONE zone_col`). It is refused by name at bind. An additive optional
  child of `WireZoneConvert` can serve it later.
- **TIME WITH TIME ZONE.** The plan has no such type. DuckDB's third `timezone` overload stays refused by name.
- **Names that ICU has and tz lacks, abbreviations, and numeric zones in SQL.** These are refused by name (section 3).
  An alias table copied from ICU would be a second source of rules.
- **Leap seconds.** `datetime` refuses zones with leap-second records. Instants are POSIX seconds, as in DuckDB.
- **Infinite timestamps.** They are already an Arrow representation departure. DuckDB passes infinity through
  `AT TIME ZONE` unchanged; komira has no infinite timestamp to pass.
- **pandas `ambiguous="infer"`, a bool array, `nonexistent=<timedelta>`, and `.dt.tz` as a `tzinfo`.** The first
  three need a pass across rows or per-row arguments; the last needs zone rules in Python. All are refused by name.
- **Rule data from the host or from an environment variable** (`TZDIR`, `TZ`). See section 1 and rule S2.
- **Updating rules without a release.** Rules change only with a pin change, so a plan run twice gives one answer.
- **Writing zone names to Parquet.** Parquet has only `isAdjustedToUTC`. Arrow IPC already keeps the name.

## 8. Slices

Each slice is one pull request that a session can take cold. (a) does not depend on (b1) or (b2), so it can wait
for the owner's ruling while they land.

1. **(a) Rule data and the lookup.** Waits for the owner's ruling (A or B, section 1). It adds the Zig generator with
   its tests, `generated/tzdb/` with its `_fresh` gate, `src/tzdb` (`zone`, `fixed_offset_zone`, `canonical_name`,
   `release`, the non-allocating resolve), its README examples and tests (section 5 (a)), the `third_party/tzdata`
   visibility change, and the wheel licence notice. Library code only: no plan, SQL or Python change.
2. **(b1) The zone-aware value through the plan.** `ScalarValue.ts_tz`, `WireScalar.ts_tz` and the physical plan
   version 3; `EXPR_ZONE_CONVERT`, `WireZoneConvert` and the two policy enums; the typing arm; the three kernels for
   `"UTC"` (every other zone refused by name); every reader of `ts_micros` in section 2; the join key rule. Needs no
   rule data and changes no SQL or Python surface. **This slice unblocks `to_timestamp`** (komira-ai/komira#2344).
3. **(b2) TIMESTAMPTZ in SQL.** Needs (b1). The zoned TIMESTAMPTZ literal with and without an offset; the §6.11
   conversion of komira-ai/komira#1221; `CAST` to and from TIMESTAMPTZ; interval arithmetic on a TIMESTAMPTZ; and
   query semantics §6.9 and §6.11 updated, with the corpus cases of section 5 (b2).
4. **(c1) IANA zones in the engine.** Needs (a) and (b1). Lowering resolves every zone through `tzdb`, replacing the
   `"UTC"`-only path; `batch_eval` gains the `//src/tzdb` dependency; the kernels serve every policy; the tests of
   section 5 (c1) and the policy test.
5. **(c2) SQL `AT TIME ZONE` and `timezone()`.** Needs (b2) and (c1). The binder resolves names through `tzdb`
   (`canonical_name`, the `UTC±` mapping, the refusals); the `AT TIME ZONE` production; `timezone` with two
   arguments, and with one argument along with `timezone_hour` and `timezone_minute`, replacing `_R_TZFN`; the
   `time_zones` corpus and its runners; the `function_coverage.tsv` rows; and query semantics items for the rules of
   section 3, including the rule-data departure.
6. **(d1) pandas verbs.** Needs (c1). `dt.tz_localize`, `dt.tz_convert`, the zone-aware fields and `floor`, the
   refusal rows, the changelog line, the verbs table row, `python/docs/dataframe/dt_accessor.md`, the test-only
   `tzdata` wheel pin, and the tests of section 5 (d1, d2).
7. **(d2) polars verbs.** Needs (d1). The `expr.dt` namespace with `replace_time_zone`, `convert_time_zone` and the
   fields, with the same pieces as (d1) for the polars skin.
8. **(e) The rank 78 task.** Needs (c2) and (d1). The directory, the page, a probe for any form still refused, the
   catalogue status, and the rank 79 Related line.

## Sources

- DuckDB v1.5.6 source: `extension/icu/icu-timezone.cpp`, `extension/icu/icu-datefunc.cpp` and
  `extension/icu/icu_extension.cpp` at the [v1.5.6 tag](https://github.com/duckdb/duckdb/tree/v1.5.6).
- DuckDB documentation, "Timestamp with time zone functions", "Timestamp types" and "Time zones"
  ([1.5 documentation](https://duckdb.org/docs/1.5/sql/functions/timestamptz.html)).
- pandas documentation, [`Series.dt.tz_localize`](https://pandas.pydata.org/docs/reference/api/pandas.Series.dt.tz_localize.html)
  and [`Series.dt.tz_convert`](https://pandas.pydata.org/docs/reference/api/pandas.Series.dt.tz_convert.html).
- polars documentation, [`Expr.dt.replace_time_zone`](https://docs.pola.rs/api/python/stable/reference/expressions/api/polars.Expr.dt.replace_time_zone.html)
  and [`Expr.dt.convert_time_zone`](https://docs.pola.rs/api/python/stable/reference/expressions/api/polars.Expr.dt.convert_time_zone.html).
- Arrow [`format/Schema.fbs`](https://github.com/apache/arrow/blob/main/format/Schema.fbs), the `Timestamp` table.
- RFC 8536 and RFC 9636 (TZif); the IANA tz database, release 2026e.
