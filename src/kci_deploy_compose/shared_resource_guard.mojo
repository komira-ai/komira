"""`shared_resource_guard` — A TEARDOWN MAY NOT REAP WHAT IT DOES NOT OWN.

The pure core behind the `kci delete` refusal, and behind the SWEEP that
answers "which nodes in an app's graph address a project-global resource?"

THE HAZARD
==========
`compose_api` composes the project-global API-Gateway backend-auth service
account into EVERY edge-bearing app's OWN graph. Were that node
`RETENTION_DELETE`, the teardown of one unrelated app would delete the service
account every other app's front door impersonates.

`compose_api`'s `SHARED_RESOURCE_RETENTION` block is the FIRST half of the
answer: those nodes are `RETENTION_RETAIN_KEEP`, so an ordinary `delete` skips
them. This module is the SECOND half, and it is the general one, because
retention is not a floor:

  * `--delete-data` LIFTS the RETAIN_KEEP skip project-wide (`force_delete_data`).
  * a `--run-id` run scope lifts it too (`run_scope_lifts_retention`).
  * and RETAIN_KEEP is a value an author can forget to write on the NEXT
    project-global node.

A retention is a DEFAULT. This is a CHECK, and it reads the graph rather than
trusting the annotation on it.

THE RULE, DERIVED — NEVER A LIST OF NODE IDS
============================================
A hand-written list of "the shared nodes" is a gate that stops seeing the node
somebody adds tomorrow. The set is WALKED, never listed.

AND THE PREDICATE IS **EXCLUSIVE** OWNERSHIP, NOT OWNERSHIP. Asking "does THIS
graph create the resource?" cannot see the hazard at all — because the
edge-bearing graph really does create the gateway SA (get-or-create). N graphs
create it; that is fine. What none of them has is the right to DELETE it. So:

    An identity is EXCLUSIVELY OWNED by this graph iff this graph creates it AND
    no other release machine's graph creates it.

    A node is a TEARDOWN HAZARD iff its `delete` would remove something no
    exclusively-owned identity of this graph accounts for, AND the reverse walk
    would actually reach it (`RETENTION_DELETE`, or RETAIN_KEEP under a
    `force_delete_data` lift).

⇒ exclusivity is a CROSS-GRAPH fact, so this module cannot answer it alone and
does not pretend to: `siblings` is a required argument, and an empty sibling set
means "nothing else declares any of this", which is the correct reading for the
LAST machine out of an environment.

THE GRANT ARM NEEDS THE PRINCIPAL, AND THAT IS THE ONE PLACE THIS DIFFERS FROM
`run_scope._node_addressed_names`. That function collects what a node ADDRESSES
and deliberately excludes the principal ("`principal_identity_ref` names WHO is
being authorized, not WHAT is being changed"), which is right for its question —
"does this run own every name in the graph?".

The teardown question is different, because a grant conformer's delete removes
exactly ONE `(target, member, role)` triple. A binding is therefore this graph's
to remove iff EITHER end is EXCLUSIVELY its own:

    principal `<svc>-role` (exclusive)  x  target `shared-secret-a`
        -> OURS. The member is deleted in the same reverse walk; unbinding it
           takes away nothing anyone else holds.
    principal `deploy-principal`        x  target `<svc>-svc` (exclusive)
        -> OURS. The policy itself goes with the service.
    principal `deploy-principal`        x  target `shared-secret-a`
        -> HAZARD. Neither end is ours at all. Every app composes this SAME node,
           so whichever app is deleted first unbinds the authority all the
           others' validate jobs run on.
    principal `deploy-principal`        x  target `<gateway SA>`
        -> HAZARD. The target IS created by this graph — and by every other
           edge-bearing graph, so it is not EXCLUSIVE, and unbinding actAs on it
           makes the next edge deploy of any OTHER app fail CreateApiConfig.

Collapsing the two ends into one predicate makes this either noisy (refusing
every `<svc>-role` grant on a shared secret) or blind (missing the
deploy-principal x shared-secret pair). They are kept apart.

FAIL-CLOSED OVER `ResourceKind`
===============================
`_node_created_identities` is TOTAL over the enum and RAISES on an ordinal it
does not know — the `run_scope._node_addressed_names` discipline, for the same
reason: a default arm that answers "creates nothing" / "addresses nothing"
makes a NEW resource kind silently invisible to this guard, and invisible here
means reapable by a graph that does not own it. A new kind must state which of
its names it creates before it can appear in a graph anyone deletes.

WHAT IS DELIBERATELY NOT HERE
=============================
* NO cloud read. Whether a sibling is LIVE is a question for the cloud's own list
  API; this module answers the offline half — "does another release machine's
  bundle compose a node addressing this same resource?" — which is the half that
  is deterministic, testable, and available before anything is deleted. The IO
  shell supplies the sibling manifests, walking the SAME release-machine corpus
  its other ownership refusals walk.
* NO skip-and-continue. `shared_resource_refusal` refuses the WHOLE teardown, for
  `run_scope_violations`' reason: a teardown that silently skips one node is a
  teardown that leaks, and the leak is invisible.

Pure + deterministic: proto values in, `String`s out. No I/O, no clock, no
randomness. ZERO UnsafePointer, no wildcard origin.
"""

