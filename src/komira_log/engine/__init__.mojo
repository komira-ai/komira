# =============================================================================
# komira_log.engine — the binary event-pipeline CORE (P2a).
# =============================================================================
#
# A NanoLog-class binary log engine, built as a STANDALONE,
# well-tested unit. P2a is the core + a direct round-trip test; P2b wires it
# into the runtime / worker loop / EngineContext and swaps it behind the P1
# facade. Import directly from sub-modules (no facade here — the package facade
# is `komira_log/__init__.mojo`).
#
# Sub-modules:
#   log_event_record — the POD fixed-stride on-ring record (kind/level/site_id/
#                      timestamp/corr_id/arg-blob).
#   site_dictionary  — comptime FNV-1a site-ID + the decoder dictionary.
#   record_ring      — per-core SPSC ring of records (generalized obs ring) +
#                      the string-arg spill arena.
#   calibration      — raw-tick timestamp + the drain-side wall-time anchor.
#   emit             — the comptime `emit_record[fmt, module, *ArgTs]` hot path.
#   drain            — decode-at-flush: ring → decoded text lines.
#
# P4a — the UNIFIED span (tracing) surface on the SAME ring + drain:
#   span_context     — per-worker span-id stack + id/trace allocation (the
#                      `Slab[SpanContextSlot]` the engine owns; obs Tracer shape).
#   span_emit        — SPAN_OPEN / SPAN_CLOSE `LogEventRecord` builders (the
#                      span twin of `emit`; rides the same record kind field).
#   span_drain       — SPAN records → OTLP-shaped JSON, with the cross-batch
#                      OPEN/CLOSE correlator (`OpenSpanTable`) + the unified
#                      `drain_unified` (logs → text, spans → OTLP, one ring).
#
# the METRIC surface on the SAME ring + the SAME drains:
#   metric_emit      — `REC_METRIC` record builder + decoder (the metric twin of
#                      `span_emit`). One record IS one point: no cross-batch
#                      correlator is needed, so there is no `metric_drain`
#                      module — the six ring consumers each carry a four-line
#                      arm instead. The return channel is the engine's
#                      `_metric_buf` / `take_metric_points`, the span channel's shape.
# =============================================================================
