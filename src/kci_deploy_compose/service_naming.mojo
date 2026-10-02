# =============================================================================
# kci_deploy_compose/service_naming.mojo — THE NAME AXIS OF A DEPLOY TARGET,
#   BESIDE THE REFUSAL THAT REQUIRES IT.
# =============================================================================
#
# `AppSpec.name_scope == NAME_SCOPE_REGIONAL` (field 37) says the authored `name`
# is a BASE name that the DEPLOY TARGET qualifies. This module is where a bundle
# carrying that marker becomes the bundle a deploy composes, and
# `compose_api._auto_lifted_services` REFUSES BY NAME any bundle that reaches
# compose without it.
#
# ── IT LIVES IN THIS PACKAGE ON PURPOSE ────────────────────────────────────────
# The REFUSAL is in this package, so its only REMEDY must be too: a gate inside
# this package that composes a regional bundle has to be able to resolve the
# names first, and it cannot depend on a package that depends on this one. The
# deploy tool imports and re-exports these functions; the target-bundle
# generation that needs the ENV REGISTRY stays in the deploy tool.
#
# ONE CONVENTION, ONE DEFINITION. The `<base>-<cloud>-<region>` spelling is
# `komira_svcref.regional_service_name` and is IMPORTED, never re-declared; the
# mapper imports its inverse from the same place. A second spelling of a service
# name is how a registry key comes to exist that is no service's name.
# =============================================================================

from kci_bundle_proto.app_bundle import (
    AppBundle,
    AppKind,
    AppSpec,
    NameScope,
    ServiceSpec,
)

# THE ONE COMPOSER OF A REGION-QUALIFIED SERVICE NAME — imported, never
# re-declared.
from komira_svcref.service_registry import regional_service_name

from kci_deploy_compose.compose_api import (
    auto_lifted_services_unresolved,
    service_name_scope,
)


def bundle_declares_derived_names(bundle: AppBundle) raises -> Bool:
    """Whether ANY service this bundle composes declares `NAME_SCOPE_REGIONAL`.

    The cheap predicate the callers use to leave a bundle untouched: a bundle
    that declares none is returned by `resolve_service_names_for_target`
    completely untouched — not "rebuilt to the same value", untouched — so the
    auto-lift shape (`services` empty vs non-empty) it presents to compose is
    exactly the one its author wrote. That distinction is load-bearing:
    `_auto_lifted_services` IGNORES the singular `name`/`spec` the moment
    `services` is non-empty, so a resolver that always materialised a `services`
    list would silently change what a single-service bundle composes from."""
    var services = auto_lifted_services_unresolved(bundle)
    for i in range(len(services)):
        if service_name_scope(services[i]) == NameScope.NAME_SCOPE_REGIONAL:
            return True
    return False


def target_service_name(
    base: String, scope: Int, cloud: Int, region: String
) raises -> String:
    """THE DERIVATION, in one line and one place: what a service whose authored
    name is `base` is CALLED when it is deployed to `(cloud, region)`.

      NAME_SCOPE_UNSPECIFIED -> `base`
      NAME_SCOPE_REGIONAL    -> `<base>-<cloud>-<region>`    (the derived name)

    For example:
      ("svc-a", REGIONAL, CLOUD_GCP, "region-1") -> svc-a-gcp-region-1
      ("svc-a", REGIONAL, CLOUD_AWS, "region-2") -> svc-a-aws-region-2

    AN EMPTY REGION IS A REFUSAL, NOT A FALLBACK, AND THIS IS THE WHOLE SAFETY
    ARGUMENT. `regional_service_name` returns the BARE `base` for an empty region
    — a deliberate, documented arm of the composer, and exactly the wrong answer
    here. The service registry row is keyed on the PROJECT ALONE (no region
    axis), so a deploy composing the bare name could claim the key of a live,
    unrelated service of the same name (an orphan of an earlier rename, say)
    with no signal anywhere — the 403-behind-a-green-deploy failure this whole
    design exists to prevent, arriving by the other door.

    An UNSPECIFIED cloud is refused by `cloud_segment` itself, with its own
    diagnostic ("a caller that cannot say which cloud it is deploying to has not
    yet resolved its environment binding")."""
    if scope != NameScope.NAME_SCOPE_REGIONAL:
        return base.copy()
    if region.byte_length() == 0:
        raise Error(
            String(
                "resolve_service_names_for_target: service '"
            )
            + base
            + String(
                "' declares `name_scope: NAME_SCOPE_REGIONAL`, so its name is"
                " `<base>-<cloud>-<region>` — but the deploy target resolved NO"
                " region. There is no name to compose. `regional_service_name`"
                " returns the BARE base for an empty region and that arm may NOT"
                " be taken here: the bare name would be '"
            )
            + base
            + String(
                "', whose service-registry row is keyed on PROJECT ALONE, so a"
                " deploy in one region would claim the row of a same-named"
                " service in another. Resolve the environment binding's region"
                " (or the bundle's `spec.region` override) before composing."
            )
        )
    return regional_service_name(base, cloud, region)


