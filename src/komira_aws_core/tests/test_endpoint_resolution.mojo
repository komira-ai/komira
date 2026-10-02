# The endpoint resolution table: regions and partitions, FIPS and dual-stack,
# endpoint URL parsing, and the configured-endpoint precedence of the AWS
# SDKs (AWS_IGNORE_CONFIGURED_ENDPOINT_URLS, AWS_ENDPOINT_URL_<SERVICE>,
# AWS_ENDPOINT_URL, the profile's endpoint_url), all over in-memory
# environments and files.

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AwsCredentialParams,
    AwsEndpoint,
    MapEnv,
    MapFiles,
    aws_endpoint_config,
    aws_partition_for_region,
    aws_service_endpoint,
    resolve_endpoint,
    service_endpoint_env_var,
)


def _host(prefix: String, region: String, fips: Bool, ds: Bool) raises -> String:
    return aws_service_endpoint(prefix, region, fips, ds).host


def _refused(prefix: String, region: String, fips: Bool, ds: Bool, want: String) raises:
    try:
        _ = aws_service_endpoint(prefix, region, fips, ds)
    except e:
        assert_true(String(e).find(want) >= 0, String(e))
        return
    raise Error("not refused: " + prefix + " " + region)


def test_partition_table() raises:
    # region, partition id, plain host, fips host, dual-stack host
    var rows: List[List[String]] = [
        ["us-east-1", "aws", "logs.us-east-1.amazonaws.com",
         "logs-fips.us-east-1.amazonaws.com", "logs.us-east-1.api.aws"],
        ["eu-west-3", "aws", "logs.eu-west-3.amazonaws.com",
         "logs-fips.eu-west-3.amazonaws.com", "logs.eu-west-3.api.aws"],
        ["ap-southeast-5", "aws", "logs.ap-southeast-5.amazonaws.com",
         "logs-fips.ap-southeast-5.amazonaws.com", "logs.ap-southeast-5.api.aws"],
        ["cn-north-1", "aws-cn", "logs.cn-north-1.amazonaws.com.cn",
         "logs-fips.cn-north-1.amazonaws.com.cn",
         "logs.cn-north-1.api.amazonwebservices.com.cn"],
        ["us-gov-west-1", "aws-us-gov", "logs.us-gov-west-1.amazonaws.com",
         "logs-fips.us-gov-west-1.amazonaws.com", "logs.us-gov-west-1.api.aws"],
        ["us-iso-east-1", "aws-iso", "logs.us-iso-east-1.c2s.ic.gov",
         "logs-fips.us-iso-east-1.c2s.ic.gov", ""],
        ["us-isob-east-1", "aws-iso-b", "logs.us-isob-east-1.sc2s.sgov.gov",
         "logs-fips.us-isob-east-1.sc2s.sgov.gov", ""],
        ["us-isof-south-1", "aws-iso-f", "logs.us-isof-south-1.csp.hci.ic.gov",
         "logs-fips.us-isof-south-1.csp.hci.ic.gov", ""],
        ["eu-isoe-west-1", "aws-iso-e", "logs.eu-isoe-west-1.cloud.adc-e.uk",
         "logs-fips.eu-isoe-west-1.cloud.adc-e.uk", ""],
        ["eusc-de-east-1", "aws-eusc", "logs.eusc-de-east-1.amazonaws.eu",
         "logs-fips.eusc-de-east-1.amazonaws.eu", ""],
        # A region of no known shape is in `aws`, as in the AWS SDKs.
        ["xx-future-9", "aws", "logs.xx-future-9.amazonaws.com",
         "logs-fips.xx-future-9.amazonaws.com", "logs.xx-future-9.api.aws"],
    ]
    for i in range(len(rows)):
        var r = rows[i].copy()
        assert_equal(aws_partition_for_region(r[0]).id, r[1], r[0])
        assert_equal(_host("logs", r[0], False, False), r[2], r[0])
        assert_equal(_host("logs", r[0], True, False), r[3], r[0])
        if r[4].byte_length() > 0:
            assert_equal(_host("logs", r[0], False, True), r[4], r[0])
        else:
            _refused("logs", r[0], False, True, "no dual-stack")
    # FIPS and dual-stack together.
    assert_equal(
        _host("sqs", "us-west-2", True, True), "sqs-fips.us-west-2.api.aws"
    )
    # Pseudo regions map to their partition but get no generic endpoint.
    assert_equal(aws_partition_for_region("aws-cn-global").id, "aws-cn")
    assert_equal(aws_partition_for_region("aws-us-gov-global").id, "aws-us-gov")
    _refused("iam", "aws-global", False, False, "global pseudo region")
    _refused("logs", "fips-us-east-1", False, False, "legacy FIPS")
    _refused("logs", "us-east-1-fips", False, False, "legacy FIPS")
    _refused("logs", "", False, False, "no AWS region")
    _refused("logs", "US-EAST-1", False, False, "not a valid AWS region")
    _refused("logs", "us-east-1.evil.com", False, False, "not a valid AWS region")
    var ep = aws_service_endpoint("logs", "us-east-1", False, False)
    assert_equal(ep.scheme, "https")
    assert_equal(ep.port, 443)
    assert_equal(ep.base_path, "")


