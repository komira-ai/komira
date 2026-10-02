# =============================================================================
# komira_aws_core/tests/test_credential_chain.mojo
# =============================================================================
#
# The default credential chain and region resolution, hermetically: MapEnv,
# MapFiles, a FixedClock and a scripted CredentialTransport that answers the
# STS, container and instance-metadata endpoints.
#
#   * precedence across EVERY pair of the six steps: with exactly two
#     configured, the earlier one answers;
#   * AWS_EC2_METADATA_DISABLED switches instance metadata off (no request
#     is sent) and only "true" (any case) does;
#   * profile resolution: AWS_PROFILE, role_arn + source_profile (signed
#     AssumeRole), web_identity_token_file, credential_source, loops,
#     credential_process refused by name, a region-only profile falling
#     through; the success arm of credential_source EcsContainer and
#     Ec2InstanceMetadata and of a two-hop role chain, each AssumeRole
#     signed with the source's temporary key and session token;
#   * a region outside the aws / aws-us-gov partitions refused at STS,
#     naming its setting;
#   * region order: parameter, AWS_REGION, AWS_DEFAULT_REGION, profile;
#   * refusals name the setting and never carry a secret value;
#   * every environment read the chain makes is a standard AWS SDK variable
#     (or HOME), seen through the EnvSource.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AwsCredential,
    AwsCredentialParams,
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
    FixedClock,
    MapEnv,
    MapFiles,
    ResolvedAwsCredential,
    resolve_aws_credentials,
    resolve_aws_region,
)


comptime _FIX = "src/komira_aws_core/tests/fixtures/"
comptime _ENV_SECRET = "FAKEenvSecretKeyEXAMPLEKEY00000000000000"
comptime _PROFILE_SECRET = "FAKEprofileSecretKeyEXAMPLEKEY0000000000"
comptime _WEB_TOKEN = "eyJFAKE.eyJFAKE-TOKEN.c2lnbmF0dXJl"
comptime _CONTAINER_AUTH = "FAKE-CONTAINER-AUTH-TOKEN"


def _read(name: String) raises -> String:
    with open(String(_FIX) + name, "r") as f:
        return f.read()


struct Scripted(CredentialTransport, Movable):
    """Answers the endpoints the chain may call. Records each request."""

    var imds_up: Bool
    var sent: List[CredentialHttpRequest]
    var sts_web: String
    var sts_role: String
    var container: String
    var imds_creds: String

    def __init__(out self, imds_up: Bool) raises:
        self.imds_up = imds_up
        self.sent = List[CredentialHttpRequest]()
        self.sts_web = _read("sts_assume_role_with_web_identity.response.xml")
        self.sts_role = _read("sts_assume_role.response.xml")
        self.container = _read("container.response.json")
        self.imds_creds = _read("imds_credentials.response.json")

    def send(
        mut self, req: CredentialHttpRequest
    ) raises -> CredentialHttpResponse:
        self.sent.append(req.copy())
        if req.host.startswith("sts."):
            if req.body.find("Action=AssumeRoleWithWebIdentity&") >= 0:
                return CredentialHttpResponse(200, self.sts_web)
            if req.body.find("Action=AssumeRole&") >= 0:
                return CredentialHttpResponse(200, self.sts_role)
        if req.host == "169.254.170.2" or req.host == "169.254.170.23":
            return CredentialHttpResponse(200, self.container)
        if self.imds_up and (
            req.host == "169.254.169.254" or req.host == "[fd00:ec2::254]"
        ):
            if req.target == "/latest/api/token":
                return CredentialHttpResponse(200, String("FAKE-IMDS-TOKEN"))
            if req.target == "/latest/meta-data/iam/security-credentials/":
                return CredentialHttpResponse(200, String("example-instance-role"))
            if req.target.endswith("/example-instance-role"):
                return CredentialHttpResponse(200, self.imds_creds)
        raise Error("connection refused")

    def hosts(self) -> String:
        var out = String("")
        for i in range(len(self.sent)):
            out += self.sent[i].method + " " + self.sent[i].host + self.sent[i].target + ";"
        return out


# The six steps, in chain order, and what each yields.
comptime _N = 6


