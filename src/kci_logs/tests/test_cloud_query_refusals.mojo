# =============================================================================
# kci_logs/tests/test_cloud_query_refusals.mojo — both cloud arms' request
#   escaping, continuation tokens and EVERY parse refusal, asserted on the
#   exact fault sentence.
# =============================================================================
#
# A parse that tolerated a malformed value would turn a body it cannot read
# into a page of plausible entries (or an "empty stream"), and an operator
# would read that as what the container printed. Each refusal below asserts
# the page is NOT ok, carries no entries, and names the byte where the scan
# stopped and the body length, with the body itself never echoed.
#
#   G1  `json_escape` escapes `"` `\` LF CR TAB and keeps other bytes.
#   G2  `parse_entries_list_body`: an empty body and a body whose only
#       `"entries"` is a VALUE are empty successes; whitespace around keys and
#       between entries is skipped; `nextPageToken` is carried (and a
#       non-string one is not).
#   G3  every refusal: `entries` not an array, unterminated array, an element
#       that is not an object, an unterminated object, a key with no `:`, a
#       non-string `textPayload` / `severity` / `timestamp`, and a value that
#       cannot be skipped.
#   A1  ECS handle arithmetic refusals: empty ARN, trailing `/`, and a stream
#       name refused when the ARN yields no task id.
#   A2  `get_log_events_body` escapes the group and the stream (`\` LF CR TAB)
#       and the forward token.
#   A3  `parse_get_log_events_body`: empty body, absent `events`, `"events"`
#       as a VALUE, two events separated by `,` kept in order with whitespace.
#   A4  every refusal, as G3, for the CloudWatch shape (`timestamp` must be a
#       number, `message` a string).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_logs.gcp_logging_query import json_escape, parse_entries_list_body
from kci_logs.aws_cloudwatch_query import (
    ecs_task_id,
    ecs_task_log_stream,
    get_log_events_body,
    parse_get_log_events_body,
)


def _gcp_refused(body: String, at: Int, what: String) raises:
    var p = parse_entries_list_body(body, String("h"))
    assert_false(p.ok(), String("must refuse: ") + what)
    assert_equal(len(p.entries), 0, what)
    assert_equal(
        p.fault,
        String("malformed log entry at byte ")
        + String(at)
        + String(" of a ")
        + String(body.byte_length())
        + String("-byte body (NOT echoed)"),
        what,
    )


def _aws_refused(body: String, at: Int, what: String) raises:
    var p = parse_get_log_events_body(body)
    assert_false(p.ok(), String("must refuse: ") + what)
    assert_equal(len(p.entries), 0, what)
    assert_equal(
        p.fault,
        String("malformed log event at byte ")
        + String(at)
        + String(" of a ")
        + String(body.byte_length())
        + String("-byte body (NOT echoed)"),
        what,
    )


# =============================================================================
# GCP
# =============================================================================
def test_gcp_json_escape_every_arm() raises:
    assert_equal(
        json_escape(String('a"b\\c\nd\re\tf/é')),
        String('a\\"b\\\\c\\nd\\re\\tf/é'),
    )


def test_gcp_parse_tokens_whitespace_and_empty() raises:
    var empty = parse_entries_list_body(String(""), String("h"))
    assert_true(empty.ok(), empty.fault)
    assert_equal(len(empty.entries), 0)
    assert_equal(empty.next_token, String(""))

    var value_only = parse_entries_list_body(
        String('{"note":"entries"}'), String("h")
    )
    assert_true(value_only.ok(), "a value spelled `entries` is not the key")
    assert_equal(len(value_only.entries), 0)

    var body = String(
        '{ "entries" : [ { "textPayload" : "one" } ,\n'
        '\t{"textPayload":"two","severity":"ERROR"} ] ,'
        ' "nextPageToken" : "tok/1" }'
    )
    var p = parse_entries_list_body(body, String("h"))
    assert_true(p.ok(), p.fault)
    assert_equal(len(p.entries), 2, "both entries, across `,` and whitespace")
    assert_equal(p.entries[0].text, String("one"))
    assert_equal(p.entries[1].text, String("two"))
    assert_equal(p.entries[1].severity, String("ERROR"))
    assert_equal(p.next_token, String("tok/1"), "the continuation is carried")

    var numeric_tok = parse_entries_list_body(
        String('{"nextPageToken":7}'), String("h")
    )
    assert_true(numeric_tok.ok(), numeric_tok.fault)
    assert_equal(numeric_tok.next_token, String(""), "a non-string token is no token")


def test_gcp_array_refusals() raises:
    var not_array = String('{"entries":{}}')
    var p = parse_entries_list_body(not_array, String("h"))
    assert_false(p.ok())
    assert_equal(
        p.fault,
        String("`entries` was not an array at byte 11 of a 14-byte body (NOT echoed)"),
    )
    var open = String('{"entries":[{"textPayload":"x"}')
    var q = parse_entries_list_body(open, String("h"))
    assert_false(q.ok())
    assert_equal(
        q.fault,
        String("unterminated `entries` array in a ")
        + String(open.byte_length())
        + String("-byte body (NOT echoed)"),
    )
    assert_equal(len(q.entries), 0, "a refused page carries no entries")