def test_parse_endpoint_url() raises:
    var e = AwsEndpoint.parse("http://localhost:4566", "T")
    assert_equal(e.scheme, "http")
    assert_equal(e.host, "localhost")
    assert_equal(e.port, 4566)
    assert_equal(e.host_header(), "localhost:4566")
    assert_equal(e.url_for("/"), "http://localhost:4566/")
    e = AwsEndpoint.parse("HTTPS://Example.COM/", "T")
    assert_equal(e.scheme, "https")
    assert_equal(e.host, "example.com")
    assert_equal(e.port, 443)
    assert_equal(e.host_header(), "example.com")
    assert_equal(e.base_path, "")
    e = AwsEndpoint.parse("https://proxy.example.com:8443/aws/sqs/", "T")
    assert_equal(e.base_path, "/aws/sqs")
    assert_equal(e.target_for("/"), "/aws/sqs/")
    assert_equal(e.target_for("/q?x=1"), "/aws/sqs/q?x=1")
    assert_equal(e.host_header(), "proxy.example.com:8443")
    # botocore's _urljoin keeps the endpoint path exactly on the root target:
    # "/proxy" stays "/proxy" (no slash added), "/proxy/" stays "/proxy/".
    e = AwsEndpoint.parse("https://h.example.com/proxy", "T")
    assert_equal(e.target_for("/"), "/proxy")
    assert_equal(e.target_for("/q"), "/proxy/q")
    assert_equal(e.url_for("/"), "https://h.example.com/proxy")
    var pre = e.with_host_prefix("data-")
    assert_equal(pre.target_for("/"), "/proxy", "the host prefix lost the path")
    assert_equal(pre.host, "data-h.example.com")
    e = AwsEndpoint.parse("https://h.example.com/proxy/", "T")
    assert_equal(e.target_for("/"), "/proxy/")
    assert_equal(e.target_for("/q"), "/proxy/q")
    pre = e.with_host_prefix("data-")
    assert_equal(pre.target_for("/"), "/proxy/", "the host prefix lost the slash")
    e = AwsEndpoint.parse("http://[fd00:ec2::254]:8080", "T")
    assert_equal(e.host, "[fd00:ec2::254]")
    assert_equal(e.port, 8080)
    e = AwsEndpoint.parse("http://127.0.0.1", "T")
    assert_equal(e.port, 80)
    assert_equal(e.host_header(), "127.0.0.1")

    var bad: List[List[String]] = [
        ["localhost:4566", "no scheme"],
        ["ftp://example.com", "other than http"],
        ["https://user:pw@example.com", "user info"],
        ["https://example.com/?a=b", "query or a fragment"],
        ["https://example.com/#f", "query or a fragment"],
        ["https://example.com:0", "outside 1..65535"],
        ["https://example.com:70000", "outside 1..65535"],
        ["https://example.com:4x", "malformed port"],
        ["https://", "empty host"],
        ["https://exa_mple.com", "outside [a-z0-9.-]"],
        ["https://example.com\r\nX: y", "control byte"],
        ["https://[fd00::1", "unterminated IPv6"],
    ]
    for i in range(len(bad)):
        var row = bad[i].copy()
        try:
            _ = AwsEndpoint.parse(row[0], "SETTING_X")
            raise Error("accepted: " + row[0])
        except err:
            var m = String(err)
            assert_true(m.find(row[1]) >= 0, row[0] + " -> " + m)
            assert_true(m.find("SETTING_X") >= 0, "the setting is not named: " + m)
            if row[0].find("pw@") >= 0:
                assert_true(m.find("pw") < 0, "the URL leaked into the error")