def _label(k: Int) -> String:
    if k == 0:
        return String("parameter")
    if k == 1:
        return String("environment")
    if k == 2:
        return String("web-identity")
    if k == 3:
        return String("profile default")
    if k == 4:
        return String("container")
    return String("instance-metadata")


def _key(k: Int) -> String:
    if k == 0:
        return String("AKIDPARAMETER")
    if k == 1:
        return String("AKIDENVIRONMENT")
    if k == 2:
        return String("ASIAWEBIDENTITYEXAMPL")
    if k == 3:
        return String("AKIDPROFILE")
    if k == 4:
        return String("ASIACONTAINEREXAMPLE")
    return String("ASIAINSTANCEEXAMPLE0")


def _configure(
    k: Int, mut params: AwsCredentialParams, mut env: MapEnv, mut files: MapFiles
):
    if k == 0:
        params.credential = AwsCredential(
            String("AKIDPARAMETER"), String("param-secret"), String("")
        )
    elif k == 1:
        env.set("AWS_ACCESS_KEY_ID", "AKIDENVIRONMENT")
        env.set("AWS_SECRET_ACCESS_KEY", _ENV_SECRET)
    elif k == 2:
        env.set("AWS_WEB_IDENTITY_TOKEN_FILE", "/var/run/token")
        env.set("AWS_ROLE_ARN", "arn:aws:iam::123456789012:role/example-web-role")
        env.set("AWS_ROLE_SESSION_NAME", "komira-test")
        files.put("/var/run/token", String(_WEB_TOKEN) + "\n")
    elif k == 3:
        files.put(
            "/home/u/.aws/credentials",
            "[default]\naws_access_key_id = AKIDPROFILE\n"
            "aws_secret_access_key = " + String(_PROFILE_SECRET) + "\n",
        )
    elif k == 4:
        env.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example-task-id")


# Every variable the chain may read: the standard AWS SDK settings and HOME.
def _standard_names() -> List[String]:
    return [
        "HOME",
        "AWS_PROFILE",
        "AWS_CONFIG_FILE",
        "AWS_SHARED_CREDENTIALS_FILE",
        "AWS_REGION",
        "AWS_DEFAULT_REGION",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
        "AWS_ROLE_ARN",
        "AWS_ROLE_SESSION_NAME",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
        "AWS_EC2_METADATA_DISABLED",
        "AWS_EC2_METADATA_SERVICE_ENDPOINT",
        "AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE",
    ]


def _only_standard_reads(env: MapEnv) raises:
    var allowed = _standard_names()
    for i in range(len(env.reads)):
        var ok = False
        for j in range(len(allowed)):
            if allowed[j] == env.reads[i]:
                ok = True
        assert_true(ok, "the chain read a non-standard variable " + env.reads[i])


def _run(
    params: AwsCredentialParams, mut env: MapEnv, mut files: MapFiles, mut t: Scripted
) raises -> ResolvedAwsCredential:
    var clock = FixedClock(1789473600)
    var r = resolve_aws_credentials(params, env, files, t, clock)
    _only_standard_reads(env)
    return r^


def _refused(
    params: AwsCredentialParams,
    var env: MapEnv,
    mut files: MapFiles,
    imds_up: Bool,
    needle: String,
) raises:
    var t = Scripted(imds_up)
    try:
        _ = _run(params, env, files, t)
    except e:
        var msg = String(e)
        assert_true(msg.find(needle) >= 0, msg)
        var secrets: List[String] = [_ENV_SECRET, _PROFILE_SECRET, _WEB_TOKEN, _CONTAINER_AUTH]
        for secret in secrets:
            assert_true(msg.find(secret) < 0, "a refusal carried a secret: " + msg)
        _only_standard_reads(env)
        return
    raise Error("expected a refusal containing: " + needle)


