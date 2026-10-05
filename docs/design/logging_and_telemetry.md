# Logging and telemetry: record rings, spans, metrics, and the log read seam

## What is it for, and what is out of scope?

These libraries give a Mojo process one way to write diagnostics. A call site writes `log.info[fmt, module](*args)`. The format string and module tag are compile-time parameters, so a record carries 32-bit ids and encoded arguments instead of text. A `SharedEngine` holds one ring of fixed-size records per worker, and a drain decodes each record into a text line, a span or a metric point. A read seam, `ServiceLogSearch`, and a route over it, gated by an access hook the service supplies, let a service answer queries about a log it writes to an object store.

| Library | Role |
|---|---|
| `komira_log` (`src/komira_log`) | The facade, the typed `Logger` and `Tracer`, `SharedEngine`, its rings, drains and output sinks |
| `komira_metrics` (`src/komira_metrics`) | `MetricsSet` and EXPLAIN ANALYZE rendering, the metric series table and sweep, histograms, attribute-set interning |
| `komira_trace` (`src/komira_trace`) | The span tracer, its per-worker span rings and the JSONL span exporter |
| `komira_clock` (`src/komira_clock`) | The clock reads: `now_ns`, `now_unix_ms`, `now_unix_us`, `thread_cpu_ns` |
| `komira_name_registry` (`src/komira_name_registry`) | `NameRegistry` and `name_id`, the compile-time name to 32-bit id mapping the metric and span libraries share |
| `komira_spsc_ring` (`src/komira_spsc_ring`) | The generic single-producer single-consumer ring `SpscRing[T]` under both the log record ring and the span rings |
| `komira_log_query` (`src/komira_log_query`) | The `ServiceLogSearch` trait, its erased facade, the `LogReadAccess` hook, and the `GET <path>` route |
| `komira_metrics_reader` (`src/komira_metrics_reader`) | The `MetricsReader` trait, its erased facade and scripted double, the `MetricsReadAccess` hook, and the `GET <path>` metrics route |

Out of scope:

- Where a drained record goes next, and what answers a read query. These libraries stop at the drain and at the read seam: the `ServiceLogSearch` trait takes any conformer, and no conformer ships here.
- Threshold detection over metric series, and the readers of a cloud's own container logs. A reader of a cloud's metrics, or of metric files in an object store, conforms to `MetricsReader` in a package of its own.
- Worker threads and their idle hooks: the async runtime lives in `komira_async`.
- Export over OTLP: not built; see the limits.

## How does it work?

```
log.info[fmt, module](args)   Logger.info[fmt, module](args)
   | comptime floor, then SharedEngine.admits(level, module)
   |-- bound worker thread: encode LogEventRecord -> LogRecordRing[wid]
   |-- unbound thread:      render now -> emit_fallback_line
   '-- no engine installed: render now -> LogConfig (stderr)
drain_worker(w)            -> text line -> LogSink (stderr | file | per-core segments)
drain_worker_to_lines(w)   -> List[String]
drain_worker_to_records(w) -> LogRecordView -> a consumer's own sink
drain_worker_unified(w)    -> log lines and completed OTLP-shaped spans
```

### How does log.info reach the engine?

The five level functions in `src/komira_log/facade.mojo` (`trace`, `debug`, `info`, `warn`, `error`) forward to `_emit[level, fmt, module]`. It runs `comptime if level < MIN_COMPILED_LEVEL: return`, then resolves the process-global engine with `LogManager._resolve()`. With an engine installed, it returns early if the engine is not `enabled()`, and `SharedEngine.admits(level, module)` decides after that. `site_id = fnv1a_32(fmt)` and `module_id = fnv1a_32(module)` are compile-time values, and the timestamp is a raw counter tick from `read_raw_ticks()`.

