# An S3Fs signs with the credential the shared default chain holds NOW. The
# file system's credential source is komira_aws_core's SharedCredsSource over
# the real chain (the container endpoint, scripted: no network) and a clock
# the test advances; its connector is AwsEchoConnector, whose answer carries
# the request as it reached the wire.
#
# Rows: a file system and a clone of it made before the rotation share ONE
# refresh: after the first credential's refresh window opens, the clone signs
# with credential 2, then the original does, and the endpoint was called twice
# (once per credential), not once per file system.
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
    MapEnv,
    MapFiles,
    SharedCredsSource,
    SystemAwsClock,
)
from komira_http_client.client import HttpClientConfig
from komira_objectstore_s3 import AddressingStyle, S3Config, S3Fs
from komira_retry import Backoff, Jitter, RetryPolicy


# 2026-09-19T12:00:00Z
comptime _NOW = 1789819200
comptime _IN_WINDOW = _NOW + 3600 - AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS + 1


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

    def __init__(out self):
        self.calls = 0


struct _Endpoint(CredentialTransport, Copyable, Movable, Deinitable):
    var _script: ArcPointer[_Script]

    def __init__(out self, script: ArcPointer[_Script]):
        self._script = script

    def send(
        mut self, req: CredentialHttpRequest
    ) raises -> CredentialHttpResponse:
        ref s = self._script[]
        s.calls += 1
        var expires = "2026-09-19T13:00:00Z" if s.calls == 1 else "2026-09-19T14:00:00Z"
        var body = String('{"AccessKeyId":"ASIAROTATING') + String(s.calls)
        body += '","SecretAccessKey":"CANARY-SECRET-' + String(s.calls)
        body += '","Token":"CANARY-TOKEN-' + String(s.calls)
        body += '","Expiration":"' + String(expires) + '"}'
        return CredentialHttpResponse(200, body)


comptime _Creds = SharedCredsSource[
    DefaultChainCredsSource[MapEnv, MapFiles, _Endpoint, _CredClock]
]
comptime _Fs = S3Fs[AwsEchoConnector, _Creds, SystemAwsClock]


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def _creds(script: ArcPointer[_Script], now: ArcPointer[_Now]) -> _Creds:
    var env = MapEnv()
    env.set("HOME", "/home/u")
    env.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example")
    return _Creds(
        DefaultChainCredsSource[MapEnv, MapFiles, _Endpoint, _CredClock](
            AwsCredentialParams(),
            env^,
            MapFiles(),
            _Endpoint(script),
            _CredClock(now),
        )
    )


def _fs(var creds: _Creds) raises -> _Fs:
    return _Fs(
        "lake",
        S3Config(
            "us-east-1",
            endpoint="http://127.0.0.1:9000",
            addressing=AddressingStyle.path(),
            retry=RetryPolicy(
                Backoff(initial_ms=1, multiplier=2.0, max_ms=2, jitter=Jitter.full()),
                max_attempts=1,
                deadline_ms=Int64(60_000),
            ),
        ),
        _mk_echo,
        HttpClientConfig.defaults(),
        creds^,
        # SystemAwsClock: the file system signs at the wall clock; only the key id and
        # token are asserted.
        SystemAwsClock(),
    )


def _wire(fs: _Fs) raises -> String:
    var file = fs.open("data/a.parquet")
    try:
        _ = fs.read_at(file, 0, 4)
    except e:
        return String(e).lower()
    raise Error("the echo answered with a success")


def _assert_signed_with(wire: String, n: Int) raises:
    var id = "credential=asiarotating" + String(n) + "/"
    assert_true(wire.find(id) >= 0, id + " is not in " + wire)
    var token = "x-amz-security-token: canary-token-" + String(n)
    assert_true(wire.find(token) >= 0, token + " is not in " + wire)


def test_fs_and_clone_share_one_refresh() raises:
    var script = ArcPointer[_Script](_Script())
    var now = ArcPointer[_Now](_Now(_NOW))
    var h = _fs(_creds(script, now))
    var c = h.clone()
    _assert_signed_with(_wire(h), 1)
    now[].seconds = _IN_WINDOW
    _assert_signed_with(_wire(c), 2)
    _assert_signed_with(_wire(h), 2)
    assert_equal(script[].calls, 2, "the file system and its clone refreshed apart")


def main() raises:
    test_fs_and_clone_share_one_refresh()
    print("OK")