from kci_manifest_proto.full_manifest import (
    FullManifest,
    ResourceKind,
    ResourceNode,
    Retention,
)


# =============================================================================
# §1 — the finding value.
# =============================================================================


struct SharedResourceFinding(Copyable, Movable, Deinitable):
    """ONE node of a graph that addresses a resource the graph does not create.

    `resource` is the cloud-resource identity — an SA `account_id`, a Secret
    handle, an artifact repository, a `<svc>-svc` service name, or the EMPTY
    string for a project-scoped IAM binding (`projects/<P>`, which no app owns by
    construction). `principal` is set only for the two grant kinds.

    `reaped` is what makes this a HAZARD rather than an observation: TRUE iff the
    reverse walk would actually reach the node under the retention lift in force.
    """

    var logical_id: String
    var kind: Int
    var resource: String
    var principal: String
    var reaped: Bool

    def __init__(
        out self,
        var logical_id: String,
        kind: Int,
        var resource: String,
        var principal: String,
        reaped: Bool,
    ):
        self.logical_id = logical_id^
        self.kind = kind
        self.resource = resource^
        self.principal = principal^
        self.reaped = reaped


def _project_scope_label() -> String:
    """The label used for an EMPTY grant target. A project-scoped binding
    (`projects/<P>`) is the most-shared resource there is, and printing `''`
    reads as a bug rather than as the project."""
    return String("<the project itself>")


def finding_resource_label(f: SharedResourceFinding) -> String:
    """`f.resource` rendered for a human — the project label for an empty one."""
    if f.resource.byte_length() == 0:
        return _project_scope_label()
    return f.resource.copy()


# =============================================================================
# §2 — what a graph CREATES. TOTAL over ResourceKind; raises on an unknown one.
# =============================================================================


