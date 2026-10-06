# =============================================================================
# komira_gcp_monitoring — read a project's Cloud Monitoring metrics through
#   the komira_metrics_reader seam.
# =============================================================================
#
#   time_series_list.mojo  `projects.timeSeries.list`, pure: the path and
#                          query (`time_series_list_path`,
#                          `time_series_list_query`), the filter
#                          (`monitoring_filter`, values quoted, label keys
#                          refused unless plain identifiers), and the
#                          response parse (`parse_time_series_list_response`).
#   reader.mojo            `CloudMonitoringMetricsReader`, a `MetricsReader`
#                          for one project, sending each GET through
#                          komira_http_client with a bearer token from a
#                          komira_gcp_core token source.
#
# Hand-written, not generated: ListTimeSeries is a GET whose query carries a
# Timestamp and a Duration, which the REST generator does not yet render
# (time_series_list.mojo says where, and what would change it).
#
# It reads no environment: the project, the host, the connector and the
# token source are the caller's.
# =============================================================================

from komira_gcp_monitoring.time_series_list import (
    LIST_TIME_SERIES_MAX_PAGE_SIZE,
    LIST_TIME_SERIES_RPC,
    MONITORING_DEFAULT_HOST,
    MONITORING_MIN_ALIGNMENT_S,
    RESOURCE_LABEL_PREFIX,
    MonitoringSeries,
    TimeSeriesListPage,
    TimeSeriesListRequest,
    filter_label_selector,
    group_by_field,
    label_key_refusal,
    monitoring_filter,
    ns_of_rfc3339,
    parse_time_series_list_response,
    percent_encode,
    quote_filter_string,
    rfc3339_of_ns,
    time_series_list_path,
    time_series_list_query,
)
from komira_gcp_monitoring.reader import (
    MONITORING_DEFAULT_MAX_PAGES,
    CloudMonitoringMetricsReader,
    monitoring_aligner,
    monitoring_reducer,
)