On a thread bound to a worker id, `_emit` registers the site in the `SiteDictionary`, fills a `LogEventRecord` of kind `REC_LOG`, and writes the argument tags and bytes with an `ArgBlobWriter`. Arguments that fit in `ARG_INLINE_BYTES` (48) stay in the record; longer ones spill to the ring's arena. It then calls `try_push` on that worker's `LogRecordRing`. On a thread with no worker id, `_emit` renders the line at once and calls `emit_fallback_line`. With no engine installed, `_ensure_config()` builds a default `LogConfig` on first use and the line goes to stderr.

Three other surfaces share this path. `get_logger[module]()` returns a `GlobalLogger` that calls the same `_emit`. `Logger[origin]` in `logger.mojo` borrows one engine through a concrete origin and uses the same `admits` and escalation. `emit_erased` in `logger_erased.mojo` takes the format and arguments at run time and keeps only the level and module as compile-time parameters, so call sites that share both share one compiled body. A `Tracer[origin]` in `src/komira_log/tracer.mojo` is the span twin of `Logger[origin]`: `start_span[name](worker_id)` and `end_span(span_id, worker_id)` push span records onto the same ring.

### How is a log level decided?

Levels are `LEVEL_TRACE` (0) to `LEVEL_ERROR` (4), with `LEVEL_OFF` (5), in `levels.mojo`. `MIN_COMPILED_LEVEL` is `LEVEL_TRACE`, so by default the compile-time floor removes no site. An `EnvFilter` (`env_filter.mojo`) parses a directive such as `info,komira_http=debug`: a global level plus per-module rules. A rule matches a module that equals its prefix or starts with the prefix and a `.`, and the longest matching prefix wins.

`SharedEngine.admits` makes one decision. With no rules it compares against the runtime global level, one atomic load. When a rule matches the module, the rule governs in either direction, so `x=debug` under an `info` default admits DEBUG for `x`. When no rule matches, the runtime global level governs, so `set_global_level` moves every module that has no rule of its own.

Configuration arrives as arguments, not from the environment. A binary parses its own `--log-level` and `--log-format` flags and calls `init_logging_from_spec(spec, source, log_format, on_deployed_platform)`; `LOG_SPEC_SOURCE_FLAG` is `"--log-level"`, the `source` to pass for the flag. `init_logging()` and the lazy `_ensure_config()` install the built-in default (global level INFO, no rules), and `LOG_SPEC_SOURCE_DEFAULT` names it as "built-in default (no --log-level given)". Each of the three prints `log_config_banner_lines`, which name the level and where it came from. `init_logging_with(filter)` installs an explicit `EnvFilter` and prints nothing. No code in these libraries reads an environment variable.

`render_line` in `pattern_layout.mojo` writes `{ts} {LEVEL} [{module}] {message} {k=v ...}`, or a JSON line when the selected layout is JSON. `select_log_layout` stores the choice in a C cell, and `init_logging_from_spec` calls it on every call. `log_format_is_json` in `komira_log/structured_log.mojo` decides: `json` or `text` (any case) wins; any other value, empty or malformed, falls back to the `on_deployed_platform` argument.

### What does the engine hold?

`SharedEngine(num_workers, filter)` allocates `num_workers + 1` rings of `DEFAULT_RING_CAPACITY` (4,096, defined in `komira_spsc_ring/spsc_ring.mojo`) records. Worker rings use `OVERFLOW_DROP`; the last ring, the fallback slot, uses `OVERFLOW_BLOCK`. It also holds the `SiteDictionary` (`site_id` to format, `module_id` to module), a `CalibrationAnchor` that converts ticks to wall time at drain time (`refresh_anchor`), the global level and the `EnvFilter`, one `LogSink`, and a pthread TLS key for the worker id (`worker_id_tls.mojo`). Logs, span opens, span closes and metric points share one ring; `LogEventRecord.kind` is `REC_LOG`, `REC_SPAN_OPEN`, `REC_SPAN_CLOSE` or `REC_METRIC`.

