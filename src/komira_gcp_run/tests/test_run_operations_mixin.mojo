# The operations client's paths are Cloud Run's, as the pinned service
# configuration states them.
#
# operations_mixin.proto restates two `http.rules` of
# google/cloud/run/v2/run_v2.yaml (the Run API's service configuration,
# extracted from the googleapis archive at the pin and staged here as
# run_v2.yaml) so the generator can generate them: GetOperation and
# WaitOperation of google.longrunning.Operations. This test reads that file
# and the generated client (staged whole at gen/) and fails if either rule
# there is not the one the client was generated with, so a bump of the pin
# that moves Run's operations cannot leave the client polling the old path.
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


def test_the_service_configuration_binds_the_mixin_to_runs_paths() raises:
    var yaml = _read("run_v2.yaml")
    assert_true(
        yaml.startswith("type: google.api.Service\n"),
        "run_v2.yaml is not a service configuration",
    )
    assert_equal(_count(yaml, "- name: google.longrunning.Operations\n"), 1)
    assert_equal(
        _count(
            yaml,
            "  - selector: google.longrunning.Operations.GetOperation\n"
            + "    get: '/v2/{name=projects/*/locations/*/operations/*}'\n",
        ),
        1,
    )
    assert_equal(
        _count(
            yaml,
            "  - selector: google.longrunning.Operations.WaitOperation\n"
            + "    post: '/v2/{name=projects/*/locations/*/operations/*}:wait'\n"
            + "    body: '*'\n",
        ),
        1,
    )
    # Each selector is bound once: a second rule for either would be a
    # binding this client does not have.
    assert_equal(_count(yaml, "selector: google.longrunning.Operations.GetOperation\n"), 1)
    assert_equal(_count(yaml, "selector: google.longrunning.Operations.WaitOperation\n"), 1)
    assert_equal(_count(yaml, "\nname: run.googleapis.com\n"), 1)


def test_the_client_is_generated_with_those_paths() raises:
    var client = _read("gen/operations_mixin.mojo")
    assert_equal(
        _count(client, '"""GET `/v2/{name=projects/*/locations/*/operations/*}`'), 1
    )
    assert_equal(
        _count(client, '"""POST `/v2/{name=projects/*/locations/*/operations/*}:wait`'),
        1,
    )
    assert_equal(_count(client, 'self._rest_host = String("run.googleapis.com")'), 2)
    assert_equal(_count(client, "[RT: Runtime]("), 2)


def main() raises:
    test_the_service_configuration_binds_the_mixin_to_runs_paths()
    test_the_client_is_generated_with_those_paths()
    print("OK")
