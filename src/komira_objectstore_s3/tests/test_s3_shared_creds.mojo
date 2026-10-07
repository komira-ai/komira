# Temporary credentials rotate under a cloned S3 client: the request signed
# after the first credential's refresh window carries the NEW credential, on
# the file system that took the first one and on a clone of it, and the
# provider is called once per rotation, not once per clone.
#
# The credential source is komira_aws_core's SharedCredsSource over the real
# default chain (the container endpoint, scripted: no network) and a clock the
# test advances. The S3 clients send over AwsEchoConnector, whose answer is an
# error carrying the request exactly as it reached the wire, so each row reads
# the access key id and the session token the request was signed with (the
# signing clock is a separate FixedClock). Rows:
#
#  * S3Fs: the original signs with credential 1; the clock moves into the
#    refresh window; the CLONE (made before the rotation, with its own store)
#    signs with credential 2, and so does the original; two provider calls;
#  * S3ConditionalStore: the same through its clone;
#  * while the cached credential is valid and the endpoint is down, a request
#    is still signed with it, and with the credential expired and the
#    endpoint down the send fails with the named error, which holds none of
#    the credential material (canary secret and token).
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS,
    AwsClock,
    AwsCredentialParams,
    AwsEchoConnector,
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
    DefaultChainCredsSource,
    FixedClock,
    MapEnv,
    MapFiles,
    SharedCredsSource,
)
from komira_http_client.client import HttpClientConfig
from komira_objectstore.path import Path
from komira_objectstore_s3 import (
    AddressingStyle,
    S3Config,
    S3ConditionalStore,
    S3Fs,
)
from komira_retry import Backoff, Jitter, RetryPolicy


# 2026-09-19T12:00:00Z
comptime _NOW = 1789819200
# Credential 1 expires an hour after _NOW.
comptime _IN_WINDOW = _NOW + 3600 - AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS + 1
comptime _EXPIRED = _NOW + 3600


struct _Now(Movable):
    var seconds: Int

    def __init__(out self, seconds: Int):
        self.seconds = seconds


struct _CredClock(AwsClock, Copyable, Movable, Deinitable):
    var _now: ArcPointer[_Now]

    def __init__(out self, now: ArcPointer[_Now]):
        self._now = now

    def now_unix_seconds(mut self) -> Int:
        return self._now[].seconds


struct _Script(Movable):
    var calls: Int
    var down: Bool

    def __init__(out self):
        self.calls = 0
        self.down = False


struct _Endpoint(CredentialTransport, Copyable, Movable, Deinitable):
    """The container credentials endpoint: answer i is key id ASIAROTATING<i>
    with canary secret and token, expiring an hour after _NOW for the first
    answer and two hours after it for every later one."""

    var _script: ArcPointer[_Script]

    def __init__(out self, script: ArcPointer[_Script]):
        self._script = script

    def send(
        mut self, req: CredentialHttpRequest
    ) raises -> CredentialHttpResponse:
        ref s = self._script[]
        s.calls += 1
        if s.down:
            raise Error("connection refused")
        var expires = "2026-09-19T13:00:00Z" if s.calls == 1 else "2026-09-19T14:00:00Z"
        var body = String('{"AccessKeyId":"ASIAROTATING') + String(s.calls)
        body += '","SecretAccessKey":"CANARY-SECRET-' + String(s.calls)
        body += '","Token":"CANARY-TOKEN-' + String(s.calls)
        body += '","Expiration":"' + String(expires) + '"}'
        return CredentialHttpResponse(200, body)


comptime _Creds = SharedCredsSource[
    DefaultChainCredsSource[MapEnv, MapFiles, _Endpoint, _CredClock]
]


struct _Rig(Movable):
    var creds: _Creds
    var script: ArcPointer[_Script]
    var now: ArcPointer[_Now]

    def __init__(out self):
        var env = MapEnv()
        env.set("HOME", "/home/u")
        env.set(
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example"
        )
        self.script = ArcPointer[_Script](_Script())
        self.now = ArcPointer[_Now](_Now(_NOW))
        self.creds = _Creds(
            DefaultChainCredsSource[MapEnv, MapFiles, _Endpoint, _CredClock](
                AwsCredentialParams(),
                env^,
                MapFiles(),
                _Endpoint(self.script),
                _CredClock(self.now),
            )
        )


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def _config() raises -> S3Config:
    return S3Config(
        "us-east-1",
        endpoint="http://127.0.0.1:9000",
        addressing=AddressingStyle.path(),
        retry=RetryPolicy(
            Backoff(initial_ms=1, multiplier=2.0, max_ms=2, jitter=Jitter.full()),
            max_attempts=1,
            deadline_ms=Int64(60_000),
        ),
    )


