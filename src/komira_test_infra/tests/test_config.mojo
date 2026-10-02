# TestInfraConfig parsing: a complete file parses; a missing, unknown,
# repeated or mistyped field raises NAMING THE FIELD; and no refusal carries a
# configured value.

from std.testing import assert_equal, assert_false, assert_true

from komira_test_infra import MapFiles, load_test_infra_config, parse_test_infra_config

comptime _ENDPOINT: String = "https://cfg-sentinel.invalid:9443"

comptime _GOOD: String = """
# a comment
object_store {
  endpoint: "https://cfg-sentinel.invalid:9443"
  region: "test-region-1"
  bucket: "cfg-bucket-sentinel"
  run_prefix: "stem/runs/"
  credentials_file: "/mnt/creds/sentinel-credentials"
}
max_lease_seconds: 5400
teardown_budget_seconds: 120
"""


def _error_of(text: String) -> String:
    """The refusal message, or "" when the text parsed."""
    try:
        _ = parse_test_infra_config(text)
    except e:
        return String(e)
    return String("")


def _assert_refused(text: String, want: String) raises:
    var msg = _error_of(text)
    assert_true(msg.byte_length() > 0, "expected a refusal containing: " + want)
    assert_true(want in msg, "refusal '" + msg + "' does not contain '" + want + "'")
    for value in [_ENDPOINT, "cfg-sentinel", "cfg-bucket-sentinel", "sentinel-credentials"]:
        assert_false(value in msg, "refusal carries a configured value: " + msg)


def test_parses_a_complete_file() raises:
    var c = parse_test_infra_config(_GOOD)
    assert_equal(c.endpoint, _ENDPOINT)
    assert_equal(c.region, "test-region-1")
    assert_equal(c.bucket, "cfg-bucket-sentinel")
    assert_equal(c.run_prefix, "stem/runs/")
    assert_equal(c.credentials_file, "/mnt/creds/sentinel-credentials")
    assert_equal(c.max_lease_seconds, 5400)
    assert_equal(c.teardown_budget_seconds, 120)
    # `object_store: { ... }` (with a colon) is the same message.
    var c2 = parse_test_infra_config(_GOOD.replace("object_store {", "object_store: {"))
    assert_equal(c2.bucket, "cfg-bucket-sentinel")


def test_each_missing_field_is_named() raises:
    var lines: List[String] = [
        "  endpoint: \"https://cfg-sentinel.invalid:9443\"\n",
        "  region: \"test-region-1\"\n",
        "  bucket: \"cfg-bucket-sentinel\"\n",
        "  run_prefix: \"stem/runs/\"\n",
        "  credentials_file: \"/mnt/creds/sentinel-credentials\"\n",
        "max_lease_seconds: 5400\n",
        "teardown_budget_seconds: 120\n",
    ]
    var names: List[String] = [
        "object_store.endpoint",
        "object_store.region",
        "object_store.bucket",
        "object_store.run_prefix",
        "object_store.credentials_file",
        "max_lease_seconds",
        "teardown_budget_seconds",
    ]
    for i in range(len(lines)):
        var text = _GOOD.replace(lines[i], "")
        assert_true(text != _GOOD, "fixture line not found: " + lines[i])
        _assert_refused(text, "missing required field: " + names[i])
    # Several missing: every one is named.
    var msg = _error_of("max_lease_seconds: 10\n")
    for i in range(len(names)):
        if names[i] != "max_lease_seconds":
            assert_true(names[i] in msg, msg)
    # An empty file names them all.
    assert_true("object_store.endpoint" in _error_of(""))


def test_unknown_fields_are_refused_by_name() raises:
    _assert_refused(_GOOD + "secret_dir: \"/x\"\n", "unknown field secret_dir")
    _assert_refused(
        _GOOD.replace("  region:", "  profile: \"p\"\n  region:"),
        "unknown field object_store.profile",
    )
    # A misplaced unquoted host is a bareword, not an identifier: not echoed.
    var msg = _error_of(_GOOD + "cfg-sentinel.invalid\n")
    assert_true("unknown field (name not shown" in msg, msg)
    assert_false("cfg-sentinel" in msg, msg)