def test_host_prefix_and_resolve() raises:
    var e = AwsEndpoint.https("data.mediastore.us-east-1.amazonaws.com")
    assert_equal(e.with_host_prefix("").host, e.host)
    assert_equal(
        e.with_host_prefix("abc-").host,
        "abc-data.mediastore.us-east-1.amazonaws.com",
    )
    try:
        _ = AwsEndpoint.parse("http://127.0.0.1:4566", "T").with_host_prefix("x.")
        raise Error("prefixed an IP host")
    except err:
        assert_true(String(err).find("IP-literal") >= 0, String(err))
    try:
        _ = e.with_host_prefix("a b.")
        raise Error("accepted a bad prefix")
    except err:
        assert_true(String(err).find("[a-z0-9.-]") >= 0, String(err))

    var none = Optional[AwsEndpoint]()
    var r = resolve_endpoint(none, "sqs.us-east-1.amazonaws.com")
    assert_equal(r.url_for("/"), "https://sqs.us-east-1.amazonaws.com/")
    var some = Optional[AwsEndpoint](AwsEndpoint.parse("http://localhost:4566", "T"))
    r = resolve_endpoint(some, "sqs.us-east-1.amazonaws.com")
    assert_equal(r.url_for("/"), "http://localhost:4566/")


def test_service_env_var_name() raises:
    assert_equal(service_endpoint_env_var("SQS"), "AWS_ENDPOINT_URL_SQS")
    assert_equal(
        service_endpoint_env_var("Secrets Manager"),
        "AWS_ENDPOINT_URL_SECRETS_MANAGER",
    )
    assert_equal(
        service_endpoint_env_var("CloudWatch Logs"),
        "AWS_ENDPOINT_URL_CLOUDWATCH_LOGS",
    )
    assert_equal(
        service_endpoint_env_var("ApiGatewayV2"), "AWS_ENDPOINT_URL_APIGATEWAYV2"
    )


def _cfg_url(mut env: MapEnv, mut files: MapFiles) raises -> String:
    var c = aws_endpoint_config(
        AwsCredentialParams(), env, files, "SQS", "AWS_ENDPOINT_URL_SQS"
    )
    if not c.endpoint:
        return String("<aws>")
    return c.endpoint.value().url_for("/") + " from " + c.endpoint_setting


comptime _CFG = "/home/u/.aws/config"


def _env_with_config() -> MapEnv:
    var env = MapEnv()
    env.set("AWS_CONFIG_FILE", _CFG)
    env.set("AWS_SHARED_CREDENTIALS_FILE", "/home/u/.aws/credentials")
    return env^


