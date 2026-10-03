# The AwsCredsSource contract a generated client relies on, in the shape the
# client emitter writes it: a Movable client struct parametric over
# `T: AwsCredsSource`, moving the source in and handing it back out, and
# calling `credentials()` once per send. Then the cached default chain: a
# long-term credential is resolved once; a temporary one is re-resolved once
# it is inside the advisory window, and an already-expired answer is refused.
# The two windows are botocore's RefreshableCredentials, values and
# comparisons: advisory 15 min, mandatory 10 min, and a window applies only
# when the time left is STRICTLY LESS than its length (refresh_needed: `if
# seconds_remaining >= refresh_in: return False`). The boundary tests pin
# both edges: exactly 900 s left is cached, 899 refreshes; exactly 600 s left
# still falls back to the cached credential on a failed refresh, 599 raises.
# A failed refresh in the advisory window keeps the cached credential; one in
# the mandatory window raises, so a send never signs with a credential that
# has under ten minutes left. Differences from botocore that remain (see
# creds_source.mojo): an answer that has already expired is a failed refresh
# here, so in the advisory window it keeps the cached credential where
# botocore raises; an answer expiring in exactly 0 s counts as expired here
# (botocore: strictly past); time is whole seconds.

from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS,
    AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS,
    AwsCredential,
    AwsCredentialParams,
    AwsCredsSource,
    AwsEndpoint,
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
    DefaultChainCredsSource,
    FixedClock,
    MapEnv,
    MapFiles,
    StaticCredsSource,
    resolve_endpoint,
)


struct _ShapeClient[T: AwsCredsSource](Movable, Deinitable):
    """The fields and moves of a generated `<Svc>Client[C, T]`, without the
    connector (which needs the HTTP library)."""

    var _creds_source: Self.T
    var _region: String
    var _endpoint_override: Optional[AwsEndpoint]

    def __init__(
        out self,
        var creds_source: Self.T,
        region: String,
        endpoint_override: Optional[AwsEndpoint] = Optional[AwsEndpoint](),
    ):
        self._creds_source = creds_source^
        self._region = region
        self._endpoint_override = endpoint_override.copy()

    def into_creds_source(deinit self) -> Self.T:
        return self._creds_source^

    def signing_key_id(mut self) raises -> String:
        var cred = self._creds_source.credentials()
        return cred.access_key_id

    def host(self) raises -> String:
        return resolve_endpoint(
            self._endpoint_override,
            "sqs." + self._region + ".amazonaws.com",
        ).host_header()


struct _Container(CredentialTransport, Movable, Deinitable):
    """The container credentials endpoint, answering with a temporary
    credential that expires at `expires[i]` on the i-th call."""

    var expires: List[String]
    var calls: Int
    var down: Bool

    def __init__(out self, var expires: List[String]):
        self.expires = expires^
        self.calls = 0
        self.down = False

    def send(
        mut self, req: CredentialHttpRequest
    ) raises -> CredentialHttpResponse:
        if req.host != "169.254.170.2":
            raise Error("unexpected host " + req.host)
        if self.down:
            self.calls += 1
            raise Error("connection refused")
        var i = min(self.calls, len(self.expires) - 1)
        self.calls += 1
        var body = String('{"AccessKeyId":"ASIACONTAINER') + String(self.calls)
        body += '","SecretAccessKey":"FAKEsecret","Token":"FAKE-TOKEN",'
        body += '"Expiration":"' + self.expires[i] + '"}'
        return CredentialHttpResponse(200, body)


def test_shape_with_static_source() raises:
    var src = StaticCredsSource(
        AwsCredential(String("AKIDEXAMPLE"), String("FAKEsecret"), String(""))
    )
    var c = _ShapeClient[StaticCredsSource](src^, String("us-east-1"))
    assert_equal(c.signing_key_id(), "AKIDEXAMPLE")
    assert_equal(c.host(), "sqs.us-east-1.amazonaws.com")
    # The source threads through to the next client.
    var back = c^.into_creds_source()
    var c2 = _ShapeClient[StaticCredsSource](
        back^,
        String("eu-west-1"),
        Optional[AwsEndpoint](AwsEndpoint.parse("http://localhost:4566", "T")),
    )
    assert_equal(c2.signing_key_id(), "AKIDEXAMPLE")
    assert_equal(c2.host(), "localhost:4566")


