# =============================================================================
# authz_port.mojo — the neutral authorization interface.
# =============================================================================
#
# `AuthzPort` is the neutral authorization seam: "can `principal` do `action`
# on `resource`?" A host binds SOME `AuthzPort` conformer and gates every
# mutating verb through it — the port answers True on grant, False on deny. A
# managed deployment supplies a conformer that maps the port's (action,
# resource) onto its own RBAC + row-scope service; a single-user host can
# supply its own (e.g. the allow-all-authenticated default below).
#
# This is a NEUTRAL LEAF package — it names ONLY the transport primitives the
# seam shape requires (`Reactor` / `Runtime` for the RT-parametric async-park
# contract + `AuthedUser` for the principal) and carries no permission-model
# vocabulary (no scopes, capabilities or roles, no database id type). The
# action + resource are POD value types built from Strings only, so a host can
# depend on the port without dragging in an RBAC engine.
#
# The seam SHAPE mirrors `komira_http`'s `RequestDispatcher.dispatch`:
# `check[RT]` takes the caller's reactor so a conformer that reaches an async
# store PARKS on the caller's own reactor rather than standing up an internal
# runtime.
#
# Encapsulation: no UnsafePointer crosses any boundary; no wildcard origins; no
# unsafe_from_address. `AuthzAction` / `AuthzResource` are POD value types
# (Strings only), with no pointer field and no heap-owning element stored in a
# byte-backed slab.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_server.middleware import AuthedUser


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
        granted DELIBERATELY. A conformer that maps `delete` onto its write tier
        has silently flattened the lattice; a conformer that does not recognize
        `delete` at all falls into its fail-closed default (strictest tier),
        which is safe but makes an explicit DELETE grant unusable."""
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
# AuthzResource — a neutral resource reference (POD, Strings only).
# =============================================================================
struct AuthzResource(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """A neutral reference to the resource an action applies to. POD value type
    carrying a `kind` label (e.g. `repo`, `document`) + up to three
    hyphenated-UUID Strings scoping it: `org_id`, `workspace_id`, `resource_id`
    (each EMPTY when unset). Strings ONLY — no id type is imported; a
    conformer parses the hyphenated strings into its own id type at the edge.
    Construct via the scope factories (`workspace` / `org` / `org_and_workspace`)."""

    var kind: String
    var org_id: String
    var workspace_id: String
    var resource_id: String

    def __init__(
        out self,
        var kind: String,
        var org_id: String,
        var workspace_id: String,
        var resource_id: String,
    ):
        self.kind = kind^
        self.org_id = org_id^
        self.workspace_id = workspace_id^
        self.resource_id = resource_id^

    # ---- scope factories ----

    @staticmethod
    def workspace(kind: String, workspace_id: String) -> AuthzResource:
        """A workspace-scoped resource (org + resource id unset)."""
        return AuthzResource(
            kind.copy(), String(""), workspace_id.copy(), String("")
        )

    @staticmethod
    def workspace_resource(
        kind: String, workspace_id: String, resource_id: String
    ) -> AuthzResource:
        """A workspace-scoped resource carrying the PER-ROW resource id (org unset).
        By-id verbs (get / delete / update one row) use this so the authz check
        CARRIES the specific resource, not just the workspace scope — a conformer
        that gates per-row can then read `resource_id`. A conformer that maps on
        (workspace, action) alone ignores `resource_id` (the workspace-membership
        tier); the per-row tenancy bind (the fetched row's workspace == the path
        workspace) is then the dispatcher's to enforce."""
        return AuthzResource(
            kind.copy(), String(""), workspace_id.copy(), resource_id.copy()
        )

    @staticmethod
    def org(kind: String, org_id: String) -> AuthzResource:
        """An org-scoped resource (workspace + resource id unset)."""
        return AuthzResource(
            kind.copy(), org_id.copy(), String(""), String("")
        )

    @staticmethod
    def org_and_workspace(
        kind: String, org_id: String, workspace_id: String
    ) -> AuthzResource:
        """A resource scoped to a workspace within a named org (resource id
        unset)."""
        return AuthzResource(
            kind.copy(), org_id.copy(), workspace_id.copy(), String("")
        )

    # ---- scope predicates ----

    def has_org(self) -> Bool:
        """True iff an org id is set (non-empty)."""
        return self.org_id.byte_length() > 0

    def has_workspace(self) -> Bool:
        """True iff a workspace id is set (non-empty)."""
        return self.workspace_id.byte_length() > 0


# =============================================================================
# AuthzPort — the authorization interface (the one-method seam).
# =============================================================================
trait AuthzPort(Movable, Deinitable):
    """The neutral authorization interface. A host binds one conformer and gates
    its verbs through `check`; a managed deployment supplies a conformer backed
    by its own RBAC service."""

    def check[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        principal: AuthedUser,
        action: AuthzAction,
        resource: AuthzResource,
    ) raises -> Bool:
        """The authorization interface — can `principal` do `action` on `resource`?
        True on grant, False on deny. RT-parametric so a conformer reaching an
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
# NEITHER is a substitute for authentication. `AllowAuthenticatedAuthz` grants to
# any principal that carries a NON-NIL user id — which is only meaningful because
# the identity reaching a dispatcher is the one an upstream verifier STAMPED
# from a verified credential. Bind it only behind such a verifier, or behind an equivalent
# ingress-level authentication; bind `DenyAllAuthz` when a surface must be off.
# =============================================================================
struct AllowAuthenticatedAuthz(AuthzPort):
    """An `AuthzPort` that grants any action to any AUTHENTICATED principal — i.e.
    one whose `user_id` is not the nil UUID — and denies an unauthenticated one.

    The DB-free single-tenant default: it delegates the whole authorization
    decision to whatever authenticated the caller (a verified grant token names a
    user, an org and a workspace; a host that has already fenced the request to its
    own tenant has nothing left to look up without a membership store). A host with
    a membership store should bind a conformer backed by it instead; a host with
    per-repo ACLs should bind one that reads `resource.resource_id`."""

    def __init__(out self):
        pass

    def check[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        principal: AuthedUser,
        action: AuthzAction,
        resource: AuthzResource,
    ) raises -> Bool:
        """True iff `principal` carries a non-nil user id. `action` / `resource`
        are ignored (there is no store to scope them against). The nil test is a
        raw 16-byte scan so this leaf needs no `Uuid` import."""
        for i in range(16):
            if principal.user_id.byte_at(i) != UInt8(0):
                return True
        return False


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
        principal: AuthedUser,
        action: AuthzAction,
        resource: AuthzResource,
    ) raises -> Bool:
        """Always False."""
        return False
