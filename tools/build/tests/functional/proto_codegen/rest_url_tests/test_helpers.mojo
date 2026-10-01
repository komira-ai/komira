"""Runs the URL helpers protoc-gen-mojo emits over a vector table.

`_rest_path_var` expands a `{field=pattern}` path variable, `_rest_path_segment`
a one-segment `{field}` or `{field=*}` one, and `_rest_pct_encode` a query
value. Each refused case states the exact error, which names the field (and
the pattern) and never the value.
"""

from rest_url.helpers import (
    _rest_path_segment,
    _rest_path_var,
    _rest_pct_encode,
)

comptime FIELD = "parent"


def _mismatch(pattern: String) -> String:
    return String("path variable `parent` does not match `") + pattern + "`"


comptime BAD_SEGMENT = "path variable `parent` has an empty, `.` or `..` segment"
comptime BAD_ONE_SEGMENT = "path variable `name` is empty, `.` or `..`"


def _case(value: String, pattern: String) -> String:
    return String("_rest_path_var(\"") + value + "\", \"" + pattern + "\")"


def var_ok(value: String, pattern: String, want: String) raises:
    var got = String("")
    try:
        got = _rest_path_var(value, pattern, String(FIELD))
    except e:
        raise Error(_case(value, pattern) + " raised: " + String(e))
    if got != want:
        raise Error(_case(value, pattern) + " = \"" + got + "\", want \"" + want + "\"")


def _no_echo(what: String, value: String, msg: String) raises:
    # Values that must not be echoed carry the token `secret`; the fixed
    # text never does (the exact-text check above holds the rest).
    if value.find("secret") >= 0 and msg.find("secret") >= 0:
        raise Error(what + ": the error echoes the value: " + msg)


def var_refused(value: String, pattern: String, want_err: String) raises:
    var refused = False
    var msg = String("")
    try:
        _ = _rest_path_var(value, pattern, String(FIELD))
    except e:
        refused = True
        msg = String(e)
    if not refused:
        raise Error(_case(value, pattern) + " was accepted")
    if msg != want_err:
        raise Error(_case(value, pattern) + " said \"" + msg + "\", want \"" + want_err + "\"")
    _no_echo(_case(value, pattern), value, msg)


def seg_ok(value: String, want: String) raises:
    var what = String("_rest_path_segment(\"") + value + "\")"
    var got = String("")
    try:
        got = _rest_path_segment(value, String("name"))
    except e:
        raise Error(what + " raised: " + String(e))
    if got != want:
        raise Error(what + " = \"" + got + "\", want \"" + want + "\"")


def seg_refused(value: String) raises:
    var what = String("_rest_path_segment(\"") + value + "\")"
    var refused = False
    var msg = String("")
    try:
        _ = _rest_path_segment(value, String("name"))
    except e:
        refused = True
        msg = String(e)
    if not refused:
        raise Error(what + " was accepted")
    if msg != BAD_ONE_SEGMENT:
        raise Error(what + " said \"" + msg + "\", want \"" + BAD_ONE_SEGMENT + "\"")


def pct_eq(value: String, want: String) raises:
    var got = _rest_pct_encode(value)
    if got != want:
        raise Error(String("_rest_pct_encode(\"") + value + "\") = \"" + got + "\", want \"" + want + "\"")


def main() raises:
    # `*`: exactly one segment.
    var_ok("projects/p1", "projects/*", "projects/p1")
    var_ok("projects/...", "projects/*", "projects/...")  # `...` is a name
    var_ok("projects/.a", "projects/*", "projects/.a")
    var_refused("folders/secret-folder", "projects/*", _mismatch("projects/*"))
    var_refused("project/secret-p", "projects/*", _mismatch("projects/*"))
    var_refused("projects", "projects/*", _mismatch("projects/*"))
    var_refused("projects/p1/extra", "projects/*", _mismatch("projects/*"))
    var_refused("a/b", "*", _mismatch("*"))  # many segments against `*`
    var_refused("", "projects/*", _mismatch("projects/*"))

    # A literal is compared byte by byte, not by length: each value segment
    # below is as long as the pattern segment and differs in one byte (the
    # first, the last, a middle one, and a literal after a `*`).
    var_refused("xrojects/secret-p", "projects/*", _mismatch("projects/*"))
    var_refused("projectz/secret-p", "projects/*", _mismatch("projects/*"))
    var_refused("proXects/secret-p", "projects/*", _mismatch("projects/*"))
    var_refused("buckets/b/objectz/secret-x", "buckets/*/objects/**", _mismatch("buckets/*/objects/**"))

    # `**`: the rest of the value, zero, one or many segments.
    var_ok("operations", "operations/**", "operations")
    var_ok("operations/op1", "operations/**", "operations/op1")
    var_ok("operations/a/b/c", "operations/**", "operations/a/b/c")
    var_ok("buckets/b/objects/x/y", "buckets/*/objects/**", "buckets/b/objects/x/y")
    var_refused("", "operations/**", _mismatch("operations/**"))
    var_refused("other/op1", "operations/**", _mismatch("operations/**"))
    # A lone `**` (`{name=**}`): any non-empty path, but never an empty one,
    # which would leave `/v1/{name=**}` naming the collection `/v1/`.
    var_ok("a", "**", "a")
    var_ok("a/b", "**", "a/b")
    var_refused("", "**", BAD_SEGMENT)

    # Empty, `.` and `..` segments change which resource the path names.
    var_refused("projects/p1/", "projects/*", _mismatch("projects/*"))
    var_refused("operations/secret-op/", "operations/**", BAD_SEGMENT)
    var_refused("projects//secret-p1", "projects/*", BAD_SEGMENT)
    var_refused("/projects/p1", "projects/*", BAD_SEGMENT)
    var_refused("projects/.", "projects/*", BAD_SEGMENT)
    var_refused("projects/..", "projects/*", BAD_SEGMENT)
    var_refused("operations/secret/../b", "operations/**", BAD_SEGMENT)
    var_refused("operations/a/./b", "operations/**", BAD_SEGMENT)
    var_refused("operations/a//b", "operations/**", BAD_SEGMENT)

    # Each segment percent-encoded, the `/` between them kept.
    var_ok("projects/a b?c#d%e", "projects/*", "projects/a%20b%3Fc%23d%25e")
    var_ok("operations/x y/z:w", "operations/**", "operations/x%20y/z%3Aw")
    var_ok("projects/é", "projects/*", "projects/%C3%A9")

    # One segment: `/` is encoded; empty, `.` and `..` are refused.
    seg_ok("abc", "abc")
    seg_ok("a/b", "a%2Fb")
    seg_ok("a b", "a%20b")
    seg_ok("...", "...")
    seg_ok(".a", ".a")
    seg_ok("..a", "..a")
    seg_refused("")
    seg_refused(".")
    seg_refused("..")

    # Query values: everything outside [A-Za-z0-9-._~] encoded, hex upper.
    pct_eq("AZaz09-._~", "AZaz09-._~")
    pct_eq("/?#[]@!$&'()*+,;=% ", "%2F%3F%23%5B%5D%40%21%24%26%27%28%29%2A%2B%2C%3B%3D%25%20")
    # The neighbours of the a-z range and the bytes above it: backtick (0x60),
    # `{` (0x7B), `|`, `}` and DEL (0x7F) are all reserved.
    pct_eq(String("`{|}") + chr(0x7F), "%60%7B%7C%7D%7F")
    pct_eq("éÿ", "%C3%A9%C3%BF")
    pct_eq("", "")

    print("test_helpers: PASS")
