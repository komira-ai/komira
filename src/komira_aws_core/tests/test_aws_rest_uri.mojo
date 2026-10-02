# The request target of a REST operation (aws_rest.mojo): URI labels,
# greedy labels, the literal query, httpQuery and httpQueryParams, and the
# hostPrefix labels. Each row is derived from the rule it cites:
#
#   [U]  RFC 3986 section 2: unreserved = ALPHA / DIGIT / "-" / "." / "_" /
#        "~" stay; every other byte of the UTF-8 form is %XX, uppercase hex
#        (section 2.1)
#   [L]  https://smithy.io/2.0/spec/http-bindings.html#httplabel-trait and
#        #greedy-labels: a label is percent-encoded, a greedy label keeps
#        '/', labels are required
#   [Q]  #httpquery-trait / #httpqueryparams-trait: lists repeat the key;
#        a literal or httpQuery key wins over an httpQueryParams entry
#   [S3] an S3 object key is a greedy `{Key+}` whose "." and ".." are
#        ordinary key bytes: it is encoded by [U] and [L] and never
#        normalized
#   [E]  https://smithy.io/2.0/spec/endpoint-traits.html#hostlabel-trait,
#        and the rules engine's isValidHostLabel:
#        [A-Za-z0-9][A-Za-z0-9-]{0,62}

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AWS_TS_ISO8601,
    AwsRestUri,
    aws_host_label,
    aws_host_prefix,
    aws_text_bool,
    aws_text_ts,
)


def _one(pattern: String, name: String, value: String) raises -> String:
    var names: List[String] = [name]
    var values: List[String] = [value]
    return AwsRestUri.expand(pattern, names, values).target()


def _refused_expand(
    pattern: String, names: List[String], values: List[String], why: String
) raises:
    try:
        _ = AwsRestUri.expand(pattern, names, values)
    except e:
        assert_true(String(e).find(why) >= 0, String(e))
        return
    raise Error("pattern '" + pattern + "' was expanded")


def test_label_encoding() raises:
    # [U] unreserved bytes stay.
    assert_equal(_one("/{L}", "L", "AZaz09-._~"), "/AZaz09-._~")
    # [U] gen-delims and sub-delims are encoded in a label value, '/'
    # included [L].
    assert_equal(_one("/{L}", "L", ":/?#[]@"), "/%3A%2F%3F%23%5B%5D%40")
    assert_equal(
        _one("/{L}", "L", "!$&'()*+,;="), "/%21%24%26%27%28%29%2A%2B%2C%3B%3D"
    )
    # [U] '%' itself, a space, and non-ASCII as its UTF-8 bytes.
    assert_equal(_one("/{L}", "L", "100%"), "/100%25")
    assert_equal(_one("/{L}", "L", "a b"), "/a%20b")
    assert_equal(_one("/{L}", "L", "é"), "/%C3%A9")
    assert_equal(_one("/{L}", "L", "😹"), "/%F0%9F%98%B9")
    # [L] a greedy label keeps '/' and encodes everything else as a plain
    # label does.
    assert_equal(_one("/{L+}", "L", "a/b c/d?"), "/a/b%20c/d%3F")
    # Literal path text around labels is copied as written.
    var names: List[String] = ["Id", "Rest"]
    var values: List[String] = ["x y", "p/q"]
    assert_equal(
        AwsRestUri.expand("/v1/items/{Id}/sub/{Rest+}", names, values).target(),
        "/v1/items/x%20y/sub/p/q",
    )
    # A label in the middle of a segment, and the same label twice.
    assert_equal(_one("/a-{L}-b/{L}", "L", "1"), "/a-1-b/1")
    # Label text is the aws_text form of the member [L].
    assert_equal(_one("/{Flag}", "Flag", aws_text_bool(True)), "/true")
    assert_equal(
        _one("/{When}", "When", aws_text_ts(1789473600.0, AWS_TS_ISO8601)),
        "/2026-09-15T12%3A00%3A00Z",
    )


def test_s3_keys() raises:
    # [S3] the bucket is a plain label, the key greedy.
    var p = String("/{Bucket}/{Key+}?x-id=GetObject")
    var names: List[String] = ["Bucket", "Key"]
    var rows: List[String] = [
        "a b.txt",
        "/b/a%20b.txt?x-id=GetObject",
        "x/y z/k.txt",
        "/b/x/y%20z/k.txt?x-id=GetObject",
        # Dot segments are key bytes, leading or embedded.
        "../k",
        "/b/../k?x-id=GetObject",
        "x/../y",
        "/b/x/../y?x-id=GetObject",
        # Not normalized: a leading '/', '//', '.' segments and a trailing
        # '/' all stay.
        "/leading",
        "/b//leading?x-id=GetObject",
        "a//b/./c/",
        "/b/a//b/./c/?x-id=GetObject",
        # '+' is a sub-delim [U]: encoded, never read as a space.
        "a+b=c&d",
        "/b/a%2Bb%3Dc%26d?x-id=GetObject",
    ]
    for i in range(0, len(rows), 2):
        var values: List[String] = ["b", rows[i]]
        assert_equal(
            AwsRestUri.expand(p, names, values).target(), rows[i + 1], rows[i]
        )


