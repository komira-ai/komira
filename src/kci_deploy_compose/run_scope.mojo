"""`run_scope` — RUN-SCOPED LIFECYCLE: the pure capability behind.

`kci deploy --run-id <id>` / `kci delete --run-id <id>` (`AppBundle.ephemeral`).

WHY THE SCOPING HAS TO BE STRUCTURAL
====================================

A shell that hand-builds run-scoped names and then hand-deletes exactly those
names is the alternative, and its delete half is the dangerous half:
`gcloud run services delete` UN-SHIPS A RUNNING REVISION, and the only thing
standing between that verb and a standing service is a shell variable being
interpolated into the right string. A teardown that can reach a NON-run-scoped
resource is a strictly worse bug than leaking one.

So run-scoping here is NOT a naming convention applied by the caller. It is two
functions that cannot be separated in practice:

  1. `scope_bundle`   — rewrites the authored intent so that EVERY name the
                        composition derives carries the run token. Every logical
                        id in `compose_api` is derived from `ServiceSpec.name`
                        (`<name>-role` / `-secret` / `-config` / `-datastore` /
                        `-svc`), so renaming at the intent tier scopes the whole
                        graph by construction rather than by enumeration.
  2. `run_scope_violations` — walks the COMPOSED manifest and reports every
                        cloud-addressable name that does NOT carry the token.
                        TOTAL over `ResourceKind` and FAIL-CLOSED on a kind it
                        does not know.

`compose_run_scoped` fuses them: it is the ONLY way to obtain a run-scoped
manifest, and it RAISES on any violation. That is what makes the scoping
structural instead of conventional — the guard cannot be skipped by a caller
that forgot it, because there is no unguarded path to the value.

(2) IS THE ONE THAT CATCHES REAL BUGS. `compose_api` emits nodes whose names
are CONSTANTS, not derived from the service name — the shared API-Gateway
backend-auth service account (`EDGE_GATEWAY_SA_ACCOUNT_ID`), say. Those name
resources a run does not own. Under a run scope the reverse walk would DELETE
them, taking out every standing deployment that shares them. The violation
check refuses the whole graph rather than reaping a shared resource, and
`test_run_scope.mojo` pins that refusal.

WHAT IS DELIBERATELY NOT HERE
=============================

* NO new verb. `kci delete` (`VERB_DELETE`) already walks the graph in reverse
  honouring per-node `Retention`, and `--delete-data` (`force_delete_data`) is
  already the switch that lifts the `RETAIN_KEEP` skip. A run scope IMPLIES
  that lift (see `run_scope_lifts_retention`) — it does not grow a second
  mechanism beside it.
* NO `verify_teardown` affordance, and there must never be one. The leak
  detection that proves a teardown deleted everything MUST read the cloud's own
  list API, never kci's bookkeeping — a teardown that asks its own ledger
  whether it deleted everything reports clean precisely when it is wrong (see
  `EphemeralScope`'s own comment in `app_bundle.proto`).

Pure + deterministic, like every other module in this package: value transforms
over proto values, no I/O, no clock, no randomness. The run id is MINTED by the
caller (a shell `mint_run_id`, a CI job id) and only ever VALIDATED here.
"""

from kci_manifest_proto.full_manifest import (
    FullManifest,
    ResourceKind,
    ResourceNode,
)
from kci_bundle_proto.app_bundle import (
    AppBundle,
    AppKind,
    AppSpec,
)

from kci_deploy_compose.compose_api import compose_api


# =============================================================================
# §1 — the token, and the shape of a run id.
# =============================================================================

# The infix that marks a name as belonging to one run.
#
# WHY AN INFIX WITH ITS OWN WORD IN IT, AND NOT A BARE `-<run_id>` SUFFIX.
# A bare suffix makes `carries()` a guess: `app-a-abc123` might be a scoped
# `app-a` or it might be a standing service somebody named that way. The
# literal `-run-` costs five bytes and turns the predicate into a fact. It is
# ALSO what a leak detector greps for: `--filter="name~-run-<id>$"` over the
# cloud's own list API finds every survivor of one run and NOTHING else, which
# is the assertion a conformance check must keep making from OUTSIDE this tool.
comptime RUN_SCOPE_INFIX: String = "-run-"

# The run id's own shape. Bounds are NOT arbitrary — see `validate_run_id`.
comptime RUN_ID_MIN_LEN: Int = 4
comptime RUN_ID_MAX_LEN: Int = 12