def resolve_service_names_for_target(
    bundle: AppBundle, cloud: Int, region: String
) raises -> AppBundle:
    """THE ONE PLACE A BUNDLE'S AUTHORED NAMES BECOME THE DEPLOY TARGET'S
    SERVICE NAMES. Call it on the way into `compose`, with the EFFECTIVE binding
    — i.e. after any `spec.region` override has been applied, so the region here
    is the one all four apply sites will use.

    RETURNS THE BUNDLE UNTOUCHED when no service declares `NAME_SCOPE_REGIONAL`.
    Not "rebuilt to an equal value" — the same value — so the composed
    manifest's node ids and content address are unmoved, and the auto-lift's
    `services`-empty branch is still the branch a single-service bundle takes.

    WHEN A SERVICE DOES DECLARE IT, the resolved bundle differs in exactly two
    ways, both of them necessary:

      1. `services` is MATERIALISED (from the auto-lift) with each opted-in
         service's `name` replaced by its derived name. Materialising it is what
         makes the derived name authoritative — `_auto_lifted_services` ignores
         the singular `name` whenever `services` is non-empty.

      2. Each resolved service's `name_scope` is reset to UNSPECIFIED. The
         resolved bundle is one whose names ARE its service names, which is
         precisely what UNSPECIFIED means — and it makes this function
         IDEMPOTENT, so a double-resolve cannot compose
         `svc-a-gcp-region-1-gcp-region-1`.

    `bundle.name` IS DELIBERATELY NOT REWRITTEN. It is the MACHINE / app
    identity, not a service name: the deploy-target key, the `staged-image/<app>`
    ledger row and the ownership rows all key on it, and a bundle with two
    targets has TWO service names and ONE machine. The bundle keeps its name;
    only the running services carry the cloud and the region."""
    if not bundle_declares_derived_names(bundle):
        return bundle.copy()

    var services = auto_lifted_services_unresolved(bundle)
    var resolved = List[ServiceSpec]()
    # THE RENAME LEDGER — the (authored -> derived) pairs this call actually
    # MOVED, recorded where the move happens so no consumer has to re-derive it.
    # Only genuinely-moved names go in: an UNSPECIFIED-scope service maps to
    # itself, and rewriting a reference to it would be a no-op that widens the
    # blast radius of this loop for nothing.
    var renamed_from = List[String]()
    var renamed_to = List[String]()
    for i in range(len(services)):
        var scope = service_name_scope(services[i])
        var authored = String(services[i].name)
        var name = target_service_name(authored, scope, cloud, region)
        if name != authored:
            renamed_from.append(authored.copy())
            renamed_to.append(name.copy())
        var sp = Optional[AppSpec]()
        if services[i].spec:
            var spec_copy = services[i].spec.value().copy()
            # (2) above — the resolved bundle's names ARE its service names.
            spec_copy.name_scope = NameScope(NameScope.NAME_SCOPE_UNSPECIFIED)
            sp = Optional[AppSpec](spec_copy^)
        resolved.append(
            ServiceSpec(name^, AppKind(services[i].kind.value), sp^)
        )

    var out = bundle.copy()
    out.services = resolved^
    retarget_service_references(out, renamed_from, renamed_to)
    return out^


