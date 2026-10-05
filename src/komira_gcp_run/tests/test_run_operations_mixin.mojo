# The operations client's paths are Cloud Run's, as the pinned service
# configuration states them.
#
# operations_mixin.proto restates two `http.rules` of
# google/cloud/run/v2/run_v2.yaml (the Run API's service configuration,
# extracted from the googleapis archive at the pin and staged here as
# run_v2.yaml) so the generator can generate them: GetOperation and
# WaitOperation of google.longrunning.Operations. This test reads each rule
# out of that file once, then fails unless operations_mixin.proto (staged
# here) states the same rule and the generated client (staged whole at gen/)
# was generated with it, so a bump of the pin that moves Run's operations
# cannot leave the client polling the old path.
from std.testing import assert_equal, assert_true


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def _value_after(hay: String, anchor: String, close: String) raises -> String:
    """The text between the one occurrence of `anchor` and the next `close`."""
    assert_equal(_count(hay, anchor), 1, String("not stated once: ") + anchor)
    var start = hay.find(anchor) + anchor.byte_length()
    var end = hay.find(close, start)
    assert_true(end > start, String("no value after: ") + anchor)
    return String(hay[byte=start:end])


comptime _GET = "  - selector: google.longrunning.Operations.GetOperation\n    get: '"
comptime _WAIT = "  - selector: google.longrunning.Operations.WaitOperation\n    post: '"


def _yaml() raises -> String:
    var yaml = _read("run_v2.yaml")
    assert_true(
        yaml.startswith("type: google.api.Service\n"),
        "run_v2.yaml is not a service configuration",
    )
    return yaml^


def test_the_service_configuration_binds_the_mixin_to_runs_paths() raises:
    var yaml = _yaml()
    assert_equal(_count(yaml, "- name: google.longrunning.Operations\n"), 1)
    # Each selector is bound once: a second rule for either would be a
    # binding this client does not have.
    assert_equal(_count(yaml, "selector: google.longrunning.Operations.GetOperation\n"), 1)
    assert_equal(_count(yaml, "selector: google.longrunning.Operations.WaitOperation\n"), 1)
    assert_equal(_count(yaml, "\nname: run.googleapis.com\n"), 1)
    # The two rules are Run's own paths, not operations.proto's `/v1/...`.
    assert_true(_value_after(yaml, _GET, "'\n").startswith("/v2/"))
    assert_true(_value_after(yaml, _WAIT, "'\n").startswith("/v2/"))
    # WaitOperation's body follows its path line.
    var wait = _value_after(yaml, _WAIT, "'\n")
    assert_equal(_count(yaml, String(_WAIT) + wait + "'\n    body: '*'\n"), 1)


def test_the_restated_rules_are_the_service_configurations() raises:
    var yaml = _yaml()
    var proto = _read("operations_mixin.proto")
    var get = _value_after(yaml, _GET, "'\n")
    var wait = _value_after(yaml, _WAIT, "'\n")
    assert_equal(_value_after(proto, "      get: \"", "\"\n"), get)
    assert_equal(_value_after(proto, "      post: \"", "\"\n"), wait)
    assert_equal(_value_after(proto, "      body: \"", "\"\n"), "*")
    assert_equal(
        _value_after(proto, "option (google.api.default_host) = \"", "\";\n"),
        _value_after(yaml, "\nname: ", "\n"),
    )
    # Exactly the two rules: no third binding of the mixin rides along.
    assert_equal(_count(proto, "option (google.api.http)"), 2)
    assert_equal(_count(proto, "  rpc "), 2)


def test_the_client_is_generated_with_those_paths() raises:
    var yaml = _yaml()
    var client = _read("gen/operations_mixin.mojo")
    var get = _value_after(yaml, _GET, "'\n")
    var wait = _value_after(yaml, _WAIT, "'\n")
    assert_equal(_count(client, String('"""GET `') + get + "`"), 1)
    assert_equal(_count(client, String('"""POST `') + wait + "`"), 1)
    var host = _value_after(yaml, "\nname: ", "\n")
    assert_equal(_count(client, String('self._rest_host = String("') + host + '")'), 2)
    assert_equal(_count(client, "[RT: Runtime]("), 2)


def main() raises:
    test_the_service_configuration_binds_the_mixin_to_runs_paths()
    test_the_restated_rules_are_the_service_configurations()
    test_the_client_is_generated_with_those_paths()
    print("OK")