def _node_created_identities(node: ResourceNode) raises -> List[String]:
    """The cloud-resource identities `node` BRINGS INTO EXISTENCE — empty for a
    node that only binds/mutates something else (every grant kind).

    THE LOGICAL ID COUNTS AS AN IDENTITY FOR THE CREATE KINDS, and only for
    them. `compose_api` derives a served service's cloud name from its node's
    logical id (`<svc>-svc`), and a grant targeting a sibling names exactly that
    string — so a graph that composes `<T>-svc` owns the policy a grant on
    `<T>-svc` unbinds. A GRANT node's own logical id
    (`deploy-principal-reads-shared-secret-a`) is not a cloud name at all;
    admitting it would make the graph claim to own the very thing this module
    exists to notice it does not."""
    var out = List[String]()
    var k = node.kind.value
    if k == ResourceKind.RESOURCE_KIND_SERVERLESS_COMPUTE:
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_RUN_TO_COMPLETION_JOB:
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_OBJECT_STORE:
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_DATASTORE:
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_QUEUE:
        out.append(node.logical_id.copy())
        if node.queue:
            out.append(node.queue.value().name.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_LOAD_BALANCER:
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_DNS_RECORD:
        out.append(node.logical_id.copy())
        if node.dns_record:
            out.append(node.dns_record.value().record_name.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_IAM_ROLE:
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_SECRET:
        out.append(node.logical_id.copy())
        if node.secret:
            out.append(node.secret.value().handle.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_CONFIG:
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT:
        out.append(node.logical_id.copy())
        if node.service_account:
            out.append(node.service_account.value().account_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_WIF_PROVIDER:
        out.append(node.logical_id.copy())
        if node.wif_provider:
            out.append(node.wif_provider.value().pool_id.copy())
            out.append(node.wif_provider.value().provider_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_BUCKET:
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_ARTIFACT_REPOSITORY:
        out.append(node.logical_id.copy())
        if node.artifact_repository:
            out.append(node.artifact_repository.value().repository.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_TRIGGER:
        out.append(node.logical_id.copy())
        if node.trigger:
            out.append(node.trigger.value().name.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_WEB_FRONTEND:
        out.append(node.logical_id.copy())
        if node.web_frontend:
            out.append(node.web_frontend.value().web_slug.copy())
            out.append(node.web_frontend.value().domain.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_API_EDGE:
        # The gateway/API pair is named for the edge node itself.
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_PROJECT_SERVICE:
        # kind 20 carries NO oneof arm: the logical id IS the API service name.
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_SCHEDULED_CALL:
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_NETWORK:
        # THE ADOPT ARM CREATES NOTHING, AND CONFLATING THE TWO WOULD BE THE
        # WORST POSSIBLE ANSWER HERE. With `adopt_existing_id` NON-EMPTY the
        # conformer manages subnets INSIDE a VPC somebody else owns; claiming
        # that VPC as an identity this graph brought into existence is exactly
        # how one app's teardown reaps a network every other app is placed in.
        # The account's default VPC is the live instance of that case.
        if node.network:
            if node.network.value().adopt_existing_id.byte_length() > 0:
                return out^
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_INGRESS_POLICY:
        # One security group / firewall rule, named for the policy node itself.
        # NOT `backend_logical_id` and NOT `network_logical_id` — both name
        # resources OTHER nodes create, and listing them here would make this
        # graph claim ownership of the workload it protects and of the network
        # it sits in.
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_IAM_CUSTOM_ROLE:
        # kind 27 carries NO oneof arm: the logical id IS the custom-role id.
        #
        # AND IT DOES BRING THAT IDENTITY INTO EXISTENCE, WHICH IS EXACTLY WHAT
        # THIS GUARD IS FOR. A custom role is PROJECT-scoped and one
        # `projects/<P>/roles/<id>` may be held by several principals in several
        # bundles — so one app's teardown reaping a resource every other app
        # depends on is a LIVE hazard here. It is contained by the node being
        # RETAIN_KEEP rather than by this list being empty: claiming the
        # identity is what lets a `--delete-data` teardown be REFUSED by name
        # instead of proceeding silently.
        out.append(node.logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_INVOKE_GRANT:
        return out^  # binds; creates nothing
    elif k == ResourceKind.RESOURCE_KIND_GRANT:
        return out^  # binds; creates nothing
    raise Error(
        String("shared_resource_guard: ResourceKind ordinal ")
        + String(k)
        + String(
            " has no case in `_node_created_identities` — a new resource kind must"
            " state WHICH of its names it brings into existence before it can"
            " appear in a graph anything deletes. Refusing rather than answering"
            " 'creates nothing': a kind this guard cannot see is a kind whose"
            " resource one app's teardown can reap out from under every other app,"
            " which is the hazard this module exists for."
        )
    )


def created_identities(manifest: FullManifest) raises -> List[String]:
    """Every cloud-resource identity `manifest`'s graph brings into existence.
    The OWNERSHIP set: anything NOT in here is somebody else's."""
    var out = List[String]()
    for i in range(len(manifest.nodes)):
        for ref n in _node_created_identities(manifest.nodes[i]):
            out.append(n.copy())
    return out^


def _contains(haystack: List[String], needle: String) -> Bool:
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False


# =============================================================================
# §3 — what a node's DELETE would touch, and whether the graph owns it.
# =============================================================================


def _grant_ends(node: ResourceNode) raises -> List[String]:
    """`[target, principal]` for a grant kind; EMPTY for anything else.

    Two entries, in that order, because the caller reports the target as the
    RESOURCE and the principal as the MEMBER — see this module's header on why
    both ends are consulted and `run_scope` consults only one."""
    var out = List[String]()
    var k = node.kind.value
    if k == ResourceKind.RESOURCE_KIND_INVOKE_GRANT:
        if node.invoke_grant:
            out.append(node.invoke_grant.value().target_service_logical_id.copy())
            # `member_identity_ref`, not `principal_identity_ref` — the two
            # messages spell the same concept differently (`GrantSpec` is the
            # superset; `InvokeGrantSpec` predates it).
            out.append(node.invoke_grant.value().member_identity_ref.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_GRANT:
        if node.grant:
            out.append(node.grant.value().target_resource_logical_id.copy())
            out.append(node.grant.value().principal_identity_ref.copy())
        return out^
    return out^


def _would_be_reaped(node: ResourceNode, force_delete_data: Bool) -> Bool:
    """Whether the destroy reverse walk would actually DELETE this node.

    `RETENTION_RETAIN_KEEP` is skipped — UNLESS `force_delete_data` is in force,
    which is precisely `--delete-data` and `--run-id` (`run_scope_lifts_retention`
    routes a run scope through the SAME switch). That lift is the whole reason
    this guard exists beside the retention rather than instead of it."""
    if node.retention.value == Retention.RETENTION_RETAIN_KEEP:
        return force_delete_data
    return True


struct SiblingGraph(Copyable, Movable, Deinitable):
    """One OTHER checked-in release machine, as this guard needs to see it: its
    bundle name plus the identities its graph creates and the resources its graph
    binds. `unreadable` is non-empty when the bundle could not be parsed or
    composed — "I could not read that bundle" and "that bundle depends on
    nothing" must not be the same answer, because the second one licenses a
    delete."""

    var name: String
    var identities: List[String]
    var bound: List[String]
    var unreadable: String

    def __init__(
        out self,
        var name: String,
        var identities: List[String],
        var bound: List[String],
        var unreadable: String,
    ):
        self.name = name^
        self.identities = identities^
        self.bound = bound^
        self.unreadable = unreadable^


def sibling_graph_of(
    name: String, manifest: FullManifest
) raises -> SiblingGraph:
    """Project a sibling's composed manifest down to the two lists this guard
    compares against. Pure; the IO shell does the parse + compose."""
    var bound = List[String]()
    for i in range(len(manifest.nodes)):
        var ends = _grant_ends(manifest.nodes[i])
        if len(ends) == 2:
            bound.append(ends[0].copy())
    return SiblingGraph(
        name.copy(), created_identities(manifest), bound^, String("")
    )


def unreadable_sibling(name: String, why: String) -> SiblingGraph:
    """A sibling whose bundle this guard could not read. Kept as a first-class
    value rather than dropped — see `SiblingGraph.unreadable`."""
    return SiblingGraph(
        name.copy(), List[String](), List[String](), why.copy()
    )


def _exclusively_owned(
    manifest: FullManifest, siblings: List[SiblingGraph]
) raises -> List[String]:
    """The identities this graph creates that NO sibling's graph creates.

    THE `AND NO SIBLING` HALF IS THE WHOLE FIX. Asking only "does this graph
    create it?" answers YES for the shared gateway SA — every edge-bearing graph
    does — and that answer is exactly how a guard misses the hazard it exists
    for."""
    var owned = created_identities(manifest)
    var out = List[String]()
    for i in range(len(owned)):
        if owned[i].byte_length() == 0:
            # The EMPTY identity is the project itself. Nothing owns the project.
            continue
        var shared = False
        for si in range(len(siblings)):
            if _contains(siblings[si].identities, owned[i]):
                shared = True
                break
        if not shared:
            out.append(owned[i].copy())
    return out^


def shared_resource_findings(
    manifest: FullManifest,
    siblings: List[SiblingGraph],
    force_delete_data: Bool = False,
) raises -> List[SharedResourceFinding]:
    """THE SWEEP. Every node in `manifest` whose `delete` would remove something
    this graph does not EXCLUSIVELY own — i.e. the teardown-hazard inventory.

    Returns the FULL inventory, `reaped=False` rows included, because the
    inventory is the useful artifact for a human ("what in my app's graph is
    project-global?") while only the `reaped=True` rows can become a refusal. A
    caller that wants the hazard set filters on `.reaped`.

    With an EMPTY `siblings` list every created identity is exclusive, so only
    nodes addressing something this graph does not create at all are reported.
    That is the correct reading for the last machine out of an environment."""
    var mine = _exclusively_owned(manifest, siblings)
    var out = List[SharedResourceFinding]()
    for i in range(len(manifest.nodes)):
        ref node = manifest.nodes[i]
        var ends = _grant_ends(node)
        if len(ends) == 2:
            # A BINDING. Ours iff EITHER end is EXCLUSIVELY ours (see the header).
            var target = ends[0].copy()
            var principal = ends[1].copy()
            if _contains(mine, target) or _contains(mine, principal):
                continue
            out.append(
                SharedResourceFinding(
                    node.logical_id.copy(),
                    node.kind.value,
                    target^,
                    principal^,
                    _would_be_reaped(node, force_delete_data),
                )
            )
            continue
        # A CREATE node. Ours iff its identities are EXCLUSIVELY ours. A node with
        # no created identity at all (neither create nor grant) addresses only
        # itself and is not reported.
        var ids = _node_created_identities(node)
        if len(ids) == 0:
            continue
        var exclusive = False
        for j in range(len(ids)):
            if _contains(mine, ids[j]):
                exclusive = True
                break
        if not exclusive:
            # Report the most SPECIFIC identity — the cloud name, not the logical
            # id — when the node carries one, so the message names what an
            # operator would see in the console.
            var label = ids[len(ids) - 1].copy()
            out.append(
                SharedResourceFinding(
                    node.logical_id.copy(),
                    node.kind.value,
                    label^,
                    String(""),
                    _would_be_reaped(node, force_delete_data),
                )
            )
    return out^


# =============================================================================
# §4 — the REFUSAL. "naming both" is the requirement, so a sibling that also
#      addresses the resource is named, and an UNREADABLE sibling is named too.
# =============================================================================


def _dependents_of(
    resource: String, siblings: List[SiblingGraph]
) -> List[String]:
    """The names of the siblings whose graph CREATES or BINDS `resource`.

    An EMPTY `resource` — a project-scoped IAM binding — matches every sibling
    that binds project scope, which is the correct reading: `projects/<P>` is one
    policy and every project-scoped grant in the environment shares it."""
    var out = List[String]()
    for si in range(len(siblings)):
        ref s = siblings[si]
        if s.unreadable.byte_length() > 0:
            continue
        if _contains(s.identities, resource) or _contains(s.bound, resource):
            out.append(s.name.copy())
    return out^


def shared_resource_refusal(
    bundle_name: String,
    manifest: FullManifest,
    siblings: List[SiblingGraph],
    force_delete_data: Bool = False,
) raises -> String:
    """THE REFUSAL, or the EMPTY string when the teardown is entirely this
    graph's to perform.

    Refuses when the reverse walk would reach a node addressing a resource this
    graph does not create AND at least one other checked-in bundle addresses that
    same resource — naming the node, the resource, and the sibling(s), which is
    the "naming both" requirement.

    ALSO refuses when a sibling is UNREADABLE — but only where that ignorance can
    change the outcome, which is exactly under the retention lift:

      1. compute the REACHED foreign findings over the READABLE siblings;
      2. any reached ⇒ REFUSE (naming the resource + who depends on it, or naming
         the unreadable bundles if the "who" cannot be established);
      3. none reached, but `force_delete_data` is in force AND some sibling is
         unreadable ⇒ REFUSE. Under the lift EVERY node is reachable, including
         the RETAIN_KEEP ones, and exclusivity is a CROSS-GRAPH fact — a bundle
         this guard could not compose might be the one that also creates the
         resource, and its absence from `siblings` makes that resource look
         exclusively ours. So "nothing reached" is not a finding here, it is an
         artifact of the missing bundle.
      4. none reached, no lift ⇒ ALLOW. Without the lift the shared nodes are
         RETAIN_KEEP and the destroy walk skips them REGARDLESS of what any
         sibling declares, so sibling readability cannot change the outcome.

    WHY (4) EXISTS — an unconditional unreadable-sibling refusal BLOCKS THE
    THING IT EXISTS TO PROTECT. One unparseable bundle anywhere in the corpus
    would make EVERY `kci delete` refuse, over a bundle with no relationship to
    the resource being reaped. A guard that blocks the operation it was written
    to make safe gets deleted, and then nothing guards anything.

    AND WHY (3) EXISTS — returning early on "nothing reached" alone is
    FAIL-OPEN: an unreadable sibling contributes no identities, so
    `_exclusively_owned` would conclude the shared gateway SA is exclusively
    ours and report nothing to reach. Ignorance read as safety. (3) is the
    narrowest correction that closes it: distrust the emptiness exactly when the
    lift makes every node reachable.

    IT REFUSES; IT DOES NOT SKIP. One reachable shared resource refuses the
    WHOLE teardown, for `run_scope_violations`' reason: a teardown that silently
    skips a node is a teardown that leaks invisibly. The operator's next move is
    to delete the dependent app first, or — if the intent really is to reap the
    whole environment — to remove the sibling bundles that still declare it."""
    # ── (1) WHAT IS ACTUALLY BEING REAPED THAT IS NOT OURS ──────────────────
    var reached = List[SharedResourceFinding]()
    for ref f in shared_resource_findings(manifest, siblings, force_delete_data):
        if f.reaped:
            reached.append(f.copy())
    var broken = List[String]()
    for si in range(len(siblings)):
        if siblings[si].unreadable.byte_length() > 0:
            broken.append(
                siblings[si].name + String(" (") + siblings[si].unreadable
                + String(")")
            )
    # ── (4) NOTHING REACHED AND NO LIFT ⇒ ALLOW, whatever the corpus says. ──
    #     RETAIN_KEEP skips the shared nodes regardless of any sibling, so an
    #     unreadable bundle cannot change this outcome. This is the arm that
    #     keeps an ordinary teardown unblocked.
    if len(reached) == 0 and not force_delete_data:
        return String("")
    # ── (2)+(3) EITHER something foreign is reached, OR the lift is on and the
    #     corpus is incomplete. Both make an unreadable sibling disqualifying.
    if len(broken) > 0:
        var b = String("")
        for i in range(len(broken)):
            if i > 0:
                b += String(", ")
            b += broken[i]
        return (
            String("kci delete '")
            + bundle_name
            + String(
                "': REFUSED — under the RETAIN_KEEP lift (`--delete-retained` /"
                " `--run-id`) EVERY node is reachable, including the"
                " project-global ones, and the guard could not read every other"
                " release machine to establish which resources are exclusively"
                " this app's. "
            )
            + String(len(reached))
            + String(" foreign resource(s) already reached; unreadable: ")
            + b
            + String(
                ". 'I could not read that bundle' and 'no bundle depends on this'"
                " must not be the same answer when the second one licenses a"
                " delete. Fix the unreadable bundle(s) and re-run."
            )
        )

    # Under the lift with a fully-readable corpus and nothing reached, there is
    # genuinely nothing to say.
    if len(reached) == 0:
        return String("")

    var lines = List[String]()
    for ref f in reached:
        var deps = _dependents_of(f.resource, siblings)
        if len(deps) == 0:
            continue
        var who = String("")
        for i in range(len(deps)):
            if i > 0:
                who += String(", ")
            who += deps[i]
        var line = String("  node '") + f.logical_id + String("' would remove ")
        if f.principal.byte_length() > 0:
            line += (
                String("the IAM binding [")
                + f.principal
                + String(" -> ")
                + finding_resource_label(f)
                + String("]")
            )
        else:
            line += String("the resource '") + finding_resource_label(f) + String("'")
        line += (
            String(" — which '")
            + bundle_name
            + String("' does not create, and which these other release machines"
                     " depend on: ")
            + who
        )
        lines.append(line^)

    if len(lines) == 0:
        return String("")

    var body = String("")
    for i in range(len(lines)):
        body += String("\n") + lines[i]
    return (
        String("kci delete '")
        + bundle_name
        + String("': REFUSED — the reverse walk would remove ")
        + String(len(lines))
        + String(
            " resource(s) this app's graph does not own but other live apps"
            " depend on:"
        )
        + body
        + String(
            "\n\nA resource N graphs CREATE and 1 graph DELETES is owned by"
            " none of them: deleting it breaks every other app that composes"
            " it.\n"
            "  * If you meant to tear down one app: those nodes are"
            " RETENTION_RETAIN_KEEP for exactly this reason — drop"
            " `--delete-retained` (and `--run-id`, which lifts the same skip) and the"
            " teardown will skip them.\n"
            "  * If you meant to reap the whole environment: delete the dependent"
            " machines first, or remove their bundles. The last one out may take"
            " the shared resource with it; the first one may not."
        )
    )