def test_configured_endpoint_precedence() raises:
    var files = MapFiles()
    files.put(
        _CFG,
        "[default]\nendpoint_url = http://profile.example:1111\n"
        "[profile svc]\nservices = local\n"
        "[profile ign]\nignore_configured_endpoint_urls = true\n"
        "endpoint_url = http://never.example\n"
        "[profile fips]\nuse_fips_endpoint = true\nuse_dualstack_endpoint = TRUE\n",
    )

    # 1. Nothing set in the environment: the profile's endpoint_url.
    var env = _env_with_config()
    assert_equal(
        _cfg_url(env, files),
        "http://profile.example:1111/ from the endpoint_url of profile 'default'",
    )
    # 2. AWS_ENDPOINT_URL beats the profile.
    env.set("AWS_ENDPOINT_URL", "http://global.example:2222")
    assert_equal(
        _cfg_url(env, files), "http://global.example:2222/ from AWS_ENDPOINT_URL"
    )
    # 3. AWS_ENDPOINT_URL_<SERVICE> beats AWS_ENDPOINT_URL.
    env.set("AWS_ENDPOINT_URL_SQS", "http://sqs.example:3333")
    assert_equal(
        _cfg_url(env, files), "http://sqs.example:3333/ from AWS_ENDPOINT_URL_SQS"
    )
    # Another service's variable is not read for SQS.
    var env_other = _env_with_config()
    env_other.set("AWS_ENDPOINT_URL_SNS", "http://sns.example:4444")
    assert_equal(
        _cfg_url(env_other, files),
        "http://profile.example:1111/ from the endpoint_url of profile 'default'",
    )
    # 4. AWS_IGNORE_CONFIGURED_ENDPOINT_URLS switches every one off.
    env.set("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "true")
    assert_equal(_cfg_url(env, files), "<aws>")
    var env_i = _env_with_config()
    env_i.set("AWS_ENDPOINT_URL_SQS", "http://sqs.example:3333")
    env_i.set("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "TRUE")
    assert_equal(_cfg_url(env_i, files), "<aws>")
    assert_false(env_i.was_read("AWS_ENDPOINT_URL_SQS"), "read after ignore=true")
    # ... and "false" does not.
    env.set("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "false")
    assert_equal(
        _cfg_url(env, files), "http://sqs.example:3333/ from AWS_ENDPOINT_URL_SQS"
    )
    # 5. The profile's ignore setting, when the environment says nothing.
    var env_ign = _env_with_config()
    env_ign.set("AWS_PROFILE", "ign")
    assert_equal(_cfg_url(env_ign, files), "<aws>")
    # 6. A profile with a services section is refused, not sent to AWS.
    var env_svc = _env_with_config()
    env_svc.set("AWS_PROFILE", "svc")
    try:
        _ = _cfg_url(env_svc, files)
        raise Error("a services section was ignored")
    except err:
        assert_true(String(err).find("services section") >= 0, String(err))
    # ... but an environment endpoint still wins before the profile is asked.
    env_svc.set("AWS_ENDPOINT_URL", "http://global.example:2222")
    assert_equal(
        _cfg_url(env_svc, files),
        "http://global.example:2222/ from AWS_ENDPOINT_URL",
    )
    # 7. A named profile that does not exist is refused.
    var env_missing = _env_with_config()
    env_missing.set("AWS_PROFILE", "nope")
    try:
        _ = _cfg_url(env_missing, files)
        raise Error("a missing profile was accepted")
    except err:
        assert_true(String(err).find("'nope'") >= 0, String(err))
    # 8. A malformed URL names its variable, not its value.
    var env_bad = _env_with_config()
    env_bad.set("AWS_ENDPOINT_URL_SQS", "https://k:SECRETVALUE@x.example")
    try:
        _ = _cfg_url(env_bad, files)
        raise Error("a URL with user info was accepted")
    except err:
        var m = String(err)
        assert_true(m.find("AWS_ENDPOINT_URL_SQS") >= 0, m)
        assert_true(m.find("SECRETVALUE") < 0, "the URL leaked: " + m)
    # 9. The variable name must match the service id.
    try:
        _ = aws_endpoint_config(
            AwsCredentialParams(), env, files, "SNS", "AWS_ENDPOINT_URL_SQS"
        )
        raise Error("a mismatched variable was accepted")
    except err:
        assert_true(String(err).find("service id 'SNS'") >= 0, String(err))


def test_fips_and_dual_stack_switches() raises:
    var files = MapFiles()
    files.put(
        _CFG,
        "[profile fips]\nuse_fips_endpoint = true\nuse_dualstack_endpoint = TRUE\n"
        "[profile junk]\nuse_fips_endpoint = maybe\n",
    )
    var env = _env_with_config()
    var c = aws_endpoint_config(
        AwsCredentialParams(), env, files, "SQS", "AWS_ENDPOINT_URL_SQS"
    )
    assert_false(c.use_fips)
    assert_false(c.use_dual_stack)
    assert_false(c.endpoint.__bool__())
    env.set("AWS_PROFILE", "fips")
    c = aws_endpoint_config(
        AwsCredentialParams(), env, files, "SQS", "AWS_ENDPOINT_URL_SQS"
    )
    assert_true(c.use_fips)
    assert_true(c.use_dual_stack)
    # The environment beats the profile, both ways.
    env.set("AWS_USE_FIPS_ENDPOINT", "false")
    env.set("AWS_USE_DUALSTACK_ENDPOINT", "false")
    c = aws_endpoint_config(
        AwsCredentialParams(), env, files, "SQS", "AWS_ENDPOINT_URL_SQS"
    )
    assert_false(c.use_fips)
    assert_false(c.use_dual_stack)
    # The explicit profile parameter beats AWS_PROFILE.
    var params = AwsCredentialParams()
    params.profile = String("junk")
    try:
        _ = aws_endpoint_config(params, env, files, "SQS", "AWS_ENDPOINT_URL_SQS")
    except err:
        raise Error("the env switch should win over profile junk: " + String(err))
    var env2 = _env_with_config()
    try:
        _ = aws_endpoint_config(params, env2, files, "SQS", "AWS_ENDPOINT_URL_SQS")
        raise Error("use_fips_endpoint = maybe was accepted")
    except err:
        assert_true(
            String(err).find("use_fips_endpoint of profile 'junk'") >= 0,
            String(err),
        )


def main() raises:
    test_partition_table()
    test_parse_endpoint_url()
    test_host_prefix_and_resolve()
    test_service_env_var_name()
    test_configured_endpoint_precedence()
    test_fips_and_dual_stack_switches()
    print("OK")