def test_repeated_and_mistyped_fields() raises:
    _assert_refused(_GOOD + "max_lease_seconds: 60\n", "max_lease_seconds: set more than once")
    _assert_refused(
        _GOOD.replace("  region:", "  bucket: \"again\"\n  region:"),
        "object_store.bucket: set more than once",
    )
    _assert_refused(
        _GOOD.replace("\"https://cfg-sentinel.invalid:9443\"", "9443"),
        "object_store.endpoint: expected a quoted string",
    )
    _assert_refused(
        _GOOD.replace("max_lease_seconds: 5400", "max_lease_seconds: \"5400\""),
        "max_lease_seconds: expected a whole number",
    )
    _assert_refused(
        _GOOD.replace("max_lease_seconds: 5400", "max_lease_seconds: -5"),
        "max_lease_seconds",
    )
    _assert_refused(
        _GOOD.replace("max_lease_seconds: 5400", "max_lease_seconds 5400"),
        "max_lease_seconds: expected ':'",
    )


def test_value_rules_name_the_field() raises:
    _assert_refused(
        _GOOD.replace("\"stem/runs/\"", "\"stem/runs\""), "object_store.run_prefix"
    )
    _assert_refused(
        _GOOD.replace("\"stem/runs/\"", "\"/stem/\""), "object_store.run_prefix"
    )
    _assert_refused(
        _GOOD.replace("\"stem/runs/\"", "\"stem/../\""), "object_store.run_prefix"
    )
    _assert_refused(
        _GOOD.replace("\"https://cfg-sentinel.invalid:9443\"", "\"cfg-sentinel.invalid\""),
        "object_store.endpoint: must start with http:// or https://",
    )
    _assert_refused(
        _GOOD.replace("\"/mnt/creds/sentinel-credentials\"", "\"sentinel-credentials\""),
        "object_store.credentials_file: must be an absolute path",
    )
    _assert_refused(_GOOD.replace("\"test-region-1\"", "\"\""), "object_store.region")
    _assert_refused(
        _GOOD.replace("teardown_budget_seconds: 120", "teardown_budget_seconds: 5400"),
        "teardown_budget_seconds",
    )
    _assert_refused(
        _GOOD.replace("teardown_budget_seconds: 120", "teardown_budget_seconds: 0"),
        "teardown_budget_seconds",
    )


def test_lexer_refusals_keep_the_line_not_the_text() raises:
    var msg = _error_of(
        _GOOD.replace("\"https://cfg-sentinel.invalid:9443\"", "\"https://cfg-sentinel.invalid:9443\" [")
    )
    assert_true("line 4" in msg, msg)
    assert_true("not valid textproto" in msg, msg)
    assert_false("[" in msg, msg)
    assert_false("cfg-sentinel" in msg, msg)
    var unterminated = _error_of(
        _GOOD.replace("\"https://cfg-sentinel.invalid:9443\"", "\"https://cfg-sentinel.invalid:9443")
    )
    assert_true("line 4" in unterminated, unterminated)
    assert_false("cfg-sentinel" in unterminated, unterminated)


def test_load_reads_through_the_file_source() raises:
    var files = MapFiles()
    files.put("/cfg/testinfra.textproto", _GOOD)
    var c = load_test_infra_config("/cfg/testinfra.textproto", files)
    assert_equal(c.max_lease_seconds, 5400)
    assert_equal(len(files.reads), 1)
    var refused = False
    try:
        _ = load_test_infra_config("/cfg/absent.textproto", files)
    except e:
        refused = True
        assert_true("cannot read" in String(e), String(e))
    assert_true(refused, "an unreadable config was accepted")


def main() raises:
    test_parses_a_complete_file()
    test_each_missing_field_is_named()
    test_unknown_fields_are_refused_by_name()
    test_repeated_and_mistyped_fields()
    test_value_rules_name_the_field()
    test_lexer_refusals_keep_the_line_not_the_text()
    test_load_reads_through_the_file_source()
    print("test_config: OK")
