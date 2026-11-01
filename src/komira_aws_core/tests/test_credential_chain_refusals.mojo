# =============================================================================
# komira_aws_core/tests/test_credential_chain_refusals.mojo
# =============================================================================
#
# The default chain's profile arms that test_credential_chain does not
# reach, hermetically (MapEnv, MapFiles, a FixedClock, a scripted transport
# whose STS answers one AssumeRole and whose instance metadata is down):
#
#   * a NAMED profile in neither file is refused by region resolution too;
#   * sso_start_url and login_session are refused by name;
#   * a profile that is its own source_profile needs static keys;
#   * the source_profile chain is bounded at MAX_SOURCE_PROFILE_DEPTH hops,
#     the bound itself allowed;
#   * a source_profile that yields nothing is refused;
#   * credential_source Environment, EcsContainer and Ec2InstanceMetadata,
#     each when its source answers and when it does not;
#   * AWS_WEB_IDENTITY_TOKEN_FILE without AWS_ROLE_ARN.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_aws_core import (
    MAX_SOURCE_PROFILE_DEPTH,
    AwsCredentialParams,
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
    EnvSource,
    FixedClock,
    MapEnv,
    MapFiles,
    ResolvedAwsCredential,
    resolve_aws_credentials,
    resolve_aws_region,
)


comptime _STS_ANSWER = (
    '<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">'
    "<AssumeRoleResult><Credentials><AccessKeyId>ASIAHOP</AccessKeyId>"
    "<SecretAccessKey>FAKEhopSecret</SecretAccessKey>"
    "<SessionToken>FAKE-HOP-TOKEN</SessionToken>"
    "<Expiration>2026-09-15T13:00:00Z</Expiration></Credentials>"
    "</AssumeRoleResult></AssumeRoleResponse>"
)


struct StsOnly(CredentialTransport, Movable):
    """Answers every STS AssumeRole; every other endpoint is unreachable."""

    var sent: List[CredentialHttpRequest]

    def __init__(out self):
        self.sent = List[CredentialHttpRequest]()

    def send(
        mut self, req: CredentialHttpRequest
    ) raises -> CredentialHttpResponse:
        self.sent.append(req.copy())
        if req.host.startswith("sts.") and req.body_text().find("Action=AssumeRole&") >= 0:
            return CredentialHttpResponse(200, String(_STS_ANSWER))
        raise Error("connection refused")


struct LateKeysEnv(EnvSource):
    """An environment whose static keys appear after the chain's first read
    of them (another thread of the process sets them): the chain's own
    environment step sees none, a later credential_source Environment
    sees them."""

    var inner: MapEnv
    var key_reads: Int

    def __init__(out self, var inner: MapEnv):
        self.inner = inner^
        self.key_reads = 0

    def get(mut self, name: StaticString) -> String:
        if name == "AWS_ACCESS_KEY_ID":
            self.key_reads += 1
            return String("AKIDLATE") if self.key_reads > 1 else String("")
        if name == "AWS_SECRET_ACCESS_KEY":
            return String("FAKElateSecret") if self.key_reads > 1 else String("")
        return self.inner.get(name)


def _env(profile: String) -> MapEnv:
    var env = MapEnv()
    env.set("HOME", "/home/u")
    if profile.byte_length() > 0:
        env.set("AWS_PROFILE", profile)
    return env^


def _files(config: String) -> MapFiles:
    var files = MapFiles()
    files.put("/home/u/.aws/config", config)
    return files^


def _resolve(
    var env: MapEnv, mut files: MapFiles, mut t: StsOnly
) raises -> ResolvedAwsCredential:
    var clock = FixedClock(1789473600)
    return resolve_aws_credentials(AwsCredentialParams(), env, files, t, clock)


def _refused(profile: String, config: String, want: String) raises:
    var files = _files(config)
    var t = StsOnly()
    try:
        _ = _resolve(_env(profile), files, t)
    except e:
        assert_equal(String(e), want)
        return
    raise Error("not refused: " + want)


comptime _ROLE = "role_arn = arn:aws:iam::123456789012:role/r\n"


def test_named_profile_missing_for_region() raises:
    var env = _env("nope")
    var files = MapFiles()
    try:
        _ = resolve_aws_region(AwsCredentialParams(), env, files)
        raise Error("an absent named profile was accepted")
    except e:
        assert_equal(String(e), "the AWS profile 'nope' is in neither shared file")
    # The default profile, absent, is no region and no refusal.
    var env2 = _env("")
    assert_equal(resolve_aws_region(AwsCredentialParams(), env2, files), "")


def test_unsupported_settings() raises:
    _refused(
        "s", "[profile s]\nsso_start_url = https://example.com/start\n",
        "profile 's' uses sso_start_url, which komira_aws_core does not support",
    )
    _refused(
        "l", "[profile l]\nlogin_session = x\n",
        "profile 'l' uses login_session, which komira_aws_core does not support",
    )


def test_own_source_profile_needs_keys() raises:
    _refused(
        "self", "[profile self]\n" + String(_ROLE) + "source_profile = self\n",
        "profile 'self' is its own source_profile but has no static keys",
    )


