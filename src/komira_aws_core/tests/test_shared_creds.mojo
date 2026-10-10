# SharedCredsSource: one refreshing credential source behind an ArcPointer, so
# a Copyable client holds the default chain and its clones share it.
#
# The chain is the real DefaultChainCredsSource over a scripted container
# endpoint (no network) and a clock the test advances after the source has
# been moved into the Arc, so the refresh policy under test is the shipped one:
#
#  * rotation: a credential read after the first one's refresh window is the
#    NEW one, and a clone made before the rotation sees it too;
#  * one refresh for all clones: the provider is called once per refresh, not
#    once per clone;
#  * single flight: eight threads, each on its own clone, all find the
#    credential inside its refresh window at once and the provider is called
#    ONCE (the scripted endpoint is slow, so a refresh that is not serialized
#    is called by several);
#  * a failed refresh while the cached credential is still outside the
#    mandatory window keeps serving it, and the next call tries again;
#  * the credential expired (or about to be) and the refresh failed is the
#    named error, whose text holds none of the key id, secret or token of any
#    credential the endpoint handed out (canary strings), neither when the
#    endpoint is down nor when it answers with an already-expired credential;
#  * the lock is released on that error path: the next call, with the endpoint
#    back, succeeds;
#  * a static credential, and a chain whose parameters state the keys, never
#    call a provider however far the clock moves.

from std.ffi import external_call
from std.memory import ArcPointer, Pointer
from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS,
    AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS,
    SHARED_CREDS_REFRESH_FAILED,
    AwsClock,
    AwsCredential,
    AwsCredentialParams,
    AwsCredsSource,
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
    DefaultChainCredsSource,
    MapEnv,
    MapFiles,
    SharedCredsSource,
    StaticCredsSource,
)
from komira_fork_join import ForkJoinBody, fork_join


# 2026-09-19T12:00:00Z
comptime _NOW = 1789819200
comptime _ONE_HOUR = "2026-09-19T13:00:00Z"
comptime _TWO_HOURS = "2026-09-19T14:00:00Z"
comptime _ALREADY_EXPIRED = "2026-09-19T11:00:00Z"
# Inside the advisory window of a credential expiring in an hour, outside the
# mandatory one.
comptime _ADVISORY_NOW = _NOW + 3600 - AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS + 1
# Inside the mandatory window.
comptime _MANDATORY_NOW = _NOW + 3600 - AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS + 1


struct _Now(Movable):
    var seconds: Int

    def __init__(out self, seconds: Int):
        self.seconds = seconds


struct _SharedClock(AwsClock, Copyable, Movable, Deinitable):
    """A clock the test advances after the source has taken a copy."""

    var _now: ArcPointer[_Now]

    def __init__(out self, now: ArcPointer[_Now]):
        self._now = now

    def now_unix_seconds(mut self) -> Int:
        return self._now[].seconds


struct _Script(Movable):
    """What the scripted container endpoint does; `calls` is the provider's
    call count. Touched by the chain under the credential lock, and by the test
    only while no thread runs."""

    var expires: List[String]
    var calls: Int
    var down: Bool
    var delay_us: Int

    def __init__(out self, var expires: List[String], delay_us: Int = 0):
        self.expires = expires^
        self.calls = 0
        self.down = False
        self.delay_us = delay_us


struct _Endpoint(CredentialTransport, Copyable, Movable, Deinitable):
    """The container credentials endpoint. Its i-th answer carries key id
    ASIAROTATING<i> and canary secret and token, and expires at `expires[i]`."""

    var _script: ArcPointer[_Script]

    def __init__(out self, script: ArcPointer[_Script]):
        self._script = script

    def send(
        mut self, req: CredentialHttpRequest
    ) raises -> CredentialHttpResponse:
        if req.host != "169.254.170.2":
            raise Error("unexpected host " + req.host)
        ref s = self._script[]
        if s.delay_us > 0:
            _ = external_call["usleep", Int32](UInt32(s.delay_us))
        s.calls += 1
        if s.down:
            raise Error("connection refused")
        var i = min(s.calls - 1, len(s.expires) - 1)
        var body = String('{"AccessKeyId":"ASIAROTATING') + String(s.calls)
        body += '","SecretAccessKey":"CANARY-SECRET-' + String(s.calls)
        body += '","Token":"CANARY-TOKEN-' + String(s.calls)
        body += '","Expiration":"' + s.expires[i] + '"}'
        return CredentialHttpResponse(200, body)