def test_every_pair() raises:
    var pairs = 0
    for i in range(_N):
        for j in range(i + 1, _N):
            var params = AwsCredentialParams()
            var env = MapEnv()
            env.set("HOME", "/home/u")
            var files = MapFiles()
            _configure(i, params, env, files)
            _configure(j, params, env, files)
            var t = Scripted(j == _N - 1)
            var r = _run(params, env, files, t)
            var what = _label(i) + " before " + _label(j)
            assert_equal(r.source, _label(i), what)
            assert_equal(r.credential.access_key_id, _key(i), what)
            pairs += 1
    assert_equal(pairs, 15)
    # And each step alone, so a step that never answers cannot pass above.
    for k in range(_N):
        var params = AwsCredentialParams()
        var env = MapEnv()
        env.set("HOME", "/home/u")
        var files = MapFiles()
        _configure(k, params, env, files)
        var t = Scripted(k == _N - 1)
        var r = _run(params, env, files, t)
        assert_equal(r.source, _label(k))
        assert_equal(r.credential.access_key_id, _key(k))


def test_explicit_reads_nothing() raises:
    var params = AwsCredentialParams()
    params.credential = AwsCredential(String("AKIDP"), String("s"), String(""))
    var env = MapEnv()
    env.set("AWS_ACCESS_KEY_ID", "AKIDENVIRONMENT")
    var files = MapFiles()
    var t = Scripted(True)
    var r = _run(params, env, files, t)
    assert_equal(r.credential.access_key_id, "AKIDP")
    assert_equal(len(env.reads), 0)
    assert_equal(len(files.reads), 0)
    assert_equal(len(t.sent), 0)


def test_env_keys_and_partials() raises:
    var params = AwsCredentialParams()
    var env = MapEnv()
    env.set("AWS_ACCESS_KEY_ID", "AKIDENVIRONMENT")
    env.set("AWS_SECRET_ACCESS_KEY", _ENV_SECRET)
    env.set("AWS_SESSION_TOKEN", "FAKE-ENV-SESSION-TOKEN")
    var files = MapFiles()
    var t = Scripted(False)
    var r = _run(params, env, files, t)
    assert_equal(r.credential.session_token, "FAKE-ENV-SESSION-TOKEN")
    assert_true(env.was_read("AWS_SESSION_TOKEN"))

    var a = MapEnv()
    a.set("AWS_ACCESS_KEY_ID", "AKIDENVIRONMENT")
    _refused(params, a^, files, True, "AWS_ACCESS_KEY_ID is set but AWS_SECRET_ACCESS_KEY is not")
    var b = MapEnv()
    b.set("AWS_SECRET_ACCESS_KEY", _ENV_SECRET)
    _refused(params, b^, files, True, "AWS_SECRET_ACCESS_KEY is set but AWS_ACCESS_KEY_ID is not")
    var c = MapEnv()
    c.set("AWS_ROLE_ARN", "arn:aws:iam::123456789012:role/r")
    _refused(params, c^, files, True, "AWS_ROLE_ARN is set but AWS_WEB_IDENTITY_TOKEN_FILE is not")
    var d = MapEnv()
    d.set("AWS_WEB_IDENTITY_TOKEN_FILE", "/missing")
    d.set("AWS_ROLE_ARN", "arn:aws:iam::123456789012:role/r")
    _refused(params, d^, files, True, "named by AWS_WEB_IDENTITY_TOKEN_FILE")


def test_web_identity_region_and_default_session() raises:
    var params = AwsCredentialParams()
    var env = MapEnv()
    env.set("AWS_WEB_IDENTITY_TOKEN_FILE", "/t")
    env.set("AWS_ROLE_ARN", "arn:aws:iam::123456789012:role/example-web-role")
    env.set("AWS_REGION", "eu-central-1")
    var files = MapFiles()
    files.put("/t", _WEB_TOKEN)
    var t = Scripted(False)
    var r = _run(params, env, files, t)
    assert_equal(r.source, "web-identity")
    assert_equal(r.expiration, "2026-09-15T13:00:00Z")
    assert_equal(len(t.sent), 1)
    assert_equal(t.sent[0].host, "sts.eu-central-1.amazonaws.com")
    # No AWS_ROLE_SESSION_NAME: the default carries the clock's time.
    assert_true(
        t.sent[0].body.find("RoleSessionName=komira-aws-1789473600&") >= 0,
        t.sent[0].body,
    )


