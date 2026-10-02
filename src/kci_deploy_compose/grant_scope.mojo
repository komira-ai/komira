# =============================================================================
# kci_deploy_compose/grant_scope.mojo — THE ONE DERIVATION of a grant's typed
#   `GrantScope`, and the compose-time REFUSALS that make a malformed one
#   unrepresentable.
# =============================================================================
#
# ── WHY EVERY GRANT CARRIES AN EXPLICIT SCOPE ────────────────────────────────
#
# An empty `GrantSpec.target_resource_logical_id` is ambiguous: read as "the
# ambient container that owns everything in this deployment", it admits FOUR
# DISTINCT readings, two of which INVERT it. So every grant carries an explicit
# `GrantScope` and an empty target alone means nothing. The four readings:
#
#   * ONE named resource whose name only a LOWER TIER can form — ordinals 3/4's
#     `<project>-bootstrap` / `<account>-bootstrap`;
#   * the deployment's whole boundary, across kinds — ordinal 10's `projects/<P>`;
#   * a name-prefixed CLASS in a namespace the target provides — the AWS arm's
#     reading of ordinal 8's empty target (the tool's IAM role path);
#   * every resource of a kind this deploy owns — ordinal 18's AWS reading, which
#     is DELIBERATELY REFUSED.
#
# AND IT IS UNIMPLEMENTABLE ON A TARGET WITH NO AMBIENT CONTAINER. GCP has a
# project; AWS has an account and correctly REFUSES to use it ("an empty resource
# name renders a syntactically valid ARN matching nothing, and `*` would turn the
# tightest grant in the manifest into the widest in the account"); Kubernetes has
# no such container AT ALL.
#
# ── THE COMPOSER EMITS **ONE** CLASS PER NODE, AND WHERE THE READERS DISAGREE
#      THE COMPOSER'S CLASS IS THE COMPOSER'S INTENT ─────────────────────────
#
# This is the one judgement in this file and it is worth stating, because the
# four readings above are a CENSUS OF READER INTERPRETATIONS and read at a glance
# like a prescription for what to compose.
#
# Ordinal 8 `ADMIN_SET_IAM` with an empty target is the case that decides it.
# ONE composed node, TWO materializations:
#
#   * GCP  — `projects/<P>`: the deployment's whole boundary.
#   * AWS  — the tool's IAM role path (`role/kci/*`): a NAME-PREFIXED CLASS of
#            IAM roles, which is strictly NARROWER than the account.
#
# The IR node cannot be both `DEPLOYMENT` and `RESOURCE_CLASS(IAM_ROLE)`. It is
# composed as **DEPLOYMENT**, because that is what the composer means — "this
# principal may set IAM policy within this deployment" — and the AWS arm's
# narrowing to an IAM path is that ARM's own decision: the IR node denotes the
# RELATIONSHIP; the ARM chooses the carrier.
#
# AND COMPOSING IT AS `RESOURCE_CLASS(IAM_ROLE)` WOULD BREAK EVERY BOOTSTRAP,
#     BY THIS FILE'S OWN SELF-CONTAINING REFUSAL. `role/kci/*` matches
#     `…:role/kci/kci-deploy` — the deploy role is INSIDE ITS OWN FENCE — so a
#     RESOURCE_CLASS(IAM_ROLE) node is precisely what
#     `refuse_self_containing_class` below rejects. Composing it that way would
#     make the deploy principal's admin-IAM grant unbuildable and no compute
#     environment could be bootstrapped at all. The refusal exists so a NEW
#     RESOURCE_CLASS grant cannot be composed onto a self-containing kind, not to
#     retro-refuse an existing one through a classification choice made here.
#
# ── THE DERIVATION, IN THREE LINES ───────────────────────────────────────────
#
#   non-empty target                -> RESOURCE(target_logical_id = it)
#   EMPTY target, ordinal 3 or 4    -> WELL_KNOWN_RESOURCE(BUCKET,
#                                        "bootstrap-state-bucket")
#   EMPTY target, anything else     -> DEPLOYMENT
#
# The second line is what BOTH mappers implement (`<project>-bootstrap` on GCP,
# `<account>-bootstrap` on AWS): READ/WRITE's empty target has exactly ONE
# subject. ONE subject is `RESOURCE` in every respect except that the composer
# cannot form the NAME — which is the whole reason `WELL_KNOWN_RESOURCE` exists
# (the pure compose has no project).
#
# `well_known_id` IS SYMBOLIC AND MUST STAY SYMBOLIC. Putting a physical name
# here would re-create the problem the class solves, one field over.
#
# Encapsulation: value types in, value types out; every refusal `raise`s with the
# node it is about. ZERO UnsafePointer, ZERO wildcard origin.
# =============================================================================

