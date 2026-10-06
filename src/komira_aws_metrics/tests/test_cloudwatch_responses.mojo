# GetMetricData responses and errors.
#
# The bodies are hand-written in the form the CloudWatch API reference
# documents for GetMetricData (awsJson 1.0). A result's parallel Timestamps
# and Values are read as numbers and must be the same length; NextToken and
# StatusCode are carried; Messages is not read; an empty or absent
# MetricDataResults is an answer with no results. A body that is not JSON, or
# not the documented shape, raises naming its size, never its bytes. A failed
# call's error carries the status, the query-compatible code CloudWatch names
# in `x-amzn-query-error`, the message and the request id.

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import HttpResult
from komira_aws_metrics import get_metric_data_error, parse_get_metric_data_response


def test_one_result_with_a_token() raises:
    var page = parse_get_metric_data_response(
        String(
            '{"MetricDataResults":[{"Id":"m1","Label":"CPUUtilization",'
            '"Timestamps":[1789120800,1789120860,1.78912092E9],'
            '"Values":[42.5,0,7],"StatusCode":"PartialData",'
            '"Messages":[{"Code":"x","Value":"secret-ish provider text"}]}],'
            '"NextToken":"next/1","Messages":[]}'
        )
    )
    assert_equal(page.next_token, String("next/1"))
    assert_equal(len(page.results), 1)
    ref r = page.results[0]
    assert_equal(r.id, String("m1"))
    assert_equal(r.label, String("CPUUtilization"))
    assert_equal(r.status_code, String("PartialData"))
    assert_equal(len(r.timestamps), 3)
    assert_equal(r.timestamps[0], Int64(1789120800))
    assert_equal(r.timestamps[2], Int64(1789120920))
    assert_equal(r.values[0], 42.5)
    assert_equal(r.values[1], 0.0)


def test_empty_answers() raises:
    var a = parse_get_metric_data_response(String('{"MetricDataResults":[]}'))
    assert_equal(len(a.results), 0)
    assert_equal(a.next_token, String(""))
    var b = parse_get_metric_data_response(String("{}"))
    assert_equal(len(b.results), 0)
    var c = parse_get_metric_data_response(
        String('{"MetricDataResults":[{"Id":"m1","StatusCode":"Complete"}]}')
    )
    assert_equal(len(c.results[0].timestamps), 0)


def test_parallel_arrays_must_agree() raises:
    with assert_raises(contains="has 2 timestamps and 1 values"):
        _ = parse_get_metric_data_response(
            String(
                '{"MetricDataResults":[{"Id":"m1","Timestamps":[1,2],'
                '"Values":[3],"StatusCode":"Complete"}]}'
            )
        )


def test_malformed_bodies_raise_without_echo() raises:
    var secret = String("<html>account 111122223333 is suspended</html>")
    try:
        _ = parse_get_metric_data_response(secret)
        raise Error("parsed a non-JSON body")
    except e:
        var msg = String(e)
        assert_true(msg.startswith("GetMetricData: the 46-byte response is not JSON"), msg)
        assert_false("111122223333" in msg, msg)
    with assert_raises(contains="not a JSON object"):
        _ = parse_get_metric_data_response(String("[1]"))
    with assert_raises(contains="MetricDataResults is not an array"):
        _ = parse_get_metric_data_response(String('{"MetricDataResults":{}}'))
    with assert_raises(contains="a value is not a number"):
        _ = parse_get_metric_data_response(
            String('{"MetricDataResults":[{"Timestamps":[1],"Values":["1"]}]}')
        )
    with assert_raises(contains="result 0 is not an object"):
        _ = parse_get_metric_data_response(String('{"MetricDataResults":[3]}'))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def test_error_shape() raises:
    var res = HttpResult(
        400,
        _bytes(
            '{"__type":"com.amazonaws.cloudwatch#InvalidParameterValueException",'
            '"message":"The parameter Period must be a multiple of 60."}'
        ),
    )
    res.add_header(
        String("x-amzn-query-error"), String("InvalidParameterValue;Sender")
    )
    res.add_header(String("x-amzn-RequestId"), String("6b2c-0001"))
    assert_equal(
        String(get_metric_data_error(res)),
        String(
            "GetMetricData failed: HTTP 400 InvalidParameterValue: The"
            " parameter Period must be a multiple of 60. (request id 6b2c-0001)"
        ),
    )


def test_error_code_from_the_body() raises:
    var res = HttpResult(
        403,
        _bytes('{"__type":"AccessDeniedException","Message":"denied"}'),
    )
    var msg = String(get_metric_data_error(res))
    assert_true(msg.startswith("GetMetricData failed: HTTP 403 AccessDeniedException"), msg)


def main() raises:
    test_one_result_with_a_token()
    test_empty_answers()
    test_parallel_arrays_must_agree()
    test_malformed_bodies_raise_without_echo()
    test_error_shape()
    test_error_code_from_the_body()
    print("OK")
