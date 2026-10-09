# =============================================================================
# kci_logs/tests/test_run_log_scan_refusals.mojo — the run-log body parse:
#   whitespace, escapes, skipped non-listed values of every JSON shape, and
#   EVERY refusal, asserted on the exact fault sentence.
# =============================================================================
#
# `parse_run_logs_body` walks a `{"run_id":..,"lines":[..],..}` body with its
# own module-private scanner (`run_log_tail.mojo` depends on nothing in the
# cloud half). A refusal that turned lenient would print a record the body
# did not hold; a skip that miscounted a brace inside a string would end an
# object early and either refuse a good body or read a value as a key.
#
#   P1  a body with whitespace around every token, escapes `\n` `\r` `\t`
#       `\"` in a message, and non-listed keys whose values are an object
#       holding a `}` inside a string, an array, `true` and `null`, parses to
#       exactly the listed fields; a body with records and no `next_cursor`
#       takes the last record's `seq` as its cursor.
#   P2  the top-level refusals: `"lines"` only as a VALUE, `lines` not an
#       array, an unterminated `lines` array.
#   P3  every per-record refusal, at its byte and after its count of good
#       records: not an object, unterminated object, a non-string key, a key
#       with no `:`, a non-number `seq` / `ts`, a non-string `level` / `step`
#       / `message`, a backslash or a string cut at the end, and a non-listed
#       value that cannot be skipped (absent, unterminated nested string,
#       unclosed array).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_logs import parse_run_logs_body


def _refused(body: String, at: Int, good: Int, what: String) raises:
    var t = parse_run_logs_body(body, String("hint"))
    assert_false(t.ok(), String("must refuse: ") + what)
    assert_equal(len(t.records), 0, what)
    assert_equal(
        t.fetch_error,
        String("malformed log-line object at byte ")
        + String(at)
        + String(" of ")
        + String(body.byte_length())
        + String(", after ")
        + String(good)
        + String(" good record(s) (body NOT echoed)"),
        what,
    )


def test_whitespace_escapes_and_skipped_shapes() raises:
    var body = String(
        '{ "run_id" : "r1" ,\n "lines" : [\n'
        ' { "seq" : 1 , "message" : "a\\nb\\rc\\td\\"e" ,'
        ' "extra" : { "k" : [ "}]" , 1 ] } , "flag" : true , "n" : null } ,\r\n'
        '\t{"seq":2,"ts":-5,"level":"warn","step":"s","skip":[1,{"a":2}],'
        '"last":false,"message":"m"} ] }'
    )
    var t = parse_run_logs_body(body, String("hint"))
    assert_true(t.ok(), t.fetch_error)
    assert_equal(t.run_id, String("r1"), "the body's run id wins")
    assert_equal(len(t.records), 2, "two records, nothing more")
    assert_equal(t.records[0].seq, 1)
    assert_equal(t.records[0].message, String('a\nb\rc\td"e'))
    assert_equal(t.records[0].level, String(""), "nothing listed was invented")
    assert_equal(t.records[1].seq, 2)
    assert_equal(t.records[1].ts, -5)
    assert_equal(t.records[1].level, String("warn"))
    assert_equal(t.records[1].step, String("s"))
    assert_equal(t.records[1].message, String("m"))
    assert_equal(t.next_cursor, 2, "no `next_cursor`: the last seq read")
    assert_false(t.done)


def test_top_level_refusals() raises:
    var value_only = String('{"x":"lines"}')
    var a = parse_run_logs_body(value_only, String("hint"))
    assert_false(a.ok())
    assert_equal(
        a.fetch_error,
        String("the 200 body has no `lines` array (13 bytes read; body NOT echoed)"),
    )
    var not_array = String('{"lines":{}}')
    var b = parse_run_logs_body(not_array, String("hint"))
    assert_false(b.ok())
    assert_equal(
        b.fetch_error,
        String("`lines` is not an array at byte 9 of 12 (body NOT echoed)"),
    )
    var open = String('{"lines":[{"seq":1}')
    var c = parse_run_logs_body(open, String("hint"))
    assert_false(c.ok())
    assert_equal(len(c.records), 0, "a refused tail carries no records")
    assert_equal(
        c.fetch_error,
        String(
            "unterminated `lines` array after 1 record(s), at byte 19 of 19"
            " (body NOT echoed)"
        ),
    )


def test_record_refusals() raises:
    _refused(String('{"lines":[1]}'), 10, 0, "not an object")
    _refused(String('{"lines":[{"seq":1'), 10, 0, "unterminated object")
    _refused(String('{"lines":[{1:2}]}'), 10, 0, "a key that is not a string")
    _refused(String('{"lines":[{"seq" 1}]}'), 10, 0, "no colon")
    _refused(String('{"lines":[{"seq":"1"}]}'), 10, 0, "a string seq")
    _refused(String('{"lines":[{"ts":-}]}'), 10, 0, "a sign with no digit")
    _refused(String('{"lines":[{"level":1}]}'), 10, 0, "a numeric level")
    _refused(String('{"lines":[{"step":1}]}'), 10, 0, "a numeric step")
    _refused(String('{"lines":[{"message":1}]}'), 10, 0, "a numeric message")
    _refused(String('{"lines":[{"message":"ab\\'), 10, 0, "a trailing backslash")
    _refused(String('{"lines":[{"message":"ab'), 10, 0, "an unterminated string")
    _refused(String('{"lines":[{"extra":'), 10, 0, "a key with no value")
    _refused(String('{"lines":[{"extra":{"k":"open'), 10, 0, "an open nested string")
    _refused(String('{"lines":[{"extra":[1,[2]'), 10, 0, "an unclosed array")
    _refused(String('{"lines":[{"seq":1},2]}'), 20, 1, "after one good record")


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    try:
        f()
        print("PASS", name)
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("test_whitespace_escapes_and_skipped_shapes", test_whitespace_escapes_and_skipped_shapes, failed)
    _run("test_top_level_refusals", test_top_level_refusals, failed)
    _run("test_record_refusals", test_record_refusals, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("test_run_log_scan_refusals: ALL 3 CASES PASS")
