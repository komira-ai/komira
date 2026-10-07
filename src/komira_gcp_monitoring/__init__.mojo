# =============================================================================
# komira_gcp_monitoring — read a project's Cloud Monitoring metrics through
#   the komira_metrics_reader seam.
# =============================================================================
#
#   time_series_list.mojo  the adapter over the generated
#                          `MetricServiceClient.list_time_series`
#                          (komira_gcp_monitoring_client), pure: the request
#                          it builds and refuses (`list_time_series_request`,
#                          `time_series_list_name`), the filter
#                          (`monitoring_filter`, values quoted, label keys
#                          refused unless plain identifiers), and the page it
#                          reads from the response (`time_series_list_page`,
#                          `parse_time_series_list_response`).
#   reader.mojo            `CloudMonitoringMetricsReader`, a `MetricsReader`
#                          for one project, sending each GET through the
#                          generated client with a bearer token from a
#                          komira_gcp_core token source.
#
# It reads no environment: the project, the host, the connector and the
# token source are the caller's.
# =============================================================================

from komira_gcp_monitoring.time_series_list import (
    LIST_TIME_SERIES_MAX_PAGE_SIZE,
    MONITORING_DEFAULT_HOST,
    MONITORING_MIN_ALIGNMENT_S,
    RESOURCE_LABEL_PREFIX,
    MonitoringSeries,
    TimeSeriesListPage,
    TimeSeriesListRequest,
    filter_label_selector,
    group_by_field,
    label_key_refusal,
    list_time_series_request,
    monitoring_filter,
    ns_of_timestamp,
    parse_time_series_list_response,
    quote_filter_string,
    time_series_list_name,
    time_series_list_page,
    timestamp_of_ns,
)
from komira_gcp_monitoring.reader import (
    MONITORING_DEFAULT_MAX_PAGES,
    CloudMonitoringMetricsReader,
    monitoring_aligner,
    monitoring_reducer,
)
