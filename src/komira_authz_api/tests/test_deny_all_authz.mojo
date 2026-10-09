# DenyAllAuthz denies every (action, resource) combination, for any principal.

from std.testing import assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime, block_on
from komira_authz_api import AuthzAction, AuthzResource, DenyAllAuthz
from komira_http_server.middleware import Principal

comptime RT = BlockingRuntime[NoopSink]


def _denies_everything(mut reactor: Reactor[NoopSink]) raises -> Int64:
    """Returns the number of combinations that were wrongly granted."""
    var actions = List[AuthzAction]()
    actions.append(AuthzAction.read())
    actions.append(AuthzAction.write())
    actions.append(AuthzAction.delete())
    actions.append(AuthzAction.admin())
    actions.append(AuthzAction(String("unrecognized")))

    var resources = List[AuthzResource]()
    resources.append(AuthzResource(kind=String("repo"), id=String("")))
    resources.append(AuthzResource(kind=String("repo"), id=String("r1")))
    resources.append(
        AuthzResource(kind=String("document"), id=String("d1")).with_attribute(
            String("label"), String("draft")
        )
    )

    var users = List[Principal]()
    users.append(Principal(scheme=String("jwt"), subject=String("subject-1")))  # authenticated
    users.append(Principal(scheme=String("session"), subject=String("")))  # empty

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