def test_imds_disabled_switch() raises:
    var params = AwsCredentialParams()
    var files = MapFiles()
    var on: List[String] = ["true", "TRUE", " True "]
    for spelling in on:
        var env = MapEnv()
        env.set("AWS_EC2_METADATA_DISABLED", spelling)
        var t = Scripted(True)
        try:
            _ = _run(params, env, files, t)
            raise Error("instance metadata answered while disabled")
        except e:
            assert_true(
                String(e).find("disabled by AWS_EC2_METADATA_DISABLED") >= 0,
                String(e),
            )
        assert_equal(len(t.sent), 0, "a request was sent while disabled")
    var off: List[String] = ["false", "", "1", "yes"]
    for spelling in off:
        var env = MapEnv()
        env.set("AWS_EC2_METADATA_DISABLED", spelling)
        var t = Scripted(True)
        var r = _run(params, env, files, t)
        assert_equal(r.source, "instance-metadata")
        assert_equal(len(t.sent), 3)
        assert_equal(t.sent[0].method, "PUT")
    # Not on EC2 (no answer): the chain's final refusal says why.
    var env = MapEnv()
    _refused(params, env^, files, False, "no answer to the IMDSv2 token request")
    # IPv6 mode reaches the IPv6 endpoint.
    var v6 = MapEnv()
    v6.set("AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE", "IPv6")
    var t = Scripted(True)
    _ = _run(params, v6, files, t)
    assert_equal(t.sent[0].host, "[fd00:ec2::254]")


def _profile_env(profile: String) -> MapEnv:
    var env = MapEnv()
    env.set("HOME", "/home/u")
    if profile.byte_length() > 0:
        env.set("AWS_PROFILE", profile)
    return env^


