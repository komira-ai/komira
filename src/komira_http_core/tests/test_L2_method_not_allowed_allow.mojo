# HttpResponse.method_not_allowed(allowed): the 405 carries an `Allow` header
# (RFC 9110 §15.5.6, §10.2.1) naming each allowed method once, sorted by name.
# Each test names the defect it catches.

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import HttpMethod, HttpResponse


def _allow(var methods: List[HttpMethod]) raises -> String:
    var r = HttpResponse.method_not_allowed(methods)
    assert_equal(Int(r.status), 405)
    assert_true(String("allow") in r.headers, "a 405 without an Allow header")
    return r.headers[String("allow")]


def test_every_method_is_listed_sorted() raises:
    """Catches an Allow header that is missing, keeps only the first method,
    or keeps registration order: the last method given sorts first."""
    var methods = List[HttpMethod]()
    methods.append(HttpMethod.get())
    methods.append(HttpMethod.post())
    methods.append(HttpMethod.delete())
    assert_equal(_allow(methods^), String("DELETE, GET, POST"))


def test_a_repeated_method_is_listed_once() raises:
    """Catches a method named twice when two routes (or two services) both
    register it for the path."""
    var methods = List[HttpMethod]()
    methods.append(HttpMethod.put())
    methods.append(HttpMethod.get())
    methods.append(HttpMethod.put())
    assert_equal(_allow(methods^), String("GET, PUT"))


def test_one_method_and_none() raises:
    var one = List[HttpMethod]()
    one.append(HttpMethod.patch())
    assert_equal(_allow(one^), String("PATCH"))
    assert_equal(_allow(List[HttpMethod]()), String(""))


def test_the_no_argument_form_has_no_allow() raises:
    var r = HttpResponse.method_not_allowed()
    assert_equal(Int(r.status), 405)
    assert_false(String("allow") in r.headers)
    assert_equal(r.headers[String("content-length")], String("0"))


def main() raises:
    test_every_method_is_listed_sorted()
    test_a_repeated_method_is_listed_once()
    test_one_method_and_none()
    test_the_no_argument_form_has_no_allow()
    print("PASS test_L2_method_not_allowed_allow")
