# The generated client reads no environment: every input is a parameter,
# the endpoint ones included (SecretsManagerEndpointConfig). The package's
# four files (the three generated ones and the hand-written
# secretsmanager_overrides) are staged as this test's data, at gen/<file>;
# the test reads each one and fails if any names a way to read the
# environment, reaches the FFI a read would go through, or takes the core's
# ruleset-free endpoint path.
# komira_aws_core's test_env_source_only holds the same line for the core,
# where the one read site is its EnvSource.
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def _read(name: String) raises -> String:
    with open(String(_DIR) + name, "r") as f:
        return f.read()


def test_no_environment_read() raises:
    var banned: List[String] = [
        "getenv",
        "_read_env",
        "std.os",
        "EnvSource",
        "ProcessEnv",
        "aws_endpoint_config",
        "komira_core_ffi",
        "external_call",
        # Not a read: komira_aws_core's endpoint path for a client with no
        # ruleset (an override, else https://<host>), whose override a
        # caller takes from the environment through aws_endpoint_config.
        # This module resolves every endpoint through the service's ruleset
        # over SecretsManagerEndpointConfig, and must not take that path around it.
        "resolve_endpoint(",
    ]
    var files: List[String] = [
        "__init__.mojo",
        "_layout_probe.mojo",
        "komira_aws_secretsmanager.mojo",
        "secretsmanager_overrides.mojo",
    ]
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                files[i] + " names " + banned[j] + "; the generated client"
                " takes every input as a parameter",
            )


def test_the_scan_saw_the_client() raises:
    # Not vacuous: the module staged is the generated client, whole, and
    # holds exactly the operations the BUCK file names.
    var text = _read("komira_aws_secretsmanager.mojo")
    assert_true(text.byte_length() > 20000, "the staged module is too small")
    assert_equal(_count(text, "\nstruct SecretsManagerEndpointConfig("), 1)
    assert_equal(_count(text, "#   mode         : client"), 1)
    assert_equal(_count(text, "\ndef build_"), 6)
    assert_equal(_count(text, "\ndef parse_"), 6)
    assert_equal(_count(text, '"secretsmanager.CreateSecret"'), 1)
    assert_equal(_count(text, '"secretsmanager.DeleteSecret"'), 1)
    assert_equal(_count(text, '"secretsmanager.DescribeSecret"'), 1)
    assert_equal(_count(text, '"secretsmanager.GetSecretValue"'), 1)
    assert_equal(_count(text, '"secretsmanager.PutSecretValue"'), 1)
    assert_equal(_count(text, '"secretsmanager.RestoreSecret"'), 1)
    # DeleteSecret's plain verb is the hand-written module's: the client
    # has only the raw one.
    assert_equal(_count(text, "    def delete_secret("), 0)
    assert_equal(_count(text, "    def delete_secret_raw("), 1)
    assert_equal(_count(text, "owner  : komira_aws_secretsmanager.secretsmanager_overrides.delete_secret"), 1)
    # The client sends where the ruleset resolves each call.
    assert_equal(
        _count(
            text,
            "resolve_get_secret_value_endpoint(self._rules, self._endpoint_config, input)",
        ),
        # the verb and the same verb over injected seams (`<op>_with`)
        2,
    )
    # A write resolves and builds the input whose unset idempotency token
    # the verb filled: CreateSecret and PutSecretValue, in each verb.
    assert_equal(
        _count(
            text,
            "resolve_create_secret_endpoint(self._rules, self._endpoint_config, filled)",
        ),
        2,
    )
    assert_equal(_count(text, "if not filled.client_request_token:"), 4)
    assert_equal(_count(text, "Optional[String](aws_idempotency_token())"), 4)
    assert_equal(_count(text, "from komira_aws_core import aws_idempotency_token\n"), 1)


def main() raises:
    test_no_environment_read()
    test_the_scan_saw_the_client()
    print("OK")