def test_profiles() raises:
    var files = MapFiles()
    files.put(
        "/home/u/.aws/config",
        "[default]\nregion = us-west-2\n"
        "[profile dev]\nrole_arn = arn:aws:iam::123456789012:role/example-role\n"
        "source_profile = base\nrole_session_name = komira-test\n"
        "external_id = example-external-id\nduration_seconds = 1800\n"
        "[profile wif]\nrole_arn = arn:aws:iam::123456789012:role/example-web-role\n"
        "web_identity_token_file = /t\n"
        "[profile loop1]\nrole_arn = arn:aws:iam::123456789012:role/a\nsource_profile = loop2\n"
        "[profile loop2]\nrole_arn = arn:aws:iam::123456789012:role/b\nsource_profile = loop1\n"
        "[profile self]\nrole_arn = arn:aws:iam::123456789012:role/s\nsource_profile = self\n"
        "aws_access_key_id = AKIDSELF\naws_secret_access_key = selfsecret\n"
        "[profile both]\nrole_arn = arn:aws:iam::123456789012:role/b\nsource_profile = base\n"
        "credential_source = Environment\n"
        "[profile envsrc]\nrole_arn = arn:aws:iam::123456789012:role/e\n"
        "credential_source = Environment\n"
        "[profile badsrc]\nrole_arn = arn:aws:iam::123456789012:role/e\n"
        "credential_source = Somewhere\n"
        "[profile proc]\ncredential_process = /bin/print-creds\n"
        "[profile sso]\nsso_session = corp\n"
        "[profile half]\naws_access_key_id = AKIDHALF\n"
        "[profile dangling]\nrole_arn = arn:aws:iam::123456789012:role/d\nsource_profile = nobody\n",
    )
    files.put(
        "/home/u/.aws/credentials",
        "[base]\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\n"
        "aws_secret_access_key = " + String(_PROFILE_SECRET) + "\n",
    )
    files.put("/t", _WEB_TOKEN)
    var params = AwsCredentialParams()

    # role_arn + source_profile: a signed AssumeRole to the profile's region.
    var env = _profile_env(String("dev"))
    var t = Scripted(False)
    var r = _run(params, env, files, t)
    assert_equal(r.source, "profile dev")
    assert_equal(r.credential.access_key_id, "ASIAASSUMEDROLEEXAMPL")
    assert_equal(len(t.sent), 1)
    # dev has no region of its own and default's region is not inherited.
    assert_equal(t.sent[0].host, "sts.amazonaws.com")
    assert_true(
        t.sent[0].header("Authorization").find(
            "Credential=AKIAIOSFODNN7EXAMPLE/20260915/us-east-1/sts/aws4_request"
        ) >= 0,
        t.sent[0].header("Authorization"),
    )
    # The signing time is the FixedClock, to the second.
    assert_equal(t.sent[0].header("X-Amz-Date"), "20260915T120000Z")
    # A static source carries no session token.
    assert_equal(t.sent[0].header("X-Amz-Security-Token"), "")
    assert_true(t.sent[0].body.find("ExternalId=example-external-id") >= 0)
    assert_true(t.sent[0].body.find("DurationSeconds=1800") >= 0)
    # The explicit profile parameter wins over AWS_PROFILE; AWS_REGION reaches STS.
    var p2 = AwsCredentialParams()
    p2.profile = String("dev")
    var env2 = _profile_env(String("nonexistent"))
    env2.set("AWS_REGION", "us-west-2")
    var t2 = Scripted(False)
    _ = _run(p2, env2, files, t2)
    assert_equal(t2.sent[0].host, "sts.us-west-2.amazonaws.com")

    # role_arn + web_identity_token_file in a profile.
    var e3 = _profile_env(String("wif"))
    var t3 = Scripted(False)
    r = _run(params, e3, files, t3)
    assert_equal(r.credential.access_key_id, "ASIAWEBIDENTITYEXAMPL")
    assert_true(t3.sent[0].body.find("Action=AssumeRoleWithWebIdentity&") >= 0)

    # A profile that is its own source uses its own static keys.
    var e4 = _profile_env(String("self"))
    var t4 = Scripted(False)
    r = _run(params, e4, files, t4)
    assert_true(
        t4.sent[0].header("Authorization").find("Credential=AKIDSELF/") >= 0
    )

    # credential_source = Environment: with the keys set, the environment
    # step (2) answers before the profile step (4), as in the AWS SDKs;
    # without them the profile is refused naming the setting.
    var e5 = _profile_env(String("envsrc"))
    e5.set("AWS_ACCESS_KEY_ID", "AKIDENVIRONMENT")
    e5.set("AWS_SECRET_ACCESS_KEY", _ENV_SECRET)
    var t5 = Scripted(False)
    r = _run(params, e5, files, t5)
    assert_equal(r.source, "environment")
    assert_equal(len(t5.sent), 0)
    var p6 = AwsCredentialParams()
    p6.profile = String("envsrc")
    var e6 = _profile_env(String(""))
    var t6 = Scripted(False)
    try:
        _ = _run(p6, e6, files, t6)
        raise Error("credential_source Environment without keys was accepted")
    except e:
        assert_true(String(e).find("credential_source Environment") >= 0, String(e))

    _refused(params, _profile_env(String("loop1")), files, False, "loops back to 'loop1'")
    _refused(params, _profile_env(String("both")), files, False, "exactly one of source_profile")
    _refused(params, _profile_env(String("badsrc")), files, False, "unknown credential_source")
    _refused(params, _profile_env(String("proc")), files, False, "uses credential_process, which")
    _refused(params, _profile_env(String("sso")), files, False, "uses sso_session, which")
    _refused(params, _profile_env(String("half")), files, False, "sets only one of aws_access_key_id")
    _refused(params, _profile_env(String("dangling")), files, False, "source_profile 'nobody'")
    _refused(params, _profile_env(String("nobody")), files, False, "'nobody' is in neither shared file")

    # A region-only default profile holds no credential: the chain moves on.
    var only = MapFiles()
    only.put("/home/u/.aws/config", "[default]\nregion = us-west-2\n")
    var e7 = _profile_env(String(""))
    var t7 = Scripted(True)
    r = _run(params, e7, only, t7)
    assert_equal(r.source, "instance-metadata")


