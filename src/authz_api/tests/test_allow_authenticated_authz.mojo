# AllowAuthenticatedAuthz grants a non-empty subject and refuses the empty one.

from std.testing import assert_equal

from async_rt.ops.waker_sink import NoopSink
from async_rt.reactor.reactor import BACKEND_MOCK, Reactor
from async_rt.runtime.blocking_runtime import BlockingRuntime, block_on
from authz_api import (
    AllowAuthenticatedAuthz,
    AuthzAction,
    AuthzResource,
)
from http_server.middleware import Principal

comptime RT = BlockingRuntime[NoopSink]


def _decisions(mut reactor: Reactor[NoopSink]) raises -> Int64:
    """Bit 0: short subject granted. Bit 1: long subject granted. Bit 2: empty
    subject granted (must stay clear)."""
    var authz = AllowAuthenticatedAuthz()
    var action = AuthzAction.delete()
    var resource = AuthzResource(kind=String("repo"), id=String("r-1"))
    var bits = Int64(0)
    if authz.check[RT](reactor, Principal(scheme=String("jwt"), subject=String("a")), action, resource):
        bits |= 1
    if authz.check[RT](
        reactor, Principal(scheme=String("session"), subject=String("a-much-longer-subject")), action, resource
    ):
        bits |= 2
    if authz.check[RT](reactor, Principal(scheme=String("jwt"), subject=String("")), action, resource):
        bits |= 4
    return bits


def test_grants_non_empty_and_refuses_empty() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var bits = block_on[NoopSink, Int64](rt, _decisions)
    assert_equal(Int(bits), 3)
    _ = rt^


def main() raises:
    test_grants_non_empty_and_refuses_empty()
    print("PASS authz_api AllowAuthenticatedAuthz")
