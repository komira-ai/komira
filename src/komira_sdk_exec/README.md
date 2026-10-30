# komira_sdk_exec

The engine-execution layer of the SDK: twelve modules, ten leaves that need
nothing from the rest of the package except each other, and the plan gates
(`plan_validation_gate`, `parquet_glob_options`), which build on `komira_sdk`;
and the engine context with its SQL door (`engine_*` below), which runs a SQL
query over Parquet files from text to record batches. Views, writes, the plan
cache and the plan gates' call sites are not wired into the context yet.

| module | does |
|---|---|
| `sink_variant_tags` | the 16 `SINK_VARIANT_FILE_*` arm-lookup tags (`UInt8`), with no imports, so a module that needs only the integers does not pull in the write stack |
| `plan_compile_cache` | the two-layer plan-compile cache (`PlanCompileCache`): Layer 1 keyed by the plan's structural hash, Layer 2 keyed by `compose_full_cache_key` (structural hash, log2-bucketed cardinality fingerprint from `compute_stats_hash`, and a per-sink-kind salt that excludes the output path); capped at `RESOLVED_CACHE_CAP` entries with LRU eviction that skips pinned entries and raises when every entry is pinned |
| `plan_validation_routes` | the ledger of terminal execution routes and what the plan validation gate does about each (`COVERED`, `WIRED_UNPROVEN`, `UNCOVERED`, test harness); `route_index_for_entry` looks an entry token up and `ledger_self_check` refuses a contradictory ledger |
| `plan_validation_gate` | the dev-flag gate over `validate_plan`: `plan_validation_outcome` returns what the gate did for a plan at a ledger entry (`VALIDATED`, `NOT_VALIDATED` naming the first plan tag the validator does not model, or `FAILED` with the validator's finding) and raises on an entry the ledger does not name; `validate_plan_at_entry` prints one line and raises only on `FAILED`; `assert_plan_integrity`; `plan_tag_name`; `plan_validation_enabled(armed)` takes the caller's switch, default off, and reads no environment variable |
| `parquet_glob_options` | `to_glob_options`: `ParquetReadOptions` to the discovery layer's `GlobDiscoveryOptions` (the empty-match policy) |
| `scan_binding_gate_wiring` | runs the scan-binding epoch gate at a route against the caller's resolver (`check_scan_bindings_at_entry`, or `..._unbound` for a caller with no registry) and raises on an entry token the ledger does not name |
| `post_rewrite_gate` | `plan_values_are_admissible` and `check_values_after_rewrite`: a rewrite may not introduce a literal the plan wire value check refuses, judged as a difference between the plan the optimizer was handed and the plan it produced |
| `paginated_result` | `PaginatedResult` (the value a caller holds) and `PaginatedState` (the context-side pre-chunked result, cursor and cache pin) for a result that is materialized eagerly and handed out in pages, and the cap on open results |
| `view_handle` | `ViewHandle`: a registered view's name plus a generation, with no context back-reference, so a re-registered name invalidates old handles |
| `materialized_view_handle` | `MaterializedViewHandle`: the same shape for a view whose result is stored |
| `secret_capability` | `SecretCapability`: the handle a plan holds for a secret-bearing node, carrying only the node id (never the value, never the secret ref); `open_connection_for` lifts the plan's `SecretBindings` into a `SecretRegistry` over the supplied store and reveals that node's secret to a `CredentialConsumer` inside the call, so the value never escapes |
| `session_stats` | `SessionStats`: a plain snapshot of the worker counts |

### The engine context and `run_sql`

Import each module by name. The context is a small state struct; what it can
do is a free function in a module of its own.

| module | does |
|---|---|
| `engine_options` | `EngineOptions`: `worker_count` and `memory_budget_bytes`, each `Optional` (absent means the host profile's own value). Values the caller fills from its flags; no environment variable is read |
| `engine_context` | `EngineContext(options)`: probes the host once, applies the options over the profile, starts the worker runtime. Holds the catalog, the registered tables, `footers` (a `ParquetFooters`), `host_profile` and `runtime`. A count or budget below 1 is refused with `ENGINE_OPTIONS_INVALID`. `begin_query` drops the footer cache |
| `engine_catalog` | `register_parquet(ctx, name, path)`: the table's schema is its file's footer |
| `engine_lower` | `lowering_inputs` (the facts of each scan, from `ctx.footers`, in the cutter's scan order; a registered table's scan is checked against its registered schema) and `lower_for_context` |
| `engine_execute` | `run_lowered_plan(ctx, lowered)`: a `RealBuilder` over a per-run metadata cache and expression pool, the segment pool sized from the memory budget, `run_plan` on `ctx.runtime` with the host profile's thread count; returns the result segment's batch |
| `engine_sql` | `run_sql(ctx, text) -> SqlOutcome`: tokenize and parse, `bind_statement`, `optimize`, lower, run. Nothing raises: `SqlOutcome.refusal` holds the step (`parse`, `bind`, `optimize`, `lower`, `execute`) and that step's own message |

**The footer cache is pinned to a query.** `komira_parquet_footers.FooterCache`
has no cap, so the context does not keep it: `run_sql` starts by replacing it
with an empty one (`begin_query`). Within a call the binder and lowering read
one version of each file's footer (`ParquetFooters` and `lowering_facts` share
the cache and refuse a file whose identity changed since it was read). The next
call reads each file it names again, so a file replaced between queries is read
as the new file, and is refused at step `lower` (naming the table) when its
schema no longer matches the registered table. That a file replaced by identity
(size, time, inode) is refused cannot be reached from `run_sql`, because the
cache is fresh for every call; the package's own tests cover it.

What this does not close: the scan opens the file afresh. `run_lowered_plan`
builds a new `komira_parquet.ParquetMetadataCache` for the run, so the scan
reads the footer a second time, and a file replaced between lowering and the
scan is read with the old plan's schema and min/max (komira#2024 adds the
check at scan time). A same-schema replacement with new min/max is correct
across queries only because no plan is cached between them; wiring
`plan_compile_cache` into `run_sql` would reopen that hole. The price of the
pin is the footer reads: one by the footer cache per file per query, and one
more by the scan.

