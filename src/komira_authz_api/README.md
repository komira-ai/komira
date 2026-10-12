# komira_authz_api

The authorization seam a host gates its verbs through: "may `principal` do
`action` on `resource`?" It declares the interface and two store-free
conformers, and nothing that decides access from data.

- `AuthzPort` is the one-method trait: `check[RT](reactor, principal, action,
  resource) -> Bool`, True to allow, False to deny. It takes the caller's
  reactor so a conformer that asks an async store parks on the caller's own
  reactor.
- `AuthzAction` is a verb by name, built with `read()`, `write()`,
  `delete()` or `admin()` (or any name); equality compares the name.
- `AuthzResource` is a `kind` label the host declares, an opaque `id`
  (empty for an action on the kind as a whole, such as a create) and an
  `attributes` string map, empty unless set (`with_attribute`).
- `AllowAuthenticatedAuthz` allows any action on any resource by a principal
  whose subject is non-empty and denies an empty one. It does not
  authenticate: it trusts whatever verified the caller's credential and set
  the subject.
- `DenyAllAuthz` denies everything, for a surface that is switched off.

There are no roles, scopes or permission tables here; a host with a
membership store writes its own `AuthzPort` conformer. The caller,
`Principal` (its scheme, `jwt` or `session`, a subject and claims), comes
from `komira_http_server`.

## Examples

The two reference conformers, run on a blocking runtime with the mock
reactor backend (nothing touches the network):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime, block_on
from komira_authz_api import AllowAuthenticatedAuthz, AuthzAction, AuthzResource
from komira_authz_api import DenyAllAuthz
from komira_http_server.middleware import Principal

comptime RT = BlockingRuntime[NoopSink]

def reference_decisions(mut reactor: Reactor[NoopSink]) raises -> Int64:
    var resource = AuthzResource(kind=String("document"), id=String("doc-1"))
    var allow = AllowAuthenticatedAuthz()
    var deny = DenyAllAuthz()
    var bits = Int64(0)
    if allow.check[RT](reactor, Principal(scheme=String("jwt"), subject=String("alice")), AuthzAction.delete(), resource):
        bits |= 1
    if allow.check[RT](reactor, Principal(scheme=String("jwt"), subject=String("")), AuthzAction.read(), resource):
        bits |= 2  # an empty subject is not authenticated: stays clear
    if deny.check[RT](reactor, Principal(scheme=String("jwt"), subject=String("alice")), AuthzAction.read(), resource):
        bits |= 4  # DenyAllAuthz allows nothing: stays clear
    return bits

var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
assert_equal(Int(block_on[NoopSink, Int64](rt, reference_decisions)), 1)
_ = rt^
```

The value types, and a host's own conformer that allows only `read`:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo module
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime, block_on
from komira_async.runtime.runtime_trait import Runtime
from komira_authz_api import AuthzAction, AuthzPort, AuthzResource
from komira_http_server.middleware import Principal


struct ReadOnlyAuthz(AuthzPort):
    def __init__(out self):
        pass

    def check[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        principal: Principal,
        action: AuthzAction,
        resource: AuthzResource,
    ) raises -> Bool:
        return principal.subject.byte_length() > 0 and action == AuthzAction.read()


def read_only_decisions(mut reactor: Reactor[NoopSink]) raises -> Int64:
    var authz = ReadOnlyAuthz()
    var doc = AuthzResource(kind=String("document"), id=String("doc-1"))
    var bits = Int64(0)
    if authz.check[BlockingRuntime[NoopSink]](reactor, Principal(scheme=String("session"), subject=String("bob")), AuthzAction.read(), doc):
        bits |= 1
    if authz.check[BlockingRuntime[NoopSink]](reactor, Principal(scheme=String("session"), subject=String("bob")), AuthzAction.write(), doc):
        bits |= 2
    return bits


def main() raises:
    var doc = AuthzResource(kind=String("document"), id=String("doc-1"))
    assert_equal(doc.kind, "document")
    assert_equal(doc.id, "doc-1")
    var tagged = doc.copy().with_attribute(String("label"), String("draft"))
    assert_equal(tagged.attributes.get(String("label")).value(), "draft")
    assert_equal(doc.attributes.len(), 0)  # the original is unchanged
    assert_equal(AuthzAction.admin().name, "admin")
    assert_true(AuthzAction(String("read")) == AuthzAction.read())

    var rt = BlockingRuntime[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    assert_equal(Int(block_on[NoopSink, Int64](rt, read_only_decisions)), 1)
    _ = rt^
```