def test_label_refusals() raises:
    var none = List[String]()
    var l: List[String] = ["L"]
    var empty: List[String] = [""]
    var one: List[String] = ["v"]
    # [L] labels are required and may not be empty, greedy or not.
    _refused_expand("/{L}", l, empty, "is empty")
    _refused_expand("/{L+}", l, empty, "is empty")
    _refused_expand("/{L}", none, none, "has no value")
    # Malformed patterns.
    _refused_expand("{L}", l, one, "does not start with '/'")
    _refused_expand("", none, none, "does not start with '/'")
    _refused_expand("/{L", l, one, "unterminated label")
    _refused_expand("/{L{M}}", l, one, "unterminated label")
    _refused_expand("/L}", l, one, "'}' outside a label")
    _refused_expand("/{}", l, one, "empty label")
    _refused_expand("/{+}", l, one, "empty label")
    _refused_expand("/x?a={L}", l, one, "label in its query")
    _refused_expand("/{L}", l, none, "differ in length")


def test_query() raises:
    var none = List[String]()
    # The pattern's literal query comes first, a bare key without '='.
    var u = AwsRestUri.expand("/{B}?uploads", ["B"], ["bkt"])
    assert_equal(u.target(), "/bkt?uploads")
    assert_true(u.has_query("uploads"))
    # [Q] httpQuery: key=value, both encoded as a label is, '/' included.
    var l = AwsRestUri.expand("/{B}?list-type=2", ["B"], ["bkt"])
    l.add_query("prefix", "photos/a b/")
    l.add_query("encoding-type", "url")
    assert_equal(
        l.target(),
        "/bkt?list-type=2&prefix=photos%2Fa%20b%2F&encoding-type=url",
    )
    # [Q] a list repeats the key, in order; an empty string is `key=`.
    var r = AwsRestUri.expand("/r", none, none)
    r.add_query("id", "1")
    r.add_query("id", "")
    r.add_query("id", "a&b=c")
    assert_equal(r.target(), "/r?id=1&id=&id=a%26b%3Dc")
    # [Q] httpQueryParams entries lose to a literal or an httpQuery key,
    # and a map of lists repeats its own key.
    var p = AwsRestUri.expand("/p?fixed=1", none, none)
    p.add_query("q", "x")
    p.add_query_param("fixed", "y")
    p.add_query_param("q", "z")
    p.add_query_param("m", "1")
    p.add_query_param("m", "2")
    p.add_query_param("sp ace", "é")
    assert_equal(p.target(), "/p?fixed=1&q=x&m=1&m=2&sp%20ace=%C3%A9")
    assert_true(p.has_query("m"))
    assert_false(p.has_query("absent"))
    # [Q] the same precedence when the httpQuery member is added after the
    # map entry: the entry is dropped.
    var late = AwsRestUri.expand("/p", none, none)
    late.add_query_param("q", "z")
    late.add_query_param("k", "1")
    late.add_query("q", "x")
    late.add_query("q", "y")
    assert_equal(late.target(), "/p?k=1&q=x&q=y")
    # [Q] a query timestamp is a date-time by default.
    var t = AwsRestUri.expand("/t", none, none)
    t.add_query("since", aws_text_ts(1789473600.0, AWS_TS_ISO8601))
    assert_equal(t.query(), "since=2026-09-15T12%3A00%3A00Z")
    # No query: no '?'.
    assert_equal(AwsRestUri.expand("/", none, none).target(), "/")
    # A pattern ending in '?' carries no literal parameter.
    assert_equal(AwsRestUri.expand("/x?", none, none).target(), "/x")


def test_host_labels() raises:
    # [E] a host label: alphanumerics and '-', not starting with '-', at
    # most 63 bytes.
    assert_equal(aws_host_label("abc-123"), "abc-123")
    assert_equal(aws_host_label("a-"), "a-")
    var max63 = String("")
    for _ in range(63):
        max63 += "a"
    assert_equal(aws_host_label(max63), max63)
    var bad: List[String] = ["", "-a", "a.b", "a_b", "a b", "é", max63 + "a"]
    for i in range(len(bad)):
        try:
            _ = aws_host_label(bad[i])
            raise Error("host label '" + bad[i] + "' was accepted")
        except e:
            assert_true(String(e).find("AWS host label") >= 0, String(e))
    # [E] the hostPrefix with its labels substituted.
    assert_equal(aws_host_prefix("{Acct}.", ["Acct"], ["acct-1"]), "acct-1.")
    assert_equal(aws_host_prefix("data-", List[String](), List[String]()), "data-")
    assert_equal(
        aws_host_prefix("{A}-{B}.", ["A", "B"], ["x", "y"]), "x-y."
    )
    var refused: List[String] = ["{Acct}.", "{Acct.", "Acct}."]
    for i in range(len(refused)):
        try:
            _ = aws_host_prefix(refused[i], ["Acct"], ["a.b"])
            raise Error("host prefix '" + refused[i] + "' was expanded")
        except e:
            assert_true(String(e).find("AWS host") >= 0, String(e))
    try:
        _ = aws_host_prefix("{Other}.", ["Acct"], ["a"])
        raise Error("a host label with no value was expanded")
    except e:
        assert_true(String(e).find("has no value") >= 0, String(e))


def main() raises:
    test_label_encoding()
    test_s3_keys()
    test_label_refusals()
    test_query()
    test_host_labels()
    print("OK")