`LogManager.install(engine)` moves an engine to the heap, leaks it, and parks its address in a C static (`engine/_log_holder_shim.c`). The first install wins and later ones are no-ops.

### How is a ring drained?

A drain pops records and decodes them against the site dictionary (`engine/drain.mojo`). `SharedEngine` has four drains, and each pops, so a record goes to one of them. `drain_worker(w, max_records)` renders text and writes it to the engine's `LogSink`. `drain_worker_to_lines` returns the rendered lines. `drain_worker_to_records(w, ...)` returns owned `LogRecordView`s for a consumer that wants fields rather than text. `drain_worker_unified` returns log lines and completed spans together. `render_record_view` renders a view back to the same text line the sink would have written, which is how a consumer also mirrors a record to a sink. The engine never drains by itself: a caller decides when each ring is drained.

Span records are paired by span id in `engine/span_drain.mojo` into one OTLP-shaped JSON object. With `set_capture_spans(True)` they are kept per worker for `take_span_lines` or `drain_captured_spans`. Metric records decode to `MetricPoint`s and, with `set_capture_metrics(True)`, are kept for `take_metric_points`. Each retained buffer is capped at four ring capacities (`_SPAN_BUF_MAX`, `_METRIC_BUF_MAX`); overflow is counted by `spans_dropped_count` and `metrics_dropped_count`.

`LogSink` (`engine/output_sink.mojo`) has three modes: `SINK_STDERR`, `SINK_FILE` and `SINK_PER_CORE_SEGMENTS`, with one segment per core plus a fallback segment. The engine starts on stderr; `set_sink_stderr`, `set_sink_single_file` and `set_sink_per_core_segments` switch it. A segment rotates under its own `RotationPolicy` (none, size, time or both, with a retained-archive count, `RETAIN_ALL` keeping every archive). Output goes through `write_log_line` in `komira_log/log_write.mojo`, which retries transient errors, and a line the sink could not write is counted rather than silently dropped.

### How are metrics recorded?

There are two instruments. `MetricsSet` (`komira_metrics/metrics_set.mojo`) is a per-operator registry of at most 8 counters, 4 times and 4 gauges, with one slot per worker for up to 64 workers. `inc_in_pipeline(n, worker_id)` writes only that worker's slot, and `reduce()` sums the slots. A lookup of an unregistered name lands in a quarantine slot that no read path reports. `format_execution_report` in `explain_analyze.mojo` renders the per-operator blocks for EXPLAIN ANALYZE, and `explain_analyze_collect.mojo` is the collector, armed only for the scope of one explicit EXPLAIN ANALYZE call.

The second instrument is shaped after OpenTelemetry. `SeriesTable` (`series_table.mojo`) is one table that maps a series key, built from `(name_id, attrset_id)`, to a value; `SeriesTables` in the same file holds the per-worker tables. Attribute sets are interned by `attr_set.mojo`. `MetricSweep` (`metric_sweep.mojo`) reduces those tables and hands one `MetricPoint` per series per interval to a `MetricPointSink`. `RingMetricSink` (`komira_log/engine/metric_sink.mojo`) is one such sink: it encodes each point as a `REC_METRIC` record with `build_metric_record` and pushes it onto the engine's ring. Histograms live in `histogram.mojo` as their own tables.

### How are spans recorded?

`komira_trace` has its own span path: a `Tracer` with per-worker context slots and `start_span[name](worker_id, parent_id)` / `end_span(span_id, worker_id)`, a `SpanRecord`, one `SpscRing[SpanPacket]` per worker (`SpanPacketRing` in `span_ring.mojo`), and two exporters in `exporter.mojo` (`JsonlFileExporter`, `CapturingExporter`). A `TRACES_ENABLED` comptime flag removes every method body when it is false. The engine's span path in `komira_log` is the second one: it carries the same start and end calls as records on the log ring, so logs and spans share one drain.

### How does a service read its own log?

