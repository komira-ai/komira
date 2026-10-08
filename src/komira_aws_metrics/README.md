# komira_aws_metrics

Reads a workload's Amazon CloudWatch metrics through the
komira_metrics_reader seam. Hand-written, not generated: it sends one
operation, GetMetricData, over awsJson 1.0.

- `get_metric_data.mojo` is pure: `build_get_metric_data_body` writes the
  request body for one `CloudWatchMetricStat` (namespace, metric, dimensions,
  period, statistic) over a window, newest first; `parse_get_metric_data_response`
  decodes a page (`CloudWatchPage` of `CloudWatchResult`s and its
  `next_token`); `ecs_service_dimensions` turns an ECS service ARN into its
  `ClusterName` and `ServiceName` dimensions; `cloudwatch_period_ok` says
  whether GetMetricData accepts a period; `get_metric_data_error` turns a
  failed answer into an error.
- `CloudWatchMetricsReader` is a `MetricsReader` for one namespace and a fixed
  set of dimensions. It maps a `MetricsQuery` to GetMetricData, refuses what
  CloudWatch cannot answer (raw points, `group_by`, negated matchers, a step
  that is not an accepted period) before any call, follows `NextToken` up to
  a page limit, and signs (signing name `monitoring`) and sends each call
  through komira_aws_core over the transport it is given.
  `cloudwatch_endpoint(region)` is the regional endpoint.

The builder refuses, rather than sends, a request the service would reject
or answer with the wrong numbers: an empty namespace, metric or statistic,
too many dimensions, an unaccepted period, an empty window, a point limit out
of range. A response whose timestamps and values differ in length is
refused. No FIPS endpoint is offered. The package reads no environment.

## Examples

The request body for an ECS service's average CPU, one-minute periods:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_aws_metrics import CloudWatchMetricStat, build_get_metric_data_body
from komira_aws_metrics import ecs_service_dimensions

var stat = CloudWatchMetricStat(
    String("AWS/ECS"),
    String("CPUUtilization"),
    ecs_service_dimensions(String("arn:aws:ecs:us-east-1:111122223333:service/prod/api")),
    60,
    String("Average"),
)
var body = build_get_metric_data_body(stat, Int64(1789120800), Int64(1789207200), 1440, String(""))
assert_equal(
    body,
    String(
        '{"StartTime":1789120800,"EndTime":1789207200,"MetricDataQueries":'
        + '[{"Id":"m1","MetricStat":{"Metric":{"Namespace":"AWS/ECS",'
        + '"MetricName":"CPUUtilization","Dimensions":[{"Name":"ClusterName",'
        + '"Value":"prod"},{"Name":"ServiceName","Value":"api"}]},"Period":60,'
        + '"Stat":"Average"},"ReturnData":true}],"ScanBy":"TimestampDescending",'
        + '"MaxDatapoints":1440}'
    ),
)
```

What is refused before anything is sent:

```mojo
from komira_aws_metrics import CloudWatchDimension, cloudwatch_period_ok

assert_true(cloudwatch_period_ok(5))
assert_true(cloudwatch_period_ok(300))
assert_false(cloudwatch_period_ok(90))
# A service ARN without its cluster would match that name in every cluster.
with assert_raises(contains="without a cluster"):
    _ = ecs_service_dimensions(String("arn:aws:ecs:us-east-1:111122223333:service/api"))
var bad = CloudWatchMetricStat(
    String("AWS/ECS"), String("CPUUtilization"), List[CloudWatchDimension](), 90, String("Sum")
)
with assert_raises(contains="a period of 90 s"):
    _ = build_get_metric_data_body(bad, Int64(0), Int64(60), 1, String(""))
```

Decode a page of results; a mismatched pair of arrays is refused:

```mojo
from komira_aws_metrics import parse_get_metric_data_response

var page = parse_get_metric_data_response(
    String(
        '{"MetricDataResults":[{"Id":"m1","Label":"CPUUtilization",'
        + '"Timestamps":[1789120860,1789120800],"Values":[42.5,40.0],'
        + '"StatusCode":"Complete"}],"NextToken":"next/1"}'
    )
)
assert_equal(page.next_token, "next/1")
assert_equal(len(page.results), 1)
assert_equal(page.results[0].status_code, "Complete")
assert_equal(page.results[0].timestamps[0], Int64(1789120860))
assert_equal(page.results[0].values[0], 42.5)
with assert_raises(contains="has 2 timestamps and 1 values"):
    _ = parse_get_metric_data_response(
        String('{"MetricDataResults":[{"Id":"m1","Timestamps":[1,2],"Values":[3],"StatusCode":"Complete"}]}')
    )
```

The regional endpoint the reader is pointed at:

```mojo
from komira_aws_metrics import cloudwatch_endpoint

var endpoint = cloudwatch_endpoint(String("eu-west-1"))
assert_equal(endpoint.url_for(String("/")), "https://monitoring.eu-west-1.amazonaws.com/")
```