from kci_manifest_proto.full_manifest import (
    Capability,
    GrantScope,
    GrantScopeClass,
    GrantSpec,
    ResourceKind,
)


# ── THE WELL-KNOWN IDS ───────────────────────────────────────────────────────
# A SYMBOLIC name each target arm resolves to a physical one. There is exactly
# one today; a second belongs here and nowhere else, so the set of names an arm
# must know is readable in one place.
comptime WELL_KNOWN_BOOTSTRAP_STATE_BUCKET: String = "bootstrap-state-bucket"


# THE KINDS A `RESOURCE_CLASS` MAY NOT NAME. A class selector over a kind that
# can CONTAIN the grant's own principal authorizes the principal against ITSELF.
# Making it safe needs "every resource of kind K EXCEPT the principal", i.e. an
# exclusion, and two things block one:
#   1. The AWS policy statement is `{sid, actions, resource}` — NO `effect`
#      field — and the renderer hardcodes `"Effect":"Allow"`. That is
#      deliberate: an effect field so that ONE document can say Deny would put
#      a Deny within reach of every seam function that renders a statement.
#   2. `GrantScope` has no condition, tag or exclusion field.
# A tag on the deploy role is a PRECONDITION for excluding it from the role
# path, never the exclusion itself.
#
# ⇒ Until an EXCLUSION primitive exists — not a tag, an exclusion — this refusal
#   stands.
comptime _KIND_IAM_ROLE: Int = ResourceKind.RESOURCE_KIND_IAM_ROLE
comptime _KIND_SERVICE_ACCOUNT: Int = ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT


def grant_scope_for(capability: Int, target_resource: String) raises -> GrantScope:
    """THE ONE DERIVATION. The typed `GrantScope` of a grant the composer is
    about to emit.

    ONE FUNCTION, THREE WRITERS. The bootstrap composition's grant node,
    `compose_api._grant_node` (the INVOKE_SERVICE arm) and
    `compose_api._base_grant_node` (the generic arm) all call it. A second
    derivation would let two composers disagree about what the same `("")` means
    — which is the defect this whole type exists to end, reproduced one tier up.

    The result is `checked_grant_scope`-clean by construction; callers that build
    a scope any other way must run it through that function themselves.
    """
    if target_resource.byte_length() > 0:
        # RESOURCE — exactly ONE named node in this graph. `resource_kind` is
        # left UNSET: it is derivable for RESOURCE — the target node is IN the
        # manifest and carries its own kind, so restating it here would be a
        # second copy that can disagree with the node it names.
        return GrantScope(
            GrantScopeClass(GrantScopeClass.GRANT_SCOPE_RESOURCE),
            ResourceKind(ResourceKind.RESOURCE_KIND_UNSPECIFIED),
            target_resource,
            String(""),  # boundary_ref: the deployment's own
            String(""),
        )
    if (
        capability == Capability.CAPABILITY_READ_OBJECT_STORE
        or capability == Capability.CAPABILITY_WRITE_OBJECT_STORE
    ):
        # WELL_KNOWN_RESOURCE — the day-0 state bucket. ONE subject, whose NAME
        # only the target arm can form (`<project>-bootstrap` on GCP,
        # `<account>-bootstrap` on AWS).
        #
        # NOT `RESOURCE_CLASS`. That would be strictly WIDER than the one
        # bucket — every bucket matching a prefix — which is the exact widening
        # the AWS project-scope refusal exists to prevent, arriving through the
        # fix for it.
        return GrantScope(
            GrantScopeClass(GrantScopeClass.GRANT_SCOPE_WELL_KNOWN_RESOURCE),
            ResourceKind(ResourceKind.RESOURCE_KIND_BUCKET),
            String(""),
            String(""),
            WELL_KNOWN_BOOTSTRAP_STATE_BUCKET,
        )
    # DEPLOYMENT — the deployment's whole boundary, ACROSS kinds, so
    # `resource_kind` MUST be unset. This is ordinals 8 / 9 / 10 / 11 / 12 / 13
    # / 16 / 17 / 25's empty target, and ordinal 10 `LOG_WRITE` is the class's
    # one uncontested user.
    return GrantScope(
        GrantScopeClass(GrantScopeClass.GRANT_SCOPE_DEPLOYMENT),
        ResourceKind(ResourceKind.RESOURCE_KIND_UNSPECIFIED),
        String(""),
        String(""),
        String(""),
    )


