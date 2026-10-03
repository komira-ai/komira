# =============================================================================
# src/komira_http/middleware/middleware.mojo — Middleware trait + Context
# =============================================================================
#
# The Middleware trait is the user-extension shape. Mojo 1.0.0b1 cannot
# express a `next: Next` callable type cleanly (no impl Trait / HKT), so
# the canonical workaround used by many ecosystems (Express, fastify,
# hono) is adopted: `before(req)` may short-circuit by returning
# `Some(response)`; otherwise the chain proceeds to the next middleware
# and ultimately the handler. After the handler returns, `after(req,
# resp)` runs in REVERSE registration order for response post-processing.
#
# Errors propagate via `raises`. The chain's `error_mapper` (an instance
# of ErrorMappingMiddleware) catches any uncaught Mojo Error and maps it
# to a 500 with sanitized body.
#
# `RequestContext` carries per-request state threaded through the chain:
#   - start_ns: monotonic clock at request start (latency calculation)
#   - span_id: opaque span identifier from TracingMiddleware (0 if no tracer)
#   - request_id: optional X-Request-Id propagation (This version ships empty;
#                 RequestIdMiddleware fills this)
#
# No UnsafePointer in public sigs. No wildcard origin. Pure value
# semantics. The trait surface is forward-compatible with later
# additions (CancellationToken) — adding a new param is a clean
# evolution rather than a breaking change.
# =============================================================================

from komira_uuid.uuid import Uuid

from komira_http.codec.types import HttpRequest, HttpResponse


# =============================================================================
# §0 — AuthedUser: the authenticated-identity POD attached post-auth.
# =============================================================================
#
# Carried on `RequestContext` (an `Optional[AuthedUser]`) after an auth
# middleware resolves a bearer token. It is a POD value (two `Uuid`s, each a
# 16-byte inline buffer — no heap, no pointer) threaded on the compiler-tracked
# per-request value, NOT a borrowed reference into any store. This is the
# encapsulation-clean way to thread identity: thread the value through the
# dispatch API, not a long-lived field.
#
# `AuthedUser` lives in `komira_http` (NOT in the auth library) so that
# `RequestContext` can carry it without `komira_http` depending on an
# application package — that would invert the layering (auth → http → auth
# cycle). An auth library IMPORTS this type and is the one that populates
# it. Other auth schemes (OAuth, API keys) reuse the same POD.


