# The generated client reads no environment: every input is a parameter, the
# endpoint ones included (ECSEndpointConfig). The three generated files are
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
        # over ECSEndpointConfig, and must not take that path around it.
        "resolve_endpoint(",
    ]
    var files: List[String] = [
        "__init__.mojo",
        "_layout_probe.mojo",
        "komira_aws_ecs.mojo",
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
    var text = _read("komira_aws_ecs.mojo")
    assert_true(text.byte_length() > 20000, "the staged module is too small")
    assert_equal(_count(text, "\nstruct ECSEndpointConfig("), 1)
    assert_equal(_count(text, "#   mode         : client"), 1)
    assert_equal(_count(text, "\ndef build_"), 14)
    assert_equal(_count(text, "\ndef parse_"), 14)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.CreateCluster"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.DeregisterTaskDefinition"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.DescribeClusters"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.DescribeTaskDefinition"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.DescribeTasks"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.ListClusters"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.ListServices"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.ListTaskDefinitionFamilies"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.ListTaskDefinitions"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.ListTasks"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.PutClusterCapacityProviders"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.RegisterTaskDefinition"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.RunTask"'), 1)
    assert_equal(_count(text, '"AmazonEC2ContainerServiceV20141113.StopTask"'), 1)
    # The client sends where the ruleset resolves each call.
    assert_equal(
        _count(
            text,
            "resolve_create_cluster_endpoint(self._rules, self._endpoint_config, input)",
        ),
        # the verb and the same verb over injected seams (`<op>_with`)
        2,
    )
    # RunTask resolves and builds the input whose unset clientToken the
    # verb filled, in each verb.
    assert_equal(
        _count(text, "resolve_run_task_endpoint(self._rules, self._endpoint_config, filled)"),
        2,
    )
    assert_equal(_count(text, "if not filled.client_token:"), 2)
    assert_equal(_count(text, "generate_uuidv7().to_hyphenated()"), 2)


def main() raises:
    test_no_environment_read()
    test_the_scan_saw_the_client()
    print("OK")
