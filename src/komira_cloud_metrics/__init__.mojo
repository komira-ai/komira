# =============================================================================
# komira_cloud_metrics — READ A DEPLOYED WORKLOAD'S TIME SERIES. The sibling of
#   the cloud-log reader in `kci_logs`, and ⛔ THE HALF THAT IS DELIBERATELY NOT
#   WIRED.
# =============================================================================
#
# WHY THIS PACKAGE EXISTS: the release tool should be able to read a deployed
# workload's logs and metrics itself, so that nobody diagnoses a deploy with a
# raw `gcloud` or `aws` command. The LOGS half (`kci_logs`) has a live reader on
# both clouds and a real consumer: a failing validate step reports its own
# container output. This is the METRICS half, and it ships ⛔ WITH NO LIVE
# CONFORMER AND NO CALLER. That is a DECISION, argued below, not an unfinished
# sentence. §3 is the argument; §4 is what would flip it.
#
# ── §1 — WHAT IS HERE ───────────────────────────────────────────────────────
#   * `cloud_metric_source`         — the CLOUD-NEUTRAL seam (`CloudMetricSource`),
#                                     the four value PODs, the not-configured
#                                     default, the hermetic double.
#   * `metric_json`                 — the two scanning primitives a metric parse
#                                     needs that a log parse does not, and the
#                                     percent-encoder. Everything else comes from
#                                     `kci_logs.json_scan`.
#   * `gcp_monitoring_query`        — GCP, PURE: the `timeSeries.list` path +
#                                     query (aggregated — see below), the
#                                     allow-listed parse.
#   * `aws_cloudwatch_metrics_query`— AWS, PURE: the `GetMetricData` body, the
#                                     allow-listed parse, the parallel-array
#                                     pairing and the `PartialData` refusal.
#
# ── §2 — THE ONE DEP, AND WHY IT POINTS AT THE LOGS PACKAGE ────────────────
# `kci_logs`, for `json_scan`. ⚠ The edge LOOKS backwards (metrics depending on
# logs) and is deliberate: `json_skip_value` is what makes every allow-list in
# either package actually hold, and a second depth-tracking skipper is a second
# thing to get wrong in the one place where getting it wrong leaks structure the
# parser never intended to read. Both packages are zero-socket leaves.
#
# ── §3 — ⛔⛔ WHY THERE IS NO CONSUMER, AND WHY THAT IS THE RIGHT ANSWER ────
# The question is *"who calls this?"*, and the honest answer today is NOBODY.
# The candidates were enumerated and each fails on its own terms:
#
#   (a) A VALIDATE STEP THAT GATES ON A RATE ("error rate < X"). Two blockers,
#       both MEASURED:
#         * ⚠ CLOUD RUN'S METRIC PIPELINE LAGS. A ~26 MINUTE gap between the
#           newest point and now was measured on Cloud Run. A gate that reds on
#           an empty window after a deploy is measuring INGESTION LATENCY, not
#           the deploy. A gate that WAITS for the window to fill has added ~26
#           minutes to every deploy.
#         * ⚠ THE READ ITSELF STALLS IN THE ENVIRONMENT A VALIDATE STEP RUNS IN.
#           `timeSeries.list` STALLS above ~1.1 MB inside a Cloud Run JOB and
#           dies on a fixed ~279s budget — 12/12 passes below the threshold, 0/2
#           above — and does NOT reproduce off Cloud Run. In-cloud validate
#           steps ARE Cloud Run Jobs. The aggregation defaults in this package
#           are the measured mitigation, and the response still scales with
#           label cardinality.
#       ⛔ And a rate gate needs a THRESHOLD. No bundle authors one, and
#       inventing a default here would be a constant of the conformer's own
#       that nothing holds equal to an authored value.
#
#   (b) A DEPLOY ASSERTING "THE NEW REVISION TOOK TRAFFIC". Cloud Run's SERVICE
#       resource answers this EXACTLY and SYNCHRONOUSLY through its `traffic`
#       status, which the deploy graph already reads. A metric would be a
#       lagging, sampled restatement of a fact already held — strictly worse, and
#       wrong for ~26 minutes.
#
#   (c) "IS THIS SERVICE HEALTHY" AS A GATE. An `http_check` step answers it
#       directly, now, from the caller's own observation: the MEASURED status is
#       the oracle, and a logged or metered one is compared AGAINST it.
#
#   (d) AN OPERATOR-FACING `kci metrics` VERB. ⛔ The LOGS half did NOT get a
#       verb; it became an enrichment on a seam that already existed and was
#       already being called. A metrics verb would be the first of its kind,
#       built on no measured need.
#
# ⇒ ⛔ SO THE LIBRARY HALF IS BUILT AND NOTHING CALLS IT. What that buys, and it
#   is not nothing: the CAPABILITY is REACHABLE from the release tool's
#   libraries, every request shape and refusal is PINNED by a hermetic
#   falsifier, and the two measurements above are written down IN THE CODE that
#   the first real consumer will read, instead of being re-derived as a flake.
#
# ── §4 — ⭐ WHAT WOULD FLIP THIS, STATED SO IT IS FALSIFIABLE ──────────────
# Wire a conformer the day ANY of these is true — not before:
#   1. A bundle AUTHORS a threshold (a `validate` step declaring a metric, a
#      window and a bound). Then the gate has a number that is not ours.
#   2. The `timeSeries.list` stall is FIXED (the standing suspect is the TLS 1.3
#      KeyUpdate at ~1 MiB) AND the read moves off the Cloud Run Job path.
#   3. A question arrives that genuinely has no synchronous answer — a
#      RETROSPECTIVE one ("what did this workload do during the incident
#      window"), which is the shape metrics are actually good at and which no
#      deploy gate asks.
#
# ⛔ NO SOCKET IS NAMED HERE, and that is load-bearing exactly as it is in the
# logs package: the transport is a trait, so every query shape, refusal and
# parse branch — on BOTH clouds — is provable with zero network. A dep on an
# HTTP client here would put a TLS stack on the `-I` line of every consumer.
# =============================================================================

from komira_cloud_metrics.cloud_metric_source import (
    DEFAULT_METRIC_ALIGNER,
    DEFAULT_METRIC_ALIGNMENT_PERIOD,
    CloudMetricSource,
    MetricPage,
    MetricPoint,
    MetricSeries,
    MetricWindow,
    NoCloudMetricSource,
    ScriptedCloudMetricSource,
)
from komira_cloud_metrics.metric_json import (
    json_scan_scalar_text,
    parse_f64,
    urlencode_query_component,
)
from komira_cloud_metrics.gcp_monitoring_query import (
    GCP_TIMESERIES_FIELD_ALLOWLIST,
    MONITORING_HOST,
    parse_timeseries_body,
    run_service_metric_filter,
    service_leaf,
    service_project,
    timeseries_path,
    timeseries_query,
)
from komira_cloud_metrics.aws_cloudwatch_metrics_query import (
    AWS_METRIC_RESULT_FIELD_ALLOWLIST,
    CLOUDWATCH_METRICS_SERVICE,
    CLOUDWATCH_METRICS_TARGET,
    cloudwatch_metrics_host,
    ecs_service_cluster,
    ecs_service_name,
    get_metric_data_body,
    parse_get_metric_data_body,
)