`ServiceLogSearch` (`komira_log_query/search_seam.mojo`) is the read trait, with one method, `scan(q: ServiceLogQuery) raises -> ServiceLogPage`. A `ServiceLogQuery` carries a nanosecond window, a term and a limit; a `ServiceLogPage` carries `ServiceLogHit`s. `ErasedServiceLogSearch` holds one conformer behind function pointers so a dispatcher holds a single non-generic field and the conformer's storage type instantiates only at `erase[S]`. The package depends on `komira_http_core` and nothing else. No conformer ships in this tree.

`service_log_response(search, req, access, now_ns)` in `route.mojo` serves the route; `is_service_log_request(req, path)` matches `GET` at the exact path the service mounted it on. It asks the `access` hook first (`LogReadAccess.allows(req)` in `access.mojo`), then reads `q`, `since_ms`, `until_ms` and `limit`. The window ends at `now_ns` by default and starts 2,592,000,000 ms (30 days) before its end. `since_ms` after `until_ms` is a 400. The limit defaults to 50, is raised to 1 if lower, and is capped at 500. The function never raises. When `scan` raises, a query with no term (`q` empty) becomes a 400 that carries the conformer's own message, because the conformer could not answer a time-range query by itself; a query with a term becomes a 500, `log index read failed`, that names the fault.

### How does a service read its metrics?

`MetricsReader` (`komira_metrics_reader/reader.mojo`) is the read trait, with two methods. `refusal(q: MetricsQuery) -> String` returns "" when the reader can answer, else a sentence naming what its store cannot do (a step finer than it keeps, an aggregation it cannot compute, grouping it cannot express); it reads nothing. `read(q) raises -> MetricsPage` answers. A `MetricsQuery` carries an inclusive nanosecond window, a metric name, equality and inequality label matchers, an aggregation (`raw`, `sum`, `rate`, `mean`, `min`, `max`, `count`) over a step, group-by keys, and a series and a point limit. A `MetricsPage` carries `MetricsSeriesData` (metric, labels, samples oldest first, each a nanosecond time and a Float64), `truncated` when a limit cut the answer, and `sources_scanned`. `ErasedMetricsReader` is the non-generic facade, as `ErasedServiceLogSearch` is for logs, and `ScriptedMetricsReader` is the double. The package depends on `komira_http_core` and nothing else; no reader ships in it.

`metrics_response(reader, req, access, now_ns)` in `route.mojo` serves `GET` at the exact path `is_metrics_request` matches. It asks the `MetricsReadAccess` hook first; a refusal, a raising hook and an unwired reader are one byte-identical 404. It then reads `metric` (required), `since_ms`, `until_ms`, `step_ms`, `agg`, `group_by`, `label.<k>`, `not_label.<k>`, `series_limit` and `point_limit`. The window ends at `now_ns` by default and starts one hour before its end; the step defaults to 60,000 ms; the limits default to 100 series and 1,440 points and are clamped to 1,000 and 100,000. A present but malformed number, an inverted window and an unknown aggregation are each a 400, never a default. The reader's refusal is a 400 carrying its sentence, and the read is not made; a raise from the read is a 500, `metrics read failed`, that names it.

## Why is it built this way?

### Why encode records into a ring instead of formatting at the call site?

**Decision.** A call site writes a fixed-size binary record into its own worker's ring, and the drain formats it later.

**Because.** The `SharedEngine` header states the rule: logging must never stall the dataplane. The format string is a compile-time literal, so the record needs only its 32-bit digest, and decoding happens at drain time from the `SiteDictionary`. The drain's `_render_runtime_module` produces the same layout as `render_line`, so a line reads the same whichever path produced it.

**Alternatives weighed.**

- Format and write on the caller's thread: kept only for threads with no worker id and for processes with no engine, where no drain would ever run.
- Move the whole emit out of line to cut compile cost: not done. Only the cold render is out of line (`_write_rendered`), so the hot path stays inlined at the call site.

