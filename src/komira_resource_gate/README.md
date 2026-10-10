# komira_resource_gate

Per-resource authorization in front of a dispatcher. An application declares
which routes exist and what each one touches; the gate refuses everything
else and asks an `AuthzPort` (from `komira_authz_api`) about the rest.

- `RouteDecision` is DENY, PUBLIC, or GOVERNED by a `ResourceRequirement`
  (an `AuthzAction` on an `AuthzResource`). Its zero value is DENY. It has no
  `is_denied()`: a caller lets a request through only after `is_governed()`
  or `is_public()`. `requirement()` raises unless the decision is governed.
- `ResourceRouteTable` is an ordered list of `RouteRule`s; the first row that
  matches the method and path wins, and no match is DENY. Rows:
  `governed(method, pattern, kind, id_capture, action)`,
  `on_kind(method, pattern, kind, action)` (the kind as a whole, empty id;
  the only kind-wide row: `governed` with an empty `id_capture` denies),
  `public_route(method, pattern)` and `deny_route(method, pattern, reason)`.
  Patterns hold literal segments, `{name}` captures, `{name}<suffix>`
  captures (`{repo}.git`) and a final `*` for one or more further segments.
  A path that starts without `/`, or has an empty or dot segment (`.`, `..`,
  also as `%2e`), is refused before any row is tried. Matching is on the raw
  bytes: nothing is percent-decoded, so the captured id is the segment as
  sent, `adm%69n` is not the literal `admin`, and `%2F` does not split a
  segment. A `deny_route` carve-out therefore holds only for an inner
  dispatcher that routes on the same raw bytes.
- `ResourceCatalog` is the trait an application implements: one pure static
  `route(method, path) -> RouteDecision`, usually a table's `route`. The query
  string is not an input.
- `ResourceAuthzGate[Inner, Catalog, Authz]` is a `CtxRequestDispatcher` in
  front of `Inner`. Per request: route; a public route runs `Inner` with no
  principal and none of the gate's attributes; anything else not governed is
  403; governed without a principal (or with an empty subject) is 401 with
  `WWW-Authenticate: Bearer`; then `Authz.check`: False is 403, a raise is 503
  with `Retry-After: 1`. An allowed request runs `Inner` with the authorized
  action, kind and id in `ctx.attributes` under `GATE_ATTRIBUTE_ACTION`,
  `GATE_ATTRIBUTE_RESOURCE_KIND` and `GATE_ATTRIBUTE_RESOURCE_ID`. Refusals
  carry fixed text bodies and `Cache-Control: no-store`.

Authentication is not here: a middleware in front (for example a bearer-token
one) verifies the credential and sets `ctx.principal`. A public route is
reached only if that middleware lets an unauthenticated request through.

## Examples

A route table, routed without a server:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_authz_api import AuthzAction
from komira_resource_gate import ResourceRouteTable, RouteRule

var rules = List[RouteRule]()
rules.append(RouteRule.public_route(String("GET"), String("/health")))
rules.append(RouteRule.governed(String("GET"), String("/repos/{repo}"), String("repo"), String("repo"), AuthzAction.read()))
rules.append(RouteRule.on_kind(String("POST"), String("/repos"), String("repo"), AuthzAction.write()))
var table = ResourceRouteTable(rules^)

assert_true(table.route(String("GET"), String("/health")).is_public())
var read = table.route(String("GET"), String("/repos/acme")).requirement()
assert_equal(read.action.name, "read")
assert_equal(read.resource.kind, "repo")
assert_equal(read.resource.id, "acme")
assert_equal(table.route(String("POST"), String("/repos")).requirement().resource.id, "")
# Not declared, or not canonical: neither governed nor public.
var other = table.route(String("GET"), String("/admin"))
assert_true(not other.is_governed() and not other.is_public())
var dots = table.route(String("GET"), String("/repos/../admin"))
assert_true(not dots.is_governed() and not dots.is_public())
```