# 2026-09-19T12:00:00Z
comptime _NOW = 1789819200


def test_chain_caches_long_term_keys() raises:
    var env = MapEnv()
    env.set("HOME", "/home/u")
    env.set("AWS_ACCESS_KEY_ID", "AKIDENVEXAMPLE")
    env.set("AWS_SECRET_ACCESS_KEY", "FAKEenvSecret")
    var src = DefaultChainCredsSource[MapEnv, MapFiles, _Container, FixedClock](
        AwsCredentialParams(),
        env^,
        MapFiles(),
        _Container(List[String]()),
        FixedClock(_NOW),
    )
    var c = _ShapeClient[
        DefaultChainCredsSource[MapEnv, MapFiles, _Container, FixedClock]
    ](src^, String("us-east-1"))
    for _ in range(3):
        assert_equal(c.signing_key_id(), "AKIDENVEXAMPLE")
    var back = c^.into_creds_source()
    assert_equal(back.resolutions, 1)
    back.clock.unix_seconds = _NOW + 100 * 86400
    _ = back.credentials()
    assert_equal(back.resolutions, 1, "a non-expiring credential was re-resolved")


def test_chain_refreshes_before_expiry() raises:
    var env = MapEnv()
    env.set("HOME", "/home/u")
    env.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example")
    var expires: List[String] = [
        "2026-09-19T13:00:00Z",  # an hour after _NOW
        "2026-09-19T14:00:00Z",
    ]
    var src = DefaultChainCredsSource[MapEnv, MapFiles, _Container, FixedClock](
        AwsCredentialParams(),
        env^,
        MapFiles(),
        _Container(expires^),
        FixedClock(_NOW),
    )
    assert_equal(src.credentials().access_key_id, "ASIACONTAINER1")
    # Exactly ADVISORY seconds left: not yet in the window (botocore's
    # `seconds_remaining >= refresh_in` is no refresh): cached.
    src.clock.unix_seconds = (
        _NOW + 3600 - AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS
    )
    assert_equal(src.credentials().access_key_id, "ASIACONTAINER1")
    assert_equal(src.transport.calls, 1)
    # One second less (ADVISORY - 1 left): in the window, re-resolved.
    src.clock.unix_seconds = (
        _NOW + 3600 - AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS + 1
    )
    assert_equal(src.credentials().access_key_id, "ASIACONTAINER2")
    assert_equal(src.transport.calls, 2)
    assert_equal(src.resolutions, 2)


def test_chain_refuses_an_expired_answer() raises:
    var env = MapEnv()
    env.set("HOME", "/home/u")
    env.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example")
    var expires: List[String] = ["2026-09-19T11:00:00Z"]
    var src = DefaultChainCredsSource[MapEnv, MapFiles, _Container, FixedClock](
        AwsCredentialParams(),
        env^,
        MapFiles(),
        _Container(expires^),
        FixedClock(_NOW),
    )
    try:
        _ = src.credentials()
        raise Error("an expired credential was handed out")
    except e:
        var m = String(e)
        assert_true(m.find("already expired") >= 0, m)
        assert_true(m.find("FAKE") < 0, "a secret is in the error: " + m)


def _container_source(
    var expires: List[String],
) -> DefaultChainCredsSource[MapEnv, MapFiles, _Container, FixedClock]:
    var env = MapEnv()
    env.set("HOME", "/home/u")
    env.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example")
    return DefaultChainCredsSource[MapEnv, MapFiles, _Container, FixedClock](
        AwsCredentialParams(),
        env^,
        MapFiles(),
        _Container(expires^),
        FixedClock(_NOW),
    )


def _assert_refresh_raises(
    mut src: DefaultChainCredsSource[MapEnv, MapFiles, _Container, FixedClock],
    expect: String,
) raises:
    var raised = False
    try:
        _ = src.credentials()
    except e:
        raised = True
        var m = String(e)
        assert_true(m.find(expect) >= 0, m)
        assert_true(m.find("FAKE") < 0, "a secret is in the error: " + m)
    assert_true(raised, "a credential in the mandatory window was handed out")


def test_windows_are_botocore_values() raises:
    assert_equal(AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS, 15 * 60)
    assert_equal(AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS, 10 * 60)