**Revisit if.** Records wait in worker rings long enough to be dropped. Nothing in `komira_async` drains a log ring; the embedder calls a drain, through the drains above or an idle hook it installs.

### Why is a WARN never dropped when a ring is full?

**Decision.** A full worker ring drops TRACE, DEBUG and INFO records and escalates WARN and ERROR to a synchronous write (`escalate_line`), which also flushes the sink.

**Because.** A dropped record must not stall query work, but a WARN or ERROR often comes just before a crash, and its line must be durable first. Both the facade and `Logger` escalate at `LEVEL_WARN`, and `test_log_typed_never_drop_contract` asserts that both surfaces do. A failed write and a failed flush are counted separately, because the first means the line is gone and the second means it landed but may not survive.

**Alternatives weighed.**

- Block the producer until the ring has room: this is the fallback ring's policy (`OVERFLOW_BLOCK`), and it is not used for worker rings because it stalls the dataplane.
- Escalate ERROR only: this drops WARN lines, which the design states must never be dropped.

**Revisit if.** Escalated writes become frequent enough to slow workers, which would show in `overflow_dropped_count` and the sink counters.

### Why are the global engine and the global config leaked and parked in C statics?

**Decision.** `LogManager.install` leaks the engine and stores its address in `komira_log_holder_set`, and every ambient resolve reads it back. `LogConfig` is leaked and parked the same way, and the selected layout is a third C cell.

**Because.** Mojo has no module-level variables, so each process-wide cell lives in C and holds one word and no logging logic. The engine is never moved or freed, so the one `unsafe_from_address` in `_resolve` always names a live engine. The header of `log_manager.mojo` records the alternative it replaced: an address that named a movable field of a per-session struct dangles once that struct is destroyed.

**Alternatives weighed.**

- Park the address in a per-session field: rejected for the reason above.
- Thread a handle through every call: this is the typed `Logger`, and it exists alongside the ambient path because many call sites have no context to borrow from.

**Revisit if.** Mojo gains module-level globals.

### Who decides who may read the log?

**Decision.** The embedding service, through a `LogReadAccess` hook that `service_log_response` takes as a required argument. A read is denied unless the hook says yes: the two hooks shipped, `DenyLogReads` and `HeaderTokenAccess(header, token)`, both answer no by default (`HeaderTokenAccess` while its header name or secret is empty), a hook that raises is a no, and no allow-everything hook ships.

**Because.** `access.mojo`'s header records it: who may read depends on the service (a shared secret, a token its front end verified, a role in its own user table), so the library cannot choose. The route returns the whole log, and a service's log names data from every one of its callers, so a read surface open whenever nobody configured it is open when nobody is looking. A service that wants an open log writes that hook itself, where a reviewer sees it.

**Alternatives weighed.**

- A built-in token header: it fixes one policy and one header name for every service.
- Allow when no hook is configured: the open-when-unconfigured failure above.

### Why does the log route answer 404 to every refusal?

**Decision.** `service_log_response` answers the same 404 when the hook says no, when it raises, and when the service has no reader, and it validates arguments only after the access check.

**Because.** The route's header records it: a distinct 401 or 403 would tell an unauthenticated caller that the route exists. Validating arguments first would show such a caller a 400 on a service with the route and a 404 on one without.

An allowed caller can still see a 400: an inverted window (`since_ms` after `until_ms`), a bound past the nanosecond range, or a term-free query that the wired conformer cannot answer.

### Why does the read seam take no caller?

**Decision.** `ServiceLogSearch.scan` takes a window, a term and a limit, and nothing that names the caller.

**Because.** The header of `search_seam.mojo` records it: a conformer reads one log and answers from all of it; who may read it is decided before the read, by the hook. A service with separate logs for separate audiences wires a reader and mounts a route, with its own hook, for each.

**Alternatives weighed.**