comptime _Chain = DefaultChainCredsSource[
    MapEnv, MapFiles, _Endpoint, _SharedClock
]
comptime _Shared = SharedCredsSource[_Chain]


struct _Rig(Movable):
    var src: _Shared
    var script: ArcPointer[_Script]
    var now: ArcPointer[_Now]

    def __init__(out self, var expires: List[String], delay_us: Int = 0):
        var env = MapEnv()
        env.set("HOME", "/home/u")
        env.set(
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example"
        )
        self.script = ArcPointer[_Script](_Script(expires^, delay_us))
        self.now = ArcPointer[_Now](_Now(_NOW))
        self.src = _Shared(
            _Chain(
                AwsCredentialParams(),
                env^,
                MapFiles(),
                _Endpoint(self.script),
                _SharedClock(self.now),
            )
        )


def _expiries() -> List[String]:
    return [_ONE_HOUR, _TWO_HOURS]


def test_rotation_after_the_window_uses_the_new_credential() raises:
    var rig = _Rig(_expiries())
    var other = rig.src.copy()
    assert_equal(rig.src.credentials().access_key_id, "ASIAROTATING1")
    # A clone made BEFORE the rotation reads the rotated credential.
    rig.now[].seconds = _ADVISORY_NOW
    var rotated = other.credentials()
    assert_equal(rotated.access_key_id, "ASIAROTATING2")
    assert_equal(rotated.secret_access_key, "CANARY-SECRET-2")
    assert_equal(rotated.session_token, "CANARY-TOKEN-2")
    assert_equal(rig.src.credentials().access_key_id, "ASIAROTATING2")


def test_clones_share_one_refresh() raises:
    var rig = _Rig(_expiries())
    var a = rig.src.copy()
    var b = rig.src.copy()
    _ = rig.src.credentials()
    _ = a.credentials()
    _ = b.credentials()
    assert_equal(rig.script[].calls, 1, "each clone resolved the chain itself")
    rig.now[].seconds = _ADVISORY_NOW
    _ = b.credentials()
    _ = a.credentials()
    _ = rig.src.credentials()
    assert_equal(rig.script[].calls, 2, "each clone refreshed on its own")


struct _Hammer[o: MutOrigin](ForkJoinBody):
    """Every thread signs once on a clone of the shared source."""

    var src: _Shared
    var keys: Pointer[List[String], Self.o]

    def __init__(out self, var src: _Shared, keys: Pointer[List[String], Self.o]):
        self.src = src^
        self.keys = keys

    def run(self, tid: Int) raises:
        var mine = self.src.copy()
        self.keys[][tid] = mine.credentials().access_key_id


def test_concurrent_callers_share_one_refresh() raises:
    # The endpoint is slow, so threads that are not serialized all reach it.
    var rig = _Rig(_expiries(), delay_us=30_000)
    _ = rig.src.credentials()
    assert_equal(rig.script[].calls, 1)
    rig.now[].seconds = _ADVISORY_NOW
    var n = 8
    var keys = List[String]()
    for _ in range(n):
        keys.append(String(""))
    var body = _Hammer(rig.src.copy(), Pointer(to=keys))
    fork_join(body, n)
    assert_equal(rig.script[].calls, 2, "the refresh was not single-flight")
    for i in range(n):
        assert_equal(keys[i], "ASIAROTATING2")


