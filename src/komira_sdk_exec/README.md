# komira_sdk_exec

The engine-execution layer of the SDK. This is its early slice: nine leaf
modules that need nothing from the rest of the package except each other, and
the plan gates (`plan_validation_gate`, `parquet_glob_options`), which build on
`komira_sdk`. The engine context that drives a query, the sinks and the frames
come in later slices; nothing here runs a query.

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
| `session_stats` | `SessionStats`: a plain snapshot of the worker counts |

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

## Limits

`post_rewrite_gate` is a free-standing check; its call sites belong to the
engine context. The plan validation gate that `plan_validation_routes` is the
ledger for is `plan_validation_gate`; its call sites (the `@parameter if` and
switch guards at each route) belong to the engine context, a later slice. No
ledger row is COVERED yet: the guard tests the
first-draft rows named are not in this slice, so those rows are WIRED_UNPROVEN
until their tests arrive, and a test here checks that a COVERED row only names a
test file this package ships. `deps` in the BUCK file is the full transitive
closure; a later slice that pulls a new library adds it in the same change.
