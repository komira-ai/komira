# The GetMetricData request body, byte for byte, and the builder's refusals.
#
# The expected bodies are written here from the CloudWatch API reference for
# GetMetricData (awsJson 1.0): one MetricDataQuery with a MetricStat, epoch
# seconds for StartTime and EndTime, ScanBy stated newest first, MaxDatapoints,
# and NextToken only on a continued read. A dimension value holding a quote
# is escaped, not spliced. An ECS service ARN gives ClusterName and
# ServiceName, and the cluster-less ARN form is refused.

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_metrics import (
    CloudWatchDimension,
    CloudWatchMetricStat,
    build_get_metric_data_body,
    cloudwatch_period_ok,
    ecs_service_dimensions,
)


def _stat(period_s: Int = 60) raises -> CloudWatchMetricStat:
    return CloudWatchMetricStat(
        String("AWS/ECS"),
        String("CPUUtilization"),
        ecs_service_dimensions(
            String("arn:aws:ecs:us-east-1:111122223333:service/prod/api")
        ),
        period_s,
        String("Average"),
    )


def test_first_page_body() raises:
    var body = build_get_metric_data_body(
        _stat(), Int64(1789120800), Int64(1789207200), 1440, String("")
    )
    assert_equal(
        body,
        String(
            '{"StartTime":1789120800,"EndTime":1789207200,"MetricDataQueries":'
            '[{"Id":"m1","MetricStat":{"Metric":{"Namespace":"AWS/ECS",'
            '"MetricName":"CPUUtilization","Dimensions":[{"Name":"ClusterName",'
            '"Value":"prod"},{"Name":"ServiceName","Value":"api"}]},"Period":60,'
            '"Stat":"Average"},"ReturnData":true}],"ScanBy":"TimestampDescending",'
            '"MaxDatapoints":1440}'
        ),
    )


def test_next_page_carries_the_token() raises:
    var body = build_get_metric_data_body(
        _stat(300), Int64(10), Int64(20), 5, String("tok/+=")
    )
    assert_true(body.endswith(',"MaxDatapoints":5,"NextToken":"tok/+="}'), body)
    assert_true('"Period":300' in body, body)


def test_a_quote_in_a_dimension_is_escaped() raises:
    var dims = List[CloudWatchDimension]()
    dims.append(CloudWatchDimension(String("Route"), String('a"b\\c')))
    var stat = CloudWatchMetricStat(
        String("Custom"), String("Hits"), dims^, 60, String("Sum")
    )
    var body = build_get_metric_data_body(stat, Int64(0), Int64(60), 1, String(""))
    assert_true('{"Name":"Route","Value":"a\\"b\\\\c"}' in body, body)


def test_builder_refusals() raises:
    with assert_raises(contains="period of 90 s"):
        _ = build_get_metric_data_body(_stat(90), Int64(0), Int64(60), 1, String(""))
    with assert_raises(contains="is empty"):
        _ = build_get_metric_data_body(_stat(), Int64(60), Int64(60), 1, String(""))
    with assert_raises(contains="MaxDatapoints 0"):
        _ = build_get_metric_data_body(_stat(), Int64(0), Int64(60), 0, String(""))
    with assert_raises(contains="MaxDatapoints 100801"):
        _ = build_get_metric_data_body(_stat(), Int64(0), Int64(60), 100801, String(""))
    var empty_ns = CloudWatchMetricStat(
        String(""), String("m"), List[CloudWatchDimension](), 60, String("Sum")
    )
    with assert_raises(contains="namespace is empty"):
        _ = build_get_metric_data_body(empty_ns, Int64(0), Int64(60), 1, String(""))
    var empty_dim = List[CloudWatchDimension]()
    empty_dim.append(CloudWatchDimension(String("k"), String("")))
    var bad_dim = CloudWatchMetricStat(
        String("n"), String("m"), empty_dim^, 60, String("Sum")
    )
    with assert_raises(contains="empty name or value"):
        _ = build_get_metric_data_body(bad_dim, Int64(0), Int64(60), 1, String(""))
    var many = List[CloudWatchDimension]()
    for i in range(31):
        many.append(CloudWatchDimension(String("d") + String(i), String("v")))
    var too_many = CloudWatchMetricStat(
        String("n"), String("m"), many^, 60, String("Sum")
    )
    with assert_raises(contains="31 dimensions"):
        _ = build_get_metric_data_body(too_many, Int64(0), Int64(60), 1, String(""))


def test_periods() raises:
    for p in [1, 5, 10, 20, 30, 60, 120, 3600, 86400]:
        assert_true(cloudwatch_period_ok(p), String(p))
    for p in [0, -60, 2, 15, 25, 40, 45, 61, 90]:
        assert_false(cloudwatch_period_ok(p), String(p))


def test_ecs_service_dimensions() raises:
    var d = ecs_service_dimensions(
        String("arn:aws:ecs:eu-west-1:111122223333:service/blue/web-1")
    )
    assert_equal(len(d), 2)
    assert_equal(d[0].name, String("ClusterName"))
    assert_equal(d[0].value, String("blue"))
    assert_equal(d[1].name, String("ServiceName"))
    assert_equal(d[1].value, String("web-1"))
    with assert_raises(contains="without a cluster"):
        _ = ecs_service_dimensions(
            String("arn:aws:ecs:eu-west-1:111122223333:service/web-1")
        )
    with assert_raises(contains="not an ECS service ARN"):
        _ = ecs_service_dimensions(String("projects/p/services/s"))
    with assert_raises(contains="names no service"):
        _ = ecs_service_dimensions(
            String("arn:aws:ecs:eu-west-1:111122223333:service/blue/")
        )


def main() raises:
    test_first_page_body()
    test_next_page_carries_the_token()
    test_a_quote_in_a_dimension_is_escaped()
    test_builder_refusals()
    test_periods()
    test_ecs_service_dimensions()
    print("OK")
