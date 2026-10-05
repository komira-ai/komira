# The generated client reads no environment: every input is a parameter, the
# endpoint ones included (EC2EndpointConfig). The three generated files are
# staged as this test's data, at gen/<file>; the test reads each one and
# fails if any names a way to read the environment, reaches the FFI a read
# would go through, or takes the core's ruleset-free endpoint path.
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
        # over EC2EndpointConfig, and must not take that path around it.
        "resolve_endpoint(",
    ]
    var files: List[String] = [
        "__init__.mojo",
        "_layout_probe.mojo",
        "komira_aws_ec2.mojo",
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
    # Not vacuous: the module staged is the generated client, whole.
    var text = _read("komira_aws_ec2.mojo")
    assert_true(text.byte_length() > 20000, "the staged module is too small")
    assert_equal(_count(text, "\ndef build_run_instances_request("), 1)
    assert_equal(_count(text, "\nstruct EC2EndpointConfig("), 1)
    assert_equal(_count(text, 'AwsQueryWriter(String("RunInstances")'), 1)
    assert_equal(_count(text, "#   mode         : client"), 1)
    # The client sends where the ruleset resolves each call.
    assert_equal(
        _count(
            text,
            "resolve_describe_instances_endpoint(self._rules, self._endpoint_config, input)",
        ),
        # the verb and the same verb over injected seams (`<op>_with`)
        2,
    )


def main() raises:
    test_no_environment_read()
    test_the_scan_saw_the_client()
    print("OK")