def test_container_auth_token() raises:
    var params = AwsCredentialParams()
    var files = MapFiles()
    files.put("/auth", String(_CONTAINER_AUTH) + "\n")
    var env = MapEnv()
    env.set("AWS_CONTAINER_CREDENTIALS_FULL_URI", "http://169.254.170.23/v1/credentials")
    env.set("AWS_CONTAINER_AUTHORIZATION_TOKEN", "FROM-ENV")
    env.set("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", "/auth")
    var t = Scripted(False)
    var r = _run(params, env, files, t)
    assert_equal(r.source, "container")
    # The token file wins over the token variable.
    assert_equal(t.sent[0].header("Authorization"), _CONTAINER_AUTH)
    var e2 = MapEnv()
    e2.set("AWS_CONTAINER_CREDENTIALS_FULL_URI", "http://169.254.170.23/v1/credentials")
    e2.set("AWS_CONTAINER_AUTHORIZATION_TOKEN", "FROM-ENV")
    var t2 = Scripted(False)
    _ = _run(params, e2, files, t2)
    assert_equal(t2.sent[0].header("Authorization"), "FROM-ENV")
    # RELATIVE_URI wins over FULL_URI and carries no token.
    var e3 = MapEnv()
    e3.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/x")
    e3.set("AWS_CONTAINER_CREDENTIALS_FULL_URI", "http://169.254.170.23/v1/credentials")
    e3.set("AWS_CONTAINER_AUTHORIZATION_TOKEN", "FROM-ENV")
    var t3 = Scripted(False)
    _ = _run(params, e3, files, t3)
    assert_equal(t3.sent[0].host, "169.254.170.2")
    assert_equal(t3.sent[0].header("Authorization"), "")
    var e4 = MapEnv()
    e4.set("AWS_CONTAINER_CREDENTIALS_FULL_URI", "http://evil.example.com/creds")
    _refused(params, e4^, files, False, "uses plain http to a host")
    var e5 = MapEnv()
    e5.set("AWS_CONTAINER_CREDENTIALS_FULL_URI", "https://creds.example.com/x")
    _refused(params, e5^, files, False, "the container credentials endpoint did not answer")


def _assume_role_signed_by(
    req: CredentialHttpRequest, key_id: String, session_token: String, role: String
) raises:
    """`req` is the STS AssumeRole for `role`, signed at the FixedClock time
    with `key_id`, carrying `session_token` ("" = none) as
    X-Amz-Security-Token."""
    assert_equal(req.host, "sts.amazonaws.com")
    assert_true(req.body.find("Action=AssumeRole&") >= 0, req.body)
    assert_true(req.body.find("RoleArn=" + role + "&") >= 0, req.body)
    assert_equal(req.header("X-Amz-Date"), "20260915T120000Z")
    assert_true(
        req.header("Authorization").find(
            "Credential=" + key_id + "/20260915/us-east-1/sts/aws4_request"
        ) >= 0,
        req.header("Authorization"),
    )
    assert_equal(req.header("X-Amz-Security-Token"), session_token)
    # A session token is signed (in SignedHeaders), not merely attached.
    assert_equal(
        req.header("Authorization").find("x-amz-security-token") >= 0,
        session_token.byte_length() > 0,
    )