def test_gcp_entry_refusals() raises:
    _gcp_refused(String('{"entries":[1]}'), 12, "an element that is not an object")
    _gcp_refused(String('{"entries":[{"textPayload":"x"'), 12, "unterminated object")
    _gcp_refused(String('{"entries":[{"textPayload" "x"}]}'), 12, "no colon")
    _gcp_refused(String('{"entries":[{"textPayload":1}]}'), 12, "numeric text")
    _gcp_refused(String('{"entries":[{"severity":1}]}'), 12, "numeric severity")
    _gcp_refused(String('{"entries":[{"timestamp":1}]}'), 12, "numeric timestamp")
    _gcp_refused(String('{"entries":[{"labels":"open'), 12, "unskippable value")


# =============================================================================
# AWS
# =============================================================================
def test_aws_handle_refusals() raises:
    assert_equal(ecs_task_id(String("")), String(""), "empty ARN")
    assert_equal(
        ecs_task_id(String("arn:aws:ecs:r:1:task/cluster/")),
        String(""),
        "a trailing `/` names no task",
    )
    assert_equal(
        ecs_task_log_stream(
            String("ecs"), String("app"), String("arn:aws:ecs:r:1:task/c/")
        ),
        String(""),
        "no task id, no stream name",
    )


def test_aws_request_escapes() raises:
    assert_equal(
        get_log_events_body(
            String('/ecs/f"x'), String("p\\a\nb\rc\td"), 5, String('f/1"2')
        ),
        String(
            '{"logGroupName":"/ecs/f\\"x","logStreamName":"p\\\\a\\nb\\rc\\td",'
            '"limit":5,"nextToken":"f/1\\"2","startFromHead":true}'
        ),
    )


def test_aws_parse_tokens_whitespace_and_empty() raises:
    var empty = parse_get_log_events_body(String(""))
    assert_true(empty.ok(), empty.fault)
    assert_equal(len(empty.entries), 0)

    var no_events = parse_get_log_events_body(
        String('{"nextForwardToken":"f/9"}')
    )
    assert_true(no_events.ok(), no_events.fault)
    assert_equal(len(no_events.entries), 0)
    assert_equal(no_events.next_token, String("f/9"))

    var value_only = parse_get_log_events_body(String('{"note":["events"]}'))
    assert_true(value_only.ok(), "a value spelled `events` is not the key")
    assert_equal(len(value_only.entries), 0)

    var body = String(
        '{ "events" : [ { "timestamp" : 1789200000000 , "message" : "one" ,'
        ' "ingestionTime" : 1789200000123 } ,\n'
        '\t{"message":"two","timestamp":1789200000001} ] }'
    )
    var p = parse_get_log_events_body(body)
    assert_true(p.ok(), p.fault)
    assert_equal(len(p.entries), 2, "both events, across `,` and whitespace")
    assert_equal(p.entries[0].text, String("one"))
    assert_equal(p.entries[0].timestamp, String("1789200000000"))
    assert_equal(p.entries[1].text, String("two"))
    assert_equal(p.entries[1].timestamp, String("1789200000001"))


def test_aws_array_refusals() raises:
    var not_array = String('{"events":{}}')
    var p = parse_get_log_events_body(not_array)
    assert_false(p.ok())
    assert_equal(
        p.fault,
        String("`events` was not an array at byte 10 of a 13-byte body (NOT echoed)"),
    )
    var open = String('{"events":[{"message":"x"}')
    var q = parse_get_log_events_body(open)
    assert_false(q.ok())
    assert_equal(
        q.fault,
        String("unterminated `events` array in a ")
        + String(open.byte_length())
        + String("-byte body (NOT echoed)"),
    )
    assert_equal(len(q.entries), 0, "a refused page carries no entries")


def test_aws_event_refusals() raises:
    _aws_refused(String('{"events":[1]}'), 11, "an element that is not an object")
    _aws_refused(String('{"events":[{"message":"x"'), 11, "unterminated object")
    _aws_refused(String('{"events":[{1:2}]}'), 11, "a key that is not a string")
    _aws_refused(String('{"events":[{"message" "x"}]}'), 11, "no colon")
    _aws_refused(String('{"events":[{"message":1}]}'), 11, "numeric message")
    _aws_refused(String('{"events":[{"timestamp":"x"}]}'), 11, "string timestamp")
    _aws_refused(String('{"events":[{"logStreamName":"open'), 11, "unskippable value")


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    try:
        f()
        print("PASS", name)
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("test_gcp_json_escape_every_arm", test_gcp_json_escape_every_arm, failed)
    _run("test_gcp_parse_tokens_whitespace_and_empty", test_gcp_parse_tokens_whitespace_and_empty, failed)
    _run("test_gcp_array_refusals", test_gcp_array_refusals, failed)
    _run("test_gcp_entry_refusals", test_gcp_entry_refusals, failed)
    _run("test_aws_handle_refusals", test_aws_handle_refusals, failed)
    _run("test_aws_request_escapes", test_aws_request_escapes, failed)
    _run("test_aws_parse_tokens_whitespace_and_empty", test_aws_parse_tokens_whitespace_and_empty, failed)
    _run("test_aws_array_refusals", test_aws_array_refusals, failed)
    _run("test_aws_event_refusals", test_aws_event_refusals, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("test_cloud_query_refusals: ALL 9 CASES PASS")