# ─── THE TWO CLOUD LENGTH BOUNDS, CHECKED OFFLINE ────────────────────────────
#
# The alternative is to hand-shorten every name and keep the arithmetic
# ("<=30 chars: prefix + run_id") in a comment, which is a constraint living in
# a comment instead of in a check.
#
# THEY ARE TWO BOUNDS, NOT ONE, AND CONFLATING THEM REFUSES VALID GRAPHS. A
# GCP service-account `account_id` caps at 30; a Cloud Run service name, a GCS
# bucket name and a Secret Manager handle cap at 63. Applying 30 to everything
# would reject an ordinary two-service bundle, because a cross-service GRANT
# node's logical id is `<caller>-invokes-<callee>` — 44 bytes with both names
# scoped, and not a service account at all.
comptime SA_ACCOUNT_ID_MAX: Int = 30
comptime RESOURCE_NAME_MAX: Int = 63


def validate_run_id(run_id: String) -> String:
    """The run id's shape, as a REASON string — empty means valid.

    Not a style rule. Each clause is a cloud constraint that would otherwise
    surface as an opaque 400 from a create call, halfway through a graph, with
    some resources already standing:

      * NON-EMPTY, 4..12 bytes — the id is APPENDED to every composed name, and
        `SA_ACCOUNT_ID_MAX` leaves ~13 bytes of headroom over a typical app
        symbol. Below 4 the collision surface across concurrent runs stops being
        a rounding error.
      * `[a-z0-9]` only — Cloud Run service names, GCS bucket names and IAM
        `account_id`s are all lowercase-alphanumeric-and-hyphen. An UPPERCASE or
        `_` id is rejected by the cloud, not by us, and much later.
      * FIRST BYTE `[a-z]` — a service-account `account_id` may not start with a
        digit, and the id is the tail of a name only when the app symbol is
        empty; keeping the rule unconditional means one rule instead of a
        per-kind one.
    """
    var b = run_id.as_bytes()
    if len(b) == 0:
        return String(
            "run id is empty — `--run-id` names WHICH throwaway run's resources"
            " this command may create or destroy, and an empty one would scope"
            " nothing"
        )
    if len(b) < RUN_ID_MIN_LEN:
        return (
            String("run id '")
            + run_id
            + String("' is shorter than ")
            + String(RUN_ID_MIN_LEN)
            + String(
                " bytes — too short to keep two concurrent runs from colliding"
                " on one name"
            )
        )
    if len(b) > RUN_ID_MAX_LEN:
        return (
            String("run id '")
            + run_id
            + String("' is longer than ")
            + String(RUN_ID_MAX_LEN)
            + String(
                " bytes — it is appended to EVERY composed name, and a GCP"
                " service-account account_id caps at "
            )
            + String(SA_ACCOUNT_ID_MAX)
        )
    var first = b[0]
    if not (first >= UInt8(ord("a")) and first <= UInt8(ord("z"))):
        return (
            String("run id '")
            + run_id
            + String(
                "' must start with a lowercase letter — a GCP service-account"
                " account_id may not begin with a digit or a hyphen"
            )
        )
    for i in range(len(b)):
        var c = b[i]
        var ok = (c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or (
            c >= UInt8(ord("0")) and c <= UInt8(ord("9"))
        )
        if not ok:
            return (
                String("run id '")
                + run_id
                + String(
                    "' must be lowercase [a-z0-9] only — Cloud Run service"
                    " names, GCS bucket names and IAM account ids admit no"
                    " other characters"
                )
            )
    return String("")


struct RunScope(Copyable, Movable, Deinitable):
    """One throwaway run's identity, as a value.

    Constructed ONLY through `RunScope.of`, which refuses a malformed id — so a
    `RunScope` in hand is a run id that has already passed `validate_run_id`.
    """

    var run_id: String

    def __init__(out self, var run_id: String):
        self.run_id = run_id^

    @staticmethod
    def of(run_id: String) raises -> RunScope:
        """A validated `RunScope`, or a fail-loud raise naming the defect."""
        var why = validate_run_id(run_id)
        if why.byte_length() > 0:
            raise Error(String("kci: --run-id: ") + why)
        return RunScope(run_id.copy())

    def token(self) -> String:
        """The literal every run-scoped name ends with: `-run-<id>`."""
        return String(RUN_SCOPE_INFIX) + self.run_id

    def carries(self, name: String) -> Bool:
        """Does `name` belong to THIS run?

        A SUBSTRING test, and that is not laziness — it is why the token is an
        INFIX. `compose_api` appends its own role suffixes AFTER the service
        name (`<name>-role`, `-secret`, `-config`, `-svc`), so a scoped service
        `canary-run-conf7x9q` yields the node id `canary-run-conf7x9q-svc`,
        which does NOT end with the token, so an `endswith` test would reject
        every composed node.

        It is still a FACT rather than a heuristic, because the token carries
        its own word: `-run-<id>` cannot be arrived at by accident the way a
        bare `-<id>` suffix can. It is also EXACTLY the string a leak detector
        greps the cloud's own list API for.

        BUT THE SUBSTRING TEST MUST BE RIGHT-BOUNDED.
        ---------------------------------------------
        A bare `__contains__` defends against an unrelated name colliding with
        a bare `-<id>` suffix, but NOT against ONE RUN ID BEING A PREFIX OF
        ANOTHER. Run ids are VARIABLE-LENGTH (`RUN_ID_MIN_LEN` 4 ..
        `RUN_ID_MAX_LEN` 12), so `abc1` and `abc12` are both legal, and

            "canary-run-abc12-svc".__contains__("-run-abc1")   ==   True

        would make run `abc1` claim run `abc12`'s entire graph. That is not
        cosmetic: `run_scope_violations` is the guard `kci delete --run-id`
        consults before it deletes ANYTHING, and its contract is "EMPTY means
        the graph is entirely this run's". Under the collision it would return
        EMPTY for another run's graph, and the reverse walk would then delete
        it.

        Nothing can refuse the colliding id at mint time: ids are minted by
        callers (a shell `mint_run_id`, a CI job id) that cannot see each
        other's. So the PREDICATE has to be correct, not the id space.

        THE RULE: a match counts only if the byte after the token is not a run
        id byte (`[a-z0-9]`), or the token ends the name. `-run-abc1` inside
        `-run-abc12` is followed by `2` and is rejected; inside
        `canary-run-abc1-svc` it is followed by `-` and is accepted, which is
        what keeps the `compose_api` suffixes (`-svc`, `-role`, `-secret`,
        `-config`) working — the reason an `endswith` test is not the fix.
        ALL occurrences are scanned, so a rejected one cannot mask a later
        genuine match.

        The LEFT side needs no boundary: the token begins with the literal
        `-run-`, so a longer id cannot end where a shorter one does.

        This agrees with the leak-detector recipe this module's own header
        documents (`--filter="name~-run-<id>$"`, anchored): the in-tool
        predicate and the out-of-tool assertion must not disagree, and an
        unanchored predicate would be the side that deletes.

        Falsifier: `tests/test_run_scope_id_prefix_collision.mojo`.
        """
        var t = self.token().as_bytes()
        var n = name.as_bytes()
        var tl = len(t)
        var nl = len(n)
        if tl == 0 or nl < tl:
            return False
        for at in range(nl - tl + 1):
            var hit = True
            for k in range(tl):
                if n[at + k] != t[k]:
                    hit = False
                    break
            if not hit:
                continue
            var end = at + tl
            # The token runs to the end of the name — an unextendable match.
            if end == nl:
                return True
            # Otherwise the next byte must not be one a run id could have
            # continued with, or this is a LONGER id that merely starts with
            # ours.
            var c = n[end]
            var continues_the_id = (
                c >= UInt8(ord("a")) and c <= UInt8(ord("z"))
            ) or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            if not continues_the_id:
                return True
        return False

    def scoped(self, name: String) -> String:
        """`name` bound to this run. IDEMPOTENT: scoping an already-scoped name
        returns it unchanged, so a double application (a bundle that is scoped
        and then handed to a path that scopes again) cannot produce
        `x-run-a-run-a` — which would be a name no teardown ever built and no
        leak detector ever finds."""
        if self.carries(name):
            return name.copy()
        return name + self.token()


def scoped_name_length_error(name: String, bound: Int, what: String) -> String:
    """A REASON string (empty = fine) if a run-scoped `name` exceeds `bound`.

    Checked OFFLINE at compose time, on purpose: the alternative is discovering
    it as a 400 from the cloud, mid-apply, with half the graph already standing
    and a teardown that now has to reap a partial graph. `what` names the cloud
    constraint so the message says which bound and why, not just "too long".
    """
    if name.byte_length() > bound:
        return (
            String("run-scoped name '")
            + name
            + String("' is ")
            + String(name.byte_length())
            + String(" bytes, over the ")
            + String(bound)
            + String("-byte ")
            + what
            + String(
                " bound — shorten the app or service symbol, or the run id"
            )
        )
    return String("")


# =============================================================================
# §2 — the CLI POLICY, as pure functions (the biconditional).
# =============================================================================


def run_scope_permission_error(
    bundle_name: String, has_ephemeral: Bool, run_id: String
) -> String:
    """The `ephemeral {}` ⇔ `--run-id` BICONDITIONAL, as a reason string, empty
    when permitted. BOTH directions are load-bearing and neither is obvious:

    * `--run-id` WITHOUT `ephemeral {}` ⇒ REFUSED. This is the direction the
      proto comment argues: a production bundle that silently accepted a run id
      would stand up a parallel copy of a live service under a name its
      registry, its DNS and its callers know nothing about. Presence is a
      PERMISSION the bundle grants.

    * `ephemeral {}` WITHOUT `--run-id` ⇒ ALSO REFUSED, and this direction is
      the one that prevents a permanent leak. A throwaway bundle deployed with
      no run id composes UNSCOPED names — and `delete --run-id <x>` can then
      never reach them, because they carry no token. The resources would
      outlive every teardown that was written to remove them. Presence is
      therefore an OBLIGATION as well as a permission.

    Pure: the caller supplies both halves, so this is testable without a file,
    a cloud, or a CLI.
    """
    var have_id = run_id.byte_length() > 0
    if have_id and not has_ephemeral:
        return (
            String("bundle '")
            + bundle_name
            + String(
                "' declares no `ephemeral {}` block, so `--run-id` is REFUSED."
                " A run id renames every resource this bundle composes;"
                " accepting one here would stand up a parallel copy of a"
                " STANDING deployment under a name its service registry, its"
                " DNS and its callers know nothing about. Add `ephemeral {"
                " keep_overridden_because: \"<why a run-scoped teardown may"
                " ignore RETAIN_KEEP>\" }` to opt this bundle in."
            )
        )
    if has_ephemeral and not have_id:
        return (
            String("bundle '")
            + bundle_name
            + String(
                "' declares `ephemeral {}` — it may ONLY be deployed and"
                " destroyed under a run scope, so `--run-id <id>` is REQUIRED."
                " Without one this composes UNSCOPED names that no `delete"
                " --run-id` can ever reach: the resources would outlive every"
                " teardown written to remove them."
            )
        )
    return String("")


def run_scope_lifts_retention(run_id: String, delete_data: Bool) -> Bool:
    """Whether a destroy must lift the `RETAIN_KEEP` skip.

    TRUE under a run scope, and that is the whole reason `EphemeralScope`
    requires `keep_overridden_because` to be non-empty. `RETAIN_KEEP` exists to
    stop a stray destroy from nuking a bucket that holds data. For a run-scoped
    graph there is no such data — THE BUCKET IS THE RUN — and leaving it
    standing is the cost leak a run-scoped teardown exists to prevent.

    Expressed as the EXISTING `force_delete_data` switch rather than a second
    mechanism: `kci delete --delete-data` already lifts the skip, and a run
    scope is simply another reason to. One code path in the destroy walk, two
    reasons to take it.
    """
    return delete_data or run_id.byte_length() > 0


# =============================================================================
# §3 — scope_bundle: rewrite the authored intent.
# =============================================================================


def _scope_app_spec(
    mut spec: AppSpec, scope: RunScope, where: String, mut errs: List[String]
):
    """Rewrite the name-bearing fields of ONE `AppSpec` in place, and RECORD
    (never silently drop) every authored field that names something a run cannot
    own. `where` is the human label used in a refusal."""

    # -- a SELF-PROVISIONED runtime identity ---------------------------------
    #    An authored `runtime_identity` makes `_append_runtime_sa_nodes` compose
    #    a SERVICE_ACCOUNT node whose `account_id` IS that string — a service
    #    account this graph CREATES, and therefore one a reverse walk DELETES.
    #    Left unscoped, a run-scoped teardown would delete a shared runtime SA.
    #    `_runtime_identity_of` is explicit that this same string is the SA
    #    created, the identity the compute runs AS, and every grant's principal
    #    — so scoping it here scopes all three at once.
    if spec.runtime_identity.byte_length() > 0:
        spec.runtime_identity = scope.scoped(spec.runtime_identity)

    # -- app-owned buckets: the bucket NAME is the node's own logical id -------
    for bi in range(len(spec.buckets)):
        spec.buckets[bi].name = scope.scoped(spec.buckets[bi].name)

    # -- the app's OWN datastore database ------------------------------------
    #    NOT a manifest field: the database id is threaded to the mapper as
    #    `datastore_database=`, so §4's manifest verifier CANNOT see it. It is
    #    scoped HERE. Two runs sharing one datastore database would interleave
    #    writes and each would see the other's rows.
    if spec.datastore_database.byte_length() > 0:
        spec.datastore_database = scope.scoped(spec.datastore_database)

    # -- the REFERENCED database: refused, not scoped -------------------------
    if spec.datastore_database_ref.byte_length() > 0:
        errs.append(
            where
            + String(
                " authors `datastore_database_ref` — a throwaway run may not"
                " write into a database another release machine OWNS. The"
                " reference names a standing resource by definition, so"
                " scoping it would silently point at a database that does not"
                " exist, and NOT scoping it would let a run write into"
                " production data."
            )
        )

    # -- the static-website front door: refused, not scoped -------------------
    #    A web slug, a domain and its certificate are not run-scopable things: a
    #    domain is delegated, a managed certificate takes minutes to provision
    #    and is validated against DNS. A run that could create them could also
    #    reap them.
    if spec.web_slug.byte_length() > 0:
        errs.append(
            where
            + String(
                " authors `web_slug` — a static-website front door is not"
                " run-scopable (a slug addresses a standing published site)."
            )
        )
    if spec.web_domain.byte_length() > 0 or (
        spec.web_additional_domains.byte_length() > 0
    ):
        errs.append(
            where
            + String(
                " authors a web domain — a DOMAIN and its managed certificate"
                " are delegated, DNS-validated, standing resources. A run that"
                " could create one could also REAP one."
            )
        )

    # -- inbound routes that ride the SHARED gateway --------------------------
    if len(spec.secured_inbound_routes) > 0:
        errs.append(
            where
            + String(
                " authors `secured_inbound_routes` — these ride the SHARED"
                " API-Gateway backend-auth service account, which no single"
                " run owns. See the §4 violation check, which refuses the"
                " composed graph for the same reason."
            )
        )


def _scope_service_refs(
    mut spec: AppSpec, scope: RunScope, service_names: List[String]
):
    """Rewrite every `ServiceRef` env arm that names one of THIS bundle's
    services, in lockstep with the rename those services just took.

    THE LOCKSTEP IS THE POINT. `compose_api` resolves a `service_ref` by
    matching the referenced name against the auto-lifted service list and
    fail-fasts on a miss. Rename the services and not their references and every
    cross-service reference becomes a compose error; rename the references and
    not the services and the graph silently loses its invoke grants.

    The membership test is against the ALREADY-SCOPED service list, and `scoped`
    is idempotent, so a ref that has been rewritten once is not rewritten again.
    A ref to a name that is NOT one of this bundle's services is left ALONE —
    `compose_api` will fail-fast on it exactly as it does today, which is a
    better outcome than inventing a scoped name for a service nobody declared.
    """
    for ei in range(len(spec.env)):
        if not spec.env[ei].service_ref:
            continue
        var target = spec.env[ei].service_ref.value().service.copy()
        var scoped_target = scope.scoped(target)
        for si in range(len(service_names)):
            if service_names[si] == scoped_target:
                spec.env[ei].service_ref.value().service = scoped_target.copy()
                break


def scope_bundle(bundle: AppBundle, scope: RunScope) raises -> AppBundle:
    """The authored bundle, rewritten so that EVERY name its composition derives
    belongs to `scope`.

    Scoping at the INTENT tier rather than at the manifest is the whole design.
    `_append_api_service_nodes` derives `<name>-role`, `<name>-secret`,
    `<name>-config`, `<name>-datastore` and `<name>-svc` from `ServiceSpec.name`
    — and the MAPPER recovers the service name by STRIPPING those suffixes
    (`_strip_suffix(logical_id, "-svc")`). A manifest-tier rename would have to
    inject the token BEFORE the role suffix on every id, in a place the mapper
    also had to agree about. Renaming the service is one edit that the existing
    derivation carries everywhere, and the §4 verifier proves it did.

    FAIL-CLOSED. Every authored field that names something a run cannot own is
    collected and raised TOGETHER (one round-trip for the author), never
    silently ignored and never guessed at.
    """
    var errs = List[String]()

    # -- the KIND gate --------------------------------------------------------
    # Only the API composition is run-scopable today. A STATIC_FRONTEND's whole
    # output is a domain + a certificate + a CDN-fronted bucket behind a global
    # load balancer, none of which a throwaway run should be able to create,
    # and therefore none of which it should be able to destroy. The other kinds
    # have no composition at all. Stated as a refusal rather than left to fail
    # somewhere downstream with a less useful message.
    if bundle.kind.value != AppKind.APP_KIND_API:
        raise Error(
            String("kci: --run-id: bundle '")
            + bundle.name
            + String("' is AppKind ordinal ")
            + String(bundle.kind.value)
            + String(
                " — only APP_KIND_API is run-scopable. A static-website front"
                " door is a domain, a managed certificate and a global load"
                " balancer; a run that could stand those up could also reap"
                " them."
            )
        )

    # -- standing CD bindings are not per-run --------------------------------
    if len(bundle.triggers) > 0:
        errs.append(
            String(
                "bundle authors `triggers` — a continuous-deployment trigger is"
                " a STANDING binding on a source repository, not a per-run"
                " resource. A run-scoped teardown would delete the app's"
                " deployment trigger."
            )
        )

    var out = bundle.copy()

    # -- the app symbol -------------------------------------------------------
    out.name = scope.scoped(out.name)

    # -- the singular spec (the AUTO-LIFT source when `services` is empty) ----
    if out.spec:
        _scope_app_spec(
            out.spec.value(),
            scope,
            String("bundle '") + bundle.name + String("' spec"),
            errs,
        )

    # -- the named services ---------------------------------------------------
    for si in range(len(out.services)):
        out.services[si].name = scope.scoped(out.services[si].name)
        if out.services[si].spec:
            _scope_app_spec(
                out.services[si].spec.value(),
                scope,
                String("bundle '")
                + bundle.name
                + String("' service '")
                + bundle.services[si].name
                + String("'"),
                errs,
            )

    # -- cross-service references, in lockstep with the renames above ---------
    var service_names = List[String]()
    if len(out.services) == 0:
        service_names.append(out.name.copy())
    else:
        for si in range(len(out.services)):
            service_names.append(out.services[si].name.copy())
    if out.spec:
        _scope_service_refs(out.spec.value(), scope, service_names)
    for si in range(len(out.services)):
        if out.services[si].spec:
            _scope_service_refs(out.services[si].spec.value(), scope, service_names)

    # -- THE PER-WAVE ENV-OVERRIDE SERVICE AXIS, in the SAME lockstep ----------
    #    `BundleEnvVar.service` on a `waves { env_override { … } }` entry names a
    #    service by its LOGICAL name, so it is a cross-service reference exactly
    #    like `service_ref` above and is renamed on the same rule: scope the name,
    #    keep it only if the scoped form is one of THIS bundle's services (an
    #    override naming something else is left alone — `_scope_service_refs`'s
    #    rule, for its reason).
    #
    #    WITHOUT THIS, A RUN-SCOPED MULTI-SERVICE DEPLOY REFUSES. The services
    #    are renamed `<name>-<run-id>` two blocks up; an override still naming
    #    `<name>` matches nothing and compose raises "names service '<name>',
    #    which this bundle does not declare".
    for wi in range(len(out.waves)):
        for oi in range(len(out.waves[wi].env_override)):
            var s = out.waves[wi].env_override[oi].service.copy()
            if s.byte_length() == 0:
                continue
            var ss = scope.scoped(s)
            for si in range(len(service_names)):
                if service_names[si] == ss:
                    out.waves[wi].env_override[oi].service = ss^
                    break

    # -- jobs + crons ---------------------------------------------------------
    #    Their NAMES are scoped here, so a job or cron composed into a
    #    run-scoped graph carries the token like every other node.
    for ji in range(len(out.jobs)):
        out.jobs[ji].name = scope.scoped(out.jobs[ji].name)
    for ci in range(len(out.crons)):
        out.crons[ci].name = scope.scoped(out.crons[ci].name)
        if out.crons[ci].target:
            var t = out.crons[ci].target.value().service.copy()
            var st = scope.scoped(t)
            for si in range(len(service_names)):
                if service_names[si] == st:
                    out.crons[ci].target.value().service = st.copy()
                    break

    if len(errs) > 0:
        var joined = String("")
        for i in range(len(errs)):
            if i > 0:
                joined += String("; ")
            joined += errs[i]
        raise Error(
            String("kci: --run-id: bundle '")
            + bundle.name
            + String("' cannot be run-scoped: ")
            + joined
        )
    return out^


# =============================================================================
# §4 — run_scope_violations: the guard that makes it structural.
# =============================================================================


def _node_addressed_names(node: ResourceNode) raises -> List[String]:
    """Every name on `node` that DESIGNATES A CLOUD RESOURCE THIS GRAPH WOULD
    CREATE OR MUTATE — and therefore that a reverse walk would DESTROY.

    TOTAL over `ResourceKind`, and it RAISES on an ordinal it does not know.
    That is the fail-closed property the whole capability rests on: a new
    `ResourceKind` added to `full_manifest.proto` without a case here makes
    every run-scoped compose REFUSE, naming the ordinal. The alternative — a
    default arm that returns "no names" — would make a new kind SILENTLY
    unscoped, i.e. reapable by a run that does not own it. That is the exact bug
    this module exists to prevent, so the default arm is the one thing that must
    not exist.

    ⚠ WHAT IS DELIBERATELY *NOT* COLLECTED: a PRINCIPAL. `GrantSpec.
    principal_identity_ref` names WHO is being authorized, not WHAT is being
    changed; granting a STANDING deploy identity a capability ON a run-scoped
    resource is correct and common. It is the TARGET that a reverse walk
    un-grants, so it is the target that must belong to the run.
    """
    var out = List[String]()
    # The logical id is a name in every case: for most kinds the mapper derives
    # the cloud resource name from it directly (a BUCKET node's logical id IS
    # the bucket name; a PROJECT_SERVICE node's IS the API service name).
    out.append(node.logical_id.copy())

    var k = node.kind.value
    if k == ResourceKind.RESOURCE_KIND_SERVERLESS_COMPUTE:
        return out^
    elif k == ResourceKind.RESOURCE_KIND_RUN_TO_COMPLETION_JOB:
        return out^
    elif k == ResourceKind.RESOURCE_KIND_OBJECT_STORE:
        return out^
    elif k == ResourceKind.RESOURCE_KIND_DATASTORE:
        return out^
    elif k == ResourceKind.RESOURCE_KIND_QUEUE:
        if node.queue:
            out.append(node.queue.value().name.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_LOAD_BALANCER:
        if node.load_balancer:
            out.append(node.load_balancer.value().backend_logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_DNS_RECORD:
        if node.dns_record:
            out.append(node.dns_record.value().record_name.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_IAM_ROLE:
        return out^
    elif k == ResourceKind.RESOURCE_KIND_SECRET:
        # The HANDLE is the Secret Manager secret this node creates + writes.
        if node.secret:
            out.append(node.secret.value().handle.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_CONFIG:
        return out^
    elif k == ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT:
        if node.service_account:
            out.append(node.service_account.value().account_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_WIF_PROVIDER:
        if node.wif_provider:
            out.append(node.wif_provider.value().pool_id.copy())
            out.append(node.wif_provider.value().provider_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_BUCKET:
        return out^
    elif k == ResourceKind.RESOURCE_KIND_ARTIFACT_REPOSITORY:
        if node.artifact_repository:
            out.append(node.artifact_repository.value().repository.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_TRIGGER:
        if node.trigger:
            out.append(node.trigger.value().name.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_INVOKE_GRANT:
        # The TARGET's IAM policy is what a reverse walk un-grants.
        if node.invoke_grant:
            out.append(
                node.invoke_grant.value().target_service_logical_id.copy()
            )
        return out^
    elif k == ResourceKind.RESOURCE_KIND_GRANT:
        if node.grant:
            out.append(node.grant.value().target_resource_logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_WEB_FRONTEND:
        if node.web_frontend:
            out.append(node.web_frontend.value().web_slug.copy())
            out.append(node.web_frontend.value().domain.copy())
            out.append(node.web_frontend.value().content_bucket.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_API_EDGE:
        if node.api_edge:
            out.append(node.api_edge.value().backend_logical_id.copy())
        return out^
    elif k == ResourceKind.RESOURCE_KIND_PROJECT_SERVICE:
        # kind 20 carries NO oneof arm: the logical id IS the API service name
        # (e.g. `run.googleapis.com`). Enumerated EXPLICITLY rather than left to
        # a default arm — see this function's header.
        return out^
    elif k == ResourceKind.RESOURCE_KIND_NETWORK:
        # ⛔ `adopt_existing_id` IS DELIBERATELY NOT COLLECTED. This list is
        # "names a reverse walk would DESTROY", and an adopted VPC is precisely
        # the resource a reverse walk must leave standing — the conformer's own
        # delete refuses it. Collecting it would make a run-scoped teardown
        # believe it owned the account's default network.
        return out^
    elif k == ResourceKind.RESOURCE_KIND_INGRESS_POLICY:
        # The security group / firewall rule is named for the node itself, which
        # the logical id above already covers. `backend_logical_id` and
        # `network_logical_id` are REFERENCES to resources other nodes create.
        return out^
    elif k == ResourceKind.RESOURCE_KIND_IAM_CUSTOM_ROLE:
        # kind 27 carries NO oneof arm: the logical id IS the custom-role id,
        # which the logical id above already
        # covers. Enumerated EXPLICITLY rather than left to a default arm — see
        # this function's header, and the kind-20 twin directly above.
        return out^
    raise Error(
        String(
            "run_scope: ResourceKind ordinal "
        )
        + String(k)
        + String(
            " has no case in `_node_addressed_names` — a new resource kind"
            " must state WHICH of its names address a cloud resource before it"
            " can appear in a run-scoped graph. Refusing rather than treating"
            " it as unnamed: an unnamed node is an UNSCOPED node, and an"
            " unscoped node in a run-scoped teardown is a resource this run"
            " does not own being deleted."
        )
    )


def run_scope_violations(
    manifest: FullManifest, scope: RunScope
) raises -> List[String]:
    """Every name in `manifest` that does NOT belong to `scope`, as reason
    strings. EMPTY means the graph is entirely this run's, and therefore that
    reaping it in reverse cannot touch anything else.

    This is the assertion `kci delete --run-id` needs before it deletes
    ANYTHING, and it is deliberately whole-graph: one foreign name refuses the
    WHOLE teardown rather than skipping that node. A teardown that silently
    skips is a teardown that leaks, and the leak is invisible.

    Also enforces the two cloud LENGTH bounds, because a name that is correctly
    scoped and too long fails at the cloud, mid-apply, with resources already
    standing — and a teardown then has to reap a partial graph.
    """
    var out = List[String]()
    for i in range(len(manifest.nodes)):
        # ── the SERVICE-ACCOUNT length bound (30), applied to the two places a
        #    string becomes an `account_id`. `_runtime_identity_of` is explicit
        #    that the SA created, the identity the compute runs AS, and every
        #    grant's principal are the SAME string — so both readings of it are
        #    bounded here, at the tighter of the two limits.
        var lerr = String("")
        if manifest.nodes[i].kind.value == (
            ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT
        ) and manifest.nodes[i].service_account:
            lerr = scoped_name_length_error(
                manifest.nodes[i].service_account.value().account_id,
                SA_ACCOUNT_ID_MAX,
                String("GCP service-account account_id"),
            )
        elif manifest.nodes[i].kind.value == (
            ResourceKind.RESOURCE_KIND_SERVERLESS_COMPUTE
        ) and manifest.nodes[i].serverless_compute:
            lerr = scoped_name_length_error(
                manifest.nodes[i].serverless_compute.value().runtime_identity,
                SA_ACCOUNT_ID_MAX,
                String(
                    "GCP service-account account_id (the runtime identity this"
                    " service runs AS, self-provisioned as an SA of that name)"
                ),
            )
        if lerr.byte_length() > 0:
            out.append(
                String("node '") + manifest.nodes[i].logical_id + String("': ") + lerr
            )

        var names = _node_addressed_names(manifest.nodes[i])
        for j in range(len(names)):
            var n = names[j]
            if n.byte_length() == 0:
                continue
            if not scope.carries(n):
                out.append(
                    String("node '")
                    + manifest.nodes[i].logical_id
                    + String("' (kind ")
                    + String(manifest.nodes[i].kind.value)
                    + String(") addresses '")
                    + n
                    + String(
                        "', which does NOT carry this run's token '"
                    )
                    + scope.token()
                    + String(
                        "' — it names a STANDING resource. A run-scoped"
                        " teardown of this graph would delete it, taking out"
                        " every deployment that shares it."
                    )
                )
                continue
            var too_long = scoped_name_length_error(
                n,
                RESOURCE_NAME_MAX,
                String("Cloud Run service / GCS bucket / secret-handle"),
            )
            if too_long.byte_length() > 0:
                out.append(
                    String("node '")
                    + manifest.nodes[i].logical_id
                    + String("': ")
                    + too_long
                )
    return out^


# =============================================================================
# §5 — compose_run_scoped: the FUSED chokepoint.
# =============================================================================


def compose_run_scoped(
    bundle: AppBundle, env: String, scope: RunScope
) raises -> FullManifest:
    """Scope the intent, compose it, and PROVE the result belongs to this run —
    or raise.

    THE FUSION IS THE SAFETY PROPERTY, not a convenience. There is no exported
    path that returns a run-scoped manifest WITHOUT having run
    `run_scope_violations` over it, so a caller cannot obtain one and forget the
    check. That is what "structural, not conventional" means here: the guard is
    not something the deploy path remembers to call, it is something the value
    cannot exist without.

    (`scope_bundle` and `run_scope_violations` remain individually exported
    because the CLI must scope the bundle it also hands to the driver, and
    because a test must be able to hand this function's guard a manifest that
    deliberately escapes. Neither export weakens the fusion: the CLI routes its
    bundle through THIS function's guard, and the test's job is to prove the
    guard fires.)
    """
    var scoped = scope_bundle(bundle, scope)
    var manifest = compose_api(scoped, env)
    var violations = run_scope_violations(manifest, scope)
    if len(violations) > 0:
        var joined = String("")
        for i in range(len(violations)):
            joined += String("\n  - ") + violations[i]
        raise Error(
            String("kci: --run-id ")
            + scope.run_id
            + String(": REFUSING the graph for bundle '")
            + bundle.name
            + String("' — ")
            + String(len(violations))
            + String(
                " composed name(s) do not belong to this run, so a run-scoped"
                " teardown could not be proven safe:"
            )
            + joined
        )
    return manifest^