def test_failed_refresh_keeps_serving_the_cached_credential() raises:
    var rig = _Rig(_expiries())
    var other = rig.src.copy()
    assert_equal(rig.src.credentials().access_key_id, "ASIAROTATING1")
    rig.script[].down = True
    rig.now[].seconds = _ADVISORY_NOW
    assert_equal(other.credentials().access_key_id, "ASIAROTATING1")
    assert_equal(rig.script[].calls, 2, "the refresh was not attempted")
    # The next call tries again: the endpoint back, the new credential.
    rig.script[].down = False
    assert_equal(rig.src.credentials().access_key_id, "ASIAROTATING3")
    assert_equal(rig.script[].calls, 3)


def _assert_named_error_without_canary(mut src: _Shared, expect: String) raises:
    var raised = False
    try:
        _ = src.credentials()
    except e:
        raised = True
        var m = String(e)
        assert_true(m.startswith(SHARED_CREDS_REFRESH_FAILED), m)
        assert_true(m.find(expect) >= 0, m)
        assert_true(m.find("CANARY") < 0, "credential material in: " + m)
        assert_true(m.find("ASIAROTATING") < 0, "a key id in: " + m)
    assert_true(raised, "a credential that could expire in flight was served")


def test_expired_and_unrefreshable_is_the_named_error() raises:
    var rig = _Rig(_expiries())
    _ = rig.src.credentials()
    rig.script[].down = True
    rig.now[].seconds = _MANDATORY_NOW
    _assert_named_error_without_canary(rig.src, "did not answer")
    rig.now[].seconds = _NOW + 3600
    var clone = rig.src.copy()
    _assert_named_error_without_canary(clone, "did not answer")
    # The lock was released on the error path: with the endpoint back the very
    # next call (a deadlock would hang the test) gets the new credential.
    rig.script[].down = False
    assert_equal(clone.credentials().access_key_id, "ASIAROTATING4")


def test_an_expired_answer_names_no_credential_material() raises:
    # The endpoint answers, but with a credential that has already expired: a
    # failed refresh, and the refused credential's canaries stay out of it.
    var rig = _Rig([_ONE_HOUR, _ALREADY_EXPIRED])
    _ = rig.src.credentials()
    rig.now[].seconds = _MANDATORY_NOW
    _assert_named_error_without_canary(rig.src, "already expired")


def test_a_credential_with_no_expiry_is_never_refreshed() raises:
    var fixed = SharedCredsSource[StaticCredsSource](
        StaticCredsSource(
            AwsCredential(
                String("AKIDSTATIC"), String("CANARY-STATIC"), String("")
            )
        )
    )
    var other = fixed.copy()
    for _ in range(3):
        assert_equal(fixed.credentials().access_key_id, "AKIDSTATIC")
        assert_equal(other.credentials().secret_access_key, "CANARY-STATIC")

    # The chain with the keys stated in its parameters: no provider is called,
    # whatever the clock says.
    var params = AwsCredentialParams()
    params.credential = Optional[AwsCredential](
        AwsCredential(String("AKIDFIXED"), String("CANARY-FIXED"), String(""))
    )
    var script = ArcPointer[_Script](_Script(_expiries()))
    var now = ArcPointer[_Now](_Now(_NOW))
    var env = MapEnv()
    env.set("HOME", "/home/u")
    env.set("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/example")
    var chain = _Shared(
        _Chain(
            params,
            env^,
            MapFiles(),
            _Endpoint(script),
            _SharedClock(now),
        )
    )
    assert_equal(chain.credentials().access_key_id, "AKIDFIXED")
    now[].seconds = _NOW + 100 * 86400
    var again = chain.copy()
    assert_equal(again.credentials().access_key_id, "AKIDFIXED")
    assert_equal(script[].calls, 0, "a stated credential called a provider")


def main() raises:
    test_rotation_after_the_window_uses_the_new_credential()
    test_clones_share_one_refresh()
    test_concurrent_callers_share_one_refresh()
    test_failed_refresh_keeps_serving_the_cached_credential()
    test_expired_and_unrefreshable_is_the_named_error()
    test_an_expired_answer_names_no_credential_material()
    test_a_credential_with_no_expiry_is_never_refreshed()
    print("OK")
