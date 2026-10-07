# =============================================================================
# komira_aws_metrics — read a workload's CloudWatch metrics through the
#   komira_metrics_reader seam.
# =============================================================================
#
#   get_metric_data.mojo  GetMetricData, pure: the request body
#                         (`build_get_metric_data_body`), the response parse
#                         (`parse_get_metric_data_response`), the error
#                         (`get_metric_data_error`), the ECS service ARN's
#                         dimensions and the accepted periods.
#   reader.mojo           `CloudWatchMetricsReader`, a `MetricsReader` for one
#                         namespace and a fixed set of dimensions, signing and
#                         sending each call through komira_aws_core.
#
# Hand-written, not generated: generating the CloudWatch client into this
# package is a follow-up (get_metric_data.mojo says which protocol the AWS
# generator chooses from the model, and what changes when it lands).
#
# It reads no environment: the region, the endpoint, the credential source
# and the transport are the caller's.
# =============================================================================

from komira_aws_metrics.get_metric_data import (
    CLOUDWATCH_JSON_CONTENT_TYPE,
    CLOUDWATCH_MAX_DIMENSIONS,
    CLOUDWATCH_SIGNING_NAME,
    GET_METRIC_DATA_MAX_DATAPOINTS,
    GET_METRIC_DATA_TARGET,
    CloudWatchDimension,
    CloudWatchMetricStat,
    CloudWatchPage,
    CloudWatchResult,
    build_get_metric_data_body,
    cloudwatch_period_ok,
    ecs_service_dimensions,
    get_metric_data_error,
    parse_get_metric_data_response,
)
from komira_aws_metrics.reader import (
    CLOUDWATCH_DEFAULT_MAX_PAGES,
    CloudWatchMetricsReader,
    cloudwatch_endpoint,
    cloudwatch_stat,
)
