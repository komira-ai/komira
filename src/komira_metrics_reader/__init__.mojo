# =============================================================================
# komira_metrics_reader — read a service's metrics back, from wherever they
#   are kept.
# =============================================================================
#
# The read seam for metrics, the sibling of komira_log_query for logs: a
# trait a storage- or provider-specific reader conforms to, and an HTTP route a
# service mounts to answer metric queries over it.
#
# ── WHAT IS IN HERE ─────────────────────────────────────────────────────────
#   query.mojo   `MetricsQuery` (a window, a metric, label matchers, an
#                aggregation over steps, group-by keys, two limits),
#                `MetricsMatcher`, `MetricsAggregation`.
#   series.mojo  `MetricsPage` / `MetricsSeriesData` / `MetricsSample` /
#                `MetricsLabel`: series with nanosecond times and Float64
#                values, oldest first.
#   reader.mojo  `MetricsReader` (`refusal` + `read`), `ErasedMetricsReader`
#                (the non-generic facade a service holds as one field) and
#                `ScriptedMetricsReader` (the double).
#   access.mojo  `MetricsReadAccess`, `DenyMetricsReads`,
#                `MetricsHeaderTokenAccess`.
#   route.mojo   `GET <path>`: the match, the access check, the argument
#                checks, the reader's refusal, the read, the JSON render.
#
# ── THE READERS ─────────────────────────────────────────────────────────────
# None ships here. `komira_aws_metrics` reads CloudWatch, `komira_gcp_monitoring`
# reads Cloud Monitoring; a reader over metric files a service writes to an
# object store conforms to the same trait. Each is its own package, so a
# service that mounts the route links only the reader it wires.
#
# ⛔ DO NOT ADD A CLOUD SDK, A STORAGE OR A SEARCH LIBRARY TO THIS PACKAGE'S
# DEPS. It is a leaf on komira_http_core; the moment one appears, every
# service that mounts the route links it.
#
# It reads no env and no clock: the embedding service supplies the mount
# path, the access hook, the reader and the current time.
# =============================================================================

from komira_metrics_reader.query import (
    MetricsAggregation,
    MetricsMatcher,
    MetricsQuery,
)
from komira_metrics_reader.series import (
    MetricsLabel,
    MetricsPage,
    MetricsSample,
    MetricsSeriesData,
)
from komira_metrics_reader.reader import (
    ErasedMetricsReader,
    MetricsReader,
    ScriptedMetricsReader,
)
from komira_metrics_reader.access import (
    DenyMetricsReads,
    MetricsHeaderTokenAccess,
    MetricsReadAccess,
)
from komira_metrics_reader.route import (
    METRICS_AGG_PARAM,
    METRICS_DEFAULT_LOOKBACK_MS,
    METRICS_DEFAULT_POINT_LIMIT,
    METRICS_DEFAULT_SERIES_LIMIT,
    METRICS_DEFAULT_STEP_MS,
    METRICS_GROUP_BY_PARAM,
    METRICS_LABEL_PREFIX,
    METRICS_MAX_POINT_LIMIT,
    METRICS_MAX_SERIES_LIMIT,
    METRICS_METRIC_PARAM,
    METRICS_NOT_LABEL_PREFIX,
    METRICS_POINT_LIMIT_PARAM,
    METRICS_SERIES_LIMIT_PARAM,
    METRICS_SINCE_PARAM,
    METRICS_STEP_PARAM,
    METRICS_UNTIL_PARAM,
    is_metrics_request,
    metrics_response,
)