def test_profile_credential_sources() raises:
    """The success arm of every role source: credential_source EcsContainer
    and Ec2InstanceMetadata (reached through the profile step, which runs
    before the container and instance-metadata steps), and a two-hop
    source_profile chain role -> role -> static. Each AssumeRole is signed
    with the SOURCE's temporary key and carries its session token."""
    var files = MapFiles()
    files.put(
        "/home/u/.aws/config",
        "[profile ecs]\nrole_arn = arn:aws:iam::123456789012:role/ecs-target\n"
        "credential_source = EcsContainer\nrole_session_name = komira-test\n"
        "[profile ec2]\nrole_arn = arn:aws:iam::123456789012:role/ec2-target\n"
        "credential_source = Ec2InstanceMetadata\nrole_session_name = komira-test\n"
        "[profile hop2]\nrole_arn = arn:aws:iam::123456789012:role/outer\n"
        "source_profile = hop1\nrole_session_name = komira-test\n"
        "[profile hop1]\nrole_arn = arn:aws:iam::123456789012:role/inner\n"
        "source_profile = base\nrole_session_name = komira-test\n",
    )
    files.put(
        "/home/u/.aws/credentials",
        "[base]\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\n"
        "aws_secret_access_key = " + String(_PROFILE_SECRET) + "\n",
    )
    var params = AwsCredentialParams()

    # credential_source = EcsContainer.
    var e1 = _profile_env(String("ecs"))
    e1.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example-task-id")
    var t1 = Scripted(False)
    var r = _run(params, e1, files, t1)
    assert_equal(r.source, "profile ecs")
    assert_equal(r.credential.access_key_id, "ASIAASSUMEDROLEEXAMPL")
    assert_equal(len(t1.sent), 2, t1.hosts())
    assert_equal(t1.sent[0].host, "169.254.170.2")
    _assume_role_signed_by(
        t1.sent[1],
        String("ASIACONTAINEREXAMPLE"),
        String("FAKE-CONTAINER-SESSION-TOKEN"),
        String("arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2Fecs-target"),
    )

    # credential_source = Ec2InstanceMetadata.
    var e2 = _profile_env(String("ec2"))
    var t2 = Scripted(True)
    r = _run(params, e2, files, t2)
    assert_equal(r.source, "profile ec2")
    assert_equal(r.credential.access_key_id, "ASIAASSUMEDROLEEXAMPL")
    assert_equal(len(t2.sent), 4, t2.hosts())
    assert_equal(t2.sent[0].host, "169.254.169.254")
    _assume_role_signed_by(
        t2.sent[3],
        String("ASIAINSTANCEEXAMPLE0"),
        String("FAKE-INSTANCE-SESSION-TOKEN"),
        String("arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2Fec2-target"),
    )

    # Two hops: hop2 -> hop1 -> base. The inner AssumeRole is signed with
    # the static base key (no token); the outer with the inner's assumed
    # temporary key and its session token.
    var e3 = _profile_env(String("hop2"))
    var t3 = Scripted(False)
    r = _run(params, e3, files, t3)
    assert_equal(r.source, "profile hop2")
    assert_equal(r.credential.access_key_id, "ASIAASSUMEDROLEEXAMPL")
    assert_equal(len(t3.sent), 2, t3.hosts())
    _assume_role_signed_by(
        t3.sent[0],
        String("AKIAIOSFODNN7EXAMPLE"),
        String(""),
        String("arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2Finner"),
    )
    _assume_role_signed_by(
        t3.sent[1],
        String("ASIAASSUMEDROLEEXAMPL"),
        String("FAKE-ASSUME-ROLE-SESSION-TOKEN"),
        String("arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2Fouter"),
    )


def _cn_web_identity_env() -> MapEnv:
    var env = MapEnv()
    env.set("AWS_WEB_IDENTITY_TOKEN_FILE", "/var/run/token")
    env.set("AWS_ROLE_ARN", "arn:aws-cn:iam::123456789012:role/example-web-role")
    env.set("AWS_REGION", "cn-north-1")
    return env^


def test_sts_partition_refused_by_setting() raises:
    """A region outside the 'aws' and 'aws-us-gov' partitions is refused at
    the STS call, naming the setting it came from; it is NOT refused for a
    credential that needs no STS call."""
    var files = MapFiles()
    files.put("/var/run/token", String(_WEB_TOKEN) + "\n")
    _refused(AwsCredentialParams(), _cn_web_identity_env(), files, False, "cn-north-1")
    _refused(AwsCredentialParams(), _cn_web_identity_env(), files, False, "from AWS_REGION")
    var p = AwsCredentialParams()
    p.region = String("cn-northwest-1")
    var e2 = MapEnv()
    e2.set("AWS_WEB_IDENTITY_TOKEN_FILE", "/var/run/token")
    e2.set("AWS_ROLE_ARN", "arn:aws-cn:iam::123456789012:role/example-web-role")
    _refused(p, e2^, files, False, "from the region parameter")
    # Static keys need no STS: the China region does not refuse them.
    var e3 = MapEnv()
    e3.set("AWS_ACCESS_KEY_ID", "AKIDENVIRONMENT")
    e3.set("AWS_SECRET_ACCESS_KEY", _ENV_SECRET)
    e3.set("AWS_REGION", "cn-north-1")
    var t3 = Scripted(False)
    var r = _run(AwsCredentialParams(), e3, files, t3)
    assert_equal(r.source, "environment")
    # us-gov-west-1 is in the aws-us-gov partition: its regional host.
    var e4 = MapEnv()
    e4.set("AWS_WEB_IDENTITY_TOKEN_FILE", "/var/run/token")
    e4.set("AWS_ROLE_ARN", "arn:aws-us-gov:iam::123456789012:role/example-web-role")
    e4.set("AWS_REGION", "us-gov-west-1")
    var t4 = Scripted(False)
    _ = _run(AwsCredentialParams(), e4, files, t4)
    assert_equal(t4.sent[0].host, "sts.us-gov-west-1.amazonaws.com")


