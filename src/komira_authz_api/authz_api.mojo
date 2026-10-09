# =============================================================================
# authz_api.mojo — the neutral authorization interface.
# =============================================================================
#
# `AuthzPort` is the neutral authorization seam: "can `principal` do `action`
# on `resource`?" A host binds SOME `AuthzPort` conformer and gates every
# mutating verb through it — the port answers True to allow, False to deny. A
# host with its own permission service supplies a conformer that maps the
# port's (action, resource) onto that service; a single-user host can supply
# its own (e.g. the allow-all-authenticated default below).
#
# This is a NEUTRAL LEAF package — it names ONLY the transport primitives the
# seam shape requires (`Reactor` / `Runtime` for the RT-parametric async-park
# contract + `Principal` for the caller) and carries no permission-model
# vocabulary (no scopes, capabilities or roles, no database id type). The
# action + resource are value types built from Strings only, so a host can
# depend on the port without dragging in an RBAC engine.
#
# The seam SHAPE mirrors `komira_http`'s `RequestDispatcher.dispatch`:
# `check[RT]` takes the caller's reactor so a conformer that reaches an async
# store PARKS on the caller's own reactor rather than standing up an internal
# runtime.
#
# Encapsulation: no UnsafePointer crosses any boundary; no wildcard origins; no
# unsafe_from_address. `AuthzAction` / `AuthzResource` are value types
# (Strings and a `Claims` map), with no pointer field and no heap-owning
# element stored in a byte-backed slab.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_server.middleware import Claims, Principal


# =============================================================================
# AuthzAction — a neutral action verb (POD).
# =============================================================================
struct AuthzAction(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """A neutral authorization action verb — WHAT the principal wants to do
    (`read` / `write` / `delete` / `admin`). POD value type wrapping a `name` String; the
    conformer maps the name onto its own permission model, and maps any name it
    does not recognize onto its strictest tier (fail-closed). Construct via the
    named factories."""

    var name: String

    def __init__(out self, var name: String):
        self.name = name^

    # ---- named factories (the readable, mistake-proof construction surface) --

    @staticmethod
    def read() -> AuthzAction:
        """The READ action verb (see a resource)."""
        return AuthzAction(String("read"))

    @staticmethod
    def write() -> AuthzAction:
        """The WRITE action verb (create / modify a resource)."""
        return AuthzAction(String("write"))

    @staticmethod
    def delete() -> AuthzAction:
        """The DELETE action verb (destroy a resource).

        NOT "write, but more so". The level lattice this verb maps onto is a
        PARTIAL order, not a ladder: a held WRITE does **not** satisfy a DELETE
        requirement, and a held DELETE satisfies neither READ nor WRITE (an
        explicit predicate table, never a numeric `>=`). Destructive actions are
        allowed DELIBERATELY. A conformer that maps `delete` onto its write tier
        has silently flattened the lattice; a conformer that does not recognize
        `delete` at all falls into its fail-closed default (strictest tier),
        which is safe but makes an explicitly allowed DELETE unusable."""
        return AuthzAction(String("delete"))

    @staticmethod
    def admin() -> AuthzAction:
        """The ADMIN action verb (administer a resource — strictest tier)."""
        return AuthzAction(String("admin"))

    # ---- equality (on the verb name) ----

    def __eq__(self, other: AuthzAction) -> Bool:
        return self.name == other.name

    def __ne__(self, other: AuthzAction) -> Bool:
        return self.name != other.name


# =============================================================================
# AuthzResource — a neutral resource reference (kind, id, attributes).
# =============================================================================
struct AuthzResource(Copyable, Movable, Deinitable):
    """A neutral reference to the resource an action applies to: a `kind` (a
    label the host declares, e.g. `repo`, `document`), an `id` (opaque to this
    package; empty when the action applies to the kind as a whole, such as a
    create), and `attributes`, an ordered string map a conformer may read
    (empty unless the caller sets one). No id type is imported; a conformer
    parses `id` into its own type at the edge."""

    var kind: String
    var id: String
    var attributes: Claims

    def __init__(out self, *, var kind: String, var id: String):
        self.kind = kind^
        self.id = id^
        self.attributes = Claims()

    def __init__(
        out self, *, var kind: String, var id: String, var attributes: Claims
    ):
        self.kind = kind^
        self.id = id^
        self.attributes = attributes^

    def with_attribute(var self, key: String, value: String) -> AuthzResource:
        """Return this resource with `key` set to `value` in its attributes."""
        self.attributes.set(key, value)
        return self^


# =============================================================================
# AuthzPort — the authorization interface (the one-method seam).
# =============================================================================
trait AuthzPort(Movable, Deinitable):
    """The neutral authorization interface. A host binds one conformer and gates
    its verbs through `check`; a host with a permission service supplies a
    conformer backed by it."""

    def check[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        principal: Principal,
        action: AuthzAction,
        resource: AuthzResource,
    ) raises -> Bool:
        """The authorization interface — can `principal` do `action` on `resource`?
        True to allow, False to deny. RT-parametric so a conformer reaching an
        async store parks on the caller's reactor."""
        ...


# =============================================================================
# Reference conformers — the two DB-FREE defaults a store-less host binds.
#
# The module header names an allow-all single-user default as the simplest
# binding; these are that default, made CONCRETE so a host does not hand-roll
# it (and so a store-less binary — e.g. a serverless host whose only backing
# store is an object bucket, no database) has a real, reviewable thing to bind
# instead of a database-backed conformer it cannot build.
#
# NEITHER is a substitute for authentication. `AllowAuthenticatedAuthz` allows
# any principal that carries a NON-EMPTY subject — which is only meaningful because
# the identity reaching a dispatcher is the one an upstream verifier STAMPED
# from a verified credential. Bind it only behind such a verifier, or behind an equivalent
# ingress-level authentication; bind `DenyAllAuthz` when a surface must be off.
# =============================================================================
struct AllowAuthenticatedAuthz(AuthzPort):
    """An `AuthzPort` that allows any action by any AUTHENTICATED principal — i.e.
    one whose `subject` is non-empty — and denies an unauthenticated one.

    The DB-free default: it delegates the whole authorization decision to
    whatever authenticated the caller (a host that has already verified the
    caller's credential has nothing left to look up without a membership store).
    A host with a membership store should bind a conformer backed by it
    instead; a host with per-repo ACLs should bind one that reads
    `resource.id`."""

    def __init__(out self):
        pass

    def check[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        principal: Principal,
        action: AuthzAction,
        resource: AuthzResource,
    ) raises -> Bool:
        """True iff `principal` carries a non-empty subject. `action` /
        `resource` are ignored (there is no store to scope them against)."""
        return principal.subject.byte_length() > 0


struct DenyAllAuthz(AuthzPort):
    """An `AuthzPort` that denies EVERYTHING. The fail-closed default a host binds
    for a surface it has not configured — a disabled surface must not be a
    half-open one."""

    def __init__(out self):
        pass

    def check[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        principal: Principal,
        action: AuthzAction,
        resource: AuthzResource,
    ) raises -> Bool:
        """Always False."""
        return False