def retarget_service_references(
    mut bundle: AppBundle,
    renamed_from: List[String],
    renamed_to: List[String],
) raises:
    """REWRITE EVERY IN-BUNDLE REFERENCE to a service this resolution RENAMED.

    THERE ARE **TWO** NAME-RESOLUTION TRANSFORMS, AND THIS FUNCTION EXISTS SO
    THERE IS ONLY ONE COPY OF THE REFERENCE REWRITE.
    `resolve_service_names_for_target` (here) is the compose-path twin; the
    deploy tool's target-bundle generation is the one a deploy writes and reads.
    A fix applied to only one of them leaves the other carrying the derived
    service name beside a reference to the authored one; one shared rewrite is
    what keeps the read side and the write side from drifting.

    `renamed_from[i] -> renamed_to[i]`, and ONLY names that genuinely MOVED
    belong in the ledger: an UNSPECIFIED-scope service maps to itself, and
    rewriting a reference to it is a no-op that widens this loop's blast radius
    for nothing.
    """
    # ─────────────────────────────────────────────────────────────────────────
    # THE RENAME CARRIES ITS REFERRERS. A rename that moves the DEFINITION and
    #     not the REFERENCES leaves a dangling reference inside a bundle the
    #     deploy then treats as authoritative.
    #
    # A regional bundle with a `service:`-qualified validate step: the apply
    # registers the DERIVED name, the served-URL observations are keyed on the
    # derived name, and the step's endpoint lookup matches by EXACT EQUALITY —
    # correctly, since substituting a sibling's URL is the one thing that lookup
    # must never do (a health gate would probe one service and report a verdict
    # about another). If the step still says the authored name, the wave is
    # refused for a missing required arg.
    #
    # AND THE BUNDLE COULD NOT HAVE SAID IT ANY OTHER WAY. `validate_bundle`
    # requires this field to be a LOGICAL `ServiceSpec.name`, checked against the
    # names the bundle DECLARES — and `app_bundle.proto` says the same at the
    # field. Authoring the derived name there is REFUSED OFFLINE. So without this
    # rewrite no bundle text would satisfy both gates. The authored surface is
    # right; the resolution must be complete.
    #
    # EXACT EQUALITY, NEVER A PREFIX OR A SUBSTRING. `probe-a` is a prefix of a
    # hypothetical `probe-a-canary`, and a loose match here would silently point
    # one step at another service's endpoint. A reference either names a service
    # this bundle declares or it does not, and `validate_bundle` has already
    # refused the second case.
    #
    # SCOPE, STATED: this rewrites `waves[].validate[].service`.
    # `crons[].target.service`, `outputs[].from_served`,
    # `RunContainer.test_role.grants_on_service` and `BundleEnvVar.service` name
    # services the same way and would need the same treatment when a regional
    # bundle authors them.
    #
    # IT REWRITES A FIELD AND ADDS/REMOVES NOTHING. A generation step that
    # dropped steps would convert a gated deploy into an ungated one that still
    # reported green; retargeting a reference inside a step preserves the step
    # SET.
    if len(renamed_from) == 0:
        return
    for wi in range(len(bundle.waves)):
        for si in range(len(bundle.waves[wi].validate)):
            var ref_name = String(bundle.waves[wi].validate[si].service)
            if ref_name.byte_length() == 0:
                continue
            for ri in range(len(renamed_from)):
                if ref_name == renamed_from[ri]:
                    bundle.waves[wi].validate[si].service = renamed_to[
                        ri
                    ].copy()