struct AuthedUser(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """The authenticated principal for a request.

    POD: three `Uuid`s (inline 16-byte buffers — no heap, no pointer) + a
    capability bitmask scalar. Attached to `RequestContext.authed_user` by an
    auth middleware after a successful token resolve; read by downstream
    handlers / authz to scope the request.

    Fields:
      user_id      — the authenticated user's UUID.
      session_id   — the session the request authenticated through (for
                     per-session revoke / audit).
      org_id       — the ORG the credential's claims are scoped to.
                     The org-scoped credential class (an `spk_` API key) pins an
                     (org, workspace) at mint; its resolve carries `org_id`
                     here so an authz path reads the org FROM THE
                     CLAIMS rather than resolving `workspace_id -> org_id` via a
                     synchronous store call. The NIL
                     UUID (`Uuid()`) means "no org context in the claims" — the
                     case for a plain user session (a session is user-scoped,
                     not org-scoped). A handler that needs an org scope checks
                     `org_id != Uuid()` and falls back to its prior resolution
                     ONLY for the nil (session) case.
      capabilities — a capability BITMASK carried in the claims: bit
                     N set ⇔ capability ordinal N is asserted by the credential.
                     `0` means "no capabilities asserted in the claims" — the
                     authz service then loads the membership for the scope as
                     before. This is an additive forward seam for a future
                     pre-resolved-capability fast path; the membership-backed
                     `Authz` decision remains authoritative when it is 0.
      principal_kind — the PRINCIPAL KIND ordinal (
                     0=HUMAN (the default), 1=AGENT, 2=SERVICE. Stored
                     as a bare `UInt8` ORDINAL (NOT the `PrincipalKind` value
                     type) so `komira_http` stays free of any application-
                     package dependency — the `PrincipalKind` bridge lives in
                     the authorization package (adding its `PrincipalKind` here
                     would invert the layering: http → an app package). Every
                     existing token resolves to a HUMAN principal whose
                     `principal_id == user_id` — `principal_kind` defaults to 0
                     so every existing construction site is unchanged (purely
                     additive, the same way `org_id`/`capabilities` were added).
    """

    var user_id: Uuid
    var session_id: Uuid
    var org_id: Uuid
    var capabilities: UInt64
    # The principal-kind ordinal. 0=HUMAN
    # (default), 1=AGENT, 2=SERVICE. A bare ordinal (no app-package type) so
    # AuthedUser stays a POD leaf that `komira_http` can own without an edge to the
    # authorization package. The `PrincipalKind` value type + the bridge live there.
    var principal_kind: UInt8

    def __init__(out self, user_id: Uuid, session_id: Uuid):
        """The org-less constructor (a plain user SESSION — user-scoped, no org
        context). `org_id` defaults to the NIL UUID, `capabilities` to 0, and
        `principal_kind` to 0 (HUMAN); a handler that needs an org scope must
        resolve it (the session path keeps its prior behavior). 100%
        source-compatible with every existing two-arg construction site."""
        self.user_id = user_id
        self.session_id = session_id
        self.org_id = Uuid()
        self.capabilities = UInt64(0)
        self.principal_kind = UInt8(0)

    def __init__(
        out self,
        user_id: Uuid,
        session_id: Uuid,
        org_id: Uuid,
        capabilities: UInt64,
    ):
        """The org-aware constructor (the org-scoped credential class — an
        `spk_` API key whose claims pin an org). Carries `org_id` +
        `capabilities` from the resolved credential so an authz path reads the org
        scope FROM THE CLAIMS with no store call. `principal_kind`
        defaults to 0 (HUMAN) — every existing four-arg construction site is
        unchanged (a HUMAN principal whose `principal_id == user_id`)."""
        self.user_id = user_id
        self.session_id = session_id
        self.org_id = org_id
        self.capabilities = capabilities
        self.principal_kind = UInt8(0)

    def __init__(
        out self,
        user_id: Uuid,
        session_id: Uuid,
        org_id: Uuid,
        capabilities: UInt64,
        principal_kind: UInt8,
    ):
        """The principal-aware constructor: the
        org-scoped form PLUS an explicit `principal_kind` ordinal (0=HUMAN /
        1=AGENT / 2=SERVICE). Used by the agent-delegation path (a future addition)
        to mint an AGENT/SERVICE principal's `AuthedUser`. HUMAN callers keep the
        two/four-arg forms (kind defaults to 0)."""
        self.user_id = user_id
        self.session_id = session_id
        self.org_id = org_id
        self.capabilities = capabilities
        self.principal_kind = principal_kind

    def principal_id(self) -> Uuid:
        """The PRINCIPAL identity (permissions_model_rfc §2.1). For every existing
        HUMAN token `principal_id == user_id` — the widening from `user_id` to
        `principal_id` is the GENERALIZATION of the identity, not a new column
        (an AGENT/SERVICE principal reuses the same `user_id` field to carry its
        principal id). This accessor names the generalized identity at the read
        site so callers stop reading `user_id` where they mean "the principal"."""
        return self.user_id


# =============================================================================
# §0b — GrantClaim: the RESOLVED grant a managed-app serve-side auth middleware
#   attaches post-verify. Defined HERE in `komira_http` (NOT imported from
#   the token package) for the SAME layering reason `AuthedUser` is defined here:
#   the token package transitively depends on `komira_http` (through the
#   secret store, the database layer and `komira_pg`), so
#   importing its `GrantClaim` into `RequestContext` would form a dependency CYCLE.
#   This is a plain POD MIRROR of the token package's `GrantClaim` fields over the
#   `komira_uuid` `Uuid` (the SAME Uuid `AuthedUser` already uses — no new dep);
#   a verifying grant middleware (above the cycle) converts the
#   offline-verified token `GrantClaim` into this http-local POD when it
#   attaches it, exactly as an auth middleware builds an `AuthedUser`.
# =============================================================================

comptime GRANT_CLAIM_CTX_REF_LEN: Int = 16
"""The width of a per-resource `resource_ref`, mirrored here for the SAME layering
reason the whole POD is mirrored here.

It must equal the token package's grant-claim ref length and the resource
catalog's resource-ref length — three constants describing ONE datum from
the http-mirror side, the wire side and the semantic side. A drift would silently
TRUNCATE a ref, which does not fail: it produces a shorter comparison that a
different resource can satisfy. The consumer that owns all three pins them
equal with a test."""


struct GrantClaim(
    Copyable, Movable, Deinitable
):
    # MOJO-1.0.0: `ImplicitlyCopyable` DROPPED, `Copyable` kept. 1.0.0 makes
    # `InlineArray` non-implicitly-copyable, and a struct owning one cannot
    # synthesise an implicit copy ctor -- there is no manual override (a
    # hand-written `__copyinit__` is not consulted). Copies of this POD
    # record are now spelled `.copy()`; that is the SAME memcpy b2 emitted
    # implicitly, so codegen and cost are unchanged.
    """The RESOLVED per-resource grant an offline-verified control-plane token
    carries, threaded on `RequestContext.grant_claim` by a managed-app serve-side
    auth middleware. A plain POD MIRROR of the token package's `GrantClaim` — 3
    `Int`/`Int64` scalars + 3 inline 16-byte `Uuid`s (no heap, no pointer) — so
    `komira_http` can own it WITHOUT depending on the (cyclically-above) token
    stack. The middleware maps the verified token `GrantClaim` field-for-
    field into this type; per-app enforcement reads it off the ctx.

    Fields (the token package's grant claim holds the authoritative semantics):
      resource_type — the `ResourceType` ordinal (APP = 1 for a managed app).
      resource_id   — the resource's Uuid; for a managed-app token == `aud`.
      level         — the `AccessLevel` ordinal held (READ / WRITE / DELETE).
      org_id        — the hard tenant boundary (grants NEVER cross an org).
      workspace_id  — the workspace fence (org-shared when nil).
      iat / exp     — the token's mint time + hard expiry (Unix-epoch µs).
      owner_id      — ★ the token SUBJECT: the principal the token was minted FOR.
      granted_ref   — ★ the 16-byte `resource_ref` of the per-resource grant entry
                      (v4 `GrantEntry`). NIL on a v3 claim and on a v4 claim with
                      no entries; a nil ref matches NOTHING.

    ★ `granted_ref` IS THE THIRD AXIS AND IT ANSWERS A QUESTION THE OTHER TWO
    CANNOT. `resource_id`/`aud` says WHICH DEPLOYMENT (every user of one app shares
    it); `owner_id` says WHICH HUMAN (but says nothing about what they hold);
    `granted_ref` says WHICH INSTANCE — the one resource the control plane resolved
    a grant on when it minted this token. For a PERSONAL resource whose instances
    are named by a string (a mailbox address, a repo name) that is the only datum
    that can answer "is this caller entitled to THIS name", because the app cannot
    read the control plane on the data path and the name→principal mapping lives
    there. The ref is `SHA-256(type_key ‖ 0x1F ‖ name)[0:16]`, computed IDENTICALLY
    by the mint (from the row it read) and by the app (from the request path), so
    neither needs the other's registry.

    ⛔ THIS FIELD CARRIES ONLY THE **FIRST** GRANT ENTRY of a scoped claim, and
    that is a stated limitation, not an oversight. A scoped claim carries up to 16
    entries; this POD is documented as heap-free and pointer-free, and a 16-entry
    array would be either a heap `List` (breaking that) or 384 inline bytes copied
    on every middleware hop. An app that addresses ONE resource per token (a
    token minted for one mailbox, one calendar, one room) reads this field. An app
    that needs the whole array uses its auth library's grant verifier, which
    carries the full grant list. Do NOT grow this POD into a second scoped
    claim; the two seams exist for different shapes of app.

    ★ `owner_id` IS PART OF THIS MIRROR BECAUSE A PERSONAL RESOURCE NEEDS IT.
    The control plane packs the subject in the
    claim, BOTH wire versions carry it, and the verifier maps it. A mirror
    that stops one field short while its own docstring claims to be a
    complete field-for-field copy makes the seam every managed app sits behind
    silently drop that datum: an app could not
    fence a caller to their own data even in principle.

    The lesson is not "add a field" — it is that a type describing itself as a MIRROR
    must be pinned to its source by a test, because a missing field in a mirror is
    invisible at every call site. `resource_id`/`aud` is the DEPLOYMENT (which app);
    `owner_id` is the PRINCIPAL (which human). They are different axes and an app
    needs both."""

    var resource_type: Int
    var resource_id: Uuid
    var level: Int
    var org_id: Uuid
    var workspace_id: Uuid
    var iat: Int64
    var exp: Int64
    # ★ The SUBJECT axis. Nil means the credential named no principal, which every
    # owner-fenced route must treat as a refusal, never as a wildcard.
    var owner_id: Uuid
    # ★ The PER-RESOURCE axis (v4 `GrantEntry.resource_ref`). Nil on a v3 claim and
    # on a v4 claim with no entries — see the class docstring's `granted_ref` note.
    var granted_ref: Array[UInt8, GRANT_CLAIM_CTX_REF_LEN]

    def __init__(
        out self,
        resource_type: Int,
        resource_id: Uuid,
        level: Int,
        org_id: Uuid,
        workspace_id: Uuid,
        iat: Int64,
        exp: Int64,
        owner_id: Uuid = Uuid(),
    ):
        """★ `owner_id` DEFAULTS TO NIL so every existing 7-arg construction site
        stays source-compatible AND fail-closed: a caller that does not supply a
        subject confers no owner authority, because nil never equals a path segment.
        The alternative (a required 8th argument) would have been a wide mechanical
        diff whose only effect is to make un-migrated call sites not compile — and
        the fail-closed default already makes them safe.

        `granted_ref` is NIL on this overload for the SAME reason and with the same
        force: a v3 claim has no per-resource half at all, and a nil ref names no
        resource and matches nothing (`ref_matches` and `find_grant` both reject a
        nil on EITHER side). A v3 token therefore confers no per-resource
        entitlement rather than a wildcard one."""
        self.resource_type = resource_type
        self.resource_id = resource_id
        self.level = level
        self.org_id = org_id
        self.workspace_id = workspace_id
        self.iat = iat
        self.exp = exp
        self.owner_id = owner_id
        self.granted_ref = Array[UInt8, GRANT_CLAIM_CTX_REF_LEN](fill=0)

    def __init__(
        out self,
        resource_type: Int,
        resource_id: Uuid,
        level: Int,
        org_id: Uuid,
        workspace_id: Uuid,
        iat: Int64,
        exp: Int64,
        owner_id: Uuid,
        granted_ref: Array[UInt8, GRANT_CLAIM_CTX_REF_LEN],
    ):
        """The v4 form: the identity half PLUS the 16-byte `resource_ref` of the
        per-resource grant entry the verifier resolved for this token.

        ⛔ THE REF IS RAW BYTES HERE ON PURPOSE, exactly as it is on the v4 wire.
        `komira_http` must not learn how a ref is DERIVED — `ResourceRef.from_name`
        lives in the OSS `resource_catalog` leaf, which sits ABOVE this package —
        only how WIDE one is. The consumer wraps it (`ResourceRef(claim.granted_ref)`)
        and compares with `ref_matches`, which is nil-safe on both sides."""
        self.resource_type = resource_type
        self.resource_id = resource_id
        self.level = level
        self.org_id = org_id
        self.workspace_id = workspace_id
        self.iat = iat
        self.exp = exp
        self.owner_id = owner_id
        # MOJO-1.0.0: `granted_ref` is a borrowed param, so `^` would be a
        # use-after-move at the caller. 16 bytes, ctor-only -- same memcpy b2 emitted.
        self.granted_ref = granted_ref.copy()

    def granted_ref_is_nil(self) -> Bool:
        """True iff `granted_ref` is all-zero — i.e. this credential names NO
        specific resource instance.

        Stated as a named predicate rather than left to each call site, because the
        answer must never be read as "any resource": a nil ref is the shape of a v3
        token, of a v4 token the mint left entitlement-free, and of a mirror field
        somebody forgot to populate. All three must refuse."""
        var acc = UInt8(0)
        for i in range(GRANT_CLAIM_CTX_REF_LEN):
            acc |= self.granted_ref[i]
        return acc == UInt8(0)

    def aud(self) -> Uuid:
        """The audience the token was minted FOR = the deployment id =
        `resource_id` (mirrors the token claim's `aud`)."""
        return self.resource_id


# =============================================================================
# §1 — RequestContext: per-request threaded state.
# =============================================================================


@fieldwise_init
struct RequestContext(
    Copyable, Movable, Deinitable
):
    # MOJO-1.0.0 CASCADE, NOT A LOCAL CHOICE. `ImplicitlyCopyable` dropped here
    # because `grant_claim: Optional[GrantClaim]` is no longer implicitly
    # copyable -- and GrantClaim is not, because 1.0.0 made `InlineArray`
    # non-implicitly-copyable and a struct owning one cannot synthesise the
    # implicit copy ctor (no manual override exists). `Copyable` is kept, so
    # every copy still happens; it is now spelled `.copy()`, which is the SAME
    # memcpy the compiler was emitting.
    #
    # ⚠ THE KEYSTONE IS `komira_uuid.uuid.Uuid`, NOT THIS STRUCT.
    # GrantClaim holds FOUR `Uuid`s and Uuid is itself `ImplicitlyCopyable` with
    # an `InlineArray[UInt8, 16]` field -- so if Uuid drops Uuid's conformance,
    # this cascade arrives here anyway and nothing done locally can stop it.
    # Retyping `GrantClaim.granted_ref` to `SIMD[DType.uint8, 16]` WOULD keep
    # both structs implicitly copyable (16 is a power of two, so SIMD can
    # express it) -- and was REJECTED: `granted_ref` is passed
    # as `ResourceRef(claim.granted_ref)` by consumers in other packages,
    # so the retype is a cross-package API change,
    # and `ResourceRef` has already dropped its own conformance for the same
    # reason. One answer everywhere beats two that disagree at the boundary.
    """Per-request state threaded through the middleware chain.

    POD struct: all-scalar fields, no heap-owning state. Cheap to pass
    by value through the chain.

    Fields:
      start_ns      — request start (monotonic ns since epoch); set by
                      LoggingMiddleware.before. Used in after() for
                      latency calculation.
      span_id       — opaque span identifier from the tracer; 0 if no
                      tracer is configured OR if TracingMiddleware
                      was not enabled.
      worker_id     — worker / pthread id; threaded through for
                      komira_trace.Tracer.start_span which is per-worker.
                      single-threaded baseline: 0.
      short_circuit — set by chain driver when a `before` returns
                      Some(response) so `after` knows the response did
                      NOT come from a handler — affects which post-
                      processors run (e.g. CORS still adds headers).
      authed_user   — the authenticated principal, set by an auth
                      middleware's `before` after a successful token
                      resolve; `None` until then (and on every
                      unauthenticated / public route). Additive POD field
                      (an `Optional[AuthedUser]` — no heap, no pointer);
                      handlers + authz read it to scope the request. This
                      is the threaded-on-the-dispatch-value identity seam.
      grant_claim   — the RESOLVED grant an offline-verified control-plane
                      token carries, set by a `VerifyingGrantMiddleware`'s
                      `before` on an app's serve surface (shared serve-side
                      auth that every app may install); `None`
                      until then. Additive POD field (an
                      `Optional[GrantClaim]` — 3 Int/Int64 + 3 inline
                      `Uuid`s, no heap, no pointer). It lives in ITS OWN
                      field and MUST NOT populate `AuthedUser.capabilities`
                      — conflating the two would trip the capability-bitmask
                      short-circuit path. A managed-app handler / per-app
                      enforcement reads THIS field (the resolved grant) and
                      feeds it to `authorize_from_claim`; the human-session
                      identity path keeps reading `authed_user`.
    """

    var start_ns: UInt64
    var span_id: UInt64
    var worker_id: Int
    var short_circuit: Bool
    var authed_user: Optional[AuthedUser]
    # The offline-verified control-plane grant (managed-app serve-side auth). Its
    # OWN field — NEVER folded into `authed_user.capabilities` (that would trip the
    # capability-bitmask short-circuit). POD (`GrantClaim` is 3 Int/Int64 + 3
    # inline `Uuid`s — pointer-free), copied per-request with the rest of the ctx.
    var grant_claim: Optional[GrantClaim]
    # GRANT-PRE-AUTHORIZED (managed-app serve-side authz). Set by a managed app's
    # dispatcher-level grant gate AFTER it has authorized a request from
    # `grant_claim` (tenancy-bind + `authorize_from_claim` — the SOLE authorizer on
    # the managed-app serve path). When True, a downstream handler's store-backed
    # `Authz.require` is a redundant re-gate and MUST be skipped: the grant gate
    # already made the ONE authorization decision (`authorize_decision`), and the
    # managed-app principal holds NO membership row the store gate could satisfy.
    # A plain `Bool` POD (no heap, no pointer); defaults False so every existing
    # co-hosted (session / API-key) request path is byte-identical — the store
    # `Authz.require` still decides when this is False. This is NOT an authz bypass:
    # it is the marker that authz ALREADY ran (upstream, on the resolved grant), so
    # the handler does not double-decide.
    var grant_preauthorized: Bool

    @staticmethod
    def new() -> RequestContext:
        return RequestContext(
            start_ns=UInt64(0),
            span_id=UInt64(0),
            worker_id=0,
            short_circuit=False,
            authed_user=Optional[AuthedUser](),
            grant_claim=Optional[GrantClaim](),
            grant_preauthorized=False,
        )

    @staticmethod
    def for_worker(worker_id: Int) -> RequestContext:
        return RequestContext(
            start_ns=UInt64(0),
            span_id=UInt64(0),
            worker_id=worker_id,
            short_circuit=False,
            authed_user=Optional[AuthedUser](),
            grant_claim=Optional[GrantClaim](),
            grant_preauthorized=False,
        )


# =============================================================================
# §2 — Middleware trait (user-extension shape; This version ships builtins).
# =============================================================================
# The `before` / `after` pair is the Mojo 1.0.0b1
# workaround for the absent `Service<Request> = Layer<Request, Response>`
# higher-kinded type. Express / fastify / hono all use this shape.
#
# Trait surface:
#   * before — invoked BEFORE the next middleware / handler. Returns
#              Some(response) to short-circuit; None to continue. May
#              `raises` — exception propagates UP through the chain.
#   * after  — invoked AFTER the inner chain returns. Receives the
#              borrowed request + the mut response so it can rewrite
#              headers / body (e.g. compression, CORS). May `raises`.
#
# Ships the trait declaration + 4 concrete builtins composed in
# `MiddlewareChain`. User-extension via the trait is forward-compatible;
# the chain's parametric extension hook is filled in separately.


trait Middleware(Movable, Deinitable):
    """Ordered request/response interceptor.

    Conform to this trait to plug a custom interceptor into a
    MiddlewareChain. The 4 builtins (Cors / Tracing / Logging /
    ErrorMapping) are concrete-typed for performance + Mojo 1.0.0b1
    compatibility (no `List[OwnedPointer[Middleware]]` dispatch); user
    extensions plug through a single parametric chain slot.

    Lifecycle:
      1. before(req, ctx) — may short-circuit by returning Some(response).
      2. (next middleware / handler) — runs only if before returned None.
      3. after(req, resp, ctx) — runs UNCONDITIONALLY in reverse order.

    Short-circuit semantics: returning Some(response) from before()
    skips ALL subsequent middlewares AND the handler. The after()
    chain then runs in reverse on that short-circuit response. This
    lets e.g. an AuthMiddleware return 401 while still allowing
    LoggingMiddleware to log the rejection.

    Error semantics: a `raises` exception from any layer propagates up
    until ErrorMappingMiddleware (which conventionally sits at the
    outermost / first-registered position) catches it and converts to
    a 500.
    """

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        ...

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        ...