def checked_grant_scope(scope: GrantScope, where: String) raises -> GrantScope:
    """THE COMPOSE-TIME REFUSAL. Returns `scope` iff it satisfies the per-class
    field contracts and the self-containing rule; otherwise RAISES, naming
    `where`.

    IT IS THE **RETURN TYPE** THAT CARRIES THE CHECK, not a `def check(...)`
    a caller can forget to call. A validator whose result is discardable is a
    validator that gets discarded.

    THE SELF-CONTAINING ARM IS UNREACHABLE FROM ANY COMPOSER TODAY AND THAT IS
    STATED RATHER THAN HIDDEN. `grant_scope_for` never returns `RESOURCE_CLASS`,
    so no manifest walk can exercise it and an assertion over composed nodes
    alone would pass VACUOUSLY. Its falsifier therefore builds the malformed
    scope DIRECTLY and asserts the raise.
    """
    var cls = scope.scope_class.value
    if cls == GrantScopeClass.GRANT_SCOPE_UNSPECIFIED:
        raise Error(
            String("grant scope: ")
            + where
            + String(
                " left `scope_class` UNSPECIFIED. That is the fail-fast zero"
                " value and the legacy-`\"\"` sentinel — a composed grant node"
                " MUST state which of the four shapes it is, because readers"
                " that decide that for themselves disagree, and two of them"
                " invert it."
            )
        )
    if cls == GrantScopeClass.GRANT_SCOPE_RESOURCE:
        if scope.target_logical_id.byte_length() == 0:
            raise Error(
                String("grant scope: ")
                + where
                + String(
                    " is RESOURCE with an EMPTY `target_logical_id`. RESOURCE"
                    " means exactly ONE named node in this graph; an empty id"
                    " is `\"\"` reconstituted inside the new type."
                )
            )
        return scope.copy()
    # Every non-RESOURCE class names no single node.
    if scope.target_logical_id.byte_length() > 0:
        raise Error(
            String("grant scope: ")
            + where
            + String(
                " carries a `target_logical_id` on a class that is not"
                " RESOURCE. Only RESOURCE names one node; the others select."
            )
        )
    if cls == GrantScopeClass.GRANT_SCOPE_DEPLOYMENT:
        if scope.resource_kind.value != ResourceKind.RESOURCE_KIND_UNSPECIFIED:
            raise Error(
                String("grant scope: ")
                + where
                + String(
                    " is DEPLOYMENT with a `resource_kind` set. DEPLOYMENT is"
                    " the whole boundary ACROSS kinds — naming one would be a"
                    " RESOURCE_CLASS wearing the wrong discriminant."
                )
            )
        return scope.copy()
    if cls == GrantScopeClass.GRANT_SCOPE_WELL_KNOWN_RESOURCE:
        if scope.well_known_id.byte_length() == 0:
            raise Error(
                String("grant scope: ")
                + where
                + String(
                    " is WELL_KNOWN_RESOURCE with an EMPTY `well_known_id`."
                    " The symbolic name IS the whole content of this class;"
                    " without it the node is `\"\"` again, one field over."
                )
            )
        if scope.resource_kind.value == ResourceKind.RESOURCE_KIND_UNSPECIFIED:
            raise Error(
                String("grant scope: ")
                + where
                + String(
                    " is WELL_KNOWN_RESOURCE with no `resource_kind`. The arm"
                    " resolving the symbolic name has to know WHAT it is"
                    " resolving (a bucket, a table, a repo)."
                )
            )
        return scope.copy()
    # RESOURCE_CLASS.
    if scope.resource_kind.value == ResourceKind.RESOURCE_KIND_UNSPECIFIED:
        raise Error(
            String("grant scope: ")
            + where
            + String(
                " is RESOURCE_CLASS with no `resource_kind`. The kind IS the"
                " selector; without it the class selects everything, which is"
                " `\"\"` reconstituted inside the new type."
            )
        )
    return refuse_self_containing_class(scope, where)


