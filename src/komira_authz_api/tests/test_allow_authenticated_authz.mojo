# AllowAuthenticatedAuthz grants a non-nil user id and refuses the nil one.

from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime, block_on
from komira_authz_api import (
    AllowAuthenticatedAuthz,
    AuthzAction,
    AuthzResource,
)
from komira_http_server.middleware import AuthedUser
from komira_uuid.uuid import Uuid

comptime RT = BlockingRuntime[NoopSink]


def _uuid_with_byte(idx: Int) -> Uuid:
    var b = Array[UInt8, 16](fill=UInt8(0))
    b[idx] = UInt8(1)
    return Uuid(b)


def _decisions(mut reactor: Reactor[NoopSink]) raises -> Int64:
    """Bit 0: non-nil first-byte user granted. Bit 1: non-nil last-byte user
    granted. Bit 2: nil user granted (must stay clear)."""
    var authz = AllowAuthenticatedAuthz()
    var action = AuthzAction.delete()
    var resource = AuthzResource.workspace(String("repo"), String("ws"))
    var bits = Int64(0)
    if authz.check[RT](
        reactor, AuthedUser(_uuid_with_byte(0), Uuid()), action, resource
    ):
        bits |= 1
    if authz.check[RT](
        reactor, AuthedUser(_uuid_with_byte(15), Uuid()), action, resource
    ):
        bits |= 2
    if authz.check[RT](reactor, AuthedUser(Uuid(), Uuid()), action, resource):
        bits |= 4
    return bits


def test_grants_non_nil_and_refuses_nil() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var bits = block_on[NoopSink, Int64](rt, _decisions)
    assert_equal(Int(bits), 3)
    _ = rt^


def main() raises:
    test_grants_non_nil_and_refuses_nil()
    print("PASS komira_authz_api AllowAuthenticatedAuthz")