def _refused_before_any_send(
    var env: MapEnv, mut files: MapFiles, imds_up: Bool, needles: List[String]
) raises:
    """Resolution refuses with every needle in the message and the transport
    saw ZERO requests: the refusal came before any source was reached."""
    var t = Scripted(imds_up)
    try:
        _ = _run(AwsCredentialParams(), env, files, t)
    except e:
        var msg = String(e)
        for n in needles:
            assert_true(msg.find(n) >= 0, "missing '" + n + "' in: " + msg)
        assert_equal(len(t.sent), 0, "sent before refusing: " + t.hosts())
        return
    raise Error("expected a refusal; sent: " + t.hosts())


def test_profile_role_sts_partition_refused_before_source() raises:
    """A profile role_arn whose region is in an unsupported STS partition is
    refused BEFORE its source credential is fetched (container, instance
    metadata or source_profile), naming the setting the region came from,
    not the generic 'the resolved region' of the later sts_host check."""
    var files = MapFiles()
    files.put(
        "/home/u/.aws/config",
        "[profile cnecs]\nrole_arn = arn:aws-cn:iam::123456789012:role/ecs-target\n"
        "credential_source = EcsContainer\nregion = cn-north-1\n"
        "[profile cnhop]\nrole_arn = arn:aws-cn:iam::123456789012:role/outer\n"
        "source_profile = cnecs\n",
    )
    # Region from the profile; the container endpoint is configured and
    # would answer, so a send would be observed.
    var e1 = _profile_env(String("cnecs"))
    e1.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example-task-id")
    _refused_before_any_send(
        e1^, files, True,
        [String("from the region of profile 'cnecs'"), String("cn-north-1")],
    )
    # Region from AWS_REGION, role sourced through source_profile.
    var e2 = _profile_env(String("cnhop"))
    e2.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example-task-id")
    e2.set("AWS_REGION", "cn-north-1")
    _refused_before_any_send(
        e2^, files, True,
        [String("from AWS_REGION"), String("cn-north-1")],
    )


def test_region_order() raises:
    var files = MapFiles()
    files.put(
        "/home/u/.aws/config",
        "[default]\nregion = ap-south-1\n[profile dev]\nregion = eu-west-1\n",
    )
    var params = AwsCredentialParams()
    var env = _profile_env(String(""))
    assert_equal(resolve_aws_region(params, env, files), "ap-south-1")
    env.set("AWS_PROFILE", "dev")
    assert_equal(resolve_aws_region(params, env, files), "eu-west-1")
    env.set("AWS_DEFAULT_REGION", "us-east-2")
    assert_equal(resolve_aws_region(params, env, files), "us-east-2")
    env.set("AWS_REGION", "us-west-1")
    assert_equal(resolve_aws_region(params, env, files), "us-west-1")
    params.region = String("ca-central-1")
    assert_equal(resolve_aws_region(params, env, files), "ca-central-1")
    var none = MapEnv()
    var nofiles = MapFiles()
    assert_equal(resolve_aws_region(AwsCredentialParams(), none, nofiles), "")
    var bad = MapEnv()
    bad.set("AWS_REGION", "us-east-1.evil.example.com")
    try:
        _ = resolve_aws_region(AwsCredentialParams(), bad, nofiles)
        raise Error("an invalid region was accepted")
    except e:
        assert_true(String(e).find("the region from AWS_REGION") >= 0, String(e))
        assert_true(String(e).find("evil") < 0, String(e))


def main() raises:
    test_every_pair()
    test_explicit_reads_nothing()
    test_env_keys_and_partials()
    test_web_identity_region_and_default_session()
    test_imds_disabled_switch()
    test_profiles()
    test_container_auth_token()
    test_region_order()
    test_profile_credential_sources()
    test_sts_partition_refused_by_setting()
    test_profile_role_sts_partition_refused_before_source()
    print("OK")