def refuse_self_containing_class(
    scope: GrantScope, where: String
) raises -> GrantScope:
    """A `RESOURCE_CLASS` over a kind that can CONTAIN the grant's own
    principal is REFUSED until an exclusion primitive exists.

    Today that is exactly kinds 8 `IAM_ROLE` and 11 `SERVICE_ACCOUNT`. It is a
    NAMED SUB-CASE rather than a reason to drop the class: `RESOURCE_CLASS` does
    not create the hole (an empty-target role statement renders the tool's role
    path, and the deploy role is inside that fence) — it is the first construct
    that makes the hole NAMEABLE BY A LINT.
    """
    var kind = scope.resource_kind.value
    if kind == _KIND_IAM_ROLE or kind == _KIND_SERVICE_ACCOUNT:
        raise Error(
            String("grant scope: ")
            + where
            + String(
                " is RESOURCE_CLASS over a kind that can CONTAIN THE GRANT'S"
                " OWN PRINCIPAL (ResourceKind ordinal "
            )
            + String(kind)
            + String(
                " — IAM_ROLE or SERVICE_ACCOUNT). Such a grant authorizes the"
                " principal AGAINST ITSELF: `role/kci/*` matches"
                " `…:role/kci/kci-deploy`, so a class grant over roles would"
                " give the deploy role iam:PutRolePolicy,"
                " iam:UpdateAssumeRolePolicy and iam:DeleteRole ON ITSELF."
                " Making it safe needs `every resource of kind K EXCEPT the"
                " principal`, which needs a Deny/condition primitive that"
                " neither the AWS policy statement (no `effect` field,"
                " deliberately) nor GrantScope (no condition, tag or exclusion"
                " field) can express. Compose a RESOURCE scope naming the one"
                " target, or land the exclusion primitive first."
            )
        )
    return scope.copy()


def grant_scope_of(gs: GrantSpec, where: String) raises -> GrantScope:
    """THE READER'S ENTRY POINT. The grant's typed scope, or a RAISE naming the
    node.

    AN UNSET SCOPE IS A REFUSAL, NOT A FALLBACK TO FIELD 3. Falling back is the
    state in which `\"\"` had to be interpreted, and interpreting it is what
    readers did in different ways. A composer that forgets to set it fails at
    the node, naming itself, instead of silently getting whichever meaning this
    particular reader holds.
    """
    if not gs.scope:
        raise Error(
            String("grant scope: ")
            + where
            + String(
                " carries NO `GrantScope` (field 4). Every composer sets it and"
                " there is no field-3 `\"\"` fallback — so this node was built"
                " by something that does not derive its scope. Build it"
                " through `kci_deploy_compose.grant_scope.grant_scope_for`."
            )
        )
    return checked_grant_scope(gs.scope.value(), where)


def scope_is_well_known(scope: GrantScope, well_known_id: String) -> Bool:
    """TRUE iff `scope` is the WELL_KNOWN_RESOURCE named `well_known_id`.

    The typed replacement for `target_resource_logical_id.byte_length() == 0`
    in a reader that resolves the day-0 state bucket. Note what it no longer
    matches: a DEPLOYMENT-scoped grant, which the empty-string test could not
    tell apart and which resolves to something else entirely.
    """
    return (
        scope.scope_class.value == GrantScopeClass.GRANT_SCOPE_WELL_KNOWN_RESOURCE
        and scope.well_known_id == well_known_id
    )


def scope_is_deployment(scope: GrantScope) -> Bool:
    """TRUE iff `scope` is the deployment's whole boundary, across kinds."""
    return scope.scope_class.value == GrantScopeClass.GRANT_SCOPE_DEPLOYMENT


def scope_names_one_resource(scope: GrantScope) -> Bool:
    """TRUE iff `scope` names exactly ONE node in this graph."""
    return scope.scope_class.value == GrantScopeClass.GRANT_SCOPE_RESOURCE