- A caller argument on `scan`: every conformer would become an access-control enforcer.

## What must always hold?

- **A suppressed record costs only the gates.** `_emit` returns before any argument is rendered when `admits` is false. `test_log_erased_emit_perf` times it (its `PAIR 2 SUPPRESSED` arm emits at DEBUG against a WARN engine and asserts nothing reached the ring); `test_log_effective_level_resolution` covers the decision.
- **A record the ring rejects at WARN or above is written synchronously.** Enforced by `test_log_facade_error_escalation` and `test_log_typed_never_drop_contract`.
- **One producer per ring, for log records.** A thread with no worker id never pushes a log record; it renders and writes. Not enforced by a type, and span records are an exception (see the limits). The `SiteDictionary` append is not synchronised, so two bound workers registering a new site at once can race (`facade.mojo`).
- **Only the first `LogManager.install` takes effect, and the engine it installs is never freed.** Enforced by `test_log_manager_global`.
- **Each drained record goes to one drain.** All four drains pop. A consumer that needs both outputs mirrors with `render_record_view`.
- **The log route touches no environment and no clock.** Its token and time arrive as arguments.
- **The retained span and metric buffers are bounded.** Overflow is counted, never blocking. Covered by `test_log_drain_span_retained_all_drains` and `test_log_drain_metric_point_all_drains`.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `src/komira_log/facade.mojo` | The ambient call surface | `info`, `warn`, `_emit`, `get_logger`, `span_open` |
| `src/komira_log/logger.mojo`, `logger_erased.mojo`, `tracer.mojo` | Typed and erased surfaces | `Logger`, `emit_erased`, `Tracer` |
| `src/komira_log/config.mojo`, `env_filter.mojo`, `levels.mojo` | Levels, directives, the no-engine config | `LogConfig`, `init_logging_from_spec`, `EnvFilter`, `MIN_COMPILED_LEVEL` |
| `src/komira_log/pattern_layout.mojo` | Text and JSON line layout | `render_line`, `render_json_line`, `select_log_layout` |
| `src/komira_log/engine/shared_engine.mojo` | The engine | `SharedEngine`, `admits`, `drain_worker`, `drain_worker_to_records` |
| `src/komira_log/engine/log_manager.mojo` | The process-global engine | `LogManager` |
| `src/komira_log/engine/record_ring.mojo`, `log_event_record.mojo` | Ring and record | `LogRecordRing`, `LogEventRecord`, `ArgBlobWriter` |
| `src/komira_log/engine/drain.mojo`, `span_drain.mojo` | Decode and span pairing | `render_record_view`, `drain_unified` |
| `src/komira_log/engine/output_sink.mojo`, `rotation.mojo` | Output modes and rotation | `LogSink`, `SegmentFile`, `RotationPolicy` |
| `src/komira_log/engine/metric_emit.mojo`, `metric_sink.mojo` | Metric records on the ring | `build_metric_record`, `RingMetricSink` |
| `src/komira_metrics/metrics_set.mojo`, `explain_analyze.mojo` | Per-operator metrics | `MetricsSet`, `format_execution_report` |
| `src/komira_metrics/series_table.mojo`, `metric_sweep.mojo`, `histogram.mojo` | Series metrics | `SeriesTable`, `MetricSweep`, `HistogramTable` |
| `src/komira_trace/tracer.mojo`, `exporter.mojo`, `span_ring.mojo` | Spans | `Tracer`, `JsonlFileExporter`, `SpanPacketRing` |
| `src/komira_log/log_write.mojo`, `structured_log.mojo` | Writes, JSON selection | `write_log_line`, `log_format_is_json` |
| `src/komira_clock/clock.mojo`, `src/komira_spsc_ring/spsc_ring.mojo` | Clocks, the generic ring | `now_ns`, `SpscRing` |
| `src/komira_log_query/route.mojo`, `access.mojo`, `search_seam.mojo`, `hit.mojo` | Read route, access hook, trait and values | `service_log_response`, `LogReadAccess`, `ServiceLogSearch`, `ServiceLogQuery` |
| `src/komira_metrics_reader/route.mojo`, `access.mojo`, `reader.mojo`, `query.mojo`, `series.mojo` | Metrics read route, access hook, trait and values | `metrics_response`, `MetricsReadAccess`, `MetricsReader`, `MetricsQuery` |