**Refused here, by name.** A statement that is not a query
(`STATEMENT_NOT_A_QUERY`, step `bind`); a scalar subquery (the optimizer keeps
it in the plan and lowering refuses the node, `LOWERING_UNCUTTABLE_NODE`; the
door also refuses with `OPTIMIZE_UNRESOLVED_SCALAR` a plan whose optimization
asks for a scalar to be executed first, a guard no query tested here reaches); a plan that
scans an in-memory batch, such as a SELECT with no FROM
(`EXECUTE_UNSUPPORTED_PARAM`, step `execute`); a sink denied its memory by the
budget, a sum outside its declared type and a pool not whole after a run (step
`execute`); and whatever lowering, the binder or the parser refuses (a join is
`LOWERING_UNCUTTABLE_NODE` at `lower`). A glob path and a table of several
files are refused by the footer package. Lowering given fewer scan facts than
the plan has scans refuses by name (`LOWERING_INPUTS_SCAN_COUNT`);
`lowering_inputs` descends only scan, filter, project, limit, aggregate and sort
nodes and gives a facts entry per scan it reaches, and the cutter refuses any
other node by name before it asks for the scans below it. `worker_count` and
`memory_budget_bytes` have a lower bound of 1 and no upper bound. A
cancellation token is local to a call, so cancel is not reachable from
`run_sql`. After a refusal the context is unchanged and runs the next query.

## Tests

The tests run when the package is built.

- `test_plan_cache_full_sink_hash`: the sink kind is part of the Layer 2 key
  and the path is not.
- `test_resolved_cache_pin_count`: a pinned entry survives an eviction wave,
  pins are counted, and a cache of only pinned entries refuses an insert.
- `test_resolved_cache_lru_eviction_stress`: past the cap the oldest unpinned
  entry is evicted.
- `test_plan_validation_gate_direct`: the gate's outcome for a scan, for a union
  under either child of a join (not validated, naming `PLAN_UNION`) and for a
  filter on a missing column (failed); the entry token must be a ledger row;
  `validate_plan_at_entry` raises only on a failure; the 16 tag names; the
  glob-options mapping; the switch defaults off.
- `test_plan_validation_routes_ledger`: the ledger's self check and lookups,
  and the wiring's refusal of an unregistered token and of a handle from
  another epoch.
- `test_run_sql_q6`: TPC-H Q6's text from `komira_bench_corpus` over a lineitem-shaped
  Parquet file gives the integer oracle's DECIMAL(38,4); a join, a syntax error,
  an unknown table, a missing file, CREATE TABLE AS and a replaced file are named
  refusals, as are a tiny memory budget, an INT64 sum out of range, a scalar
  subquery (refused by lowering) and a SELECT with no FROM; the context runs on after a refusal; the
  footer cache reads each file once per query and shares it between bind and
  lower; a file replaced between queries is read again; options are validated;
  contexts are created and dropped repeatedly, the segment pool whole after
  each run.
- `test_secret_capability_reveal`: a capability reveals exactly the secret
  bound to its own node id, once and after one store resolve; two capabilities
  over one bindings table each reveal their own value; an unbound node or a
  removed ref raises before the consumer is called.

## Limits

The context does not yet hold a source registry, a plan cache, spill options or
the plan validation switch. `run_sql` serves one result segment of Parquet
scans; Q1 waits for the grouped sinks and the sort. The post-rewrite gate and
the plan validation gate are not called from `run_sql`.

`post_rewrite_gate` is a free-standing check; its call sites belong to the
engine context. The plan validation gate that `plan_validation_routes` is the
ledger for is `plan_validation_gate`; its call sites (the `@parameter if` and
switch guards at each route) belong to the engine context, a later slice. No
ledger row is COVERED yet: the guard tests the first-draft rows named are not
in this slice, so those rows are WIRED_UNPROVEN until their tests arrive, and a
test here checks that a COVERED row only names a test file this package ships.
`deps` in the BUCK file is the full transitive closure; a later slice that
pulls a new library adds it in the same change.
