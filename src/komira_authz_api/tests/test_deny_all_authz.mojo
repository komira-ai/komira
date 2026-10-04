# DenyAllAuthz denies every (action, resource) combination, for any principal.

from std.testing import assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime, block_on
from komira_authz_api import AuthzAction, AuthzResource, DenyAllAuthz
from komira_http_server.middleware import AuthedUser
from komira_uuid.uuid import Uuid

comptime RT = BlockingRuntime[NoopSink]


def _some_uuid() -> Uuid:
    var b = Array[UInt8, 16](fill=UInt8(0))
    b[0] = UInt8(0xAB)
    b[15] = UInt8(0xCD)
    return Uuid(b)


def _denies_everything(mut reactor: Reactor[NoopSink]) raises -> Int64:
    """Returns the number of combinations that were wrongly granted."""
    var actions = List[AuthzAction]()
    actions.append(AuthzAction.read())
    actions.append(AuthzAction.write())
    actions.append(AuthzAction.delete())
    actions.append(AuthzAction.admin())
    actions.append(AuthzAction(String("unrecognized")))

    var resources = List[AuthzResource]()
    resources.append(AuthzResource.workspace(String("repo"), String("ws")))
    resources.append(
        AuthzResource.workspace_resource(String("repo"), String("ws"), String("r1"))
    )
    resources.append(AuthzResource.org(String("document"), String("org")))
    resources.append(
        AuthzResource.org_and_workspace(String("document"), String("org"), String("ws"))
    )

    var users = List[AuthedUser]()
    users.append(AuthedUser(_some_uuid(), _some_uuid()))  # authenticated
    users.append(AuthedUser(Uuid(), Uuid()))  # nil

    var authz = DenyAllAuthz()
    var granted = Int64(0)
    for u in range(len(users)):
        for a in range(len(actions)):
            for r in range(len(resources)):
                if authz.check[RT](reactor, users[u], actions[a], resources[r]):
                    granted += 1
    return granted


def test_deny_all_denies_every_combination() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var granted = block_on[NoopSink, Int64](rt, _denies_everything)
    assert_false(granted != 0)
    _ = rt^


def main() raises:
    test_deny_all_denies_every_combination()
    print("PASS komira_authz_api DenyAllAuthz")
