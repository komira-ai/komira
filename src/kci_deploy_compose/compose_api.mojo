# =============================================================================
# kci_deploy_compose/compose_api.mojo — the API-kind COMPOSITION.
# =============================================================================
#
# WHAT THIS IS. A Composition is a plain, value-typed Mojo function that expands
# the tier-1 authored intent bundle (`app_bundle.proto`) into the tier-2
# synthesized resource graph (`full_manifest.proto`) — the Crossplane
# Claim -> Composition -> resources shape. This file is the `Api` Composition:
# `compose_api(bundle, env)` emits the FIXED 4-node topology every API composes
# to on EVERY cloud —
#
#       IamRole  ->  Secret  ->  Config  ->  ServerlessCompute
#
# — where `->` is a `depends_on` edge the engine Kahn-walks (create predecessors
# first). Only the below-the-line mapper's per-node conformer selection differs
# by cloud (Cloud Run vs systemd+proxy); the manifest is byte-identical across
# installations. The node kinds are GENERIC — no vendor product name appears
# here.
#
# PURE + DETERMINISTIC (load-bearing). This is a pure function: NO cloud calls,
# NO env-binding resolution (`env` is the logical symbol string only, carried
# verbatim into `FullManifest.environment`), NO side effects. Synth runs EXACTLY
# ONCE at run create/plan; the reconciler NEVER re-invokes it. Determinism is
# load-bearing: the same bundle+env in yields a byte-identical manifest +
# content-address out — so config keys are inserted in bundle-declaration order
# and every derived id/token is a deterministic function of `bundle.name`.
#
# THE ERASE-EARLY / VALUE-TYPED DISCIPLINE. A Composition MUST be a plain
# value-typed function — never a nested generic type tower — so that compile
# cost stays linear in the bundle surface. Every node is a flat `ResourceNode`
# value built by a small helper; nothing is generic over the node type.
#
# IMAGE-REF RESOLUTION. Synth runs BEFORE the BUILD wave completes, so a
# `from_build` image ref cannot be a digest yet: it is carried through
# SYMBOLICALLY as `from_build:<target>` in the node's `image_digest`, and the
# pipeline pins the real sha256 at BUILD completion. A `digest` ref passes
# through VERBATIM (already pinned).
#
# RETENTION. All four API nodes are `RETENTION_DELETE` — they are app-owned
# (their lifecycle IS the deploy's), so `rollback_create` / `destroy_graph`
# destroy them on a reverse walk. Only standing state/artifact nodes are
# `RETENTION_RETAIN_KEEP` (see SHARED_RESOURCE_RETENTION below).
#
# Encapsulation: value-typed AppBundle + String in, FullManifest out; `raises`
# on a malformed bundle (fail-fast). ZERO UnsafePointer, ZERO wildcard origin, no
# pointers at all.
# =============================================================================

from kci_deploy_compose.content_address import content_address
from kci_deploy_compose.param_resolve import (
    resolve_parameter_args,
    # THE SELF-URL TOKEN. Reused rather than re-spelled: `param_resolve`
    # reserves this exact string for the ARGV channel, and one spelling is what
    # keeps the reserved name reserved.
    PARAM_DEPLOY_URL_TOKEN,
    # The token `_refuse_authorizer_identity_conflict`'s MARKER GUARD recognises
    # as having a downstream both-sink resolver. Imported, never retyped: the
    # guard compares against the same declaration the mapper's resolver keys on.
    PARAM_SVCREF_TOKEN_OPEN,
)
# THE ONE GRANT-SCOPE DERIVATION, shared with the bootstrap composition so the
# two composers cannot disagree about what the same `""` target means.
from kci_deploy_compose.grant_scope import (
    checked_grant_scope,
    grant_scope_for,
)

from kci_manifest_proto.full_manifest import (
    FullManifest,
    ResourceNode,
    ResourceKind,
    Retention,
    ServerlessComputeSpec,
    # ★ THE RESOLVED OUTBOUND PATH (`ServerlessComputeSpec.network_egress`,
    # field 10) — the resolved-tier twin of the intent tier's
    # `ValidateVpcEgress`. Declared IN full_manifest.proto (which imports
    # nothing), so the crossing between the two tiers happens here, by copy.
    NetworkEgressSpec,
    ConfigSpec,
    SecretSpec,
    IamRoleSpec,
    DatastoreSpec,
    DatastoreCollectionSpec,
    # The RESOLVED access path (`DatastoreCollectionSpec.primary_access_path` /
    # `.secondary_access_paths`). Declared IN full_manifest.proto (which imports
    # nothing), so the crossing from the intent tier happens here, BY COPY —
    # `_datastore_collections_of` is the one place it happens.
    DatastoreAccessPath,
    GrantSpec,
    # `GrantSpec.scope` (field 4) — the TYPED scope.
    GrantScope,
    FederatedAssumePrincipal,
    InAccountAssumePrincipal,
    ServiceAccountSpec,
    WebRuntimeConfigEntry,
    Capability,
    # The static-website front-door composite spec — emitted by
    # `compose_static_frontend`.
    WebFrontendSpec,
    # The FULL url-map route table — the full_manifest WebRouteRule (aliased to
    # disambiguate from the app_bundle one).
    WebRouteRule as FMWebRouteRule,
    # What a route rule ASSERTS about its paths (ROUTE / DENY / DEFAULT) —
    # IDENTICALLY-NAMED intent-tier enum imported below from `kci_bundle_proto`
    # (the two proto files declare it INDEPENDENTLY with identical ordinals by
    # construction, like SourceKind/RegistryKind).
    WebRouteDisposition as FMWebRouteDisposition,
    TriggerSpec,
    SourceKind,
    RegistryKind,
    # The RESOLVED trigger arms — the standalone-tier mirror of the intent-tier
    # `GitPush` / `Schedule` / `PackagePublished` (declared independently in the
    # two proto files; neither may import the other).
    ResolvedGitPush,
    ResolvedSchedule,
    ResolvedPackagePublished,
    # The platform-INJECTED per-attempt liveness harness synthesized onto every
    # resolved compute node (never authored on the customer AppBundle).
    SupervisorSpec,
    SupervisorMode,
    # API-EDGE kind 19: the 4-field composite spec + its two enums — emitted per
    # service with an `inbound: CLIENT` intent, gated per wave
    # (Wave.api_edge_enabled).
    ApiEdgeSpec,
    RouteMode,
    EdgeAuthMode,
    # ONE additional, EDGE-SECURED route on that same edge — the resolved mirror
    # of the intent-tier `SecuredInboundRoute`, projected by
    # `_secured_edge_routes_of`.
    SecuredEdgeRoute,
    # RESOURCE_KIND_BUCKET arm 13 (the app-provisioned placement/staging bucket —
    # `AppSpec.buckets`): the RESOLVED bucket desired-state (location + the audited
    # storage_class / UBLA / public-access-prevention). Emitted by `_bucket_node`.
    # The intent tier's same-shaped-minus-`name` message keeps the bare
    # `BucketSpec`, exactly as `ResolvedGitPush` sits opposite `GitPush`.
    ResolvedBucketSpec,
    # RESOURCE_KIND_RUN_TO_COMPLETION_JOB arm 2 (the JOBS capability): the
    # RESOLVED one-shot-job desired-state an `AppBundle.jobs[]`
    # entry composes into. Emitted by `_run_to_completion_job_node`.
    RunToCompletionJobSpec,
    # SCHEDULED_CALL kind 21 / oneof arm 20: the RESOLVED
    # wall-clock cron that calls a served node in THIS graph. Emitted per
    # `AppBundle.crons` by `_append_cron_nodes`. Carries NO url and NO audience —
    # both are the target's serving address, discovered at apply time.
    ScheduledCallSpec,
    # THE TWO NETWORK KINDS (25 NETWORK / arm 21, 26 INGRESS_POLICY / arm 22).
    # `EgressMode` is the ONE operator-facing dial on a network; `IngressRule`
    # is the peer/port/protocol row an `IngressPolicySpec` repeats.
    # NEITHER NODE IS EMITTED INTO ANY MANIFEST BY THIS FILE YET, ON PURPOSE —
    # see `network_node`'s docstring: a node no arm can materialize is the first
    # unmappable node in every composition, and the apply-form arm raises on it.
    EgressMode,
    IngressPolicySpec,
    IngressRule,
    NetworkSpec,
    # THE MAIL-TRANSPORT SPINE'S RESOLVED ARMS (kinds 5 and 7). `QueueSpec` is
    # oneof arm 5, `DnsRecordSpec` arm 7. `RESOURCE_KIND_MAIL_DOMAIN_IDENTITY`
    # (22) needs no import: it carries its whole identity in `logical_id` and
    # sets NO oneof arm.
    QueueSpec,
    DnsRecordSpec,
)

from kci_bundle_proto.app_bundle import (
    AppBundle,
    AppKind,
    ImageRef,
    AppSpec,
    ServiceSpec,
    # WHETHER A SERVICE'S AUTHORED NAME IS ITS NAME OR A BASE NAME THE DEPLOY
    # TARGET QUALIFIES (`AppSpec.name_scope`). The qualified name is composed by
    # `service_naming` (over `komira_svcref.regional_service_name`); an
    # unresolved bundle is REFUSED by name (see `_auto_lifted_services`), which
    # makes a missing resolution fail-LOUD rather than fail-quiet.
    NameScope,
    TriggerSource,
    # The `run_container` arm of a validate step — read for the identity its JOB
    # runs as (`runtime_identity`) and for the read authorities it declares
    # (`reads_secret`, `reads_telemetry`).
    RunContainer,
    Wave,
    # The per-wave env-var override element (`Wave.env_override`) — the SAME
    # BundleEnvVar shape as a spec-level `env {}`; the per-ENV deploy-config
    # overlay `compose_api` folds onto the Config node for the selected wave,
    # for the ONE service it names (see `_wave_env_overrides_by_service`).
    BundleEnvVar,
    # THE TYPED SELF WAVE-OUTPUT ENUM — needed by `_self_output_marker_for`,
    # which renders the ONE arm a container's STATIC environment can carry and
    # REFUSES the rest by name.
    ValueFrom,
    # The intent-tier trigger enums, aliased to disambiguate from the
    # IDENTICALLY-NAMED standalone-tier `SourceKind` / `RegistryKind` imported
    # above from `kci_manifest_proto` (the two proto files declare the enums
    # INDEPENDENTLY with identical ordinals by construction). The `Bundle*`
    # alias keeps the ctor cascade unambiguous so a translate reads the RIGHT
    # tier's arm.
    SourceKind as BundleSourceKind,
    RegistryKind as BundleRegistryKind,
    # The intent-tier trigger ARMS, aliased for the same reason.
    GitPush as BundleGitPush,
    Schedule as BundleSchedule,
    PackagePublished as BundlePackagePublished,
    # The intent-tier bucket declaration (`AppSpec.buckets`). The resolved tier
    # is `ResolvedBucketSpec`, so this alias is the `Bundle*` convention, the
    # standing of `BundleGitPush` beside `ResolvedGitPush`. The authored intent
    # (name / location / storage_class / UBLA / public_access_prevention) that
    # `_append_bucket_nodes` translates into the `ResolvedBucketSpec` node.
    BucketSpec as BundleBucketSpec,
    # The intent-tier EDGE-SECURED route declaration (`AppSpec.
    # secured_inbound_routes`) + its policy enum. `_secured_edge_routes_of`
    # translates them onto the resolved `SecuredEdgeRoute`; the enum is named here
    # because the translate RAISES on any value it does not know.
    EdgeAuthPolicyKind,
    # THE INTENT-TIER ANSWER TO "MAY THE INTERNET CALL THIS APP?"
    # (`IngressSpec.caller_class`). Named here because `_append_api_edge_nodes`
    # RAISES on a value it does not know rather than falling through to the
    # pass-through default — an unrecognised caller class must not resolve to
    # the most permissive arm.
    EdgeCallerClass,
    # The intent-tier JOB declaration (`AppBundle.jobs`), aliased to disambiguate
    # from the IDENTICALLY-NAMED RESOLVED-tier `RunToCompletionJobSpec` imported
    # above (the `Bundle*` alias convention). Translated by `_append_job_nodes`.
    JobSpec as BundleJobSpec,
    # THE INTENT-TIER MAIL-TRANSPORT SPINE (`AppSpec.mail_transport`, field 34).
    # `MailIdentityOwnership` is named here because `_append_mail_transport_nodes`
    # RAISES on UNSPECIFIED rather than defaulting it — the ONE axis where both
    # answers are destructive in opposite directions (see the proto).
    MailTransportSpec,
    MailIdentityOwnership,
    # THE INTENT-TIER DATASTORE COLLECTION SHAPES
    # (`AppSpec.datastore_collections`, field 35), aliased to disambiguate from
    # the IDENTICALLY-NAMED RESOLVED-tier `DatastoreAccessPath` imported above
    # from `kci_manifest_proto` (the `Bundle*` alias convention — the standing of
    # `BundleBucketSpec` beside `ResolvedBucketSpec`). `DatastoreCollection`
    # itself does not collide with `DatastoreCollectionSpec`; it is aliased for
    # the same reason its sibling is, so the ctor cascade in
    # `_datastore_collections_of` reads the RIGHT tier's arm at every line.
    DatastoreCollection as BundleDatastoreCollection,
    DatastoreAccessPath as BundleDatastoreAccessPath,
    # THE INTENT-TIER PER-CLOUD SPEC VARIANT (`AppSpec.cloud_variants`, field
    # 36). `resolve_cloud_variant` below is the ONE reader of the field: it
    # selects the entry whose mirrored `Cloud`
    # ordinal equals this composition's own `cloud` parameter, overlays only the
    # members that entry AUTHORS, and refuses an UNSPECIFIED or duplicated
    # posture by name. Named here rather than aliased because no resolved-tier
    # type shares the word.
    CloudVariant,
    # The intent-tier ingress realization inputs — named because
    # `resolve_cloud_variant` overlays a variant's `ingress` onto the spec and
    # must spell the Optional's type.
    IngressSpec,
)
from kci_bundle_proto.deploy_model import DatastoreNeed, InboundNeed


# The symbolic carry-through form written into a ServerlessCompute node's
# `image_digest` when the bundle's image is a `from_build` ref (synth runs before
# BUILD completes; the pipeline replaces this marker with the pinned sha256 at
# BUILD completion). A `digest` ref never takes this path — it is already pinned.
comptime FROM_BUILD_DIGEST_MARKER_PREFIX: String = "from_build:"

# NOTE (Grant model). Cross-resource authorizations are SEPARATE ordered `Grant`
# nodes (a policy on the TARGET, member = the principal — see `_grant_node` /
# `_append_grant_nodes`), not permission tokens on the IamRole node.
# `IamRoleSpec.permissions` is `reserved` in the proto and the IamRole node is an
# empty-spec identity node.

# The NEUTRAL datastore-impl tokens carried into a `DatastoreSpec.impl` at synth
# (cloud-agnostic — synth NEVER resolves the concrete per-cloud impl; the
# below-the-line mapper resolves `serverless` -> the cloud's serverless DB, e.g.
# Firestore on GCP). One token per non-none `DatastoreNeed` arm.
comptime DATASTORE_IMPL_SERVERLESS: String = "serverless"
comptime DATASTORE_IMPL_DEDICATED: String = "dedicated"

# =============================================================================
# RUNTIME-IDENTITY SELF-PROVISION — DEPLOY, not bootstrap, creates each
# self-provisioned service's runtime SA + its base grants.
# =============================================================================
#
# When a bundle's `AppSpec.runtime_identity` is AUTHORED (non-empty),
# `compose_api` emits — per service — a `RESOURCE_KIND_SERVICE_ACCOUNT` node
# (creating the SA the compute RUNS AS) plus the base `RESOURCE_KIND_GRANT`
# nodes. An UNSET `runtime_identity` derives `<service>-role` and emits NEITHER —
# a plain app bundle composes with no identity nodes.
#
# The bucket and the artifact repository are BOOTSTRAP resources referenced BY
# NAME (external grant targets — the grant conformer self-derives the resource
# path from the name, NO graph dependency). These names MUST match the bootstrap
# composition's constants, but compose cannot import the bootstrap composition
# (it imports the mapper; compose is a pure leaf), so they are duplicated here
# with this cross-reference. The bucket is `<project>-bootstrap` —
# project-dependent, so compose emits an EMPTY target (the pure, env-agnostic
# composition has no project) and the below-the-line mapper resolves
# `<project>-bootstrap` from its `project` binding for an OBJECT_STORE grant with
# an empty target.
#
# A secret the service reads is NOT a base grant: a service that reads a secret
# declares it in `secret_bindings`, and gets the ordinary per-handle READ_SECRET
# grant from that declaration. Custody of a secret is a bundle declaration, never
# a composer constant.
comptime ARTIFACT_REPO_ID: String = "kci"

# =============================================================================
# DEPLOY PRINCIPAL — the identity kci's own bootstrap creates and deploys as.
# =============================================================================
#
# The in-cloud validation JOB runs as the deploy SA. To mint an ACCEPTED OIDC
# token and reach a PRIVATE-ingress service — which a LOCAL fork-exec validator
# cannot — that SA needs `roles/run.invoker` ON the service. For every
# SELF-PROVISION service, compose emits ONE extra `Grant` node — principal =
# `DEPLOY_PRINCIPAL`, capability INVOKE_SERVICE, target = the service's OWN
# `<S>-svc` node — reusing the SAME unified-Grant mechanism the external-service
# invoke grant uses (the mapper expands the short name to the cloud's principal
# form). An app with no `runtime_identity` is validated via LOCAL SUBPROCESS,
# needs no deploy-SA invoker, and composes no such grant.
#
# The name MUST match the bootstrap composition's deploy SA id (the SA kci's
# bootstrap creates in a fresh env), but compose cannot import the bootstrap
# composition (it imports the mapper; compose is a pure leaf), so it is
# duplicated here with this cross-reference — exactly like `ARTIFACT_REPO_ID`.
comptime DEPLOY_PRINCIPAL: String = "kci-deploy"

# =============================================================================
# API-EDGE GATEWAY BACKEND-AUTH SA. The gateway ApiConfig stamps a backend-auth
# SA the ESPv2 gateway impersonates to mint the backend OIDC token; that SA must
# EXIST (else `CreateApiConfig` 400s `Service account "…" does not exist`) and
# the deploy caller must hold `roles/iam.serviceAccountUser` (actAs) on it.
# `_append_api_edge_nodes` self-provisions BOTH as graph nodes.
# =============================================================================
#
# This is the SINGLE SOURCE OF TRUTH for the gateway SA's flat account_id. The
# kci binary imports this constant to form the FULL email it stamps onto the
# ApiConfig, and the SERVICE_ACCOUNT node emitted here carries the SAME
# account_id — so the mapper's `service_account_email(account_id, project)`
# derivation reconstructs the EXACT email the ApiConfig stamps (no name drift by
# construction). Env-agnostic compose carries the FLAT short name only (no
# project, no env read); the mapper forms the vendor email — exactly like the
# runtime `<svc>-role` SAs.
comptime EDGE_GATEWAY_SA_ACCOUNT_ID: String = "kci-edge-gw"

# =============================================================================
# THE AWS FRONT DOOR'S AUTHORIZER — the names that make kind 19 materializable.
# =============================================================================
#
# `EDGE_AUTHORIZER_SUFFIX` MUST EQUAL the AWS mapper's authorizer suffix. The
# mapper resolves the authorizer BY NAME out of the manifest and REFUSES a node
# it cannot find; a drift between these two spellings makes every composed AWS
# edge gap with "no node named `<edge>-authorizer`" while the composer emitted
# one under a different id. It is not IMPORTED because this package sits ABOVE
# the mapper (compose is cloud-neutral and runs with no mapper on `-I`); the
# mapper's tests hold the equality.
comptime EDGE_AUTHORIZER_SUFFIX: String = "-authorizer"

# The two env KEYS the authorizer reads its issuer and audience from are the
# AUTHORIZER'S OWN CONTRACT, so they are not named here: the bundle declares
# them (`IngressSpec.authorizer_issuer_env` / `.authorizer_audience_env`). The
# schema this package builds against does not carry those fields yet, so an AWS
# identity-JWT edge is REFUSED at compose (see `_append_api_edge_nodes`) rather
# than handed keys kci invented.

# =============================================================================
# SHARED_RESOURCE_RETENTION — A SHARED RESOURCE MAY NOT BE OWNED BY ONE APP'S
#   GRAPH. The one rule behind every `retention=Retention.RETENTION_RETAIN_KEEP`
#   in this file.
# =============================================================================
#
# THE HAZARD. A node composed IDENTICALLY into every edge-bearing app's graph as
# RETENTION_DELETE is deleted by the reverse walk of whichever app is torn down
# first — e.g. the project-global gateway backend-auth SA every edge
# impersonates. Deleting one unrelated app then breaks every other app's running
# ingress. Restoring the SA does not restore the system: the undelete mints a
# NEW uid, so every policy that named the old one holds a stale
# `deleted:serviceAccount:…?uid=…` member until something converges it.
#
# ── THE RULE, and it is about OWNERSHIP, not about data ──────────────────────
#
#   A node whose resource this graph does not EXCLUSIVELY own is RETAIN_KEEP.
#
# For a CREATE node (kind 11 ServiceAccount, …) "own" means: is this resource's
# identity derived from THIS app? `<svc>-role` is — one graph creates it, and its
# lifecycle IS that deploy's. The gateway SA is not: it is a CONSTANT, one per
# project, emitted by every edge-bearing graph, and the FIRST deploy creates it
# while all the others merely converge it. A resource N graphs create and 1 graph
# deletes is not owned by any of them.
#
# For a GRANT node the resource is the BINDING, and `delete` removes exactly one
# `(target, member, role)` triple. So the binding belongs to this graph iff at
# least ONE of its two ends does:
#
#   principal `<svc>-role` (created here) x ANY target  -> DELETE. The member is
#       being deleted anyway; unbinding it removes nothing anyone else holds.
#   ANY principal x target `<svc>-svc` (created here)   -> DELETE. Same, from the
#       other end — the policy itself goes.
#   principal `DEPLOY_PRINCIPAL` x a STANDING secret (NEITHER created here)
#       -> RETAIN_KEEP. Every app composes this identical node. Whichever app is
#       deleted first unbinds the authority all the others' validate jobs run on.
#
# ── WHY RETAIN_KEEP AND NOT `ingress { gateway_service_account: … }` ─────────
# The bundle-authored-identity arm exists (`_append_api_edge_nodes`) and it does
# fix the SA: an authored account emits no create node and no delete node. It is
# not the primary fix for two reasons. (1) It makes every edge bundle's
# correctness depend on an author remembering to name a pre-existing account,
# and it moves the SA's creation back out-of-band. (2) It fixes ONE node; the
# defect is a CLASS — several node ids in this file address project-global
# resources — and an authoring convention cannot reach the others. RETAIN_KEEP
# is the model already used for standing project-global infrastructure (the
# bootstrap bucket, the artifact repo, the WIF pool, the deploy SA, every
# PROJECT_SERVICE enable node), so the shared gateway SA is the same concept
# applied where it is needed.
#
# ── THE NODES THIS FILE COMPOSES THAT ARE PROJECT-SCOPED ──────────────────────
# The discriminator is the one above — a binding is this graph's to remove iff
# EITHER end is EXCLUSIVELY this graph's — so a shared PRINCIPAL on an app-owned
# TARGET is safe and does NOT appear here.
#
#   id                                                emitted by
#   ------------------------------------------------  ---------------------------
#   `edge-gateway-sa`                                 _append_api_edge_nodes
#       CREATES the gateway SA — the only node in this file that CREATES a
#       project-global RESOURCE.
#   `edge-gateway-sa-deploy-sa-user-grant`            _append_api_edge_nodes
#       deploy principal x gateway SA. Both ends foreign.
#   `<deploy>-reads-<secret>`                         _append_validate_step_secret_grant_nodes
#       deploy principal x an out-of-band secret. The id is derived from the
#       SECRET, so two bundles reading one secret compose the byte-identical node.
#   `<bundle>-validator-datastore-read-grant`         _append_shared_infra_validator_read_grant
#       deploy principal x `projects/<P>`. THE ID HIDES THE SHARING: it is keyed on
#       `bundle.name`, so two bundles emit two DIFFERENT ids for ONE binding.
#
# ONE NEAR MISS, recorded because it looks like another row and is not:
# `<deploy>-reads-<bucket>` (the validate-job bucket read) also has the shared
# deploy principal — but its TARGET is an app-declared bucket this graph
# creates, so the whole policy goes with the bucket. Shared principal alone is
# not the defect; shared principal AND shared target is.
#
# THIS LIST IS DOCUMENTATION, NOT THE CHECK. `shared_resource_guard.
# shared_resource_findings` DERIVES it from the composed graph plus the sibling
# corpus, so a row somebody adds tomorrow is covered with no edit here.
#
# WHAT RETAIN_KEEP DOES *NOT* COVER: `--delete-data` (and a `--run-id` run
# scope, via `run_scope_lifts_retention`) LIFTS the RETAIN_KEEP skip
# project-wide. That is the residual, and it is why retention is only half the
# answer — `shared_resource_guard.mojo` is the other half: it REFUSES a teardown
# that would still reach one of these, naming the resource and the sibling
# bundles that depend on it. A run scope is already safe: `run_scope_violations`
# refuses the whole graph over exactly these names.

# The PUBLIC-INVOKER SENTINEL principal (AppSpec.public_invoker, field 24). When
# a bundle authors `public_invoker: true`, compose emits ONE INVOKE_SERVICE grant
# on the service's OWN `<name>-svc` whose principal is THIS sentinel. It is NOT a
# service-account handle — the mapper recognizes it and threads it through
# VERBATIM (no `<sa>@<project>` email expansion, no SA-propagation retry), and
# the GCP grant conformer forms the IAM member as the LITERAL `allUsers`
# (public/unauthenticated at the network layer) instead of
# `serviceAccount:<email>`. It is for a service dialed by a peer that has NO
# OIDC identity (e.g. a browser), so IAM cannot gate it and security lives at the
# app layer. The exact string `allUsers` IS the GCP IAM member for "any
# principal, authenticated or not" — carried verbatim so it is auditable and
# grep-visible in the composed graph, never a magic bool the conformer invents.
comptime PUBLIC_INVOKER_PRINCIPAL: String = "allUsers"

# =============================================================================
# The cross-service reference marker contract (compose <-> runtime).
# =============================================================================
#
# THE MARKER. For an env var `VAR = ref("T")` (a `ServiceRef{service: T}` arm on
# `BundleEnvVar.val`, oneof case 3), compose emits a COMPANION Config entry
#
#       <VAR><SVCREF_MARKER_SUFFIX>  ->  T           (e.g. WORKER_URL__SVCREF -> worker)
#
# into the OWNING service's Config node `values`. The value is the LOGICAL sibling
# service name `T` (no vendor URL, no cloud token) — NOT T's URL.
#
# WHY A RUNTIME MARKER, NOT A COMPOSE-TIME LITERAL. T's URL is the OBSERVED deploy
# URL — unknown at compose (synth runs BEFORE T is deployed, and T can redeploy to
# a new URL). So `VAR` is resolved at RUNTIME, not baked into static config.
#
# THE RUNTIME-CONSUMPTION CONTRACT (implemented service-side, not here). The
# deployed service S, at boot, for every container env key ending in
# `SVCREF_MARKER_SUFFIX`:
#   1. take the marker's value `T` (the logical sibling name),
#   2. call `ServiceResolver.resolve(T, now_ms)` — a read-through of the
#      registry key `service/T` -> T's registered URL (or `None` if T is not yet
#      registered / deployed),
#   3. inject that URL as env `<VAR>` (strip the `SVCREF_MARKER_SUFFIX` suffix to
#      recover `VAR`) for the app to read as an ordinary env var.
# The marker flows to the container UNCHANGED: the below-the-line mapper folds a
# Config node's `values` verbatim into the container env (one EnvVar per entry), so
# `<VAR>__SVCREF=T` arrives as a plain container env var the runtime consumer reads.
#
# NAMING RESERVATION. `SVCREF_MARKER_SUFFIX` is a RESERVED env-key suffix — an app
# must not author a literal env var whose name ends in it (it would be interpreted
# as a service-ref marker at runtime).
comptime SVCREF_MARKER_SUFFIX: String = "__SVCREF"


def _self_output_marker_for(
    service: String, var_name: String, value_from: ValueFrom
) raises -> String:
    """The `${…}` token a `value_from` env var renders into a Config node's value.

    ONE SPELLING WITH THE ARGV CHANNEL. `PARAM_DEPLOY_URL_TOKEN` is imported
    rather than re-spelled: a reserved token with two literal spellings is a
    reserved token in one channel only, and the below-the-line resolver reads
    both channels.

    ONLY `VALUE_FROM_DEPLOY_URL` IS RENDERED, AND EVERY OTHER ARM REFUSES. Each
    has its own reason, and none of them is "unimplemented":

      * `VALUE_FROM_EDGE_URL` — the discovered API-edge URL is an OUTPUT of the
        apply that is not available to a resource being created by that same
        apply, and unlike the self-url there is no second post-create write on
        which to bake it (an edge is a different node, and the compute node is
        already converged when it appears). A validate STEP can have it; a
        container's static environment cannot.
      * `VALUE_FROM_ENV_PROJECT` / `VALUE_FROM_ENV_REGION` — these ARE known
        before anything is applied, so they are resolvable in principle. They are
        refused here because compose has no `EnvBinding` in hand at this call
        site, and inventing one would resolve them against the wrong env.
        Threading the binding is a separate change.
      * `VALUE_FROM_UNSPECIFIED` — the proto3 zero, fail-fast invalid.

    A REFUSAL, NOT A DROP. Dropping a `value_from` env var silently gives the
    author a container missing the variable behind a green deploy; refusing the
    arms that cannot be answered keeps the answerable one honest."""
    var v = value_from.value
    if v == ValueFrom.VALUE_FROM_DEPLOY_URL:
        return String(PARAM_DEPLOY_URL_TOKEN)
    raise Error(
        String("compose_api: service '")
        + service
        + String("' env var '")
        + var_name
        + String("' uses `value_from` ordinal ")
        + String(v)
        + String(
            ", which compose cannot render into a container's STATIC"
            " environment. Only VALUE_FROM_DEPLOY_URL (this service's own"
            " converged URL) is resolvable there, and only because a Lambda's"
            " configuration is a POST-CREATE surface —"
            " `UpdateFunctionConfiguration` — so the address can be baked after"
            " the door that assigns it exists.\n\n  If you want the API-EDGE"
            " url, or the environment's project/region, declare it on the wave's"
            " `validate { run_container { env {} } }`: a validate step runs"
            " AFTER convergence, where all three resolve.\n  If you want a"
            " PEER's endpoint, use `service_ref { service: \"<name>\" }`.\n\n"
            "REFUSED rather than DROPPED: a dropped variable produces a"
            " container with no such variable behind a green deploy."
        )
    )


# ENSURE-SECRET per-handle node id INFIX. An ensure-mode
# `secret_bindings` binding emits a per-handle RESOURCE_KIND_SECRET create node whose
# logical_id is `<svc><INFIX><handle>` — DISTINCT from the aggregate `<svc>-secret`
# node so both coexist, and shaped so the below-the-line mapper recovers the OWNING
# SERVICE by stripping from this infix (NOT the plain `-secret` tail, which would
# strip to the handle). The mapper builds the per-handle create node's ensure verb
# from ITS OWN SecretSpec.handle (the real Secret Manager name) so `GcpSecret.create`
# create-if-absent + versioned-PUTs it, and the accessor grant `depends_on` this node
# so the container EXISTS before the grant's read-modify-write GetIamPolicy runs.
comptime ENSURE_SECRET_NODE_INFIX: String = "-secret-ensure-"


# =============================================================================
# SUPERVISOR SYNTHESIS — the platform-INJECTED liveness harness
# (`full_manifest.proto:SupervisorSpec`). `compose_api` SYNTHESIZES a
# SupervisorSpec onto EVERY resolved compute node. The customer NEVER sees or
# sets the SupervisorSpec — the only supervisor-adjacent knobs a customer may
# touch are the four `AppSpec` HINT fields 9-12 (`supervisor_child_health_path` /
# `_port` / `_cpu` / `_memory`), which compose MERGES in.
#
# CLOUD-AGNOSTIC + DETERMINISTIC. Every value here is a DEPLOY CONSTANT or a
# deterministic function of the bundle — NO cloud call, NO clock — so synth stays
# pure (a byte-identical manifest out for the same bundle in).
#
# The supervisor IMAGE and the REPORT TARGET are not composed: which wrapper
# image runs and which service receives the heartbeats are facts of the
# environment the graph is placed in, not of the bundle, so the placement side
# supplies them. kci_manifest_proto reserves SupervisorSpec fields 1 and 6
# (`supervisor_image_digest`, `report_target`), so the graph has no slot for
# either.

# The platform lease/heartbeat timing defaults (seconds). The lease-check fences an
# attempt whose renew is not seen within ttl+grace; the heartbeat cadence MUST be <
# ttl. 60/10/30 = a 10s push cadence, a 60s lease, +30s slack for a transient
# network stall / a cold-start hop before LEASE_EXPIRED. Stored as `Int` comptime
# constants; wrapped `Int32(...)` at the SupervisorSpec ctor.
comptime SUPERVISOR_LEASE_TTL_SECONDS: Int = 60
comptime SUPERVISOR_HEARTBEAT_INTERVAL_SECONDS: Int = 10
comptime SUPERVISOR_GRACE_SECONDS: Int = 30


def _supervisor_spec(spec: AppSpec) raises -> SupervisorSpec:
    """SYNTHESIZE the platform-injected `SupervisorSpec` for a compute node from the
    customer `AppSpec`. The platform OWNS `mode` and the lease+heartbeat timing
    (deploy constants above); the supervisor image and report target are not
    in the graph (SupervisorSpec fields 1 and 6 are reserved): the placement side
    supplies them. The customer's four `AppSpec`
    supervisor HINTS (fields 9-12) are MERGED verbatim into `child_health_path` /
    `child_health_port` / `cpu` / `memory`. A bundle with NO hints (all empty/0)
    yields a valid DEFAULT SupervisorSpec that is byte-identical to one that omits
    the hint fields (additive-safe). PURE + DETERMINISTIC — no cloud call, no
    clock: the same AppSpec in yields a byte-identical SupervisorSpec out.
    `mode = WRAPPER` (the platform-enforced default on every cloud that lets us
    set the entrypoint; SIDECAR is a per-cloud fallback the mapper may downgrade
    to, NOT a customer choice)."""
    return SupervisorSpec(
        SupervisorMode(SupervisorMode.SUPERVISOR_MODE_WRAPPER),  # mode (platform default)
        Int32(SUPERVISOR_LEASE_TTL_SECONDS),  # lease_ttl_seconds (platform default)
        Int32(SUPERVISOR_HEARTBEAT_INTERVAL_SECONDS),  # heartbeat_interval_seconds
        Int32(SUPERVISOR_GRACE_SECONDS),  # grace_seconds (platform default)
        spec.supervisor_child_health_path.copy(),  # MERGED HINT (field 9)
        spec.supervisor_child_health_port,  # MERGED HINT (field 10)
        spec.supervisor_cpu.copy(),  # MERGED HINT (field 11, SIDECAR)
        spec.supervisor_memory.copy(),  # MERGED HINT (field 12, SIDECAR)
    )


# =============================================================================
# §1 — the API node builders. Each returns a flat `ResourceNode` value with
#      exactly one `config` oneof arm set (the arm index MUST agree with `kind`).
#      Arm indices (1-based position in the oneof):
#      1=serverless_compute 4=datastore 8=iam_role 9=secret 10=config_data …
#      15=trigger 16=invoke_grant (DEPRECATED/unemitted) 17=grant
#      18=web_frontend 19=api_edge … Each builder sets exactly one arm and
#      passes `None` for the others.
# =============================================================================


def _runtime_invoke_grant_id(runtime_identity: String, service_name: String) -> String:
    """The logical id of the runtime identity's invoke grant on its OWN service.

    ONE function so the composer and its falsifiers derive the string the same
    way — the `datastore_node_id_for` precedent. The shape is the sibling ids'
    (`<deploy>-invokes-<svc>`, `allUsers-invokes-<svc>`): `<principal>
    -invokes-<service>`, principal FIRST, because the target is what every
    `-invokes-` id on a service has in common and the principal is what
    distinguishes them."""
    return runtime_identity + String("-invokes-") + service_name


def _runtime_invoke_is_a_grant_node_on_cloud(cloud: Int) -> Bool:
    """Whether THIS cloud carries *"the runtime identity may invoke its OWN
    service"* as a SEPARATE kind-17 GRANT node, instead of INSIDE the kind-8
    IamRole node.

    THE AUTHORIZATION IS THE SAME ONE ON BOTH CLOUDS; ONLY ITS CARRIER MOVES.
    On GCP the kind-8 node IS the carrier — the GCP bridge's IamRole conformer
    calls `ensure_role_binding(runtime_identity)`, a `setIamPolicy` binding
    `roles/run.invoker` on the service. So the grant is not a manifest node
    there: it lives inside the conformer of a node whose `IamRoleSpec` is EMPTY.

    On AWS the kind-8 cell is a CLEAN SKIP — `IamRoleSpec` is empty, so the node
    has no desired state to materialize, and the identity it stands for is
    already minted by kind 11. Skipping the node would skip the only place the
    authorization exists. The AWS shape of that same authorization is an
    IDENTITY policy — `lambda:InvokeFunction` on the function ARN, written by
    `PutRolePolicy` — i.e. PRINCIPAL-side, which is a kind-17 GRANT: principal
    `<svc>-role`, `CAPABILITY_INVOKE_SERVICE`, target `<svc>-svc`.

    IT IS AN EITHER/OR, NEVER A BOTH, AND THE `else` IS THE LOAD-BEARING HALF.
    Composing the grant on GCP *in addition* to the kind-8 node would emit a
    second node asking for the binding the first one already sets — a duplicate
    `setIamPolicy` on every service, and a new content address for every bundle,
    for zero authorization gained. Emitting BOTH on AWS would compose a kind-8
    node that expresses nothing and is then reported as a gap forever: a node no
    cloud should CREATE is a node no cloud should COMPOSE.

    KEYED ON `CLOUD_AWS`, NOT ON `!= CLOUD_GCP` — the identical rule
    `_capability_is_permanently_absent_on_aws` states, for the identical reason:
    the evidence is AWS-specific (a kind-8 skip, an IAM inline policy, a Lambda
    ARN), and `CLOUD_LOCAL` IS the GCP posture run against emulators. Azure and
    Kubernetes get this answer from their own arms' adjudication or not at all;
    until then they compose the kind-8 node."""
    return cloud == CLOUD_AWS


def _validator_runs_as_the_deploy_principal_on_cloud(cloud: Int) -> Bool:
    """Whether THIS cloud's IN-ENV validate job RUNS AS the deploy principal
    (`DEPLOY_PRINCIPAL`) — i.e. whether the deploy identity needs standing
    authorizations of its own in order to VALIDATE what it just deployed.

    THIS IS A PREMISE, NOT A PREFERENCE, AND ON AWS IT IS FALSE. On GCP the
    in-cloud validator job is placed with the deploy SA as its runtime identity.
    Every authorization that job needs — `run.invoker` on the service it dials,
    `objectViewer` on the blob it reads back, `datastore.viewer` on the store it
    inspects — has to be a standing binding on THAT principal, and `compose_api`
    emits each as a kind-17 GRANT whose `principal_identity_ref` is
    `DEPLOY_PRINCIPAL`.

    On AWS there is no in-env validator yet — a `run_container` step routes to
    the LOCAL fork-exec arm, under the operator's own credentials, which need no
    composed grant — and the execution arm that will carry one does not run as
    the deploy role either.

    AND COMPOSING THEM ANYWAY MAKES THE APPLY UNABLE TO CONVERGE, PERMANENTLY. A
    grant's carrier on AWS is an INLINE POLICY ON THE PRINCIPAL'S ROLE, so a
    deploy-principal grant is a `PutRolePolicy` on the deploy role — and the AWS
    grant conformer REFUSES every mutating verb on it, for two independent
    reasons:

      * `role_externally_owned` — the role is created by an OUT-OF-BAND day-0 act
        (the customer's CloudFormation stack) and is owned outside this graph.
        Nothing here holds a credential that could write its policy set — the
        role is what grants the credential this apply runs AS.
      * `role_authorization_en_bloc` — that role's authorization is authored as
        ONE document, and it denies `iam:PutRolePolicy` on the role's own
        path-qualified ARN. An explicit Deny beats any Allow, so even an
        operator-credentialled apply plans CREATE and gets AccessDenied.

    Such a node can never materialize — no retry, no credential and no day-2 act
    closes it. A node no cloud should CREATE is a node no cloud should COMPOSE.

    IT IS A **SEPARATE** PREDICATE FROM `_runtime_invoke_is_a_grant_node_on_cloud`,
    AND MERGING THEM WOULD BE WRONG EVEN THOUGH BOTH KEY ON `CLOUD_AWS` TODAY.
    That one answers *where does the RUNTIME identity's self-invoke authorization
    live* (kind-8 node on GCP, kind-17 grant on AWS) — it says a grant IS composed
    on AWS. This one answers *does the DEPLOY identity need standing
    authorizations here at all* — it says a grant is NOT. Two different subjects,
    two different carriers: the day a cloud grows an in-env validator that runs
    as its own job identity, it needs to be able to say so without also moving
    the runtime-invoke carrier.

    KEYED ON `CLOUD_AWS`, NOT ON `== CLOUD_GCP` — the same rule
    `_runtime_invoke_is_a_grant_node_on_cloud` and
    `_capability_is_permanently_absent_on_aws` both state. The evidence is
    AWS-specific (an externally-owned IAM role, an en-bloc policy document, a Deny
    on `iam:PutRolePolicy`), and `CLOUD_LOCAL` IS the GCP posture run against
    emulators — it places the same job as the same SA, so an `== CLOUD_GCP` test
    would silently delete every local validate gate's authority.

    WHAT THIS DOES **NOT** GATE: the two trust grants
    (`-role-deploy-token-creator-grant`, `-role-deploy-sa-user-grant`) also carry
    the deploy principal, and they are NOT about validation — they are about the
    deployer being able to attach a runtime role at all. They are gated on AWS,
    one ordinal at a time, by `_capability_is_permanently_absent_on_aws` (7 and
    14), because the reason is the CAPABILITY's absence rather than the
    validator's premise. Same for `edge-gateway-sa-deploy-sa-user-grant`, gated
    inline at its own site."""
    return cloud != CLOUD_AWS


def _iam_role_node(
    var logical_id: String, var depends_on: List[String]
) raises -> ResourceNode:
    """The IamRole node (config oneof arm 8) — the identity the compute RUNS AS. It
    binds the runtime SA `roles/run.invoker` on its OWN Cloud Run service, which is a
    `setIamPolicy` ON THE SERVICE — so this node `depends_on` the service (`<name>-svc`)
    and runs LAST: the service must EXIST before its IAM policy can be set (a first
    deploy would otherwise 404 `SetIamPolicy` on a not-yet-created service). This grant
    is an INGRESS grant, NOT a boot prerequisite, so running it after the service is
    correct (the service boots without it; secret/config still run BEFORE the service).
    The spec is EMPTY (`IamRoleSpec()`): cross-resource authorizations are SEPARATE
    `Grant` nodes (see `_append_grant_nodes`).

    NOT COMPOSED ON EVERY CLOUD. On `CLOUD_AWS` this node's ONE authorization is
    composed as a kind-17 GRANT instead, because the AWS arm's kind-8 cell is a
    CLEAN SKIP and skipping the node would skip the only place the authorization
    exists. `_runtime_invoke_is_a_grant_node_on_cloud` carries the argument and
    the call site is the `else` of that branch."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_IAM_ROLE),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        8,
        None, None, None, None, None, None, None,      # arms 1-7
        Optional[IamRoleSpec](IamRoleSpec()),          # arm 8 (empty-spec identity)
        None, None, None, None, None, None, None, None, None, None, None,  # arms 9-19
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _secret_node(
    var logical_id: String,
    var depends_on: List[String],
    var handle: String,
    var capability_node: String,
    custody: Int = 0,
) raises -> ResourceNode:
    """The Secret node (config oneof arm 9) — the durable authorization record
    (the VALUE never rides in the manifest). Depends on the IamRole.

    `custody` is the authoring `SecretBinding.custody` ORDINAL, carried through
    VERBATIM (0=UNSPECIFIED/read-as-CUSTOMER, 1=CUSTOMER, 2=OPERATOR). It is the
    BINDING half of the custody predicate. The applier supplies the other half —
    is this deploy acting in somebody else's account? — at apply time, because
    that half is a property of the deploy, not of the bundle, and the same bundle
    has different answers in an operator's own project and in a customer's.
    Defaulted to 0 so a caller that authors no custody composes the CUSTOMER
    reading."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_SECRET),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        9,
        None, None, None, None, None, None, None, None,  # arms 1-8
        Optional[SecretSpec](
            SecretSpec(handle^, capability_node^, Int32(custody))
        ),  # arm 9
        None, None, None, None, None, None, None, None, None, None,  # arms 10-19
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _config_node(
    var logical_id: String,
    var depends_on: List[String],
    var values: Dict[String, String],
) raises -> ResourceNode:
    """The Config node (config oneof arm 10) — non-secret key/value config data
    (the app's literal env). Depends on the Secret."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_CONFIG),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        10,
        None, None, None, None, None, None, None, None, None,  # arms 1-9
        Optional[ConfigSpec](ConfigSpec(values^)),             # arm 10
        None, None, None, None, None, None, None, None, None,  # arms 11-19
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


# ─── THE DATASTORE NODE'S LOGICAL ID, AND ITS INVERSE ────────────────────────
#
# THE PAIR IS ONE UNIT AND LIVES IN ONE PLACE, because the MAPPER runs the
# inverse: its orphan guard recovers the OWNING SERVICE from a datastore node's
# id in order to ask whether that service composed a ServerlessCompute node. A
# second, hand-written decode there is one edit away from disagreeing with the
# encode here — and the disagreement is SILENT in the worse direction: the
# guard's message is "orphan Datastore node", so a correctly-composed deploy is
# refused with a sentence blaming the bundle.
#
# The empty-collection form is `<service>-datastore`. The GCP-side composition
# spells that same form; the two agree by construction on the only case it can
# produce.
comptime _DATASTORE_ID_SUFFIX: String = "-datastore"
comptime _DATASTORE_ID_INFIX: String = "-datastore-"


def datastore_node_id_for(service: String, collection: String) -> String:
    """The DATASTORE node's logical id for `service`'s `collection`.

    EMPTY `collection` ⇒ `<service>-datastore`, the no-collection form. NAMED ⇒
    `<service>-datastore-<collection>`, so N collection groups become N nodes
    under N DISTINCT graph keys — two nodes under one key is ONE node the engine
    applies once, i.e. a table silently never created.

    THE ID IS A GRAPH KEY, NEVER A RESOURCE NAME. The AWS arm names the table
    after the COLLECTION (`aws_datastore_table_spec_for`: "on AWS the collection
    name IS the table name … so it is never derived from the logical id: a
    derived name silently ADOPTS or COLLIDES with whatever already holds it"),
    and the GCP arm names the database from the threaded `datastore_database`.
    So changing this id moves a node in the graph and moves NO cloud object."""
    if collection.byte_length() == 0:
        return service + _DATASTORE_ID_SUFFIX
    return service + _DATASTORE_ID_INFIX + collection


def datastore_node_service_of(logical_id: String) -> String:
    """The INVERSE of `datastore_node_id_for`: the SERVICE that owns the datastore
    node `logical_id`, or `logical_id` unchanged when it is not a datastore id.

    THE SUFFIX ARM IS CHECKED FIRST AND THAT ORDER IS LOAD-BEARING. A SERVICE
    named `a-datastore-b` that authors no collection composes
    `a-datastore-b-datastore`, and an infix-first decode splits at the FIRST
    `-datastore-` and answers `a`, which is no service. Suffix-first answers
    `a-datastore-b`.

    AND ORDER ALONE IS NOT ENOUGH, WHICH IS WHY `_datastore_node_ids_for`
    REFUSES `-datastore` INSIDE EITHER COMPONENT WHEN COLLECTIONS ARE AUTHORED.
    The id is `<service>-datastore-<collection>` and it is a two-component string
    joined by a separator that either component may contain — so no ordering of
    the two arms decodes every pair. With that refusal in force this function is
    TOTAL over every id the composer can emit:

      * NO collections -> `<service>-datastore`, and the suffix arm returns
        `<service>` WHATEVER the service name contains (there is no second
        component to confuse it);
      * collections    -> `<service>-datastore-<collection>` where neither half
        contains `-datastore`, so the string cannot END with `-datastore` and its
        FIRST `-datastore-` is the separator itself.

    An id this function did not emit (a hand-composed node, a foreign manifest)
    is returned UNCHANGED rather than guessed at — the caller's `_svc_index` then
    finds no service, which is the orphan verdict such a node deserves."""
    if (
        logical_id.endswith(_DATASTORE_ID_SUFFIX)
        and logical_id.byte_length() > _DATASTORE_ID_SUFFIX.byte_length()
    ):
        return String(
            logical_id[
                byte=0 : logical_id.byte_length()
                - _DATASTORE_ID_SUFFIX.byte_length()
            ]
        )
    var at = logical_id.find(_DATASTORE_ID_INFIX)
    if at > 0:
        return String(logical_id[byte=0 : at])
    return logical_id


def _datastore_access_path_of(
    p: BundleDatastoreAccessPath,
) raises -> DatastoreAccessPath:
    """The intent-tier access path -> the RESOLVED one. A total field-for-field
    copy, and nothing else: no default, no derivation, no validation.

    EVERY BRANCH THAT COULD LIVE HERE WOULD BE A GUESS AT A KEY SCHEMA, and on
    the arm that materializes one a key schema is IMMUTABLE — the only path
    between two designs is destroy-and-recreate, which loses every row. So the
    composer carries what was AUTHORED, verbatim, and the arm that knows what a
    complete key looks like is the one that REFUSES an incomplete one by name.
    A composer that helpfully supplied `string` for an absent type would make
    that refusal unreachable and the wrong answer permanent."""
    return DatastoreAccessPath(
        p.name.copy(),
        p.partition_field.copy(),
        p.partition_field_type.copy(),
        p.ordered_field.copy(),
        p.ordered_field_type.copy(),
    )


def _datastore_node_ids_for(
    service: String, spec: AppSpec
) raises -> List[String]:
    """THE N NODE IDS ONE SERVICE'S DATASTORE COMPOSES TO — one per AUTHORED
    collection, in AUTHORED ORDER, and exactly ONE when nothing is authored.

    WHY N NODES AND NOT ONE NODE CARRYING N. A graph node is ONE resource
    (`EnvPlan.assert_accounted` — every manifest node is in exactly one list),
    and on the AWS arm a collection IS a table. So one node carrying N
    collections has no materialization that is not a SINGLE-TABLE DESIGN, i.e.
    an invented key schema — and a DynamoDB partition key is PERMANENT and
    uncorrectable, destroying every item to change.
    `aws_datastore_table_spec_for` refuses that node by count and names this
    function's job in its own refusal text: "emit one DATASTORE node per
    collection — never an arm change".

    ZERO COLLECTIONS STILL COMPOSES ONE NODE, and it is the bare
    `<service>-datastore` id. That node is what the AWS arm refuses BY NAME
    ("authors 0 collection(s)") rather than guessing a schema; the refusal is
    the honest report of an unauthored shape and is not this function's to
    resolve.

    TWO NAMES ARE REFUSED HERE, AND NEITHER IS A KEY-SCHEMA JUDGEMENT — they
    are this function's OWN graph invariant, which is why they live here while
    every field of the key schema crosses untouched (`_datastore_access_path_of`):
      * an EMPTY name has no node id to be, and would compose the bare
        `<service>-datastore` — silently colliding with the no-collection form
        and losing the collection;
      * a DUPLICATE name composes two nodes under ONE graph key, which is one
        node the engine applies once. That is a table silently never created,
        discovered at the app's first write and not at this deploy."""
    var out = List[String]()
    if len(spec.datastore_collections) == 0:
        out.append(datastore_node_id_for(service, String("")))
        return out^
    # THE SEPARATOR MAY NOT APPEAR INSIDE EITHER COMPONENT. The per-collection
    # id is `<service>-datastore-<collection>`, a two-component string joined by
    # a token either half could contain — and no ordering of
    # `datastore_node_service_of`'s two arms decodes every such pair, so a node
    # id that cannot be inverted is refused rather than composed. The mapper's
    # ORPHAN GUARD runs that inverse on every datastore node, and a wrong answer
    # there refuses a correctly-composed deploy with a message blaming the
    # bundle. This keeps the inverse TOTAL by construction.
    if service.find(_DATASTORE_ID_SUFFIX) >= 0:
        raise Error(
            String("compose: service '")
            + service
            + String(
                "' authors datastore collections AND its own name contains"
                " `-datastore`. Its per-collection node ids"
                " (`<service>-datastore-<collection>`) could not be inverted"
                " back to the service, and the mapper's orphan guard runs that"
                " inverse on every datastore node — so the deploy would be"
                " refused as an orphan with a message blaming the bundle."
                " Rename the service, or author one collection per service."
            )
        )
    for ci in range(len(spec.datastore_collections)):
        ref c = spec.datastore_collections[ci]
        if c.name.byte_length() == 0:
            raise Error(
                String("compose: service '")
                + service
                + String("' authors a collection at index ")
                + String(ci)
                + String(
                    " with an EMPTY name. The collection name is this node's"
                    " graph KEY (and, on the AWS arm, the TABLE name), so an"
                    " empty one composes the bare `<service>-datastore` id —"
                    " colliding with the no-collection form and losing the"
                    " collection entirely."
                )
            )
        if c.name.find(_DATASTORE_ID_SUFFIX) >= 0:
            raise Error(
                String("compose: service '")
                + service
                + String("' authors the collection '")
                + c.name
                + String(
                    "', whose name contains `-datastore`. That is the separator"
                    " in this node's id (`<service>-datastore-<collection>`), so"
                    " the id could not be inverted back to the service — and the"
                    " mapper's orphan guard runs that inverse on every datastore"
                    " node. Rename the collection."
                )
            )
        for pj in range(ci):
            if spec.datastore_collections[pj].name == c.name:
                raise Error(
                    String("compose: service '")
                    + service
                    + String("' authors the collection '")
                    + c.name
                    + String("' TWICE (indices ")
                    + String(pj)
                    + String(" and ")
                    + String(ci)
                    + String(
                        "). Two collections of one name compose two nodes under"
                        " ONE graph key, which is one node the engine applies"
                        " once — a store silently never created, discovered at"
                        " the app's first write rather than at this deploy."
                    )
                )
        out.append(datastore_node_id_for(service, c.name))
    return out^


def _authored_datastore_collection_names(spec: AppSpec) raises -> List[String]:
    """The AUTHORED collection names, in AUTHORED ORDER — and **EMPTY** when the
    service authors none.

    IT IS NOT `_datastore_node_ids_for` WITH A DIFFERENT RETURN TYPE, AND THE
    DIFFERENCE IS THE ZERO CASE. That function composes ONE node for a service
    that authors nothing (the bare `<service>-datastore` id), because a service
    that declares a `DatastoreNeed` gets a node whether or not it says what
    shape it is. This returns EMPTY there, because its ONE consumer — the
    READ_WRITE_DATASTORE (9) base grant's resource-scoping arm — must ask a
    different question: *did the author NAME the stores this grant is about?* An
    unnamed store has no table name on AWS (`aws_datastore_table_spec_for`
    refuses that node BY COUNT rather than inventing a key schema), so a
    RESOURCE-scoped grant on it would name a node that never materializes —
    trading a live over-grant for a permanent gap.

    NO VALIDATION HERE, DELIBERATELY. `_datastore_node_ids_for` raises on an
    empty name, a `-datastore`-containing name and a duplicate, and it runs on
    EVERY compose that reaches a datastore node — so a second copy of those three
    refusals would be a second author of one rule. This is a projection."""
    var out = List[String]()
    for ci in range(len(spec.datastore_collections)):
        out.append(spec.datastore_collections[ci].name.copy())
    return out^


def _datastore_grant_is_resource_scoped_on_cloud(cloud: Int) -> Bool:
    """Whether THIS cloud carries the runtime identity's READ_WRITE_DATASTORE (9)
    authority as N RESOURCE-scoped grants (one per authored store) instead of ONE
    DEPLOYMENT-scoped grant over the whole deployment boundary.

    THE AUTHORITY IS THE SAME ONE ON BOTH CLOUDS; ONLY ITS SCOPE MOVES — the
    `_runtime_invoke_is_a_grant_node_on_cloud` shape, one capability along. On GCP
    the DEPLOYMENT scope is EXACT: `roles/datastore.user` binds on `projects/<P>`
    and reaches every Firestore database in it, which is precisely the set the
    grant means. There is nothing to narrow, and narrowing anyway would emit N
    read-modify-write `SetIamPolicy` calls binding one member on one project N
    times, plus a new content address for every bundle, for zero authority
    gained.

    ON AWS THE SAME SCOPE IS A **DIFFERENT SET**. AWS has no project, so a
    DEPLOYMENT-scoped ordinal 9 has no exact target: whatever single table the
    mapper resolves it to, the grant then authorizes item writes on a table that
    is not this app's, and covers NONE of the tables this app composed. Scoping
    the grant to the app's own authored stores is the only exact answer.

    KEYED ON `CLOUD_AWS`, NOT ON `!= CLOUD_GCP` — the standing rule in this
    file. The evidence is AWS-specific (a DynamoDB table name, an absent project
    primitive), and `CLOUD_LOCAL` IS the GCP posture run against emulators: it
    binds the same project-scoped role, so an `!= CLOUD_GCP` test would silently
    rewrite every local deploy's datastore authority.

    IT IS A SEPARATE PREDICATE FROM `_capability_is_permanently_absent_on_aws`,
    and ordinal 9 must NEVER join that set. This is not an absence — AWS has the
    peer, the capability has a row, and the node MAPS. What is wrong is the SCOPE,
    so the answer is a resolved target, never a dropped node: gating it would
    delete the runtime's document authority from the plan entirely."""
    return cloud == CLOUD_AWS


def _datastore_collections_of(
    spec: AppSpec,
) raises -> List[DatastoreCollectionSpec]:
    """THE ONE CROSSING between the AUTHORING tier (`AppSpec.
    datastore_collections`, field 35) and the RESOLVED tier
    (`DatastoreSpec.collections`, field 4).

    Without this channel every kind-4 node would derive "authors 0
    collection(s)" — a node that MAPS successfully and materializes nothing,
    with the arm's refusal reading as a bundle's mistake rather than as an
    absent surface.

    IT IS A COPY AND IT IS TOTAL. Every field crosses or the compiler says so;
    there is no filter, no dedupe, no sort and no cardinality check. Each of
    those would be a decision, and each belongs somewhere else:
      * ORDER is AUTHORED ORDER — the composed manifest's content address is a
        hash over these bytes, so a re-ordering composer churns a new address
        for no change.
      * N IS NOT JUDGED HERE. A datastore holds N collections; the arm that
        materializes one node as exactly one table REFUSES N != 1 by count, and
        it can only say so if it is handed the N. A composer that truncated to
        the first would silently convert that stated refusal into a
        SINGLE-TABLE DESIGN, i.e. an invented, permanent key schema.
      * COMPLETENESS IS NOT JUDGED HERE either — see
        `_datastore_access_path_of`.

    A spec that authors no collection returns an EMPTY list, and the `repeated`
    encoding writes no bytes for it."""
    var out = List[DatastoreCollectionSpec]()
    for ref c in spec.datastore_collections:
        var primary: Optional[DatastoreAccessPath] = None
        if c.primary_access_path:
            primary = Optional[DatastoreAccessPath](
                _datastore_access_path_of(c.primary_access_path.value())
            )
        var secondary = List[DatastoreAccessPath]()
        for ref sp in c.secondary_access_paths:
            secondary.append(_datastore_access_path_of(sp))
        out.append(
            DatastoreCollectionSpec(
                c.name.copy(),
                primary^,
                secondary^,
                c.expiry_field.copy(),
                c.referenced,
            )
        )
    return out^


def _datastore_node(
    var logical_id: String,
    var depends_on: List[String],
    var impl: String,
    analytics_replica: Bool,
    referenced: Bool = False,
    var collections: List[DatastoreCollectionSpec] = List[
        DatastoreCollectionSpec
    ](),
) raises -> ResourceNode:
    """The Datastore node (config oneof arm 4) — the app's OLTP datastore. Emitted
    ONLY when the AppSpec declares a `DatastoreNeed` of SERVERLESS/DEDICATED (a
    NONE/UNSPECIFIED intent gets no node). `impl` is the NEUTRAL intent token
    (`serverless`/`dedicated`); the below-the-line mapper resolves it to the
    cloud's serverless DB (Firestore on GCP) and ensures the database + composite
    indexes. Sits AFTER the Config node, BEFORE the ServerlessCompute node so the
    datastore is provisioned before the served container comes up."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_DATASTORE),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        4,
        None, None, None,                              # arms 1-3
        Optional[DatastoreSpec](
            DatastoreSpec(
                impl^,
                analytics_replica,
                referenced,
                # THE COLLECTION SHAPES (field 4), AS AUTHORED
                # (`AppSpec.datastore_collections`, field 35);
                # `_datastore_collections_of` is the crossing.
                #
                # Empty when the bundle authors no collection: authoring a key
                # schema is a separate, permanent decision (see the field's own
                # comment). An empty list is the honest answer and the
                # `repeated` encoding writes no bytes — and the AWS arm REFUSES
                # a datastore that names no collection BY NAME rather than
                # guessing a schema it can never correct.
                collections^,
            )
        ),  # arm 4
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 5-19
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _bucket_node(
    var logical_id: String,
    var depends_on: List[String],
    var location: String,
    var storage_class: String,
    uniform_bucket_level_access: Bool,
    var public_access_prevention: String,
    object_expiry_days: Int32,
) raises -> ResourceNode:
    """The Bucket node (config oneof arm 13) — an app-provisioned object-store bucket
    (`AppSpec.buckets`). The bucket NAME is
    the node's own `logical_id` (GCS names are globally unique; one bucket per node);
    the name MAY carry the `${project}` token verbatim (the env-agnostic compose has
    no project — the mapper resolves it). RETENTION_DELETE (app-owned — the DEPLOY
    graph's lifecycle IS this bucket's, unlike the standing bootstrap bucket's
    RETAIN_KEEP). Ordered BEFORE the ServerlessCompute node (the service depends_on it,
    the datastore-before-service precedent). Dispatched by `map_manifest_to_graph`
    (RESOURCE_KIND_BUCKET -> make_bucket_node -> GcpBucketConformer over the EXISTING
    StorageApi seam).

    ⚠ `Retention(RETENTION_DELETE)` AND `object_expiry_days` ARE DIFFERENT AXES.
    The first says the DEPLOY may delete this BUCKET on teardown; the second says
    how long an OBJECT inside it may live before GCS deletes it. A transit store
    sets both, and neither implies the other."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_BUCKET),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        13,
        None, None, None, None, None, None, None, None, None, None, None, None,  # arms 1-12
        Optional[ResolvedBucketSpec](
            ResolvedBucketSpec(
                location^,
                storage_class^,
                uniform_bucket_level_access,
                public_access_prevention^,
                object_expiry_days,
            )
        ),  # arm 13 (bucket)
        None, None, None, None, None, None,  # arms 14-19
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


# =============================================================================
# THE MAIL-TRANSPORT SPINE — the composer for kinds 5 (QUEUE), 7 (DNS_RECORD)
# and 22 (MAIL_DOMAIN_IDENTITY).
#
# A conformer, live adapter and erase site that no composer can reach are not a
# feature, they are a file; these three functions are the composer that makes
# them reachable from an authored bundle (`AppSpec.mail_transport`).
#
# THEY ARE CLOUD-AGNOSTIC AND THEY NAME NO VENDOR. "SES", "SQS" and "Route53"
# appear in the AWS ARM and nowhere in this file. A composer that knew which
# cloud it targeted would put the manifest's neutrality in the wrong tier.
# =============================================================================


def _mail_domain_identity_node(
    var domain: String, ownership: MailIdentityOwnership
) raises -> ResourceNode:
    """The MailDomainIdentity node (kind 22) — a domain proved to a mail provider
    as one this deployment may send as and receive for.

    NO ONEOF ARM, AND THAT IS THE SCHEMA'S DECISION, NOT AN OMISSION. Kind 22
    carries its entire identity in `logical_id` (the `RESOURCE_KIND_PROJECT_SERVICE`
    shape): a spec message would hold one field duplicating the id and one more the
    conformer already defaults. So this is the only node this file emits with
    `_oneof0_case == 0`.

    AND ITS `Retention` IS LOAD-BEARING INPUT, NOT A READOUT — the ONE node
    kind where that is true. A domain identity is either the deployment's own or
    somebody else's, and the two have opposite, equally destructive failure
    modes:

        RETENTION_RETAIN_KEEP  externally owned. Adopt and observe; create, update
                               and delete all REFUSE. Deleting an identity a third
                               party verified stops THEIR mail — and against AWS
                               that delete call simply SUCCEEDS.
        RETENTION_DELETE       ours end to end. Create, converge, delete.

    UNSPECIFIED therefore RAISES rather than defaulting: there is no safe guess,
    which is exactly why the authoring tier makes it an enum the author must
    state."""
    if domain.byte_length() == 0:
        raise Error(
            "compose: `mail_transport.domain` is EMPTY. The domain IS the"
            " MailDomainIdentity node's logical_id (kind 22 sets no oneof arm),"
            " so an empty one is not a weaker node — it is an unaddressable one"
        )
    if domain.find(String("@")) >= 0:
        # A MAILBOX IS NOT A DOMAIN, and this is not a formatting nit. An
        # address verifies as an EMAIL identity — a different resource, with
        # different verification and a different blast radius — so stripping the
        # local part would silently compose a node for something the author did
        # not ask for, against a conformer written for the other kind.
        raise Error(
            "compose: `mail_transport.domain` is '"
            + domain
            + "', which carries an '@' — that is a MAILBOX, not a domain. A"
            " mailbox verifies as an EMAIL identity: a different resource, with"
            " different verification and different blast radius. Author the"
            " DOMAIN ('example.com'), not an address in it"
        )
    var retention = Retention(Retention.RETENTION_DELETE)
    if ownership.value == MailIdentityOwnership.MAIL_IDENTITY_OWNERSHIP_EXTERNAL:
        retention = Retention(Retention.RETENTION_RETAIN_KEEP)
    elif ownership.value != MailIdentityOwnership.MAIL_IDENTITY_OWNERSHIP_OURS:
        raise Error(
            "compose: `mail_transport.identity_ownership` is UNSPECIFIED for"
            " domain '"
            + domain
            + "'. It is REQUIRED and is NOT defaulted, because both answers are"
            " destructive in opposite directions: guessing OURS makes the"
            " deploy's teardown delete an identity somebody else verified (which"
            " stops THEIR mail, and the delete call SUCCEEDS), and guessing"
            " EXTERNAL leaves a domain we own unverified (which stops OURS)."
            " State MAIL_IDENTITY_OWNERSHIP_OURS or"
            " MAIL_IDENTITY_OWNERSHIP_EXTERNAL"
        )
    return ResourceNode(
        domain^,
        ResourceKind(ResourceKind.RESOURCE_KIND_MAIL_DOMAIN_IDENTITY),
        List[String](),  # a graph ROOT — the identity precedes everything
        retention,
        0,  # NO oneof arm set (kind 22 carries its identity in logical_id)
        None, None, None, None, None, None, None, None, None, None,  # arms 1-10
        None, None, None, None, None, None, None, None, None, None,  # arms 11-20
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _queue_node(
    var logical_id: String, var queue_name: String, var depends_on: List[String]
) raises -> ResourceNode:
    """The Queue node (kind 5, oneof arm 5) — the queue accepted inbound mail
    lands in.

    ONE NODE FOR ONE QUEUE. A dead-letter queue is a CLOUD RENDERING decision,
    not a manifest statement: the AWS arm derives `<name>-dlq` as a companion,
    and a GCP arm would answer the same sentence with a subscription's
    `deadLetterPolicy` — a FIELD, not a second resource. Composing the DLQ here
    would make the spec unmappable onto the cloud whose primitive has the other
    shape, which is the exact failure the kind/arm split exists to prevent.

    RETENTION_RETAIN_KEEP, AND IT IS NOT A DEFAULT SOMEBODY PICKED. A queue
    holds messages whose senders were already told delivery was accepted, so a
    node declaring RETENTION_DELETE would be a declaration the conformer ignores —
    a lie the plan would print.

    AND THE MANIFEST'S CODE IS THE STRONGEST ONE THE PROTO CAN SPELL, NOT THE
    CONFORMER'S ANSWER. The queue conformer reports RETAIN_UNDELETABLE
    unconditionally — a CAPABILITY statement no flag overrides, because both
    fences (the conformer and the live queue adapter's delete) refuse. The proto
    `Retention` carries only the two POLICY members by design (a manifest states
    INTENT; only the conformer knows whether a delete path exists), so
    RETAIN_KEEP here is the closest true thing a bundle can author and the
    conformer strengthens it. Do NOT add an UNDELETABLE member to the proto: it
    would let a bundle CLAIM a capability boundary the conformer is the only
    thing that can know about."""
    if queue_name.byte_length() == 0:
        raise Error(
            "compose: `mail_transport.inbound_queue` is EMPTY on a node that was"
            " asked for. A queue is addressed BY NAME, and the empty name"
            " resolves to no queue while being a perfectly well-formed request"
        )
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_QUEUE),
        depends_on^,
        Retention(Retention.RETENTION_RETAIN_KEEP),
        5,
        None, None, None, None,  # arms 1-4
        Optional[QueueSpec](QueueSpec(queue_name^)),  # arm 5 (queue)
        None, None, None, None, None,  # arms 6-10
        None, None, None, None, None,  # arms 11-15
        None, None, None, None, None,  # arms 16-20
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _dns_record_node(
    var logical_id: String,
    var depends_on: List[String],
    var record_name: String,
    var record_type: String,
    var target: String,
) raises -> ResourceNode:
    """One DnsRecord node (kind 7, oneof arm 7) — a record that proves, routes or
    scopes the mail domain.

    NO TTL AND NO ZONE, because `DnsRecordSpec` has neither. The hosted zone is
    RESOLVED from the record name against the account by the conformer (whose own
    header states why carrying one here would be a guess); the TTL is that
    conformer's stated default.

    RETENTION_DELETE. Unlike the identity above, a record is a statement THIS
    deploy publishes and may retract — its whole content is derivable from this
    manifest. The externally-owned axis lives on the IDENTITY, which is the
    resource whose deletion is irreversible for a third party.

    THE TYPE AND THE WIRE-SAFETY OF THESE THREE STRINGS ARE NOT CHECKED HERE.
    They are checked by the conformer, BY NAME, with a sentence about what the
    provider does with the value — and a second copy in the composer is the one
    that would go stale. What IS checked here is the pair that has no meaning at
    any later layer: an empty name or an empty type produces a node with no
    identity, and the graph keys on that."""
    if record_name.byte_length() == 0:
        raise Error(
            "compose: a `mail_transport.dns_records` entry carries an EMPTY"
            " `record_name`. Name and type together ARE the record set's"
            " identity, so an empty name is un-addressable rather than partial"
        )
    if record_type.byte_length() == 0:
        raise Error(
            "compose: the `mail_transport.dns_records` entry for '"
            + record_name
            + "' carries an EMPTY `record_type`. A record set is keyed on"
            " (name, type) — half a key is not a weaker record, it is a"
            " different one"
        )
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_DNS_RECORD),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        7,
        None, None, None, None, None, None,  # arms 1-6
        Optional[DnsRecordSpec](
            DnsRecordSpec(record_name^, record_type^, target^)
        ),  # arm 7 (dns_record)
        None, None, None,  # arms 8-10
        None, None, None, None, None,  # arms 11-15
        None, None, None, None, None,  # arms 16-20
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def mail_transport_queue_logical_id(mt: MailTransportSpec) -> String:
    """The QUEUE node's graph key: the AUTHORED `inbound_queue_logical_id`, else
    `<inbound_queue>-queue`.

    THE AUTHORED FORM EXISTS SO A MANIFEST-DRIVEN APPLY CAN **ADOPT** A LIVE
    QUEUE. If a queue already exists under another graph key, a composed node
    under a derived key would be a SECOND node for the SAME cloud queue, and two
    graph nodes under two keys holding one resource converge whichever ran last.
    Authoring the id is how a bundle says "this is that one"."""
    if mt.inbound_queue_logical_id.byte_length() > 0:
        return mt.inbound_queue_logical_id.copy()
    return mt.inbound_queue + String("-queue")


def mail_transport_dns_logical_id(
    domain: String, record_name: String, record_type: String
) -> String:
    """The DnsRecord node's graph key: `<domain>-dns-<type>-<name>`.

    THE **TYPE** IS IN THE KEY, and it has to be. A domain publishes an MX and
    a TXT at the SAME name (the apex), which are two different record sets; a key
    derived from the name alone would give them one graph node, one intent-ledger
    entry, and a converge that overwrites whichever ran last with the other's
    value. That is the same collision the AWS arm refuses for a derived DLQ id,
    reached by a different road."""
    return (
        domain
        + String("-dns-")
        + record_type.lower()
        + String("-")
        + record_name
    )


def _append_mail_transport_nodes(
    spec: AppSpec, mut nodes: List[ResourceNode]
) raises:
    """Append this service's MAIL-TRANSPORT node set — {MailDomainIdentity ->
    Queue -> DnsRecord x N} — in that topo order.

    THE ORDER IS THE PROOF ORDER, NOT AN AESTHETIC. The identity is a graph
    ROOT; every DNS record depends_on it, because the records exist to PROVE the
    identity and a record published for an identity that does not exist proves
    nothing while applying cleanly. The queue depends on the identity for the
    same reason in the other direction: inbound mail is only accepted for a
    verified domain, so a queue standing before one is a queue nothing can fill.

    ABSENT `mail_transport` ⇒ NOTHING appended ⇒ the manifest is BYTE-IDENTICAL
    to one composed without the field, which is the additive-safe property the
    golden content-address guard pins."""
    if not spec.mail_transport:
        return
    var mt = spec.mail_transport.value().copy()
    var domain = mt.domain.copy()
    nodes.append(_mail_domain_identity_node(domain.copy(), mt.identity_ownership))
    # ── THE INBOUND QUEUE. EMPTY name ⇒ NO node: a send-only domain is a
    #    legitimate authoring (it just receives nothing), and composing a queue
    #    for it would provision a resource nothing ever reads.
    if mt.inbound_queue.byte_length() > 0:
        var q_deps = List[String]()
        q_deps.append(domain.copy())
        nodes.append(
            _queue_node(
                mail_transport_queue_logical_id(mt),
                mt.inbound_queue.copy(),
                q_deps^,
            )
        )
    # ── THE PROVING RECORDS, in AUTHORED ORDER, so the plan an operator reads is
    #    in the order the bundle was written.
    for i in range(len(mt.dns_records)):
        var rec = mt.dns_records[i].copy()
        var d_deps = List[String]()
        d_deps.append(domain.copy())
        nodes.append(
            _dns_record_node(
                mail_transport_dns_logical_id(
                    domain, rec.record_name, rec.record_type
                ),
                d_deps^,
                rec.record_name.copy(),
                rec.record_type.copy(),
                rec.target.copy(),
            )
        )


def _run_to_completion_job_node(
    var logical_id: String,
    var depends_on: List[String],
    var image_digest: String,
    # `JobSpec.args` -> `RunToCompletionJobSpec.args`. Placed here to MIRROR the
    # resolved message's own field order (image_digest = 1, args = 2), so the two
    # positional lists cannot drift.
    var args: List[String],
    var runtime_identity: String,
    var env: Dict[String, String],
    var secret_handles: List[String],
    var max_retries: Optional[Int32],
    task_timeout_seconds: Int32,
    var region: String,
) raises -> ResourceNode:
    """The RunToCompletionJob node (config oneof arm 2) — a container the deploy
    SHIPS into the target project to run once and exit (`AppBundle.jobs[]`).

    A ONE-SHOT JOB IS A DEPLOY, so it is a NODE and not a CLI flag: it carries a
    retention policy, an identity, bound secrets and a pinned image exactly as the
    served node does. What differs is the LIFETIME of the workload, not the nature
    of the act.

    AND THE NODE DOES NOT RUN IT. `create`/`update` converge the Job's
    DEFINITION; starting an execution is the `ValidateStep.execute_job` gate. That
    split is what keeps the applier idempotent — a re-apply that changes nothing
    must not re-run the job.

    RETENTION_DELETE (app-owned — the deploy graph's lifecycle IS this job's),
    matching every other app-owned node. `depends_on` is wired by the caller
    (`_append_job_nodes`) to the sibling services the job's env references, so the
    job is defined only after the services it will call exist."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_RUN_TO_COMPLETION_JOB),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        2,
        None,  # arm 1 (serverless_compute)
        Optional[RunToCompletionJobSpec](
            RunToCompletionJobSpec(
                image_digest^,
                # THE AUTHORED ARGV (`JobSpec.args = 9`), so a bundle author
                # configures a job by flags rather than only by environment
                # variables.
                #
                # EMPTY IS MEANINGFUL AND THE DEFAULT: a job authoring no `args`
                # runs its image's baked ENTRYPOINT.
                args^,
                runtime_identity^,
                # `supervisor` — NONE. The platform liveness harness is injected
                # by the placement path of a placed workload, not onto a
                # bundle-declared gate job whose exit code IS its verdict.
                None,
                env^,
                secret_handles^,
                max_retries^,
                task_timeout_seconds,
                region^,
            )
        ),  # arm 2 (run_to_completion_job)
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 3-19
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _authored_network_ingress(spec: AppSpec) -> Optional[Int32]:
    """The bundle's AUTHORED network reach as the presence-typed ordinal the
    ServerlessCompute node carries, or None when the bundle authored none.

    THE TWO STATES ARE NOT THE SAME AND THE NODE MUST KEEP THEM APART.
    UNSPECIFIED means "this bundle said nothing about network reach", and the
    deploy's correct response is to touch nothing — leave the live service's
    ingress exactly as it found it. Collapsing that onto an ordinal 0 in the node
    would also append a zero varint to every ServerlessCompute node's wire form
    and move the manifest's content address, which `test_compose_api` pins."""
    if spec.network_ingress.value == 0:
        return None
    return Optional[Int32](Int32(spec.network_ingress.value))


def _authored_cpu(spec: AppSpec, service: String) raises -> Optional[String]:
    """The bundle's AUTHORED cpu allocation as the presence-typed quantity string
    the ServerlessCompute node carries, or None when the bundle declared none.

    THE APP DECLARES ITS OWN ALLOCATION, AND WITHOUT IT A SERVED APP CANNOT BE
    BILLED AT ALL. Billing multiplies a usage INTERVAL by an ALLOCATION; `compute`
    is a serverless/serverful ENUM and the `supervisor_*` hints are the
    SIDECAR's, so this is where the bundle states the app's own allocation.

    AND IT IS CARRIED VERBATIM, NOT CONVERTED. The string stays in the ONE
    Kubernetes-quantity vocabulary the placement and billing records speak, so no
    second unit system exists on this path.

    ABSENT IS CARRIED THROUGH AS ABSENT — NEVER DEFAULTED. This is the half that
    matters most: a fabricated "0m" is an un-billed customer and is
    byte-identical to an idle one, and substituting one here would make the read
    side's loud refusal unreachable. So an omitted field composes an UNSET node
    field, and the fault surfaces at the bill, by name, once.

    AN AUTHORED-EMPTY `cpu: ""` IS A REFUSAL, BY NAME, HERE. This is the
    absent-vs-empty seam and it is why the field is presence-typed all the way
    down: "" is a value a bill will happily carry and an omission is not, so the
    two may not arrive as the same bytes. Refusing at COMPOSE is the last point
    at which the fault is still attributable to the thing that caused it (the
    bundle), and compose runs before any cloud call, so `kci <app> plan` shows
    it.

    WHAT THIS DOES **NOT** DO: it does not parse the quantity, so a
    STATED-BUT-MALFORMED value ("1k", "1e3", "256 m") is carried, not refused.
    The quantity parser belongs to the consumer that writes the allocation, and
    this package's dep closure is deliberately a pure proto->proto value
    transform; hand-rolling a second grammar here would be a second author of
    one rule. So the malformed arm stays with the one parser, which refuses it
    at the write."""
    if not spec.cpu:
        return None
    var v = spec.cpu.value()
    if v.byte_length() == 0:
        raise Error(
            String("compose: service '")
            + service
            + String(
                "' authored `cpu: \"\"` — an EMPTY compute allocation. REFUSED:"
                " 'the bundle said nothing about cpu' and 'the bundle asked for"
                " an empty amount of cpu' are different statements, and only the"
                " first one is representable downstream (the durable allocation"
                " column is NULLable precisely so \"\" never becomes a number on"
                " a bill). Either OMIT the field, or state a Kubernetes quantity"
                " (\"1000m\" / \"0.5\" / \"2\")."
            )
        )
    return Optional[String](v)


def _authored_memory(spec: AppSpec, service: String) raises -> Optional[String]:
    """The bundle's AUTHORED memory allocation, or None when it declared none.

    The `_authored_cpu` SIBLING and INDEPENDENT of it, deliberately: `place_one`
    reads `ContainerSpec.cpu` and `.memory` with two separate presence tests and
    `record_intent` refuses each on its own, so a bundle may state one without
    the other and compose must not invent a pairing rule the write side does not
    have. Same verbatim carry, same absent-is-absent rule, same authored-empty
    refusal, same stated-but-malformed residual (see `_authored_cpu`)."""
    if not spec.memory:
        return None
    var v = spec.memory.value()
    if v.byte_length() == 0:
        raise Error(
            String("compose: service '")
            + service
            + String(
                "' authored `memory: \"\"` — an EMPTY compute allocation."
                " REFUSED for the reason `cpu: \"\"` is (see `_authored_cpu`):"
                " an omission and an empty quantity are different statements and"
                " must not arrive as the same bytes. Either OMIT the field, or"
                " state a Kubernetes quantity (\"512Mi\" / \"1Gi\")."
            )
        )
    return Optional[String](v)


def _authored_health_check_path(
    spec: AppSpec, service: String
) raises -> Optional[String]:
    """The bundle's AUTHORED healthcheck endpoint as the presence-typed path the
    ServerlessCompute node carries, or None when the bundle declared none.

    THE APP DECLARES WHAT THE PLACEMENT SERVICE SHOULD ASK IT. Without this, a
    registry that moves a resource PROVISIONING -> ACTIVE does so on CLOUD
    EXISTENCE alone — and a Cloud Run service HAS a URL, and enumerates, the
    instant the create is accepted, before the revision is READY and before the
    container has opened a socket. So `ACTIVE` would mean "the cloud accepted
    the create" while every reader of it reads "the app is serving". This is
    where the bundle states the endpoint that makes ACTIVE mean that.

    ABSENT IS CARRIED THROUGH AS ABSENT — NEVER DEFAULTED TO `/healthz`. An app
    that declared no healthcheck is `NOT_GATED`: its resource is adopted on
    cloud existence, and the verdict SAYS `NOT_GATED` rather than dressing it up
    as a health PASS nobody observed. Substituting a path here would instead
    produce a give-up verdict for an app that never asked to be probed there, a
    fail-closed deploy with the container healthy.

    AN AUTHORED-EMPTY `health_check_path: ""` IS A REFUSAL, BY NAME, HERE.
    This is the absent-vs-empty seam and it is why the field is presence-typed
    all the way down: "the bundle said nothing" and "the bundle asked us to probe
    the empty path" are different statements and must not arrive as the same
    bytes. Refusing at COMPOSE is the same choice `_authored_cpu` makes — the
    last point at which the fault is still attributable to the bundle that caused
    it, and before any cloud call, so `kci <app> plan` shows it.

    WHAT THIS DOES **NOT** DO: it does not require a leading `/`, and it does
    not check that the app actually serves the path. The second is unknowable at
    compose time by construction, and it is exactly what the placement side's
    gate observes at run time — where a wrong path surfaces as a give-up verdict
    naming the path it probed, rather than as a silent pass."""
    if not spec.health_check_path:
        return None
    var v = spec.health_check_path.value()
    if v.byte_length() == 0:
        raise Error(
            String("compose: service '")
            + service
            + String(
                "' authored `health_check_path: \"\"` — an EMPTY healthcheck"
                " endpoint. REFUSED: 'the bundle declared no healthcheck' and"
                " 'the bundle asked the placement service to probe the empty path'"
                " are different statements, and only the first one is"
                " representable downstream (an UNSET node field is the"
                " NOT_GATED policy). Either OMIT the field — the app is then"
                " adopted on cloud existence, as it was before the field"
                " existed — or state the path the app actually serves"
                " (\"/healthz\")."
            )
        )
    return Optional[String](v)


def _authored_network_egress(spec: AppSpec) -> Optional[NetworkEgressSpec]:
    """The bundle's AUTHORED outbound path as the resolved-tier message the
    ServerlessCompute node carries, or None when the bundle authored none.

    A TIER CROSSING BY COPY, NOT A TRANSLATION. `AppSpec.network_egress` is an
    intent-tier `ValidateVpcEgress`; the node carries a `NetworkEgressSpec`
    declared in `full_manifest.proto` (which imports nothing, so the intent
    message cannot be named there — the same crossing `_authored_network_ingress`
    makes with the `NetworkIngress` enum). The four values move across verbatim,
    IN THE SAME POLARITY: `private_ranges_only` stays `private_ranges_only`, so
    the two tiers cannot drift into meaning opposite things. The ONE inversion to
    Cloud Run's `VpcAccess.VpcEgress` happens at the render, once.

    COMPOSE NEVER INVENTS A VALUE HERE, for the reason `_authored_network_
    ingress` states: substituting a default would change the network path of
    every bundle on its next deploy. Absent stays absent — and a SUBMESSAGE
    field, unlike a plain scalar, writes NOTHING to the wire when unset, so a
    bundle that authors none composes an unchanged content address."""
    if not spec.network_egress:
        return None
    ref a = spec.network_egress.value()
    var tags = List[String]()
    for i in range(len(a.network_tags)):
        tags.append(a.network_tags[i])
    return Optional[NetworkEgressSpec](
        NetworkEgressSpec(
            a.network, a.subnetwork, tags^, a.private_ranges_only
        )
    )


def _cloud_carries_min_scale(cloud: Int) -> Bool:
    """Whether a compute node's authored `min_scale` is a thing THIS cloud can
    hold — the ONE place the answer is written (bundles do NOT author
    `min_scale` per cloud).

    FALSE ON CLOUD_AWS ONLY, and the reason is a product fact rather than a
    missing arm: Lambda has NO minimum-scale knob. Warm capacity there is
    PROVISIONED CONCURRENCY — a separate resource, with its own lifecycle and
    its own standing bill — so there is no field on any Lambda create/update
    body for this number to land in. The AWS compute arm refuses
    `min_scale > 0`, which is correct for the ARM and would make every AWS-bound
    compute node with one authored cell UNMAPPABLE in a bundle that must serve
    BOTH clouds.

    ⇒ THE CONDITIONAL BELONGS BELOW THE LINE, NOT IN N BUNDLES. This is the
    PROJECT_SERVICE gate's own rule — "a node no cloud should CREATE is a node
    no cloud should COMPOSE" — applied to a FIELD instead of to a node, and it
    lives beside the per-cloud GRANT gate for exactly that reason. The
    alternative (an `if aws:` in every bundle authoring `scaling { min: 1 }`)
    puts a cloud name in a customer-facing intent file and goes stale one bundle
    at a time.

    KEYED ON `CLOUD_AWS`, NOT ON `!= CLOUD_GCP` — the grant gate's rule
    verbatim, and for the same reason: `!= CLOUD_GCP` would be WRONG for
    CLOUD_LOCAL, which is the GCP posture run against emulators (the env
    registry puts CLOUD_LOCAL in the Google family) and whose Cloud Run render
    carries `min_scale` perfectly well. Azure/Kubernetes need their own arm's
    adjudication, never an extrapolation from Lambda's.

    TWO-SIDED, AND THE CATASTROPHIC IMPLEMENTATION RETURNS FALSE EVERYWHERE:
    that silently scale-to-zeros every GCP service that paid for a warm
    instance, and the only symptom is a cold start on a path nobody is
    watching. The falsifier therefore states the GCP side as the AUTHORED
    NUMBER, never as "> 0"."""
    return cloud != CLOUD_AWS


def _serverless_node(
    var logical_id: String,
    var depends_on: List[String],
    var image_digest: String,
    port: Int32,
    min_scale: Int32,
    max_scale: Int32,
    var runtime_identity: String,
    var supervisor: Optional[SupervisorSpec],
    var keep_last_n: Optional[Int32],
    var args: List[String],
    var network_ingress: Optional[Int32],
    var network_egress: Optional[NetworkEgressSpec],
    cloud: Int,
    # THE APP'S DECLARED COMPUTE ALLOCATION — the `AppSpec.cpu`/`.memory` the
    # bundle authored, already read through `_authored_cpu` / `_authored_memory`
    # (which own the authored-empty refusal). Presence-typed BOTH SIDES of this
    # boundary: this builder NEVER substitutes a value, because a fabricated
    # allocation is an amount a customer never asked for, billed.
    # NO DEFAULT, FOR THE REASON `cloud` HAS NONE (see the docstring): a
    # defaulted parameter is a gate the compiler cannot hold. A compute node
    # added tomorrow must SAY what allocation it carries — including saying
    # `None` — rather than inherit an omission nobody wrote down.
    var cpu: Optional[String],
    var memory: Optional[String],
    # THE APP'S HEALTHCHECK ENDPOINT — the `AppSpec.health_check_path` the
    # bundle authored, already read through `_authored_health_check_path` (which
    # owns the authored-empty refusal). Presence-typed BOTH SIDES: this builder
    # NEVER substitutes a path, because a fabricated one produces a GIVE-UP
    # verdict for an app that never asked to be probed there.
    # NO DEFAULT, for the reason `cloud` and `cpu` have none: a defaulted
    # parameter is a gate the compiler cannot hold. A compute node added tomorrow
    # must SAY whether it carries a healthcheck — including saying `None`.
    var health_check_path: Optional[String],
) raises -> ResourceNode:
    """The ServerlessCompute node (config oneof arm 1) — the served container.
    Depends on the Config; runs AS the IamRole (`runtime_identity`). Carries the
    platform-INJECTED `supervisor` synthesized by `_supervisor_spec` at the call
    site — the per-attempt liveness harness, never customer-authored.

    THE `min_scale` GATE LIVES IN THIS BODY, NOT AT THE CALL SITES, AND THAT
    EXCLUSIVITY IS THE WHOLE VALUE. When a per-cloud predicate is consulted by
    SOME of the sites that emit the thing it governs, adding a member to it
    changes nothing and the predicate becomes a list nobody reads. `cloud` is
    therefore REQUIRED here (no default — a defaulted cloud is a wrong answer
    that compiles), every `_serverless_node` call routes through this one
    branch, and a compute node added tomorrow is gated with no edit at all.

    AND THE WITHHOLD IS RECORDED, NEVER JUST PERFORMED. When the gate fires
    on a non-zero authored value, `min_scale` goes out as 0 AND
    `withheld_min_scale` carries the authored number, so the plan can SAY that a
    latency contract was not carried. A withhold with no record is the OMISSION
    class — a green plan for a service that is not the one the bundle
    describes."""
    var carried_min_scale = min_scale
    var withheld_min_scale = Optional[Int32](None)
    if not _cloud_carries_min_scale(cloud) and min_scale > 0:
        carried_min_scale = Int32(0)
        withheld_min_scale = Optional[Int32](min_scale)
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_SERVERLESS_COMPUTE),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        1,
        Optional[ServerlessComputeSpec](
            ServerlessComputeSpec(
                image_digest^,
                port,
                carried_min_scale,
                max_scale,
                runtime_identity^,
                # The platform-synthesized SupervisorSpec (field 6) — merged
                # AppSpec hints + platform defaults (mode/timing). Attached to
                # EVERY resolved compute node.
                supervisor^,  # supervisor
                # RETENTION (field 7): the keep-last-N revisions bound threaded from
                # AppSpec.keep_last_n (UNSET flows through; the mapper applies the
                # kci default).
                keep_last_n^,  # keep_last_n
                # THE RESOLVED PARAMETER ARGV (field 8) — one `--<flag>=<value>`
                # token per parameter that resolved, in BUNDLE DECLARATION
                # ORDER. EMPTY for a bundle that declares no `parameters`.
                args^,  # args
                # THE NETWORK REACH ORDINAL (field 9) — the
                # `AppSpec.network_ingress` the bundle AUTHORED, carried as the
                # raw `NetworkIngress` ordinal (full_manifest.proto imports
                # nothing, so the typed enum cannot be named there — the
                # `runtime_extra_capabilities` crossing, in the other direction).
                # UNSET == the bundle authored none == STAMP NOTHING.
                # PRESENCE-typed, not a zero sentinel: this encoder writes plain
                # scalars unconditionally, so a zero would append bytes to every
                # node and move the golden content address.
                network_ingress^,  # network_ingress
                # THE OUTBOUND PATH (field 10) — the `AppSpec.network_egress`
                # the bundle AUTHORED, carried as the resolved-tier
                # `NetworkEgressSpec`. UNSET == the bundle authored none ==
                # RENDER NOTHING, and a submessage writes no bytes when unset so
                # the golden content address does not move.
                network_egress^,  # network_egress
                # THE WITHHELD LATENCY CONTRACT (field 11) — the `min_scale`
                # this BUNDLE AUTHORED on a wave whose cloud cannot carry it.
                # Set by the gate at the top of this body, and by NOTHING else.
                # UNSET on every GCP/LOCAL composition and on every AWS node
                # whose bundle authored min_scale 0 ⇒ a presence-typed field
                # writes no bytes.
                withheld_min_scale^,  # withheld_min_scale
                # THE APP'S DECLARED COMPUTE ALLOCATION (fields 12-13) — the
                # bundle's own cpu/memory, carried VERBATIM in the
                # Kubernetes-quantity vocabulary the allocation records speak,
                # so the declared value hands straight through with no
                # conversion.
                #
                # UNSET STAYS UNSET. A presence-typed `optional string` writes
                # NO bytes when absent — and, far more importantly, the absence
                # reaches the bill AS an absence, which billing refuses loudly.
                # A default here would bill a number nobody asked for.
                cpu^,  # cpu (field 12)
                memory^,  # memory (field 13)
                # THE APP'S HEALTHCHECK ENDPOINT (field 14) — the path the
                # placement service probes from OUTSIDE the container to decide
                # whether the resource may become ACTIVE. Carried VERBATIM;
                # UNSET stays UNSET, which writes no bytes and is the
                # `NOT_GATED` policy (adopt on cloud existence, and SAY that is
                # what happened) rather than a default anyone could mistake for
                # a health observation.
                health_check_path^,  # health_check_path (field 14)
            )
        ),  # arm 1
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 2-19
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _grant_node(
    var logical_id: String,
    var principal_identity_ref: String,
    var target_service_logical_id: String,
    var depends_on: List[String],
) raises -> ResourceNode:
    """The unified Grant node (config oneof arm 17) — a CROSS-SERVICE invoke
    grant. Authorizes the CALLER service's runtime identity
    (`principal_identity_ref` == the SA the caller runs as = its `<S>-role`) the
    generic `CAPABILITY_INVOKE_SERVICE` on the CALLEE served node
    (`target_service_logical_id` == `<T>-svc`). A SEPARATE ordered node (the
    grant is a policy on the CALLEE's OWN resource with the caller as member, so
    it must apply AFTER the callee exists) that `depends_on` the callee —
    grant-after-target-exists. RETENTION_DELETE (app-owned). Vendor-neutral: the
    node carries ONLY the generic `Capability`; the concrete cloud role
    terminates in the conformer. Dispatched by `map_manifest_to_graph`
    (RESOURCE_KIND_GRANT -> make_grant_node -> the cloud's grant conformer)."""
    # field 4 `scope`, computed BEFORE the ctor so it does
    # not depend on argument-evaluation order against the `^` moves below.
    # ALWAYS a named callee, so always `RESOURCE` — but DERIVED rather than
    # written as a literal, because a literal is what would go stale if this arm
    # ever composed a target-less invoke.
    var scope = checked_grant_scope(
        grant_scope_for(
            Capability.CAPABILITY_INVOKE_SERVICE, target_service_logical_id
        ),
        String("invoke grant '") + logical_id + String("'"),
    )
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_GRANT),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        17,
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 1-16
        Optional[GrantSpec](
            GrantSpec(
                principal_identity_ref^,
                Capability(Capability.CAPABILITY_INVOKE_SERVICE),
                target_service_logical_id^,
                Optional[GrantScope](scope^),
            )
        ),  # arm 17 (grant)
        None,  # arm 18 (web_frontend)
        None,  # arm 19 (api_edge)
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _api_edge_node(
    var logical_id: String,
    var backend_logical_id: String,
    route_mode: Int,
    var route_path: String,
    edge_auth_mode: Int,
    var depends_on: List[String],
    var secured_routes: List[SecuredEdgeRoute] = List[SecuredEdgeRoute](),
    var gateway_service_account: String = String(""),
    var gateway_region: String = String(""),
    var allowed_sources: List[String] = List[String](),
    enable_required_services: Bool = False,
    var identity_issuer: String = String(""),
    var identity_audience: String = String(""),
    var developer_access_principal: String = String(""),
) raises -> ResourceNode:
    """The ApiEdge node (config oneof arm 19, field 23): ONE composite node
    giving exactly ONE served node a client-facing entry, realized per target
    by that target's conformer (the GCP gateway trio; ZERO resources on
    direct/on-prem). RETENTION_DELETE (the edge holds no data/domain/cert and is
    deterministically recreatable — the registry is the URL source of truth).
    `depends_on` = [backend_logical_id], ORDERING-only (the live backend address
    flows via the output->input accumulator seam at apply time, never authored).
    Per-MODE logical ids (`<backend>-inbound-edge` / `<backend>-client-edge`)
    keep a webhook inbound edge and a client edge coexisting on one backend.
    Vendor-neutral: NO vendor product rides here.

    THE LAST THREE (`identity_issuer` / `identity_audience` /
    `developer_access_principal`) are the PEER-ONLY edge's inputs. All three
    EMPTY — every bundle that authors no `EDGE_CALLER_CLASS_PEER_INTERNAL` —
    composes a node byte-identical to one that omits them. The third is refused
    by `_wave_developer_access_principal` unless the caller's environment
    definition allows developer access, so it cannot arrive here for an env
    that does not.

    THE FOUR BEFORE THOSE are the ingress REALIZATION inputs (`AppSpec.ingress`).
    They arrive from the bundle and terminate in the conformer, so the gateway
    SA, region, allowed sources and required-service enablement are authored
    rather than supplied from outside the manifest. EMPTY/DEFAULT on all four
    (every bundle that authors no `ingress {}` block) composes a node
    byte-identical to one that omits them."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_API_EDGE),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        19,
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 1-18
        Optional[ApiEdgeSpec](
            ApiEdgeSpec(
                backend_logical_id^,
                RouteMode(route_mode),
                route_path^,
                EdgeAuthMode(edge_auth_mode),
                secured_routes^,
                gateway_service_account^,
                gateway_region^,
                allowed_sources^,
                enable_required_services,
                # ── identity_issuer / identity_audience (fields 10-11) ────────
                #
                # The issuer must SERVE its EC key set at the well-known
                # identity JWKS path, so an edge configured with
                # `x-google-jwks_uri: <issuer>/.well-known/identity-jwks.json`
                # fetches a document that is there. That is the issuer's
                # contract, not this composer's.
                #
                # This mode is reached only by a bundle that AUTHORS
                # `EDGE_CALLER_CLASS_PEER_INTERNAL` on a wave that names an
                # issuer, so no other bundle composes differently.
                identity_issuer^,
                identity_audience^,
                # The AUTHENTICATED DEVELOPER-ACCESS principal. Non-empty ONLY
                # for an env whose definition allows developer access —
                # `_append_api_edge_nodes` refuses to reach here with a value
                # otherwise, so this parameter cannot be the place such an edge
                # acquires one.
                developer_access_principal^,
            )
        ),  # arm 19 (api_edge, field 23)
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _wave_api_edge_enabled(bundle: AppBundle, env: String) -> Bool:
    """Whether the wave for `env` has its API-EDGE staging toggle ON
    (`Wave.api_edge_enabled`). No wave for `env` (or the toggle unset) => OFF:
    the edge is strictly OPT-IN per wave."""
    for i in range(len(bundle.waves)):
        if bundle.waves[i].env == env:
            return bundle.waves[i].api_edge_enabled
    return False


# The `ValidateStep.check` oneof discriminant for the `run_container` arm
# (1 == http_check, 2 == run_container). The ordinal is the proto field number
# and there is no generated symbol for it.
comptime _CHECK_RUN_CONTAINER: Int = 2


def _wave_peer_identity_issuer(bundle: AppBundle, env: String) -> String:
    """The token issuer THIS env's peer-only edges trust
    (`Wave.peer_identity_issuer`), or `""` when this env's wave names none.

    PER-ENV BY CONSTRUCTION: only the wave whose `env` matches is read, so one
    environment's edge cannot be pointed at another environment's issuer. A
    bundle-global issuer field would make that cross-environment trust
    expressible, which is why there is not one."""
    for i in range(len(bundle.waves)):
        if bundle.waves[i].env == env:
            return bundle.waves[i].peer_identity_issuer.copy()
    return String("")


def _wave_developer_access_principal(
    bundle: AppBundle, env: String, developer_access_allowed: Bool
) raises -> String:
    """The authenticated developer-access principal THIS env's peer-only edges
    additionally accept (`Wave.developer_access_principal`), or `""`.

    WHETHER AN ENV MAY COMPOSE ONE IS A FACT OF THE ENVIRONMENT, NOT OF THE
    BUNDLE. The caller passes `developer_access_allowed` from the target
    environment's definition. It FAILS CLOSED: the default is False, so an env
    whose definition says nothing — including every env created tomorrow — is
    refused until its definition opts in, in a diff a reviewer reads.

    RAISES when the wave for an env that does not allow it authors one. It does
    NOT silently return `""`, and the difference matters more than it looks: a
    dropped field leaves an operator believing they have direct access to a
    service they cannot reach. An error names the field, the env, and the rule.

    A WAVE **IS** AN ENV, so `compose_api(bundle, "<env>")` reads that env's wave
    and no other. Authoring this on one env's wave composes nothing at all into
    another env's manifest — it is not filtered out downstream, it is never
    read. The refusal below is for the other case: authoring it on the wave of
    an env that does not allow it."""
    for i in range(len(bundle.waves)):
        if bundle.waves[i].env != env:
            continue
        var principal = bundle.waves[i].developer_access_principal.copy()
        if principal.byte_length() == 0:
            return String("")
        if not developer_access_allowed:
            raise Error(
                String(
                    "compose_api: bundle '"
                    + bundle.name
                    + "' authors a developer_access_principal ('"
                    + principal
                    + "') on the wave for env '"
                    + env
                    + "', whose environment definition does not allow"
                    " developer access (developer_access_allowed is unset). An"
                    " authenticated developer-access principal is a SECOND"
                    " accepted caller on an internal service's edge: it turns"
                    " the caller set from 'the other services in this"
                    " deployment' into 'whoever holds"
                    " serviceAccountTokenCreator on one account', permanently"
                    " and with no per-call record distinguishing them from a"
                    " peer. Set developer_access_allowed on the environment"
                    " definition to opt that environment in, or remove the"
                    " field from this wave."
                )
            )
        return principal^
    return String("")


def _wave_gates_on_a_container(bundle: AppBundle, env: String) -> Bool:
    """Whether the wave for `env` gates on at least one RUNNABLE `run_container`
    validate step — i.e. whether this deploy will place an in-cloud validate JOB.

    THE ONE THING COMPOSE CAN SEE. A `run_container` step is routed IN-ENV as a
    cloud JOB running as the deploy principal; an `http_check` is ALWAYS a LOCAL
    health GET from the operator's host and creates no job and no cloud
    identity. Compose has no environment BINDING (it cannot know whether the env
    is a cloud env), so the authored step FORM is the narrowest declarative
    signal available for "this env's deploy runs a job as the deploy SA". A wave
    with only `http_check` steps — or no `validate` at all — composes no
    validator grant.

    AN EXCLUDED STEP DOES NOT COUNT. `ValidateStep.excluded_because` (the
    exclusion marker whose value IS its justification) contracts the step out of
    a resolved run, so it places no job and must not buy a standing IAM grant.
    An exclusion that silently kept a privilege would be the opposite of what
    the marker is for."""
    for i in range(len(bundle.waves)):
        if bundle.waves[i].env != env:
            continue
        ref wave = bundle.waves[i]
        for s in range(len(wave.validate)):
            ref step = wave.validate[s]
            if step._oneof0_case != _CHECK_RUN_CONTAINER:
                continue
            if step.excluded_because.byte_length() > 0:
                continue  # EXCLUDED — contracted out of the run, places no job
            return True
        return False
    return False


def _append_validate_step_secret_grant_nodes(
    bundle: AppBundle,
    env: String,
    mut nodes: List[ResourceNode],
    # REQUIRED, NOT DEFAULTED — `_append_api_service_nodes`'s own rule, for the
    # same reason: omitting it would compose the WRONG THING (a grant on the day-0
    # deploy role that no AWS apply can ever write), not merely less.
    cloud: Int,
) raises:
    """THE SELF-FETCHED-SECRET READ GRANTS — one per `RunContainer.reads_secret`
    the wave for `env` declares.

    A validate job that fetches a secret itself (rather than having it mounted)
    must hold `secretAccessor` on that secret, and the deploy principal's
    standing roles grant nothing on a secret's data plane. Without this node the
    job reports HTTP 403 on every read, behind a green apply.

    WHY A GENERIC NODE AND NOT A PER-SECRET SPECIAL CASE. A composer edit per
    secret would be a requirement nobody writing a bundle can see they need, and
    it would keep living as a comment in the bundle. A comment cannot converge.
    This node reads what the STEP declares, so the bundle that needs the grant
    is the artifact that asks for it.

    SCOPE:
      * Per-SECRET and resource-scoped: `roles/secretmanager.secretAccessor` on
        ONE named secret, never project-wide.
      * Gated on the step being RUNNABLE, not merely present: an
        `excluded_because` step is contracted out of the run, places no job, and
        must not buy a standing privilege — the same rule
        `_wave_gates_on_a_container` enforces, applied per step rather than per
        wave.
      * Gated on the AUTHORED declaration, so the DEFAULT is no node at all.
      * NOT gated on `self_provision`. That predicate is about whether the DEPLOY
        creates a runtime SA; the principal here is the step's job identity,
        which exists in every env.

    THE PRINCIPAL IS `_validate_step_job_principal(rc)`, NOT A CONSTANT. The
    placer attaches the job to the AUTHORED `RunContainer.runtime_identity`
    when set, so a grant naming the deploy SA for a job that runs as somebody
    else authorizes a principal that never makes the call and leaves the caller
    403ing — a green deploy and a red gate with nothing connecting them. ONE
    derivation, shared with the telemetry node, is what keeps "the SA the job is
    attached to" and "the SA the grant authorizes" from drifting into two
    answers.

    DEDUPED BY (PRINCIPAL, SECRET) — the telemetry node's key, for the same
    reason. Two steps in one wave may read the same secret; as ONE identity that
    is ONE binding and the second declaration is the same grant. As TWO
    identities it is TWO distinct members on that secret's policy and BOTH are
    needed — deduping on the target alone would silently drop the second job's
    authority and leave it 403ing with the bundle insisting it had asked. Two
    nodes then share one target resource, which `apply_graph` applies SERIALLY
    and the IAM binder re-drives on an etag conflict.

    A GRAPH ROOT (empty `depends_on`): BOTH ends are external to this graph.
    `kci bootstrap` creates the deploy SA, and the secret itself is provisioned
    out of band. A `depends_on` naming either would name a node this graph does
    not contain."""
    # NOT ON `CLOUD_AWS`. The AWS carrier for a deploy-principal grant is
    # `PutRolePolicy` on the day-0 deploy role, which the AWS grant conformer
    # refuses permanently. See `_validator_runs_as_the_deploy_principal_on_cloud`.
    if not _validator_runs_as_the_deploy_principal_on_cloud(cloud):
        return
    var seen = List[String]()
    for i in range(len(bundle.waves)):
        if bundle.waves[i].env != env:
            continue
        ref wave = bundle.waves[i]
        for s in range(len(wave.validate)):
            ref step = wave.validate[s]
            if step._oneof0_case != _CHECK_RUN_CONTAINER:
                continue
            if step.excluded_because.byte_length() > 0:
                continue  # EXCLUDED — places no job, buys no grant
            if not step.run_container:
                continue
            ref rc = step.run_container.value()
            if len(rc.reads_secret) == 0:
                continue
            # WHO THE JOB ACTUALLY RUNS AS — the authored `runtime_identity`
            # when set, else the deploy principal. The SAME derivation the
            # telemetry grant node uses, so the two cannot drift.
            var principal = _validate_step_job_principal(rc)
            for k in range(len(rc.reads_secret)):
                ref secret = rc.reads_secret[k]
                if secret.byte_length() == 0:
                    continue  # `validate_bundle` already refused this
                # The id carries the PRINCIPAL, so two steps reading one secret
                # as two identities compose two nodes rather than collapsing
                # onto one and dropping the second job's authority.
                var node_id = (
                    _principal_id_token(principal)
                    + String("-reads-")
                    + secret
                )
                var dup = False
                for j in range(len(seen)):
                    if seen[j] == node_id:
                        dup = True
                        break
                if dup:
                    continue
                seen.append(node_id.copy())
                nodes.append(
                    _base_grant_node(
                        node_id^,
                        principal.copy(),  # the job's SA (mapper expands a bare name)
                        Capability.CAPABILITY_READ_SECRET,  # secretAccessor
                        secret.copy(),  # target = the NAMED secret, never project-wide
                        List[String](),  # graph ROOT — both ends are external
                        # RETAIN_KEEP: the id is derived from (PRINCIPAL,
                        # SECRET), so two bundles whose validate jobs run as the
                        # same identity and read the same secret compose the
                        # byte-identical node, and deleting either unbinds the
                        # other's validate step.
                        Retention.RETENTION_RETAIN_KEEP,
                    )
                )
        return
    return


def _validate_step_job_principal(rc: RunContainer) -> String:
    """WHO a validate step's in-cloud JOB runs as — the `principal_identity_ref`
    every grant composed for that step must name.

    The AUTHORED `RunContainer.runtime_identity` (a full SA email) when set, else
    `DEPLOY_PRINCIPAL`, the default the field's own proto comment states. ONE
    derivation, so "the SA the job is attached to" and "the SA the grant
    authorizes" cannot drift into two answers: a grant naming the deploy SA for
    a job that runs as somebody else authorizes a principal that never makes the
    call and leaves the caller 403ing, which is a green deploy and a red gate
    with nothing connecting them.

    The mapper handles both spellings: a bare name is expanded to
    `<name>@<project>.iam.gserviceaccount.com`, and a ref already carrying `@` is
    threaded verbatim with the SA-propagation retry OFF (it is not created in
    this apply)."""
    if rc.runtime_identity.byte_length() > 0:
        return rc.runtime_identity.copy()
    return DEPLOY_PRINCIPAL


def _principal_id_token(principal: String) -> String:
    """The node-id-safe short form of a principal ref: the SA local part
    (`app-role@example-project.iam.gserviceaccount.com` -> `app-role`),
    or the ref verbatim when it is already a bare name. Used ONLY to build a
    logical id — the grant itself always carries the FULL ref."""
    var at = principal.find(String("@"))
    if at < 0:
        return principal.copy()
    return String(principal[byte=0:at])


# The `TelemetryRead` ordinals (`app_bundle.proto`). Named here rather than
# imported so this file states the two it maps; an ordinal added to the enum
# without a row below composes NO node, which `_append_validate_step_telemetry_
# grant_nodes` turns into an explicit raise rather than a silent drop.
comptime _TELEMETRY_READ_LOGS: Int = 1
comptime _TELEMETRY_READ_METRICS: Int = 2


def _append_validate_step_telemetry_grant_nodes(
    bundle: AppBundle,
    env: String,
    mut nodes: List[ResourceNode],
    # REQUIRED, NOT DEFAULTED — see `_append_validate_step_secret_grant_nodes`.
    cloud: Int,
) raises:
    """THE OBSERVABILITY READ GRANTS — one per DISTINCT (principal, plane) the
    wave for `env` declares via `RunContainer.reads_telemetry`.

    A validator that asserts on what a deployed service LOGGED or MEASURED must
    be able to read the log and metric planes, and the deploy principal's
    standing roles grant nothing on Logging or Monitoring. Without this node the
    validator reports a 403 on its read precondition and every dependent row is
    unobservable.

    WHY A NODE AND NOT A HAND BINDING. A hand binding produces a green that the
    NEXT fresh environment does not have. This node reads what the STEP
    declares, so the requirement is in the bundle and converges with it.

    THE CAPABILITIES ARE DERIVED FROM WHAT A VALIDATOR CALLS:

        POST logging.googleapis.com/v2/entries:list  -> `logging.logEntries.list`
        GET  monitoring.../v3/projects/<P>/timeSeries -> `monitoring.timeSeries.list`

    `roles/logging.viewer` and `roles/monitoring.viewer` are the narrowest
    predefined roles carrying those, and both are read-only across their whole
    API. The rejected neighbours are named in the grant conformer's role table:
    `logging.privateLogViewer` is a superset (Data Access audit logs);
    `monitoring.editor`/`admin` add `timeSeries.create`; `logging.logWriter` /
    `monitoring.metricWriter` are the WRITE halves and carry no read at all —
    which is why READ_LOGS is its own ordinal and not a widening of LOG_WRITE.

    SCOPE, AND WHY EACH NARROWING IS THE ONE IT IS:
      * GATED ON THE AUTHORED DECLARATION, so the DEFAULT IS NO NODE.
      * GATED ON THE STEP BEING RUNNABLE, not merely present: an
        `excluded_because` step is contracted out of the run, places no job, and
        must not buy a standing privilege — per-step, the rule
        `_wave_gates_on_a_container` applies per-wave.
      * THE PRINCIPAL IS THE STEP'S OWN JOB IDENTITY (`_validate_step_job_
        principal`), not a hardcoded deploy SA. A step that declares
        `runtime_identity` runs as that SA and must be the one authorized;
        granting the deploy SA instead would converge green and 403 forever.
      * READ-ONLY, matching the seam. The validator has no write verb on either
        API, and its grant should be able to say the same thing.
      * PROJECT-SCOPED, which here is a LAW rather than a gap (contrast the
        datastore row): `entries:list` takes `resourceNames: ["projects/<P>"]`
        and `timeSeries.list` is addressed `projects/<P>/timeSeries`, so the
        project IS the query's subject. Neither a log nor a metric is an
        IAM-bindable resource and there is no per-resource condition to narrow
        with.

    DEDUPED BY (PRINCIPAL, PLANE). A project's IAM policy is ONE resource under
    read-modify-write SetIamPolicy, so two nodes binding the same triple would
    race and one binding would be lost — the reason the secret node dedupes.

    A GRAPH ROOT (empty `depends_on`) + `RETAIN_KEEP`, for the datastore-read
    A GRAPH ROOT (empty `depends_on`) + `RETAIN_KEEP`, for the datastore-read
    node's reason: BOTH ends are external to this graph. `kci bootstrap`
    creates the deploy SA, and the project is nobody's app resource.

    AN UNMAPPED ORDINAL RAISES. A value added to `TelemetryRead` without a row
    here would otherwise compose NO node and the gate would report the same 403
    with the bundle insisting it had asked — a silent drop."""
    # NOT ON `CLOUD_AWS` — the same premise, the same predicate. See
    # `_validator_runs_as_the_deploy_principal_on_cloud`.
    if not _validator_runs_as_the_deploy_principal_on_cloud(cloud):
        return
    var seen = List[String]()
    for i in range(len(bundle.waves)):
        if bundle.waves[i].env != env:
            continue
        ref wave = bundle.waves[i]
        for s in range(len(wave.validate)):
            ref step = wave.validate[s]
            if step._oneof0_case != _CHECK_RUN_CONTAINER:
                continue
            if step.excluded_because.byte_length() > 0:
                continue  # EXCLUDED — places no job, buys no grant
            if not step.run_container:
                continue
            ref rc = step.run_container.value()
            if len(rc.reads_telemetry) == 0:
                continue
            var principal = _validate_step_job_principal(rc)
            for k in range(len(rc.reads_telemetry)):
                var plane = Int(rc.reads_telemetry[k].value)
                if plane == 0:
                    continue  # `validate_bundle` already refused this
                var cap: Int
                var plane_token: String
                if plane == _TELEMETRY_READ_LOGS:
                    cap = Capability.CAPABILITY_READ_LOGS
                    plane_token = String("logs")
                elif plane == _TELEMETRY_READ_METRICS:
                    cap = Capability.CAPABILITY_READ_MONITORING
                    plane_token = String("metrics")
                else:
                    raise Error(
                        String(
                            "compose_api: RunContainer.reads_telemetry carries"
                            " TelemetryRead ordinal "
                        )
                        + String(plane)
                        + String(
                            " which this composer has no capability row for. A"
                            " new plane must be mapped here; composing no node"
                            " would leave the validator 403ing while the bundle"
                            " insists it asked for the grant."
                        )
                    )
                var node_id = (
                    _principal_id_token(principal)
                    + String("-reads-")
                    + plane_token
                )
                var dup = False
                for j in range(len(seen)):
                    if seen[j] == node_id:
                        dup = True
                        break
                if dup:
                    continue
                seen.append(node_id.copy())
                nodes.append(
                    _base_grant_node(
                        node_id^,
                        principal.copy(),
                        cap,
                        String(""),  # PROJECT-scoped -> `projects/<P>`
                        List[String](),  # graph ROOT — both ends are external
                        # RETAIN_KEEP — the datastore-read rule, and the same
                        # sharing hazard: the id is derived from (principal,
                        # plane), so two bundles whose validate jobs run as the
                        # deploy SA compose the byte-identical node and deleting
                        # either would unbind the other's gate.
                        Retention.RETENTION_RETAIN_KEEP,
                    )
                )
        return
    return


def _wave_env_overrides_by_service(
    bundle: AppBundle, env: String, services: List[ServiceSpec]
) raises -> List[Dict[String, String]]:
    """The per-ENV env-var OVERRIDE maps for the wave whose `env` matches, ONE PER
    SERVICE, positionally aligned with `services`.

    THE SERVICE AXIS. A `Wave` is BUNDLE-scoped and has no service axis;
    `BundleEnvVar.service` is that axis. Folding one map onto EVERY service's
    Config node is harmless while a bundle is one service and a CONFIG LEAK once
    a bundle holds several: every service would receive every other service's
    per-env values, credentials included.

    THE DECIDED DEFAULT FOR AN OVERRIDE THAT NAMES NO SERVICE IS **REFUSE**,
    when more than one service would receive it. The alternatives are "apply to
    all" (the leak) and "apply to the first" (a silent wrong answer with a
    tie-break for a hat). A bundle with exactly ONE receiving service has nothing
    to be ambiguous about, so the axis stays OPTIONAL and every single-service
    bundle composes without it.

    THE CANDIDATE SET IS THE **RECEIVERS**, NOT `len(services)`. A
    SHARED_INFRASTRUCTURE service composes no Config node — its artifact is a
    database — so it is not a candidate for an unqualified override, and a bundle
    of {owner, one served service} is unambiguous. Counting every declared
    service would refuse that shape, which is a refusal with no wrong answer
    behind it.

    AND THE VALIDATION IS OVER THE WHOLE OVERRIDE LIST, NOT PER SERVICE. The
    obvious implementation — "give me the overrides for service S" called once per
    service — answers correctly for every service that EXISTS and never looks at
    an override naming one that does not, so a typo'd service name becomes an
    override silently dropped. That is the same fail-quiet in a new place, which
    is why an unknown name RAISES here.

    Only the LITERAL-`value` arm is honored (a `value_from` / `service_ref`
    override is dynamic/cross-service, not a per-env literal), unchanged. No wave
    for `env`, or an empty `env_override`, ⇒ EMPTY maps ⇒ the spec-level `env {}`
    values stand."""
    var out = List[Dict[String, String]]()
    for _ in range(len(services)):
        out.append(Dict[String, String]())

    # The RECEIVERS: the services that compose a Config node. An override can only
    # land on one of these, so this is both the resolution target for an
    # unqualified override and the legality check for a qualified one.
    var receivers = List[Int]()
    for i in range(len(services)):
        if not service_serves_nothing(services[i]):
            receivers.append(i)

    for i in range(len(bundle.waves)):
        if bundle.waves[i].env != env:
            continue
        ref ovr = bundle.waves[i].env_override
        for j in range(len(ovr)):
            if ovr[j]._oneof0_case != 1:  # literal `value` arm ONLY
                continue
            # The receiving service INDEX. Every path below either assigns it or
            # raises — there is deliberately no fallback value, because a
            # fallback here IS the fan-out this function exists to remove.
            var target: Int
            if ovr[j].service.byte_length() > 0:
                # QUALIFIED: the named service must exist AND must receive env.
                var found = -1
                for si in range(len(services)):
                    if services[si].name == ovr[j].service:
                        found = si
                        break
                if found < 0:
                    var declared = String("")
                    for si in range(len(services)):
                        declared += String(" ") + services[si].name
                    raise Error(
                        String("compose_api: wave '")
                        + env
                        + String("' env_override '")
                        + ovr[j].name
                        + String("' names service '")
                        + ovr[j].service
                        + String(
                            "', which this bundle does not declare. Declared"
                            " services:"
                        )
                        + declared
                    )
                if service_serves_nothing(services[found]):
                    raise Error(
                        String("compose_api: wave '")
                        + env
                        + String("' env_override '")
                        + ovr[j].name
                        + String("' names service '")
                        + ovr[j].service
                        + String(
                            "', which composes no Config node (its artifact is a"
                            " resource, not a served container) — the override"
                            " could never land. Aim it at a served service, or"
                            " delete it."
                        )
                    )
                target = found
            else:
                # UNQUALIFIED: legal only when exactly ONE service receives it.
                if len(receivers) == 1:
                    target = receivers[0]
                else:
                    var candidates = String("")
                    for ri in range(len(receivers)):
                        candidates += (
                            String(" ") + services[receivers[ri]].name
                        )
                    raise Error(
                        String("compose_api: wave '")
                        + env
                        + String("' env_override '")
                        + ovr[j].name
                        + String("' names no service, and ")
                        + String(len(receivers))
                        + String(
                            " services in this bundle would receive it:"
                        )
                        + candidates
                        + String(
                            ". Add `service: \"<name>\"` to the env_override."
                            " Applying it to all of them is a config leak across"
                            " services (one service's credentials reach every"
                            " other), and picking one is a silent wrong answer"
                            " for the rest."
                        )
                    )
            out[target][ovr[j].name.copy()] = ovr[j].value.value().copy()
        break
    return out^


# ═══════════════════════════════════════════════════════════════════════════
#  THE DEPLOY REGION — DERIVED FROM THE SERVICES, NEVER FROM THE SINGULAR SPEC
# ═══════════════════════════════════════════════════════════════════════════


def bundle_deploy_region(bundle: AppBundle) raises -> String:
    """The per-bundle deploy-region OVERRIDE, or `""` for "no override, use the
    `--env` binding's region".

    WHY IT LIVES HERE, NEXT TO THE AUTO-LIFT. `compose` IGNORES the singular
    `bundle.spec` whenever `services` is non-empty (`_auto_lifted_services`), so
    a binding derived from the SINGULAR `bundle.spec.region` would read a value
    compose never uses: per-service region pins would reach compose and NOT the
    deploy, and the machine would be placed in the env binding's region while
    every assertion about it said otherwise. Deriving the region from
    `auto_lifted_services` — the SAME list compose emits node sets from — is
    what makes the two structurally unable to disagree.

    THE SAME HAZARD AS THE INVOKE-GRANT REGION ONE LAYER UP.
    `_invoke_grant_region` exists because a wrong region binds `run.invoker` on
    a service that does not exist there: not an error any deploy can see —
    green deploy, 403 on every call, forever. A wrong DEPLOY region has the same
    silent shape and reaches four apply sites at once (the compute region, the
    served-URL registry poll, the IAM binder, the datastore-index ensure).

    DISAGREEMENT IS A REFUSAL, NOT A TIE-BREAK. The effective binding rewrites
    the ONE `EnvBinding` the verbs thread everywhere, so a bundle is placed in
    exactly ONE region; two pinned regions have no answer and neither does a
    PARTIAL pin (an unpinned sibling would silently relocate out of its env's
    region on the strength of a value written about a different service). Both
    raise, naming the services and the regions.

    A RESOURCE-OWNER SERVICE IS NOT A CANDIDATE. A SHARED_INFRASTRUCTURE
    service's artifact is a database, which has no compute placement — counting
    it as an unpinned dissenter would refuse a bundle of one owner plus pinned
    served services.

    For a single-service bundle the auto-lift synthesizes one service from the
    singular spec, so the derived region IS `bundle.spec.region`, and a bundle
    that pins nothing derives `""`."""
    # `refuse_unresolved=False` — see `_auto_lifted_services`. This function
    #   asks about REGIONS, never about names, and it is what the deploy calls to
    #   DERIVE the region the name resolver then consumes. Refusing here would be
    #   a cycle.
    var services = _auto_lifted_services(bundle, refuse_unresolved=False)
    var chosen = String("")
    var chosen_by = String("")
    var unpinned = String("")
    for i in range(len(services)):
        if service_serves_nothing(services[i]):
            continue
        var r = String("")
        if services[i].spec:
            r = services[i].spec.value().region.copy()
        if r.byte_length() == 0:
            unpinned += String(" ") + services[i].name
            continue
        if chosen.byte_length() == 0:
            chosen = r^
            chosen_by = services[i].name.copy()
            continue
        if r != chosen:
            raise Error(
                String("bundle_deploy_region: bundle '")
                + bundle.name
                + String("' pins TWO deploy regions — service '")
                + chosen_by
                + String("' pins '")
                + chosen
                + String("' and service '")
                + services[i].name
                + String("' pins '")
                + r
                + String(
                    "'. One deploy places one bundle in ONE region (the effective"
                    " EnvBinding is rewritten once and threaded to the compute,"
                    " registry-poll, IAM and index-ensure sites together), so"
                    " there is no answer to return. Split the bundle, or pin one"
                    " region."
                )
            )
    if chosen.byte_length() > 0 and unpinned.byte_length() > 0:
        raise Error(
            String("bundle_deploy_region: bundle '")
            + bundle.name
            + String("' pins its deploy region PARTIALLY — service '")
            + chosen_by
            + String("' pins '")
            + chosen
            + String("' while these served services pin nothing:")
            + unpinned
            + String(
                ". The pin moves the WHOLE bundle (it overrides the one"
                " EnvBinding every apply site reads), so an unpinned service"
                " would silently relocate out of its env's region on the"
                " strength of a value written about a different service. Pin"
                " every served service, or none."
            )
        )
    return chosen^


def _wave_parameter_override(
    bundle: AppBundle, env: String
) raises -> Dict[String, String]:
    """The per-ENV PARAMETER override map for the wave whose `env` matches — the
    twin of `_wave_env_overrides_by_service`, and deliberately so: per-env binding is
    the same problem for a parameter as for an env var, and two different shapes
    for it would be two things to keep in sync.

    Only the LITERAL `value` arm is honored (a `marker` / `value_from` /
    `service_ref` override is a dynamic source, not a per-env literal; honoring
    one here would mean two tiers deciding the same value). No matching wave, or
    no overrides, ⇒ an EMPTY map ⇒ the spec-level declaration stands."""
    var out = Dict[String, String]()
    for i in range(len(bundle.waves)):
        if bundle.waves[i].env == env:
            ref ovr = bundle.waves[i].parameter_override
            for j in range(len(ovr)):
                if ovr[j]._oneof0_case == 1:  # literal `value` arm ONLY
                    out[ovr[j].name.copy()] = ovr[j].value.value().copy()
            break
    return out^


def _secured_edge_routes_of(spec: AppSpec) raises -> List[SecuredEdgeRoute]:
    """Project the AUTHORED `AppSpec.secured_inbound_routes` (intent tier) onto the
    resolved `SecuredEdgeRoute` list the API_EDGE node carries.

    THE POLICY IS TRANSLATED, NOT PASSED THROUGH, and an unknown value RAISES.
    The two enums are declared in two protos that may not import each other, so
    this is the one place their vocabularies are related — and a translate that
    fell through to a default would pick a value for a field whose whole job is to
    say whether a route is authenticated. `validate` already refuses an
    UNSPECIFIED policy at authoring; this raise is what makes that refusal
    load-bearing rather than merely first."""
    var out = List[SecuredEdgeRoute]()
    for i in range(len(spec.secured_inbound_routes)):
        ref r = spec.secured_inbound_routes[i]
        if (
            r.policy.value
            != EdgeAuthPolicyKind.EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT
        ):
            raise Error(
                String("compose: secured inbound route '")
                + r.route_path
                + String(
                    "' carries an edge-auth policy the edge render cannot secure a"
                    " route with (only EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT is"
                    " a per-route policy today). Rendering it anyway would emit a"
                    " `security` requirement naming a definition that is never"
                    " rendered — which the gateway ACCEPTS, leaving the route"
                    " OPEN."
                )
            )
        # NO audience travels: compose runs before any cloud call, and the
        # accepted `aud` is the origin of a gateway that does not exist yet. The
        # conformer binds it from the live `Gateway.default_hostname`.
        out.append(
            SecuredEdgeRoute(
                r.route_path.copy(),
                EdgeAuthMode(EdgeAuthMode.EDGE_AUTH_MODE_FEDERATED_SA_JWT),
                r.sa_email.copy(),
            )
        )
    return out^


def _identity_marker_without_a_both_sink_resolver(value: String) -> String:
    """The composition marker in `value` that NO downstream arm resolves on BOTH
    of the two sinks an identity value lands on; EMPTY when there is none.

    ── WHY THIS PREDICATE IS NOT "DOES IT CONTAIN A MARKER" ───────────────────
    `_refuse_authorizer_identity_conflict` runs in COMPOSE, which is env-agnostic
    BY CONTRACT: it emits the token and the mapper substitutes
    (`param_resolve.param_marker_token`'s own header states the seam). So a
    marker on an identity value is an ORDINARY case here, not a defect, and a
    blanket refusal would red a bundle at compose time for doing exactly what
    the design asks.

    ── WHAT IT DOES ASSERT ─────────────────────────────────────────────────────
    An identity value composed here lands on TWO sinks and is compared BY VALUE
    across them one tier down: the EDGE's `identity_issuer` / `identity_audience`,
    and the AUTHORIZER LAMBDA'S OWN ENVIRONMENT, which this composer derives from
    the service's env plus these two writes. The caller's equality test is what
    claims the two agree. When both sides hold the same unresolved marker, that
    equality is a TAUTOLOGY — the two operands are the same string BY
    CONSTRUCTION — so the claim is worth something only if a later tier resolves
    BOTH sinks with the SAME resolver. Exactly one token has one:

      the SVCREF marker           env  the AWS mapper's config-env render
                                  edge the AWS mapper's identity pin
                                  (both by way of one endpoint-marker resolver)

    Any other marker has at most ONE resolver, or none: the PROJECT and REGION
    markers are refused on AWS outright and have no AWS meaning at all. For
    those, two equal placeholders here would report agreement and the deploy
    would then either stamp the literal text onto a live door or die three
    tiers away with a message about a field this bundle never edited — "nobody
    checked" reported as "the check passed", on the ONE kind whose refusals ARE
    the security surface. This asks the question at the tier that can name the
    BUNDLE LINE, which the mapper cannot.

    IT ANSWERS THE MARKER, NOT A BOOL, because the refusal has to quote it.
    A guard that says "there is a marker" sends the reader off to find it.

    AND IT IS DELIBERATELY A STATED LIST RATHER THAN A DERIVATION. There is no
    expression in this package for "does the AWS mapper resolve token T on both
    sinks" — that arm lives in a compile unit this package must not reach into.
    So the list is stated, and it is stated by comparing against the IMPORTED
    token declaration rather than by sniffing a substring, so that adding a
    resolver without adding the row here fails CLOSED: the value is refused,
    loudly, at compose, by a message naming the marker."""
    var open_at = value.find(String("${"))
    if open_at < 0:
        return String("")
    if String(PARAM_SVCREF_TOKEN_OPEN) in value:
        return String("")
    var rest = String(value[byte=open_at:])
    var close_rel = rest.find(String("}"))
    if close_rel < 0:
        # An unterminated marker is still a marker, and quoting it to the end of
        # the value is what makes the refusal actionable (the AWS arm quotes an
        # unterminated marker the same way).
        return rest^
    return String(rest[byte = 0 : close_rel + 1])


def _authorizer_env_key(service_name: String, field: String) raises -> String:
    """The env KEY the AWS authorizer Lambda reads one identity value from —
    `IngressSpec.authorizer_issuer_env` or `IngressSpec.authorizer_audience_env`.

    THE KEYS ARE THE AUTHORIZER'S OWN CONTRACT, SO THE BUNDLE DECLARES THEM.
    kci must not author them: a composer that invents the names becomes a second
    author of somebody else's binary's configuration, and the two drift.

    The schema this package builds against does not carry those two fields yet,
    so an AWS identity-JWT edge is REFUSED here, naming the field, rather than
    composed with keys nobody declared. This is the one function that changes
    when the fields land: it then returns the declared name, and refuses an
    empty one by name."""
    raise Error(
        String("compose_api: service '")
        + service_name
        + String(
            "' composes an EDGE_AUTH_MODE_IDENTITY_JWT client edge on an AWS"
            " env. Its authorizer reads the issuer and audience from env keys"
            " the bundle must declare (`ingress."
        )
        + field
        + String(
            "`), and that field is not available in this schema. Refusing"
            " rather than inventing a key name: the keys are the authorizer's"
            " contract, not this composer's.\n\nNothing was deployed."
        )
    )


def _refuse_authorizer_identity_conflict(
    service_name: String,
    authz_id: String,
    key: String,
    authz_cfg: Dict[String, String],
    edge_value: String,
    what_it_is: String,
) raises:
    """THE SERVICE AND THE EDGE MAY NOT NAME DIFFERENT IDENTITIES.

    The AWS authorizer Lambda is configured with the SERVICE's own environment
    (see the call sites), and the composer then writes the two identity values
    the EDGE owns over the top. When the service authored the SAME key with a
    DIFFERENT value, that overwrite would be silent — and the authorizer and the
    handler would then be reading different answers to the same question: the
    door would admit tokens the handler then rejects, a 403 from the
    application for a request the gateway said yes to, with nothing naming the
    disagreement.

    EQUAL IS FINE AND IS THE ORDINARY CASE, not an exception grudgingly
    allowed: an application that reads its own audience from the same key the
    authorizer reads authors that key on the service, at the same value the
    ingress block names, and passes here.

    THE VALUES ARE QUOTED IN THE MESSAGE. Neither is a secret (an issuer origin
    and a deployment audience are both public), and a refusal that says "they
    disagree" without saying how sends the reader to diff two files by hand.

    Raises:
        If `authz_cfg` already carries `key` at a value other than `edge_value`.
    """
    # ═════════════════════════════════════════════════════════════════════
    # THE MARKER GUARD, AND IT RUNS BEFORE THE EQUALITY TEST BECAUSE THE
    #    EQUALITY TEST IS WHAT IT DOES NOT TRUST.
    #
    # The `return` below is a claim that the service and the edge NAME THE SAME
    # IDENTITY. Over two literals that claim is evidence. Over two copies of one
    # unresolved marker it is a tautology: `compose_api` DERIVES the authorizer's
    # environment from these very fields, one variable into two sinks, so the two
    # operands are the same string by construction and equality proves only that
    # the composer ran — "nobody checked" reported as "the check passed", on the
    # one kind whose refusals ARE the security surface.
    #
    # SO THE GUARD IS NOT "REFUSE A MARKER". Compose is env-agnostic BY CONTRACT
    # and a marker here is an ordinary case; refusing all of them would red a
    # bundle for doing what the design asks. It refuses the markers for which NO
    # downstream tier resolves BOTH sinks with one resolver — see
    # `_identity_marker_without_a_both_sink_resolver`, which is where that list
    # and its reasoning live.
    #
    # AND IT IS CHECKED ON BOTH OPERANDS, not just the bundle's. The edge value
    # is derived by this composer from `waves.peer_identity_issuer` /
    # `ingress.peer_identity_audience`, which are just as authorable.
    var svc_marker = String("")
    if key in authz_cfg:
        svc_marker = _identity_marker_without_a_both_sink_resolver(
            authz_cfg[key]
        )
    var edge_marker = _identity_marker_without_a_both_sink_resolver(edge_value)
    if svc_marker.byte_length() > 0 or edge_marker.byte_length() > 0:
        # WHICH SIDE IS QUOTED. The SERVICE's is preferred when both carry
        # one, because that is the line an author edits; the edge's value is
        # DERIVED by this composer from `waves.peer_identity_issuer` /
        # `ingress.peer_identity_audience`, so naming "the API edge" still points
        # at a bundle field, one indirection away.
        var offender = edge_marker.copy()
        var whose = (
            String("service '")
            + service_name
            + String("' — its API EDGE, derived from that wave/ingress block —")
        )
        if svc_marker.byte_length() > 0:
            offender = svc_marker.copy()
            whose = String("service '") + service_name + String("'")
        raise Error(
            String("compose_api: ")
            + whose
            + String(" names the UNRESOLVABLE COMPOSITION MARKER '")
            + offender
            + String("' as ")
            + what_it_is
            + String(
                ". Refusing, and refusing EVEN IF THE TWO SIDES MATCH — that is"
                " the whole point of this check. The AWS front door's CUSTOM"
                " REQUEST authorizer ('"
            )
            + authz_id
            + String(
                "') is configured with THIS SERVICE'S OWN environment plus the"
                " two identity values the edge owns, and the mapper then pins"
                " the edge against that environment BY VALUE"
                " (`aws_api_edge_identity_pin_gap`). This composer DERIVES the"
                " one from the other, so an unresolved marker appears on both"
                " sides and equality is a tautology, not evidence: the pin would"
                " report agreement between two placeholders, which is strictly"
                " worse than no pin — it turns \"nobody checked\" into \"the"
                " check passed\".\n\n  ⇒ Only ONE marker is resolved on BOTH"
                " sinks by one resolver: `"
            )
            + String(PARAM_SVCREF_TOKEN_OPEN)
            + String(
                "<service>}`, the peer's endpoint as recorded under"
                " `service/<name>` by the deploy that converged it. Author one of"
                " those, or a literal.\n\nNothing was deployed."
            )
        )
    if key in authz_cfg:
        if authz_cfg[key] == edge_value:
            return
    else:
        return
    raise Error(
        String("compose_api: service '")
        + service_name
        + String("' authors env '")
        + key
        + String("' = '")
        + authz_cfg[key]
        + String("', but its API edge names '")
        + edge_value
        + String("' for the same value — ")
        + what_it_is
        + String(
            ". The AWS front door's CUSTOM REQUEST authorizer ('"
        )
        + authz_id
        + String(
            "') is configured with THIS SERVICE'S OWN environment plus the two"
            " identity values the edge owns, so composing anyway would silently"
            " overwrite one of the two and leave the door and the application"
            " behind it verifying against different authorities. The handler"
            " re-runs the identity ladder itself and does not trust the"
            " authorizer's verdict, so the disagreement surfaces as the"
            " application refusing requests the gateway admitted, with nothing"
            " naming the cause.\n\n  ⇒ Make them one value: the edge's issuer is"
            " the wave's `peer_identity_issuer` and the edge's audience is"
            " `ingress.peer_identity_audience`.\n\nNothing was deployed."
        )
    )


def _append_api_edge_nodes(
    bundle: AppBundle,
    services: List[ServiceSpec],
    env: String,
    mut nodes: List[ResourceNode],
    cloud: Int = CLOUD_GCP,
    # Whether the target environment's definition allows a developer-access
    # principal on a peer-only edge. Fails closed: see
    # `_wave_developer_access_principal`.
    developer_access_allowed: Bool = False,
) raises:
    """API-EDGE AUTO-EMISSION: for each service whose AppSpec declares
    `inbound: CLIENT` — and for each served `APP_KIND_API` service that declares
    NO `inbound` but DOES author an `ingress {}` block (see the trigger inside) —
    emit ONE `RESOURCE_KIND_API_EDGE` {CATCH_ALL, CLIENT_PASSTHROUGH} node — IFF
    this env's wave has the staging toggle ON (`_wave_api_edge_enabled`; default
    OFF). The node: logical id `<name>-client-edge`, backend `<name>-svc`, empty
    route_path (the CATCH_ALL contract). Emitted on EVERY provider — the
    realization (GCP gateway trio vs the DIRECT no-op) is selected per
    DeployProvider at the MAPPER layer, so the graph shape is identical on every
    target.

    GATEWAY BACKEND-AUTH SA. When ANY client edge is emitted, this ALSO
    self-provisions — ONCE per graph, ordered BEFORE the first API_EDGE node —
    the project-global gateway SA (a `RESOURCE_KIND_SERVICE_ACCOUNT` node,
    account_id `EDGE_GATEWAY_SA_ACCOUNT_ID`) plus a
    `CAPABILITY_SERVICE_ACCOUNT_USER` Grant giving the deploy caller
    (`DEPLOY_PRINCIPAL`) actAs on it. Every API_EDGE node `depends_on` both, so
    the GCP gateway conformer's `CreateApiConfig` — which stamps that SA as
    backend auth — never runs before the SA exists + the actAs binding lands
    (else GCP returns `400 FAILED_PRECONDITION: Service account "…" does not
    exist`). The SA's flat account_id matches the kci binary's projection by
    construction (the shared `EDGE_GATEWAY_SA_ACCOUNT_ID` constant), so the SA
    the graph creates == the SA the ApiConfig stamps.

    THE `inbound: WEBHOOK` -> SINGLE_PATH ARM. It emits ONE
    `{SINGLE_PATH, WEBHOOK_SECRET}` node on the AUTHORED `inbound_route_path`,
    plus the app's `secured_inbound_routes` as additional EDGE-AUTHENTICATED
    routes on that same edge. Without this arm a bundle authoring
    `inbound: INBOUND_NEED_WEBHOOK` would compose NOTHING — it would validate,
    the service would stay private, and the third party's POST would 403 at the
    front end. Still gated by `_wave_api_edge_enabled`, so which ENVS get an edge
    remains a per-wave decision.

    SECURED ROUTES ARE LEGAL ONLY ON THIS ARM. A CLIENT edge is CATCH_ALL — it
    already serves `/**` — so a "secured" path beside it would be one ESPv2
    matching-precedence rule away from being served UNSECURED by the catch-all
    operation. `validate` refuses the combination at authoring; this function
    would drop them silently, which is why the refusal lives there.

    Appended AFTER the grant nodes, in service-declaration order (deterministic).
    """
    if not _wave_api_edge_enabled(bundle, env):
        return
    # GATEWAY BACKEND-AUTH SA. The gateway SA is PROJECT-GLOBAL (one per project,
    # shared by every client edge), so it + its deploy-actAs grant are emitted
    # ONCE per graph — BEFORE the first API_EDGE node — and every API_EDGE node
    # `depends_on` them so `CreateApiConfig` never runs before the SA exists + the
    # deploy principal holds serviceAccountUser on it. Stable per-graph logical
    # ids (not per-service): duplicating the node per client service would
    # collide the id (the SA is global).
    var gateway_sa_id = String("edge-gateway-sa")
    var gateway_sa_grant_id = String("edge-gateway-sa-deploy-sa-user-grant")
    var emitted_gateway_sa = False
    # The per-ENV env overrides, ONE MAP PER SERVICE, positionally aligned with
    # `services` — the same call the service Config nodes are built from. Needed
    # here because the AWS authorizer Lambda is configured with the SERVICE's own
    # effective environment (see the authorizer block below); computed ONCE,
    # outside the loop, because it walks the whole wave.
    var edge_env_overrides = _wave_env_overrides_by_service(
        bundle, env, services
    )
    for si in range(len(services)):
        ref svc = services[si]
        if not svc.spec:
            continue
        var need = svc.spec.value().inbound.value
        var is_client = need == InboundNeed.INBOUND_NEED_CLIENT
        var is_webhook = need == InboundNeed.INBOUND_NEED_WEBHOOK
        # ── AUTO-PROVISIONING ──────────────────────────────────────────────────
        #
        # A serverless application provisions its API Gateway automatically: a
        # served `APP_KIND_API` service gets a CATCH_ALL client edge WITHOUT
        # authoring `inbound: CLIENT` — the front door stops being a thing each
        # bundle has to remember to ask for. (The exact trigger is narrowed
        # below; read that block before changing this one.)
        #
        # AND THAT IS PRECISELY WHY IT CANNOT BE A SILENT WIDENING. A service
        # with no `inbound` is private BY ABSENCE: no edge, so no front door.
        # Auto-provisioning removes the absence. If it also inherited
        # `EdgeCallerClass`'s "UNSPECIFIED means CLIENT_PASSTHROUGH" reading,
        # internal services would acquire PUBLIC pass-through gateways and every
        # signal would stay green. So an AUTO-PROVISIONED edge REFUSES an
        # unanswered caller class (the refusal is a few lines below, once
        # `ingress` has been read).
        #
        # THE ASYMMETRY WITH AN AUTHORED `inbound: CLIENT` IS DELIBERATE. That
        # service's author already stated an inbound need, so UNSPECIFIED there
        # keeps its established meaning. The service that said NOTHING is the
        # one whose intent nobody has recorded, and it is the one being newly
        # exposed — so it is the one that must answer.
        #
        # `POLL` IS NOT AUTO-PROVISIONED. An author who wrote
        # `INBOUND_NEED_POLL` said this app PULLS its work; composing an inbound
        # front door would contradict a stated intent rather than fill a gap.
        # SHARED_INFRASTRUCTURE services are excluded for a harder reason: they
        # compose no `<name>-svc` node at all (`service_serves_nothing`), so the
        # edge's `depends_on` would dangle and Kahn's algorithm silently never
        # schedules it.
        #
        # ── THE TRIGGER IS THE `ingress {}` BLOCK, NOT MERELY THE ABSENCE OF
        #    `inbound` ────────────────────────────────────────────────────────────
        #
        # A service that authors an `ingress {}` block has thought about who may
        # call it; that block is where `caller_class` lives, so the thing that
        # PROVISIONS the gateway and the thing that SECURES it are the same
        # authored fact. There is no ordering in which a gateway appears before
        # the answer does — which is the exposure guard made structural rather
        # than enforced by a check that a later refactor could reorder past.
        #
        # WHAT THIS DOES NOT DO: a service that authors NEITHER `inbound` NOR
        # `ingress` still composes no edge. An internal service acquires its
        # front door by adding the `ingress {}` block that states its caller
        # class.
        var is_auto = (
            need == InboundNeed.INBOUND_NEED_UNSPECIFIED
            and svc.kind.value == AppKind.APP_KIND_API
            and Bool(svc.spec.value().ingress)
        )
        # The CATCH_ALL arm, however it was reached. `is_client` stays the
        # AUTHORED answer so the refusals below can tell the two apart.
        var composes_client_edge = is_client or is_auto
        if not (composes_client_edge or is_webhook):
            continue
        # ── THE INGRESS REALIZATION INPUTS (`AppSpec.ingress`) ───────────────
        #
        # Read once here and carried onto the node; absent block => all empty.
        var ing_gateway_sa = String("")
        var ing_gateway_region = String("")
        var ing_allowed_sources = List[String]()
        var ing_enable_services = False
        var ing_caller_class = EdgeCallerClass.EDGE_CALLER_CLASS_UNSPECIFIED
        var ing_peer_audience = String("")
        if svc.spec.value().ingress:
            ref ing = svc.spec.value().ingress.value()
            ing_gateway_sa = ing.gateway_service_account.copy()
            ing_gateway_region = ing.gateway_region.copy()
            ing_allowed_sources = ing.allowed_sources.copy()
            ing_enable_services = ing.enable_required_services
            ing_caller_class = ing.caller_class.value
            ing_peer_audience = ing.peer_identity_audience.copy()
        # ── THE AUTO-PROVISION EXPOSURE GUARD ─────────────────────────────────
        #
        # AN AUTO-PROVISIONED EDGE MUST SAY WHO MAY CALL IT. This is the single
        # refusal that keeps auto-provisioning from being a security regression,
        # and it is stated as a REFUSAL rather than a default because there is no
        # safe default to pick: PUBLIC on an internal service is an
        # unauthenticated `/**` catch-all in front of it, and PEER_INTERNAL
        # guessed onto a genuinely customer-facing app is a front door nobody can
        # reach.
        #
        # IT FAILS THE COMPOSE, WHICH COSTS A DEPLOY AND IS THE CHEAP OPTION.
        # The alternative — auto-provision and leave the class unanswered — is a
        # gateway that authenticates nobody, standing in front of an internal
        # service, with nothing red.
        #
        # IT NAMES THE FIX, BOTH BRANCHES OF IT. A peer service answers
        # PEER_INTERNAL + `peer_identity_audience` (and its wave a
        # `peer_identity_issuer`); a deliberately public one answers PUBLIC. The
        # message says both because an operator hitting this is by construction
        # someone who has never thought about this field.
        if (
            is_auto
            and ing_caller_class
            == EdgeCallerClass.EDGE_CALLER_CLASS_UNSPECIFIED
        ):
            raise Error(
                String(
                    "compose_api: service '"
                    + svc.name
                    + "' authors no `inbound`, so this composer AUTO-PROVISIONS"
                    " an API Gateway for it — and it answers no"
                    " `ingress.caller_class`, so this composer cannot tell"
                    " whether the internet may call it.\n\n  Without the"
                    " gateway this service is private BY ABSENCE: no inbound"
                    " need, no edge, no front door. Auto-provisioning removes"
                    " that absence, so the question has to be ANSWERED rather"
                    " than left unasked. Composing the pass-through default (a"
                    " CLIENT_PASSTHROUGH"
                    " edge) would publish an unauthenticated `/**` catch-all in"
                    " front of this service, silently.\n\n  Answer it on the"
                    " service's `spec { ingress { … } }`:\n    an INTERNAL"
                    " service ->  caller_class:"
                    " EDGE_CALLER_CLASS_PEER_INTERNAL\n                      "
                    "  peer_identity_audience: \"<this app's own audience>\"\n "
                    "                       (and `peer_identity_issuer` on the"
                    " wave for this env)\n    a PUBLIC app        -> "
                    " caller_class: EDGE_CALLER_CLASS_PUBLIC\n\nNothing was"
                    " deployed."
                )
            )
        # AN AUDIENCE UNDER ANY CLASS BUT PEER_INTERNAL IS REFUSED, not
        # ignored. Nothing else reads the field, so an author who set it under
        # PUBLIC would believe their public edge was checking `aud` — and the
        # composed edge would be an honest pass-through that never contradicts
        # them. This is the intent-tier mirror of the mapper's refusal of a
        # resolved `identity_issuer` under a non-identity mode.
        if (
            ing_caller_class != EdgeCallerClass.EDGE_CALLER_CLASS_PEER_INTERNAL
            and ing_peer_audience.byte_length() > 0
        ):
            raise Error(
                String(
                    "compose_api: service '"
                    + svc.name
                    + "' authors ingress.peer_identity_audience ('"
                    + ing_peer_audience
                    + "') but its caller_class is not"
                    " EDGE_CALLER_CLASS_PEER_INTERNAL, so no edge auth reads"
                    " it. The composed edge would be an unauthenticated"
                    " pass-through while the bundle states an accepted"
                    " audience."
                )
            )
        # A CALLER CLASS ON A **WEBHOOK** INBOUND IS REFUSED, because the
        # webhook arm below does not read it — authoring
        # `EDGE_CALLER_CLASS_PEER_INTERNAL` on an `inbound: INBOUND_NEED_WEBHOOK`
        # service would otherwise compose an `EDGE_AUTH_MODE_WEBHOOK_SECRET`
        # pass-through edge, silently, with an empty issuer and no error.
        #
        # THE FORK THAT READS `caller_class` LIVES INSIDE THE CLIENT-EDGE
        # BRANCH. A field whose ONE reader is behind a branch needs a refusal on
        # the OTHER branch, or the branch IS the else.
        #
        # BOTH non-zero values are refused, not just PEER_INTERNAL: `PUBLIC` on a
        # webhook edge is equally unread, and an author who wrote it believes
        # this composer agreed with them.
        #
        # THE PREDICATE IS `not composes_client_edge`, NOT `not is_client`.
        # Auto-provisioning is a SECOND way to reach the CATCH_ALL arm, and an
        # auto-provisioned service is REQUIRED to answer `caller_class` — so
        # `not is_client` here would refuse exactly the bundles the guard above
        # just forced to answer.
        if not composes_client_edge and (
            ing_caller_class != EdgeCallerClass.EDGE_CALLER_CLASS_UNSPECIFIED
        ):
            raise Error(
                String(
                    "compose_api: service '"
                    + svc.name
                    + "' authors ingress.caller_class on an"
                    " `inbound: INBOUND_NEED_WEBHOOK` service. The webhook arm"
                    " composes EDGE_AUTH_MODE_WEBHOOK_SECRET unconditionally and"
                    " reads neither caller_class nor peer_identity_audience, so"
                    " a PEER_INTERNAL answer here would compose an"
                    " unauthenticated pass-through edge while the bundle states"
                    " the edge is peer-only. Refusing rather than discarding the"
                    " answer: author it on an `inbound: INBOUND_NEED_CLIENT`"
                    " service, or extend the webhook arm to honour it."
                )
            )
        # AN AUTHORED GATEWAY IDENTITY IS PRE-EXISTING, SO THIS GRAPH NEITHER
        # CREATES IT NOR GRANTS actAs ON IT — and that is a decision, not an
        # omission.
        #
        # The self-provisioned path below exists because the project-global
        # gateway SA is the graph's own: the graph creates it, so the graph must
        # also give the deploy caller `actAs` on it or the ApiConfig create
        # returns FAILED_PRECONDITION. An AUTHORED account is the exact opposite
        # case — it is named by an operator who already has one. Emitting a
        # create node for an account we do not own would fight whoever does;
        # emitting an actAs grant on it would be a set-IAM-policy on a resource
        # this graph cannot assume exists, which 404s at apply rather than at
        # validate.
        #
        # THE CONSEQUENCE: an authored account must ALREADY hold whatever the
        # deploy caller needs to stamp it (self-actAs when it IS the deploy
        # caller, and an explicit binding otherwise). That is a live-IAM fact no
        # offline check can see, so nothing here pretends to check it.
        #
        # ── AND IT IS GCP-ONLY. ON AWS THIS PAIR IS COMPOSED FOR NOBODY.
        #
        # The self-provisioned SA exists to satisfy ONE GCP call: `CreateApiConfig`
        # stamps a backend-auth service account and returns
        # `400 FAILED_PRECONDITION` if it does not exist. AWS's HTTP API has no
        # such field — API Gateway invokes a Lambda as the SERVICE PRINCIPAL
        # `apigateway.amazonaws.com`, authorised by a RESOURCE POLICY on the
        # function — which is exactly why the AWS mapper REFUSES an authored
        # `gateway_service_account` BY NAME (there is no account the edge mints
        # a backend-hop token as).
        #
        # ⇒ SO COMPOSING THE PAIR ON AN AWS ENV WOULD CREATE AN IAM ROLE AND AN
        #   actAs-SHAPED GRANT THAT NOTHING READS, and the grant's capability is
        #   `CAPABILITY_SERVICE_ACCOUNT_USER` (14) — one of the capabilities
        #   `_grant_composes_on_cloud` already refuses to compose on AWS because
        #   AWS has no peer for them. Emitting it here would re-open the same
        #   hole through a second door.
        var self_provisioned_sa = (
            ing_gateway_sa.byte_length() == 0 and cloud != CLOUD_AWS
        )
        if self_provisioned_sa and not emitted_gateway_sa:
            # (a) CREATE the gateway backend-auth SA (flat account_id — the mapper's
            #     SA conformer derives `<account_id>@<project>...`, matching the email
            #     the kci binary stamps on the ApiConfig by construction).
            nodes.append(
                _service_account_node(
                    gateway_sa_id.copy(),
                    EDGE_GATEWAY_SA_ACCOUNT_ID,
                    String("kci API-Gateway backend-auth SA"),
                    # RETAIN_KEEP — PROJECT-GLOBAL and composed identically into
                    # EVERY edge-bearing app's graph, so under RETENTION_DELETE
                    # the FIRST app deleted takes the SA out from under all the
                    # others. See SHARED_RESOURCE_RETENTION at the head of this
                    # file. Convergence is unchanged: every graph still ENSURES
                    # it (get-or-create), which is what makes N creators correct
                    # and 1 deleter wrong.
                    Retention.RETENTION_RETAIN_KEEP,
                )
            )
            # (b) GRANT the deploy caller serviceAccountUser (actAs) on the
            #     gateway SA — required to stamp it as the ApiConfig backend auth.
            #     depends_on the SA node (grant-after-SA-exists); the principal
            #     expands to the full deploy email at the mapper, the target
            #     expands to the gateway SA email at the mapper.
            var grant_deps = List[String]()
            grant_deps.append(gateway_sa_id.copy())
            nodes.append(
                _base_grant_node(
                    gateway_sa_grant_id.copy(),
                    DEPLOY_PRINCIPAL,  # deploy principal (mapper -> full email)
                    Capability.CAPABILITY_SERVICE_ACCOUNT_USER,  # roles/iam.serviceAccountUser
                    EDGE_GATEWAY_SA_ACCOUNT_ID,  # target = gateway SA (mapper -> full email)
                    grant_deps^,
                    # RETAIN_KEEP — BOTH ends foreign to this graph: the deploy
                    # principal is bootstrap's, and the target is the
                    # project-global gateway SA immediately above (which this
                    # graph retains rather than owns). Unbinding it on one app's
                    # teardown makes the NEXT edge deploy of ANY OTHER app fail
                    # `CreateApiConfig` with FAILED_PRECONDITION, which is the
                    # exact failure this pair of nodes is here to prevent.
                    Retention.RETENTION_RETAIN_KEEP,
                )
            )
            emitted_gateway_sa = True
        var backend_id = svc.name + String("-svc")
        var deps = List[String]()
        deps.append(backend_id.copy())
        # ORDER the ApiConfig create AFTER the gateway SA exists + actAs is granted.
        # ONLY when this graph is the one creating that SA: an edge that names a
        # pre-existing identity has no such node to wait for, and depending on a
        # logical_id no node carries is a dangling edge the topo-sort rejects.
        if self_provisioned_sa:
            deps.append(gateway_sa_id.copy())
            deps.append(gateway_sa_grant_id.copy())
        if composes_client_edge:
            # ── WHO MAY CALL THIS EDGE (`IngressSpec.caller_class`) ──────────
            #
            # THE ONE FORK THAT SEPARATES A CUSTOMER-FACING FRONT DOOR FROM AN
            # INTERNAL PEER. Both arms compose the same CATCH_ALL edge on the
            # same backend; they differ ONLY in what the edge demands of a
            # caller, and getting that backwards puts an internal service on
            # the internet. Every arm below is written out — there is no `else`
            # falling through to the permissive one.
            var edge_mode = EdgeAuthMode.EDGE_AUTH_MODE_CLIENT_PASSTHROUGH
            var edge_issuer = String("")
            var edge_audience = String("")
            var edge_dev_principal = String("")
            if (
                ing_caller_class
                == EdgeCallerClass.EDGE_CALLER_CLASS_PEER_INTERNAL
            ):
                edge_mode = EdgeAuthMode.EDGE_AUTH_MODE_IDENTITY_JWT
                edge_issuer = _wave_peer_identity_issuer(bundle, env)
                edge_audience = ing_peer_audience.copy()
                # PEER-ONLY AND `public_invoker: true` CANNOT BOTH BE TRUE OF
                # ONE SERVICE: together they would compose an IDENTITY_JWT edge
                # AND an `allUsers -> roles/run.invoker` grant on the same
                # backend, in the same graph.
                #
                # THE EDGE IS NOT THE ONLY DOOR. `public_invoker` binds the
                # literal IAM member `allUsers` on the service's OWN
                # `*.run.app` URL, which the gateway config publishes as its
                # `x-google-backend: address`. So an edge that refuses a request
                # without a valid identity token refuses it only on the path
                # through the edge, while the address the edge names takes
                # anyone.
                #
                # The two fields are separately correct and jointly a
                # contradiction, so the refusal is here rather than a comment
                # asking a reader to notice: `EDGE_CALLER_CLASS_PEER_INTERNAL`
                # states an intent about WHO MAY CALL THE APP, and a bundle
                # cannot state that and also open the app to everyone.
                if svc.spec.value().public_invoker:
                    raise Error(
                        String(
                            "compose_api: service '"
                            + svc.name
                            + "' is EDGE_CALLER_CLASS_PEER_INTERNAL AND authors"
                            " `public_invoker: true`. The peer-only edge would"
                            " demand an identity token from the peers' issuer"
                            " while the SAME backend's own Cloud Run URL — the"
                            " address that edge publishes as `x-google-backend`"
                            " — is bound to the IAM member `allUsers`, i.e."
                            " reachable unauthenticated by anyone who reads the"
                            " composed config. Edge auth is not a reachability"
                            " boundary. Drop one: `public_invoker` for a peer"
                            " service, or the PEER_INTERNAL answer for a"
                            " deliberately public one."
                        )
                    )
                # A PEER-ONLY SERVICE IN AN ENV THAT NAMES NO ISSUER IS A
                # REFUSAL, NEVER A PASS-THROUGH. The tempting fallback — "no
                # issuer for this env, so compose a CLIENT_PASSTHROUGH edge" —
                # silently publishes an internal service to the internet, and it
                # does so on the env where somebody forgot a field. Failing the
                # compose is loud and costs a deploy; the fallback is quiet.
                if edge_issuer.byte_length() == 0:
                    raise Error(
                        String(
                            "compose_api: service '"
                            + svc.name
                            + "' is EDGE_CALLER_CLASS_PEER_INTERNAL but the"
                            " wave for env '"
                            + env
                            + "' names no peer_identity_issuer. Composing"
                            " anyway would emit a PASS-THROUGH edge — a public"
                            " `/**` front door on an internal service — so"
                            " this refuses instead. Author"
                            " `peer_identity_issuer` on that wave (the token"
                            " issuer THIS env's peers trust)."
                        )
                    )
                if edge_audience.byte_length() == 0:
                    raise Error(
                        String(
                            "compose_api: service '"
                            + svc.name
                            + "' is EDGE_CALLER_CLASS_PEER_INTERNAL but"
                            " authors no ingress.peer_identity_audience. An"
                            " empty audience renders an empty"
                            " `x-google-audiences`, which does NOT mean 'the"
                            " default audience' — it means the edge stops"
                            " checking `aud` and admits any token this issuer"
                            " ever signed, for any service."
                        )
                    )
                # The authenticated developer-access principal.
                # `_wave_developer_access_principal` RAISES when the caller's
                # environment definition does not allow developer access, so
                # such an env cannot reach the node builder with a value — and
                # a wave that authors none returns "".
                edge_dev_principal = _wave_developer_access_principal(
                    bundle, env, developer_access_allowed
                )
            elif (
                ing_caller_class
                != EdgeCallerClass.EDGE_CALLER_CLASS_UNSPECIFIED
                and ing_caller_class
                != EdgeCallerClass.EDGE_CALLER_CLASS_PUBLIC
            ):
                # AN UNRECOGNISED CALLER CLASS IS A REFUSAL. A new enum value
                # reaching an old composer must not resolve to the most
                # permissive arm — that is how a future "internal" class ships
                # as a public edge.
                raise Error(
                    String(
                        "compose_api: service '"
                        + svc.name
                        + "' carries an ingress.caller_class this composer does"
                        " not know. Refusing rather than defaulting to the"
                        " pass-through arm, which would publish it."
                    )
                )
            var edge_id = svc.name + String("-client-edge")
            # ── THE AWS FRONT DOOR'S SECOND DEPLOYABLE ───────────────────────
            #
            # On AWS an application's identity-checked front door is an API
            # Gateway HTTP API plus a CUSTOM REQUEST Lambda authorizer that
            # verifies the caller's token against the issuer.
            #
            # WITHOUT THIS BLOCK KIND 19 MAPS FOR NOTHING. The AWS mapper's edge
            # arm resolves its authorizer FROM THE MANIFEST and REFUSES a derived
            # ARN, because `CreateAuthorizer` validates an invoke URI's SHAPE and
            # never its existence — a fabricated one is ACCEPTED and the door
            # then answers 500 to every request behind a green plan.
            #
            # TWO NODES, NOT ONE, AND THE SECOND IS THE POINT. The mapper ALSO
            # pins the edge's `identity_issuer`/`identity_audience` BY VALUE
            # against the environment it derives for the AUTHORIZER — because on
            # AWS a CUSTOM REQUEST authorizer has NO field for either value, so
            # an arm that merely required them non-empty on the EDGE would be
            # honouring them NOWHERE. The CONFIG node below is what makes that
            # pin satisfiable, and it must be in the authorizer's own
            # `depends_on` CLOSURE (the mapper walks the closure, never the id).
            #
            # THE KEYS ARE THE AUTHORIZER'S OWN CONTRACT, DECLARED BY THE
            # BUNDLE, NOT INVENTED HERE. The mapper compares VALUES precisely so
            # this composer does not become a second author of that contract.
            #
            # GCP COMPOSES NEITHER NODE, and that is not symmetry for its own
            # sake: on GCP the EDGE carries the issuer and audience directly
            # (`x-google-issuer` / `x-google-audiences`), so an authorizer
            # container there would be a second Cloud Run service nothing calls.
            if (
                cloud == CLOUD_AWS
                and edge_mode == EdgeAuthMode.EDGE_AUTH_MODE_IDENTITY_JWT
            ):
                var authz_id = edge_id + String(EDGE_AUTHORIZER_SUFFIX)
                # The env keys the authorizer reads the issuer and audience from.
                # Bundle-declared; `_authorizer_env_key` refuses when the schema
                # cannot carry the declaration.
                var issuer_key = _authorizer_env_key(
                    svc.name, String("authorizer_issuer_env")
                )
                var audience_key = _authorizer_env_key(
                    svc.name, String("authorizer_audience_env")
                )
                # THE IMAGE IS AUTHORED, NEVER DERIVED FROM THE BACKEND'S.
                # Pointing the authorizer at the application's own image is the
                # app authorizing itself — CLIENT_PASSTHROUGH wearing an
                # authorizer's name — which the AWS edge spec refuses one layer
                # down. So the bundle must declare the authorizer's own
                # `build {}`, and its NAME is the authorizer node's id: ONE
                # derivation, so the refusal below is trivially actionable and
                # there is no second naming convention to keep in sync.
                var authz_build = String("")
                for bi in range(len(bundle.build)):
                    if bundle.build[bi].name == authz_id:
                        authz_build = bundle.build[bi].name.copy()
                        break
                if authz_build.byte_length() == 0:
                    raise Error(
                        String(
                            "compose_api: service '"
                            + svc.name
                            + "' composes an EDGE_AUTH_MODE_IDENTITY_JWT client"
                            " edge on an AWS env, and the AWS front door is an"
                            " API Gateway HTTP API plus a CUSTOM REQUEST"
                            " authorizer that verifies the caller's token. That"
                            " authorizer is a SECOND DEPLOYABLE — a Lambda of its"
                            " own, not a setting on the edge — and this bundle"
                            " declares no `build { name: \""
                            + authz_id
                            + "\" }` for it.\n\n  REFUSING rather than"
                            " deriving one: `CreateAuthorizer` validates an"
                            " invoke URI's SHAPE and never its existence, so a"
                            " fabricated authorizer is ACCEPTED and the door"
                            " then answers 500 to EVERY request with the plan"
                            " green, the address resolving and nothing served."
                            " Pointing it at the application's own image"
                            " instead would be the app authorizing itself.\n\n"
                            "  ⇒ Declare `build { name: \""
                            + authz_id
                            + "\" dockerfile: \"//<the authorizer image>\" }`."
                            "\n\nNothing was deployed."
                        )
                    )
                var authz_cfg_id = authz_id + String("-config")
                # ── THE AUTHORIZER'S ENVIRONMENT IS THE SERVICE'S, PLUS THE
                #    TWO IDENTITY VALUES THE EDGE OWNS.
                #
                # An authorizer configured with ONLY the two identity keys cannot
                # read anything else its own boot requires: the door is created,
                # `CreateAuthorizer` accepts it, the plan reads GREEN — and the
                # authorizer then fails its own boot, so a publicly reachable
                # door answers 500 to every request forever.
                #
                # THE CONTRACT IS DELIBERATELY PRODUCT-NEUTRAL: this composer
                # does NOT know which keys a given authorizer wants, and MUST NOT
                # — naming one product's keys here is how a generic composer
                # becomes a second author of somebody else's env contract. What
                # it knows is structural: the authorizer and the backend are TWO
                # PROCESSES OF ONE PRODUCT standing at one door, so the
                # authorizer is configured with the service's own environment.
                # That makes agreement a GUARANTEE rather than a convention — a
                # second `authorizer_env {}` block would be a second place for
                # the same values to drift, and a door that trusts a different
                # issuer than the handler admits tokens the handler then rejects.
                #
                # LITERALS ONLY, and the omission is the same judgement the AWS
                # mapper makes one tier down: a `service_ref` entry composes the
                # `__SVCREF` marker, which is resolved at RUNTIME by a resolver a
                # Lambda does not have (the AWS config-env render refuses that
                # suffix by name). Copying it would hand the authorizer a
                # variable literally NAMED with the suffix. The service's OWN
                # config node carries the same marker and gaps at the same place,
                # so the fault is reported once, at the node that authored it.
                var authz_cfg = Dict[String, String]()
                for i in range(len(svc.spec.value().env)):
                    if svc.spec.value().env[i]._oneof0_case == 1:  # literal arm
                        authz_cfg[
                            svc.spec.value().env[i].name.copy()
                        ] = svc.spec.value().env[i].value.value().copy()
                # The per-ENV override overlay, applied for the SAME reason and in
                # the SAME order the service's own Config node applies it: an
                # override REPLACES the env-neutral default, and an authorizer
                # reading the pre-override value would disagree with the handler
                # on exactly the envs somebody bothered to override.
                for entry in edge_env_overrides[si].items():
                    authz_cfg[entry.key.copy()] = entry.value.copy()
                # AND NOW THE TWO THE EDGE OWNS — WRITTEN LAST, SO THEY WIN.
                # They stay DERIVED FROM THE EDGE and are never taken from the
                # bundle's env, because that is what keeps the mapper's identity
                # pin meaningful: it compares the EDGE's two identity fields
                # against the environment derived for the AUTHORIZER, and a
                # bundle allowed to author the authorizer side directly could
                # satisfy the pin while disagreeing with the door.
                #
                # BUT A SERVICE THAT AUTHORS A **DIFFERENT** VALUE IS A REFUSAL,
                # NOT A SILENT OVERWRITE. The handler re-runs the identity check
                # itself and does NOT trust the authorizer's verdict (the door
                # answers "who are you", the handler answers "may you"), so the
                # two processes read these keys from their own environments. If
                # they disagree, the door admits tokens the handler then rejects
                # — a 403 from the application for a request the gateway said yes
                # to, with nothing anywhere naming the disagreement. Overwriting
                # quietly would BUILD that state; the refusal names both values.
                _refuse_authorizer_identity_conflict(
                    svc.name,
                    authz_id,
                    issuer_key,
                    authz_cfg,
                    edge_issuer,
                    String(
                        "the ISSUER the door trusts. The authorizer would verify"
                        " the caller's token against one issuer's published"
                        " JWKS while the handler behind it verifies against"
                        " another"
                    ),
                )
                _refuse_authorizer_identity_conflict(
                    svc.name,
                    authz_id,
                    audience_key,
                    authz_cfg,
                    edge_audience,
                    String(
                        "the AUDIENCE every accepted token must name. The door"
                        " would admit tokens minted for a different deployment"
                        " than the one the handler pins"
                    ),
                )
                authz_cfg[issuer_key] = edge_issuer.copy()
                authz_cfg[audience_key] = edge_audience.copy()
                nodes.append(
                    _config_node(
                        authz_cfg_id.copy(), List[String](), authz_cfg^
                    )
                )
                # ── THE DOOR'S OWN EXECUTION IDENTITY, CREATED BY THIS GRAPH.
                #
                # The authorizer function needs a role to run as, and nothing
                # else creates one: unlike `<svc>-role` (minted by bootstrap when
                # a bundle authors no `runtime_identity`), `<authz>-role` has no
                # other owner. So this emission is UNCONDITIONAL — making it
                # track `self_provision` would leave every bundle that does not
                # self-provision with a `CreateFunction` that fails with
                # "The role defined for the function cannot be assumed by
                # Lambda" (AWS returns that exact string for a role that does
                # not exist as well as for one with a wrong trust document, which
                # makes the failure read like a policy bug when it is not one).
                #
                # AND IT IS **NOT** THE SERVICE'S ROLE. `<svc>-role` carries this
                # app's DATA-PLANE authority (the bootstrap bucket, the artifact
                # repo, the datastore) via `_append_runtime_sa_and_base_grants`,
                # and the authorizer is the ONE process in this product that
                # unauthenticated traffic reaches BY DESIGN — deciding whether to
                # admit it is its whole job. One IAM principal for both would
                # make the door/handler split unenforceable a tier down: audit
                # logs, a resource policy and every future `Condition` would see
                # ONE identity where the split says two.
                #
                # NOTHING IS GRANTED HERE, AND THAT IS THE LEAST-PRIVILEGE HALF.
                # The AWS mapper DERIVES this role's policy set from the
                # manifest (its own log group, and the reads its configuration
                # names, found by walking the `depends_on` CLOSURE and therefore
                # reaching the authorizer's own config node above). A
                # `_base_grant_node` here would hand it capabilities it never
                # calls.
                #
                # THE ID AND THE ACCOUNT_ID ARE ONE DERIVATION EACH, mirroring
                # `<svc>-role-sa` / `<svc>-role` exactly, so an operator reads
                # one convention for both halves of the product.
                var authz_runtime_id = authz_id + String("-role")
                var authz_sa_id = authz_runtime_id + String("-sa")
                nodes.append(
                    _service_account_node(
                        authz_sa_id.copy(),
                        authz_runtime_id.copy(),
                        String("kci ") + authz_id + String(" execution SA"),
                    )
                )
                var authz_deps = List[String]()
                authz_deps.append(authz_cfg_id.copy())
                # ORDER the function AFTER the role it runs as. A missing edge
                # is not a topo-sort error — Kahn's algorithm schedules the
                # function whenever — and a `CreateFunction` that wins the race
                # against `CreateRole` fails with the identical 400 above.
                authz_deps.append(authz_sa_id^)
                # `min_scale` IS 0 AND MUST STAY 0. Lambda has no minimum-scale
                # knob — warm capacity is PROVISIONED CONCURRENCY, a separate
                # resource this arm does not model — so the AWS compute arm
                # REFUSES `min_scale > 0`.
                # `max_scale` tracks the SERVICE's, because a door cannot admit
                # more concurrency than its authorizer can answer.
                nodes.append(
                    _serverless_node(
                        authz_id.copy(),
                        authz_deps^,
                        FROM_BUILD_DIGEST_MARKER_PREFIX + authz_build,
                        Int32(8080),
                        Int32(0),
                        (
                            svc.spec.value().scaling.value().max
                            if svc.spec.value().scaling
                            else Int32(1)
                        ),
                        # THE SAME STRING THE SA NODE ABOVE CARRIES AS ITS
                        # `account_id` — one variable, two sinks, the
                        # `_runtime_identity_of` contract. Two spellings here
                        # `_runtime_identity_of` contract. Two spellings here
                        # would create a role under one name and point the
                        # function at another, failing with the identical 400.
                        authz_runtime_id^,
                        Optional[SupervisorSpec](None),
                        Optional[Int32](None),
                        List[String](),
                        Optional[Int32](None),
                        Optional[NetworkEgressSpec](None),
                        # THE GATE IS HANDED THE CLOUD HERE TOO EVEN THOUGH
                        # THIS SITE PASSES A LITERAL 0. It costs nothing and it
                        # is what makes the gate's exclusivity real: the day
                        # somebody threads a non-zero value into the authorizer
                        # (a warm door is a plausible ask), the gate is already
                        # in the path rather than needing to be remembered.
                        cloud,
                        # NO ALLOCATION, AND THAT IS NOT AN OMISSION — IT IS
                        # THE ANSWER. This node is the API-edge AUTHORIZER, a
                        # PLATFORM-synthesized companion function, not the
                        # customer's served app. `AppSpec.cpu`/`.memory` is the
                        # APP's declared allocation; copying it here would state
                        # the same allocation TWICE out of ONE declaration and
                        # double-count the app's own bill against a second
                        # compute unit. So UNSET, which is the honest "the bundle
                        # declared nothing about this unit".
                        None,  # cpu — the APP's, not this companion's
                        None,  # memory — likewise
                        # THE HEALTHCHECK ENDPOINT — `None`, FOR THE SAME REASON
                        # AND ONE STRONGER. `AppSpec.health_check_path` names a
                        # path the CUSTOMER'S APP serves; this node is a
                        # PLATFORM-synthesized authorizer function running a
                        # different image. Copying the app's path here would make
                        # the placement service probe THIS unit for an endpoint
                        # it does not serve. The authorizer therefore declares no
                        # healthcheck and is `NOT_GATED`.
                        None,  # health_check_path — the APP's, not this companion's
                    )
                )
                # ORDER the door AFTER the Lambda it delegates every decision
                # to. A route bound to an authorizer that does not exist yet is
                # created without complaint and 500s until it does.
                deps.append(authz_id.copy())
            nodes.append(
                _api_edge_node(
                    edge_id^,
                    backend_id^,
                    RouteMode.ROUTE_MODE_CATCH_ALL,
                    String(""),  # empty under CATCH_ALL (the CATCH_ALL contract)
                    edge_mode,
                    deps^,
                    List[SecuredEdgeRoute](),
                    ing_gateway_sa^,
                    ing_gateway_region^,
                    ing_allowed_sources^,
                    ing_enable_services,
                    edge_issuer^,
                    edge_audience^,
                    edge_dev_principal^,
                )
            )
            continue
        # ── the SINGLE_PATH (webhook inbound) arm ────────────────────────────
        #
        # The route is the AUTHORED `inbound_route_path` — never a baked default.
        # `validate` already requires it under WEBHOOK; the mapper fail-fasts on
        # an empty one, so a bundle that slipped past both produces an error
        # naming the field rather than a gateway serving `:`.
        nodes.append(
            _api_edge_node(
                svc.name + String("-inbound-edge"),
                backend_id^,
                RouteMode.ROUTE_MODE_SINGLE_PATH,
                svc.spec.value().inbound_route_path.copy(),
                EdgeAuthMode.EDGE_AUTH_MODE_WEBHOOK_SECRET,
                deps^,
                _secured_edge_routes_of(svc.spec.value()),
                ing_gateway_sa^,
                ing_gateway_region^,
                ing_allowed_sources^,
                ing_enable_services,
            )
        )


# =============================================================================
# ── THE SCHEDULED CALL — `AppBundle.crons[]` -> a graph node ───────────────────
# =============================================================================
#
# WHAT IT IS FOR. A min=0 service that owes the world a periodic call (a
# reconcile backstop, say) has no way to tick itself, so the cron IS its
# liveness. A cron created by a hand-rolled script next to the deploy is gated
# by nothing; composing it from the bundle puts it in the graph.
#
# THE CRON IS TWO NODES, NOT ONE, AND THAT IS THE WHOLE AUTH STORY. The invoker
#   grant and the cron create are only correct together: a cron whose SA holds no
#   `run.invoker` gets a 403 with an empty body on every tick, forever, behind a
#   green deploy. So `_append_cron_nodes` emits, per authored cron:
#     (a) a `RESOURCE_KIND_GRANT` {invoker identity, INVOKE_SERVICE, <T>-svc} —
#         the SAME `_grant_node` the cross-service path uses, ordered after the
#         target (grant-after-target-exists), and
#     (b) the `RESOURCE_KIND_SCHEDULED_CALL` node, which `depends_on` BOTH.
#   The scheduler object is therefore never created before the identity it
#   authenticates as is authorized to call the thing it calls.
#
# ONE IDENTITY FIELD, DELIBERATELY. `CronSpec.invoker_identity` is BOTH the
#   OIDC subject the scheduler mints as AND the member of that grant. Two fields
#   could name two accounts and the failure is a 403 at the backend that reads
#   exactly like a missing binding (the `IngressSpec.gateway_service_account` /
#   `SecuredInboundRoute.sa_email` precedent).
#
# WHAT THE SERVICE PATH ENFORCES, DECIDED EXPLICITLY FOR THIS KIND:
#   * AUTHENTICATING CONFIGURATION — YES, ENFORCED, and it is the (a) node above.
#     There is no unauthenticated arm: an EMPTY `invoker_identity` resolves to the
#     TARGET's own runtime identity, never to "no auth".
#   * REGION FROM THE ENV BINDING — YES. The scheduler object's region is NOT on
#     this node: the mapper takes the deploy's bound region (and the conformer's
#     `nearest_supported()` remap, because Cloud Scheduler does not exist in every
#     region a service can deploy to). An authored region here would be a second
#     source of truth for something the env binding already states.
#   * DIGEST PINNING — N/A. A cron ships no image; there is nothing to pin.
#   * THE /healthz READINESS GATE — N/A as a traffic gate, and NOT skipped: the
#     cron's target is a served node this same graph creates, and THAT node's
#     health gate already governs whether it serves. The cron `depends_on` it, so
#     the scheduler object is not created until the service it calls is up.
#   * THE ADDRESS — NOT AUTHORED. See `ScheduledCallSpec`: the url and the OIDC
#     audience are both derived from the ONE observed backend address at apply
#     time, by one formatter.


def _scheduled_call_node(
    var logical_id: String,
    var target_logical_id: String,
    var cron: String,
    var timezone: String,
    var path: String,
    var http_method: String,
    var invoker_identity: String,
    attempt_deadline_seconds: Int,
    var depends_on: List[String],
) raises -> ResourceNode:
    """The ScheduledCall node (kind 21, config oneof arm 20, field 24) — a
    wall-clock cron calling a served node in THIS graph.

    RETENTION_DELETE (app-owned): a cron holds no data, no domain and no cert,
    and is deterministically recreatable from the bundle — the `_api_edge_node`
    reasoning, unchanged. `depends_on` carries the target's served node AND
    the invoker grant; both edges are real (the scheduler object must not exist
    before the thing it calls, nor before that call is authorized).

    Vendor-neutral: NO vendor product rides here — "Cloud Scheduler" is named
    only inside the conformer."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_SCHEDULED_CALL),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        20,
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 1-19
        Optional[ScheduledCallSpec](
            ScheduledCallSpec(
                target_logical_id^,
                cron^,
                timezone^,
                path^,
                http_method^,
                invoker_identity^,
                Int32(attempt_deadline_seconds),
            )
        ),  # arm 20 (scheduled_call, field 24)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _append_cron_nodes(
    bundle: AppBundle,
    services: List[ServiceSpec],
    mut nodes: List[ResourceNode],
) raises:
    """CRON AUTO-EMISSION: per `bundle.crons[]`, in declaration order, emit the
    invoker GRANT then the SCHEDULED_CALL node that depends on it.

    NOT GATED BY A WAVE TOGGLE, unlike the API edge. An edge is a rollout
    decision (which envs get a front door); a periodic backstop is not — a cron
    that exists in one env and silently not in another is an asymmetry nothing
    would surface. A bundle that authors no `crons {}` composes no cron node.

    FAIL-CLOSED ON AN UNKNOWN TARGET. `validate` already refuses a cron whose
    `target { service: … }` is not a service this bundle declares, and it refuses
    it at AUTHORING with the served-name list in the message. This re-checks
    against the ACTUALLY-COMPOSED service list rather than trusting that, because
    the two can differ — `_auto_lifted_services` is what decides which services a
    bundle composes, and a cron pointing at a name that validates but does not
    compose would emit a `depends_on` edge to a node that is not in the graph.
    Kahn's algorithm does not fail on a dangling edge; it silently never schedules
    the node. So this raises instead.

    THE LOGICAL IDS are `<cron-name>-cron` and `<cron-name>-cron-invoke-grant`,
    derived from the AUTHORED cron name (unique within the bundle — `validate`
    enforces that), so two crons on one service cannot collide."""
    for i in range(len(bundle.crons)):
        ref c = bundle.crons[i]
        if not c.target:
            raise Error(
                String("compose_api: cron '")
                + c.name
                + String(
                    "' has no `target { service: \"<name>\" }`. A cron with no"
                    " target is a cron whose invoker binding this deploy cannot"
                    " make, and a cron that cannot invoke is a no-op behind a"
                    " green deploy. (`validate` refuses this at authoring; this"
                    " is the compose-side backstop.)"
                )
            )
        var target = c.target.value().service.copy()
        var target_idx = _svc_declared(services, target)
        if target_idx < 0:
            raise Error(
                String("compose_api: cron '")
                + c.name
                + String("' targets service '")
                + target
                + String(
                    "', which this bundle does not COMPOSE. `depends_on` an"
                    " absent node does not fail the topo sort — it silently"
                    " never schedules the cron, so the deploy reports converged"
                    " with no cron. Name a service this bundle declares."
                )
            )
        # AND "DECLARED" IS NOT THE SAME QUESTION AS "COMPOSES A SERVED NODE".
        # A RESOURCE-OWNER service is declared and composes NO `<name>-svc` node
        # — so a cron aimed at it would pass the check above and emit
        # `depends_on <owner>-svc` against a node that does not exist: precisely
        # the dangling edge the paragraph above says this function exists to
        # prevent.
        if service_serves_nothing(services[target_idx]):
            raise Error(
                String("compose_api: cron '")
                + c.name
                + String("' targets service '")
                + target
                + String(
                    "', which OWNS A RESOURCE AND SERVES NOTHING (`kind:"
                    " APP_KIND_SHARED_INFRASTRUCTURE`) — it composes no"
                    " ServerlessCompute node, so there is nothing for a scheduled"
                    " call to invoke. The cron would `depends_on` a node that does"
                    " not exist, never be scheduled, and the deploy would report"
                    " converged with no cron. Name a SERVED service."
                )
            )
        var backend_id = target + String("-svc")
        # EMPTY invoker identity ⇒ the TARGET's own runtime identity. NEVER "no
        # auth": an unauthenticated arm here is how a scheduled call to a private
        # service becomes a scheduled call to a public one.
        #
        # `_runtime_identity_of` is TOTAL — it falls back to the derived
        # `<service>-role` — so this branch always produces a real principal and
        # there is no "empty identity" arm to fall through. That is the point:
        # the composed graph has no shape in which a scheduled call exists
        # without an identity and a grant.
        var invoker = c.invoker_identity.copy()
        if invoker.byte_length() == 0:
            ref tsvc = services[_svc_declared(services, target)]
            if not tsvc.spec:
                raise Error(
                    String("compose_api: cron '")
                    + c.name
                    + String("' targets service '")
                    + target
                    + String(
                        "', which carries no `spec {}` — so there is no runtime"
                        " identity to default the cron's invoker to. Author"
                        " `invoker_identity` on the cron."
                    )
                )
            invoker = _runtime_identity_of(tsvc.spec.value(), target)
        var grant_id = c.name + String("-cron-invoke-grant")
        var grant_deps = List[String]()
        grant_deps.append(backend_id.copy())
        nodes.append(
            _grant_node(
                grant_id.copy(),
                invoker.copy(),
                backend_id.copy(),
                grant_deps^,
            )
        )
        var deps = List[String]()
        deps.append(backend_id.copy())
        deps.append(grant_id^)
        nodes.append(
            _scheduled_call_node(
                c.name + String("-cron"),
                backend_id^,
                c.cron.copy(),
                c.timezone.copy(),
                c.path.copy(),
                c.http_method.copy(),
                invoker^,
                Int(c.attempt_deadline_seconds),
                deps^,
            )
        )


def _svc_declared(services: List[ServiceSpec], name: String) -> Int:
    """Index of the service named `name` in the COMPOSED service list, or -1.
    Used by `_append_cron_nodes` to fail-close on a cron target no node exists
    for (a dangling `depends_on` is silently never scheduled, not an error)."""
    for i in range(len(services)):
        if services[i].name == name:
            return i
    return -1


def _service_account_node(
    var logical_id: String,
    var account_id: String,
    var display_name: String,
    retention: Int = Retention.RETENTION_DELETE,
) raises -> ResourceNode:
    """The runtime ServiceAccount node (config oneof arm 11) — CREATES the SA the
    compute RUNS AS (`account_id` == the service's `runtime_identity`). A graph ROOT
    (no `depends_on`): the identity must exist before its grants + the served node.
    Mirrors the bootstrap composition's SA node, DEFAULT RETENTION_DELETE
    (app-owned — the DEPLOY graph's lifecycle IS this SA's, unlike bootstrap's
    standing RETAIN_KEEP SAs). The below-the-line mapper dispatches
    RESOURCE_KIND_SERVICE_ACCOUNT -> make_service_account_node -> the cloud's SA
    conformer (self-derives the SA email from `(account_id, project)`).

    `retention` EXISTS BECAUSE NOT EVERY SA THIS FUNCTION BUILDS IS APP-OWNED.
    `<svc>-role` is: exactly one graph creates it and its lifecycle IS that deploy's.
    The API-Gateway backend-auth SA is NOT — see `SHARED_RESOURCE_RETENTION` at the
    head of this file. Defaulted, so every `<svc>-role` call site is unchanged."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT),
        List[String](),  # graph ROOT — the identity precedes its grants + the service
        Retention(retention),
        11,
        None, None, None, None, None, None, None, None, None, None,  # arms 1-10
        Optional[ServiceAccountSpec](
            # `externally_owned=False`, AND IT IS NOT A DEFAULT BEING TAKEN —
            # the generated ctor has none, so this file states it. A DEPLOY
            # graph's `<svc>-role` is an identity THIS graph mints: on AWS the
            # arm creates it under the tool's role path with the deploy role's
            # own credential, which is the ordinary case the ownership axis
            # exists to distinguish from the day-0 role. The one node that is
            # NOT ours is composed by the bootstrap composition, on `CLOUD_AWS`
            # only.
            ServiceAccountSpec(
                account_id^,
                display_name^,
                False,
                False,
                List[FederatedAssumePrincipal](),
                List[InAccountAssumePrincipal](),
            )
        ),  # arm 11 (service_account)
        None, None, None, None, None, None, None, None,  # arms 12-19
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _base_grant_node(
    var logical_id: String,
    var principal_identity_ref: String,
    capability: Int,
    var target_resource: String,
    var depends_on: List[String],
    retention: Int = Retention.RETENTION_DELETE,
) raises -> ResourceNode:
    """A base capability Grant node (config oneof arm 17) — a scoped IAM set-policy of
    `capability`'s cloud role on `target_resource`, member = the principal's runtime SA.
    Unlike `_grant_node` (which hardcodes CAPABILITY_INVOKE_SERVICE on a `<T>-svc`
    target), this takes a GENERIC capability ordinal + an arbitrary target NAME (the
    bucket / artifact-repo SHORT NAME for a resource-scoped grant, or `""` for a
    project-scoped grant). DEFAULT RETENTION_DELETE (app-owned). Vendor-neutral:
    the node carries ONLY the generic `Capability`; the concrete cloud role
    terminates in the grant conformer. Mirrors the bootstrap composition's grant
    node.

    `retention` EXISTS FOR THE BINDINGS WHOSE BOTH ENDS ARE FOREIGN. See
    `SHARED_RESOURCE_RETENTION` at the head of this file. Defaulted, so every
    `<svc>-role`-principal grant is unchanged."""
    # field 4 `scope`, computed BEFORE the ctor so it does
    # not depend on argument-evaluation order against the `^` moves below.
    # THIS IS THE ARM THAT EMITS `String("")` — ordinals 3 / 9 / 10 / 11 plus
    # every authored `runtime_extra_capabilities` — so it is where the four
    # meanings of `""` came from, and the one the typed scope exists for.
    var scope = checked_grant_scope(
        grant_scope_for(capability, target_resource),
        String("base grant '") + logical_id + String("'"),
    )
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_GRANT),
        depends_on^,
        Retention(retention),
        17,
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 1-16
        Optional[GrantSpec](
            GrantSpec(
                principal_identity_ref^,
                Capability(capability),
                target_resource^,
                Optional[GrantScope](scope^),
            )
        ),  # arm 17 (grant)
        None,  # arm 18 (web_frontend)
        None,  # arm 19 (api_edge)
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _runtime_identity_of(spec: AppSpec, service_name: String) -> String:
    """The runtime SA a service RUNS AS: the AUTHORED `AppSpec.runtime_identity` when
    non-empty, else the DERIVED `<service_name>-role`.
    The SINGLE source of truth for the identity string carried on the ServerlessCompute
    node's `runtime_identity`, the ServiceAccount node's `account_id`, and every grant's
    `principal_identity_ref` — so the SA created, the identity the compute runs AS, and
    the principal each grant authorizes are the EXACT same string."""
    if spec.runtime_identity.byte_length() > 0:
        return spec.runtime_identity.copy()
    return service_name + String("-role")


def _translate_source_kind(bk: BundleSourceKind) -> SourceKind:
    """Translate the intent-tier `GitPush.source_kind` (`app_bundle.proto`) to the
    standalone-tier `ResolvedGitPush.source_kind` (`full_manifest.proto`),
    ORDINAL->ORDINAL. The two enums are declared INDEPENDENTLY in the two proto
    files (neither may import the other — a layering inversion) but with IDENTICAL
    ordinals by construction, so a value-preserving `.value` re-wrap is the correct
    translate. The `BundleSourceKind` param type keeps the two tiers unambiguous."""
    return SourceKind(bk.value)


def _translate_registry_kind(bk: BundleRegistryKind) -> RegistryKind:
    """Translate the intent-tier `PackagePublished.registry_kind` to the
    standalone-tier `ResolvedPackagePublished.registry_kind`, ordinal->ordinal
    (identical ordinals by construction — see `_translate_source_kind`)."""
    return RegistryKind(bk.value)


# ── The `TriggerSource.on` / `TriggerSpec.on` ARM INDICES ────────────────────
# The generated `_oneof0_case` is the 1-BASED ARM INDEX in DECLARATION order, NOT
# the proto field number (intent tier: 6/7/8; resolved tier: 8/9/10). The two
# tiers declare their arms in the SAME order on purpose, so ONE set of constants
# names both — which is what makes `_append_trigger_nodes`' arm dispatch a
# translate rather than a remap. A wrong index here is a SILENT wrong-arm read.
comptime TRIGGER_ARM_UNSET: Int = 0
comptime TRIGGER_ARM_GIT_PUSH: Int = 1
comptime TRIGGER_ARM_SCHEDULE: Int = 2
comptime TRIGGER_ARM_PACKAGE_PUBLISHED: Int = 3


def _trigger_node(
    var logical_id: String,
    var name: String,
    arm: Int,
    var git_push: Optional[ResolvedGitPush],
    var schedule: Optional[ResolvedSchedule],
    var package_published: Optional[ResolvedPackagePublished],
    var pipeline_ref: String,
    var webhook_secret_ref: String,
) raises -> ResourceNode:
    """The Trigger node (config oneof arm 15) — a standing continuous-deployment
    trigger. MIRRORS `_invoke_grant_node`
    (arm 16): a SEPARATE ordered node the below-the-line trigger pass materializes,
    RETENTION_DELETE (app-owned). The PRESENCE of >=1 Trigger node IS the identifier
    of continuous (vs one-shot) deployment.

    TWO NESTED ONEOFS, TWO ARM NUMBERINGS — do not conflate them:
      * the ResourceNode `config` oneof — TRIGGER is arm 15 (field 19);
      * the TriggerSpec `on` oneof — git_push 1 / schedule 2 / package_published 3.
    `arm` here is the SECOND one. A wrong value in either is a SILENT misparse,
    not a compile error, which is why both are asserted by the round-trip guard.

    ARM DISCIPLINE (the outer oneof). The oneof puts TRIGGER at arm 15
    (`_oneof0_case == 15`, field 19), INVOKE_GRANT at arm 16 (deprecated/unemitted),
    and GRANT at arm 17. So the cascade is `None×14`, then `Optional[TriggerSpec](...)`
    (arm 15), then TWO `None`s (arm 16 invoke_grant + arm 17 grant left unset). The
    round-trip test pins `_oneof0_case == 15` + every TriggerSpec field surviving,
    co-resident with a serverless node that still lands on arm 1 (no arm
    displacement). A standing trigger has NO `depends_on` edge (it is a graph root
    binding, not part of the per-service create chain)."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_TRIGGER),
        List[String](),  # standing root binding — no depends_on edge
        Retention(Retention.RETENTION_DELETE),
        15,
        None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 1-14
        Optional[TriggerSpec](
            TriggerSpec(
                pipeline_ref^,
                webhook_secret_ref^,
                name^,
                arm,
                git_push^,
                schedule^,
                package_published^,
            )
        ),  # arm 15 (trigger)
        None,  # arm 16 (invoke_grant left unset)
        None,  # arm 17 (grant left unset)
        None,  # arm 18 (web_frontend left unset)
        None,  # arm 19 (api_edge left unset)
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


# =============================================================================
# §2 — image-ref resolution (symbolic carry-through vs verbatim passthrough).
# =============================================================================


def _resolve_image_digest(image: ImageRef) raises -> String:
    """Resolve an `ImageRef` to the ServerlessCompute node's `image_digest`.

    `digest` arm (oneof case 1) -> the pinned sha256 passes through VERBATIM.
    `from_build` arm (oneof case 2) -> the symbolic `from_build:<target>` marker
    (synth runs before BUILD completes; the pipeline pins the real digest later).
    No arm set -> raise (an image ref MUST name exactly one source).
    """
    if image._oneof0_case == 1:
        return image.digest.value().copy()
    elif image._oneof0_case == 2:
        return FROM_BUILD_DIGEST_MARKER_PREFIX + image.from_build.value()
    raise Error(
        "compose_api: ImageRef has no `source` arm set — an image must name"
        " exactly one of `digest` or `from_build`"
    )


# =============================================================================
# §3 — the API Composition.
#
# CARDINALITY. One AppBundle expresses N NAMED services that compose into ONE
# FullManifest. `compose_api` AUTO-LIFTS (`_auto_lifted_services`) then emits ONE
# per-service node set (`_append_api_service_nodes`) per service, in
# service-declaration order. For a single-service bundle (empty `services`) the
# auto-lift synthesizes exactly one service from the singular `name`/`kind`/
# `spec`, so the emitted graph is the same as the singular form's.
# =============================================================================


def _auto_lifted_services(
    bundle: AppBundle, refuse_unresolved: Bool = True
) raises -> List[ServiceSpec]:
    """The AUTO-LIFT: the authoritative ordered list of services to compose. If
    `bundle.services` is EMPTY, synthesize a ONE-element list from the singular
    `name`/`kind`/`spec`. If NON-EMPTY, `bundle.services` is authoritative — the
    singular `name`/`spec` are ignored (the singular `kind` gated `compose()`
    dispatch upstream).

    AND IT REFUSES A SERVICE WHOSE NAME IS NOT YET RESOLVED.
    `AppSpec.name_scope == NAME_SCOPE_REGIONAL` says the authored `name` is a BASE
    name that the DEPLOY TARGET qualifies — so the string in `name` is not a
    service name at all, and composing it would emit node ids, a registry key and
    a peer token for a service that will never exist. The qualification is
    performed by `service_naming.resolve_service_names_for_target` BEFORE
    compose; a bundle that reaches here still carrying a REGIONAL scope has
    skipped it, and that is an ERROR, never a fall-through to the base name.

    WHY A FALL-THROUGH WOULD BE THE WORST ARM. The base name may well be the
    name of a live, unrelated service — an orphan of an earlier rename, say —
    and the service registry row is keyed on the project alone (no region
    axis), so composing the bare name would claim that live service's key from
    a deploy in another region, with no signal anywhere. Refusing is the only
    arm that cannot do that.

    `refuse_unresolved=False` is for the ONE reader that asks a question about
    the services' REGIONS and never about their names — `bundle_deploy_region`,
    which is what the deploy calls to *derive* the region the resolver then needs.
    Refusing there would be a cycle: the region cannot be known before the name,
    and the name cannot be composed before the region."""
    var out = List[ServiceSpec]()
    if len(bundle.services) == 0:
        var sp = Optional[AppSpec]()
        if bundle.spec:
            sp = Optional[AppSpec](bundle.spec.value().copy())
        out.append(ServiceSpec(bundle.name.copy(), AppKind(bundle.kind.value), sp^))
    else:
        for i in range(len(bundle.services)):
            out.append(bundle.services[i].copy())
    if refuse_unresolved:
        for i in range(len(out)):
            if service_name_scope(out[i]) == NameScope.NAME_SCOPE_REGIONAL:
                raise Error(
                    String(
                        "compose: service '"
                    )
                    + out[i].name
                    + String("' of bundle '")
                    + bundle.name
                    + String(
                        "' declares `name_scope: NAME_SCOPE_REGIONAL`, so '"
                    )
                    + out[i].name
                    + String(
                        "' is a BASE name and NOT this service's name. The"
                        " service name is a FUNCTION of the deploy target"
                        " (`regional_service_name(base, target.cloud,"
                        " target.region)` -> e.g. svc-a-gcp-region-1), and it"
                        " must be resolved by `service_naming"
                        ".resolve_service_names_for_target(bundle, cloud,"
                        " region)` BEFORE compose. Composing the base name would"
                        " emit node ids, a registry key and a peer token for a"
                        " service that will never exist — and could claim the"
                        " project-keyed registry row of an unrelated live"
                        " service that happens to carry the base name."
                    )
                )
    return out^


def service_name_scope(svc: ServiceSpec) -> Int:
    """THE ONE READER of `AppSpec.name_scope` in this package — the NameScope
    ordinal a service declares, or `NAME_SCOPE_UNSPECIFIED` when it has no spec
    at all.

    A second `svc.spec.value().name_scope.value` spelled inline anywhere is one
    refactor away from disagreeing about the no-spec case, and the disagreement
    is silent in the dangerous direction: a service with no spec would read as
    "resolved" in one place and be skipped by the resolver in another."""
    if not svc.spec:
        return NameScope.NAME_SCOPE_UNSPECIFIED
    return svc.spec.value().name_scope.value


def auto_lifted_services(bundle: AppBundle) raises -> List[ServiceSpec]:
    """PUBLIC re-export of the AUTO-LIFT rule — the authoritative ordered list of
    services a bundle composes.

    WHY IT IS PUBLIC (the `kci outputs` verb). The set of SERVED
    services a bundle composes is exactly this list: `_append_api_service_nodes`
    derives each service's served node id as `<svc.name>-svc`, and the deploy's
    post-converge registration writes `service/<svc.name>` -> the observed URL for
    each of them. A reader that wants to answer "where did my services land?"
    MUST enumerate the same set — so it calls THIS function rather than
    re-deriving the auto-lift rule (a second copy would drift the day a bundle
    shape changes, and the reader would then confidently report a service that
    was never composed, or miss one that was).

    Pure — a value transform over the authored bundle, no compose round-trip."""
    return _auto_lifted_services(bundle)


def auto_lifted_services_unresolved(bundle: AppBundle) raises -> List[ServiceSpec]:
    """The AUTO-LIFT with the NAME-SCOPE REFUSAL SUPPRESSED — the auto-lift rule
    asked of a bundle whose names have NOT yet been resolved against a deploy
    target.

    IT HAS EXACTLY ONE INTENDED CALLER AND THAT CALLER EXISTS TO MAKE THE
    REFUSAL UNREACHABLE: `service_naming
    .resolve_service_names_for_target`, which reads this list, composes each
    opted-in service's real name from `(cloud, region)` and hands `compose` a
    bundle the refusal has nothing to say about. Anything else that calls this is
    reading a BASE name as if it were a service name, which is the defect
    `_auto_lifted_services`' refusal was added to catch — so if you are about to
    call it, the question to answer first is which deploy target you are asking
    about.

    It exists as a parameter-free public function rather than as
    `_auto_lifted_services(bundle, refuse_unresolved=False)` at the call site so
    that the suppression is one greppable name with one docstring, instead of a
    boolean whose meaning lives somewhere else."""
    return _auto_lifted_services(bundle, refuse_unresolved=False)


def service_serves_nothing(svc: ServiceSpec) -> Bool:
    """THE ONE PREDICATE for "this service's ARTIFACT is a resource, not a served
    container".

    A bundle may mix kinds, so this is a per-service question, and it is asked
    from four places that must never disagree:

      * `_append_shared_infra_service_nodes` vs `_append_api_service_nodes` — the
        compose dispatch (which node set to build);
      * `_append_cron_nodes` — a cron aimed at a service that composes no
        `<name>-svc` node emits a dangling `depends_on`, and Kahn's algorithm does
        not fail on a dangling edge, it silently never schedules the node;
      * `_append_shared_infra_validator_read_grant` — the validate gate's
        datastore-read authority follows the service that owns the resource;
      * `resource_owner_service_names` -> the mapper's per-node orphan guard.

    A second copy of `kind == APP_KIND_SHARED_INFRASTRUCTURE` in any of them is one
    refactor away from disagreeing with the others, and the disagreements are all
    silent (a node nobody schedules, a grant nobody composes)."""
    return svc.kind.value == AppKind.APP_KIND_SHARED_INFRASTRUCTURE


def resource_owner_service_names(bundle: AppBundle) raises -> List[String]:
    """THE SERVICES THAT OWN A RESOURCE AND SERVE NOTHING, by name — the input
    to the mapper's PER-NODE orphan guard (`map_manifest_to_graph`'s
    `resource_owner_services`).

    DERIVED FROM THE AUTHORED KIND, THROUGH THE AUTO-LIFT — never hand-listed
    and never re-derived. `_auto_lifted_services` is what decides which services a
    bundle COMPOSES; deriving this from `bundle.services` directly would answer
    correctly for a `services {}` document and silently EMPTY for a singular-spec
    `APP_KIND_SHARED_INFRASTRUCTURE` bundle, whose one composed service is
    synthesized rather than authored.

    A bundle with no resource-owner service returns EMPTY, and an empty list
    leaves the mapper's guard verdict unchanged on every node."""
    var services = _auto_lifted_services(bundle)
    var out = List[String]()
    for i in range(len(services)):
        if service_serves_nothing(services[i]):
            out.append(String(services[i].name))
    return out^


def _append_shared_infra_service_nodes(
    svc: ServiceSpec, mut nodes: List[ResourceNode], composer: String
) raises:
    """Compose ONE named SHARED-INFRASTRUCTURE service's node set — exactly ONE
    standalone DATASTORE node, `<svc.name>-datastore`, and nothing else.

    THE ONE IMPLEMENTATION, called from BOTH sides. `compose_shared_infrastructure`
    (a whole bundle whose kind is SHARED_INFRASTRUCTURE) and `compose_api`'s
    per-service dispatch (one shared-infra SERVICE among N) produce the SAME node,
    because they call this. A second copy for the multi-service path is how the two
    would come to disagree about ownership or impl the first time either moved.

    WHY IT IS THIS SMALL — the reasoning is `compose_shared_infrastructure`'s and
    is unchanged: every other node in the API composition exists to serve or to
    support a served container. A service that serves nothing needs no runtime SA,
    no secret bundle, no config object, and composing them anyway would provision
    resources nothing reads — resources that can fail a deploy and cannot fail a
    test.

    OWNERSHIP: `referenced=False`, always. A shared-infrastructure service that
    REFERENCED its resource would own nothing, which leaves the consumers exactly
    where they started — N claimants and no owner. That is why
    `datastore_database_ref` is REFUSED here rather than honoured.

    `composer` names the caller in every diagnostic, so a refusal says which
    dispatch produced it (the single-service Composition or the per-service loop)."""
    if not svc.spec:
        raise Error(
            composer
            + ": shared-infrastructure service '"
            + svc.name
            + "' has no `spec` (it must declare the resources it owns)"
        )
    ref spec = svc.spec.value()
    # A SHARED-INFRASTRUCTURE SERVICE MAY NOT AUTHOR `cloud_variants` — REFUSED,
    # not ignored. This function takes NO `cloud` (it composes one standalone
    # datastore node and nothing else), so a variant authored here would be
    # AUTHORED AND READ BY NOBODY: the field would sit in the file looking like a
    # working per-cloud override while every deploy on every cloud composed the
    # spec-level value. When a resource owner genuinely needs per-cloud shapes,
    # thread `cloud` into this function and delete this refusal in the same
    # change — the refusal is what makes that a deliberate act.
    if len(spec.cloud_variants) > 0:
        raise Error(
            composer
            + ": shared-infrastructure service '"
            + svc.name
            + "' authors `cloud_variants`, and this composition resolves none —"
            + " it takes no cloud posture. Leaving it would be a per-cloud"
            + " override that every cloud ignores. Move the per-cloud"
            + " declaration onto a served service, or thread the cloud into"
            + " `_append_shared_infra_service_nodes` and delete this refusal."
        )
    var ds = spec.datastore.value
    var owns_a_datastore = not (
        ds == DatastoreNeed.DATASTORE_NEED_UNSPECIFIED
        or ds == DatastoreNeed.DATASTORE_NEED_NONE
    )
    # THE REFUSAL IS "OWNS NOTHING", NOT "HAS NO DATASTORE". A `mail_transport`
    # block owns a domain identity, a queue and N records, and a service holding
    # one composes a graph that is anything but empty. Keying the PREDICATE on
    # ownership of ANY resource is what keeps the refusal true.
    if not owns_a_datastore and not spec.mail_transport:
        raise Error(
            composer
            + ": shared-infrastructure service '"
            + svc.name
            + "' declares `datastore: NONE/unset` and authors no `mail_transport`,"
            + " so it owns NOTHING and composes to an EMPTY graph. A"
            + " shared-infrastructure release machine that owns no resource is a"
            + " deploy that does nothing while reading as infrastructure — declare"
            + " `datastore: DATASTORE_NEED_SERVERLESS`, author a `mail_transport`"
            + " spine, or delete it."
        )
    if spec.datastore_database_ref.byte_length() > 0:
        raise Error(
            composer
            + ": shared-infrastructure service '"
            + svc.name
            + "' authors `datastore_database_ref`, i.e. it REFERENCES a database"
            + " another release machine owns. A shared-infrastructure machine exists"
            + " to BE that other machine; if it references, nobody owns, and the"
            + " consumers are back to N claimants and no owner. Author"
            + " `datastore_database` instead."
        )
    # THE MAIL-TRANSPORT SPINE, FIRST and by the SAME function the API path
    # calls. ABSENT ⇒ nothing appended.
    _append_mail_transport_nodes(spec, nodes)
    if not owns_a_datastore:
        return
    var datastore_impl = (
        DATASTORE_IMPL_DEDICATED
        if ds == DatastoreNeed.DATASTORE_NEED_DEDICATED
        else DATASTORE_IMPL_SERVERLESS
    )
    # ONE NODE PER AUTHORED COLLECTION. ZERO collections composes exactly ONE
    # node under the `<svc>-datastore` id. Each node is a graph ROOT: a
    # resource-owner service has no in-graph predecessor.
    var ds_ids = _datastore_node_ids_for(svc.name, spec)
    var ds_colls = _datastore_collections_of(spec)
    for di in range(len(ds_ids)):
        var one = List[DatastoreCollectionSpec]()
        if di < len(ds_colls):
            one.append(ds_colls[di].copy())
        nodes.append(
            _datastore_node(
                ds_ids[di].copy(),
                List[String](),
                datastore_impl,
                False,
                False,  # referenced: an OWNER never references
                # THIS NODE'S OWN COLLECTION (field 35), and only it. One node
                # is one resource; a node carrying N is the single-table design
                # the AWS arm refuses by name.
                one^,
            )
        )


def resolve_cloud_variant(
    spec: AppSpec, cloud: Int, who: String
) raises -> AppSpec:
    """SELECT THE PER-CLOUD SPEC VARIANT (`AppSpec.cloud_variants`, field 36)
    and overlay it onto `spec`. THE ONE READER OF THAT FIELD.

    A service that runs on several clouds needs per-cloud answers for a few
    members (the image, the ingress, the datastore shapes). The key is the cloud
    POSTURE, not the env name.

    `cloud` is the mirrored `kci.deploy.v1.Cloud` ordinal this composition was
    called with — the SAME parameter that already gates the per-cloud grant nodes
    below, read off `EnvBinding.cloud` by the deploy driver. Keying on it rather
    than on the env NAME is the point: several AWS envs (a personal one, a
    production one, a customer's own account) are several env symbols and ONE
    answer to "which image", and an env-keyed override would make the author
    restate that once per environment — with the first environment nobody
    remembered taking the GCP image on AWS, which converges and then fails at
    the first invoke.

    THE SAFETY PROPERTY: an EMPTY `cloud_variants` returns `spec` UNCHANGED, so
    the composed manifest and its content address are unchanged. A selected
    variant overlays ONLY the members it AUTHORS. A bundle whose variants name
    OTHER clouds than this deploy's likewise composes unchanged — that is not a
    refusal, it is the ordinary case for a GCP deploy of a bundle that carries
    an AWS variant.

    THREE REFUSALS, ALL BY NAME, none of them a silent drop:

      1. `CLOUD_UNSPECIFIED` (0) — a variant that names no posture can be
         selected by NO deploy, so it is authored-and-ignored. It is not a
         wildcard and not a default arm; a per-cloud override with a
         fall-through arm would be a second spelling of the spec-level value,
         which is the thing the spec level already is.
      2. TWO variants naming ONE posture — two answers to one question. Taking
         the first would make the authored ORDER load-bearing for something the
         author never said was ordered, and taking the last would silently
         discard a block somebody wrote.
      3. A matched variant that authors NO member — it changes nothing, so it
         either means something this schema cannot express or it is a typo in a
         member name. Both are worth stopping for; neither is worth composing.

    `who` names the composition for the diagnostic (a bundle with five services
    needs to be told WHICH one refused)."""
    if len(spec.cloud_variants) == 0:
        return spec.copy()

    # -- validate the WHOLE authored set before selecting from it. A refusal that
    #    only fires for the cloud you happen to be deploying to is a refusal that
    #    reports a GCP author's mistake to an AWS operator, weeks later.
    var seen = List[Int]()
    for i in range(len(spec.cloud_variants)):
        var ordinal = Int(spec.cloud_variants[i].cloud)
        if ordinal == CLOUD_UNSPECIFIED:
            raise Error(
                who
                + String(": `cloud_variants` entry ")
                + String(i)
                + String(
                    " names CLOUD_UNSPECIFIED. A variant that names no cloud"
                    " posture can be selected by no deploy, so it is authored"
                    " and ignored — it is NOT a wildcard and NOT a default arm"
                    " (the spec level already is the default). Name one of"
                    " CLOUD_GCP / CLOUD_AWS / CLOUD_AZURE / CLOUD_KUBERNETES /"
                    " CLOUD_LOCAL, or delete the block."
                )
            )
        for j in range(len(seen)):
            if seen[j] == ordinal:
                raise Error(
                    who
                    + String(
                        ": two `cloud_variants` entries name the same cloud"
                        " posture (ordinal "
                    )
                    + String(ordinal)
                    + String(
                        "). That is two answers to one question: taking the"
                        " first would make the authored order load-bearing for"
                        " something you never said was ordered, and taking the"
                        " last would silently discard a block you wrote. Merge"
                        " them into one entry."
                    )
                )
        seen.append(ordinal)

    var out = spec.copy()
    for i in range(len(spec.cloud_variants)):
        ref v = spec.cloud_variants[i]
        if Int(v.cloud) != cloud:
            continue
        if (
            not v.image
            and not v.ingress
            and len(v.datastore_collections) == 0
        ):
            raise Error(
                who
                + String(
                    ": the `cloud_variants` entry for cloud ordinal "
                )
                + String(cloud)
                + String(
                    " authors no member — no `image`, no `ingress`, no"
                    " `datastore_collections` — so selecting it changes"
                    " nothing. Either it means something this schema cannot"
                    " express, or a member name is misspelled; both are worth"
                    " stopping for."
                )
            )
        # -- OVERLAY, member by member. An ABSENT member leaves the spec-level
        #    value exactly where it was, which is what lets a variant naming only
        #    an image change only the image.
        if v.image:
            out.image = Optional[ImageRef](v.image.value().copy())
        if v.ingress:
            out.ingress = Optional[IngressSpec](v.ingress.value().copy())
        if len(v.datastore_collections) > 0:
            # REPLACES, never appends. A merge would make the spec-level list
            # mean a different thing depending on which cloud read it, and there
            # is no correct order for a merged list.
            var cols = List[BundleDatastoreCollection]()
            for k in range(len(v.datastore_collections)):
                cols.append(v.datastore_collections[k].copy())
            out.datastore_collections = cols^
        break
    return out^


def _append_api_service_nodes(
    svc: ServiceSpec,
    env_override: Dict[String, String],
    mut nodes: List[ResourceNode],
    # REQUIRED, NOT DEFAULTED, AND IT IS THE ONE PARAMETER HERE THAT IS. Every
    # other argument below has a default because omitting it composes LESS;
    # omitting `cloud` would compose the WRONG THING — GCP-only grant nodes into
    # an AWS graph. There is ONE call site and it has a cloud to state.
    cloud: Int,
    env: String = String(""),
    param_override: Dict[String, String] = Dict[String, String](),
    supplied_params: Dict[String, String] = Dict[String, String](),
    # N, NOT ONE. The in-bundle OWNER's datastore nodes — N of
    # them when the owner authors N collections — so a REFERENCING service's own
    # datastore nodes are ordered after EVERY one of them. A single id would have
    # ordered the referencer after the owner's FIRST store only, and the other
    # N-1 would run whenever: Kahn's algorithm does not fail on an absent edge.
    var owner_datastore_ids: List[String] = List[String](),
) raises:
    """Compose ONE named service's API node set — {IamRole -> Secret -> Config
    [-> Datastore] -> ServerlessCompute} — appending each flat `ResourceNode` into
    `nodes` in topo order. `env_override` is the selected wave's per-ENV literal-value
    override map for THIS service (`_wave_env_overrides_by_service`[i]) — folded
    onto the Config node's env AFTER the spec-level `env {}` literals, so a
    per-env value WINS over the env-neutral spec default. An EMPTY map leaves the
    Config env as authored. Every derived id is keyed on `svc.name`
    (`<name>-role`/`-secret`/`-config`/`-datastore`/`-svc`) so N services' node
    sets are disjoint (a multi-service manifest's graphs never collide). Raises
    on a non-API service kind, a missing spec, or a missing image ref
    (fail-fast)."""
    if svc.kind.value != AppKind.APP_KIND_API:
        raise Error(
            "compose_api: service '"
            + svc.name
            + "' is not APP_KIND_API (ordinal "
            + String(svc.kind.value)
            + ") — only API services compose here (fail-fast)"
        )
    if not svc.spec:
        raise Error(
            "compose_api: service '"
            + svc.name
            + "' has no `spec` (need image/port/scaling intent)"
        )
    # THE PER-CLOUD SPEC VARIANT OVERLAY (`AppSpec.cloud_variants`, field 36) —
    # applied HERE, on the local copy, BEFORE anything reads a member of it.
    # Every subsequent line in this function therefore sees ONE spec, and there
    # is no second place that has to remember to ask which cloud this is. EMPTY
    # variants returns the spec unchanged.
    var spec = resolve_cloud_variant(
        svc.spec.value(),
        cloud,
        String("compose_api: service '") + svc.name + String("'"),
    )
    if not spec.image:
        raise Error(
            "compose_api: service '" + svc.name + "' spec has no `image` ref"
        )
    var image = spec.image.value().copy()

    # -- deterministic logical ids, all derived from svc.name -----------------
    var role_id = svc.name + String("-role")
    var secret_id = svc.name + String("-secret")
    var config_id = svc.name + String("-config")
    var svc_id = svc.name + String("-svc")

    # -- image digest: symbolic carry-through for from_build, verbatim digest --
    var image_digest = _resolve_image_digest(image)

    # -- scaling intent (default min=0 scale-to-zero, max=1 single-instance) ---
    var min_scale = Int32(0)
    var max_scale = Int32(1)
    if spec.scaling:
        min_scale = spec.scaling.value().min
        max_scale = spec.scaling.value().max

    # -- Config node values: the LITERAL env vars, in service-declaration order
    #    (deterministic). A `service_ref` cross-service ref (arm case 3) emits the
    #    URL-RESOLUTION MARKER `<VAR>__SVCREF -> T` (the sibling's LOGICAL name,
    #    not its URL — T's URL is the observed deploy URL, resolved at RUNTIME by
    #    the service-side ServiceResolver; see the SVCREF_MARKER_SUFFIX contract
    #    above).
    #
    # ARM CASE 2 (`value_from`) IS NOT A SILENT DROP. A dropped entry would give
    #    an author who wrote `env { name: "X" value_from: VALUE_FROM_DEPLOY_URL }`
    #    a container with no `X` and a green deploy — the fail-OPEN direction on a
    #    field whose whole purpose is to name an endpoint.
    #
    #    `resolve_endpoint_arg_marker` REFUSES this token on ARGV as circular,
    #    and that refusal is CORRECT: a command line is fixed by `CreateFunction`,
    #    so no ordering of "create the service" and "know its url" exists. A
    #    Lambda ENVIRONMENT is different — config arrives through
    #    `UpdateFunctionConfiguration` AFTER create, and a function url is
    #    assigned by a SEPARATE call on an already-existing function. So compose
    #    emits the marker and the AWS FUNCTION conformer resolves it at apply,
    #    against the door it just ensured.
    #
    #    COMPOSE DOES NOT JUDGE WHETHER THE CLOUD CAN RESOLVE IT, deliberately —
    #    the same split this file applies to the argv form: compose carries the
    #    author's intent faithfully in a typed form; judging whether that intent
    #    is satisfiable belongs to the tier that knows the deployed world. On
    #    Cloud Run the url really is assigned by the create, so the GCP arm is
    #    where that refusal belongs.
    var config_values = Dict[String, String]()
    for i in range(len(spec.env)):
        if spec.env[i]._oneof0_case == 1:  # literal `value` arm
            config_values[spec.env[i].name.copy()] = spec.env[i].value.value().copy()
        elif spec.env[i]._oneof0_case == 2:  # `value_from` SELF wave-output arm
            config_values[spec.env[i].name.copy()] = _self_output_marker_for(
                svc.name, spec.env[i].name, spec.env[i].value_from.value()
            )
        elif spec.env[i]._oneof0_case == 3:  # `service_ref` cross-service arm
            config_values[
                spec.env[i].name.copy() + SVCREF_MARKER_SUFFIX
            ] = spec.env[i].service_ref.value().service.copy()

    # -- PER-ENV OVERRIDE overlay: the selected wave's `env_override` literals WIN
    #    over the env-neutral spec-level `env {}` default. Applied AFTER the
    #    spec.env loop so an override REPLACES the same-named default. An EMPTY map
    #    is a no-op. Overrides are literal-value only (the
    #    `_wave_env_overrides_by_service` contract), so this never touches the
    #    SVCREF markers.
    for entry in env_override.items():
        config_values[entry.key.copy()] = entry.value.copy()

    # -- datastore intent: whether the app declares an OLTP datastore need.
    #    Cross-resource authorizations are SEPARATE ordered `Grant` nodes, not
    #    tokens on the IamRole node. --------------------------------------------
    var ds = spec.datastore.value
    var has_datastore = (
        ds != DatastoreNeed.DATASTORE_NEED_UNSPECIFIED
        and ds != DatastoreNeed.DATASTORE_NEED_NONE
    )
    # The NEUTRAL datastore-impl token (only meaningful when has_datastore).
    var datastore_impl = (
        DATASTORE_IMPL_DEDICATED
        if ds == DatastoreNeed.DATASTORE_NEED_DEDICATED
        else DATASTORE_IMPL_SERVERLESS
    )
    # THE OWNERSHIP AXIS (reference-not-own). A service that authored
    # `datastore_database_ref` OPENS a database another release machine owns, so
    # its datastore node is READ-ONLY below the line: the mapper builds a probe
    # rather than an ensure, and an absent database REFUSES the deploy.
    #
    # Compose reads the FIELD directly and judges nothing — deliberately. The
    # own-XOR-reference policy is resolved on the cloud-agnostic side of the line
    # where a refusal has already happened: `validate_bundle` runs before any
    # compose, and the deploy seam resolves the identity again before it maps.
    # Re-deciding the policy here would be a third copy of a four-case rule.
    var datastore_referenced = spec.datastore_database_ref.byte_length() > 0

    # -- Secret node: the service's secret bundle handle (deterministic from name).
    #    v1 SecretSpec is singular (handle + capability_node); the first binding's
    #    capability node is carried. (N>1 secret_bindings collapse to one Secret
    #    node — SecretSpec has no repeated field yet.) ---------------------------
    var secret_handle = svc.name + String("-secrets")
    var secret_cap = String("")
    if len(spec.secret_bindings) > 0:
        secret_cap = spec.secret_bindings[0].capability_node.copy()

    # -- runtime-identity SELF-PROVISION: when the bundle AUTHORS
    #    `runtime_identity`, the DEPLOY graph CREATES the SA the compute RUNS AS +
    #    its base capability grants. An UNSET field derives `<name>-role` and
    #    emits NEITHER. `runtime_id` is the SINGLE identity string used by the SA
    #    node (account_id), the ServerlessCompute node (runtime_identity), and
    #    every grant.
    var runtime_id = _runtime_identity_of(spec, svc.name)
    var self_provision = spec.runtime_identity.byte_length() > 0
    var sa_id = svc.name + String("-role-sa")

    # -- depends_on edges: [SA ->] secret -> config [-> datastore] -> svc -> role ---
    #    The run.invoker-on-OWN-service IamRole node binds IAM ON the service, so it
    #    depends on the service and runs LAST (a first deploy cannot setIamPolicy on a
    #    not-yet-created service). On `CLOUD_AWS` the node at the end of that
    #    chain is a kind-17 GRANT rather than the kind-8 IamRole — SAME edge, same
    #    position, different carrier; see `_runtime_invoke_is_a_grant_node_on_cloud`.
    #    Secret is the graph ROOT. When self-provisioning, the
    #    ServiceAccount node is an ADDITIONAL root and the SERVICE depends_on it (runs
    #    AS the SA just created). When the service declares a datastore need, the
    #    Datastore node sits BETWEEN config and svc so the DB is provisioned first.
    #    Ensure order: [SA + its base grants ->] secret -> config [-> datastore] -> svc -> role.
    # N DATASTORE NODE IDS, one per authored collection. ZERO collections yields
    # exactly ONE id, `<svc>-datastore`.
    var datastore_ids = _datastore_node_ids_for(svc.name, spec)
    var secret_deps = List[String]()  # ROOT (was [role]; role now runs AFTER svc)
    var config_deps = List[String]()
    config_deps.append(secret_id.copy())
    var svc_deps = List[String]()
    # THE SERVICE DEPENDS ON **EVERY** DATASTORE NODE, not on the first. The
    # edge exists so the store is provisioned before the container that reads it
    # comes up; N-1 missing edges is a container that boots before N-1 of its
    # stores exist, and the failure surfaces at the app's first request rather
    # than at this deploy — Kahn's algorithm does not fail on an absent edge, it
    # schedules the node whenever.
    if has_datastore:
        for di in range(len(datastore_ids)):
            svc_deps.append(datastore_ids[di].copy())
    else:
        svc_deps.append(config_id.copy())
    if self_provision:
        svc_deps.append(sa_id.copy())  # the service RUNS AS the SA the deploy created
    # -- app-provisioned BUCKETS (`AppSpec.buckets`). The service depends_on each
    #    bucket node (bucket-before-service — the datastore-before-service
    #    precedent) so the placement/staging bucket EXISTS before the served
    #    container comes up. The bucket NODE id == the bucket NAME (`bks.name`,
    #    verbatim — MAY carry `${project}`, which the mapper resolves for the
    #    resource name; the graph key stays un-substituted so this depends_on edge
    #    matches). ZERO buckets => nothing added.
    for bi in range(len(spec.buckets)):
        svc_deps.append(spec.buckets[bi].name.copy())
    var role_deps = List[String]()
    role_deps.append(svc_id.copy())  # run.invoker-on-own-service: service must exist

    # -- self-provision: emit the runtime SA (graph root) + its base grants FIRST,
    #    so the identity + its permissions precede the served node. The bundle's
    #    AppSpec.runtime_extra_capabilities (field 21) adds ONE project-scoped
    #    grant per declared ordinal on top.
    if self_provision:
        _append_runtime_sa_nodes(
            nodes,
            svc.name,
            runtime_id.copy(),
            sa_id.copy(),
            spec.runtime_extra_capabilities.copy(),
            # THE CLOUD, THREADED. On CLOUD_AWS some of the base grants are not
            # composed at all — see `_grant_composes_on_cloud`.
            cloud,
            # THE AUTHORED STORES THE ORDINAL-9 GRANT IS **ABOUT**. EMPTY unless
            # this service AUTHORS collections: an ordinal-9 grant naming an
            # authored store must resolve to THAT store on a cloud whose
            # datastore grant is resource-scoped.
            _authored_datastore_collection_names(spec) if has_datastore else List[
                String
            ](),
        )
        # MOUNTED-SECRET ACCESSOR grants (secretAccessor-BEFORE-service). The
        # runtime SA needs `roles/secretmanager.secretAccessor` on EACH
        # `secret://`-mounted secret the container reads at BOOT, else the revision
        # fails `Permission denied on secret: …/versions/latest for Revision service
        # account <svc>-role@…`. Emit one READ_SECRET grant per `secret_bindings`
        # handle, each depends_on the SA node, and make the SERVICE depends_on each
        # so the accessor is BOUND before the revision boots (the DAG enforces the
        # ordering). Custody of a secret is this declaration: a service that reads
        # a secret declares it here and gets its grant here, whatever the secret is.
        var mount_grant_deps = List[String]()
        mount_grant_deps.append(sa_id.copy())
        for i in range(len(spec.secret_bindings)):
            var handle = spec.secret_bindings[i].handle.copy()
            if handle.byte_length() == 0:
                continue

            # ENSURE-MODE: a binding that is NOT pre-seeded out of band. Emit a
            # per-handle RESOURCE_KIND_SECRET CREATE node keyed on the REAL handle
            # (so the below-the-line ensure-secret conformer create-if-absents the
            # container + versioned-PUTs the kci-seeded value), and make the
            # accessor grant `depends_on` it so the secret EXISTS before the
            # grant's read-modify-write GetIamPolicy runs (else that policy read
            # NOT_FOUND-crashes). An authorize-only binding (the default,
            # `ensure=false`) emits NO create node: a secret seeded out of band
            # keeps its accessor grant `depends_on` == [SA] only.
            var ensure = spec.secret_bindings[i].ensure
            var this_grant_deps = mount_grant_deps.copy()
            if ensure:
                var ensure_node_id = (
                    svc.name + ENSURE_SECRET_NODE_INFIX + handle
                )
                # rooted at the aggregate Secret node (graph root) — the ensure-secret
                # conformer runs no earlier than the app's secret bundle ensure. Its
                # SecretSpec carries the REAL handle (the Secret Manager name), NOT the
                # phantom aggregate handle — that is what the ensure loop create-writes.
                var ensure_deps = List[String]()
                ensure_deps.append(secret_id.copy())
                # CUSTODY rides onto the ensure node (and ONLY the ensure node —
                # the aggregate `<svc>-secret` node pools authorize-only handles
                # and must stay a do-not-write bundle). Without it the applier
                # would have to re-open the bundle to learn whose credential this
                # handle names, which is exactly the kind of out-of-band lookup
                # that lets the two facts drift apart.
                nodes.append(
                    _secret_node(
                        ensure_node_id.copy(),
                        ensure_deps^,
                        handle.copy(),
                        spec.secret_bindings[i].capability_node.copy(),
                        spec.secret_bindings[i].custody.number(),
                    )
                )
                this_grant_deps.append(ensure_node_id.copy())
                # the served revision also boots AFTER the container is provisioned.
                svc_deps.append(ensure_node_id^)

            var mount_grant_id = (
                svc.name + String("-role-accessor-") + handle + String("-grant")
            )
            nodes.append(
                _base_grant_node(
                    mount_grant_id.copy(),
                    runtime_id.copy(),
                    Capability.CAPABILITY_READ_SECRET,
                    handle^,
                    this_grant_deps^,
                )
            )
            svc_deps.append(mount_grant_id^)  # revision boots AFTER the accessor binds

    # -- THE MAIL-TRANSPORT SPINE, FIRST. The domain identity is a graph ROOT and
    #    everything else in that set hangs off it, so it precedes the service's own
    #    identity/config/compute chain — which is also the order an operator reads a
    #    plan in. ABSENT `mail_transport` ⇒ NOTHING appended.
    _append_mail_transport_nodes(spec, nodes)
    # -- assemble THIS service's node set (topo order; edges carried by depends_on)
    # THE RUNTIME IDENTITY'S INVOKE AUTHORIZATION ON ITS OWN SERVICE — ONE
    #    NODE, AND WHICH KIND IT IS DEPENDS ON THE CLOUD. See
    #    `_runtime_invoke_is_a_grant_node_on_cloud` for the whole argument; the
    #    short form is that GCP carries it INSIDE the kind-8 node's conformer and
    #    AWS skips that node, so on AWS the same authorization has to be a
    #    kind-17 GRANT or it is carried by nothing at all.
    #
    # THE AWS ARM IS ALSO GATED ON `self_provision`, AND THAT IS DERIVED
    #    RATHER THAN CAUTIOUS. The AWS grant conformer REFUSES every mutating verb
    #    on a role this graph does not mint — it reads that off the graph by
    #    looking for a SERVICE_ACCOUNT node whose `account_id` is the principal,
    #    and the SA node is composed under exactly this predicate
    #    (`_append_runtime_sa_nodes`, above). So without it the node would map and
    #    then never converge: a grant reported as foreign drift on every apply,
    #    forever. An AWS service that does not self-provision gets the kind-8
    #    node and its named gap, which is the honest answer rather than a grant
    #    on a role nobody creates.
    if _runtime_invoke_is_a_grant_node_on_cloud(cloud) and self_provision:
        nodes.append(
            _grant_node(
                # The sibling ids on this same target are `<deploy>-invokes
                # -<svc>` and `allUsers-invokes-<svc>`; this is the THIRD
                # principal on it, spelled the same way. `runtime_id` (not
                # `role_id`) is the principal string the SA node's `account_id`
                # and the compute node's `runtime_identity` also carry, so the
                # id, the member and the minted role are ONE string — the
                # `_runtime_identity_of` contract.
                _runtime_invoke_grant_id(runtime_id, svc.name),
                runtime_id.copy(),
                svc_id.copy(),
                # The SAME `[<svc>-svc]` edge the kind-8 node carried, and for
                # the same reason on both clouds: the policy names the function
                # ARN, so it applies AFTER the target exists.
                role_deps^,
            )
        )
    else:
        nodes.append(_iam_role_node(role_id.copy(), role_deps^))
    nodes.append(_secret_node(secret_id^, secret_deps^, secret_handle^, secret_cap^))
    nodes.append(_config_node(config_id.copy(), config_deps^, config_values^))
    if has_datastore:
        # ONE NODE PER AUTHORED COLLECTION, in authored order.
        var ds_colls = _datastore_collections_of(spec)
        for di in range(len(datastore_ids)):
            var ds_deps = List[String]()
            ds_deps.append(config_id.copy())
            # OWNER-BEFORE-REFERENCER. When a SIBLING service in this same
            # bundle OWNS the database this one borrows, this node depends_on the
            # owner's — so the engine ENSURES the database before anything probes
            # it.
            #
            # WHY THIS EDGE IS THE WHOLE PERMIT. One owner + N referencers is
            # allowed *because* there is exactly one order in which that is
            # coherent. Without the edge the order is whatever the services
            # happen to be listed in, and the failure is not a crash: the
            # referenced node's probe RAISES "the database does not exist" on a
            # FIRST deploy into a fresh environment, for a database its own
            # bundle is about to create nodes later. Ordering that holds by luck
            # is not ordering.
            #
            # **EVERY** OWNER NODE, NOT THE FIRST. An owner that authors N
            # collections composes N nodes; depending on one of them orders this
            # referencer after that one store and leaves the other N-1 free to
            # run later. EMPTY `owner_datastore_ids` adds nothing. A service
            # never depends on ITSELF: the owner's own nodes pass their own ids
            # here and the equality check drops them.
            if datastore_referenced:
                for oi in range(len(owner_datastore_ids)):
                    if owner_datastore_ids[oi] != datastore_ids[di]:
                        ds_deps.append(owner_datastore_ids[oi].copy())
            # THIS NODE'S OWN COLLECTION SHAPE (field 35), and only it. EMPTY
            # when the service authors no collection.
            #
            # THE TWO `referenced` AXES ARE DIFFERENT QUESTIONS AND BOTH ARE
            # CARRIED. `datastore_referenced` above says whether THIS SERVICE
            # owns the DATABASE or borrows a sibling's;
            # `DatastoreCollection.referenced` says whether a COLLECTION inside
            # it is owned outside this graph and must be ADOPTED rather than
            # created. A service can own its database and adopt one collection
            # in it, so neither may be derived from the other.
            var one = List[DatastoreCollectionSpec]()
            if di < len(ds_colls):
                one.append(ds_colls[di].copy())
            nodes.append(
                _datastore_node(
                    datastore_ids[di].copy(),
                    ds_deps^,
                    datastore_impl,
                    False,
                    datastore_referenced,
                    one^,
                )
            )
    # -- app-provisioned BUCKETS + their per-bucket WRITE grants (`AppSpec.buckets`).
    #    Emitted BEFORE the ServerlessCompute node (the service depends_on each —
    #    wired into `svc_deps` above), so the placement/staging bucket exists before
    #    the served container boots. Each bucket also gets ONE
    #    `CAPABILITY_WRITE_OBJECT_STORE` grant (objectAdmin) — plus, on a
    #    self-provision service, ONE `CAPABILITY_READ_OBJECT_STORE` grant for the
    #    in-cloud VALIDATE JOB's SA (see the block at the bottom of this loop) — so
    #    the service's runtime SA can put/delete blobs — principal = the SAME
    #    `runtime_id` the ServerlessCompute node runs AS, target = the bucket NAME
    #    (the grant conformer self-derives the bucket resource; the mapper resolves
    #    `${project}` in the target), depends_on the bucket node
    #    (grant-after-target-exists). The bucket node id (== bucket name) is emitted
    #    VERBATIM (may carry `${project}`); the mapper resolves the token for the
    #    RESOURCE name while the graph key stays un-substituted (so the svc + grant
    #    depends_on edges still match). ZERO buckets => nothing emitted.
    for bi in range(len(spec.buckets)):
        var bkt = spec.buckets[bi].copy()
        # A graph ROOT (empty depends_on): the placement bucket has no in-graph
        # predecessor — the identity + config precede the SERVICE, but a bucket only
        # needs to exist before the service reads it, which the svc depends_on edge
        # enforces. (Mirrors the WIF/AR/state-bucket roots.)
        nodes.append(
            _bucket_node(
                bkt.name.copy(),  # bucket node id == bucket name (may carry ${project})
                List[String](),  # graph ROOT (svc depends_on it — see svc_deps)
                bkt.location.copy(),
                bkt.storage_class.copy(),
                bkt.uniform_bucket_level_access,
                bkt.public_access_prevention.copy(),
                # The AUTHORED object expiry (0 = the bundle makes no lifetime
                # claim).
                bkt.object_expiry_days,
            )
        )
        # The per-bucket WRITE_OBJECT_STORE (objectAdmin) grant for the runtime SA.
        var bkt_grant_deps = List[String]()
        bkt_grant_deps.append(bkt.name.copy())  # grant-after-bucket-exists
        nodes.append(
            _base_grant_node(
                svc.name + String("-role-write-") + bkt.name + String("-grant"),
                runtime_id.copy(),  # principal = the SA the ServerlessCompute runs AS
                Capability.CAPABILITY_WRITE_OBJECT_STORE,
                bkt.name.copy(),  # target = the bucket NAME (mapper resolves ${project})
                bkt_grant_deps^,
            )
        )
        # ── THE VALIDATE-JOB READ GRANT ───────────────────────────────────────
        # The IN-CLOUD validate JOB runs as the deploy principal. A validator that
        # READS BACK a blob this app wrote needs `storage.objectViewer` ON THAT
        # BUCKET: the deploy principal's standing roles carry no storage role, and
        # a bucket provisioned by the loop above gets objectAdmin for the app's
        # OWN `<name>-role@` and nobody else. A gate that reads a resource needs an
        # EXPLICIT grant on it; "it is broad, it will be covered" is how such a
        # gate ships RED with a 403.
        #
        # LEAST PRIVILEGE — READ, and only on THIS bucket.
        # `CAPABILITY_READ_OBJECT_STORE` -> `roles/storage.objectViewer` on
        # `projects/_/buckets/<name>`. The validator ASSERTS AN OBJECT IS
        # PRESENT; it never writes or administers. A WRITE/ADMIN grant here would
        # be a standing mutate capability for a job that runs on EVERY deploy.
        #
        # ORDERED AFTER THE BUCKET. `depends_on == [<bucket node>]`, exactly like
        # the WRITE grant above — a grant applied before its bucket exists is a
        # half-applied graph (the GetIamPolicy read-modify-write NOT_FOUNDs).
        #
        # GATED ON `self_provision`, the SAME condition as the validator-invoke
        # grant below, and for the same reason: that is the arm whose validate
        # step runs IN-CLOUD as the deploy principal. A non-self-provision app is
        # validated by a LOCAL fork-exec under the operator's own credentials,
        # which this grant would not help.
        #
        # AND ON THE CLOUD AXIS TOO. "The validate job runs as the deploy
        # principal" is a GCP premise; on AWS the grant's carrier would be an
        # inline policy on the day-0 deploy role, which the AWS grant conformer
        # refuses permanently. See
        # `_validator_runs_as_the_deploy_principal_on_cloud`.
        if self_provision and _validator_runs_as_the_deploy_principal_on_cloud(
            cloud
        ):
            var vread_deps = List[String]()
            vread_deps.append(bkt.name.copy())  # grant-after-bucket-exists
            nodes.append(
                _base_grant_node(
                    DEPLOY_PRINCIPAL
                    + String("-reads-")
                    + bkt.name,
                    DEPLOY_PRINCIPAL,  # deploy principal (mapper -> full email)
                    Capability.CAPABILITY_READ_OBJECT_STORE,
                    bkt.name.copy(),  # target = the bucket NAME (mapper resolves ${project})
                    vread_deps^,
                )
            )
    # RESOLVE THE DECLARED PARAMETERS INTO ARGV, and REFUSE (rc=9) here — at
    # COMPOSE time, before any cloud call — if a REQUIRED one resolves to
    # nothing. Refusing here rather than at the API is what makes `kci <app>
    # plan <env>` show it, makes a partial deploy unreachable, and covers the
    # operator path an API-tier check structurally cannot see.
    var param_args = resolve_parameter_args(
        svc.name, env, spec, param_override, supplied_params
    )
    nodes.append(
        _serverless_node(
            svc_id^,
            svc_deps^,
            image_digest^,
            spec.port,
            min_scale,
            max_scale,
            runtime_id^,
            # SYNTHESIZE + ATTACH the platform SupervisorSpec (merge the
            # customer's AppSpec supervisor HINTS + the platform defaults). Every
            # served node gets a supervisor — the customer never authors it.
            Optional[SupervisorSpec](_supervisor_spec(spec)),
            # RETENTION: thread the AUTHORED AppSpec.keep_last_n through onto the
            # ServerlessComputeSpec (UNSET flows through as None; the mapper
            # applies the kci default).
            spec.keep_last_n.copy(),
            # THE RESOLVED PARAMETER ARGV. Resolved from `AppSpec.parameters`
            # against the wave's `parameter_override` and the supplied map; a
            # REQUIRED parameter that resolves to nothing has already RAISED by
            # here (the rc=9 refusal), so a composed graph never carries a
            # half-configured service.
            param_args^,
            # THE AUTHORED NETWORK REACH. The bundle's `network_ingress` ordinal,
            # threaded verbatim — compose NEVER invents a value here. UNSPECIFIED
            # (0) makes the deploy stamp nothing.
            #
            # COMPOSE DOES NOT SUBSTITUTE A "SAFE" DEFAULT, DELIBERATELY. Picking
            # one here would silently change the network surface of every bundle
            # on its next deploy — and picking the SAFE one
            # (INTERNAL_AND_LOAD_BALANCER) would black-hole whichever service
            # turns out to be dialed directly. The default lives in the bundle,
            # where it is reviewable.
            _authored_network_ingress(spec),
            # THE AUTHORED OUTBOUND PATH (field 33) — the OTHER HALF of a
            # private-ingress topology, threaded verbatim for the same reason the
            # reach above is: compose never invents one. ABSENT renders no
            # `vpc_access`, so the revision egresses over the PUBLIC INTERNET and
            # a peer with `internal-and-cloud-load-balancing` ingress refuses it AT
            # THE EDGE. Authoring the ingress half alone is what takes a front door
            # down; this is the field that closes the pair.
            _authored_network_egress(spec),
            # THE CLOUD, so the `min_scale` gate in `_serverless_node`'s body
            # can fire: a bundle authoring `scaling { min: 1 }` composes that 1 on
            # GCP and composes 0 + a RECORDED withhold on AWS, out of ONE bundle.
            cloud,
            # THE APP'S OWN DECLARED COMPUTE ALLOCATION (AppSpec 38/39). The
            # served app's compute node is the unit a bill is drawn against.
            #
            # THE BUNDLE'S VALUE, VERBATIM, OR NOTHING. `_authored_cpu` /
            # `_authored_memory` REFUSE an authored-empty `cpu: ""` by name here
            # at compose — before any cloud call, so `kci <app> plan` shows it —
            # and carry an OMISSION through as absent rather than defaulting.
            # Compose does not invent an allocation: a fabricated "0m" is an
            # un-billed customer and is byte-identical to an idle one.
            _authored_cpu(spec, svc.name),
            _authored_memory(spec, svc.name),
            # THE APP'S HEALTHCHECK ENDPOINT (AppSpec field 40 -> node field 14).
            # The served app's compute node is the unit the placement service
            # probes; without a declared endpoint a resource would reach ACTIVE on
            # the strength of the cloud accepting the create, which is a fact
            # about the SERVICE RESOURCE and never about the APP.
            #
            # THE BUNDLE'S VALUE, VERBATIM, OR NOTHING.
            # `_authored_health_check_path` REFUSES an authored-empty
            # `health_check_path: ""` by name here at compose, and carries an
            # OMISSION through as absent rather than defaulting to `/healthz` —
            # which would give up on an app that never asked to be probed there.
            _authored_health_check_path(spec, svc.name),
        )
    )

    # -- VALIDATOR-INVOKE grant. The in-cloud validation JOB RUNS AS the deploy
    #    principal, so it needs run.invoker on THIS service to mint an accepted
    #    OIDC token + reach it (a PRIVATE-ingress service the LOCAL fork-exec
    #    cannot). Emitted ONLY for a SELF-PROVISION service — an app with no
    #    `runtime_identity` is validated via LOCAL SUBPROCESS. Reuses the unified
    #    Grant mechanism (`_grant_node` hardcodes INVOKE_SERVICE on a `<T>-svc`
    #    target): principal = DEPLOY_PRINCIPAL, target = THIS service's OWN
    #    `<S>-svc`, depends_on [<S>-svc] (grant-after-target-exists — the served
    #    node IS in this graph). Appended AFTER the served node (like the SVCREF
    #    invoke grants).
    #
    # NOT ON `CLOUD_AWS`: its AWS carrier is `PutRolePolicy` on the day-0 deploy
    #    role, which the AWS grant conformer refuses for TWO independent,
    #    permanent reasons. The whole argument, and why this is a different
    #    question from `_runtime_invoke_is_a_grant_node_on_cloud`, is in
    #    `_validator_runs_as_the_deploy_principal_on_cloud`.
    if self_provision and _validator_runs_as_the_deploy_principal_on_cloud(
        cloud
    ):
        var vg_target = svc.name + String("-svc")
        var vg_deps = List[String]()
        vg_deps.append(vg_target.copy())
        nodes.append(
            _grant_node(
                DEPLOY_PRINCIPAL + String("-invokes-") + svc.name,
                DEPLOY_PRINCIPAL,
                vg_target^,
                vg_deps^,
            )
        )

    # -- PUBLIC (allUsers) INVOKER grant (AppSpec.public_invoker, field 24). When
    #    the bundle OPTS IN (`public_invoker: true`), emit ONE INVOKE_SERVICE grant
    #    on THIS service's OWN `<S>-svc`, principal = the `allUsers` SENTINEL (the
    #    mapper threads it verbatim; the GCP grant conformer binds the LITERAL IAM
    #    member `allUsers` -> `roles/run.invoker`, i.e. PUBLIC/unauthenticated
    #    ingress at the network layer). Reuses the SAME unified Grant mechanism as
    #    the validator-invoke grant (`_grant_node` hardcodes INVOKE_SERVICE on a
    #    `<T>-svc` target), depends_on [<S>-svc] (grant-after-target-exists). This
    #    is INDEPENDENT of `self_provision`: the publicness is a property of the
    #    SERVED SERVICE, not the runtime identity.
    #
    #    It is for a service dialed by a peer with NO OIDC identity to present (a
    #    browser over wss://, say), so IAM cannot gate it and security lives in
    #    the APP layer. EMPTY/false (the default) => NO node emitted => the
    #    service stays PRIVATE (scoped run.invoker only) — a bundle must OPT IN
    #    explicitly. A service invoked by OIDC-authenticated peers MUST NOT set
    #    this.
    if spec.public_invoker:
        var pub_target = svc.name + String("-svc")
        var pub_deps = List[String]()
        pub_deps.append(pub_target.copy())
        nodes.append(
            _grant_node(
                # a STABLE logical id distinct from every SA-principal grant on this
                # service (the sentinel `allUsers` is never an SA, so no collision).
                String("allUsers-invokes-") + svc.name,
                PUBLIC_INVOKER_PRINCIPAL,  # the `allUsers` sentinel (mapper: verbatim)
                pub_target^,
                pub_deps^,
            )
        )


# =============================================================================
# THE PER-CLOUD GRANT GATE — "a node no cloud should CREATE is a node no cloud
#    should COMPOSE" (the PROJECT_SERVICE precedent).
# =============================================================================
#
# An AWS env must not compose GCP-only resources. For RESOURCE_KIND_PROJECT_SERVICE
# the bootstrap composition does not emit GCP API-enable nodes into an AWS graph;
# the fix lives in the COMPOSER rather than the arm. This is the SAME rule on
# GRANT nodes, in this file, and it is deliberately the same shape: a `cloud`
# threaded down, a predicate, and an early `continue` — never a second
# convention.
#
# THE SET IS **NOT** "everything AWS refuses". The authority is the AWS IaC
# arm's capability-gap reasons, and they hold TWO kinds of refusal that must not
# be collapsed:
#
#   * PERMANENT — a GCP concept with no AWS peer, adjudicated with its argument.
#     Composing one for an AWS env asks for a resource nobody will ever build.
#     THOSE are gated here.
#   * NOT-YET — AWS has a peer and the row is unwritten. Gating one of THOSE
#     would delete the work from the plan: the operator would see a smaller
#     graph and NO gap, and the missing authorization would surface as a 403 at
#     the grantee's first call. They stay composed and stay REPORTED as gaps.
#
# `_capability_is_permanently_absent_on_aws` is the criterion, never "the arm
# refuses it" — that is what keeps the NEXT ordinal from being gated on the
# strength of a refusal alone.
#
# THE ORDINALS ARE MIRRORED HERE, NOT IMPORTED, and that is a real cost stated
# rather than hidden. This package keeps a tight dep closure, and the AWS IaC
# package is a cloud ARM — importing it into the NEUTRAL IR composer would invert
# the layering this gate exists to defend. So the mirror is FALSIFIED rather
# than avoided: the AWS arm's tests link BOTH and assert, ordinal by ordinal,
# that every capability gated here has a non-empty gap reason, and that the
# NOT-YET ordinals this file composes are NOT gated.
#
# AND THE GATE IS KEYED ON `CLOUD_AWS`, NOT ON `!= CLOUD_GCP`. The
# PROJECT_SERVICE gate can write `!= CLOUD_GCP` because API-enablement is a
# GCP-only concept full stop. Here the EVIDENCE is AWS-specific — every reason
# above is a sentence about IAM roles, `AssumeRolePolicyDocument` and
# per-account API enablement — and `!= CLOUD_GCP` would be WRONG for
# CLOUD_LOCAL, which IS the GCP posture run against emulators. Widening this to
# Azure or Kubernetes needs those arms' own adjudication, never an
# extrapolation from AWS's.

# The `Cloud` posture ordinals, MIRRORED from the env-binding layer (itself a
# mirror of `environment.proto`'s `Cloud`). See the dep-closure note above for
# why this is a mirror.
comptime CLOUD_UNSPECIFIED: Int = 0
comptime CLOUD_GCP: Int = 1
comptime CLOUD_AWS: Int = 2


def _capability_is_permanently_absent_on_aws(cap: Int) -> Bool:
    """Whether `cap` is a GCP concept AWS will never have a peer for — PERMANENT,
    never NOT-YET.

    THE FOUR:

      * IMPERSONATE (7) — on GCP, "who may act as this identity" is N separate
        `serviceAccountTokenCreator` GRANTS. On AWS it is a FIELD of the role, its
        `AssumeRolePolicyDocument`. There is no grant to compose because there is
        no grant-shaped thing.
      * LOG_WRITE (10) — on GCP a PROJECT-scoped `roles/logging.logWriter`
        binding, and AWS has no project. On AWS "may this identity write logs" is
        a property of the EXECUTION ROLE, minted WITH it: the mapper's
        SERVICE_ACCOUNT arm attaches the log-write policies for every function
        running as the role. That carrier exists; gating a node whose authority
        is carried by NOTHING is the over-reach this predicate exists to prevent.
      * SERVICE_USAGE (11) — the CONSUMER half of API enablement, whose ADMIN half
        (ENABLE_SERVICES 17) is the concept the PROJECT_SERVICE gate removes. AWS
        has no per-account enablement, so there is no enablement state for a
        principal to be a consumer of.
      * SERVICE_ACCOUNT_USER (14) — GCP needs an explicit act-as grant for an
        identity to run as itself; an AWS execution role IS the principal, so the
        node disappears. (`iam:PassRole` is the near neighbour and belongs to the
        compute-attach path, not here.)

    MORE ORDINALS ARE PERMANENT AND ARE DELIBERATELY **NOT** IN THIS SET,
    because this file composes none of them and a predicate is not a place to
    list capabilities for their own sake. ENABLE_SERVICES (17),
    BIND_MANAGED_SERVICE (25) and READ_ARTIFACT_REPOSITORY_IAM (27) are composed
    only by the bootstrap composition; ADMIN_SERVERLESS_COMPUTE (12) is permanent
    in ONE of its two halves and NOT-YET in the other, so it is not a member of
    this set at all. Listing them here would gate nothing and read as
    coverage."""
    return (
        cap == Capability.CAPABILITY_IMPERSONATE
        or cap == Capability.CAPABILITY_LOG_WRITE
        or cap == Capability.CAPABILITY_SERVICE_USAGE
        or cap == Capability.CAPABILITY_SERVICE_ACCOUNT_USER
    )


def _grant_composes_on_cloud(cap: Int, cloud: Int) -> Bool:
    """Whether a GRANT of `cap` should be COMPOSED at all for a `cloud` env.

    TWO-SIDED, AND THAT IS THE POINT — the PROJECT_SERVICE gate's own warning,
    which applies here unchanged. The catastrophic implementation of this
    predicate is one that returns False on EVERY cloud: it silently deletes the
    runtime SA's `serviceUsageConsumer` binding and the deployer's token-creator
    / act-as trust from every GCP deploy, and the next `kci deploy` then cannot
    run a service AS its own runtime SA, with no clue why. A one-sided assertion
    ("AWS composes zero") passes for that implementation, so the falsifier
    states the GCP side as the FULL grant set rather than as "> 0"."""
    if cloud != CLOUD_AWS:
        return True
    return not _capability_is_permanently_absent_on_aws(cap)


def _append_base_grant(
    mut nodes: List[ResourceNode],
    var logical_id: String,
    var principal: String,
    capability: Int,
    var target: String,
    var deps: List[String],
    cloud: Int,
) raises:
    """Append ONE self-provision base grant — UNLESS this cloud has no peer for its
    capability, in which case append NOTHING.

    THE **ONLY** WAY `_append_runtime_sa_nodes` EMITS A BASE GRANT, and that
    exclusivity is the whole value of this function. Wrapping an
    `if _grant_composes_on_cloud(...)` around only the currently-gated grants
    and leaving the others calling `nodes.append(_base_grant_node(...))`
    directly works and it rots: `_capability_is_permanently_absent_on_aws`
    becomes a list only some call sites read, so ADDING an ordinal to it changes
    nothing — a predicate that cannot be wrong because nothing consults it.

    ⇒ ROUTING EVERY BASE GRANT THROUGH ONE FUNCTION makes the membership
      load-bearing: the day another capability is adjudicated PERMANENT, one line
      in the predicate gates every site that emits it, and a mutation of that
      list is visible in the composed manifest."""
    if not _grant_composes_on_cloud(capability, cloud):
        _ = logical_id^
        _ = principal^
        _ = target^
        _ = deps^
        return
    nodes.append(
        _base_grant_node(
            logical_id^, principal^, capability, target^, deps^
        )
    )


# =============================================================================
# EXTRA runtime capability grants (AppSpec.runtime_extra_capabilities, field 21).
# The GENERIC per-service extra-grant mechanism (no per-service special-casing): a
# bundle DECLARES additional project-scoped capability ordinals its runtime SA
# needs beyond the base grants, and compose emits ONE project-scoped grant per
# ordinal. ONLY the project-scoped capabilities are legal (a target=="" grant).
# A NON-project-scoped or UNSPECIFIED/out-of-range ordinal FAIL-FASTS at compose
# (before apply).
def _is_project_scoped_capability(cap: Int) -> Bool:
    """Whether `cap` is a project-scoped capability (a target=="" grant) legal as an
    AppSpec.runtime_extra_capabilities entry. The project-scoped set mirrors the
    conformer's `_resource_for_capability` project arm: READ_WRITE_DATASTORE(9), LOG_WRITE(10),
    SERVICE_USAGE(11), ADMIN_SERVERLESS_COMPUTE(12), PUSH_MESSAGING(13)."""
    return (
        cap == Capability.CAPABILITY_READ_WRITE_DATASTORE
        or cap == Capability.CAPABILITY_LOG_WRITE
        or cap == Capability.CAPABILITY_SERVICE_USAGE
        or cap == Capability.CAPABILITY_ADMIN_SERVERLESS_COMPUTE
        or cap == Capability.CAPABILITY_PUSH_MESSAGING
        # PLACE_JOB_VM (29) joins the set, and it is project-scoped for a LAW
        # rather than by convention: the twelve permissions authorize an
        # `instances.insert`, and at the moment GCE checks them the instance and
        # its boot disk do not exist and have no policy to bind on (the
        # ADMIN_OBJECT_STORE argument). See `_append_extra_capability_grants` —
        # authoring THIS ordinal also emits the custom-role node whose role the
        # grant names and the SA-scoped act-as grant no project-scoped role can
        # carry.
        or cap == Capability.CAPABILITY_PLACE_JOB_VM
        # READ_SERVERLESS_COMPUTE (30) — the READ-ONLY companion of
        # ADMIN_SERVERLESS_COMPUTE (12), for a validate identity that must read a
        # deployed Cloud Run service's own `template.serviceAccount` and
        # `template.containers[].env[].name` back. Project-scoped because that is
        # the only scope this authoring surface composes; `roles/run.viewer`
        # carries 50 permissions and not one of them is a write.
        or cap == Capability.CAPABILITY_READ_SERVERLESS_COMPUTE
        # READ_IAM_POLICY (31) — the authority the GRANT READ-BACK probe needs
        # to call `getIamPolicy` on the six target kinds the GCP conformer forms,
        # so the comparison can report an UNDECLARED role and not only a missing
        # one. Project-scoped because the probe addresses up to 26 distinct
        # targets of six kinds per cell and `roles/iam.securityReviewer` is
        # measured bindable at all six scopes, so one binding covers them all.
        # It does NOT subsume ordinal 30: that role carries
        # `run.services.getIamPolicy` and NOT `run.services.get`.
        or cap == Capability.CAPABILITY_READ_IAM_POLICY
    )


comptime GCE_JOB_PLACEMENT_CUSTOM_ROLE_ID: String = "kciJobPlacementGce"
"""The custom-role id `CAPABILITY_PLACE_JOB_VM` binds — and, because kind 27
carries its identity in `logical_id`, ALSO the node's own id.

IT IS A PERSISTENT KEY IN TWO SYSTEMS AT ONCE, which is stricter than either
alone. Renaming it does not rename the role in GCP (the next apply sees a role
it has never reconciled beside a live one nothing claims) AND it does not rename
the node (the next apply sees a CREATE beside an ORPHAN). Same rule as
`_extra_capability_label`'s node-id fragments, doubled.

camelCase where every other kci identifier is kebab-case, and that is forced:
a GCP custom-role id is `[a-zA-Z0-9_.]{3,64}` and may NOT contain `-`.

MUST EQUAL the GCP bridge's job-placement role id, which OWNS it along with the
permission set and the reviewed document; the bridge's tests hold the equality.
It is a copy rather than an import because this package is the intent tier and
must not depend on a cloud bridge."""


def _custom_role_node(var role_id: String) raises -> ResourceNode:
    """The IamCustomRole node (kind 27) — a PROJECT CUSTOM ROLE holding an exact
    permission list, so a grant can bind an authority no predefined role
    expresses without also conveying far more.

    NO ONEOF ARM, AND THAT IS THE SCHEMA'S DECISION. Kind 27 carries its
    entire identity in `logical_id` (the `RESOURCE_KIND_PROJECT_SERVICE` /
    `RESOURCE_KIND_MAIL_DOMAIN_IDENTITY` shape): the ROLE ID is the identity, and
    the PERMISSION LIST is vendor vocabulary that lives in the conformer's
    registry keyed on that id — exactly where a `Capability` ordinal's role
    string already lives. A neutral IR carrying `compute.instances.create` would
    be naming GCP's vocabulary in the schema every cloud reads.

    RETENTION_RETAIN_KEEP, AND IT IS NOT THE USUAL DATA-PROTECTION
    ARGUMENT. `projects.roles.delete` is a SOFT delete: GCP holds the id in a
    7-day tombstone during which the role can be neither re-created nor patched,
    and the only repair is an `undelete` nothing composes. So an app-lifecycle
    RETENTION_DELETE would make a routine destroy/recreate a hard, week-long
    failure — and, worse, would let ONE bundle's teardown remove a
    PROJECT-scoped object other principals may hold, which is the shared-resource
    hazard `shared_resource_guard` exists for. A GRAPH ROOT: the role must
    exist before anything binds it, and it depends on nothing."""
    return ResourceNode(
        role_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_IAM_CUSTOM_ROLE),
        List[String](),  # a graph ROOT — the role precedes every binding of it
        Retention(Retention.RETENTION_RETAIN_KEEP),
        0,  # NO oneof arm set (kind 27 carries its identity in logical_id)
        None, None, None, None, None, None, None, None, None, None,  # arms 1-10
        None, None, None, None, None, None, None, None, None, None,  # arms 11-20
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _extra_capability_label(cap: Int) -> String:
    """A stable, human-readable grant-id fragment for an extra-capability ordinal
    (`<svc>-role-extra-<label>-grant`). Keyed on the ordinal so the node id is
    deterministic + diffable (the same authored ordinal keeps a stable node key).

    THE LABEL DOES NOT FOLLOW A CAPABILITY RENAME, AND THAT IS THE POINT OF
    "KEYED ON THE ORDINAL". Ordinal 9 is `READ_WRITE_DATASTORE` and ordinal 12
    `ADMIN_SERVERLESS_COMPUTE`; their labels read `datastore-use` /
    `run-developer` DELIBERATELY: a node id is a PERSISTENT KEY on a live
    resource graph, so renaming the fragment does not rename anything in the
    cloud — it makes the next apply see a node id it has never reconciled
    (CREATE) beside a live one nothing claims (ORPHAN). The enum's NAME is
    vocabulary; a node id is state. Only a deliberate, separately reasoned
    migration may move one.
    """
    if cap == Capability.CAPABILITY_READ_WRITE_DATASTORE:
        return String("datastore-use")  # node-id key — NOT the enum name
    if cap == Capability.CAPABILITY_LOG_WRITE:
        return String("log-write")
    if cap == Capability.CAPABILITY_SERVICE_USAGE:
        return String("service-usage")
    if cap == Capability.CAPABILITY_ADMIN_SERVERLESS_COMPUTE:
        return String("run-developer")  # node-id key — NOT the enum name
    if cap == Capability.CAPABILITY_PUSH_MESSAGING:
        return String("push-messaging")
    if cap == Capability.CAPABILITY_PLACE_JOB_VM:
        return String("place-job-vm")
    if cap == Capability.CAPABILITY_READ_SERVERLESS_COMPUTE:
        return String("run-viewer")  # node-id key — NOT the enum name
    if cap == Capability.CAPABILITY_READ_IAM_POLICY:
        return String("iam-policy-read")  # node-id key — NOT the enum name
    return String("cap") + String(cap)


def _append_extra_capability_grants(
    mut nodes: List[ResourceNode],
    service_name: String,
    runtime_id: String,
    var deps: List[String],
    extra_capabilities: List[Int32],
    cloud: Int,
) raises:
    """Emit ONE project-scoped `RESOURCE_KIND_GRANT` node per declared extra capability
    (AppSpec.runtime_extra_capabilities). Each grant: principal == `runtime_id`, target
    == "" (project-scoped -> `projects/<P>`), `depends_on` the SA node (grant-after-SA-
    exists). FAIL-FASTS on an UNSPECIFIED / out-of-range / NON-project-scoped ordinal
    (a bundle must not author, e.g., READ_SECRET here — that is a resource-scoped grant
    with a target). DEDUPE against a capability already covered by the base
    grants (READ_WRITE_DATASTORE / LOG_WRITE / SERVICE_USAGE) — a redundant
    declaration is a no-op, so a bundle re-declaring a base capability does not
    emit a duplicate node key. EMPTY => nothing appended.

    THE `cloud` GATE APPLIES HERE TOO, AND ITS ORDER RELATIVE TO THE FAIL-FAST IS
    LOAD-BEARING. The authoring refusal above runs FIRST and on EVERY cloud: a
    bundle that authors a non-project-scoped ordinal has a BUG, and an AWS env
    must not make that bug silent by skipping the node before the check. Only
    after the ordinal is known well-formed does the per-cloud gate drop it. Of
    the legal ordinals here, SERVICE_USAGE (11) and LOG_WRITE (10) are permanent
    AWS absences (both are already in the base set, so a declaration dedupes
    away); the arm is written anyway, because a predicate that covers one
    emission site of a capability and not its sibling is how one set of grants
    comes to be gated and another not."""
    var seen = List[Int]()  # per-service dedupe (incl. the 3 base project capabilities)
    seen.append(Capability.CAPABILITY_READ_WRITE_DATASTORE)
    seen.append(Capability.CAPABILITY_LOG_WRITE)
    seen.append(Capability.CAPABILITY_SERVICE_USAGE)
    for i in range(len(extra_capabilities)):
        var cap = Int(extra_capabilities[i])
        if not _is_project_scoped_capability(cap):
            raise Error(
                String("compose_api: runtime_extra_capabilities ordinal ")
                + String(cap)
                + String(
                    " on service '"
                )
                + service_name
                + String(
                    "' is not a project-scoped capability — only the project-scoped"
                    " ordinals (READ_WRITE_DATASTORE=9 / LOG_WRITE=10 / SERVICE_USAGE=11 /"
                    " ADMIN_SERVERLESS_COMPUTE=12 / PUSH_MESSAGING=13) may be authored here (a"
                    " resource-scoped grant needs a target; fail-fast)"
                )
            )
        var dup = False
        for k in range(len(seen)):
            if seen[k] == cap:
                dup = True
                break
        if dup:
            continue
        seen.append(cap)
        # THE PER-CLOUD GATE, AFTER the authoring fail-fast and AFTER the dedupe
        # bookkeeping — `seen` records the ordinal either way, so a bundle that
        # declares one twice behaves identically on every cloud.
        if not _grant_composes_on_cloud(cap, cloud):
            continue
        var grant_deps = deps.copy()
        if cap == Capability.CAPABILITY_PLACE_JOB_VM:
            # THE ONE ORDINAL WHOSE GRANT IS NOT SELF-SUFFICIENT. Everything else
            # in this loop names a PREDEFINED role, which exists in every project
            # before anything is deployed. `PLACE_JOB_VM` names the PROJECT
            # CUSTOM ROLE `projects/<P>/roles/<GCE_JOB_PLACEMENT_CUSTOM_ROLE_ID>`,
            # which exists only because this graph creates it — so authoring the
            # ordinal must emit TWO more nodes, and they are DERIVED here rather
            # than authored separately for one reason: three things that must
            # always agree cannot be three independent statements in a bundle.
            #
            #   (1) the kind-27 IamCustomRole node — the role OBJECT.
            #   (2) the SA-scoped act-as grant — `iam.serviceAccounts.actAs`,
            #       which GCP evaluates on the SERVICE ACCOUNT resource and which
            #       therefore can NEVER ride the project-scoped role. It is in
            #       NEITHER `roles/compute.instanceAdmin.v1` NOR
            #       `roles/compute.admin`, so there is no predefined role that
            #       would have carried it either.
            #
            # (2)'s TARGET IS THIS SERVICE'S OWN RUNTIME SA, AND THAT IS A
            # PREMISE WORTH STATING. A placer that attaches its own runtime SA to
            # the VM it places needs "attach YOURSELF to a VM you placed" and
            # nothing more. A project-scoped `roles/iam.serviceAccountUser`
            # instead would let this identity attach EVERY service account in the
            # project — including the deploy principal — to a VM whose startup
            # script it also chooses, which is arbitrary code execution as any
            # identity in the project.
            if cloud == CLOUD_AWS:
                raise Error(
                    String(
                        "compose_api: runtime_extra_capabilities ordinal 29"
                        " (PLACE_JOB_VM) on service '"
                    )
                    + service_name
                    + String(
                        "' has no AWS form as a GRANT node. On AWS the same"
                        " authority is an INLINE POLICY on the execution role,"
                        " minted with the role itself, not a binding to a named"
                        " role object — which is why kind 27 is DESIGNED-ABSENT"
                        " on the AWS arm. Refused here rather than gated"
                        " silently: this ordinal is deliberately NOT in"
                        " `_capability_is_permanently_absent_on_aws`, because"
                        " gating it would delete the authority from the plan"
                        " and the operator would see a smaller graph and no gap."
                    )
                )
            var role_node_id = String(GCE_JOB_PLACEMENT_CUSTOM_ROLE_ID)
            var already = False
            for n in range(len(nodes)):
                if nodes[n].logical_id == role_node_id:
                    already = True
                    break
            if not already:
                # ONE NODE PER PROJECT, NOT ONE PER SERVICE — deduped on the
                # ROLE ID, which IS the node's logical_id. A custom role is a
                # single project-scoped object; two nodes naming it would race to
                # create it and fight over deleting it, and `ResourceGraph.add`
                # dedupes LOGICAL ids, so the second would be dropped silently
                # rather than caught.
                nodes.append(_custom_role_node(role_node_id.copy()))
            grant_deps.append(role_node_id.copy())
            nodes.append(
                _base_grant_node(
                    service_name + String("-role-actas-vm-sa-grant"),
                    runtime_id,
                    Capability.CAPABILITY_SERVICE_ACCOUNT_USER,
                    # SA-SCOPED: the mapper expands this flat `<svc>-role` to the
                    # full SA email and the conformer forms
                    # `projects/<P>/serviceAccounts/<email>`. Not `""` — an empty
                    # target here is a PROJECT-scoped act-as, which is the exact
                    # widening this grant exists to avoid.
                    runtime_id,
                    deps.copy(),
                )
            )
        nodes.append(
            _base_grant_node(
                service_name
                + String("-role-extra-")
                + _extra_capability_label(cap)
                + String("-grant"),
                runtime_id,
                cap,
                String(""),  # project-scoped (target=="")
                grant_deps^,
            )
        )
    _ = deps^


def _append_runtime_sa_nodes(
    mut nodes: List[ResourceNode],
    service_name: String,
    var runtime_id: String,
    var sa_id: String,
    extra_capabilities: List[Int32],
    cloud: Int,
    # THE AUTHORED DATASTORE COLLECTION NAMES this service composes — EMPTY
    # when it authors none. Read by exactly ONE emission below: the
    # READ_WRITE_DATASTORE (9) base grant. See
    # `_datastore_grant_is_resource_scoped_on_cloud`.
    var datastore_collections: List[String] = List[String](),
) raises:
    """Emit the runtime ServiceAccount node (graph ROOT, id `<name>-role-sa`) that
    CREATES `runtime_id` + its FIVE base capability grants:
      RESOURCE-scoped (external BOOTSTRAP targets referenced BY NAME — the grant
        conformer self-derives the resource path from the name, NO graph
        dependency): READ_OBJECT_STORE (the `<project>-bootstrap` state bucket —
        EMPTY target, the below-the-line mapper self-derives it from the project
        since the pure compose has none), READ_ARTIFACTS (the `ARTIFACT_REPO_ID`
        artifact repo).
      PROJECT-scoped (target=="" -> `projects/<P>`): READ_WRITE_DATASTORE (reach
        the datastore), LOG_WRITE (emit structured logs), SERVICE_USAGE (call
        enabled APIs).
    Each grant's principal == `runtime_id` (the EXACT SA the node creates + the
    ServerlessCompute node runs AS) and `depends_on` the SA node
    (grant-after-SA-exists). Mirrors the bootstrap composition's runtime-SA
    grants. A secret the service reads is NOT a base grant: it is declared in
    `secret_bindings` and granted per handle by the caller.

    THE DEPLOY-SA TRUST (2 grants, ALWAYS emitted per self-provision): the
    deployer (`DEPLOY_PRINCIPAL`) gets IMPERSONATE (tokenCreator) +
    SERVICE_ACCOUNT_USER (act-as) on the `<svc>-role` SA created here — so
    `kci deploy` can run a service AS its runtime SA + mint its impersonation
    token. Authored HERE (not bootstrap) so it orders grant-after-SA-exists (a
    self-provisioned runtime SA does not exist at bootstrap time).

    EXTRA CAPABILITIES (`extra_capabilities` == AppSpec.runtime_extra_capabilities):
    on TOP of the base grants + the 2 trust grants, emit ONE project-scoped grant
    per declared ordinal (the generic per-service extra-grant mechanism).
    Fail-fast on a non-project-scoped ordinal; dedupe against the 3 base project
    capabilities. EMPTY => the base + trust grant set only.

    FOUR OF THOSE SEVEN GRANTS ARE NOT COMPOSED ON `CLOUD_AWS`: SERVICE_USAGE
    (11) and LOG_WRITE (10) of the base five, and BOTH trust grants —
    IMPERSONATE (7) and SERVICE_ACCOUNT_USER (14). Each is a PERMANENT AWS
    absence with its argument written down in the AWS arm's capability-gap
    reasons, and composing one would ask the AWS arm for a resource it must
    never build. `_grant_composes_on_cloud` is the gate and its section header
    carries the reasoning. LOG_WRITE (10) is the one of the four whose
    authority is carried by an AWS structure this composer's own graph still
    contains: the runtime SA node stays, and the mapper attaches the log-write
    inline policies to the role it mints from it.

    THE SA NODE ITSELF IS **NOT** GATED, and that is the load-bearing half.
    Its AWS peer exists and is materialized — `RESOURCE_KIND_SERVICE_ACCOUNT`
    maps through the AWS IAM role conformer to a real IAM role. What disappears
    on AWS is the SEPARATE act-as/token-creator grant, because an AWS execution
    role IS the principal; the identity does not disappear with it.

    AND THE THREE THAT REMAIN ARE **STILL COMPOSED ON AWS ON PURPOSE**:
    READ_ARTIFACTS (5) and READ_WRITE_DATASTORE (9) MAP, and READ_OBJECT_STORE
    (3) maps once the arm resolves its empty target. The rule is what governs
    the NEXT ordinal: dropping a NOT-YET here would delete the work from the
    plan, which is strictly worse than a reported gap. "The arm refuses it" is
    NOT the criterion; `_capability_is_permanently_absent_on_aws` is."""
    nodes.append(
        _service_account_node(
            sa_id.copy(),
            runtime_id.copy(),
            String("kci ") + service_name + String(" runtime SA"),
        )
    )
    var deps = List[String]()
    deps.append(sa_id^)  # every base grant orders AFTER the SA node exists
    # EVERY BASE GRANT BELOW GOES THROUGH `_append_base_grant`, WHICH CONSULTS
    # THE PER-CLOUD GATE — including the ones that are never gated today. That
    # is the point: the alternative (an `if` wrapped around only the
    # currently-gated ones) makes `_capability_is_permanently_absent_on_aws` a
    # list nobody reads, so ADDING an ordinal to it changes nothing and the next
    # capability adjudicated PERMANENT gets composed into AWS graphs anyway.
    #
    # READ_OBJECT_STORE on the bootstrap bucket — EMPTY target (the mapper resolves
    # `<project>-bootstrap` from its project binding; the pure compose has no project).
    #
    # THIS ONE IS COMPOSED ON AWS. It is NOT a permanent absence — S3 has the
    # peer and the AWS arm renders the capability — what is missing is the
    # TARGET: the AWS arm has no project to resolve `<project>-bootstrap` from.
    # Gating it here would be exactly the NOT-YET mistake this gate refuses to
    # make; the answer is the arm resolving `<account_ref>-bootstrap`, which is
    # the same name the bootstrap composition composes as the AWS day-0 S3 bucket
    # node.
    _append_base_grant(
        nodes,
        service_name + String("-role-read-bucket-grant"),
        runtime_id.copy(),
        Capability.CAPABILITY_READ_OBJECT_STORE,
        String(""),
        deps.copy(),
        cloud,
    )
    # READ_ARTIFACTS on the bootstrap AR repo (external target, by NAME).
    _append_base_grant(
        nodes,
        service_name + String("-role-read-artifacts-grant"),
        runtime_id.copy(),
        Capability.CAPABILITY_READ_ARTIFACTS,
        ARTIFACT_REPO_ID,
        deps.copy(),
        cloud,
    )
    # PROJECT-scoped runtime roles (target=="" -> `projects/<P>`).
    #
    # EXCEPT ON `CLOUD_AWS` WHEN THIS SERVICE AUTHORS ITS OWN STORES, WHERE THE
    #   PROJECT-SCOPED FORM IS AN OVER-GRANT ON A TABLE THAT IS NOT THIS APP'S.
    #   AWS has no project, so a DEPLOYMENT scope has no exact transcription: any
    #   single table the mapper resolves it to is a DIFFERENT set from the stores
    #   this service composes.
    #
    #   The fix is a RESOLVED TARGET pointing at the kind-4 node, never a
    #   widening. So on AWS, with collections authored, this emits ONE
    #   RESOURCE-scoped grant PER STORE instead of one DEPLOYMENT-scoped grant —
    #   exact coverage, no foreign table, and no arbitrary pick between N stores
    #   (one document carries ONE `Resource` ARN, so "the first one" would be a
    #   silent wrong answer for the other N-1).
    if _datastore_grant_is_resource_scoped_on_cloud(cloud) and len(
        datastore_collections
    ) > 0:
        for dsi in range(len(datastore_collections)):
            # THE NODE ID COMES FROM `datastore_node_id_for`, THE SAME FUNCTION
            # `_datastore_node_ids_for` USES — never re-spelled here. The
            # grant's target is a GRAPH REFERENCE, so a second derivation that
            # drifted by one character would compose a RESOURCE scope naming no
            # node, and the AWS arm would fall through to the external-name arm
            # and hand the id back as if it were a table NAME.
            var collection = datastore_collections[dsi].copy()
            var store_id = datastore_node_id_for(service_name, collection)
            var store_deps = deps.copy()
            # grant-after-store-exists, on top of grant-after-SA-exists. Both
            # ends are in THIS graph, which is what makes the resource-scoped
            # form expressible at all.
            store_deps.append(store_id.copy())
            _append_base_grant(
                nodes,
                service_name
                + String("-role-datastore-use-")
                + collection
                + String("-grant"),
                runtime_id.copy(),
                Capability.CAPABILITY_READ_WRITE_DATASTORE,
                store_id^,
                store_deps^,
                cloud,
            )
    else:
        _append_base_grant(
            nodes,
            service_name + String("-role-datastore-use-grant"),
            runtime_id.copy(),
            Capability.CAPABILITY_READ_WRITE_DATASTORE,
            String(""),
            deps.copy(),
            cloud,
        )
    # LOG_WRITE — DROPPED ON `CLOUD_AWS`. GCP's peer is a PROJECT-scoped
    # `roles/logging.logWriter` binding and AWS has no project, so this grant
    # arrives with an EMPTY target whose only account-wide transcription is every
    # log group in the account. On AWS the authority is a property of the
    # EXECUTION ROLE and is minted WITH it — the mapper's SERVICE_ACCOUNT arm
    # attaches the log-write inline policies for every function running as this
    # SA. THE SA NODE ABOVE IS NOT GATED, which is what makes this safe: the
    # identity this grant was about is still composed, and it is the thing that
    # carries the authority.
    _append_base_grant(
        nodes,
        service_name + String("-role-log-write-grant"),
        runtime_id.copy(),
        Capability.CAPABILITY_LOG_WRITE,
        String(""),
        deps.copy(),
        cloud,
    )
    # SERVICE_USAGE — DROPPED ON `CLOUD_AWS`. AWS has no per-account API
    # enablement, so there is no enablement state for a principal to be a
    # CONSUMER of; the AWS capability table refuses it permanently and names this
    # composer as the place the decision belongs. NOT a `!= CLOUD_GCP` test — see
    # `_grant_composes_on_cloud`.
    _append_base_grant(
        nodes,
        service_name + String("-role-service-usage-grant"),
        runtime_id.copy(),
        Capability.CAPABILITY_SERVICE_USAGE,
        String(""),
        deps.copy(),
        cloud,
    )
    # THE DEPLOY-SA -> RUNTIME-SA impersonation/act-as trust. The deployer must be
    # able to IMPERSONATE (mint tokens AS) and ACT-AS (attach / run a Cloud Run
    # service AS) this service's runtime SA — else `kci deploy` cannot deploy a
    # service that RUNS AS `<svc>-role` (serviceAccountUser) nor mint an
    # impersonation token for it (tokenCreator). A self-provisioned runtime SA is
    # created HERE, not at bootstrap, so a bootstrap-composed grant on it would
    # 404 — authoring the trust HERE (grant-after-SA-exists: each depends_on the
    # SA node) is the correct create-order. principal = the deployer short name
    # `DEPLOY_PRINCIPAL` (the mapper expands it to `<name>@<project>`); target =
    # the `<svc>-role` runtime SA (the mapper expands the short name to the full
    # SA email for the SA-scoped IMPERSONATE / SERVICE_ACCOUNT_USER resource
    # path). Generic: EVERY self-provisioned service authors the deployer's trust
    # on ITS OWN runtime SA. CAPABILITY_IMPERSONATE(7) ==
    # roles/iam.serviceAccountTokenCreator; SERVICE_ACCOUNT_USER(14) ==
    # roles/iam.serviceAccountUser.
    #
    # BOTH TRUST GRANTS ARE GATED ON `CLOUD_AWS`, and the reason is one sentence
    # per ordinal rather than "AWS is different". IMPERSONATE (7): on AWS the
    # trust set is a FIELD of the role — its `AssumeRolePolicyDocument` — so there
    # is no grant-shaped thing to compose. SERVICE_ACCOUNT_USER (14): an AWS
    # execution role IS the principal, so the act-as node disappears entirely.
    # WHAT DOES **NOT** DISAPPEAR IS THE NEED — a deploy into an AWS account
    # still has to be entitled to attach this role to a function — and that
    # entitlement is `iam:PassRole` on the DEPLOY path, granted where the compute
    # is attached rather than here.
    _append_base_grant(
        nodes,
        service_name + String("-role-deploy-token-creator-grant"),
        DEPLOY_PRINCIPAL,  # principal = the deploy principal (mapper -> full email)
        Capability.CAPABILITY_IMPERSONATE,  # roles/iam.serviceAccountTokenCreator
        runtime_id.copy(),  # target = the <svc>-role SA (mapper -> full email)
        deps.copy(),
        cloud,
    )
    _append_base_grant(
        nodes,
        service_name + String("-role-deploy-sa-user-grant"),
        DEPLOY_PRINCIPAL,  # principal = the deploy principal (mapper -> full email)
        Capability.CAPABILITY_SERVICE_ACCOUNT_USER,  # roles/iam.serviceAccountUser
        runtime_id.copy(),  # target = the <svc>-role SA (mapper -> full email)
        deps.copy(),
        cloud,
    )
    # EXTRA project-scoped capability grants (AppSpec.runtime_extra_capabilities)
    # — ONE grant per declared ordinal beyond the base grants. EMPTY => nothing
    # appended. Fail-fast on a non-project-scoped ordinal.
    _append_extra_capability_grants(
        nodes, service_name, runtime_id^, deps^, extra_capabilities, cloud
    )


def _append_grant_nodes(
    services: List[ServiceSpec], mut nodes: List[ResourceNode]
) raises:
    """GRANT AUTO-EMISSION: for each service S that has a `ServiceRef{
    service: T}` arm on an `spec.env` entry OR on an `spec.parameters` entry (the
    argv channel), emit ONE unified `Grant` node (INVOKE_SERVICE)
    so S's runtime identity may invoke T. principal = `<S>-role` (S's
    `runtime_identity` — the EXACT string carried on S's ServerlessCompute node, so
    the grant authorizes precisely the SA S runs as); target = `<T>-svc`;
    `depends_on = [<T>-svc]` (grant-after-target-exists). The grant node's own id is
    `<S>-invokes-<T>`.

    DEDUPE — one grant per (S, T) pair even when S references T from multiple env
    vars AND from a parameter (a service pair is granted invoke ONCE). Grants are
    appended AFTER every service node set, walked in (service-declaration, then
    env refs, then parameter refs) order — deterministic.

    SIBLING vs EXTERNAL target. A `ref("T")` whose T IS a sibling service in THIS
    bundle emits a grant with `depends_on = [<T>-svc]` (grant-after-target-exists —
    the callee's served node is in this same graph). A `ref("T")` whose T is NOT a
    sibling is treated as an EXTERNAL peer reference (T is deployed by its OWN
    bundle): the grant is
    still emitted (target `<T>-svc`, so the mapper recovers T's short name and the
    grant conformer self-derives T's Cloud Run resource by NAME), but with NO
    `depends_on` — there is no `<T>-svc` node in THIS graph to order against.
    EXTERNAL is gated on the bundle being SINGLE-service (no siblings exist, so any
    ref necessarily names a peer in another bundle); in a MULTI-service bundle a
    non-sibling ref is a TYPO and FAIL-FASTS (no dangling intra-bundle ref).

    A bundle with NO `service_ref` arm emits ZERO grant nodes (this is a pure
    no-op)."""
    # The valid target set = every (auto-lifted) service's logical name.
    var valid = List[String]()
    for i in range(len(services)):
        valid.append(services[i].name.copy())

    # EXTERNAL-target gate: a non-sibling ref is an EXTERNAL peer (deployed by its
    # OWN bundle) ONLY when THIS bundle has a single service — a single-service
    # bundle has NO siblings, so any ServiceRef necessarily names a peer in another
    # bundle. A MULTI-service bundle's non-sibling ref is a TYPO (fail-fast below).
    var single_service = len(services) <= 1

    for si in range(len(services)):
        var svc = services[si].copy()
        if not svc.spec:
            continue  # a missing spec already fail-fast'd in the node pass (defensive)
        var spec = svc.spec.value().copy()
        var seen = List[String]()  # targets already granted for THIS S (per-(S,T) dedupe)
        # THE TARGET SET IS THE UNION OF BOTH REFERENCE CHANNELS. `spec.env` and
        # `spec.parameters` are walked HERE, in the SAME pass with the SAME
        # dedupe list, because a `service_ref` PARAMETER renders the
        # `${svcref:T}` argv marker (`param_resolve.param_svcref_token`).
        #
        # ONE PASS, NOT TWO FUNCTIONS, AND THAT IS THE POINT. The grant and the
        # marker are two halves of ONE mechanism — a resolved URL the caller may
        # not invoke is a 403 with extra steps. Emitting them from separate walks
        # is how they would eventually come apart: an app that composes clean,
        # maps clean, and 403s on its first call with nothing in the graph to say
        # why. `seen` spanning both channels also means a service that references
        # T from an env var AND from a parameter is granted invoke ONCE.
        #
        # ORDER: env refs first, then parameter refs (declaration order within
        # each). A bundle with no parameter `service_ref` therefore emits the
        # env-ref grant list alone.
        var targets = List[String]()
        for ei in range(len(spec.env)):
            if spec.env[ei]._oneof0_case != 3:  # only the `service_ref` arm
                continue
            targets.append(spec.env[ei].service_ref.value().service.copy())
        for pi in range(len(spec.parameters)):
            if spec.parameters[pi]._oneof0_case != 5:  # only `service_ref`
                continue
            targets.append(
                spec.parameters[pi].service_ref.value().service.copy()
            )

        for ti in range(len(targets)):
            var target = targets[ti].copy()

            # Classify: is T a sibling service in THIS bundle?
            var is_sibling = False
            var sibling_kind = AppKind(AppKind.APP_KIND_UNSPECIFIED)
            for vi in range(len(valid)):
                if valid[vi] == target:
                    is_sibling = True
                    sibling_kind = AppKind(services[vi].kind.value)
                    break

            # FAIL-FAST: a SIBLING that SERVES NOTHING cannot be invoked, and the
            # grant this would emit is worse than useless — it would carry
            # `depends_on [<T>-svc]` naming a node that does not exist in this
            # graph, because a non-API service composes no `-svc` node at all.
            # That is a DANGLING EDGE in a manifest whose whole contract is that
            # every `depends_on` names a node it is ordered against.
            #
            # A `service_ref` to the shared-infrastructure service that owns the
            # database is the concrete shape — a plausible authoring mistake,
            # since "the thing my service talks to" and "the thing my service
            # reads from" look alike in a bundle. A datastore is reached through
            # the datastore binding, never through an invoke grant.
            if is_sibling and sibling_kind.value != AppKind.APP_KIND_API:
                raise Error(
                    "compose_api: service '"
                    + svc.name
                    + "' has a ServiceRef to sibling '"
                    + target
                    + "', whose kind is "
                    + sibling_kind.json_name()
                    + " — only an APP_KIND_API service composes a served node to"
                    + " invoke. A non-API service has no `-svc` node, so the grant"
                    + " would depend on a node that does not exist (fail-fast)"
                )

            # FAIL-FAST: a non-sibling ref in a MULTI-service bundle is a typo (no
            # dangling intra-bundle ref). A single-service bundle's non-sibling ref
            # is EXTERNAL — allowed (falls through to emit an external grant).
            if not is_sibling and not single_service:
                raise Error(
                    "compose_api: service '"
                    + svc.name
                    + "' has a ServiceRef to unknown service '"
                    + target
                    + "' — not a sibling in this multi-service bundle (an intra-"
                    + "bundle ref must name a sibling; fail-fast)"
                )

            # DEDUPE: one grant per (S, T) pair.
            var dup = False
            for k in range(len(seen)):
                if seen[k] == target:
                    dup = True
                    break
            if dup:
                continue
            seen.append(target.copy())

            # Emit the single (S -> T) invoke grant (unified Grant, INVOKE_SERVICE).
            # The target node id is `<T>-svc` for BOTH cases — the mapper recovers T's
            # SHORT name by stripping `-svc`, and the grant conformer SELF-DERIVES T's
            # Cloud Run resource from (project, region, T), so a name-not-in-graph
            # (external) target needs NO graph node.
            var target_svc = target + String("-svc")
            var deps = List[String]()
            if is_sibling:
                # SIBLING: order the grant AFTER the callee's served node (grant-
                # after-target-exists) — the `<T>-svc` node IS in this graph.
                deps.append(target_svc.copy())
            # EXTERNAL: NO depends_on — T is deployed by its OWN bundle, so there is
            # no `<T>-svc` node here to order against (empty in-edges => topo root).
            nodes.append(
                _grant_node(
                    svc.name + String("-invokes-") + target,  # grant node id
                    _runtime_identity_of(spec, svc.name),  # principal = S's runtime identity
                    target_svc^,  # target = <T>-svc (mapper strips -> T short name)
                    deps^,  # sibling: [<T>-svc]; external: [] (peer in another bundle)
                )
            )


# =============================================================================
# THE JOBS CAPABILITY — `AppBundle.jobs[]` -> one
# RESOURCE_KIND_RUN_TO_COMPLETION_JOB node each, plus the two grants a job
# needs to be able to do anything at all.
#
# WHICH SERVICE-PATH GUARANTEES APPLY TO A JOB, DECIDED FIELD BY FIELD RATHER
#   THAN ASSUMED:
#
#   IMAGE-DIGEST PINNING            — APPLIES, same seam. `_resolve_image_digest`
#     is called on the job's `ImageRef` exactly as on a service's, so a job's
#     image is a pinned sha256 or the `from_build:` marker the pipeline pins
#     later. It is NOT a mutable `:latest` tag — a gate that cannot say which
#     build it ran.
#   REGION FROM THE ENV BINDING     — APPLIES. Compose emits `JobSpec.region`
#     VERBATIM, which is EMPTY unless the author stated one; the mapper resolves
#     empty to the binding's region. Compose has no environment binding and must
#     never invent a region.
#   RUNTIME IDENTITY, FULLY QUALIFIED — APPLIES. The node carries the same
#     identity SYMBOL a service node carries; the mapper resolves it to a full
#     principal email the SAME way it does for a service, so a bare `<x>-role`
#     cannot reach the wire.
#   SECRETS NEVER PLAINTEXT         — APPLIES. Only the HANDLE is composed; the
#     applier renders it as a Secret-Manager `secretKeyRef`. A value never enters
#     the manifest, and never enters a Job spec that `run.jobs.get` will show a
#     reader.
#   THE /healthz STARTUP PROBE AS THE READINESS TRAFFIC GATE — DOES NOT APPLY,
#     and the reason is structural rather than an omission: a Cloud Run Job has
#     no serving port, no revision and no traffic split, so there is no traffic
#     to gate. The equivalent guarantee for a job is that its EXIT CODE is the
#     verdict, which is `ExecuteJob.gate_on = GATE_ON_EXIT_CODE`.
#   NO PUBLIC INGRESS WITHOUT AN AUTHENTICATING CONFIGURATION — DOES NOT APPLY
#     in the inbound direction (a Job has no URL and nothing can call it), but
#     its OUTBOUND twin does and is enforced here: a job that calls a sibling
#     service gets an INVOKE_SERVICE grant, and a job that mounts a secret gets
#     a READ_SECRET grant on THAT NAMED SECRET. Without them the job 403s at
#     run time, which reads exactly like a product failure — these are declared
#     graph state, not one-time manual prerequisites.
#   REVISION RETENTION / `keep_last_n` — DOES NOT APPLY. A Job has executions,
#     not revisions, and nothing here prunes them.

# The logical-id suffix of a composed run-to-completion job node. The mapper
# strips it to recover the authored `JobSpec.name` (the `-svc` precedent).
comptime JOB_NODE_SUFFIX: String = "-job"


def _job_inheritance_refused_on_aws(
    job_name: String, service_name: String, inherited: String
) -> String:
    """STATED AT THE POINT OF FAILURE: a job inside a SERVICE-BEARING bundle
    must author its own `runtime_identity` on `CLOUD_AWS`.

    This function is the message, separated out because the refusal it carries
    will surprise the first author who adds a `jobs {}` block to a bundle that
    already has a service, and a refusal that does not teach is a papercut.

    NON-RAISING (it returns the sentence) so the wording has ONE author."""
    return (
        String("compose_api: job '")
        + job_name
        + String("' declares no `runtime_identity`, so it would INHERIT '")
        + inherited
        + String("' from service '")
        + service_name
        + String(
            "' — and on CLOUD_AWS that is REFUSED.\n"
            "  WHY, AND IT IS A CLOUD ASYMMETRY RATHER THAN A BUG: an AWS IAM"
            " role DECLARES who may assume it, and a role this deploy graph"
            " mints trusts EXACTLY ONE service principal. A service runs as"
            " 'lambda.amazonaws.com' (or 'ecs-tasks.amazonaws.com'); a job is"
            " an ECS task and runs as 'ecs-tasks.amazonaws.com'. ONE role"
            " cannot carry both without being permanently broader than either"
            " use needs — and that breadth would be invisible right here, at"
            " the place it was authored. On GCP the identical bundle composes"
            " fine: a service account has no trust document, so one identity"
            " runs both.\n"
            "  ⇒ THE FIX: give job '"
        )
        + job_name
        + String(
            "' its own `runtime_identity: \"<name>\"` in the bundle. The deploy"
            " graph then MINTS that identity as a SERVICE_ACCOUNT node and its"
            " IAM role trusts 'ecs-tasks.amazonaws.com' alone.\n"
            "  TWO OTHER ANSWERS WERE CONSIDERED AND REJECTED: (a)"
            " INHERITANCE — one role trusting both principals, refused because"
            " every such role is permanently broader than either use needs and"
            " the breadth is invisible at the authoring site; (b) a"
            " composer-DERIVED `<job>-job-role`, refused because it would be"
            " one more name derivation for an operator to learn and for every"
            " tier to agree on. (fail-fast)"
        )
    )


def _job_runtime_identity(
    job: BundleJobSpec, services: List[ServiceSpec], cloud: Int
) raises -> String:
    """The identity a declared job RUNS AS: the AUTHORED `JobSpec.runtime_identity`
    when non-empty, else the FIRST declared service's runtime identity — "the same
    identity the bundle's service resolves to, never a broader one" (the field's
    own contract).

    RAISES when neither exists. A job with no identity would be created with an
    empty `service_account_email`, which Cloud Run silently fills with the
    project's DEFAULT compute service account — an identity that is broader than
    anything this bundle declares and that no grant here scopes. Defaulting to it
    is the failure mode this raise exists to prevent.

    AND ON `CLOUD_AWS` THE INHERITANCE ARM ITSELF RAISES. See
    `_job_inheritance_refused_on_aws`. This is a CLOUD ASYMMETRY and it is
    accepted, not overlooked: on GCP one service account runs a Cloud Run
    service and a Cloud Run job with no trust document in sight, while on AWS an
    IAM role DECLARES who may assume it and a graph-minted one trusts exactly
    one service principal.

    `cloud` IS REQUIRED, NO DEFAULT: a defaulted cloud is a wrong answer that
    compiles — an AWS env composed as GCP reports CONVERGED."""
    if job.runtime_identity.byte_length() > 0:
        return job.runtime_identity.copy()
    for i in range(len(services)):
        if services[i].spec:
            var inherited = _runtime_identity_of(
                services[i].spec.value(), services[i].name
            )
            if cloud == CLOUD_AWS:
                raise Error(
                    _job_inheritance_refused_on_aws(
                        job.name, services[i].name, inherited
                    )
                )
            return inherited^
    raise Error(
        "compose_api: job '"
        + job.name
        + "' declares no `runtime_identity` and this bundle declares no service"
        " to inherit one from — a job with no identity would be created under"
        " the project's DEFAULT compute service account, which is broader than"
        " anything this bundle declares and which no composed grant scopes."
        " State `runtime_identity` on the job (fail-fast)."
    )


def _append_job_nodes(
    bundle: AppBundle,
    services: List[ServiceSpec],
    mut nodes: List[ResourceNode],
    cloud: Int,
) raises:
    """Emit ONE `RESOURCE_KIND_RUN_TO_COMPLETION_JOB` node per `AppBundle.jobs[]`,
    in declaration order, plus the outbound grants each job needs.

    A bundle with NO `jobs { … }` block appends NOTHING — the additive-safety
    property the schema landed with, which this function must not break.

    THE ENV TRANSLATION IS THE POINT OF THE WHOLE CAPABILITY.
      * literal `value`   -> a literal env entry.
      * `service_ref: T`  -> the URL-resolution MARKER `<VAR>__SVCREF -> T`, the
        SAME encoding a service's Config node carries, so a job and a service
        resolve a sibling's URL through ONE mechanism. A hand-rolled
        `describe | grep` derivation yields an EMPTY STRING (not an error) when
        the grepped key is renamed — a job then runs against nothing and exits
        however it likes.
      * `value_from`      -> REFUSED, by name, see below.

    `value_from: VALUE_FROM_DEPLOY_URL` IS REFUSED ON A JOB, DELIBERATELY. On a
    service that arm means "MY OWN converged URL". A job has no URL of its own, so
    there is no answer to give; accepting the arm would silently inject an empty
    string, which is exactly the failure the typed ref exists to remove. The
    cross-service intent has a spelling that IS answerable (`service_ref`) and the
    error names it."""
    if len(bundle.jobs) == 0:
        return
    # The sibling-service name set — the valid `service_ref` target vocabulary.
    var valid = List[String]()
    for i in range(len(services)):
        valid.append(services[i].name.copy())

    for ji in range(len(bundle.jobs)):
        var job = bundle.jobs[ji].copy()
        if job.name.byte_length() == 0:
            raise Error(
                "compose_api: jobs["
                + String(ji)
                + "] has an empty `name` — a job with no name cannot be named by"
                " an `execute_job` step and has no logical id (fail-fast)"
            )
        if not job.image:
            raise Error(
                "compose_api: job '" + job.name + "' has no `image` ref"
            )
        var job_id = job.name + JOB_NODE_SUFFIX
        var image_digest = _resolve_image_digest(job.image.value())
        var runtime_identity = _job_runtime_identity(job, services, cloud)

        # -- env + the sibling targets it references ------------------------
        var env_values = Dict[String, String]()
        var targets = List[String]()  # per-job dedup of service_ref targets
        for ei in range(len(job.env)):
            ref e = job.env[ei]
            if e._oneof0_case == 1:  # literal `value`
                env_values[e.name.copy()] = e.value.value().copy()
            elif e._oneof0_case == 3:  # `service_ref` cross-service
                var target = e.service_ref.value().service.copy()
                var is_sibling = False
                for vi in range(len(valid)):
                    if valid[vi] == target:
                        is_sibling = True
                        break
                if not is_sibling:
                    raise Error(
                        "compose_api: job '"
                        + job.name
                        + "' has a ServiceRef to unknown service '"
                        + target
                        + "' — a job's ref must name a service THIS bundle"
                        " declares, because the invoke grant that makes the call"
                        " work is composed from this same graph (fail-fast)"
                    )
                env_values[
                    e.name.copy() + SVCREF_MARKER_SUFFIX
                ] = target.copy()
                var dup = False
                for k in range(len(targets)):
                    if targets[k] == target:
                        dup = True
                        break
                if not dup:
                    targets.append(target^)
            elif e._oneof0_case == 2:  # `value_from` — refused on a job
                raise Error(
                    "compose_api: job '"
                    + job.name
                    + "' env '"
                    + e.name
                    + "' uses `value_from` — a job has no serving URL of its own,"
                    " so VALUE_FROM_DEPLOY_URL has no value to resolve to and"
                    " would inject an empty string. Name the service with"
                    " `service_ref { service: \"<name>\" }` instead (fail-fast)"
                )

        # -- the NAME-ONLY secret handles (never a value) --------------------
        var secret_handles = List[String]()
        for si in range(len(job.secret_bindings)):
            var h = job.secret_bindings[si].handle.copy()
            if h.byte_length() > 0:
                secret_handles.append(h^)

        # -- the node's in-edges: every sibling service it will call ---------
        var deps = List[String]()
        for ti in range(len(targets)):
            deps.append(targets[ti] + String("-svc"))

        # -- THE JOB'S OWN IDENTITY NODE ---------------------------------------
        #    A job's `runtime_identity` must name a principal SOMETHING IN THE
        #    GRAPH CREATES, and both clouds report a missing one as success:
        #    Cloud Run's `CreateJob` accepts a `serviceAccount` that does not
        #    exist and ECS `RegisterTaskDefinition` accepts a `taskRoleArn` that
        #    does not exist. Neither fails until EXECUTION — the exact
        #    create-clean/fail-late shape every refusal above guards. A job may
        #    be the only compute in a bundle, with no served sibling to inherit
        #    an identity from, so this pass mints one.
        #
        # GATED ON THE **AUTHORED** FIELD (`job.runtime_identity`), NOT ON THE
        #    RESOLVED ONE, AND THE DIFFERENCE IS RESOURCE OWNERSHIP. A job that
        #    INHERITS resolves to a service's identity; when that service did not
        #    itself self-provision (it authored no `runtime_identity` and derived
        #    `<svc>-role`), BOOTSTRAP owns that identity. Minting it here would
        #    make this deploy its creator — and, under the RETENTION_DELETE every
        #    app-owned SA carries, its DELETER on teardown.
        #    `_runtime_identity_of`'s self-provision gate draws the same line for
        #    a service, for the same reason.
        #
        # ONE IDENTITY, ONE NODE. The scan is over `account_id` — the identity
        #   string itself — and not over the logical id, because a service's SA
        #   node is `<svc.name>-role-sa` while its account_id is
        #   `_runtime_identity_of(spec, name)`; those two agree only when the
        #   service authors nothing. Two nodes creating one identity is two
        #   creators and, on teardown, two deleters.
        #
        # RESIDUAL, NAMED RATHER THAN WIDENED: when a SIBLING SERVICE already
        #   composes the identity, this pass adds no `depends_on` edge from the
        #   job to that SA. The edge is added only for the node THIS pass mints.
        #   A job that references a sibling reaches it transitively
        #   (job -> <T>-svc -> <T>-role-sa); a job that references none has no
        #   path. On `CLOUD_AWS` the shared-identity case is refused outright by
        #   `_job_runtime_identity`, so the residual is GCP-only.
        if job.runtime_identity.byte_length() > 0:
            var identity_already_composed = False
            for ni in range(len(nodes)):
                if (
                    nodes[ni].kind.value
                    != ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT
                ):
                    continue
                if not nodes[ni].service_account:
                    continue
                if (
                    nodes[ni].service_account.value().account_id
                    == runtime_identity
                ):
                    identity_already_composed = True
                    break
            if not identity_already_composed:
                var job_sa_id = runtime_identity + String("-sa")
                # A LOGICAL-ID COLLISION IS REFUSED, NOT RESOLVED BY
                #   WHICHEVER APPEND RAN LAST. It is representable: a service
                #   named `svc-a` authoring `runtime_identity: "x-role"`
                #   composes `svc-a-role-sa` for account `x-role`, and a job
                #   authoring `svc-a-role` derives the SAME logical id for a
                #   DIFFERENT account. Two nodes under one id is a graph Kahn's
                #   algorithm cannot order and a `depends_on` that names an
                #   ambiguous target.
                for ni in range(len(nodes)):
                    if nodes[ni].logical_id == job_sa_id:
                        raise Error(
                            "compose_api: job '"
                            + job.name
                            + "' runs as identity '"
                            + runtime_identity
                            + "', whose SERVICE_ACCOUNT node would be '"
                            + job_sa_id
                            + "' — a logical id THIS graph already uses for a"
                            " different node. Two nodes under one id cannot be"
                            " ordered and a `depends_on` naming it is"
                            " ambiguous. Rename the job's `runtime_identity`"
                            " (fail-fast)."
                        )
                nodes.append(
                    _service_account_node(
                        job_sa_id.copy(),
                        runtime_identity.copy(),
                        String("kci ") + job.name + String(" job runtime SA"),
                    )
                )
                # The job RUNS AS the identity this pass just created, so it
                # orders after it. Kahn's algorithm does not fail on a missing
                # edge — it schedules the job whenever, which is a `CreateJob`
                # racing the `CreateServiceAccount` it needs.
                deps.append(job_sa_id^)

        nodes.append(
            _run_to_completion_job_node(
                job_id.copy(),
                deps^,
                image_digest^,
                job.args.copy(),
                runtime_identity.copy(),
                env_values^,
                secret_handles.copy(),
                job.max_retries.copy(),
                job.task_timeout_seconds,
                job.region.copy(),
            )
        )

        # -- OUTBOUND AUTH, part 1: invoke each sibling this job calls -------
        # Without this the job reaches the service and gets a 403 with an empty
        # body — indistinguishable in the log from the service being broken.
        for ti in range(len(targets)):
            var target_svc = targets[ti] + String("-svc")
            var gdeps = List[String]()
            gdeps.append(target_svc.copy())
            nodes.append(
                _grant_node(
                    job_id + String("-invokes-") + targets[ti],
                    runtime_identity.copy(),
                    target_svc^,
                    gdeps^,
                )
            )

        # -- OUTBOUND AUTH, part 2: read each secret this job mounts ---------
        # Resource-scoped to the NAMED secret, never project-wide. Graph ROOT —
        # the secret is provisioned by the service's own node set or seeded out
        # of band, so there is no node here to order against.
        for si in range(len(secret_handles)):
            nodes.append(
                _base_grant_node(
                    job_id + String("-reads-") + secret_handles[si],
                    runtime_identity.copy(),
                    Capability.CAPABILITY_READ_SECRET,
                    secret_handles[si].copy(),
                    List[String](),
                )
            )


def _append_trigger_nodes(
    triggers: List[TriggerSource], mut nodes: List[ResourceNode], pipeline_ref: String
) raises:
    """STANDING-TRIGGER AUTO-EMISSION: emit ONE Trigger node
    per `bundle.triggers` entry, mirroring `_append_grant_nodes`. Each node
    carries the same `pipeline_ref` (== `bundle.name` — the multi-source fan-in: any
    bound trigger firing runs the SAME pipeline). All `RETENTION_DELETE` (app-owned).
    The intent-tier arm is translated arm-for-arm to the standalone tier (the two
    tiers declare the SAME arms in the SAME order — see `TRIGGER_ARM_*`).

    THE LOGICAL_ID IS THE TRIGGER'S NAME. A key that is a function of the git
    payload (`trigger-<source_kind_ord>-<repo_ref>`) cannot survive the open set:
    a SCHEDULE has no source_kind and no repo_ref, so every schedule would key
    to the byte-identical `trigger-0-`, and two schedules on one machine would
    COLLIDE into one node. The id is therefore `trigger-<name>`, keyed on the
    field that exists for every arm and is unique per machine by construction
    (enforced at validate).

    It is a function of AUTHORED IDENTITY, not of the loop index, so inserting or
    removing a trigger mid-list does not churn every other trigger's downstream
    webhook id (the standing manifest's minimal-diff property), and renaming a
    repository does not re-id an otherwise-unchanged binding.

    Any reconciler that derives a trigger's id independently MUST keep it
    byte-identical to this one: a ledger key and the desired-set membership line
    up only if they agree.

    THE WEBHOOK SECRET IS PER-ARM. `webhook_secret_ref` is a deterministic HANDLE
    (the value never rides in the manifest — the SecretSpec discipline) for the two
    arms that have an INBOUND WEBHOOK. A SCHEDULE has no inbound delivery and
    therefore no HMAC secret: minting a handle for one would advertise a secret no
    conformer will ever provision, so the field is left EMPTY.

    A bundle with ZERO triggers appends NOTHING (a pure no-op) — so `compose_triggers`
    yields an EMPTY standing manifest (the one-shot deployment identity)."""
    for ti in range(len(triggers)):
        var t = triggers[ti].copy()
        if t.name.byte_length() == 0:
            raise Error(
                "compose: trigger #"
                + String(ti)
                + " on pipeline '"
                + pipeline_ref
                + "' has an EMPTY `name`. The name is the trigger's node identity"
                " (`trigger-<name>`); an empty one would collide every unnamed"
                " trigger onto a single node."
            )
        # Stable id keyed on the AUTHORED NAME — index-free, arm-independent.
        var logical_id = String("trigger-") + t.name
        var arm = t._oneof0_case
        var git_push: Optional[ResolvedGitPush] = None
        var schedule: Optional[ResolvedSchedule] = None
        var package_published: Optional[ResolvedPackagePublished] = None
        # A webhook secret handle ONLY for the arms with an inbound delivery.
        var webhook_secret_ref = String("")
        if arm == TRIGGER_ARM_GIT_PUSH:
            ref g = t.git_push.value()
            git_push = Optional[ResolvedGitPush](
                ResolvedGitPush(
                    _translate_source_kind(g.source_kind),
                    g.repo_ref.copy(),
                    g.ref_.copy(),
                )
            )
            webhook_secret_ref = logical_id + String("-webhook-secret")
        elif arm == TRIGGER_ARM_SCHEDULE:
            ref s = t.schedule.value()
            schedule = Optional[ResolvedSchedule](
                ResolvedSchedule(s.cron.copy(), s.timezone.copy())
            )
        elif arm == TRIGGER_ARM_PACKAGE_PUBLISHED:
            ref p = t.package_published.value()
            package_published = Optional[ResolvedPackagePublished](
                ResolvedPackagePublished(
                    _translate_registry_kind(p.registry_kind),
                    p.package_ref.copy(),
                    p.version_range.copy(),
                )
            )
            webhook_secret_ref = logical_id + String("-webhook-secret")
        else:
            # An armless trigger names no firing condition. Emitting it would put a
            # node in the standing manifest that no conformer can act on and no
            # reader can interpret — the one-shot/continuous identifier would say
            # CONTINUOUS while nothing can ever fire. Fail fast (UNSPECIFIED
            # semantics), the same discipline `compose()` applies to an unknown kind.
            raise Error(
                "compose: trigger '"
                + t.name
                + "' on pipeline '"
                + pipeline_ref
                + "' sets NO payload arm (TriggerSource.on unset) — it names no"
                " firing condition. Author exactly one of `git_push`, `schedule`,"
                " `package_published`."
            )
        nodes.append(
            _trigger_node(
                logical_id^,
                t.name.copy(),
                arm,
                git_push^,
                schedule^,
                package_published^,
                pipeline_ref.copy(),
                webhook_secret_ref^,
            )
        )


def compose_api(
    bundle: AppBundle,
    env: String,
    supplied_params: Dict[String, String] = Dict[String, String](),
    # ── `cloud` — A DEFAULTED PARAMETER, AND WHAT PAYS FOR THE DEFAULT ─────────
    # A defaulted cloud is a wrong answer that compiles, and a required parameter
    # would be the stronger gate. The default exists because `compose` /
    # `compose_api` have many callers, most of them tests; it is paid for twice,
    # and neither payment is a comment:
    #   (a) THE PRODUCTION APPLY PATH THREADS IT. The deploy driver reads `cloud`
    #       off the env binding and hands the same value to the mapper and to
    #       `compose`, so the arm that materializes and the composer that emits
    #       read ONE field of ONE object.
    #   (b) THE DEFAULT IS FALSIFIED, not assumed: the tests assert that an
    #       omitted `cloud` composes the FULL GCP grant set (so a silently
    #       defaulted AWS deploy is a visible over-composition, never a silent
    #       under-composition) and that `CLOUD_AWS` composes the reduced one.
    # AN OMITTED `cloud` ON AN AWS ENV THEREFORE FAILS **LOUD**: the AWS arm
    # raises on the un-gated grant.
    cloud: Int = CLOUD_GCP,
    # Whether the target environment's definition allows a developer-access
    # principal on a peer-only edge (`Wave.developer_access_principal`). The
    # caller reads it from the environment definition. Defaults to False, so an
    # env that says nothing refuses — see `_wave_developer_access_principal`.
    developer_access_allowed: Bool = False,
) raises -> FullManifest:
    """The `Api` Composition: expand an API intent bundle into a FullManifest for
    `env`. Emits ONE per-service node set
    {IamRole -> Secret -> Config [-> Datastore] -> ServerlessCompute} per
    AUTO-LIFTED service, in service-declaration order — so N named services
    coexist in ONE manifest. A single-service bundle (empty `services`) is
    auto-lifted from the singular fields. Pure + deterministic; `env` is the
    logical symbol only (no binding resolution). Raises on a non-API kind or a
    malformed service spec (fail-fast, UNSPECIFIED semantics).

    CROSS-SERVICE REFERENCES. A `ServiceRef{service: T}` env arm on a service S
    contributes TWO things to the compose output: (1) the OWNING service's Config
    node gains the URL-resolution MARKER `<VAR>__SVCREF -> T` (see
    `SVCREF_MARKER_SUFFIX`), and (2) ONE unified Grant node (INVOKE_SERVICE) is
    auto-emitted per (S, T) pair (`_append_grant_nodes`) so S's runtime identity
    may invoke T. A bundle with NO `service_ref` arm emits neither.

    PER-SERVICE KIND. The loop dispatches on `ServiceSpec.kind`, NOT on the
    bundle's singular kind: `APP_KIND_API` composes the served node set;
    `APP_KIND_SHARED_INFRASTRUCTURE` composes ONE standalone datastore node and
    nothing else, from the same function `compose_shared_infrastructure` calls.
    That is what lets ONE bundle hold several served services and the resource
    owner they share. Every other kind keeps the existing fail-fast."""
    if bundle.kind.value != AppKind.APP_KIND_API:
        raise Error(
            "compose_api: expected AppKind APP_KIND_API, got ordinal "
            + String(bundle.kind.value)
            + " — dispatch a non-API kind through `compose()` (fail-fast)"
        )

    # -- AUTO-LIFT: the authoritative ordered services list (singular fields ->
    #    one service when `services` is empty; else `services` verbatim). -------
    var services = _auto_lifted_services(bundle)

    # -- the selected wave's per-ENV env-var overrides. EMPTY when no wave
    #    matches `env` or the wave authors no override.
    #
    # -- ONE MAP PER SERVICE, POSITIONALLY ALIGNED WITH `services`. One wave
    #    binds one env, but a wave has no service axis, so folding its map onto
    #    every service would leak one service's per-env values (credentials
    #    included) onto every other. `BundleEnvVar.service` is the axis; an
    #    override that names no service is REFUSED when more than one service
    #    would receive it. See `_wave_env_overrides_by_service`. ---------------
    var env_overrides = _wave_env_overrides_by_service(bundle, env, services)

    # -- emit each service's node set, in service-declaration order ------------
    # -- the selected wave's per-ENV PARAMETER overrides (Wave field 5), the
    #    parameter-model twin of `env_override` above. EMPTY ⇒ the spec-level
    #    declaration stands. ----------------------------------------------------
    var param_override = _wave_parameter_override(bundle, env)

    # -- THE IN-BUNDLE DATASTORE OWNER ------------------------------------------
    # Which sibling service, if any, OWNS the database the others borrow. Empty
    # for a single-service bundle or a multi-service bundle with no datastore.
    #
    # Compose READS the field and judges nothing — the same discipline the
    # `datastore_referenced` line states in `_append_api_service_nodes`. The
    # own-XOR-reference policy, the two-owners refusal and the
    # one-database-per-bundle refusal all run BEFORE any compose
    # (`validate_bundle` at authoring time, the deploy seam again before it
    # maps). Re-deciding here would be a third copy of a five-case rule; taking
    # the FIRST owner is therefore not a tie-break, it is a read of a set the
    # refusals have already proven has at most one element.
    #
    # N IDS, NOT ONE. An owner that authors N collections composes N datastore
    # nodes, and a referencer must be ordered after ALL of them — see the
    # `owner_datastore_ids` loop in `_append_api_service_nodes`.
    var owner_datastore_ids = List[String]()
    for i in range(len(services)):
        if not services[i].spec:
            continue
        if services[i].spec.value().datastore_database.byte_length() > 0:
            owner_datastore_ids = _datastore_node_ids_for(
                services[i].name, services[i].spec.value()
            )
            break

    var nodes = List[ResourceNode]()
    # PER-SERVICE KIND DISPATCH. The dispatch is TOTAL — an unhandled kind keeps
    # the existing fail-fast inside `_append_api_service_nodes`, which names the
    # service and its ordinal, rather than being silently composed as something
    # it did not declare.
    #
    # THE VALIDATE-JOB DATASTORE READ GRANT CARRIES ACROSS. It is emitted below,
    # after the service loop, on the SAME predicate and by the SAME function the
    # standalone shared-infrastructure machine uses (see
    # `_append_shared_infra_validator_read_grant`): nothing in the grant's
    # derivation is a function of the bundle kind, and keying it there would
    # drop the authority a resource owner's validate gate needs whenever the
    # owner is a service inside a larger bundle.
    for i in range(len(services)):
        if service_serves_nothing(services[i]):
            # A service that OWNS a resource and SERVES NOTHING: exactly one
            # standalone datastore node, from the same function
            # `compose_shared_infrastructure` calls. Composed AT ITS DECLARED
            # POSITION in the services list, not hoisted — an author who needs
            # the database provisioned before its consumers says so by declaring
            # it first, and a compose that silently reordered would make the
            # authored order mean nothing.
            _append_shared_infra_service_nodes(
                services[i], nodes, String("compose_api")
            )
            continue
        _append_api_service_nodes(
            services[i],
            # THIS SERVICE'S OWN override map, not the wave's whole map.
            env_overrides[i],
            nodes,
            # THE CLOUD — threaded from this function's own parameter, which the
            # deploy driver reads off `EnvBinding.cloud`.
            cloud,
            env,
            param_override,
            # THE SUPPLIED PARAMETER MAP — the deploying caller's opaque
            # name/value pairs, or an operator's `--param NAME=VALUE`. It is the
            # HIGHEST rung of the resolution order, above the per-wave override.
            #
            # REACHABLE ON PURPOSE. Hard-coding an empty map here would make the
            # top rung of the documented resolution order DEAD CODE, and a
            # resolution order with an unreachable first step is a lie in a
            # comment.
            supplied_params,
            # OWNER-BEFORE-REFERENCER: a REFERENCING service's datastore nodes
            # depend_on EVERY one of the OWNER's, so the database is ENSURED
            # before it is probed. EMPTY adds no edge.
            owner_datastore_ids.copy(),
        )

    # -- auto-emit the cross-service invoke grants (one per (S,T) pair), AFTER
    #    every service node set exists so each grant's `depends_on [<T>-svc]`
    #    references an already-emitted callee. Fail-fast on a ref to an unknown
    #    service. ZERO grants when no service has a `service_ref` arm. ----------
    _append_grant_nodes(services, nodes)

    # -- THE SELF-FETCHED-SECRET READ GRANTS: one resource-scoped READ_SECRET
    #    grant for the step's job principal per DISTINCT
    #    `RunContainer.reads_secret` this env's wave declares on a RUNNABLE step.
    #    A wave that declares no `reads_secret` composes none. ------------------
    _append_validate_step_secret_grant_nodes(bundle, env, nodes, cloud)

    # -- THE OBSERVABILITY READ GRANTS: one project-scoped read grant per
    #    DISTINCT (job principal, telemetry plane) this env's wave declares via
    #    `RunContainer.reads_telemetry` on a RUNNABLE step. The same declaration
    #    channel as `reads_secret` directly above. A wave that declares no
    #    `reads_telemetry` composes none. ---------------------------------------
    _append_validate_step_telemetry_grant_nodes(bundle, env, nodes, cloud)

    # -- THE VALIDATE-JOB DATASTORE READ GRANT, FOR THE **SERVICE** FORM.
    #    Emitted IFF this bundle carries a service that owns a resource and
    #    serves nothing, AND this env's wave gates on a runnable container (the
    #    second half is the function's own predicate). SAME function, SAME node
    #    id, SAME capability the standalone shared-infra machine composes —
    #    because the grant follows the RESOURCE OWNER.
    #
    #    An API bundle with no resource-owner service composes none — and so
    #    does a shared-infrastructure BUNDLE here, which reaches the same
    #    function through `compose_shared_infrastructure`.
    var _owns_a_resource = False
    for i in range(len(services)):
        if service_serves_nothing(services[i]):
            _owns_a_resource = True
            break
    if _owns_a_resource:
        _append_shared_infra_validator_read_grant(bundle, env, nodes, cloud)

    # -- THE JOBS CAPABILITY: one RUN_TO_COMPLETION_JOB node per
    #    `AppBundle.jobs[]`, plus the invoke/secret grants each job needs to be
    #    able to do anything. Appended AFTER every service node set so a job's
    #    `depends_on [<T>-svc]` references an already-emitted callee — the same
    #    ordering rule `_append_grant_nodes` follows. A bundle with no `jobs {}`
    #    block appends NOTHING. --------------------------------------------------
    _append_job_nodes(bundle, services, nodes, cloud)

    # -- API-EDGE auto-emission: one CATCH_ALL client edge per
    #    `inbound: CLIENT` service, IFF this env's wave staging toggle is ON
    #    (default OFF). -----------------------------------------------------------
    #    `cloud` IS THREADED because the edge's SIDECAR NODES are NOT
    #    cloud-neutral even though the edge itself is: GCP's gateway backend-auth
    #    SA has no AWS peer, and AWS's CUSTOM REQUEST authorizer Lambda has no GCP
    #    peer. See `_append_api_edge_nodes`.
    _append_api_edge_nodes(
        bundle, services, env, nodes, cloud, developer_access_allowed
    )

    # -- CRON auto-emission: per `bundle.crons[]`, the invoker GRANT then the
    #    SCHEDULED_CALL that depends on it. LAST, so every `depends_on` it emits
    #    references an already-emitted node. A bundle with no `crons {}` emits
    #    ZERO nodes here. NOT gated by a wave toggle: a periodic backstop present
    #    in one env and silently absent in another is an asymmetry nothing would
    #    surface. -----------------------------------------------------------------
    _append_cron_nodes(bundle, services, nodes)

    # -- content-address the pinned desired-state (synth-once) ------------------
    var manifest = FullManifest(env.copy(), String(""), nodes^)
    var addr = content_address(manifest)
    manifest.content_address = addr
    return manifest^


def compose_triggers(bundle: AppBundle) raises -> FullManifest:
    """Compose ONLY the STANDING Trigger nodes of a bundle into a SEPARATE
    content-addressed FullManifest — the STANDING trigger-manifest (a separate
    standing manifest DECOUPLES trigger RETENTION + rollback from the per-env API
    graph; the mapper-skip is the defensive complement).

    NO env param — a trigger binding is env-INDEPENDENT: `pipeline_ref` (== the app
    SYMBOL, `bundle.name`) drives every environment, so the standing manifest is
    synthesized ONCE per app, not once per env (`environment` is left EMPTY). Emits
    one Trigger node per `bundle.triggers` via `_append_trigger_nodes` and pins the
    result with the existing `content_address()`. A ZERO-trigger bundle yields an
    EMPTY manifest (no nodes) — the one-shot deployment identity. Pure + deterministic
    (the same bundle in yields a byte-identical manifest + address out).

    This is a SEPARATE function from `compose_api` — the per-env compose path is
    UNTOUCHED by triggers."""
    var nodes = List[ResourceNode]()
    _append_trigger_nodes(bundle.triggers, nodes, bundle.name)
    var manifest = FullManifest(String(""), String(""), nodes^)
    var addr = content_address(manifest)
    manifest.content_address = addr
    return manifest^


# =============================================================================
# §4 — the total dispatch surface over AppKind. `compose()` routes each kind to
#      its Composition; the non-API kinds that have none are stubs that raise
#      clearly (NOT-YET-IMPLEMENTED) so the surface is TOTAL — an
#      UNSPECIFIED/unknown kind fails fast.
# =============================================================================


def compose(
    bundle: AppBundle,
    env: String,
    cloud: Int = CLOUD_GCP,
    developer_access_allowed: Bool = False,
) raises -> FullManifest:
    """Dispatch a bundle to its kind's Composition (total over AppKind). Raises
    on UNSPECIFIED/unknown (fail-fast), a not-yet-implemented deployable kind, or
    a TYPED BUILD+TEST ARTIFACT kind (desktop/mobile/library — no deploy topology
    yet).

    THE SINGULAR `kind` SELECTS THE COMPOSITION; `ServiceSpec.kind` SELECTS EACH
    SERVICE'S TOPOLOGY. These are different questions and the split is deliberate.
    A MIXED bundle — N served services plus a resource owner — declares
    `kind: APP_KIND_API` (it HAS a served topology), and `compose_api`'s loop then
    composes each service by ITS OWN kind. `APP_KIND_SHARED_INFRASTRUCTURE` at the
    BUNDLE level still means what it always meant: a machine that serves nothing at
    all, whose Composition builds no served nodes and therefore refuses a served
    service inside it.

    `cloud` REACHES TWO COMPOSITIONS, AND THAT IS NOT AN OVERSIGHT.
    `APP_KIND_API` SELF-PROVISIONS a runtime identity, so its node set contains
    capability GRANTS that can be GCP concepts with no AWS peer, and
    `APP_KIND_SHARED_INFRASTRUCTURE` composes the validate-job datastore read
    grant. The other Compositions are forwarded nothing because they emit
    nothing that varies with it — the day one of them composes a grant it takes
    the parameter. See `compose_api`'s `cloud` comment for why the default
    exists and what pays for it.

    `developer_access_allowed` reaches `compose_api` only: it governs the
    peer-only API edge, which no other Composition emits."""
    var k = bundle.kind.value
    if k == AppKind.APP_KIND_API:
        return compose_api(
            bundle,
            env,
            cloud=cloud,
            developer_access_allowed=developer_access_allowed,
        )
    elif k == AppKind.APP_KIND_STATIC_FRONTEND:
        return compose_static_frontend(bundle, env)
    elif k == AppKind.APP_KIND_DATA_PIPELINE:
        return compose_data_pipeline(bundle, env)
    elif k == AppKind.APP_KIND_SEARCH_CLUSTER:
        return compose_search_cluster(bundle, env)
    elif k == AppKind.APP_KIND_SHARED_INFRASTRUCTURE:
        return compose_shared_infrastructure(bundle, env, cloud=cloud)
    elif (
        k == AppKind.APP_KIND_DESKTOP_APPLICATION
        or k == AppKind.APP_KIND_MOBILE_APPLICATION
        or k == AppKind.APP_KIND_LIBRARY
    ):
        # A desktop/mobile/library artifact is a BUILD+TEST target that the
        # device-farm matrix fans over — NOT a deployable-service
        # topology. There is NO Composition that maps it to a served-node graph,
        # so fail-closed with a clear diagnostic rather than misrouting it into a
        # service topology (an EXPLICIT arm, not the UNSPECIFIED/unknown catch-all).
        raise Error(
            "compose: AppKind "
            + bundle.kind.json_name()
            + " (ordinal "
            + String(k)
            + ") is a BUILD+TEST artifact (device-farm matrix), not a"
            + " deployable-service topology — it has no deploy Composition"
        )
    raise Error(
        "compose: AppKind UNSPECIFIED/unknown (ordinal "
        + String(k)
        + ") — a bundle MUST declare a concrete kind (fail-fast)"
    )


def compose_shared_infrastructure(
    bundle: AppBundle, env: String, cloud: Int = CLOUD_GCP
) raises -> FullManifest:
    """THE SHARED-INFRASTRUCTURE COMPOSITION — a release machine that OWNS
    resources and SERVES NOTHING.

    ONE node: the DATASTORE. No IamRole, no Secret, no Config, no ServerlessCompute.

    WHY IT IS THIS SMALL, DELIBERATELY. Every other node in the API composition
    exists to serve or to support a served container: the runtime SA and its role,
    the secret bundle it mounts, the env config it boots with. A machine that serves
    nothing needs none of them, and composing them anyway would provision an
    identity, a secret handle and a config object that nothing ever reads — resources
    that can fail a deploy and cannot fail a test. The whole reason this is a KIND
    rather than an `APP_KIND_API` with no routes is to be able to say that.

    THE NODE IS STANDALONE — no owning service — which is why the mapper must be
    called with `require_serverless=False` for this kind. That is the carve-out
    the bootstrap manifest uses for its standalone DATASTORE node, and the graph
    builder derives it from the authored kind (the STATIC_FRONTEND precedent)
    rather than from a caller remembering.

    OWNERSHIP: `referenced=False`, always. A shared-infrastructure machine that
    REFERENCED its own resource would own nothing, which would leave its
    consumers exactly where they started — N claimants and no owner.

    `cloud` REACHES EXACTLY ONE NODE HERE — the validate-job datastore READ
    grant, whose principal is the deploy principal and which is therefore
    subject to `_validator_runs_as_the_deploy_principal_on_cloud`. It is
    DEFAULTED to `CLOUD_GCP` for the same reason `compose`'s is; `compose`
    threads its own value through."""
    if not bundle.spec:
        raise Error(
            "compose_shared_infrastructure: bundle has no `spec` (a shared-"
            "infrastructure machine must declare the resources it owns)"
        )
    # The node itself comes from `_append_shared_infra_service_nodes` — the SAME
    # function `compose_api`'s per-service dispatch calls — over the AUTO-LIFTED
    # one-element services list. The auto-lift is what makes "a bundle whose kind
    # is SHARED_INFRASTRUCTURE" and "a shared-infra SERVICE in a multi-service
    # bundle" the same case: `<name>-datastore`, standalone, owner-not-referencer.
    var services = _auto_lifted_services(bundle)
    var nodes = List[ResourceNode]()
    for i in range(len(services)):
        # THE PER-SERVICE KIND IS CHECKED HERE TOO, and it refuses more than the
        # API loop does. This Composition builds NO served nodes at all, so an
        # `APP_KIND_API` service authored inside a SHARED_INFRASTRUCTURE bundle
        # would compose to a datastore and silently never be served. A mixed
        # would compose to a datastore and silently never be served. A mixed
        # bundle declares `kind: APP_KIND_API` at the top and goes through
        # `compose_api`, whose loop composes BOTH kinds.
        if services[i].kind.value != AppKind.APP_KIND_SHARED_INFRASTRUCTURE:
            raise Error(
                "compose_shared_infrastructure: service '"
                + services[i].name
                + "' declares kind "
                + services[i].kind.json_name()
                + " inside a SHARED_INFRASTRUCTURE bundle, which composes no served"
                + " nodes — that service would provision nothing and be reachable by"
                + " nobody. Declare the BUNDLE as APP_KIND_API and let the"
                + " per-service dispatch compose each kind (fail-fast)"
            )
        _append_shared_infra_service_nodes(
            services[i], nodes, String("compose_shared_infrastructure")
        )
    _append_shared_infra_validator_read_grant(bundle, env, nodes, cloud)
    return FullManifest(env.copy(), String(""), nodes^)


def _append_shared_infra_validator_read_grant(
    bundle: AppBundle,
    env: String,
    mut nodes: List[ResourceNode],
    # REQUIRED, NOT DEFAULTED — see `_append_validate_step_secret_grant_nodes`.
    cloud: Int,
) raises:
    """THE VALIDATE-JOB DATASTORE READ GRANT.

    A validate gate that inspects a resource owner's datastore (its database,
    its composite indexes, a document read) runs as the deploy principal, whose
    standing roles grant NOTHING on the datastore — so every call the probe
    makes is refused. A two-valued probe renders the refusals as ABSENCE; a
    three-valued one reports UNREADABLE, which makes the report honest and still
    leaves the gate unable to observe its subject. THIS node is the other half:
    the authority the observation needs, COMPOSED onto the deploy graph so a
    rebuild reproduces it. A hand binding would produce a green that the next
    fresh environment does not have.

    ── THE CAPABILITY IS DERIVED FROM WHAT THE PROBE CALLS ─────────────────────
    A datastore probe needs exactly THREE verbs:

        get_database()       GET databases/<db>                 -> `datastore.databases.getMetadata`
        list_indexes()       GET .../collectionGroups/-/indexes  -> `datastore.indexes.list`
        list_documents(c)    GET .../documents/<c>?pageSize=1    -> `datastore.entities.list`

    `roles/datastore.indexAdmin` — the intuitive answer — is INSUFFICIENT: it
    carries NO `datastore.entities.*`, so a document-plane read stays blinded,
    and an admin plane that answers proves nothing about a data plane that does
    not. `roles/datastore.user` covers all three and adds write.
    `roles/datastore.viewer` covers all three and stops — so ONE grant of
    `CAPABILITY_DATASTORE_READ`, not two, and not a writer.

    ── SCOPE, AND WHY EACH NARROWING IS THE ONE IT IS ──────────────────────────
      * GATED ON THE WAVE PLACING A JOB (`_wave_gates_on_a_container`). A wave
        with no runnable `run_container` step places no cloud job, so there is no
        in-cloud identity to authorize and the grant would buy nothing. An
        `excluded_because` step is contracted out of the run and must not buy a
        standing privilege either — that predicate already enforces it.
      * READ-ONLY, matching the seam. The probe is read-only BY CONSTRUCTION
        (there is no write verb to call), and its grant should be able to say the
        same thing.
      * PROJECT-SCOPED BY OMISSION, NOT BY STRUCTURE. `projects/<P>` is the only
        BINDING POINT a datastore role has, but not the only SCOPE — a datastore
        binding can be narrowed to one database by an IAM CONDITION
        (`resource.type == "firestore.googleapis.com/Database" && resource.name
        == "projects/<P>/databases/<D>"`). For THIS node the practical
        difference is small — the principal is the deploy principal and the
        probe is read-only.
      * NOT gated on `self_provision`. This kind provisions no runtime SA at all;
        the principal is the deploy principal, which bootstrap creates in every
        env.

    A GRAPH ROOT (empty `depends_on`): BOTH ends are external to this graph.
    `kci bootstrap` creates the deploy SA, and the binding target is the project
    itself. A `depends_on` on the datastore node would be WRONG in the
    load-bearing direction — the grant must converge whether or not the database
    ensure did, or a first-contact failure hides its own diagnosis.

    ── AND WHY THE **SERVICE** FORM GETS IT TOO ────────────────────────────────
    `compose_api` calls this function as well, IFF the bundle carries a service
    that owns a resource and serves nothing:

      (1) NOTHING IN THE DERIVATION IS A FUNCTION OF THE BUNDLE KIND. The role is
          derived from what the probe CALLS (three read verbs) and the principal
          is the deploy principal, which bootstrap creates in every environment.
          The bundle kind is only the PATH by which this function is reached —
          never a premise of it.
      (2) IT ADDS NO PRIVILEGE CLASS. `roles/datastore.viewer` for the deploy
          principal, project-scoped, is the identical node the standalone
          shared-infrastructure machine composes — same id, same capability, same
          principal. It is the SAME authority, kept attached to the resource
          owner as the owner moves from a bundle into a service.
      (3) THE ALTERNATIVE IS A CONTROL THAT CONSOLIDATION SILENTLY REMOVES. A
          grant keyed on the bundle kind means the same machine, authored the
          same way, LOSES its validate gate's read authority purely because it
          was merged into a larger deploy unit.
      (4) THE BOUNDED-AND-LOUD ARGUMENT CUTS THE OTHER WAY ON A GATE. A
          three-valued probe means a missing grant reports UNREADABLE rather than
          a false ABSENT — which makes the REPORT honest and still leaves the
          gate unable to observe its subject. "Fails visibly" is not a reason to
          ship a gate that cannot see.

    ONE NODE PER GRAPH, keyed on `bundle.name` — the binding is PROJECT-scoped
    and the principal is fixed, so two resource-owner services would compose the
    same binding twice under one id. `compose_api` therefore calls this once, on
    presence, not once per owner.

    THE DEFAULT IS NO NODE. A SHARED_INFRASTRUCTURE bundle whose wave declares
    no container gate composes none; an API bundle with NO resource-owner
    service composes none; and `compose_static_frontend`,
    `compose_data_pipeline` and `compose_search_cluster` never reach here."""
    # NOT ON `CLOUD_AWS` — the same premise, the same predicate. See
    # `_validator_runs_as_the_deploy_principal_on_cloud`.
    if not _validator_runs_as_the_deploy_principal_on_cloud(cloud):
        return
    if not _wave_gates_on_a_container(bundle, env):
        return
    nodes.append(
        _base_grant_node(
            bundle.name + String("-validator-datastore-read-grant"),
            DEPLOY_PRINCIPAL,  # deploy principal (mapper -> full email)
            Capability.CAPABILITY_DATASTORE_READ,  # roles/datastore.viewer
            String(""),  # PROJECT-scoped -> `projects/<P>`
            List[String](),  # graph ROOT — both ends are external
            # RETAIN_KEEP — and this one is the SHARPEST case, because the node
            # ID hides the sharing. The id is keyed on `bundle.name`, so two
            # bundles emit two DIFFERENT ids; the BINDING they produce is the
            # same single `(projects/<P>, deploy principal, roles/datastore.viewer)`
            # triple. Deleting either app unbinds it for both, and the id
            # difference means nothing in the graph could ever have noticed.
            Retention.RETENTION_RETAIN_KEEP,
        )
    )


# The runtime-config keys projected from a STATIC_FRONTEND bundle's `spec.env`
# into the WebFrontend node's `runtime_config`. The env-neutral SPA build
# carries NO per-env values; each env's bundle authors its client-side
# identifiers, which the conformer stamps into the per-env `config.json`. Every
# OTHER env entry (build flags, mock switches) stays out of config.json.
#
# WHICH KEYS ARE PUBLIC IS THE BUNDLE'S DECLARATION (`AppSpec.web_runtime_config_
# keys`), never a list in this composer: the projected document is fetched by
# the BROWSER, so membership in that list is what makes a key public. An EXPLICIT
# set, not a prefix, so a stray key cannot project into `config.json`
# unannounced. Empty means nothing is projected: a pure static frontend.


def _declared_web_runtime_config_keys(bundle: AppBundle) -> List[String]:
    """The runtime-config keys this bundle DECLARES public
    (`AppSpec.web_runtime_config_keys`).

    The schema this package builds against does not carry that field yet, so no
    key is declared and nothing is projected: a static frontend composes with an
    EMPTY runtime config until the field lands. This is the one function that
    changes when it does."""
    return List[String]()


def _is_web_runtime_config_key(name: String, declared: List[String]) -> Bool:
    """True iff `name` is one of the bundle's DECLARED public runtime-config keys.
    An EXPLICIT membership test: no key can project without being declared."""
    for i in range(len(declared)):
        if name == declared[i]:
            return True
    return False


def _project_web_runtime_config(
    bundle: AppBundle, env: String
) raises -> List[WebRuntimeConfigEntry]:
    """Project the bundle's `spec.env` LITERAL entries whose names the bundle
    DECLARES public (`_declared_web_runtime_config_keys`) into the WebFrontend
    node's `runtime_config`, with THIS ENV'S WAVE OVERRIDES APPLIED. Only
    literal-value arms are projected (the runtime config is per-env client
    identifiers, never a typed wave/service reference); order is the authored
    SPEC order (stable + diffable). A bundle with no spec / no declared keys
    yields an EMPTY list.

    THE `env` ARGUMENT IS WHY `Wave.web_override` CARRIES NO RUNTIME CONFIG.
    Under one front-door bundle with two waves the per-env client identifiers
    diverge, and the obvious move is to put them on the front-door override
    beside the slug and the domain. Rejected: `Wave.env_override` (field 4)
    ALREADY exists and is ALREADY the precedent for exactly this sentence — the
    spec-level `env {}` holds the env-NEUTRAL default, the wave supplies the
    env-correct value. Putting them on `web_override` would create a SECOND
    runtime-config override channel whose applicability depends on the bundle's
    KIND — two ways to override one env var, selected by something the author is
    not thinking about. So this function learns the env instead, and every other
    bundle kind keeps the one channel it already has.

    OVERRIDE SEMANTICS ARE `env_override`'s OWN, NOT A SECOND SET: an entry
    REPLACES the spec-level entry of the SAME NAME (literal arm only — a
    `value_from` / `service_ref` override is ignored, because a runtime config
    stamped into a public `config.json` may not carry a resolved reference), and
    an override naming a key the spec does NOT declare is IGNORED rather than
    appended. The second half is deliberate: this list is projected into a
    document the BROWSER fetches, and the declared-key membership test is what
    holds that document to the identifiers the bundle declared public. A wave
    that could INTRODUCE a key would be a wave that could publish one.

    AND A PER-ENV VALUE MAY NEVER RIDE `import.meta.env`. That is baked at
    BUILD time, so two envs' worth means two digests — and the evidence that a
    promoted artifact is the one an earlier env validated is DIGEST IDENTITY.
    The `config.json` stamped at PUBLISH is the only correct channel."""
    var out = List[WebRuntimeConfigEntry]()
    if not bundle.spec:
        return out^
    var declared = _declared_web_runtime_config_keys(bundle)
    ref sp = bundle.spec.value()
    for i in range(len(sp.env)):
        if sp.env[i]._oneof0_case != 1:  # only the literal `value` arm
            continue
        if not _is_web_runtime_config_key(sp.env[i].name, declared):
            continue
        var value = sp.env[i].value.value().copy()
        # THIS ENV'S WAVE, AND NO OTHER. `compose_static_frontend` is called with
        # one env, so one env's compose can never read another's override — the
        # same property `_wave_peer_identity_issuer` relies on, for the same
        # reason.
        for wi in range(len(bundle.waves)):
            if bundle.waves[wi].env != env:
                continue
            ref w = bundle.waves[wi]
            for oi in range(len(w.env_override)):
                if w.env_override[oi].name != sp.env[i].name:
                    continue
                if w.env_override[oi]._oneof0_case != 1:
                    continue  # literal arm only — see the docstring
                var v2 = w.env_override[oi].value.value().copy()
                value = v2^
        out.append(WebRuntimeConfigEntry(sp.env[i].name.copy(), value^))
    return out^


def validate_web_route_table(rules: List[FMWebRouteRule]) raises:
    """FAIL-FAST the authored url-map route table BEFORE it can compose into a
    manifest. This is where a NEGATIVE route gets its first tooth: a bundle that
    both DENIES a path and ROUTES it cannot compose at all, so a containment
    cannot be re-opened by an edit that merely looks additive.

    The three STRUCTURAL rejections, each with the failure it prevents:
      1. DENY with an empty `deny_reason` — an unexplained containment is one the
         next engineer deletes as dead config. The reason travels WITH the rule.
      2. DEFAULT carrying `paths` — the default arm matches nothing explicitly;
         authored paths there would silently do nothing.
      3. more than one DEFAULT — a pathMatcher has exactly one default arm, so a
         second rule would silently win or lose depending on order.
    The FOURTH rejection — a ROUTE path COVERED by a DENY path, THE containment
    The FOURTH rejection — a ROUTE path COVERED by a DENY path, THE containment
    guard — deliberately lives in the mapper
    (`assert_no_route_reopens_a_denied_path`), NOT here. Path COVERAGE is url-map
    match semantics owned by the routing seam, and this compose tier must not
    depend on a vendor bridge. Keeping ONE definition of coverage matters more
    than catching it one layer earlier: the mapper still runs before ANY cloud
    mutation on every plan/deploy, and the conformer's drift check uses that
    same predicate — two copies could disagree, which is exactly how a
    containment silently stops containing.

    Pure + deterministic (no I/O); every error names the offending rule so the
    failure is self-correctable without reading this code."""
    var default_count = 0
    for i in range(len(rules)):
        ref r = rules[i]
        var d = r.disposition.value
        if d == FMWebRouteDisposition.WEB_ROUTE_DISPOSITION_DENY:
            if r.deny_reason.byte_length() == 0:
                raise Error(
                    String(
                        "compose_static_frontend: a DENY route rule (paths"
                        " starting '"
                    )
                    + (r.paths[0] if len(r.paths) > 0 else String("<none>"))
                    + String(
                        "') carries an EMPTY `deny_reason`. A negative route is a"
                        " security containment; state WHY it exists so it is not"
                        " deleted as dead config (self-correctable: add"
                        " `deny_reason: \"…\"`)."
                    )
                )
        elif d == FMWebRouteDisposition.WEB_ROUTE_DISPOSITION_DEFAULT:
            default_count += 1
            if len(r.paths) > 0:
                raise Error(
                    String(
                        "compose_static_frontend: a DEFAULT route rule must carry"
                        " NO `paths` (it configures the pathMatcher DEFAULT arm,"
                        " not a path rule) — got '"
                    )
                    + r.paths[0]
                    + String("'.")
                )
            if default_count > 1:
                raise Error(
                    String(
                        "compose_static_frontend: more than one DEFAULT route rule"
                        " — a pathMatcher has exactly ONE default arm."
                    )
                )


def _web_frontend_node(
    var logical_id: String,
    var depends_on: List[String],
    var web_slug: String,
    var domain: String,
    var additional_domains: List[String],
    var content_bucket: String,
    var spa_fallback_document: String,
    var api_path_prefixes: List[String],
    var api_service_logical_id: String,
    cdn_enabled: Bool,
    var content_digest: String,
    var runtime_config: List[WebRuntimeConfigEntry],
    var route_rules: List[FMWebRouteRule],
) raises -> ResourceNode:
    """The WebFrontend node (config oneof arm 18) — the static-website FRONT DOOR
    composite (a content bucket + a CDN-fronted backend + a global external HTTPS
    LB). RETENTION_RETAIN_KEEP: a front door is STANDING per-env infra (a
    stray `destroy` must not nuke the domain + cert + content). The ~9 vendor L7
    primitives are self-derived from `web_slug` INSIDE the conformer (the
    byte-identical-naming ADOPT discipline). Vendor-neutral: NO vendor primitive
    name rides on this node.

    THAT WIRE VALUE IS NOT WHAT GOVERNS THE TEARDOWN, AND IT CANNOT BE. The
    proto `Retention` enum carries only the two POLICY members on purpose (a
    capability is DERIVED by the conformer that owns the delete verb, so a
    manifest must not be able to disable a teardown from a text file), and
    the node factory takes no retention argument, so this value never reaches
    the conformer. What the engine reads at destroy time is the conformer's own
    retention, RETAIN_UNDELETABLE: the node fans out ~9 L7 primitives and
    encodes no teardown order for them, so the engine skips it under EVERY flag
    — `--delete-data` included — and NAMES it in the teardown's undeletable
    report."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_WEB_FRONTEND),
        depends_on^,
        Retention(Retention.RETENTION_RETAIN_KEEP),
        18,
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 1-17
        Optional[WebFrontendSpec](
            WebFrontendSpec(
                web_slug^,
                domain^,
                additional_domains^,
                content_bucket^,
                spa_fallback_document^,
                api_path_prefixes^,
                api_service_logical_id^,
                cdn_enabled,
                content_digest^,
                runtime_config^,
                route_rules^,  # field 11 — the FULL url-map route table
                String(""),  # field 12 content_store: stamped by the pass that pins content_digest, never at compose
            )
        ),  # arm 18 (web_frontend)
        None,  # arm 19 (api_edge left unset)
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def static_frontend_web_slug(bundle: AppBundle, env: String) -> String:
    """The `web_slug` `compose_static_frontend(bundle, env)` gives the WebFrontend
    node — and so the `staged-content/<web_slug>` key DEPLOY resolves for `env`.
    `kci stage` records a web-content artifact under this key, so the two MUST
    agree for every env.

    THE `env` ARGUMENT IS THE POINT. A slug derived from
    `spec.web_slug ?? bundle.name` alone ignores `Wave.web_override`: the stage
    side would record one key while the deploy of either wave read its
    override's slug. The agreement is pinned by
    `test_the_stage_slug_is_the_slug_compose_gives_each_wave`.

    The compose body below CALLS this — one derivation, not a mirror of one:
    THIS env's wave override, when one is authored, is TOTAL and its slug is
    taken as-is (`validate_bundle` refuses an empty one); otherwise
    `spec.web_slug`, else `bundle.name`."""
    var override_slug = String("")
    var have_override = False
    for wi in range(len(bundle.waves)):
        if bundle.waves[wi].env != env:
            continue
        if not bundle.waves[wi].web_override:
            continue
        have_override = True
        override_slug = bundle.waves[wi].web_override.value().web_slug.copy()
    if have_override:
        return override_slug^
    if bundle.spec:
        ref sp = bundle.spec.value()
        if sp.web_slug.byte_length() > 0:
            return sp.web_slug.copy()
    return bundle.name.copy()


def compose_static_frontend(bundle: AppBundle, env: String) raises -> FullManifest:
    """STATIC_FRONTEND Composition — the static-website front door (a `WebFrontend`
    node reconciled by the cloud's web-frontend conformer). Emits ONE `RESOURCE_KIND_WEB_FRONTEND`
    node whose `web_slug` == `bundle.name` (the stable name-prefix DECOUPLED from
    the domain — the cutover-safety lever). The ~9 vendor L7 primitives are
    self-derived from the slug INSIDE the conformer.

    AUTHORED INTENT (AppSpec fields 13-17) + defaults:
      * web_slug            = spec.web_slug, or bundle.name when unset (the ADOPT
                              lever; slug="site-a" adopts an existing front door
                              named for it, a new slug stands up a PARALLEL one).
      * domain / additional_domains = spec.web_domain / web_additional_domains
                              (the managed-cert + host set; DNS stays MANUAL —
                              no DNS_RECORD node).
      * api_path_prefixes / api_service_logical_id = spec.web_api_path_prefixes /
                              web_api_service_logical_id (the url-map api routes +
                              the NEG's served target; both empty = a PURE static
                              frontend).
      * content_bucket      = EMPTY (the conformer derives `<project>-web-static`).
      * spa_fallback_document = "/index.html" (the SPA deep-link 404->200 default).
      * cdn_enabled         = True (content-hash freshness).
      * content_digest      = the bundle image ref (the SPA content — carried for
                              freshness/audit; the SPA BUILD+UPLOAD is a PIPELINE
                              stage, not a conformer verb).
    A graph ROOT (no `depends_on`): the front door is standing per-env infra (the
    api service it fronts lives in its OWN bundle — addressing is self-derived, no
    intra-graph edge exists to order on). Pure + deterministic (the same bundle+env
    in yields a byte-identical manifest)."""
    # ONE slug derivation: `stage` keys `staged-content/<slug>` on the same
    # function, so the record key and this node cannot drift apart.
    var web_slug = static_frontend_web_slug(bundle, env)
    var domain = String("")
    var additional_domains = List[String]()
    var api_path_prefixes = List[String]()
    var api_service_logical_id = String("")
    # The FULL url-map route table — projected 1:1 from AppSpec.web_route_rules
    # into the full_manifest WebRouteRule shape. Empty => the
    # `web_api_path_prefixes` expansion.
    var route_rules = List[FMWebRouteRule]()

    # THE PER-WAVE FRONT DOOR (`Wave.web_override`, field 8). THIS ENV'S WAVE,
    # AND NO OTHER — the loop matches on `env`, so one env's compose cannot read
    # another env's front door.
    #
    # THE OVERRIDE IS **TOTAL**: when a wave authors one, the whole topology
    # comes from it and the spec branch below is NOT taken. It is not a
    # field-by-field merge, because a merge CANNOT EXPRESS ABSENT — an empty
    # `web_route_rules` would read as *inherit*, and one env's table is not
    # another's with blanks, it may be a SHORTER TABLE (without a DENY the other
    # carries, say). `validate_bundle` refuses the two shapes that would make this
    # branch ambiguous — a spec that also authors topology, and a wave left
    # without an override while a sibling has one — so by the time compose runs,
    # exactly one of these two branches is correct and the other is unauthored.
    var have_override = False
    for wi in range(len(bundle.waves)):
        if bundle.waves[wi].env != env:
            continue
        if not bundle.waves[wi].web_override:
            continue
        ref o = bundle.waves[wi].web_override.value()
        have_override = True
        domain = o.web_domain.copy()
        additional_domains = o.web_additional_domains.copy()
        api_path_prefixes = o.web_api_path_prefixes.copy()
        api_service_logical_id = o.web_api_service_logical_id.copy()
        for ri in range(len(o.web_route_rules)):
            ref ar = o.web_route_rules[ri]
            var opaths = List[String]()
            for pi in range(len(ar.paths)):
                opaths.append(ar.paths[pi].copy())
            route_rules.append(
                FMWebRouteRule(
                    opaths^,
                    ar.backend_role.copy(),
                    ar.error_404_path.copy(),
                    ar.error_404_code,
                    FMWebRouteDisposition(ar.disposition.value),
                    ar.deny_reason.copy(),
                )
            )
    if have_override:
        # THE `bundle.name` FALLBACK IS NOT INHERITED HERE, AND THAT IS THE
        # POINT. On the spec path an empty slug means "derive `bundle.name`",
        # which is safe with one front door per bundle and is a CROSS-ENVIRONMENT
        # COLLISION with two — both waves would derive the same slug and one
        # env's L7 primitives would be stood up against the other env's project.
        # `validate_bundle` refuses an empty slug on an override, so this
        # assignment is unconditional by construction; keeping it unconditional is
        # what makes the refusal load-bearing rather than decorative. The slug
        # itself comes from `static_frontend_web_slug` (above), which takes the
        # override's slug as-is for exactly this reason.
        pass
    elif bundle.spec:
        ref sp = bundle.spec.value()
        domain = sp.web_domain.copy()
        additional_domains = sp.web_additional_domains.copy()
        api_path_prefixes = sp.web_api_path_prefixes.copy()
        api_service_logical_id = sp.web_api_service_logical_id.copy()
        for ri in range(len(sp.web_route_rules)):
            ref ar = sp.web_route_rules[ri]
            var paths = List[String]()
            for pi in range(len(ar.paths)):
                paths.append(ar.paths[pi].copy())
            route_rules.append(
                FMWebRouteRule(
                    paths^,
                    ar.backend_role.copy(),
                    ar.error_404_path.copy(),
                    ar.error_404_code,
                    # The DISPOSITION + its reason ride 1:1 into the manifest, so
                    # the synthesized graph carries the front door's FULL posture
                    # (what is routed, what must NOT be, and the default arm) —
                    # not just its positive routes.
                    FMWebRouteDisposition(ar.disposition.value),
                    ar.deny_reason.copy(),
                )
            )
    # FAIL-FAST before the manifest exists: an unexplained deny, a malformed
    # DEFAULT arm, or a ROUTE that re-opens a DENIED path is a HARD compose error
    # (see `validate_web_route_table`). This is what makes a negative route
    # permanent rather than merely un-authored.
    validate_web_route_table(route_rules)
    var node_id = web_slug + String("-web-frontend")

    # The SPA content digest (verbatim digest or the from_build carry-through
    # marker) — empty when the bundle declares no image.
    var content_digest = String("")
    if bundle.spec and bundle.spec.value().image:
        content_digest = _resolve_image_digest(bundle.spec.value().image.value())

    # The per-env runtime config projected from the bundle's declared public keys
    # in spec.env — the conformer stamps it into the env's config.json. Empty
    # when nothing is declared.
    var runtime_config = _project_web_runtime_config(bundle, env)

    var nodes = List[ResourceNode]()
    nodes.append(
        _web_frontend_node(
            node_id,
            List[String](),  # graph ROOT — standing per-env infra
            web_slug,
            domain^,
            additional_domains^,
            String(""),  # content_bucket -> conformer derives <project>-web-static
            String("/index.html"),  # spa_fallback_document (404->200)
            api_path_prefixes^,
            api_service_logical_id^,
            True,  # cdn_enabled
            content_digest^,
            runtime_config^,
            route_rules^,
        )
    )
    var manifest = FullManifest(env.copy(), String(""), nodes^)
    var addr = content_address(manifest)
    manifest.content_address = addr
    return manifest^


def compose_data_pipeline(bundle: AppBundle, env: String) raises -> FullManifest:
    """DATA_PIPELINE Composition — not yet implemented."""
    raise Error(
        "compose_data_pipeline: DATA_PIPELINE Composition not yet implemented"
    )


def compose_search_cluster(bundle: AppBundle, env: String) raises -> FullManifest:
    """SEARCH_CLUSTER Composition — not yet implemented (composes to a ~5-node
    graph: index queue + object store + compute + load balancer + DNS)."""
    raise Error(
        "compose_search_cluster: SEARCH_CLUSTER Composition not yet implemented"
    )
