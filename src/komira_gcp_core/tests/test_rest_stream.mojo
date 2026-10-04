# =============================================================================
# test_rest_stream.mojo — a REST server-stream body, and the code read back
# out of a REST client's error.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_gcp_core import (
    CODE_ABORTED,
    CODE_ALREADY_EXISTS,
    CODE_NOT_FOUND,
    gcp_rest_stream_items,
    gcp_status_error,
    gcp_status_error_code,
    gcp_status_error_unlabelled,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _items(body: String) raises -> List[String]:
    return gcp_rest_stream_items(
        String("POST"), String("RunQuery"), 200, _bytes(body)
    )


def _raised(body: String) -> String:
    try:
        _ = _items(body)
    except e:
        return String(e)
    return String("")


def test_elements_in_order_as_written() raises:
    var got = _items(
        String('[{"a":"x,y]"},\n  {"b":[1,{"c":"\\"}"}]} , {"readTime":"t"}]')
    )
    assert_equal(len(got), 3)
    assert_equal(got[0], String('{"a":"x,y]"}'))
    assert_equal(got[1], String('{"b":[1,{"c":"\\"}"}]}'))
    assert_equal(got[2], String('{"readTime":"t"}'))


def test_empty_stream() raises:
    assert_equal(len(_items(String("[]"))), 0)
    assert_equal(len(_items(String("  [ \n ] "))), 0)


def test_scalar_elements_are_kept_whole() raises:
    var got = _items(String("[1, true ,null,\"s\"]"))
    assert_equal(len(got), 4)
    assert_equal(got[0], String("1"))
    assert_equal(got[1], String("true"))
    assert_equal(got[2], String("null"))
    assert_equal(got[3], String('"s"'))


def test_error_element_raises_as_a_status_error() raises:
    # A failure after the 200 was sent: the last element is the envelope.
    var body = String(
        '[{"readTime":"t"},{"error":{"code":409,"status":"ABORTED",'
        + '"message":"secret-resource-name"}}]'
    )
    var err = _raised(body)
    var expect = String(
        gcp_status_error(
            String("POST"),
            String("RunQuery"),
            200,
            _bytes(
                String(
                    '{"error":{"code":409,"status":"ABORTED",'
                    + '"message":"secret-resource-name"}}'
                )
            ),
        )
    )
    assert_equal(err, expect)
    assert_false(String("secret") in err)
    assert_equal(
        gcp_status_error_code(String("POST"), String("RunQuery"), err),
        CODE_ABORTED,
    )


def test_a_body_that_is_not_an_array_is_refused_by_its_size() raises:
    var cases = List[String]()
    cases.append(String(""))
    cases.append(String("   "))
    cases.append(String('{"error":{"status":"NOT_FOUND"}}'))
    cases.append(String('[{"a":"secret"'))
    cases.append(String('[{"a":"secret"}] trailing'))
    cases.append(String('"secret"'))
    for c in cases:
        var err = _raised(c)
        assert_true(String("is not a JSON array") in err)
        assert_true(
            String("body ") + String(c.byte_length()) + String(" bytes") in err
        )
        assert_false(String("secret") in err)


def test_error_code_reads_back_a_rest_error() raises:
    var err = String(
        gcp_status_error(
            String("POST"),
            String("Commit"),
            409,
            _bytes(String('{"error":{"code":409,"status":"ALREADY_EXISTS"}}')),
        )
    )
    assert_equal(
        gcp_status_error_code(String("POST"), String("Commit"), err),
        CODE_ALREADY_EXISTS,
    )
    # No envelope: the code comes from the HTTP status.
    var bare = String(
        gcp_status_error(String("POST"), String("Commit"), 404, List[UInt8]())
    )
    assert_equal(
        gcp_status_error_code(String("POST"), String("Commit"), bare),
        CODE_NOT_FOUND,
    )


def test_error_code_refuses_anything_else() raises:
    var err = String(
        gcp_status_error(String("POST"), String("Commit"), 404, List[UInt8]())
    )
    # Another method, another verb.
    assert_equal(gcp_status_error_code(String("POST"), String("RunQuery"), err), -1)
    assert_equal(gcp_status_error_code(String("GET"), String("Commit"), err), -1)
    # A transport error raised before any response.
    assert_equal(
        gcp_status_error_code(
            String("POST"), String("Commit"), String("connect refused (code 5)")
        ),
        -1,
    )
    # A name that does not match the code.
    assert_equal(
        gcp_status_error_code(
            String("POST"),
            String("Commit"),
            String("POST Commit: HTTP 404, ABORTED (code 5)"),
        ),
        -1,
    )
    assert_equal(
        gcp_status_error_code(
            String("POST"),
            String("Commit"),
            String("POST Commit: HTTP 404, NOT_FOUND (code 5"),
        ),
        -1,
    )


def test_unlabelled_says_whether_the_body_named_a_status() raises:
    # The rendered line is komira_gcp_core's own; this pins the three forms a
    # body that named no status takes, and that a named one is labelled.
    var labelled = String(
        gcp_status_error(
            String("POST"),
            String("Commit"),
            409,
            _bytes(String('{"error":{"code":409,"status":"ABORTED"}}')),
        )
    )
    assert_false(
        gcp_status_error_unlabelled(String("POST"), String("Commit"), labelled),
        labelled,
    )
    var bodies = List[String]()
    bodies.append(String(""))  # no envelope
    bodies.append(String("not json"))
    bodies.append(String('{"error":{"code":409,"status":"lower-case"}}'))
    for b in bodies:
        var err = String(
            gcp_status_error(String("POST"), String("Commit"), 409, _bytes(b))
        )
        assert_true(
            gcp_status_error_unlabelled(String("POST"), String("Commit"), err),
            err,
        )
        # Another method's error is not read at all.
        assert_false(
            gcp_status_error_unlabelled(String("POST"), String("RunQuery"), err),
            err,
        )
    assert_false(
        gcp_status_error_unlabelled(
            String("POST"),
            String("Commit"),
            String("connect refused, no google.rpc.Status envelope"),
        )
    )


def main() raises:
    test_elements_in_order_as_written()
    test_empty_stream()
    test_scalar_elements_are_kept_whole()
    test_error_element_raises_as_a_status_error()
    test_a_body_that_is_not_an_array_is_refused_by_its_size()
    test_error_code_reads_back_a_rest_error()
    test_error_code_refuses_anything_else()
    test_unlabelled_says_whether_the_body_named_a_status()
    print("all gcp rest stream tests passed")