def _hops_config(hops: Int) -> String:
    """Profiles h0 .. h<hops-1>, each a role whose source is the next, and
    h<hops> with static keys."""
    var c = String("")
    for i in range(hops):
        c += (
            "[profile h" + String(i) + "]\n" + String(_ROLE)
            + "role_session_name = komira-test\n"
            + "source_profile = h" + String(i + 1) + "\n"
        )
    c += (
        "[profile h" + String(hops) + "]\naws_access_key_id = AKIDBASE\n"
        "aws_secret_access_key = FAKEbaseSecret\n"
    )
    return c^


def test_source_profile_depth_bound() raises:
    assert_equal(MAX_SOURCE_PROFILE_DEPTH, 8)
    # Eight hops: every role assumed in turn, innermost first.
    var files = _files(_hops_config(MAX_SOURCE_PROFILE_DEPTH))
    var t = StsOnly()
    var r = _resolve(_env("h0"), files, t)
    assert_equal(r.source, "profile h0")
    assert_equal(r.credential.access_key_id, "ASIAHOP")
    assert_equal(len(t.sent), MAX_SOURCE_PROFILE_DEPTH)
    assert_true(
        t.sent[0].header("Authorization").find("Credential=AKIDBASE/") >= 0,
        t.sent[0].header("Authorization"),
    )
    # Nine hops: refused before any request.
    var files9 = _files(_hops_config(MAX_SOURCE_PROFILE_DEPTH + 1))
    var t9 = StsOnly()
    try:
        _ = _resolve(_env("h0"), files9, t9)
        raise Error("a nine-hop source_profile chain was accepted")
    except e:
        assert_equal(String(e), "the source_profile chain is too long")
    assert_equal(len(t9.sent), 0)


def test_source_profile_yields_nothing() raises:
    _refused(
        "r",
        "[profile r]\n" + String(_ROLE) + "source_profile = empty\n"
        "[profile empty]\nregion = us-east-1\n",
        "source_profile 'empty' of profile 'r' yields no credential",
    )


def test_credential_sources() raises:
    # Environment: the keys the environment holds when the role is assumed.
    var files = _files(
        "[profile envsrc]\n" + String(_ROLE) + "credential_source = Environment\n"
        "role_session_name = komira-test\n"
    )
    var t = StsOnly()
    var env = LateKeysEnv(_env("envsrc"))
    var clock = FixedClock(1789473600)
    var r = resolve_aws_credentials(AwsCredentialParams(), env, files, t, clock)
    assert_equal(r.source, "profile envsrc")
    assert_equal(r.credential.access_key_id, "ASIAHOP")
    assert_equal(len(t.sent), 1)
    assert_true(
        t.sent[0].header("Authorization").find("Credential=AKIDLATE/") >= 0,
        t.sent[0].header("Authorization"),
    )
    # EcsContainer with neither container URI set.
    _refused(
        "ecs", "[profile ecs]\n" + String(_ROLE) + "credential_source = EcsContainer\n",
        "profile 'ecs' has credential_source EcsContainer but no"
        " AWS_CONTAINER_CREDENTIALS_RELATIVE_URI or _FULL_URI is set",
    )
    # Ec2InstanceMetadata with the service unreachable: the reason is named.
    var files2 = _files(
        "[profile ec2]\n" + String(_ROLE) + "credential_source = Ec2InstanceMetadata\n"
    )
    var t2 = StsOnly()
    try:
        _ = _resolve(_env("ec2"), files2, t2)
        raise Error("an unreachable instance metadata source was accepted")
    except e:
        var msg = String(e)
        assert_true(
            msg.startswith(
                "profile 'ec2' has credential_source Ec2InstanceMetadata but"
                " instance metadata is unavailable: "
            ),
            msg,
        )
        assert_true(
            msg.endswith("no answer to the IMDSv2 token request"), msg
        )


def test_web_identity_without_role() raises:
    var env = _env("")
    env.set("AWS_WEB_IDENTITY_TOKEN_FILE", "/t")
    var files = MapFiles()
    var t = StsOnly()
    try:
        _ = _resolve(env^, files, t)
        raise Error("a token file without a role was accepted")
    except e:
        assert_equal(
            String(e), "AWS_WEB_IDENTITY_TOKEN_FILE is set but AWS_ROLE_ARN is not"
        )


def main() raises:
    var failed = 0
    try:
        test_named_profile_missing_for_region()
    except e:
        print("FAIL test_named_profile_missing_for_region:", e)
        failed += 1
    try:
        test_unsupported_settings()
    except e:
        print("FAIL test_unsupported_settings:", e)
        failed += 1
    try:
        test_own_source_profile_needs_keys()
    except e:
        print("FAIL test_own_source_profile_needs_keys:", e)
        failed += 1
    try:
        test_source_profile_depth_bound()
    except e:
        print("FAIL test_source_profile_depth_bound:", e)
        failed += 1
    try:
        test_source_profile_yields_nothing()
    except e:
        print("FAIL test_source_profile_yields_nothing:", e)
        failed += 1
    try:
        test_credential_sources()
    except e:
        print("FAIL test_credential_sources:", e)
        failed += 1
    try:
        test_web_identity_without_role()
    except e:
        print("FAIL test_web_identity_without_role:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("OK")