def test_failed_refresh_keeps_the_cached_credential_while_advisory() raises:
    var expires: List[String] = [
        "2026-09-19T13:00:00Z",  # an hour after _NOW
        "2026-09-19T15:00:00Z",
    ]
    var src = _container_source(expires^)
    assert_equal(src.credentials().access_key_id, "ASIACONTAINER1")
    assert_equal(src.resolutions, 1)
    # The first advisory second (ADVISORY - 1 left), the endpoint down: the
    # refresh is tried and the cached credential is kept.
    src.transport.down = True
    src.clock.unix_seconds = (
        _NOW + 3600 - AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS + 1
    )
    assert_equal(src.credentials().access_key_id, "ASIACONTAINER1")
    assert_equal(src.transport.calls, 2, "the refresh was not attempted")
    assert_equal(src.resolutions, 1)
    # Exactly MANDATORY seconds left: the last advisory-only second (not yet
    # mandatory, strictly less is), still cached, one try per send.
    src.clock.unix_seconds = (
        _NOW + 3600 - AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS
    )
    assert_equal(src.credentials().access_key_id, "ASIACONTAINER1")
    assert_equal(src.transport.calls, 3, "more than one try per send")
    assert_equal(src.resolutions, 1)
    # The first mandatory second (MANDATORY - 1 left): the failed refresh
    # raises.
    src.clock.unix_seconds = (
        _NOW + 3600 - AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS + 1
    )
    _assert_refresh_raises(src, "did not answer")
    assert_equal(src.transport.calls, 4)
    # One second before expiry: raises too. Signing with it would draw
    # ExpiredToken from AWS before the request is served.
    src.clock.unix_seconds = _NOW + 3600 - 1
    _assert_refresh_raises(src, "did not answer")
    # At expiry: raises.
    src.clock.unix_seconds = _NOW + 3600
    _assert_refresh_raises(src, "did not answer")
    assert_equal(src.resolutions, 1)
    # The endpoint back: a fresh credential, cached.
    src.transport.down = False
    assert_equal(src.credentials().access_key_id, "ASIACONTAINER7")
    assert_equal(src.resolutions, 2)


def test_expired_answer_is_a_failed_refresh() raises:
    # A refresh that answers with an already-expired credential is a failed
    # refresh: in the advisory window the cached credential is kept (botocore
    # raises here; see the header), in the mandatory window it raises.
    var expires: List[String] = [
        "2026-09-19T13:00:00Z",
        "2026-09-19T11:00:00Z",  # before _NOW
    ]
    var src = _container_source(expires^)
    assert_equal(src.credentials().access_key_id, "ASIACONTAINER1")
    # Exactly MANDATORY seconds left: still advisory, the cached one is kept.
    src.clock.unix_seconds = (
        _NOW + 3600 - AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS
    )
    assert_equal(src.credentials().access_key_id, "ASIACONTAINER1")
    assert_equal(src.transport.calls, 2)
    assert_equal(src.resolutions, 1)
    src.clock.unix_seconds = _NOW + 3600 - 10
    _assert_refresh_raises(src, "already expired")
    assert_equal(src.transport.calls, 3)
    assert_equal(src.resolutions, 1)


def test_answer_expiring_now_is_already_expired() raises:
    # The 0 s boundary of "already expired" (`expires_at <= now`; botocore's
    # _is_expired is strictly past, so it accepts this answer -- difference 2
    # in creds_source.mojo). Nothing is cached, so the refresh is mandatory
    # and the refusal raises instead of falling back to a cached credential.
    var at_now: List[String] = ["2026-09-19T12:00:00Z"]  # == _NOW
    var src = _container_source(at_now^)
    _assert_refresh_raises(src, "already expired")
    assert_equal(src.transport.calls, 1)
    assert_equal(src.resolutions, 0)
    # One second later is accepted: the boundary is exactly 0 s.
    var one_left: List[String] = ["2026-09-19T12:00:01Z"]  # _NOW + 1
    var ok = _container_source(one_left^)
    assert_equal(ok.credentials().access_key_id, "ASIACONTAINER1")
    assert_equal(ok.resolutions, 1)


def main() raises:
    test_shape_with_static_source()
    test_chain_caches_long_term_keys()
    test_chain_refreshes_before_expiry()
    test_chain_refuses_an_expired_answer()
    test_windows_are_botocore_values()
    test_failed_refresh_keeps_the_cached_credential_while_advisory()
    test_expired_answer_is_a_failed_refresh()
    test_answer_expiring_now_is_already_expired()
    print("OK")