Entry points:

- **Public API:** `log.info[fmt, module](*args)` in `facade.mojo` for any code; `init_logging_from_spec` once at start; `SharedEngine` and `LogManager.install` for a process that owns an engine.
- **Execution starts at:** `_emit` in `facade.mojo` for a write; a `SharedEngine` drain for a publish; `service_log_response` for a read.

## How is it tested?

Each library below welds its tests with `test_srcs`, so building it runs them.

| Library | Welded tests | Covers |
|---|---|---|
| `komira_log` | 30, all of `src/komira_log/tests/` | levels and filters, facade, engine, drains, spans, metrics on the ring, sinks and rotation, escalation, JSON layout, write retry and loss accounting, TLS key reuse |
| `komira_metrics` | 9, all of `src/komira_metrics/tests/` | `MetricsSet`, EXPLAIN ANALYZE, histograms, series table, sweep, attribute sets |
| `komira_trace` | 7, all of `src/komira_trace/tests/` | tracer, JSONL exporter, span records, drain throughput |
| `komira_spsc_ring` | 2, `test_spsc_ring` and `test_ring_variants` | the generic ring: order, wrap, block and drop policies |
| `komira_clock` | 1, `test_clock` | clock reads |
| `komira_log_query` | 1, `test_service_log_route` | path match, the access hook and the one 404, window and limit, term decoding, the conformer-raise split, page rendering, the erased facade |
| `komira_metrics_reader` | 3, `test_metrics_query`, `test_metrics_reader` and `test_metrics_route` | the value types, the erased facade and the double against the trait, and the route: path match, the one 404, arguments and their 400s, the refusal and fault split, page rendering |
| `komira_name_registry` | 1, `test_name_registry` | name registry |

Run: `./buck2 build //src/komira_log:komira_log //src/komira_trace:komira_trace //src/komira_metrics:komira_metrics //src/komira_spsc_ring:komira_spsc_ring //src/komira_clock:komira_clock //src/komira_name_registry:komira_name_registry //src/komira_log_query:komira_log_query //src/komira_metrics_reader:komira_metrics_reader`.

`test_log_p2c_aot_perf` compares the typed and ambient reaches and only reports. Not tested: `emit_erased` has tests and no caller in these libraries.

## What are its limits and open questions?

- **Limit:** a thread that is not bound to a worker id always renders and writes synchronously, so an HTTP handler or CLI tool pays the full format cost per line.
- **Limit:** span records do not follow the one-producer rule. `start_span` and `end_span` take an explicit worker id and never read the thread binding, so a driver thread that opens a span on ring 0 while worker 0's own thread logs there gives that single-producer ring two producers.
- **Limit:** nothing in these libraries drains a worker ring. Records wait until the embedder calls a drain, and a full worker ring drops TRACE, DEBUG and INFO records.
- **Limit:** the `SiteDictionary` is not synchronised; two bound workers registering the same new site at once can race.
- **Limit:** `MetricPoint` has one value field and cannot carry histogram buckets.
- **Limit:** no code in these libraries calls `MetricSweep` or constructs a `RingMetricSink`; they are the pieces a metrics publisher is built from.
- **Open question:** whether the typed `Logger` is faster than the ambient path. `test_log_p2c_aot_perf`'s header records both arms measured at about the same cost. A repeatable A/B on the build farm would decide it.
- **Open question:** telemetry export over OTLP. The span and metric shapes follow OpenTelemetry, but nothing exports; a destination and a transport would have to be chosen.