def _wire_of(e: Error) -> String:
    return String(e).lower()


def _signed_with_fs(fs: S3Fs[AwsEchoConnector, _Creds, FixedClock]) raises -> String:
    """The request `fs` sends, as it reached the wire."""
    var file = fs.open("data/a.parquet")
    try:
        _ = fs.read_at(file, 0, 4)
    except e:
        return _wire_of(e)
    raise Error("the echo answered with a success")


def _signed_with_store(
    store: S3ConditionalStore[AwsEchoConnector, _Creds, FixedClock]
) raises -> String:
    try:
        _ = store.get(Path("data/a.bin"))
    except e:
        return _wire_of(e)
    raise Error("the echo answered with a success")


def _fs(var creds: _Creds) raises -> S3Fs[AwsEchoConnector, _Creds, FixedClock]:
    return S3Fs[AwsEchoConnector, _Creds, FixedClock](
        "lake",
        _config(),
        _mk_echo,
        HttpClientConfig.defaults(),
        creds^,
        FixedClock(1790000000),
    )


def _assert_signed_with(wire: String, n: Int) raises:
    var id = "credential=asiarotating" + String(n) + "/20260921/us-east-1/s3/"
    assert_true(wire.find(id) >= 0, id + " is not in " + wire)
    var token = "x-amz-security-token: canary-token-" + String(n)
    assert_true(wire.find(token) >= 0, token + " is not in " + wire)
    # Never the other one.
    var other = 1 if n != 1 else 2
    assert_true(
        wire.find("asiarotating" + String(other) + "/") < 0,
        "the other credential signed " + wire,
    )


def test_s3fs_clone_signs_with_the_rotated_credential() raises:
    var rig = _Rig()
    var fs = _fs(rig.creds.copy())
    var clone_fs = fs.clone()
    _assert_signed_with(_signed_with_fs(fs), 1)
    assert_equal(rig.script[].calls, 1)
    rig.now[].seconds = _IN_WINDOW
    # The clone's own store, built after the rotation window opened.
    _assert_signed_with(_signed_with_fs(clone_fs), 2)
    _assert_signed_with(_signed_with_fs(fs), 2)
    assert_equal(rig.script[].calls, 2, "the clones did not share one refresh")


def test_conditional_store_clone_signs_with_the_rotated_credential() raises:
    var rig = _Rig()
    var store = S3ConditionalStore[AwsEchoConnector, _Creds, FixedClock](
        "lake",
        _config(),
        _mk_echo,
        HttpClientConfig.defaults(),
        rig.creds.copy(),
        FixedClock(1790000000),
    )
    var clone_store = store.clone()
    _assert_signed_with(_signed_with_store(store), 1)
    rig.now[].seconds = _IN_WINDOW
    _assert_signed_with(_signed_with_store(clone_store), 2)
    _assert_signed_with(_signed_with_store(store), 2)
    assert_equal(rig.script[].calls, 2)


def test_a_failed_refresh_and_the_named_error() raises:
    var rig = _Rig()
    var fs = _fs(rig.creds.copy())
    var clone_fs = fs.clone()
    _assert_signed_with(_signed_with_fs(fs), 1)
    # In the window, endpoint down: the cached credential still signs.
    rig.script[].down = True
    rig.now[].seconds = _IN_WINDOW
    _assert_signed_with(_signed_with_fs(clone_fs), 1)
    # Expired, endpoint down: the send fails with the named error and no
    # credential material.
    rig.now[].seconds = _EXPIRED
    var wire = _signed_with_fs(clone_fs)
    assert_true(wire.find("refreshing them failed") >= 0, wire)
    assert_true(wire.find("canary") < 0, "credential material in: " + wire)
    assert_true(wire.find("asiarotating") < 0, "a key id in: " + wire)
    # The endpoint back: signing resumes, with the new credential.
    rig.script[].down = False
    var next = rig.script[].calls + 1
    _assert_signed_with(_signed_with_fs(fs), next)


def main() raises:
    test_s3fs_clone_signs_with_the_rotated_credential()
    test_conditional_store_clone_signs_with_the_rotated_credential()
    test_a_failed_refresh_and_the_named_error()
    print("OK")
