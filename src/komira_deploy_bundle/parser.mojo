# =============================================================================
# komira_deploy_bundle/parser.mojo — textproto -> the GENERATED AppBundle.
# =============================================================================
#
# The bounded recursive-descent parser for the AppBundle authoring surface.
# It parses the CLOSED textproto grammar
# — message blocks `{}`, `field: scalar`, repeated `field { }`, enums by their
# FULL proto value name, oneof arms, `#` comments — DIRECTLY into the generated
# `komira_rpc_bundle.app_bundle.AppBundle` struct ("parse to the
# GENERATED struct, not a parallel model"). There is no intermediate AST: each
# `_parse_<Message>` returns the generated struct, assembled from mutable local
# accumulators (the generated constructors are positional with oneof-case ints).
#
# ENUM SPELLING — friendly input, canonical output. The CANONICAL
# spelling is the FULL, fully-prefixed proto value name (`kind: APP_KIND_API`,
# `value_from: VALUE_FROM_DEPLOY_URL`, `gate_on: GATE_ON_EXIT_CODE`) and EMISSION is always canonical-full (emit / scaffold / patch). But on
# INPUT the parser ALSO accepts the SHORT token (`kind: API`)
# whenever it is an UNAMBIGUOUS suffix of exactly one declared value in that
# field's enum — the LLM-writability tenet. Resolution: an exact full-name match
# wins; else the unique `_<TOKEN>` suffix match; 0 matches -> a positioned `did
# you mean`; >1 -> a positioned ambiguity error. See `_match_enum` /
# `resolve_enum_token` (the latter reused by the patcher's `patch_set_enum`).
#
# ONEOF ARMS. `ImageRef.source` (digest | from_build), `BundleEnvVar.val` (value |
# value_from), and `ValidateStep.check` (http_check | run_container) are oneofs.
# Setting two DIFFERENT arms of one oneof is a precise parse error at the second
# arm's position; the generated `_oneof0_case` is the 1-based ARM INDEX (position
# in the oneof), NOT the field number.
#
# ENCAPSULATION: a value-typed `Cursor` over `List[Token]`; every parse fn takes
# `mut cur`. No UnsafePointer, no wildcard origin. Mojo 1.0.0b2.
# =============================================================================

from komira_rpc_bundle.app_bundle import (
    ParamType,
    ParamMarker,
    AppParameter,
    AppBundle,
    AppKind,
    # ★ WHOSE CLOUD ACCOUNT THIS WORKLOAD RUNS IN (`AppBundle.tenancy`, field
    # 15). A SECOND axis, orthogonal to `AppKind` (the topology) — see the enum's
    # own comment for why collapsing the two is a trust-boundary defect.
    Tenancy,
    BuildTarget,
    OutputFormat,
    ImageRef,
    ValueFrom,
    BundleEnvVar,
    ServiceRef,
    Scaling,
    AppSpec,
    # The app-provisioned object-store bucket declaration (`AppSpec.buckets`)
    # — parsed by `_parse_bucket_spec`.
    BucketSpec,
    # ★ THE MAIL-TRANSPORT SPINE (`AppSpec.mail_transport`, field 34) — the domain
    # identity, the inbound queue and the DNS records that prove the domain.
    # Parsed by `_parse_mail_transport_spec` / `_parse_mail_transport_dns_record`.
    MailTransportSpec,
    MailTransportDnsRecord,
    MailIdentityOwnership,
    # ★ THE DATASTORE-COLLECTION AUTHORING TIER (`AppSpec.datastore_collections`,
    # field 35) — the collection shapes this app's datastore holds, and the ONLY
    # surface on which a key schema may be stated. Parsed by
    # `_parse_datastore_collection` / `_parse_datastore_access_path`.
    CloudVariant,
    DatastoreCollection,
    DatastoreAccessPath,
    # ★ HOW A SERVICE'S NAME RELATES TO ITS BUNDLE'S NAME (`AppSpec.name_scope`,
    # field 37). `NAME_SCOPE_REGIONAL` makes the authored `name` a
    # BASE name that the deploy TARGET qualifies — the one bundle, two clouds ask.
    NameScope,
    # The FULL url-map route table (`AppSpec.web_route_rules`) — parsed by `_parse_web_route_rule`.
    WebRouteRule,
    # ★ THE PER-WAVE FRONT-DOOR TOPOLOGY (`Wave.web_override`, field 8). Parsed
    # by `_parse_web_frontend_override`; TOTAL, never merged (see the proto
    # comment).
    WebFrontendOverride,
    # ADDITIONAL inbound routes the EDGE authenticates (`AppSpec.
    # secured_inbound_routes`; federated callers) — parsed
    # by `_parse_secured_inbound_route`, plus the policy enum it names.
    SecuredInboundRoute,
    EdgeAuthPolicyKind,
    # WHO may call this app's edge (`IngressSpec.caller_class`) — read through
    # `_read_enum_value` over the CLOSED `edge_caller_class_values()` set, so a
    # misspelt class is a parse error rather than a silent proto3 zero (which
    # composes the PUBLIC pass-through).
    EdgeCallerClass,
    # What a route rule ASSERTS about its paths: ROUTE / DENY (a NEGATIVE route —
    # security containment) / DEFAULT (the pathMatcher default arm + its SPA
    # deep-link 404 fallback).
    WebRouteDisposition,
    HttpCheck,
    GateOn,
    RunContainer,
    # The DIRECT VPC EGRESS attachment a validate step's JOB may carry
    # (`RunContainer.vpc_egress`, field 7). ABSENT => no `vpcAccess` on the
    # wire => the job egresses over the PUBLIC INTERNET.
    ValidateVpcEgress,
    # The read-only observability planes a validate step's container may query
    # for itself (`RunContainer.reads_telemetry`, field 8). EMPTY => no grant.
    TelemetryRead,
    # ★ The EPHEMERAL KOMIRA CALLER IDENTITIES a validate step declares
    # (`RunContainer.test_role`, field 9). EMPTY => nothing
    # provisioned, nothing revoked, no flag rendered.
    TestRole,
    TestRoleLevel,
    ValidateStep,
    Wave,
    # ⭐ The two build-target role vocabularies (fields 6/7).
    FileRole,
    RepositoryRole,
    # The TRIGGER authoring surface: a
    # named trigger + a ONE-ARM-PER-KIND payload oneof. The open set is the arm
    # list, not an enum — `GitPush` carries the git-shaped fields, `Schedule`
    # carries a cron, `PackagePublished` carries a package + a version range.
    TriggerSource,
    SourceKind,
    GitPush,
    Schedule,
    PackagePublished,
    RegistryKind,
    ServiceSpec,
    # The reshape — named validation SETS + the
    # pipeline-STEP authoring surface (defined once, referenced by name; NOT
    # welded to an env).
    ValidationSet,
    # ⛔ The ENV RESTRICTION a validation set carries.
    # UNSPECIFIED is NOT "any env"; validate.mojo refuses it at the point a
    # pipeline step RUNS the set.
    ValidationSetEnvPolicy,
    StepKind,
    PipelineStep,
    Pipeline,
    # The device/capability matrix
    # — a NEUTRAL, universal authoring block fanned by a `PipelineStep.matrix_ref`.
    # Parsed here (schema + parse); validated in validate.mojo (fail-closed).
    Matrix,
    MatrixCell,
    # The named DEPLOY OUTPUTS — a
    # CloudFormation-style named output referenced via `${ref:<bundle>.outputs.
    # <name>}`. Parsed here; validated in validate.mojo (fail-closed).
    DeployOutput,
    # ── Four optional capabilities. Each is a declarable front door for something
    #    the deploy tool can DO. ─────────────────────────────────────────────────
    # The ingress REALIZATION inputs (`AppSpec.ingress`, field 30) — the gateway
    # SA / placement / allow-list / service-enable inputs of ingress provisioning.
    IngressSpec,
    # A run-to-completion JOB the bundle ships (`AppBundle.jobs`, field 12), and
    # the validate-step arm that EXECUTES one (`ValidateStep.execute_job`).
    # Declaring is not running — the two are deliberately separate.
    JobSpec,
    ExecuteJob,
    # A scheduled call into a service this bundle declares (`AppBundle.crons`,
    # field 13) — a control-plane reconcile backstop.
    CronSpec,
    # Run-scoped lifecycle (`AppBundle.ephemeral`, field 14) — the permission a
    # bundle grants for `--run-id`, plus the retention override that makes a
    # throwaway run's teardown complete.
    EphemeralScope,
)
from komira_rpc_bundle.deploy_model import (
    # The index shapes an app declares for the database it OWNS
    # (`AppSpec.index_tables`, field 29) — parsed by `_parse_index_table`. The
    # whole point of the field: the control plane does not author an index for
    # anybody's database, so a customer-authored bundle carries its own.
    # ⚠ The messages are declared in deploy_model.proto. `DeploymentSpec.datastore_index_tables`
    # carries the identical shapes so the CP pipeline engine can ensure a managed
    # app's indexes in the CUSTOMER project; app_bundle.proto imports deploy_model.proto
    # and not the reverse, so the shared messages live in the imported file.
    BundleIndexTable,
    BundleIndex,
    BundleIndexField,
    ComputeIntent,
    DatastoreNeed,
    InboundNeed,
    # ★ THE NETWORK REACH of the served service (`AppSpec.network_ingress`,
    # field 32) — WHO MAY OPEN A CONNECTION, as opposed to
    # `public_invoker`'s WHO MAY INVOKE ONE. UNSPECIFIED stamps nothing.
    NetworkIngress,
    SecretBinding,
    SecretCustody,
)

from komira_deploy_bundle.tokenizer import (
    Token,
    tokenize,
    TOK_IDENT,
    TOK_STRING,
    TOK_NUMBER,
    TOK_LBRACE,
    TOK_RBRACE,
    TOK_COLON,
    TOK_EOF,
    _tok_kind_name,
)
from komira_deploy_bundle.parse_error import (
    pos_prefix,
    unknown_field_error,
    unknown_enum_error,
    ambiguous_enum_error,
)


# ─── The legal enum value sets (full proto value names) ──────────────────────
# PUBLIC so the patcher's `patch_set_enum` and the tests can resolve a token
# against the same closed value set the parser uses.
def app_kind_values() -> List[String]:
    var v = List[String]()
    v.append(String("APP_KIND_UNSPECIFIED"))
    v.append(String("APP_KIND_API"))
    v.append(String("APP_KIND_STATIC_FRONTEND"))
    v.append(String("APP_KIND_DATA_PIPELINE"))
    v.append(String("APP_KIND_SEARCH_CLUSTER"))
    # Typed BUILD+TEST artifact kinds — the
    # additive tail (ordinals 5–7). Listed here so the alias resolver ACCEPTS
    # `kind: APP_KIND_DESKTOP_APPLICATION` (+ the `DESKTOP_APPLICATION` short
    # suffix); `_read_enum_value` rejects any token not in this closed set.
    v.append(String("APP_KIND_DESKTOP_APPLICATION"))
    v.append(String("APP_KIND_MOBILE_APPLICATION"))
    v.append(String("APP_KIND_LIBRARY"))
    # ★ SHARED INFRASTRUCTURE (ordinal 8; reference-not-own) — a
    # release machine that OWNS resources and SERVES NOTHING. Listed here so the
    # alias resolver ACCEPTS `kind: APP_KIND_SHARED_INFRASTRUCTURE`; `_read_enum_value`
    # rejects any token not in this closed set, which is why a proto enum value added
    # without this line parses as an "unknown value" error rather than silently.
    v.append(String("APP_KIND_SHARED_INFRASTRUCTURE"))
    return v^


def tenancy_values() -> List[String]:
    """The legal `tenancy:` values (app_bundle.proto `Tenancy`).

    WHOSE CLOUD ACCOUNT the workload runs in — a SECOND axis, orthogonal to
    `kind` (which is the TOPOLOGY). See the `Tenancy` enum in app_bundle.proto
    for why collapsing the two is a trust-boundary defect.

    `_read_enum_value` rejects any token not in this CLOSED set, which is why a
    typo is a positioned parse error rather than a silent landing on the zero
    ordinal."""
    var v = List[String]()
    v.append(String("TENANCY_UNSPECIFIED"))
    v.append(String("TENANCY_CONTROL_PLANE"))
    v.append(String("TENANCY_CUSTOMER"))
    return v^


def value_from_values() -> List[String]:
    """The legal `value_from:` tokens (app_bundle.proto `ValueFrom`).

    THE CLOSED SET IS THE POINT: `_read_enum_value` rejects anything not listed,
    so a typo is a positioned parse error rather than a silent landing on
    `VALUE_FROM_UNSPECIFIED` (which resolves to EMPTY and is DROPPED — a variable
    the container then runs without, green about whatever default it falls back
    to). Keep in lockstep with the proto enum."""
    var v = List[String]()
    v.append(String("VALUE_FROM_UNSPECIFIED"))
    v.append(String("VALUE_FROM_DEPLOY_URL"))
    v.append(String("VALUE_FROM_EDGE_URL"))
    # ── The ENV-DERIVED arms — sourced from the RESOLVED
    # `EnvBinding`, not from a wave output, so they resolve for a step that runs
    # before any deploy. See the `ValueFrom` enum comment in app_bundle.proto.
    v.append(String("VALUE_FROM_ENV_PROJECT"))
    v.append(String("VALUE_FROM_ENV_REGION"))
    # ── The INTERNAL ORIGIN — the `.run.app`
    # service URL, dialled WITHOUT the gateway hop. Parseable ANYWHERE a
    # `value_from` is; whether it is LEGAL where it was written is a semantic
    # question `validate_bundle` answers, not a lexical one. Refusing it here
    # would be the wrong seam: the parser has no idea whether it is looking at a
    # validate step or a served spec, so a lexical ban would either block the one
    # place it belongs or state nothing at all.
    v.append(String("VALUE_FROM_INTERNAL_ORIGIN_URL"))
    # ── ★★ THE VALIDATION-RUN OWNERSHIP ID — the id of the RUN
    # executing the step, minted per run and therefore un-authorable as a
    # literal. Parseable ANYWHERE a `value_from` is, for the INTERNAL_ORIGIN
    # reason exactly: the parser cannot tell a validate step's `args` from a
    # served spec's `parameters`, so WHERE it is legal is a semantic question
    # `validate_bundle` answers (argv-only, and refused on every `env` channel,
    # because configuration arrives as flags). A lexical ban here would either block the one place it
    # belongs or say nothing at all.
    v.append(String("VALUE_FROM_VALIDATION_RUN_ID"))
    # ── ★★ THE LIFECYCLE COMPUTE-ENVIRONMENT NAME — the name a
    # managed-app release machine's lifecycle wave PRODUCES and CONSUMES,
    # DERIVED by the composer from the env binding and the RELEASE MACHINE
    # name. Parseable ANYWHERE a `value_from` is, for the INTERNAL_ORIGIN /
    # RUN_ID reason exactly: the parser cannot tell a validate step's `args`
    # from a served spec's `parameters`, so WHERE it is legal is a semantic
    # question `validate_bundle` answers (argv-only, and refused on every `env`
    # channel, because configuration arrives as flags). A lexical ban here would either block the one
    # place it belongs or say nothing at all.
    v.append(String("VALUE_FROM_LIFECYCLE_ENV_NAME"))
    # ── ⭐ THE FIVE COMPUTE-ENVIRONMENT EXPECTATIONS —
    # the CP VM gate's `EXPECT_*` args, rendered from the env row through
    # the compute-environment naming functions. Parseable ANYWHERE a `value_from`
    # is, for the INTERNAL_ORIGIN / RUN_ID reason: WHERE they are legal is a
    # semantic question `validate_bundle` answers — and today its answer is
    # "nowhere yet", by name, until their resolution is implemented.
    v.append(String("VALUE_FROM_COMPUTE_ENV_SERVICE_ACCOUNT"))
    v.append(String("VALUE_FROM_COMPUTE_ENV_SUBNETWORK"))
    v.append(String("VALUE_FROM_COMPUTE_ENV_ZONE"))
    v.append(String("VALUE_FROM_COMPUTE_ENV_PROJECT"))
    v.append(String("VALUE_FROM_COMPUTE_ENV_PLACER"))
    return v^


def gate_on_values() -> List[String]:
    var v = List[String]()
    v.append(String("GATE_ON_UNSPECIFIED"))
    v.append(String("GATE_ON_EXIT_CODE"))
    return v^


def telemetry_read_values() -> List[String]:
    """The legal `RunContainer.reads_telemetry` values (app_bundle.proto
    `TelemetryRead`). `_read_enum_value` rejects any token not in this CLOSED set.

    ⚠ THIS LIST IS A PRIVILEGE CEILING, not a convenience. Every token here is
    something a bundle author can make the deploy GRANT to the validate job's
    identity, so a line added here widens what EVERY bundle may ask
    for. It is two READ scopes and nothing else."""
    var v = List[String]()
    v.append(String("TELEMETRY_READ_UNSPECIFIED"))
    v.append(String("TELEMETRY_READ_LOGS"))
    v.append(String("TELEMETRY_READ_METRICS"))
    # ⭐ THE JOB-VM OBSERVE READ. ⚠ It widens the ceiling this
    # docstring warns about — which is why the GRANT it maps to is composed by
    # the CUSTOMER'S bootstrap in the CUSTOMER'S project (never the CP graph),
    # and why `validate_bundle` refuses a step reading it, by name, until it is
    # implemented.
    # Parseable here so the refusal can name it rather than report a typo.
    v.append(String("TELEMETRY_READ_JOB_VM_STATE"))
    return v^


def test_role_level_values() -> List[String]:
    """The legal `TestRole.level` values (app_bundle.proto `TestRoleLevel`).
    `_read_enum_value` rejects any token not in this CLOSED set.

    ⚠ THIS LIST IS A PRIVILEGE CEILING, exactly as `telemetry_read_values` is:
    every token here is a level a bundle author can make the deploy GRANT to an
    ephemeral caller identity, so a line added here widens what EVERY bundle may
    ask for. ADMIN and CREATE are deliberately absent — neither is ever a stored
    `ResourceGrant.level` (see the enum's own comment in the proto)."""
    var v = List[String]()
    v.append(String("TEST_ROLE_LEVEL_UNSPECIFIED"))
    v.append(String("TEST_ROLE_LEVEL_READ"))
    v.append(String("TEST_ROLE_LEVEL_WRITE"))
    v.append(String("TEST_ROLE_LEVEL_DELETE"))
    return v^


def name_scope_values() -> List[String]:
    """The legal `AppSpec.name_scope` values (app_bundle.proto `NameScope`).

    `_read_enum_value` rejects any token not in this CLOSED set, which is why a
    proto enum value added without a line here parses as an "unknown value"
    error rather than silently landing on the zero ordinal — and the zero ordinal
    here means "the authored name IS the service name", i.e. the one answer that
    must never be reached by accident."""
    var v = List[String]()
    v.append(String("NAME_SCOPE_UNSPECIFIED"))
    v.append(String("NAME_SCOPE_REGIONAL"))
    return v^


def param_type_values() -> List[String]:
    """The legal `AppParameter.type` values (app_bundle.proto `ParamType`).

    `_read_enum_value` rejects any token not in this CLOSED set, which is why a
    proto enum value added without a line here parses as an "unknown value"
    error rather than silently landing on the zero ordinal."""
    var v = List[String]()
    v.append(String("PARAM_TYPE_UNSPECIFIED"))
    v.append(String("PARAM_TYPE_STRING"))
    v.append(String("PARAM_TYPE_INT"))
    v.append(String("PARAM_TYPE_BOOL"))
    v.append(String("PARAM_TYPE_ENUM"))
    v.append(String("PARAM_TYPE_SECRET"))
    return v^


def param_marker_values() -> List[String]:
    """The legal `AppParameter.marker` values (app_bundle.proto `ParamMarker`) —
    the REGISTERED deploy-time value producers, carried as a typed enum rather
    than the `${…}` string grammar the env path uses."""
    var v = List[String]()
    v.append(String("PARAM_MARKER_UNSPECIFIED"))
    v.append(String("PARAM_MARKER_PROJECT"))
    v.append(String("PARAM_MARKER_REGION"))
    v.append(String("PARAM_MARKER_DATASTORE_DATABASE"))
    v.append(String("PARAM_MARKER_APP_DEPLOYMENT_ID"))
    v.append(String("PARAM_MARKER_APP_SIGNING_JWKS"))
    v.append(String("PARAM_MARKER_ORG_MAIL_DOMAIN"))
    v.append(String("PARAM_MARKER_ORG_ID"))
    return v^


def web_route_disposition_values() -> List[String]:
    """The legal `WebRouteRule.disposition` enum values — what the rule ASSERTS
    about its paths: ROUTE them (the additive-safe default), DENY them (a NEGATIVE
    route — they must not reach ANY backend), or configure the pathMatcher DEFAULT
    arm (the SPA deep-link 404 fallback)."""
    var v = List[String]()
    v.append(String("WEB_ROUTE_DISPOSITION_ROUTE"))
    v.append(String("WEB_ROUTE_DISPOSITION_DENY"))
    v.append(String("WEB_ROUTE_DISPOSITION_DEFAULT"))
    return v^


def validation_set_env_policy_values() -> List[String]:
    """The legal `ValidationSet.env_policy` values (app_bundle.proto
    `ValidationSetEnvPolicy`).

    ⛔ UNSPECIFIED IS IN THIS LIST ON PURPOSE, AND IT IS NOT A PERMISSION. It is
    spellable so a bundle can round-trip one, and `validate.mojo` refuses it at
    the moment a pipeline step RUNS the set. "Safe in any env" is
    `VALIDATION_SET_ENV_POLICY_ANY_ENV` and has to be written down."""
    var v = List[String]()
    v.append(String("VALIDATION_SET_ENV_POLICY_UNSPECIFIED"))
    v.append(String("VALIDATION_SET_ENV_POLICY_ANY_ENV"))
    v.append(String("VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST"))
    return v^


def step_kind_values() -> List[String]:
    """The legal `PipelineStep.step_kind` enum values (the pipeline-step KINDS;
    the verbs lifted to step kinds). VOCABULARY:
    `STEP_KIND_STAGE` names the artifact-staging VERB (one step kind), NEVER the
    pipeline unit (which is always a "step")."""
    var v = List[String]()
    v.append(String("STEP_KIND_UNSPECIFIED"))
    v.append(String("STEP_KIND_BUILD"))
    v.append(String("STEP_KIND_STAGE"))
    v.append(String("STEP_KIND_DEPLOY"))
    v.append(String("STEP_KIND_DEPLOY_AND_VALIDATE"))
    v.append(String("STEP_KIND_TEST"))
    return v^


def output_format_values() -> List[String]:
    """The legal `BuildTarget.output_format` enum values (the OUTPUT SHAPE — NOT the
    build tool)."""
    var v = List[String]()
    v.append(String("OUTPUT_FORMAT_IMAGE"))
    v.append(String("OUTPUT_FORMAT_LIBRARY_ARTIFACT"))
    v.append(String("OUTPUT_FORMAT_STATIC_TARGZ"))
    # ★ THE GENERIC FILE SHAPE. This list is the AUTHORING
    # vocabulary: an enum arm the proto declares but this list omits is REFUSED
    # by `_read_enum_value` as an unknown value, so a template could never
    # author it. Gated by `test_output_format_vocab_matches_proto`, which reads
    # the `app_bundle.proto` bytes rather than trusting this list.
    v.append(String("OUTPUT_FORMAT_FILE"))
    return v^


def file_role_values() -> List[String]:
    """The legal `BuildTarget.file_role` values (app_bundle.proto `FileRole`).
    Parseable so `validate_bundle` can refuse a non-zero one BY NAME while it is
    declared but not yet honoured — a lexical ban would report it as a typo
    instead."""
    var v = List[String]()
    v.append(String("FILE_ROLE_UNSPECIFIED"))
    v.append(String("FILE_ROLE_POD_LOADER_BUNDLE"))
    return v^


def repository_role_values() -> List[String]:
    """The legal `BuildTarget.repository_role` values (app_bundle.proto
    `RepositoryRole`). Same parse-then-refuse split as
    `file_role_values`."""
    var v = List[String]()
    v.append(String("REPOSITORY_ROLE_STAGE_IMAGES"))
    v.append(String("REPOSITORY_ROLE_JOB_IMAGES"))
    return v^


def compute_values() -> List[String]:
    """The legal `AppSpec.compute` enum values — the AUTHORING VOCABULARY, which
    is deliberately the PROTO's full set and NOT the supported set.

    ⛔ `COMPUTE_INTENT_SERVERFUL` STAYS HERE AND IS REFUSED BY
    `_refuse_unsupported_compute_intent` AT THE PARSE SITE. This is the exact
    treatment `cloud_variant_cloud_values` gives `CLOUD_UNSPECIFIED`, for the
    reason stated there: dropping a value from this list makes the tokenizer
    report it as an UNKNOWN enum value, which is a LIE — it is a known value of a
    proto this repo ships and documents. The refusal that names WHY belongs where
    the value is READ, not in the vocabulary."""
    var v = List[String]()
    v.append(String("COMPUTE_INTENT_UNSPECIFIED"))
    v.append(String("COMPUTE_INTENT_SERVERLESS"))
    v.append(String("COMPUTE_INTENT_SERVERFUL"))
    return v^


def _refuse_unsupported_compute_intent(
    value: String, line: Int, col: Int
) raises:
    """REFUSE `compute: COMPUTE_INTENT_SERVERFUL` by name, at parse time.

    ⛔⛔ WHY THIS IS A REFUSAL AND NOT A TODO. Before it, the value was ACCEPTED
    the whole way: the parser takes it, the validator passes it, the emitter
    re-serialises it — but the deploy's GCP `DeploymentSpec` construction (the
    SERVICE and the JOB) builds `COMPUTE_INTENT_SERVERLESS` and never reads the
    authored field at all. So a customer could author SERVERFUL, get a GREEN
    deploy, and receive SERVERLESS. A value goes in with its conformer or not at
    all; a silent wrong answer past the CUSTOMER boundary cannot be walked back.

    The message says what IS supported, so an operator who hits it can act. It
    does NOT say "coming soon": `serverful` needs a VM/ECS/K8s-Deployment
    conformer that does not exist, and a promise in an error message is how the
    next reader concludes the field half-works."""
    if value != String("COMPUTE_INTENT_SERVERFUL"):
        return
    raise Error(
        pos_prefix(line, col)
        + String(
            "compute: COMPUTE_INTENT_SERVERFUL is NOT SUPPORTED. This bundle"
            " would deploy as COMPUTE_INTENT_SERVERLESS regardless — the"
            " authored value is not read by any mapper, and both GCP"
            " DeploymentSpec sites set SERVERLESS unconditionally — so"
            " accepting it would hand back a different deployment from the one"
            " written. SUPPORTED: COMPUTE_INTENT_SERVERLESS (Cloud Run on GCP,"
            " Lambda on AWS) and COMPUTE_INTENT_UNSPECIFIED (which the mapper"
            " defaults to serverless). NOT SUPPORTED: COMPUTE_INTENT_SERVERFUL"
            " — the always-on VM / ECS / K8s-Deployment realization it names has"
            " no conformer in this tree. Write COMPUTE_INTENT_SERVERLESS, or"
            " omit `compute` entirely."
        )
    )


def datastore_values() -> List[String]:
    var v = List[String]()
    v.append(String("DATASTORE_NEED_UNSPECIFIED"))
    v.append(String("DATASTORE_NEED_NONE"))
    v.append(String("DATASTORE_NEED_SERVERLESS"))
    v.append(String("DATASTORE_NEED_DEDICATED"))
    return v^


def inbound_values() -> List[String]:
    var v = List[String]()
    v.append(String("INBOUND_NEED_UNSPECIFIED"))
    v.append(String("INBOUND_NEED_WEBHOOK"))
    v.append(String("INBOUND_NEED_POLL"))
    v.append(String("INBOUND_NEED_CLIENT"))
    return v^


def cloud_variant_cloud_values() -> List[String]:
    """The authored spellings of `CloudVariant.cloud` — WHICH CLOUD POSTURE one
    per-cloud spec variant answers for (`AppSpec.cloud_variants`, field 36).

    ⚠ THE ORDINALS ARE `komira.deploy.v1.Cloud`'s, MIRRORED not imported — the
    identical treatment `Environment.deploy_provider` and `Environment.tenancy`
    take, and for the reason environment.proto's header states at length (the two
    protos are separate `-I` roots). The field is an `int32` on the wire and these
    are the tokens a bundle author writes.

    ⛔ `CLOUD_UNSPECIFIED` IS ACCEPTED HERE AND REFUSED AT COMPOSE, deliberately.
    Refusing it in the tokenizer would report it as an UNKNOWN enum value, which
    is a lie — it is a known value that no deploy can select. The refusal that
    names WHY belongs where the selection happens."""
    var v = List[String]()
    v.append(String("CLOUD_UNSPECIFIED"))
    v.append(String("CLOUD_GCP"))
    v.append(String("CLOUD_AWS"))
    v.append(String("CLOUD_AZURE"))
    v.append(String("CLOUD_KUBERNETES"))
    v.append(String("CLOUD_LOCAL"))
    return v^


def cloud_variant_cloud_ordinal(token: String) raises -> Int32:
    """The `Cloud` ORDINAL one authored `CloudVariant.cloud` token names. The
    inverse of `cloud_variant_cloud_values()`, and the ONLY place in this parser
    that knows the mapping. Raises on a token outside the closed set — which
    `_read_enum_value` has already rejected, so this raise is the belt to that
    braces rather than the diagnostic an author sees."""
    if token == String("CLOUD_UNSPECIFIED"):
        return Int32(0)
    if token == String("CLOUD_GCP"):
        return Int32(1)
    if token == String("CLOUD_AWS"):
        return Int32(2)
    if token == String("CLOUD_AZURE"):
        return Int32(3)
    if token == String("CLOUD_KUBERNETES"):
        return Int32(4)
    if token == String("CLOUD_LOCAL"):
        return Int32(5)
    raise Error(
        String("CloudVariant.cloud: unknown posture token '") + token + String("'")
    )


def network_ingress_values() -> List[String]:
    """The authored spellings of `AppSpec.network_ingress` — WHO MAY OPEN A
    CONNECTION to the served service (deploy_model.proto `NetworkIngress`).

    ⚠ UNSPECIFIED IS NOT "PRIVATE". It means the deploy stamps nothing, and the
    platform's own default then applies — which on Cloud Run is PUBLIC network
    reach. A bundle that must not be publicly dialable has to name one of the
    other three, so the omission is visible rather than mistakable for a
    decision."""
    var v = List[String]()
    v.append(String("NETWORK_INGRESS_UNSPECIFIED"))
    v.append(String("NETWORK_INGRESS_PUBLIC"))
    v.append(String("NETWORK_INGRESS_INTERNAL"))
    v.append(String("NETWORK_INGRESS_INTERNAL_AND_LOAD_BALANCER"))
    return v^


def mail_identity_ownership_values() -> List[String]:
    """The authored spellings of `MailTransportSpec.identity_ownership` — WHO
    OWNS the mail domain identity (app_bundle.proto `MailIdentityOwnership`).

    ⛔ UNSPECIFIED IS LISTED HERE AND REFUSED DOWNSTREAM, the
    `edge_auth_policy_kind_values` shape and NOT the `secret_custody_values` one.
    It is listed so an author who writes it gets the COMPOSER's sentence
    ("both answers are destructive in opposite directions") rather than the
    parser's generic `did you mean`, which would name the two legal values and
    say nothing about why guessing between them is not available."""
    var v = List[String]()
    v.append(String("MAIL_IDENTITY_OWNERSHIP_UNSPECIFIED"))
    v.append(String("MAIL_IDENTITY_OWNERSHIP_OURS"))
    v.append(String("MAIL_IDENTITY_OWNERSHIP_EXTERNAL"))
    return v^


def secret_custody_values() -> List[String]:
    """The authored spellings of `SecretBinding.custody` — WHOSE credential a
    binding names (deploy_model.proto `SecretCustody`).

    UNSPECIFIED is listed so an author may STATE the default rather than only
    inherit it; it reads as CUSTOMER, so stating it changes nothing. Unlike
    `edge_auth_policy_kind_values` there is no downstream refusal of UNSPECIFIED,
    because for custody "unspecified" has a safe and meaningful answer — do not
    write — whereas for an edge policy it has none."""
    var v = List[String]()
    v.append(String("SECRET_CUSTODY_UNSPECIFIED"))
    v.append(String("SECRET_CUSTODY_CUSTOMER"))
    v.append(String("SECRET_CUSTODY_OPERATOR"))
    # PLATFORM_MINTED — a credential the platform generates that lives in the
    # CUSTOMER's project (for example a per-org inbound-webhook secret). Listed so
    # the ordinal set here stays set-equal with `deploy_model.proto`'s enum; a
    # bundle does not normally author it, because the slots that carry it are
    # composed per-org at PROVISION time and a bundle's substitution vocabulary has no `${org}` token.
    v.append(String("SECRET_CUSTODY_PLATFORM_MINTED"))
    return v^


def edge_auth_policy_kind_values() -> List[String]:
    """The authored spellings of `SecuredInboundRoute.policy`.

    ⛔ UNSPECIFIED IS LISTED SO THE PARSER CAN READ IT, AND `validate` REFUSES IT.
    Omitting it here would make an authored `EDGE_AUTH_POLICY_KIND_UNSPECIFIED`
    an unknown-VALUE parse error, which reads as a typo; the refusal that matters
    is the one that says a route was declared secured and no policy was named."""
    var v = List[String]()
    v.append(String("EDGE_AUTH_POLICY_KIND_UNSPECIFIED"))
    v.append(String("EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT"))
    return v^


def edge_caller_class_values() -> List[String]:
    """The authored spellings of `IngressSpec.caller_class` — WHO may call this
    app's edge.

    ⛔ THE SET IS CLOSED AND `_read_enum_value` REFUSES ANYTHING OUTSIDE IT. That
    matters more here than for most enums: a misspelt caller class must not parse
    to the proto3 zero, because the zero composes today's PUBLIC pass-through and
    the misspelling would most often be someone trying to say INTERNAL.

    UNSPECIFIED is listed so an explicit one reads as itself rather than as a
    typo; it means "this bundle has not answered", and the composer's reading of
    it is documented at `EdgeCallerClass` in `app_bundle.proto`."""
    var v = List[String]()
    v.append(String("EDGE_CALLER_CLASS_UNSPECIFIED"))
    v.append(String("EDGE_CALLER_CLASS_PUBLIC"))
    v.append(String("EDGE_CALLER_CLASS_PEER_INTERNAL"))
    return v^


def source_kind_values() -> List[String]:
    var v = List[String]()
    v.append(String("SOURCE_KIND_UNSPECIFIED"))
    v.append(String("SOURCE_KIND_GIT_SELFHOSTED"))
    v.append(String("SOURCE_KIND_GIT_EXTERNAL"))
    return v^


def registry_kind_values() -> List[String]:
    var v = List[String]()
    v.append(String("REGISTRY_KIND_UNSPECIFIED"))
    v.append(String("REGISTRY_KIND_GITHUB_PACKAGES"))
    v.append(String("REGISTRY_KIND_CODEWORKS"))
    return v^


# ─── Enum alias resolution (friendly input, canonical output) ────────────────
def _match_enum(token: String, legal: List[String]) -> List[String]:
    """The core matcher. Returns the canonical declared value(s) `token` resolves
    to: an EXACT full-name match (case-insensitive) wins and returns a single
    element; otherwise EVERY declared value ending in `_<TOKEN>` (the short suffix
    alias, e.g. `API` -> `APP_KIND_API`). The caller decides unknown (0 matches)
    vs. resolved (1) vs. ambiguous (>1)."""
    var tup = token.upper()
    var out = List[String]()
    for ref v in legal:
        if v.upper() == tup:
            out.append(String(v))
            return out^  # an exact match is unique + authoritative
    var needle = String("_") + tup
    for ref v in legal:
        if v.upper().endswith(needle):
            out.append(String(v))
    return out^


def resolve_enum_token(token: String, legal: List[String]) raises -> String:
    """Resolve `token` to its CANONICAL full declared value name — accepting a
    short suffix alias when it is unambiguous (the parser's alias rule, reused by
    the patcher). Raises a NON-positioned error on unknown/ambiguous (the patcher
    has no source position); the parser builds positioned errors itself."""
    var matches = _match_enum(token, legal)
    if len(matches) == 1:
        return matches[0]
    if len(matches) == 0:
        raise Error(
            String("unknown enum value '")
            + token
            + String("' (legal: ")
            + _join_list(legal)
            + String(")")
        )
    raise Error(
        String("ambiguous enum value '")
        + token
        + String("' — matches ")
        + _join_list(matches)
        + String("; use the full value name")
    )


def _join_list(names: List[String]) -> String:
    var out = String("")
    for i in range(len(names)):
        if i > 0:
            out += String(", ")
        out += names[i]
    return out^


# ─── The parse cursor ────────────────────────────────────────────────────────
struct Cursor(Movable):
    """A value-typed cursor over the token stream. `peek` never runs past the
    terminating `TOK_EOF` sentinel (it re-returns EOF); `advance` returns the
    current token and steps forward."""

    var toks: List[Token]
    var pos: Int

    def __init__(out self, var toks: List[Token]):
        self.toks = toks^
        self.pos = 0

    def peek(self) -> Token:
        return self.toks[self.pos].copy()

    def advance(mut self) -> Token:
        var t = self.toks[self.pos].copy()
        if self.pos + 1 < len(self.toks):
            self.pos += 1
        return t^


# ─── Low-level token expectations ────────────────────────────────────────────
def _expect_colon(mut cur: Cursor, field: String) raises:
    var t = cur.peek()
    if t.kind != TOK_COLON:
        raise Error(
            pos_prefix(t.line, t.col)
            + String("expected ':' after field '")
            + field
            + String("', found ")
            + _tok_kind_name(t.kind)
        )
    _ = cur.advance()


def _read_string_value(mut cur: Cursor, field: String) raises -> String:
    _expect_colon(cur, field)
    var t = cur.peek()
    if t.kind != TOK_STRING:
        raise Error(
            pos_prefix(t.line, t.col)
            + String("field '")
            + field
            + String("' expects a quoted string, found ")
            + _tok_kind_name(t.kind)
        )
    _ = cur.advance()
    return t.text


def _read_int_value(mut cur: Cursor, field: String) raises -> Int32:
    _expect_colon(cur, field)
    var t = cur.peek()
    if t.kind != TOK_NUMBER:
        raise Error(
            pos_prefix(t.line, t.col)
            + String("field '")
            + field
            + String("' expects an integer, found ")
            + _tok_kind_name(t.kind)
        )
    _ = cur.advance()
    return Int32(atol(t.text))


def _read_bool_value(mut cur: Cursor, field: String) raises -> Bool:
    """Read `field: true|false` (the textproto bool literal — an IDENT token)."""
    _expect_colon(cur, field)
    var t = cur.peek()
    if t.kind == TOK_IDENT and (
        t.text == String("true") or t.text == String("false")
    ):
        _ = cur.advance()
        return t.text == String("true")
    raise Error(
        pos_prefix(t.line, t.col)
        + String("field '")
        + field
        + String("' expects a bool (true|false), found ")
        + _tok_kind_name(t.kind)
    )


def _read_enum_value(
    mut cur: Cursor, field: String, enum_name: String, legal: List[String]
) raises -> String:
    """Read `field: ENUM_VALUE` and resolve it to its CANONICAL full value name.
    Accepts a SHORT suffix alias when unambiguous (`API` -> `APP_KIND_API`) — the
    LLM-writability middle path; emission stays canonical-full everywhere. An
    unknown value raises a positioned `did you mean` diagnostic; a short token
    that is a suffix of more than one value raises a positioned ambiguity error."""
    _expect_colon(cur, field)
    var t = cur.peek()
    if t.kind != TOK_IDENT:
        raise Error(
            pos_prefix(t.line, t.col)
            + String("field '")
            + field
            + String("' expects an enum value, found ")
            + _tok_kind_name(t.kind)
        )
    _ = cur.advance()
    var matches = _match_enum(t.text, legal)
    if len(matches) == 1:
        return matches[0]  # the canonical full value name
    if len(matches) == 0:
        raise Error(unknown_enum_error(t.line, t.col, t.text, enum_name, legal))
    raise Error(ambiguous_enum_error(t.line, t.col, t.text, enum_name, matches))


def _open_block(mut cur: Cursor, field: String) raises:
    """Consume an optional `:` then a required `{` — the textproto message-field
    opener (`spec {` and `spec: {` are both legal)."""
    var t = cur.peek()
    if t.kind == TOK_COLON:
        _ = cur.advance()
        t = cur.peek()
    if t.kind != TOK_LBRACE:
        raise Error(
            pos_prefix(t.line, t.col)
            + String("expected '{' to open the '")
            + field
            + String("' block, found ")
            + _tok_kind_name(t.kind)
        )
    _ = cur.advance()


def _at_block_end(mut cur: Cursor, container: String) raises -> Bool:
    """True (consuming the `}`) at a block's closing brace; raises on a premature
    EOF (an unterminated block)."""
    var t = cur.peek()
    if t.kind == TOK_RBRACE:
        _ = cur.advance()
        return True
    if t.kind == TOK_EOF:
        raise Error(
            pos_prefix(t.line, t.col)
            + String("unexpected end-of-input: unterminated '")
            + container
            + String("' block (missing '}')")
        )
    return False


def _read_field_name(mut cur: Cursor, container: String) raises -> Token:
    var t = cur.peek()
    if t.kind != TOK_IDENT:
        raise Error(
            pos_prefix(t.line, t.col)
            + String("expected a field name in ")
            + container
            + String(", found ")
            + _tok_kind_name(t.kind)
        )
    _ = cur.advance()
    return t^


def _check_arm_name(arm: Int) -> StaticString:
    """The AUTHORED field name of a `ValidateStep.check` arm index. The generated
    `_oneof0_case` is the 1-BASED ARM INDEX in declaration order (http_check=1,
    run_container=2, execute_job=3), NOT the proto field number (2/3/6) — see the
    module header note on the two numbering schemes. Used only to name the
    already-set arm in a oneof-conflict error.

    It exists because the pre-`execute_job` code compared against the ONE other
    arm by hand (`if arm == 2` / `if arm == 1`), which silently stops detecting
    conflicts the moment a third arm is added: `http_check` after `execute_job`
    would have set two arms with no error at all. The guard is now `arm != 0`
    everywhere, and this names whichever arm won."""
    if arm == 1:
        return "http_check"
    if arm == 2:
        return "run_container"
    if arm == 3:
        return "execute_job"
    return "<unset>"


def _trigger_arm_name(arm: Int) -> StaticString:
    """The AUTHORED field name of a `TriggerSource.on` arm index. The generated
    `_oneof0_case` is the 1-BASED ARM INDEX in declaration order (git_push=1,
    schedule=2, package_published=3), NOT the proto field number (6/7/8) — see
    the module header note on the two numbering schemes. Used only to name the
    already-set arm in a oneof-conflict error."""
    if arm == 1:
        return "git_push"
    if arm == 2:
        return "schedule"
    if arm == 3:
        return "package_published"
    return "<unset>"


def _oneof_conflict(
    line: Int, col: Int, container: String, existing_arm: String, new_arm: String
) -> String:
    return (
        pos_prefix(line, col)
        + String("field '")
        + new_arm
        + String("' conflicts with '")
        + existing_arm
        + String("' — ")
        + container
        + String(" is a oneof (set exactly one arm)")
    )


# ─── Per-message parsers ─────────────────────────────────────────────────────
def _parse_build_target(mut cur: Cursor) raises -> BuildTarget:
    var name = String("")
    var dockerfile = String("")
    var context = String("")
    var output_format = OutputFormat(0)  # OUTPUT_FORMAT_IMAGE — zero-migration default
    var output = String("")
    # ⭐ Fields 6/7. Zero unless authored; `validate_bundle` refuses a non-zero
    # value by name while they are declared but not yet honoured.
    var file_role = FileRole(0)
    var repository_role = RepositoryRole(0)
    while not _at_block_end(cur, String("BuildTarget")):
        var f = _read_field_name(cur, String("BuildTarget"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("dockerfile"):
            dockerfile = _read_string_value(cur, String("dockerfile"))
        elif f.text == String("context"):
            context = _read_string_value(cur, String("context"))
        elif f.text == String("output_format"):
            var of = _read_enum_value(
                cur,
                String("output_format"),
                String("OutputFormat"),
                output_format_values(),
            )
            output_format = OutputFormat.from_json_name(of)
        elif f.text == String("output"):
            output = _read_string_value(cur, String("output"))
        elif f.text == String("file_role"):
            var fr = _read_enum_value(
                cur, String("file_role"), String("FileRole"), file_role_values()
            )
            file_role = FileRole.from_json_name(fr)
        elif f.text == String("repository_role"):
            var rr = _read_enum_value(
                cur,
                String("repository_role"),
                String("RepositoryRole"),
                repository_role_values(),
            )
            repository_role = RepositoryRole.from_json_name(rr)
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("dockerfile"))
            known.append(String("context"))
            known.append(String("output_format"))
            known.append(String("output"))
            known.append(String("file_role"))
            known.append(String("repository_role"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("BuildTarget"), known
                )
            )
    return BuildTarget(
        name^,
        dockerfile^,
        context^,
        output_format^,
        output^,
        file_role,
        repository_role,
    )


def _parse_image_ref(mut cur: Cursor) raises -> ImageRef:
    var arm = 0
    var digest: Optional[String] = None
    var from_build: Optional[String] = None
    while not _at_block_end(cur, String("ImageRef")):
        var f = _read_field_name(cur, String("ImageRef"))
        if f.text == String("digest"):
            if arm == 2:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("ImageRef.source"),
                        String("from_build"), String("digest"),
                    )
                )
            digest = _read_string_value(cur, String("digest"))
            arm = 1
        elif f.text == String("from_build"):
            if arm == 1:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("ImageRef.source"),
                        String("digest"), String("from_build"),
                    )
                )
            from_build = _read_string_value(cur, String("from_build"))
            arm = 2
        else:
            var known = List[String]()
            known.append(String("digest"))
            known.append(String("from_build"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("ImageRef"), known)
            )
    return ImageRef(arm, digest^, from_build^)


def _parse_service_ref(mut cur: Cursor) raises -> ServiceRef:
    """Parse a `service_ref { service: "<name>" }` block into a ServiceRef — the
    typed CROSS-SERVICE reference (app_bundle.proto `ServiceRef`: a LOGICAL
    service name only, NO vendor URL). Mirrors `_parse_build_target`."""
    var service = String("")
    while not _at_block_end(cur, String("ServiceRef")):
        var f = _read_field_name(cur, String("ServiceRef"))
        if f.text == String("service"):
            service = _read_string_value(cur, String("service"))
        else:
            var known = List[String]()
            known.append(String("service"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("ServiceRef"), known)
            )
    return ServiceRef(service^)


def _parse_bundle_env_var(
    mut cur: Cursor, allow_service: Bool = False
) raises -> BundleEnvVar:
    """Parse one `env { … }` / `env_override { … }` block into a `BundleEnvVar`.

    ★ `allow_service` IS THE CONTEXT, AND IT DEFAULTS TO REFUSING.
    `BundleEnvVar.service` names WHICH service a per-wave override applies to, and
    it is meaningful ONLY inside `Wave.env_override` — the one place the question
    is open. In an `AppSpec.env`, a `ServiceSpec.spec.env` or a `RunContainer.env`
    the answer is already given by the block the var is written in, so a `service:`
    there is refused HERE, at the authoring site, with a line and a column.

    ⚠ REFUSED, NOT IGNORED, and the default is the strict one. A parser that
    accepted the field everywhere and honoured it in one place would make the same
    six characters mean "this override targets service X" in one block and nothing
    at all in three others — and the three silent ones are where a reader would
    most reasonably expect it to work."""
    var name = String("")
    var service = String("")
    var arm = 0
    var value: Optional[String] = None
    var value_from: Optional[ValueFrom] = None
    var service_ref: Optional[ServiceRef] = None
    while not _at_block_end(cur, String("BundleEnvVar")):
        var f = _read_field_name(cur, String("BundleEnvVar"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("value"):
            if arm == 2 or arm == 3:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("BundleEnvVar.val"),
                        String("value_from") if arm == 2 else String("service_ref"),
                        String("value"),
                    )
                )
            value = _read_string_value(cur, String("value"))
            arm = 1
        elif f.text == String("value_from"):
            if arm == 1 or arm == 3:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("BundleEnvVar.val"),
                        String("value") if arm == 1 else String("service_ref"),
                        String("value_from"),
                    )
                )
            var vf = _read_enum_value(
                cur, String("value_from"), String("ValueFrom"), value_from_values()
            )
            value_from = ValueFrom.from_json_name(vf)
            arm = 2
        elif f.text == String("service_ref"):
            # The APPENDED cross-service arm (oneof case 3, field 4), authored as a
            # nested `service_ref { service: "<name>" }` block (mirrors the `image`
            # ImageRef sub-block). SVCREF-2 added the proto arm; this closes the
            # parser gap so a bundle can DECLARE the reference — the compose tier then
            # auto-emits the run.invoker Grant (sibling OR external peer).
            if arm == 1 or arm == 2:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("BundleEnvVar.val"),
                        String("value") if arm == 1 else String("value_from"),
                        String("service_ref"),
                    )
                )
            _open_block(cur, String("service_ref"))
            service_ref = _parse_service_ref(cur)
            arm = 3
        elif f.text == String("service"):
            # ★ THE SERVICE AXIS (field 5) — the per-wave override's target.
            # ⚠ NOT the `service_ref` arm: that one says "this var's VALUE is
            # another service's URL"; this one says "this OVERRIDE belongs to
            # another service". Two different questions that share a noun, which
            # is exactly why the refusal below names the block it was written in.
            if not allow_service:
                raise Error(
                    pos_prefix(f.line, f.col)
                    + String(
                        "field 'service' is meaningful ONLY on a"
                        " `waves { env_override { … } }` entry, where it names"
                        " WHICH service in the bundle the override applies to."
                        " In an `env { … }` block the service is already the one"
                        " whose spec contains it — remove the field, or move the"
                        " var into the wave override it was meant for."
                    )
                )
            service = _read_string_value(cur, String("service"))
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("value"))
            known.append(String("value_from"))
            known.append(String("service_ref"))
            # Offered as a known field ONLY where it is legal — an "unknown field
            # 'service'" list that advertised it everywhere would send an author
            # to write it in the three blocks that refuse it.
            if allow_service:
                known.append(String("service"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("BundleEnvVar"), known
                )
            )
    return BundleEnvVar(name^, service^, arm, value^, value_from^, service_ref^)


def _parse_app_parameter(mut cur: Cursor) raises -> AppParameter:
    """Parse one `parameters { … }` / `parameter_override { … }` block into an
    `AppParameter` — the typed managed-app input contract.

    ⚠ THE `source` ONEOF IS ENFORCED HERE, AND HAVING NO ARM IS LEGAL. Five arms
    (`value` | `secret_ref` | `marker` | `value_from` | `service_ref`) are
    mutually exclusive and a second one raises the SAME positioned oneof-conflict
    diagnostic `BundleEnvVar` uses. NO arm is the SUPPLIED case: the value comes
    from the control plane's opaque parameter map or an operator `--param`, which
    is the shape of every parameter a customer actually fills in — so an absent
    arm must not be an error.

    The declaration ORDER of `parameters` is load-bearing downstream (argv is
    emitted in it, so a revision's command line is byte-stable); this parser
    appends in authored order and never sorts."""
    var name = String("")
    var type = ParamType(ParamType.PARAM_TYPE_UNSPECIFIED)
    var required = False
    var default = String("")
    var description = String("")
    var flag = String("")
    var allowed_values = List[String]()
    var regex = String("")
    var min = Int64(0)
    var max = Int64(0)
    var has_min = False
    var has_max = False
    var arm = 0
    var value: Optional[String] = None
    var secret_ref: Optional[String] = None
    var marker: Optional[ParamMarker] = None
    var value_from: Optional[ValueFrom] = None
    var service_ref: Optional[ServiceRef] = None
    # ⭐ `from_build` (field 18, arm 6) — a build output of
    # this bundle, by target name. Refused by `validate_bundle` while it is
    # declared but not yet honoured.
    var from_build: Optional[String] = None

    while not _at_block_end(cur, String("AppParameter")):
        var f = _read_field_name(cur, String("AppParameter"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("type"):
            var tv = _read_enum_value(
                cur, String("type"), String("ParamType"), param_type_values()
            )
            type = ParamType.from_json_name(tv)
        elif f.text == String("required"):
            required = _read_bool_value(cur, String("required"))
        elif f.text == String("default"):
            default = _read_string_value(cur, String("default"))
        elif f.text == String("description"):
            description = _read_string_value(cur, String("description"))
        elif f.text == String("flag"):
            flag = _read_string_value(cur, String("flag"))
        elif f.text == String("allowed_values"):
            allowed_values.append(_read_string_value(cur, String("allowed_values")))
        elif f.text == String("regex"):
            regex = _read_string_value(cur, String("regex"))
        elif f.text == String("min"):
            # PRESENCE is explicit: 0 is a legitimate bound, so `has_min` is what
            # distinguishes `min: 0` from "no lower bound". Reading the field IS
            # the presence signal — the same absent-vs-empty distinction this
            # whole schema exists to preserve.
            min = Int64(_read_int_value(cur, String("min")))
            has_min = True
        elif f.text == String("max"):
            max = Int64(_read_int_value(cur, String("max")))
            has_max = True
        elif f.text == String("has_min"):
            has_min = _read_bool_value(cur, String("has_min"))
        elif f.text == String("has_max"):
            has_max = _read_bool_value(cur, String("has_max"))
        elif f.text == String("value"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("AppParameter.source"),
                        _param_source_arm_name(arm), String("value"),
                    )
                )
            value = _read_string_value(cur, String("value"))
            arm = 1
        elif f.text == String("secret_ref"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("AppParameter.source"),
                        _param_source_arm_name(arm), String("secret_ref"),
                    )
                )
            secret_ref = _read_string_value(cur, String("secret_ref"))
            arm = 2
        elif f.text == String("marker"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("AppParameter.source"),
                        _param_source_arm_name(arm), String("marker"),
                    )
                )
            var mv = _read_enum_value(
                cur, String("marker"), String("ParamMarker"), param_marker_values()
            )
            marker = ParamMarker.from_json_name(mv)
            arm = 3
        elif f.text == String("value_from"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("AppParameter.source"),
                        _param_source_arm_name(arm), String("value_from"),
                    )
                )
            var vf = _read_enum_value(
                cur, String("value_from"), String("ValueFrom"), value_from_values()
            )
            value_from = ValueFrom.from_json_name(vf)
            arm = 4
        elif f.text == String("service_ref"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("AppParameter.source"),
                        _param_source_arm_name(arm), String("service_ref"),
                    )
                )
            _open_block(cur, String("service_ref"))
            service_ref = _parse_service_ref(cur)
            arm = 5
        elif f.text == String("from_build"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("AppParameter.source"),
                        _param_source_arm_name(arm), String("from_build"),
                    )
                )
            from_build = _read_string_value(cur, String("from_build"))
            arm = 6
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("type"))
            known.append(String("required"))
            known.append(String("default"))
            known.append(String("description"))
            known.append(String("flag"))
            known.append(String("allowed_values"))
            known.append(String("regex"))
            known.append(String("min"))
            known.append(String("max"))
            known.append(String("value"))
            known.append(String("secret_ref"))
            known.append(String("marker"))
            known.append(String("value_from"))
            known.append(String("service_ref"))
            known.append(String("from_build"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("AppParameter"), known
                )
            )
    return AppParameter(
        name^, type, required, default^, description^, flag^,
        allowed_values^, regex^, min, max, has_min, has_max,
        arm, value^, secret_ref^, marker^, value_from^, service_ref^,
        from_build^,
    )


def _param_source_arm_name(arm: Int) -> StaticString:
    """The AUTHORED field name of a set `AppParameter.source` arm — so the
    oneof-conflict diagnostic names the arm the author actually wrote, not an
    ordinal they would have to look up."""
    if arm == 1:
        return "value"
    if arm == 2:
        return "secret_ref"
    if arm == 3:
        return "marker"
    if arm == 4:
        return "value_from"
    if arm == 5:
        return "service_ref"
    if arm == 6:
        return "from_build"
    return "<unset>"


def _parse_scaling(mut cur: Cursor) raises -> Scaling:
    var mn = Int32(0)
    var mx = Int32(0)
    while not _at_block_end(cur, String("Scaling")):
        var f = _read_field_name(cur, String("Scaling"))
        if f.text == String("min"):
            mn = _read_int_value(cur, String("min"))
        elif f.text == String("max"):
            mx = _read_int_value(cur, String("max"))
        else:
            var known = List[String]()
            known.append(String("min"))
            known.append(String("max"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("Scaling"), known)
            )
    return Scaling(mn, mx)


def _parse_http_check(mut cur: Cursor) raises -> HttpCheck:
    var path = String("")
    var expect_status = Int32(0)
    # ★ THE LATENCY BUDGET (`HttpCheck.max_latency_ms`, field 3). UNAUTHORED ==
    # 0 == NOT CHECKED — the status-only behaviour, preserved by construction rather than by a
    # policy someone has to remember.
    var max_latency_ms = Int32(0)
    while not _at_block_end(cur, String("HttpCheck")):
        var f = _read_field_name(cur, String("HttpCheck"))
        if f.text == String("path"):
            path = _read_string_value(cur, String("path"))
        elif f.text == String("expect_status"):
            expect_status = _read_int_value(cur, String("expect_status"))
        elif f.text == String("max_latency_ms"):
            max_latency_ms = _read_int_value(cur, String("max_latency_ms"))
        else:
            var known = List[String]()
            known.append(String("path"))
            known.append(String("expect_status"))
            known.append(String("max_latency_ms"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("HttpCheck"), known)
            )
    return HttpCheck(path^, expect_status, max_latency_ms)


def _parse_secret_binding(mut cur: Cursor) raises -> SecretBinding:
    var handle = String("")
    var capability_node = String("")
    var ensure = False
    # WHOSE credential this is. The zero value reads as CUSTOMER (do-not-write),
    # so a binding that names no custody keeps today's posture exactly.
    var custody = SecretCustody(0)
    while not _at_block_end(cur, String("SecretBinding")):
        var f = _read_field_name(cur, String("SecretBinding"))
        if f.text == String("handle"):
            handle = _read_string_value(cur, String("handle"))
        elif f.text == String("capability_node"):
            capability_node = _read_string_value(cur, String("capability_node"))
        elif f.text == String("ensure"):
            # ENSURE-mode: the deploy PROVISIONS the
            # secret container (create-if-absent) + wires the value-write, for a
            # secret NOT pre-seeded out of band. Default false = authorize-only.
            ensure = _read_bool_value(cur, String("ensure"))
        elif f.text == String("custody"):
            # CUSTODY (deploy_model.proto `SecretCustody`) — the OTHER half of
            # "may this deploy write a value here?". `ensure` provisions the
            # CONTAINER; this says whether a VALUE may go in it. Both are needed:
            # an OPERATOR binding still emits nothing unless `ensure` is set, and
            # an `ensure` binding still writes nothing unless custody is OPERATOR
            # AND the deploy is not acting in a customer account.
            var c = _read_enum_value(
                cur,
                String("custody"),
                String("SecretCustody"),
                secret_custody_values(),
            )
            custody = SecretCustody.from_json_name(c)
        else:
            var known = List[String]()
            known.append(String("handle"))
            known.append(String("capability_node"))
            known.append(String("ensure"))
            known.append(String("custody"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("SecretBinding"), known
                )
            )
    return SecretBinding(handle^, capability_node^, ensure, custody^)


def _parse_mail_transport_dns_record(
    mut cur: Cursor,
) raises -> MailTransportDnsRecord:
    """Parse one `dns_records { … }` block into a `MailTransportDnsRecord` (the
    literal record that proves / routes a mail domain).

    ⚠ NOTHING IS VALIDATED HERE, AND THAT IS THE LAYERING, NOT AN OMISSION. The
    record TYPE's legality, the `<`/`&`/quote wire-safety of the name and target,
    and the TTL all belong to the conformer that renders the change batch — it
    already refuses each BY NAME with a sentence about what Route53 does with the
    value. A second copy of those refusals here would be the one that goes stale.
    What the parser owes is the POSITION of an unknown field, which it gives."""
    var record_name = String("")
    var record_type = String("")
    var target = String("")
    while not _at_block_end(cur, String("MailTransportDnsRecord")):
        var f = _read_field_name(cur, String("MailTransportDnsRecord"))
        if f.text == String("record_name"):
            record_name = _read_string_value(cur, String("record_name"))
        elif f.text == String("record_type"):
            record_type = _read_string_value(cur, String("record_type"))
        elif f.text == String("target"):
            target = _read_string_value(cur, String("target"))
        else:
            var known = List[String]()
            known.append(String("record_name"))
            known.append(String("record_type"))
            known.append(String("target"))
            raise Error(
                unknown_field_error(
                    f.line,
                    f.col,
                    f.text,
                    String("MailTransportDnsRecord"),
                    known,
                )
            )
    return MailTransportDnsRecord(record_name^, record_type^, target^)


def _parse_datastore_access_path(
    mut cur: Cursor, container: String
) raises -> DatastoreAccessPath:
    """Parse a `primary_access_path { … }` / `secondary_access_paths { … }` block
    into a `DatastoreAccessPath` — how a collection is ADDRESSED.

    ONE function for BOTH keys, because on both clouds they are the same concept
    materialized twice (a table key and a secondary index; a document path and a
    composite index) and the message is the same. `container` is the KEY the
    author wrote, so a positioned error names the block they are looking at
    rather than the message type — the `_emit_validate_vpc_egress` discipline.

    ⛔ NOTHING IS DEFAULTED AND NOTHING IS VALIDATED HERE. A missing partition
    field is not a parse error: the parser's job is to read what was written, and
    the arm that turns these values into an IMMUTABLE key schema is the one that
    refuses an incomplete one BY NAME. A parser that silently supplied `string`
    for an absent type would make that refusal unreachable and the wrong answer
    permanent."""
    var name = String("")
    var partition_field = String("")
    var partition_field_type = String("")
    var ordered_field = String("")
    var ordered_field_type = String("")
    while not _at_block_end(cur, container):
        var f = _read_field_name(cur, container)
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("partition_field"):
            partition_field = _read_string_value(
                cur, String("partition_field")
            )
        elif f.text == String("partition_field_type"):
            partition_field_type = _read_string_value(
                cur, String("partition_field_type")
            )
        elif f.text == String("ordered_field"):
            ordered_field = _read_string_value(cur, String("ordered_field"))
        elif f.text == String("ordered_field_type"):
            ordered_field_type = _read_string_value(
                cur, String("ordered_field_type")
            )
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("partition_field"))
            known.append(String("partition_field_type"))
            known.append(String("ordered_field"))
            known.append(String("ordered_field_type"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, container, known)
            )
    return DatastoreAccessPath(
        name^,
        partition_field^,
        partition_field_type^,
        ordered_field^,
        ordered_field_type^,
    )


def _parse_datastore_collection(
    mut cur: Cursor,
) raises -> DatastoreCollection:
    """Parse ONE `datastore_collections { … }` block into a
    `DatastoreCollection` — one keyed collection inside this app's datastore
    (`AppSpec.datastore_collections`, field 35).

    ⛔ A SECOND `primary_access_path` IS REFUSED, NOT LAST-WINS. It is a SINGULAR
    field, so the second would silently REPLACE the first — and on the arm where
    this becomes a key schema the two designs are different, permanent, and
    uncorrectable without destroying every item. An author who wrote two meant
    something this schema cannot express (that is what `secondary_access_paths`
    is), so say so at the second block rather than picking one. Same rule the
    `mail_transport` block states for itself."""
    var name = String("")
    var primary: Optional[DatastoreAccessPath] = None
    var secondary_access_paths = List[DatastoreAccessPath]()
    var expiry_field = String("")
    var referenced = False
    while not _at_block_end(cur, String("DatastoreCollection")):
        var f = _read_field_name(cur, String("DatastoreCollection"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("primary_access_path"):
            if primary:
                raise Error(
                    pos_prefix(f.line, f.col)
                    + String(
                        "collection declares a SECOND `primary_access_path`"
                        " block. It is a SINGULAR field, so the second would"
                        " silently REPLACE the first — and a collection has"
                        " exactly one identity. An ADDITIONAL query shape is a"
                        " `secondary_access_paths` block."
                    )
                )
            _open_block(cur, String("primary_access_path"))
            primary = Optional[DatastoreAccessPath](
                _parse_datastore_access_path(
                    cur, String("primary_access_path")
                )
            )
        elif f.text == String("secondary_access_paths"):
            _open_block(cur, String("secondary_access_paths"))
            secondary_access_paths.append(
                _parse_datastore_access_path(
                    cur, String("secondary_access_paths")
                )
            )
        elif f.text == String("expiry_field"):
            expiry_field = _read_string_value(cur, String("expiry_field"))
        elif f.text == String("referenced"):
            referenced = _read_bool_value(cur, String("referenced"))
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("primary_access_path"))
            known.append(String("secondary_access_paths"))
            known.append(String("expiry_field"))
            known.append(String("referenced"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("DatastoreCollection"), known
                )
            )
    return DatastoreCollection(
        name^,
        primary^,
        secondary_access_paths^,
        expiry_field^,
        referenced,
    )


def _parse_mail_transport_spec(mut cur: Cursor) raises -> MailTransportSpec:
    """Parse the `mail_transport { … }` block into a `MailTransportSpec` — the
    app's mail spine: the domain it may send as and receive for, the queue
    accepted inbound mail lands in, and the DNS records that prove the domain.

    Mirrors `_parse_bucket_spec`: mutable accumulators -> the positional generated
    ctor, repeated sub-blocks appended in AUTHORED ORDER (which is the order the
    composer emits the DNS_RECORD nodes in, so a plan reads in the order it was
    written)."""
    var domain = String("")
    var identity_ownership = MailIdentityOwnership(
        MailIdentityOwnership.MAIL_IDENTITY_OWNERSHIP_UNSPECIFIED
    )
    var inbound_queue = String("")
    var inbound_queue_logical_id = String("")
    var dns_records = List[MailTransportDnsRecord]()
    while not _at_block_end(cur, String("MailTransportSpec")):
        var f = _read_field_name(cur, String("MailTransportSpec"))
        if f.text == String("domain"):
            domain = _read_string_value(cur, String("domain"))
        elif f.text == String("identity_ownership"):
            var ow = _read_enum_value(
                cur,
                String("identity_ownership"),
                String("MailIdentityOwnership"),
                mail_identity_ownership_values(),
            )
            identity_ownership = MailIdentityOwnership.from_json_name(ow)
        elif f.text == String("inbound_queue"):
            inbound_queue = _read_string_value(cur, String("inbound_queue"))
        elif f.text == String("inbound_queue_logical_id"):
            inbound_queue_logical_id = _read_string_value(
                cur, String("inbound_queue_logical_id")
            )
        elif f.text == String("dns_records"):
            _open_block(cur, String("dns_records"))
            dns_records.append(_parse_mail_transport_dns_record(cur))
        else:
            var known = List[String]()
            known.append(String("domain"))
            known.append(String("identity_ownership"))
            known.append(String("inbound_queue"))
            known.append(String("inbound_queue_logical_id"))
            known.append(String("dns_records"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("MailTransportSpec"), known
                )
            )
    return MailTransportSpec(
        domain^,
        identity_ownership^,
        inbound_queue^,
        inbound_queue_logical_id^,
        dns_records^,
    )


def _parse_bucket_spec(mut cur: Cursor) raises -> BucketSpec:
    """Parse one `buckets { … }` block into the intent `BucketSpec` (the app-
    provisioned object-store bucket — `AppSpec.buckets`). `name` MAY carry the `${project}` token (resolved by the
    mapper); `storage_class` / `public_access_prevention` default empty (the
    conformer's STANDARD / GCS defaults); `uniform_bucket_level_access` defaults
    false (additive-safe); `object_expiry_days` defaults 0 = the bundle makes NO
    object-lifetime claim (see the proto field — 0 is "unclaimed", never "delete
    immediately"). Mirrors `_parse_secret_binding` — mutable accumulators -> the
    positional generated ctor."""
    var name = String("")
    var location = String("")
    var storage_class = String("")
    var uniform_bucket_level_access = False
    var public_access_prevention = String("")
    var object_expiry_days = Int32(0)
    while not _at_block_end(cur, String("BucketSpec")):
        var f = _read_field_name(cur, String("BucketSpec"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("location"):
            location = _read_string_value(cur, String("location"))
        elif f.text == String("storage_class"):
            storage_class = _read_string_value(cur, String("storage_class"))
        elif f.text == String("uniform_bucket_level_access"):
            uniform_bucket_level_access = _read_bool_value(
                cur, String("uniform_bucket_level_access")
            )
        elif f.text == String("public_access_prevention"):
            public_access_prevention = _read_string_value(
                cur, String("public_access_prevention")
            )
        elif f.text == String("object_expiry_days"):
            # How long an object may live in this bucket before GCS deletes it
            # (one Object Lifecycle rule: Delete at age N days). ABSENT -> 0 ->
            # no lifetime claim, and the composed graph carries no lifecycle rule.
            object_expiry_days = _read_int_value(
                cur, String("object_expiry_days")
            )
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("location"))
            known.append(String("storage_class"))
            known.append(String("uniform_bucket_level_access"))
            known.append(String("public_access_prevention"))
            known.append(String("object_expiry_days"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("BucketSpec"), known
                )
            )
    return BucketSpec(
        name^,
        location^,
        storage_class^,
        uniform_bucket_level_access,
        public_access_prevention^,
        object_expiry_days,
    )


def _parse_secured_inbound_route(mut cur: Cursor) raises -> SecuredInboundRoute:
    """Parse one `secured_inbound_routes { … }` block into a
    `SecuredInboundRoute` (an ADDITIONAL inbound route the EDGE authenticates —
    `AppSpec.secured_inbound_routes`; federated callers).

    Every field's ABSENCE is legal HERE and refused by `validate`: the parser's
    job is to read what was written, and "a secured route with no policy" is a
    semantic refusal that must carry the sentence explaining it, not an
    unknown-field error. Mirrors `_parse_bucket_spec` — mutable accumulators ->
    the positional generated ctor.

    ★ `audience` IS REFUSED BY NAME, not merely absent from the known set. The
    field is reserved, so a bundle that carries one must be told WHY rather than
    told "unknown field" — see the raise below.
    """
    var route_path = String("")
    var policy = EdgeAuthPolicyKind(0)
    var sa_email = String("")
    while not _at_block_end(cur, String("SecuredInboundRoute")):
        var f = _read_field_name(cur, String("SecuredInboundRoute"))
        if f.text == String("route_path"):
            route_path = _read_string_value(cur, String("route_path"))
        elif f.text == String("policy"):
            var p = _read_enum_value(
                cur,
                String("policy"),
                String("EdgeAuthPolicyKind"),
                edge_auth_policy_kind_values(),
            )
            policy = EdgeAuthPolicyKind.from_json_name(p)
        elif f.text == String("sa_email"):
            sa_email = _read_string_value(cur, String("sa_email"))
        elif f.text == String("audience"):
            # ⛔ THE NAMED REFUSAL (proto field 4, reserved).
            raise Error(
                String("line ")
                + String(f.line)
                + String(", col ")
                + String(f.col)
                + String(
                    ": `audience` is no longer an authorable field on"
                    " secured_inbound_routes, and this is a refusal rather than"
                    " an ignore because an ignored value would keep looking like"
                    " the thing in control.\n"
                    "  The accepted `aud` must equal the ORIGIN OF THE EDGE THAT"
                    " SERVES THIS ROUTE — the caller mints its token for the"
                    " scheme+authority of the address it POSTs to. That origin is"
                    " a gateway hostname the cloud generates at Gateway CREATE,"
                    " strictly AFTER the ApiConfig whose document would carry it,"
                    " so any value written here is a guess at a string that does"
                    " not exist yet.\n"
                    "  A wrong guess fails CLOSED and SILENT: the edge answers"
                    " 401 with an empty body and mail simply stops arriving.\n"
                    "  DELETE THIS LINE. The deploy binds the audience from the"
                    " live gateway's own default_hostname, in the same apply, and"
                    " does not serve the route at all until it has read one."
                )
            )
        else:
            var known = List[String]()
            known.append(String("route_path"))
            known.append(String("policy"))
            known.append(String("sa_email"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("SecuredInboundRoute"), known
                )
            )
    return SecuredInboundRoute(route_path^, policy, sa_email^)


# The CLOSED query-scope vocabulary of a bundle-declared index. Two tokens, and
# the parser refuses anything else BY POSITION (`_read_enum_value`'s `did you
# mean` diagnostic) rather than letting the value travel to the cloud. It is a
# `string` on the wire — not a proto enum — because the token spelling is
# deliberately identical to the `DatastoreIndexManifest` textproto spelling, so
# the two forms can be proven equal.
def _index_scope_values() -> List[String]:
    var out = List[String]()
    out.append(String("SCOPE_COLLECTION"))
    out.append(String("SCOPE_COLLECTION_GROUP"))
    return out^


def _parse_index_field(mut cur: Cursor) raises -> BundleIndexField:
    """Parse one `fields { … }` block of a bundle-declared composite index into a
    `BundleIndexField` (`AppSpec.index_tables[].indexes[].fields`).

    Field ABSENCE is legal here and judged by `validate` — the parser's job is to
    read what was written. An UNKNOWN key is NOT legal: a mis-spelled `col` names
    a column that does not exist, and Firestore creates that index without
    complaint, so the mistake is only ever observed as a query that is somehow
    still slow. Mirrors `_parse_secured_inbound_route`."""
    var col = String("")
    var desc = False
    var array_contains = False
    while not _at_block_end(cur, String("BundleIndexField")):
        var f = _read_field_name(cur, String("BundleIndexField"))
        if f.text == String("col"):
            col = _read_string_value(cur, String("col"))
        elif f.text == String("desc"):
            desc = _read_bool_value(cur, String("desc"))
        elif f.text == String("array_contains"):
            array_contains = _read_bool_value(cur, String("array_contains"))
        else:
            var known = List[String]()
            known.append(String("col"))
            known.append(String("desc"))
            known.append(String("array_contains"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("BundleIndexField"), known
                )
            )
    return BundleIndexField(col^, desc, array_contains)


def _parse_index(mut cur: Cursor) raises -> BundleIndex:
    """Parse one `indexes { … }` block into a `BundleIndex` — ONE bundle-declared
    composite index (its stable name + the ORDERED composite key + the query
    scope)."""
    var name = String("")
    var fields = List[BundleIndexField]()
    var scope = String("")
    while not _at_block_end(cur, String("BundleIndex")):
        var f = _read_field_name(cur, String("BundleIndex"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("fields"):
            _open_block(cur, String("fields"))
            fields.append(_parse_index_field(cur))
        elif f.text == String("scope"):
            scope = _read_enum_value(
                cur,
                String("scope"),
                String("IndexScope"),
                _index_scope_values(),
            )
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("fields"))
            known.append(String("scope"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("BundleIndex"), known
                )
            )
    return BundleIndex(name^, fields^, scope^)


def _parse_index_table(mut cur: Cursor) raises -> BundleIndexTable:
    """Parse one `index_tables { … }` block into a `BundleIndexTable` — the
    composite indexes THIS bundle declares for ONE table of the database it OWNS
    (`AppSpec.index_tables`, field 29)."""
    var table = String("")
    var indexes = List[BundleIndex]()
    while not _at_block_end(cur, String("BundleIndexTable")):
        var f = _read_field_name(cur, String("BundleIndexTable"))
        if f.text == String("table"):
            table = _read_string_value(cur, String("table"))
        elif f.text == String("indexes"):
            _open_block(cur, String("indexes"))
            indexes.append(_parse_index(cur))
        else:
            var known = List[String]()
            known.append(String("table"))
            known.append(String("indexes"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("BundleIndexTable"), known
                )
            )
    return BundleIndexTable(table^, indexes^)


def _parse_web_frontend_override(mut cur: Cursor) raises -> WebFrontendOverride:
    """Parse one `web_override { … }` block into a `WebFrontendOverride` — the
    PER-WAVE front-door topology (`Wave.web_override`, field 8).

    ⚠ EVERY FIELD NAME IS THE `AppSpec` SPELLING, VERBATIM, and that is
    deliberate: the wave supplies the env-CORRECT value for a declaration whose
    SHAPE does not change per env, so an author moving a front door out of a
    bundle-level `spec` into a wave moves the lines and changes nothing else. A
    second vocabulary here would be a second thing to learn and a second thing to
    drift.

    ⛔ IT PARSES; IT DOES NOT RULE. The TOTAL-override refusals (spec and
    override may not BOTH author topology; slug/domain/table are required on an
    override) live in `validate_bundle`, beside every other bundle-level rule and
    reachable by every caller that validates without re-parsing. A parser that
    enforced them would also refuse an intermediate document `patch` can
    legitimately produce."""
    var web_slug = String("")
    var web_domain = String("")
    var web_additional_domains = List[String]()
    var web_api_path_prefixes = List[String]()
    var web_api_service_logical_id = String("")
    var web_route_rules = List[WebRouteRule]()
    while not _at_block_end(cur, String("WebFrontendOverride")):
        var f = _read_field_name(cur, String("WebFrontendOverride"))
        if f.text == String("web_slug"):
            web_slug = _read_string_value(cur, String("web_slug"))
        elif f.text == String("web_domain"):
            web_domain = _read_string_value(cur, String("web_domain"))
        elif f.text == String("web_additional_domains"):
            web_additional_domains.append(
                _read_string_value(cur, String("web_additional_domains"))
            )
        elif f.text == String("web_api_path_prefixes"):
            web_api_path_prefixes.append(
                _read_string_value(cur, String("web_api_path_prefixes"))
            )
        elif f.text == String("web_api_service_logical_id"):
            web_api_service_logical_id = _read_string_value(
                cur, String("web_api_service_logical_id")
            )
        elif f.text == String("web_route_rules"):
            _open_block(cur, String("web_route_rules"))
            web_route_rules.append(_parse_web_route_rule(cur))
        else:
            var known = List[String]()
            known.append(String("web_slug"))
            known.append(String("web_domain"))
            known.append(String("web_additional_domains"))
            known.append(String("web_api_path_prefixes"))
            known.append(String("web_api_service_logical_id"))
            known.append(String("web_route_rules"))
            raise Error(
                unknown_field_error(
                    f.line,
                    f.col,
                    f.text,
                    String("WebFrontendOverride"),
                    known,
                )
            )
    return WebFrontendOverride(
        web_slug^,
        web_domain^,
        web_additional_domains^,
        web_api_path_prefixes^,
        web_api_service_logical_id^,
        web_route_rules^,
    )


def _parse_web_route_rule(mut cur: Cursor) raises -> WebRouteRule:
    """Parse one `web_route_rules { … }` block into a `WebRouteRule` (the FULL
    url-map route table — `AppSpec.web_route_rules`). `paths` is the repeated-scalar form (one `paths: "…"` line per element —
    the `web_additional_domains` shape); `backend_role` (a backend name such as `spa` or `api`),
    `error_404_path`, `error_404_code` are optional scalars (empty/0 default).
    Mirrors `_parse_bucket_spec` — mutable accumulators -> the positional ctor."""
    var paths = List[String]()
    var backend_role = String("")
    var error_404_path = String("")
    var error_404_code = Int32(0)
    var disposition = WebRouteDisposition(
        WebRouteDisposition.WEB_ROUTE_DISPOSITION_ROUTE
    )
    var deny_reason = String("")
    while not _at_block_end(cur, String("WebRouteRule")):
        var f = _read_field_name(cur, String("WebRouteRule"))
        if f.text == String("paths"):
            paths.append(_read_string_value(cur, String("paths")))
        elif f.text == String("backend_role"):
            backend_role = _read_string_value(cur, String("backend_role"))
        elif f.text == String("error_404_path"):
            error_404_path = _read_string_value(cur, String("error_404_path"))
        elif f.text == String("error_404_code"):
            error_404_code = Int32(
                _read_int_value(cur, String("error_404_code"))
            )
        elif f.text == String("disposition"):
            var d = _read_enum_value(
                cur,
                String("disposition"),
                String("WebRouteDisposition"),
                web_route_disposition_values(),
            )
            disposition = WebRouteDisposition.from_json_name(d)
        elif f.text == String("deny_reason"):
            deny_reason = _read_string_value(cur, String("deny_reason"))
        else:
            var known = List[String]()
            known.append(String("paths"))
            known.append(String("backend_role"))
            known.append(String("error_404_path"))
            known.append(String("error_404_code"))
            known.append(String("disposition"))
            known.append(String("deny_reason"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("WebRouteRule"), known
                )
            )
    return WebRouteRule(
        paths^,
        backend_role^,
        error_404_path^,
        error_404_code,
        disposition,
        deny_reason^,
    )


def _parse_cloud_variant(mut cur: Cursor) raises -> CloudVariant:
    """Parse ONE `cloud_variants { … }` block into a `CloudVariant`
    (`AppSpec.cloud_variants`, field 36) — the per-CLOUD half of one spec.

    Every member is OPTIONAL inside the block: an absent member leaves the
    spec-level value in place at compose time, so a variant naming only an image
    changes only the image. The parser stores what is authored and JUDGES
    NOTHING — an UNSPECIFIED posture, a duplicate posture and a variant that
    names no member at all are all REFUSED at compose (`compose_api
    .resolve_cloud_variant`), where the sentence explaining each fits and where
    the one reader of the field lives. Two places deciding one rule is how a
    refusal comes to disagree with itself."""
    var cloud = Int32(0)
    var image: Optional[ImageRef] = None
    var ingress: Optional[IngressSpec] = None
    var variant_collections = List[DatastoreCollection]()
    while not _at_block_end(cur, String("CloudVariant")):
        var f = _read_field_name(cur, String("CloudVariant"))
        if f.text == String("cloud"):
            var tok = _read_enum_value(
                cur,
                String("cloud"),
                String("Cloud"),
                cloud_variant_cloud_values(),
            )
            cloud = cloud_variant_cloud_ordinal(tok)
        elif f.text == String("image"):
            _open_block(cur, String("image"))
            image = Optional[ImageRef](_parse_image_ref(cur))
        elif f.text == String("ingress"):
            _open_block(cur, String("ingress"))
            ingress = Optional[IngressSpec](_parse_ingress_spec(cur))
        elif f.text == String("datastore_collections"):
            _open_block(cur, String("datastore_collections"))
            variant_collections.append(_parse_datastore_collection(cur))
        else:
            var known = List[String]()
            known.append(String("cloud"))
            known.append(String("image"))
            known.append(String("ingress"))
            known.append(String("datastore_collections"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("CloudVariant"), known
                )
            )
    return CloudVariant(cloud, image^, ingress^, variant_collections^)


def _parse_ingress_spec(mut cur: Cursor) raises -> IngressSpec:
    """Parse the `ingress { … }` block into `IngressSpec` (`AppSpec.ingress`,
    field 30) — the four ingress REALIZATION inputs the conformer takes. Every
    field's ABSENCE is legal here and means "the default behaviour"; the SEMANTIC refusals (an `ingress {}` on a service
    with no inbound need, an `allUsers` gateway SA) live in `validate`, which is
    where a sentence explaining them fits. Mirrors `_parse_bucket_spec` — mutable
    accumulators -> the positional generated ctor."""
    var gateway_service_account = String("")
    var gateway_region = String("")
    var allowed_sources = List[String]()
    var enable_required_services = False
    var caller_class = EdgeCallerClass(0)
    var peer_identity_audience = String("")
    while not _at_block_end(cur, String("IngressSpec")):
        var f = _read_field_name(cur, String("IngressSpec"))
        if f.text == String("gateway_service_account"):
            gateway_service_account = _read_string_value(
                cur, String("gateway_service_account")
            )
        elif f.text == String("gateway_region"):
            gateway_region = _read_string_value(cur, String("gateway_region"))
        elif f.text == String("allowed_sources"):
            allowed_sources.append(
                _read_string_value(cur, String("allowed_sources"))
            )
        elif f.text == String("enable_required_services"):
            enable_required_services = _read_bool_value(
                cur, String("enable_required_services")
            )
        elif f.text == String("caller_class"):
            var cc = _read_enum_value(
                cur,
                String("caller_class"),
                String("EdgeCallerClass"),
                edge_caller_class_values(),
            )
            caller_class = EdgeCallerClass.from_json_name(cc)
        elif f.text == String("peer_identity_audience"):
            peer_identity_audience = _read_string_value(
                cur, String("peer_identity_audience")
            )
        else:
            var known = List[String]()
            known.append(String("gateway_service_account"))
            known.append(String("gateway_region"))
            known.append(String("allowed_sources"))
            known.append(String("enable_required_services"))
            known.append(String("caller_class"))
            known.append(String("peer_identity_audience"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("IngressSpec"), known
                )
            )
    return IngressSpec(
        gateway_service_account^,
        gateway_region^,
        allowed_sources^,
        enable_required_services,
        caller_class,
        peer_identity_audience^,
    )


def _parse_job_spec(mut cur: Cursor) raises -> JobSpec:
    """Parse one `jobs { … }` block into `JobSpec` (`AppBundle.jobs`, field 12) —
    a run-to-completion container the deploy SHIPS.

    ★ `max_retries` IS proto3-OPTIONAL AND IS READ THAT WAY. An authored
    `max_retries: 0` is a MEANINGFUL demand ("a failure is a verdict, do not
    retry") that is also the proto3 zero, so it is stored as a PRESENT
    `Optional(0)` and an unauthored field stays `None` (the platform default).
    Reading it as a plain Int32 would collapse the two, and the collapse's
    symptom is a gate that silently starts passing on its second attempt.
    Mirrors `_parse_app_spec`'s `keep_last_n` handling.

    NEGATIVE values are refused HERE rather than at validate: a negative retry
    count / timeout is not a semantic disagreement, it is a value the field
    cannot hold, and the position-carrying parse error names the exact token."""
    var name = String("")
    var image: Optional[ImageRef] = None
    var env = List[BundleEnvVar]()
    var secret_bindings = List[SecretBinding]()
    var runtime_identity = String("")
    var max_retries = Optional[Int32]()
    var task_timeout_seconds = Int32(0)
    var region = String("")
    var args = List[String]()
    while not _at_block_end(cur, String("JobSpec")):
        var f = _read_field_name(cur, String("JobSpec"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("image"):
            _open_block(cur, String("image"))
            image = _parse_image_ref(cur)
        elif f.text == String("env"):
            _open_block(cur, String("env"))
            env.append(_parse_bundle_env_var(cur))
        elif f.text == String("secret_bindings"):
            _open_block(cur, String("secret_bindings"))
            secret_bindings.append(_parse_secret_binding(cur))
        elif f.text == String("runtime_identity"):
            runtime_identity = _read_string_value(
                cur, String("runtime_identity")
            )
        elif f.text == String("max_retries"):
            var mr = _read_int_value(cur, String("max_retries"))
            if Int(mr) < 0:
                raise Error(
                    pos_prefix(f.line, f.col)
                    + String(
                        "field 'max_retries' must be >= 0 (it is a COUNT of"
                        " retries after the first attempt; 0 means 'do not"
                        " retry', which is a legal and meaningful value — that"
                        " is why the field is proto3-optional). Omit the field"
                        " for the platform default."
                    )
                )
            max_retries = Optional[Int32](Int32(mr))
        elif f.text == String("task_timeout_seconds"):
            var tt = _read_int_value(cur, String("task_timeout_seconds"))
            if Int(tt) < 0:
                raise Error(
                    pos_prefix(f.line, f.col)
                    + String(
                        "field 'task_timeout_seconds' must be >= 0 (a wall"
                        " budget in SECONDS; 0 means 'the platform default')."
                    )
                )
            task_timeout_seconds = tt
        elif f.text == String("region"):
            region = _read_string_value(cur, String("region"))
        elif f.text == String("args"):
            # ★ REPEATED, so each `args:` line APPENDS in authored order. Order
            # is semantic on an argv and nothing downstream re-sorts it.
            args.append(_read_string_value(cur, String("args")))
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("image"))
            known.append(String("env"))
            known.append(String("secret_bindings"))
            known.append(String("runtime_identity"))
            known.append(String("max_retries"))
            known.append(String("task_timeout_seconds"))
            known.append(String("region"))
            # ⚠ A MISSING ENTRY HERE MAKES A FIELD THE PARSER ACCEPTS INVISIBLE
            # TO `test_emit_completeness`, whose fixture-completeness leg reads
            # THIS LIST out of the refusal message. It is loud rather than
            # silent, but only if the list is right.
            known.append(String("args"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("JobSpec"), known
                )
            )
    return JobSpec(
        name^,
        image^,
        env^,
        secret_bindings^,
        runtime_identity^,
        max_retries^,
        task_timeout_seconds,
        region^,
        args^,
    )


def _parse_execute_job(mut cur: Cursor) raises -> ExecuteJob:
    """Parse an `execute_job { … }` block — the `ValidateStep.check` arm that
    EXECUTES a `AppBundle.jobs[]` job and gates on its exit code. That the named
    job EXISTS is a `validate` refusal, not a parse one: the parser reads one
    block at a time and has not seen the bundle's job list yet."""
    var job = String("")
    var gate_on = GateOn(0)
    while not _at_block_end(cur, String("ExecuteJob")):
        var f = _read_field_name(cur, String("ExecuteJob"))
        if f.text == String("job"):
            job = _read_string_value(cur, String("job"))
        elif f.text == String("gate_on"):
            var g = _read_enum_value(
                cur, String("gate_on"), String("GateOn"), gate_on_values()
            )
            gate_on = GateOn.from_json_name(g)
        else:
            var known = List[String]()
            known.append(String("job"))
            known.append(String("gate_on"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("ExecuteJob"), known
                )
            )
    return ExecuteJob(job^, gate_on)


def _parse_cron_spec(mut cur: Cursor) raises -> CronSpec:
    """Parse one `crons { … }` block into `CronSpec` (`AppBundle.crons`, field
    13) — a scheduled call into a SIBLING service.

    ⛔ `uri` AND `audience` ARE REFUSED BY NAME, not merely absent from the known
    set. Both are the target's serving url, which the cloud assigns at
    service-create; an authored one is a guess at a string that does not exist
    yet, unverifiable offline, and wrong-in-silence (a 403 with an empty body
    behind a green deploy). The same `SecuredInboundRoute.audience` reasoning,
    and the same treatment: say WHY, rather than let the field look ignored."""
    var name = String("")
    var cron = String("")
    var timezone = String("")
    var target: Optional[ServiceRef] = None
    var path = String("")
    var http_method = String("")
    var invoker_identity = String("")
    var attempt_deadline_seconds = Int32(0)
    while not _at_block_end(cur, String("CronSpec")):
        var f = _read_field_name(cur, String("CronSpec"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("cron"):
            cron = _read_string_value(cur, String("cron"))
        elif f.text == String("timezone"):
            timezone = _read_string_value(cur, String("timezone"))
        elif f.text == String("target"):
            _open_block(cur, String("target"))
            target = _parse_service_ref(cur)
        elif f.text == String("path"):
            path = _read_string_value(cur, String("path"))
        elif f.text == String("http_method"):
            http_method = _read_string_value(cur, String("http_method"))
        elif f.text == String("invoker_identity"):
            invoker_identity = _read_string_value(
                cur, String("invoker_identity")
            )
        elif f.text == String("attempt_deadline_seconds"):
            var ad = _read_int_value(cur, String("attempt_deadline_seconds"))
            if Int(ad) < 0:
                raise Error(
                    pos_prefix(f.line, f.col)
                    + String(
                        "field 'attempt_deadline_seconds' must be >= 0 (a"
                        " per-attempt wall budget in SECONDS; 0 means 'the"
                        " platform default')."
                    )
                )
            attempt_deadline_seconds = ad
        elif f.text == String("uri") or f.text == String("audience"):
            raise Error(
                pos_prefix(f.line, f.col)
                + String("field '")
                + f.text
                + String(
                    "' does not exist on CronSpec and deliberately never will."
                    " Its value is the TARGET SERVICE'S SERVING URL, which the"
                    " cloud assigns at service-create with a server-generated"
                    " hash — so any authored form is a GUESS at a string that"
                    " does not exist yet, cannot be checked offline, and fails"
                    " CLOSED AND SILENT when wrong (the scheduler gets a 403"
                    " with an empty body while the deploy reports green, and the"
                    " backstop has stopped ticking with nothing naming it). Name"
                    " the service instead — `target { service: \"<name>\" }`"
                    " plus `path:` — and both the url and the OIDC audience are"
                    " DERIVED from the one observed address by the one formatter"
                    " at apply time."
                )
            )
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("cron"))
            known.append(String("timezone"))
            known.append(String("target"))
            known.append(String("path"))
            known.append(String("http_method"))
            known.append(String("invoker_identity"))
            known.append(String("attempt_deadline_seconds"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("CronSpec"), known
                )
            )
    return CronSpec(
        name^,
        cron^,
        timezone^,
        target^,
        path^,
        http_method^,
        invoker_identity^,
        attempt_deadline_seconds,
    )


def _parse_ephemeral_scope(mut cur: Cursor) raises -> EphemeralScope:
    """Parse the `ephemeral { … }` block into `EphemeralScope`
    (`AppBundle.ephemeral`, field 14) — the bundle's PERMISSION to be deployed and
    destroyed as a throwaway run. The run id is never authored
    (it is per-RUN; a bundle is per-DEPLOY) — `--run-id` supplies it, and this
    block's PRESENCE is what makes that flag legal for this bundle.

    That `keep_overridden_because` is non-empty is a `validate` refusal, not a
    parse one: it is a semantic demand that needs the sentence explaining why
    ignoring a data-protecting retention has to be justified in writing."""
    var keep_overridden_because = String("")
    var max_lifetime_seconds = Int32(0)
    while not _at_block_end(cur, String("EphemeralScope")):
        var f = _read_field_name(cur, String("EphemeralScope"))
        if f.text == String("keep_overridden_because"):
            keep_overridden_because = _read_string_value(
                cur, String("keep_overridden_because")
            )
        elif f.text == String("max_lifetime_seconds"):
            var ml = _read_int_value(cur, String("max_lifetime_seconds"))
            if Int(ml) < 0:
                raise Error(
                    pos_prefix(f.line, f.col)
                    + String(
                        "field 'max_lifetime_seconds' must be >= 0 (the ORPHAN"
                        " BUDGET in SECONDS after which an abandoned run may be"
                        " reaped; 0 means no budget is declared and teardown is"
                        " the caller's obligation alone)."
                    )
                )
            max_lifetime_seconds = ml
        else:
            var known = List[String]()
            known.append(String("keep_overridden_because"))
            known.append(String("max_lifetime_seconds"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("EphemeralScope"), known
                )
            )
    return EphemeralScope(keep_overridden_because^, max_lifetime_seconds)


def _parse_validate_vpc_egress(mut cur: Cursor) raises -> ValidateVpcEgress:
    """Parse the `vpc_egress { … }` block into `ValidateVpcEgress`
    (`RunContainer.vpc_egress`, field 7) — the DIRECT VPC EGRESS attachment this
    validate step's Cloud Run JOB carries.

    ⛔ THE BLOCK'S PRESENCE IS THE WHOLE SIGNAL, AND ITS ABSENCE IS NOT NEUTRAL.
    A Cloud Run Job with no network configuration egresses over the PUBLIC
    INTERNET, so it cannot reach a service whose ingress is
    `internal-and-cloud-load-balancing` — that peer refuses it at the edge, before
    the container, and the probe reads Google's HTML 404 as an application 404.
    This block is the syntax in which reaching such a peer can be stated.

    ⚠ AUTHORING IT SELECTS, IT DOES NOT CREATE. The deploy composes no network,
    subnet, connector, Cloud Router or NAT from this — the names must already
    resolve, and one that does not fails CLOSED at the CreateJob RPC.

    The SEMANTIC refusal (a block naming only one of network / subnetwork) lives
    in `validate`, which is where the sentence explaining it fits. Mirrors
    `_parse_ingress_spec` — mutable accumulators -> the positional generated
    ctor."""
    var network = String("")
    var subnetwork = String("")
    var network_tags = List[String]()
    var private_ranges_only = False
    while not _at_block_end(cur, String("ValidateVpcEgress")):
        var f = _read_field_name(cur, String("ValidateVpcEgress"))
        if f.text == String("network"):
            network = _read_string_value(cur, String("network"))
        elif f.text == String("subnetwork"):
            subnetwork = _read_string_value(cur, String("subnetwork"))
        elif f.text == String("network_tags"):
            network_tags.append(_read_string_value(cur, String("network_tags")))
        elif f.text == String("private_ranges_only"):
            private_ranges_only = _read_bool_value(
                cur, String("private_ranges_only")
            )
        else:
            var known = List[String]()
            known.append(String("network"))
            known.append(String("subnetwork"))
            known.append(String("network_tags"))
            known.append(String("private_ranges_only"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("ValidateVpcEgress"), known
                )
            )
    return ValidateVpcEgress(
        network^, subnetwork^, network_tags^, private_ranges_only
    )


def _parse_test_role(mut cur: Cursor) raises -> TestRole:
    """Parse a `test_role { … }` block into `TestRole` (`RunContainer.test_role`,
    field 9) — ONE EPHEMERAL KOMIRA CALLER IDENTITY this validate step
    presents to the app under test.

    ⛔ NOTHING HERE IS A CREDENTIAL, AND THAT IS THE SHAPE. Five of the nine
    fields are FLAG NAMES; the values those flags carry are RESOLVED at deploy
    time (the caller's deployment id, a secret HANDLE, an org id, an issuer, and
    the TARGET deployment the role is granted on) and the private scalar is
    fetched by the validator under its own identity. `argv` is
    world-readable, which is why `AppParameter.secret_ref` is refused on a
    validate-step arg and why no spelling here can carry key material.

    EVERY semantic refusal lives in `validate` — a role whose org is the reserved
    Komira org, whose `grants_on_service` names no declared service, whose `level`
    is UNSPECIFIED, that duplicates a sibling's name or flag, or that sits on a
    bundle which is not `TENANCY_CONTROL_PLANE`. The parser's job is lexical: it
    knows nothing about the enclosing bundle, so a rule stated here would either
    be unstateable or would have to guess. Mirrors `_parse_validate_vpc_egress` —
    mutable accumulators -> the positional generated ctor."""
    var name = String("")
    var org_id = String("")
    var grants_on_service = String("")
    var level = TestRoleLevel(0)
    var deployment_id_flag = String("")
    var identity_secret_flag = String("")
    var org_id_flag = String("")
    var issuer_flag = String("")
    # ★ `granted_on_flag` (field 9) — the flag the TARGET deployment renders
    # onto. A DIFFERENT value from `deployment_id_flag`: that one is the CALLER's
    # minted id, this one is the deployment the caller was granted ON.
    var granted_on_flag = String("")
    while not _at_block_end(cur, String("TestRole")):
        var f = _read_field_name(cur, String("TestRole"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("org_id"):
            org_id = _read_string_value(cur, String("org_id"))
        elif f.text == String("grants_on_service"):
            grants_on_service = _read_string_value(
                cur, String("grants_on_service")
            )
        elif f.text == String("level"):
            var lv = _read_enum_value(
                cur,
                String("level"),
                String("TestRoleLevel"),
                test_role_level_values(),
            )
            level = TestRoleLevel.from_json_name(lv)
        elif f.text == String("deployment_id_flag"):
            deployment_id_flag = _read_string_value(
                cur, String("deployment_id_flag")
            )
        elif f.text == String("identity_secret_flag"):
            identity_secret_flag = _read_string_value(
                cur, String("identity_secret_flag")
            )
        elif f.text == String("org_id_flag"):
            org_id_flag = _read_string_value(cur, String("org_id_flag"))
        elif f.text == String("issuer_flag"):
            issuer_flag = _read_string_value(cur, String("issuer_flag"))
        elif f.text == String("granted_on_flag"):
            granted_on_flag = _read_string_value(cur, String("granted_on_flag"))
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("org_id"))
            known.append(String("grants_on_service"))
            known.append(String("level"))
            known.append(String("deployment_id_flag"))
            known.append(String("identity_secret_flag"))
            known.append(String("org_id_flag"))
            known.append(String("issuer_flag"))
            known.append(String("granted_on_flag"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("TestRole"), known
                )
            )
    return TestRole(
        name^,
        org_id^,
        grants_on_service^,
        level,
        deployment_id_flag^,
        identity_secret_flag^,
        org_id_flag^,
        issuer_flag^,
        granted_on_flag^,
    )


def _parse_run_container(mut cur: Cursor) raises -> RunContainer:
    var image: Optional[ImageRef] = None
    var gate_on = GateOn(0)
    var env = List[BundleEnvVar]()
    # `reads_secret` — the Secret Manager secret NAMES this step's container
    # fetches for itself. One `reads_secret: "…"` line per
    # element — the `allowed_sources` / `web_additional_domains` repeated-scalar
    # shape, NOT a block.
    var reads_secret = List[String]()
    # ★ `args` — the ARGV this validator's entrypoint receives (field 5).
    # `repeated AppParameter`, so it is a BLOCK per entry and it
    # reuses `_parse_app_parameter` verbatim — the same message, the same flag
    # derivation, the same `required` semantics as `AppSpec.parameters`. Authored
    # ORDER is load-bearing: the argv render walks this list in order, so a
    # re-emission must not reorder it (`_emit_run_container` does not sort).
    var args = List[AppParameter]()
    # ★ `runtime_identity` — the SA email this step's JOB runs as (field 6). A
    # plain scalar string, not a block. EMPTY => the deploy SA.
    var runtime_identity = String("")
    # ★ `vpc_egress` — the DIRECT VPC EGRESS attachment this step's JOB carries
    # (field 7). A BLOCK, and ABSENT by default: no block => no
    # `vpcAccess` on the CreateJob wire => the job egresses over the PUBLIC
    # INTERNET and cannot reach a private-ingress peer. That default is
    # byte-identical to every step authored before the field existed.
    var vpc_egress: Optional[ValidateVpcEgress] = None
    # ★ `reads_telemetry` — the read-only observability planes this step's
    # container queries for itself (field 8). One
    # `reads_telemetry: TELEMETRY_READ_*` line per element — the repeated-scalar
    # shape `reads_secret` uses, NOT a block. EMPTY => no grant node composed.
    var reads_telemetry = List[TelemetryRead]()
    # ★ `test_role` — the EPHEMERAL KOMIRA CALLER IDENTITIES this step presents to
    # the app under test (field 9). A BLOCK per entry, in AUTHORED
    # ORDER (the argv render walks the list in order, so a re-emission must not
    # reorder it — `_emit_run_container` does not sort). EMPTY => nothing is
    # provisioned, nothing is revoked and no flag is rendered, which is
    # byte-identical to every step authored before the field existed.
    var test_role = List[TestRole]()
    # ⭐ `own_identity` (field 10) — the SA ACCOUNT ID this
    # step OWNS (declared here, created by the deploy graph). A plain scalar.
    # EMPTY => byte-identical. Refused by `validate_bundle` while it is declared
    # but not yet honoured.
    var own_identity = String("")
    while not _at_block_end(cur, String("RunContainer")):
        var f = _read_field_name(cur, String("RunContainer"))
        if f.text == String("image"):
            _open_block(cur, String("image"))
            image = _parse_image_ref(cur)
        elif f.text == String("gate_on"):
            var g = _read_enum_value(
                cur, String("gate_on"), String("GateOn"), gate_on_values()
            )
            gate_on = GateOn.from_json_name(g)
        elif f.text == String("env"):
            _open_block(cur, String("env"))
            env.append(_parse_bundle_env_var(cur))
        elif f.text == String("reads_secret"):
            reads_secret.append(
                _read_string_value(cur, String("reads_secret"))
            )
        elif f.text == String("args"):
            _open_block(cur, String("args"))
            args.append(_parse_app_parameter(cur))
        elif f.text == String("runtime_identity"):
            runtime_identity = _read_string_value(
                cur, String("runtime_identity")
            )
        elif f.text == String("vpc_egress"):
            _open_block(cur, String("vpc_egress"))
            vpc_egress = Optional[ValidateVpcEgress](
                _parse_validate_vpc_egress(cur)
            )
        elif f.text == String("reads_telemetry"):
            var tr = _read_enum_value(
                cur,
                String("reads_telemetry"),
                String("TelemetryRead"),
                telemetry_read_values(),
            )
            reads_telemetry.append(TelemetryRead.from_json_name(tr))
        elif f.text == String("test_role"):
            _open_block(cur, String("test_role"))
            test_role.append(_parse_test_role(cur))
        elif f.text == String("own_identity"):
            own_identity = _read_string_value(cur, String("own_identity"))
        else:
            var known = List[String]()
            known.append(String("image"))
            known.append(String("gate_on"))
            known.append(String("env"))
            known.append(String("reads_secret"))
            known.append(String("args"))
            known.append(String("runtime_identity"))
            known.append(String("vpc_egress"))
            known.append(String("reads_telemetry"))
            known.append(String("test_role"))
            known.append(String("own_identity"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("RunContainer"), known
                )
            )
    return RunContainer(
        image^,
        gate_on,
        env^,
        reads_secret^,
        args^,
        runtime_identity^,
        vpc_egress^,
        reads_telemetry^,
        test_role^,
        own_identity^,
    )


def _parse_validate_step(mut cur: Cursor) raises -> ValidateStep:
    var name = String("")
    var arm = 0
    var depends_on = List[String]()
    var excluded_because = String("")
    # ★ THE SERVICE AXIS (field 7). WHICH service this step is ABOUT — the
    # subject of every SELF-scoped resolution it performs (the `http_check` host;
    # the `VALUE_FROM_DEPLOY_URL` its `run_container` env/args resolve). EMPTY is
    # the proto3 default and the round-trip-stable one, so a single-service
    # bundle parses and re-emits byte-identically.
    var service = String("")
    var http_check: Optional[HttpCheck] = None
    var run_container: Optional[RunContainer] = None
    # The THIRD check arm: execute a `AppBundle.jobs[]` job and
    # gate on its exit code. Arm index 3 (the generated `_oneof0_case` is the
    # 1-based ARM POSITION, not the field number).
    var execute_job: Optional[ExecuteJob] = None
    while not _at_block_end(cur, String("ValidateStep")):
        var f = _read_field_name(cur, String("ValidateStep"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("excluded_because"):
            # The EXCLUSION MARKER with its reason welded on: a NON-EMPTY value
            # excludes the step from a resolved RUN of the set, and the value IS
            # the justification (there is no way to exclude without writing one).
            # Absent ⇒ empty ⇒ the step runs, so every pre-exclusion bundle parses
            # and re-emits unchanged.
            excluded_because = _read_string_value(
                cur, String("excluded_because")
            )
        elif f.text == String("service"):
            # ★ WHICH SERVICE THIS STEP'S `SELF` MEANS. Only meaningful in a
            # bundle that declares more than one served service; `validate.mojo`
            # refuses a name that matches no declared service, and the driver
            # refuses an UNQUALIFIED step in a multi-service bundle rather than
            # silently probing the first one.
            service = _read_string_value(cur, String("service"))
        elif f.text == String("depends_on"):
            # A repeated string — each `depends_on: "<step>"` line names ONE
            # in-wave step this step waits on (a step-DAG edge). Appends;
            # an absent field leaves depends_on empty (an independent step).
            depends_on.append(_read_string_value(cur, String("depends_on")))
        elif f.text == String("http_check"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("ValidateStep.check"),
                        _check_arm_name(arm), String("http_check"),
                    )
                )
            _open_block(cur, String("http_check"))
            http_check = _parse_http_check(cur)
            arm = 1
        elif f.text == String("run_container"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("ValidateStep.check"),
                        _check_arm_name(arm), String("run_container"),
                    )
                )
            _open_block(cur, String("run_container"))
            run_container = _parse_run_container(cur)
            arm = 2
        elif f.text == String("execute_job"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("ValidateStep.check"),
                        _check_arm_name(arm), String("execute_job"),
                    )
                )
            _open_block(cur, String("execute_job"))
            execute_job = _parse_execute_job(cur)
            arm = 3
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("depends_on"))
            known.append(String("excluded_because"))
            known.append(String("http_check"))
            known.append(String("run_container"))
            known.append(String("execute_job"))
            known.append(String("service"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("ValidateStep"), known
                )
            )
    return ValidateStep(
        name^,
        depends_on^,
        excluded_because^,
        service^,
        arm,
        http_check^,
        run_container^,
        execute_job^,
    )


def _parse_wave(mut cur: Cursor) raises -> Wave:
    var env = String("")
    var validate = List[ValidateStep]()
    # The PER-WAVE api-edge staging toggle — default OFF (the edge is opt-in per
    # wave, so it can be staged one environment at a time).
    var api_edge_enabled = False
    # The PER-WAVE env-var overrides (field 4) — the per-ENV deploy config that is
    # NOT `${project}`-derivable (bootstrap OAuth client id + vanity callback host).
    # Each `env_override { name: value: }` block reuses `_parse_bundle_env_var` (the
    # SAME shape as a spec-level `env {}`). EMPTY (the default) ⇒ byte-identical.
    var env_override = List[BundleEnvVar]()
    # The PER-WAVE PARAMETER overrides (field 5) — the per-ENV parameter BINDING.
    # Mirrors `env_override` exactly: the spec-level `parameters` entry holds the
    # env-NEUTRAL declaration (type / required / description / constraints), an
    # entry here supplies the env-CORRECT value. EMPTY ⇒ byte-identical.
    var parameter_override = List[AppParameter]()
    # The PER-ENV control plane this env's PEER-ONLY edges trust (field 6) and
    # the PER-ENV authenticated developer-access principal (field 7). Both EMPTY
    # by default ⇒ byte-identical composition; the second is refused outright by
    # `compose_api` for any env not on the eligibility allow-list.
    var peer_identity_issuer = String("")
    var developer_access_principal = String("")
    # The PER-WAVE web front-door TOPOLOGY (field 8) — the one field that lets a
    # single bundle carry two environments' front doors. ABSENT (the default) ⇒
    # the bundle-level `spec.web_*` stands ⇒ byte-identical compose for every
    # bundle authored before it existed. ⚠ `Optional` and not an empty message:
    # "no override" and "an override authoring nothing" are DIFFERENT documents,
    # and the second is a refusal (`validate_bundle`), not a fallback.
    var web_override = Optional[WebFrontendOverride]()
    # ⭐ THE PER-SERVICE API-EDGE ALLOW-LIST (field 9). One
    # `api_edge_services: "…"` line per element — the repeated-scalar shape.
    # EMPTY ⇒ byte-identical. Refused by `validate_bundle` while it is declared
    # but not yet honoured.
    var api_edge_services = List[String]()
    while not _at_block_end(cur, String("Wave")):
        var f = _read_field_name(cur, String("Wave"))
        if f.text == String("env"):
            env = _read_string_value(cur, String("env"))
        elif f.text == String("validate"):
            _open_block(cur, String("validate"))
            validate.append(_parse_validate_step(cur))
        elif f.text == String("api_edge_enabled"):
            api_edge_enabled = _read_bool_value(cur, String("api_edge_enabled"))
        elif f.text == String("env_override"):
            _open_block(cur, String("env_override"))
            # ★ THE ONE SITE THAT MAY CARRY A `service:` AXIS (field 5). Every
            # other `_parse_bundle_env_var` caller takes the default and refuses
            # it — see that function's header.
            env_override.append(_parse_bundle_env_var(cur, allow_service=True))
        elif f.text == String("parameter_override"):
            _open_block(cur, String("parameter_override"))
            parameter_override.append(_parse_app_parameter(cur))
        elif f.text == String("peer_identity_issuer"):
            peer_identity_issuer = _read_string_value(
                cur, String("peer_identity_issuer")
            )
        elif f.text == String("developer_access_principal"):
            developer_access_principal = _read_string_value(
                cur, String("developer_access_principal")
            )
        elif f.text == String("web_override"):
            _open_block(cur, String("web_override"))
            # ⛔ SINGULAR, NOT REPEATED. A second `web_override {}` in one wave
            # would mean two front doors for one environment, which the composer
            # has no way to pick between — so the SECOND one is a refusal here
            # rather than a silent last-wins. Last-wins is how a reviewer reads
            # the first block and ships the second.
            if web_override:
                raise Error(
                    String(
                        "line "
                    )
                    + String(f.line)
                    + String(
                        ": a Wave may author at most ONE `web_override` block —"
                        " a second one would declare a second front door for the"
                        " same environment, and nothing can choose between them."
                        " Merge the two blocks."
                    )
                )
            web_override = Optional[WebFrontendOverride](
                _parse_web_frontend_override(cur)
            )
        elif f.text == String("api_edge_services"):
            api_edge_services.append(
                _read_string_value(cur, String("api_edge_services"))
            )
        else:
            var known = List[String]()
            known.append(String("env"))
            known.append(String("validate"))
            known.append(String("api_edge_enabled"))
            known.append(String("env_override"))
            known.append(String("parameter_override"))
            known.append(String("peer_identity_issuer"))
            known.append(String("developer_access_principal"))
            known.append(String("web_override"))
            known.append(String("api_edge_services"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("Wave"), known)
            )
    return Wave(
        env^,
        validate^,
        api_edge_enabled,
        env_override^,
        parameter_override^,
        peer_identity_issuer^,
        developer_access_principal^,
        web_override^,
        api_edge_services^,
    )


# ─── The reshape — named validation SETS + the
#     pipeline-STEP authoring surface. A validation set REUSES `_parse_validate_step`
#     (http_check | run_container), so a scripted `run_container` integration flow is
#     a first-class member. A pipeline step is `{step_kind, env(s), set ref(s)}`. ──
def _parse_validation_set(mut cur: Cursor) raises -> ValidationSet:
    """Parse one `validation_sets { name: "…" steps { <ValidateStep> } … }` block:
    a NAMED list of validation steps, defined once + referenced by name (NOT welded
    to an env). Each `steps { … }` reuses `_parse_validate_step` (the SAME shape a
    `Wave.validate` step carries)."""
    var name = String("")
    var steps = List[ValidateStep]()
    var env_policy = ValidationSetEnvPolicy(0)
    var envs = List[String]()
    while not _at_block_end(cur, String("ValidationSet")):
        var f = _read_field_name(cur, String("ValidationSet"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("steps"):
            _open_block(cur, String("steps"))
            steps.append(_parse_validate_step(cur))
        elif f.text == String("env_policy"):
            var k = _read_enum_value(
                cur,
                String("env_policy"),
                String("ValidationSetEnvPolicy"),
                validation_set_env_policy_values(),
            )
            env_policy = ValidationSetEnvPolicy.from_json_name(k)
        elif f.text == String("envs"):
            envs.append(_read_string_value(cur, String("envs")))
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("steps"))
            known.append(String("env_policy"))
            known.append(String("envs"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("ValidationSet"), known
                )
            )
    return ValidationSet(name^, steps^, env_policy, envs^)


def _parse_pipeline_step(mut cur: Cursor) raises -> PipelineStep:
    """Parse one `steps { step_kind: … envs: "…" validation_set_refs: "…"
    matrix_ref: "…" }` block — a single pipeline STEP: the `step_kind` (the verb
    it performs), the target `envs` (repeated-scalar, one line per env), the
    `validation_set_refs` (repeated-scalar, each naming a `ValidationSet.name`),
    and the optional `matrix_ref` (names an `AppBundle.matrices[].name` — the
    device/capability matrix this step fans over; the parser reads it,
    validate.mojo fail-closes it, and the deploy emits the cell fan)."""
    var step_kind = StepKind(0)
    var envs = List[String]()
    var validation_set_refs = List[String]()
    var matrix_ref = String("")
    while not _at_block_end(cur, String("PipelineStep")):
        var f = _read_field_name(cur, String("PipelineStep"))
        if f.text == String("step_kind"):
            var k = _read_enum_value(
                cur, String("step_kind"), String("StepKind"), step_kind_values()
            )
            step_kind = StepKind.from_json_name(k)
        elif f.text == String("envs"):
            envs.append(_read_string_value(cur, String("envs")))
        elif f.text == String("validation_set_refs"):
            validation_set_refs.append(
                _read_string_value(cur, String("validation_set_refs"))
            )
        elif f.text == String("matrix_ref"):
            matrix_ref = _read_string_value(cur, String("matrix_ref"))
        else:
            var known = List[String]()
            known.append(String("step_kind"))
            known.append(String("envs"))
            known.append(String("validation_set_refs"))
            known.append(String("matrix_ref"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("PipelineStep"), known
                )
            )
    return PipelineStep(step_kind, envs^, validation_set_refs^, matrix_ref^)


def _parse_pipeline(mut cur: Cursor) raises -> Pipeline:
    """Parse the `pipeline { steps { <PipelineStep> } … }` block — the ORDERED list
    of pipeline steps."""
    var steps = List[PipelineStep]()
    while not _at_block_end(cur, String("Pipeline")):
        var f = _read_field_name(cur, String("Pipeline"))
        if f.text == String("steps"):
            _open_block(cur, String("steps"))
            steps.append(_parse_pipeline_step(cur))
        else:
            var known = List[String]()
            known.append(String("steps"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("Pipeline"), known)
            )
    return Pipeline(steps^)


def _parse_matrix_cell(mut cur: Cursor) raises -> MatrixCell:
    """Parse one `cell { name: … os: … arch: … artifact_kind: … os_version_min: …
    os_version_max: … from_build: … browser: … }` block — a single MATRIX CELL
    (all-string fields; mirrors `_parse_build_target`'s scalar-field shape). A
    NATIVE cell sets `from_build`; a WEB cell sets `browser` (the native-XOR-web
    invariant is enforced in validate.mojo, not here — the parse is purely
    structural)."""
    var name = String("")
    var os = String("")
    var arch = String("")
    var artifact_kind = String("")
    var os_version_min = String("")
    var os_version_max = String("")
    var from_build = String("")
    var browser = String("")
    while not _at_block_end(cur, String("MatrixCell")):
        var f = _read_field_name(cur, String("MatrixCell"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("os"):
            os = _read_string_value(cur, String("os"))
        elif f.text == String("arch"):
            arch = _read_string_value(cur, String("arch"))
        elif f.text == String("artifact_kind"):
            artifact_kind = _read_string_value(cur, String("artifact_kind"))
        elif f.text == String("os_version_min"):
            os_version_min = _read_string_value(cur, String("os_version_min"))
        elif f.text == String("os_version_max"):
            os_version_max = _read_string_value(cur, String("os_version_max"))
        elif f.text == String("from_build"):
            from_build = _read_string_value(cur, String("from_build"))
        elif f.text == String("browser"):
            browser = _read_string_value(cur, String("browser"))
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("os"))
            known.append(String("arch"))
            known.append(String("artifact_kind"))
            known.append(String("os_version_min"))
            known.append(String("os_version_max"))
            known.append(String("from_build"))
            known.append(String("browser"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("MatrixCell"), known
                )
            )
    return MatrixCell(
        name^,
        os^,
        arch^,
        artifact_kind^,
        os_version_min^,
        os_version_max^,
        from_build^,
        browser^,
    )


def _parse_matrix(mut cur: Cursor) raises -> Matrix:
    """Parse one `matrices { name: "…" cell { <MatrixCell> } … }` block — a NAMED
    device/capability matrix (referenced by a `PipelineStep.matrix_ref`). Mirrors
    `_parse_pipeline`/`_parse_validation_set`: a `name` scalar + repeated `cell {}`
    sub-blocks."""
    var name = String("")
    var cells = List[MatrixCell]()
    while not _at_block_end(cur, String("Matrix")):
        var f = _read_field_name(cur, String("Matrix"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("cell"):
            _open_block(cur, String("cell"))
            cells.append(_parse_matrix_cell(cur))
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("cell"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("Matrix"), known)
            )
    return Matrix(name^, cells^)


def _parse_deploy_output(mut cur: Cursor) raises -> DeployOutput:
    """Parse one `outputs { name: "…" from_served: "…" }` block — a named DEPLOY
    OUTPUT. All-string fields (mirrors
    `_parse_matrix_cell`'s scalar shape). The parse is purely structural; the
    fail-closed checks (`from_served` names a real served node; unique name) live
    in validate.mojo."""
    var name = String("")
    var from_served = String("")
    while not _at_block_end(cur, String("DeployOutput")):
        var f = _read_field_name(cur, String("DeployOutput"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("from_served"):
            from_served = _read_string_value(cur, String("from_served"))
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("from_served"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("DeployOutput"), known
                )
            )
    return DeployOutput(name^, from_served^)


def _parse_app_spec(mut cur: Cursor) raises -> AppSpec:
    var image: Optional[ImageRef] = None
    var port = Int32(0)
    var env = List[BundleEnvVar]()
    var scaling: Optional[Scaling] = None
    var compute = ComputeIntent(0)
    var datastore = DatastoreNeed(0)
    var secret_bindings = List[SecretBinding]()
    var runtime_identity = String("")
    # STATIC_FRONTEND authoring (AppSpec fields 13-17). The repeated string fields use the repeated-scalar form
    # (one `web_additional_domains: "…"` line per element — the depends_on
    # shape, NOT `[...]`).
    var web_slug = String("")
    var web_domain = String("")
    var web_additional_domains = List[String]()
    var web_api_path_prefixes = List[String]()
    var web_api_service_logical_id = String("")
    # API-EDGE authoring (AppSpec fields 18-19).
    var inbound = InboundNeed(0)
    var inbound_route_path = String("")
    # ★ THE NETWORK REACH (AppSpec field 32). UNSPECIFIED (the
    # default) => the deploy stamps NOTHING, so every bundle that authors no
    # `network_ingress` composes byte-identically. It does NOT mean private: the
    # unstamped Cloud Run default is public reach.
    var network_ingress = NetworkIngress(0)
    # ★ THE SERVED SERVICE'S OUTBOUND PATH (AppSpec field 33) — the `network_
    # ingress` SIBLING, and the other half of a private-ingress topology. ABSENT
    # (the default) => no `vpc_access` on the
    # create/update body => the revision egresses over the PUBLIC INTERNET and a
    # peer with `internal-and-cloud-load-balancing` ingress refuses it AT THE
    # EDGE. Byte-identical to a bundle that does not author it.
    #
    # REUSES `ValidateVpcEgress` — the same message `RunContainer.vpc_egress`
    # (field 7) carries for a validate step's JOB, and the same
    # `_parse_validate_vpc_egress` below parses it. One Cloud Run concept, one
    # spelling, one parser: a second message would mean a fix to one scope
    # silently missing the other.
    var network_egress: Optional[ValidateVpcEgress] = None
    # ★ THE MAIL-TRANSPORT SPINE (field 34) — the domain identity, the inbound
    # queue and the DNS records that prove the domain. ABSENT (the default) ⇒ NO mail-transport node is composed and
    # the manifest is byte-identical.
    var mail_transport: Optional[MailTransportSpec] = None
    # ★ THE COLLECTION SHAPES THIS APP'S DATASTORE HOLDS (field 35). Repeated
    # `datastore_collections { … }` blocks — one `DatastoreCollection` each,
    # appended in AUTHORED ORDER and never sorted (the composed manifest's
    # content address is a hash over these bytes, so a re-ordering parser churns
    # a new address for no change). EMPTY (the default) ⇒ the composed
    # `DatastoreSpec.collections` is empty, byte-identical to a bundle without
    # the field.
    var datastore_collections = List[DatastoreCollection]()
    # ★ THE PER-CLOUD SPEC VARIANTS (field 36). Repeated `cloud_variants { … }`
    # blocks — one `CloudVariant` each, appended in AUTHORED ORDER. EMPTY (the
    # default) ⇒ no variant is selected on any cloud ⇒ the spec-level
    # declarations stand ⇒ byte-identical compose and re-emit.
    var cloud_variants = List[CloudVariant]()
    # ★ THE MANAGED-APP PARAMETERS (field 31) — the typed input contract. EMPTY
    # (the default) ⇒ no argv token, no refusal, byte-identical compose, which is
    # what lets bundles migrate ONE AT A TIME.
    var parameters = List[AppParameter]()
    # APP-PROVISIONED BUCKETS (AppSpec field 20). Repeated `buckets { … }` blocks — one BucketSpec each.
    var buckets = List[BucketSpec]()
    # EXTRA runtime capability ordinals (AppSpec field 21). Repeated scalar form
    # (one `runtime_extra_capabilities: <ordinal>` line per element — the
    # `web_additional_domains` shape). A raw `Capability` ordinal (int).
    var runtime_extra_capabilities = List[Int32]()
    # FULL url-map route table (AppSpec field 22).
    # Repeated `web_route_rules { … }` blocks — one WebRouteRule each.
    var web_route_rules = List[WebRouteRule]()
    # PER-BUNDLE DEPLOY-REGION OVERRIDE (AppSpec field 23). Empty
    # (the default) => the effective deploy region is the `--env` binding's region;
    # non-empty => it OVERRIDES the env default region for THIS bundle at
    # every apply site.
    var region = String("")
    # ★ HOW THE SERVICE NAME RELATES TO THE BUNDLE NAME (AppSpec field 37).
    # UNSPECIFIED (the default) => the authored `name` IS the service name. REGIONAL => `name` is a BASE name and the service name is
    # composed from the DEPLOY TARGET (`regional_service_name(base, cloud,
    # region)`) — one cloud-agnostic bundle, N derived names.
    var name_scope = NameScope(NameScope.NAME_SCOPE_UNSPECIFIED)
    # PUBLIC (allUsers) INVOKER (AppSpec field 24).
    # False (the default) => the served node stays PRIVATE (scoped run.invoker only,
    # byte-identical to every existing bundle); true => compose emits ONE allUsers
    # run.invoker grant on this service's own served node (for a service dialed
    # directly by browsers, which have no OIDC to present).
    var public_invoker = False
    # RETENTION (AppSpec field 25; keep-last-N Cloud Run revisions, lazy prune-at-
    # deploy). UNSET (None) => the deploy mapper applies the default (5); an
    # authored `keep_last_n: N` sets it (proto3-optional presence). additive-safe.
    var keep_last_n = Optional[Int32]()
    # EDGE-SECURED ADDITIONAL ROUTES (AppSpec field 26; federated callers).
    # Repeated `secured_inbound_routes { … }` blocks — one
    # `SecuredInboundRoute` each. EMPTY (the default) => no secured route is
    # composed (byte-identical to a bundle authored before this field existed).
    var secured_inbound_routes = List[SecuredInboundRoute]()
    # THE DATASTORE'S DATABASE NAME (AppSpec field 27 — "people
    # should pick their name in the config"). EMPTY (the default) is a VALIDATE
    # ERROR for a service declaring `datastore: SERVERLESS/DEDICATED`, never a
    # silently-substituted `control-plane` — see `validate._check_datastore_database`.
    var datastore_database = String("")
    # THE DATABASE THIS SERVICE OPENS BUT DOES NOT OWN (AppSpec field 28; the
    # reference-not-own concept). MUTUALLY EXCLUSIVE with
    # `datastore_database` above — both set, or neither on a datastore-bearing
    # service, is refused by `datastore_identity.resolve_datastore_identity`, the ONE
    # reader of the pair. The parser stores both verbatim and judges neither; the
    # policy has exactly one home.
    var datastore_database_ref = String("")
    # THE INDEX SHAPES THIS APP'S OWN DATABASE NEEDS (AppSpec field 29 — an
    # app's indexes live on that app's own database). Repeated `index_tables
    # { … }` blocks — one BundleIndexTable each. EMPTY (the default) => the
    # bundle declares no shape and the ensure step falls back to whatever the
    # control plane declares for the database. Legal ONLY on a bundle that OWNS its database — `validate`
    # refuses it alongside `datastore_database_ref`.
    var index_tables = List[BundleIndexTable]()
    # The INGRESS REALIZATION INPUTS (field 30) — None when the
    # bundle authors no `ingress {}` block, which is the default behaviour on
    # every path (the project-global gateway SA, the conformer's placement policy, no
    # allow-list, the ingress services a bootstrap prerequisite).
    var ingress: Optional[IngressSpec] = None
    # ★ THE APP'S OWN COMPUTE ALLOCATION (AppSpec fields 38-39).
    # Kubernetes quantity strings ("1000m" / "512Mi") — the SAME vocabulary
    # `Job.cpu`, `ContainerSpec.cpu` and `GcpResource.cpu` (#17) all speak, so the
    # declared value hands through with no conversion.
    #
    # ⛔ PRESENCE-TYPED, AND THE PARSER JUDGES NOTHING. `None` means the bundle
    # OMITTED the field; `Some("")` means the bundle AUTHORED an empty quantity.
    # Those are different facts and the two-state Optional is the only thing that
    # can carry the difference to the ONE place that judges it (`compose_api.
    # _authored_cpu` / `_authored_memory`, which REFUSES the authored-empty
    # spelling by name and carries an omission through as absent). A parser that
    # collapsed them would make that refusal unreachable and turn "" into a value
    # a bill would carry.
    var app_cpu = Optional[String]()
    var app_memory = Optional[String]()
    # ★★ THE APP'S HEALTHCHECK ENDPOINT (AppSpec field 40) — the
    # path the JOB MANAGER probes from OUTSIDE the container, across the ingress,
    # to decide whether a PROVISIONING `gcp_resource` row may become ACTIVE.
    #
    # ⛔ PRESENCE-TYPED, AND THE PARSER JUDGES NOTHING — the same discipline
    # `app_cpu` above takes, for the same reason. `None` means the bundle OMITTED
    # the field (the app declares no healthcheck; its resource will be
    # `NOT_GATED` and adopted on cloud existence). `Some("")` means the bundle
    # AUTHORED an empty path, which is a different fact and is REFUSED BY NAME at
    # compose. A parser that collapsed them would make that refusal unreachable
    # and would silently ask the deploy to probe the empty string.
    var app_health_check_path = Optional[String]()
    while not _at_block_end(cur, String("AppSpec")):
        var f = _read_field_name(cur, String("AppSpec"))
        if f.text == String("image"):
            _open_block(cur, String("image"))
            image = _parse_image_ref(cur)
        elif f.text == String("port"):
            port = _read_int_value(cur, String("port"))
        elif f.text == String("env"):
            _open_block(cur, String("env"))
            env.append(_parse_bundle_env_var(cur))
        elif f.text == String("scaling"):
            _open_block(cur, String("scaling"))
            scaling = _parse_scaling(cur)
        elif f.text == String("compute"):
            var c = _read_enum_value(
                cur, String("compute"), String("ComputeIntent"), compute_values()
            )
            _refuse_unsupported_compute_intent(c, f.line, f.col)
            compute = ComputeIntent.from_json_name(c)
        elif f.text == String("datastore"):
            var d = _read_enum_value(
                cur, String("datastore"), String("DatastoreNeed"), datastore_values()
            )
            datastore = DatastoreNeed.from_json_name(d)
        elif f.text == String("secret_bindings"):
            _open_block(cur, String("secret_bindings"))
            secret_bindings.append(_parse_secret_binding(cur))
        elif f.text == String("runtime_identity"):
            runtime_identity = _read_string_value(cur, String("runtime_identity"))
        elif f.text == String("web_slug"):
            web_slug = _read_string_value(cur, String("web_slug"))
        elif f.text == String("web_domain"):
            web_domain = _read_string_value(cur, String("web_domain"))
        elif f.text == String("web_additional_domains"):
            web_additional_domains.append(
                _read_string_value(cur, String("web_additional_domains"))
            )
        elif f.text == String("web_api_path_prefixes"):
            web_api_path_prefixes.append(
                _read_string_value(cur, String("web_api_path_prefixes"))
            )
        elif f.text == String("web_api_service_logical_id"):
            web_api_service_logical_id = _read_string_value(
                cur, String("web_api_service_logical_id")
            )
        elif f.text == String("inbound"):
            var ib = _read_enum_value(
                cur, String("inbound"), String("InboundNeed"), inbound_values()
            )
            inbound = InboundNeed.from_json_name(ib)
        elif f.text == String("inbound_route_path"):
            inbound_route_path = _read_string_value(
                cur, String("inbound_route_path")
            )
        elif f.text == String("network_ingress"):
            var ni = _read_enum_value(
                cur,
                String("network_ingress"),
                String("NetworkIngress"),
                network_ingress_values(),
            )
            network_ingress = NetworkIngress.from_json_name(ni)
        elif f.text == String("network_egress"):
            # The SERVICE-scoped Direct VPC egress block (field 33), parsed by
            # the SAME `_parse_validate_vpc_egress` the job scope uses. The
            # SEMANTIC refusal (a block naming only one of network/subnetwork)
            # lives in `validate`, where the sentence explaining it fits.
            _open_block(cur, String("network_egress"))
            network_egress = Optional[ValidateVpcEgress](
                _parse_validate_vpc_egress(cur)
            )
        elif f.text == String("mail_transport"):
            # The MAIL-TRANSPORT SPINE (field 34). SINGULAR: a second block would
            # silently REPLACE the first, so the duplicate is REFUSED here rather
            # than resolved last-wins — one domain identity, one inbound queue and
            # one record set per app, and an author who wrote two meant something
            # this schema cannot express.
            if mail_transport:
                raise Error(
                    "line "
                    + String(f.line)
                    + " col "
                    + String(f.col)
                    + ": AppSpec declares a SECOND `mail_transport` block."
                    + " It is a SINGULAR field, so the second would silently"
                    + " REPLACE the first — one domain identity, one inbound"
                    + " queue and one record set per app"
                )
            _open_block(cur, String("mail_transport"))
            mail_transport = Optional[MailTransportSpec](
                _parse_mail_transport_spec(cur)
            )
        elif f.text == String("buckets"):
            _open_block(cur, String("buckets"))
            buckets.append(_parse_bucket_spec(cur))
        elif f.text == String("runtime_extra_capabilities"):
            runtime_extra_capabilities.append(
                Int32(
                    _read_int_value(cur, String("runtime_extra_capabilities"))
                )
            )
        elif f.text == String("web_route_rules"):
            _open_block(cur, String("web_route_rules"))
            web_route_rules.append(_parse_web_route_rule(cur))
        elif f.text == String("region"):
            region = _read_string_value(cur, String("region"))
        elif f.text == String("name_scope"):
            var nsv = _read_enum_value(
                cur, String("name_scope"), String("NameScope"), name_scope_values()
            )
            name_scope = NameScope.from_json_name(nsv)
        elif f.text == String("public_invoker"):
            public_invoker = _read_bool_value(cur, String("public_invoker"))
        elif f.text == String("keep_last_n"):
            var kln = _read_int_value(cur, String("keep_last_n"))
            # keep_last_n is the COUNT of newest revisions to KEEP; it must be >= 1.
            # `select_revisions_to_prune` treats <= 0 as keep=0 (delete every
            # non-serving revision), so an authored `keep_last_n: 0` — the intuitive
            # spelling for "unlimited / disable pruning" — would mass-prune all
            # rollback history. Reject it at authoring; OMIT the field to use the
            # default retention.
            if kln < 1:
                raise Error(
                    pos_prefix(f.line, f.col)
                    + String(
                        "field 'keep_last_n' must be >= 1 (the count of NEWEST"
                        " revisions to KEEP); got "
                    )
                    + String(Int(kln))
                    + String(
                        ". Omit the field to use the default retention; 0 is NOT"
                        " an unlimited/keep-all sentinel — it would prune every"
                        " non-serving revision."
                    )
                )
            keep_last_n = Optional[Int32](Int32(kln))
        elif f.text == String("secured_inbound_routes"):
            _open_block(cur, String("secured_inbound_routes"))
            secured_inbound_routes.append(_parse_secured_inbound_route(cur))
        elif f.text == String("datastore_database"):
            datastore_database = _read_string_value(
                cur, String("datastore_database")
            )
        elif f.text == String("datastore_database_ref"):
            datastore_database_ref = _read_string_value(
                cur, String("datastore_database_ref")
            )
        elif f.text == String("cpu"):
            # ★ THE APP'S DECLARED CPU (field 38). Stored VERBATIM and
            # PRESENT-tagged — an authored `cpu: ""` becomes Some("") and is
            # refused at compose, not silently erased here.
            app_cpu = Optional[String](_read_string_value(cur, String("cpu")))
        elif f.text == String("memory"):
            # ★ THE APP'S DECLARED MEMORY (field 39). As `cpu` above.
            app_memory = Optional[String](
                _read_string_value(cur, String("memory"))
            )
        elif f.text == String("health_check_path"):
            # ★★ THE APP'S HEALTHCHECK ENDPOINT (field 40). Stored VERBATIM and
            # PRESENT-tagged — an authored `health_check_path: ""` becomes
            # Some("") and is refused at compose, never silently erased here.
            app_health_check_path = Optional[String](
                _read_string_value(cur, String("health_check_path"))
            )
        elif f.text == String("ingress"):
            _open_block(cur, String("ingress"))
            ingress = _parse_ingress_spec(cur)
        elif f.text == String("parameters"):
            # ★ THE MANAGED-APP PARAMETERS (field 31). Appended in AUTHORED ORDER
            # and never sorted: `compose_api` emits argv in this order, and a
            # revision whose command line reorders between deploys churns a new
            # Cloud Run revision for no change.
            _open_block(cur, String("parameters"))
            parameters.append(_parse_app_parameter(cur))
        elif f.text == String("index_tables"):
            _open_block(cur, String("index_tables"))
            index_tables.append(_parse_index_table(cur))
        elif f.text == String("cloud_variants"):
            # ★ THE PER-CLOUD SPEC VARIANTS (field 36). REPEATED — one block per
            # cloud posture. The DUPLICATE-POSTURE refusal is NOT here: it is at
            # compose, beside the UNSPECIFIED refusal, so the two halves of one
            # rule cannot drift apart.
            _open_block(cur, String("cloud_variants"))
            cloud_variants.append(_parse_cloud_variant(cur))
        elif f.text == String("datastore_collections"):
            # ★ THE COLLECTION SHAPES (field 35). REPEATED — a second block is a
            # second collection, not a replacement, which is the opposite of
            # `mail_transport` above and is why they are spelled differently:
            # one datastore holds N collections.
            _open_block(cur, String("datastore_collections"))
            datastore_collections.append(_parse_datastore_collection(cur))
        else:
            var known = List[String]()
            known.append(String("image"))
            known.append(String("port"))
            known.append(String("env"))
            known.append(String("scaling"))
            known.append(String("compute"))
            known.append(String("datastore"))
            known.append(String("secret_bindings"))
            known.append(String("runtime_identity"))
            known.append(String("web_slug"))
            known.append(String("web_domain"))
            known.append(String("web_additional_domains"))
            known.append(String("web_api_path_prefixes"))
            known.append(String("web_api_service_logical_id"))
            known.append(String("inbound"))
            known.append(String("inbound_route_path"))
            known.append(String("buckets"))
            known.append(String("runtime_extra_capabilities"))
            known.append(String("web_route_rules"))
            known.append(String("region"))
            known.append(String("name_scope"))
            known.append(String("public_invoker"))
            known.append(String("keep_last_n"))
            known.append(String("secured_inbound_routes"))
            known.append(String("datastore_database"))
            known.append(String("datastore_database_ref"))
            known.append(String("index_tables"))
            known.append(String("ingress"))
            known.append(String("parameters"))
            known.append(String("network_ingress"))
            known.append(String("network_egress"))
            known.append(String("mail_transport"))
            known.append(String("datastore_collections"))
            known.append(String("cloud_variants"))
            known.append(String("cpu"))
            known.append(String("memory"))
            known.append(String("health_check_path"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("AppSpec"), known)
            )
    return AppSpec(
        image^,
        port,
        env^,
        scaling^,
        compute,
        datastore,
        secret_bindings^,
        runtime_identity^,
        # The 4 supervisor HINT fields (9-12) default to empty/0 here
        # (byte-identical to a bundle that omits them). The bundle text does not
        # author these hints yet; only the shape exists.
        String(""),  # supervisor_child_health_path
        Int32(0),  # supervisor_child_health_port
        String(""),  # supervisor_cpu
        String(""),  # supervisor_memory
        # STATIC_FRONTEND authoring (fields 13-17) — parsed above.
        web_slug^,
        web_domain^,
        web_additional_domains^,
        web_api_path_prefixes^,
        web_api_service_logical_id^,
        # API-EDGE authoring (fields 18-19) — parsed above.
        inbound,
        inbound_route_path^,
        # APP-PROVISIONED BUCKETS (field 20) — parsed above.
        buckets^,
        # EXTRA runtime capability ordinals (field 21) — parsed above.
        runtime_extra_capabilities^,
        # FULL url-map route table (field 22) — parsed above (empty when the
        # bundle authors no `web_route_rules` block; additive-safe).
        web_route_rules^,
        # PER-BUNDLE DEPLOY-REGION OVERRIDE (field 23) — parsed above (empty when
        # the bundle authors no `region`; the effective region is then the env
        # binding's default).
        region^,
        # PUBLIC (allUsers) INVOKER (field 24) — parsed above (false when the bundle
        # authors no `public_invoker`; the served node then stays PRIVATE, scoped
        # run.invoker only — byte-identical to every existing bundle).
        public_invoker,
        # RETENTION (field 25) — parsed above (None when the bundle authors no
        # `keep_last_n`; the deploy mapper then applies the default 5).
        keep_last_n^,  # keep_last_n
        # EDGE-SECURED ADDITIONAL ROUTES (field 26) — parsed above (empty when the
        # bundle authors no `secured_inbound_routes` block; the composed API_EDGE
        # node is then byte-identical to one composed before the field existed).
        secured_inbound_routes^,
        # THE DATASTORE'S DATABASE NAME (field 27) — parsed above. EMPTY when the
        # bundle authors nothing, which `validate` REFUSES for a datastore-bearing
        # service: there is deliberately NO substituted default (see the proto).
        datastore_database^,
        # THE REFERENCED DATABASE (field 28) — parsed above. EMPTY when the bundle
        # owns its database (or has none). Exactly ONE of fields 27/28 may be set on
        # a datastore-bearing service; `resolve_datastore_identity` is the one place
        # that judges the pair.
        datastore_database_ref^,
        # THE APP-DECLARED INDEX SHAPES (field 29) — parsed above. EMPTY when the
        # bundle declares none, which is byte-identical to a bundle authored before
        # the field existed: the ensure step then reads only what the shrinking
        # control-plane literal still declares for the database.
        index_tables^,
        # THE INGRESS REALIZATION INPUTS (field 30) — parsed above. None when the
        # bundle authors no `ingress {}` block; every existing bundle therefore
        # composes and re-emits BYTE-IDENTICALLY.
        ingress^,
        # ★ MANAGED-APP PARAMETERS (field 31) — parsed above (empty when the
        # bundle authors no `parameters {}` block; every existing bundle therefore
        # composes and re-emits BYTE-IDENTICALLY).
        parameters^,
        # ★ THE NETWORK REACH (field 32) — parsed above.
        # UNSPECIFIED when the bundle authors no `network_ingress`, which makes
        # the deploy stamp nothing and every existing bundle compose and re-emit
        # BYTE-IDENTICALLY. Not the same as private — see the enum.
        network_ingress,
        # ★ THE SERVED SERVICE'S OUTBOUND PATH (field 33) — parsed above. None
        # when the bundle authors no `network_egress {}` block, which makes the
        # deploy render no `vpc_access` and every existing bundle compose and
        # re-emit BYTE-IDENTICALLY. Not the same as "no egress": absent means the
        # revision leaves over the PUBLIC INTERNET — see the proto.
        network_egress^,
        # ★ THE MAIL-TRANSPORT SPINE (field 34) — parsed above. `None` when the
        # bundle authors no `mail_transport {}` block, which is every bundle in the
        # tree but the mail-transport machine, and which is what makes the field
        # additive-safe (byte-identical compose + content address).
        mail_transport^,
        # ★ THE COLLECTION SHAPES (field 35) — parsed above. EMPTY when the
        # bundle authors no `datastore_collections {}` block: a `repeated` field
        # writes nothing when empty, so such a bundle composes and re-emits
        # BYTE-IDENTICALLY.
        datastore_collections^,
        # ★ THE PER-CLOUD SPEC VARIANTS (field 36) — parsed above. EMPTY when the
        # bundle authors no `cloud_variants {}` block: no variant is selected on
        # any cloud, so the spec-level declarations stand and the composed
        # manifest (and its content address) is unchanged.
        cloud_variants^,
        # ★ THE NAME SCOPE (field 37) — parsed above. UNSPECIFIED when the bundle
        # authors no `name_scope`: an enum's zero ordinal writes nothing on the
        # wire, so such a bundle composes and re-emits BYTE-IDENTICALLY.
        name_scope,
        # ★ THE APP'S OWN COMPUTE ALLOCATION (fields 38-39) — parsed above. None
        # when the bundle omits the field: a presence-typed `optional string`
        # writes nothing when unset, so such a bundle composes and re-emits
        # BYTE-IDENTICALLY. ⛔ NEVER a substituted "0m"/"" — a fabricated
        # allocation is an amount a customer never asked for, billed.
        app_cpu^,
        app_memory^,
        # ★★ THE APP'S HEALTHCHECK ENDPOINT (field 40) — parsed above. None when
        # the bundle omits the field: a presence-typed `optional string` writes
        # nothing when unset, so such a bundle composes and re-emits
        # BYTE-IDENTICALLY and the app stays `NOT_GATED`.
        # ⛔ NEVER a substituted "/healthz" — a fabricated path yields exactly
        # the `GAVE_UP_NEVER_ANSWERED` verdict for an app that never asked to be
        # probed there; a hardcoded `/healthz` fails healthy deploys closed.
        app_health_check_path^,
    )


def _parse_service_spec(mut cur: Cursor) raises -> ServiceSpec:
    """Parse one `services { name: "…" kind: … spec { … } }` block — ONE named
    service of a MULTI-SERVICE bundle (`AppBundle.services`, field 7).

    ★ WHY THIS ARM EXISTS. The schema declares `repeated ServiceSpec services`,
    the compose pass emits nodes per service with every derived node id keyed on
    `svc.name`, `validate_bundle` checks `services[i].spec` per element, and the
    deploy drives map->apply->post-apply-gate over N services. This arm is what
    lets a bundle SAY it: a topology expressible only in code is a topology no
    reviewer reads as IaC.

    THE FIELD SET IS THE PROTO'S, all three of it: `name` (1), `kind` (2),
    `spec` (3) — and `spec` REUSES `_parse_app_spec` verbatim, which is what makes
    a service's intent surface IDENTICAL to the singular `spec {}`'s. That reuse
    is load-bearing rather than convenient: a second, parallel AppSpec grammar is
    exactly the drift `test_emit_completeness`'s totality leg exists to refuse,
    and it would drift silently the first time a field landed on one and not the
    other.

    ⚠ THE ZERO VALUE OF `kind` IS NOT A DEFAULT. `AppKind(0)` is
    APP_KIND_UNSPECIFIED, and `compose()`'s per-service dispatch FAILS on it by
    name rather than assuming API — the UNSPECIFIED semantics this whole surface
    holds. A service that means API says APP_KIND_API.

    The parse is purely structural. Every semantic check — a service with no
    spec, a duplicate service name, a `service_ref` naming an unknown sibling —
    lives in `validate.mojo` / `compose_api`, the same split every other block
    here follows."""
    var name = String("")
    var kind = AppKind(0)
    var spec: Optional[AppSpec] = None
    while not _at_block_end(cur, String("ServiceSpec")):
        var f = _read_field_name(cur, String("ServiceSpec"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("kind"):
            var k = _read_enum_value(
                cur, String("kind"), String("AppKind"), app_kind_values()
            )
            kind = AppKind.from_json_name(k)
        elif f.text == String("spec"):
            _open_block(cur, String("spec"))
            spec = _parse_app_spec(cur)
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("kind"))
            known.append(String("spec"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("ServiceSpec"), known
                )
            )
    return ServiceSpec(name^, kind, spec^)


def _parse_git_push(mut cur: Cursor) raises -> GitPush:
    """Parse one `git_push { … }` arm — the git-shaped trigger payload
    (`{source_kind, repo_ref, ref}`). These are the SAME three fields
    a flat trigger message would carry; they live in the arm so the open set is
    the arm list rather than a widening flat message. The
    proto `ref` field escapes to the Mojo keyword-safe `ref_` (wire/JSON name
    stays `ref`), so the AUTHORED field name matched here is `ref`."""
    var source_kind = SourceKind(0)
    var repo_ref = String("")
    var ref_ = String("")
    while not _at_block_end(cur, String("GitPush")):
        var f = _read_field_name(cur, String("GitPush"))
        if f.text == String("source_kind"):
            var sk = _read_enum_value(
                cur,
                String("source_kind"),
                String("SourceKind"),
                source_kind_values(),
            )
            source_kind = SourceKind.from_json_name(sk)
        elif f.text == String("repo_ref"):
            repo_ref = _read_string_value(cur, String("repo_ref"))
        elif f.text == String("ref"):
            ref_ = _read_string_value(cur, String("ref"))
        else:
            var known = List[String]()
            known.append(String("source_kind"))
            known.append(String("repo_ref"))
            known.append(String("ref"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("GitPush"), known)
            )
    return GitPush(source_kind, repo_ref^, ref_^)


def _parse_schedule(mut cur: Cursor) raises -> Schedule:
    """Parse one `schedule { cron: "…" timezone: "…" }` arm — the CADENCE arm the
    weekly merge-from-live is authored as. The cron string is validated in
    validate.mojo (fail-closed), not here: the parse is purely structural, the
    same split every other block follows."""
    var cron = String("")
    var timezone = String("")
    while not _at_block_end(cur, String("Schedule")):
        var f = _read_field_name(cur, String("Schedule"))
        if f.text == String("cron"):
            cron = _read_string_value(cur, String("cron"))
        elif f.text == String("timezone"):
            timezone = _read_string_value(cur, String("timezone"))
        else:
            var known = List[String]()
            known.append(String("cron"))
            known.append(String("timezone"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("Schedule"), known)
            )
    return Schedule(cron^, timezone^)


def _parse_package_published(mut cur: Cursor) raises -> PackagePublished:
    """Parse one `package_published { … }` arm — a package published to a watched
    registry (`{registry_kind, package_ref, version_range}`)."""
    var registry_kind = RegistryKind(0)
    var package_ref = String("")
    var version_range = String("")
    while not _at_block_end(cur, String("PackagePublished")):
        var f = _read_field_name(cur, String("PackagePublished"))
        if f.text == String("registry_kind"):
            var rk = _read_enum_value(
                cur,
                String("registry_kind"),
                String("RegistryKind"),
                registry_kind_values(),
            )
            registry_kind = RegistryKind.from_json_name(rk)
        elif f.text == String("package_ref"):
            package_ref = _read_string_value(cur, String("package_ref"))
        elif f.text == String("version_range"):
            version_range = _read_string_value(cur, String("version_range"))
        else:
            var known = List[String]()
            known.append(String("registry_kind"))
            known.append(String("package_ref"))
            known.append(String("version_range"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("PackagePublished"), known
                )
            )
    return PackagePublished(registry_kind, package_ref^, version_range^)


def _parse_trigger_source(mut cur: Cursor) raises -> TriggerSource:
    """Parse one `triggers { … }` block into the generated `TriggerSource` — a
    NAMED trigger plus exactly ONE payload arm.

    THE ARM IS THE EVENT. There is no `event` field: `git_push` fires on a push,
    `schedule` fires on a cadence, `package_published` fires on a publish. The
    previous shape carried a separate `TriggerEvent` axis cross-producted against
    `SourceKind`, most of whose product was nonsense.

    ARM DISCIPLINE. `_oneof0_case` is the 1-based ARM INDEX in declaration order
    (git_push=1, schedule=2, package_published=3) — NOT the proto field number.
    Mirrors `_parse_validate_step`: Optional accumulators + an explicit conflict
    check on a second arm, so `git_push {} schedule {}` in one block is a
    position-carrying error rather than a silent last-wins."""
    var name = String("")
    var arm: Int = 0
    var git_push: Optional[GitPush] = None
    var schedule: Optional[Schedule] = None
    var package_published: Optional[PackagePublished] = None
    while not _at_block_end(cur, String("TriggerSource")):
        var f = _read_field_name(cur, String("TriggerSource"))
        if f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("git_push"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("TriggerSource.on"),
                        _trigger_arm_name(arm), String("git_push"),
                    )
                )
            _open_block(cur, String("git_push"))
            git_push = _parse_git_push(cur)
            arm = 1
        elif f.text == String("schedule"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("TriggerSource.on"),
                        _trigger_arm_name(arm), String("schedule"),
                    )
                )
            _open_block(cur, String("schedule"))
            schedule = _parse_schedule(cur)
            arm = 2
        elif f.text == String("package_published"):
            if arm != 0:
                raise Error(
                    _oneof_conflict(
                        f.line, f.col, String("TriggerSource.on"),
                        _trigger_arm_name(arm), String("package_published"),
                    )
                )
            _open_block(cur, String("package_published"))
            package_published = _parse_package_published(cur)
            arm = 3
        else:
            var known = List[String]()
            known.append(String("name"))
            known.append(String("git_push"))
            known.append(String("schedule"))
            known.append(String("package_published"))
            raise Error(
                unknown_field_error(
                    f.line, f.col, f.text, String("TriggerSource"), known
                )
            )
    return TriggerSource(name^, arm, git_push^, schedule^, package_published^)


# ─── The top-level entry point ───────────────────────────────────────────────
def parse_bundle(text: String) raises -> AppBundle:
    """Parse a `komira.deploy.textproto` document into the generated `AppBundle`.
    Raises a position-carrying `Error` on the first lexical/structural/unknown-
    field/unknown-enum failure — the field-precise LLM self-correction surface.
    This does NOT run the semantic pass (`validate.mojo`): a syntactically valid
    but semantically incomplete bundle parses here and is caught by `validate`."""
    var cur = Cursor(tokenize(text))

    var kind = AppKind(0)
    var name = String("")
    var builds = List[BuildTarget]()
    var spec: Optional[AppSpec] = None
    var waves = List[Wave]()
    var triggers = List[TriggerSource]()
    # The reshape — named validation SETS +
    # the pipeline (defined once, referenced by name; NOT env-keyed).
    var validation_sets = List[ValidationSet]()
    var pipeline: Optional[Pipeline] = None
    # The device/capability MATRICES —
    # named matrices, referenced by a `PipelineStep.matrix_ref`. EMPTY ⇒ no
    # authored matrix (byte-identical to a pre-matrix bundle).
    var matrices = List[Matrix]()
    # The named DEPLOY OUTPUTS — referenced
    # via `${ref:<bundle>.outputs.<name>}`. EMPTY ⇒ the bundle exposes no output
    # (byte-identical to a pre-outputs bundle).
    var outputs = List[DeployOutput]()
    # ── Four optional capabilities. All EMPTY/None when unauthored ⇒ a bundle
    #    that authors none parses and re-emits BYTE-IDENTICALLY. ───────────────
    # The run-to-completion JOBS this bundle ships (field 12). Declaring one does
    # NOT run it — a `ValidateStep.execute_job` step does.
    var jobs = List[JobSpec]()
    # The scheduled calls into this bundle's OWN services (field 13).
    var crons = List[CronSpec]()
    # RUN-SCOPED LIFECYCLE (field 14). PRESENCE is the bundle's PERMISSION to be
    # deployed under `--run-id`; absence REFUSES that flag.
    var ephemeral: Optional[EphemeralScope] = None
    # ★ TENANCY (field 15) — WHOSE CLOUD ACCOUNT THIS WORKLOAD RUNS IN. The zero
    # value is TENANCY_UNSPECIFIED, and an unauthored bundle keeps it: this
    # parser does NOT infer a tenancy from `kind`, from the bundle's name, or
    # from the environments its waves name. Every such inference is the guess the
    # `Tenancy` enum's own comment refuses to make.
    var tenancy = Tenancy(0)
    # ★ THE MULTI-SERVICE LIST (field 7) — N named services in ONE bundle. EMPTY
    # when the document authors no `services {}` block, which is the auto-lift
    # signal `_auto_lifted_services` reads: singular `name`/`kind`/`spec` become
    # a one-element list, so a single-service bundle composes and re-emits
    # BYTE-IDENTICALLY.
    var services = List[ServiceSpec]()

    while True:
        var t = cur.peek()
        if t.kind == TOK_EOF:
            break
        var f = _read_field_name(cur, String("AppBundle"))
        if f.text == String("kind"):
            var k = _read_enum_value(
                cur, String("kind"), String("AppKind"), app_kind_values()
            )
            kind = AppKind.from_json_name(k)
        elif f.text == String("tenancy"):
            # ★ TENANCY — WHOSE CLOUD ACCOUNT THIS WORKLOAD RUNS IN. VALIDATED
            # against the closed `Tenancy` set, so a typo
            # is a positioned parse error, and STORED on the bundle (field 15).
            #
            # ⚠ IT MUST BE STORED, NOT VALIDATED-AND-DROPPED: every consumer
            # downstream of the parse — composer, validator, applier — needs it to
            # tell a managed app from a control-plane service.
            var tv = _read_enum_value(
                cur, String("tenancy"), String("Tenancy"), tenancy_values()
            )
            tenancy = Tenancy.from_json_name(tv)
        elif f.text == String("name"):
            name = _read_string_value(cur, String("name"))
        elif f.text == String("build"):
            _open_block(cur, String("build"))
            builds.append(_parse_build_target(cur))
        elif f.text == String("spec"):
            _open_block(cur, String("spec"))
            spec = _parse_app_spec(cur)
        elif f.text == String("waves"):
            _open_block(cur, String("waves"))
            waves.append(_parse_wave(cur))
        elif f.text == String("triggers"):
            _open_block(cur, String("triggers"))
            triggers.append(_parse_trigger_source(cur))
        elif f.text == String("services"):
            # ★ THE MULTI-SERVICE AUTHORING SURFACE (field 7) — see
            # `_parse_service_spec`. Each block appends one named service; ZERO
            # blocks leaves the list EMPTY, which is what makes a single-service
            # bundle parse, compose and re-emit
            # byte-identically (`_auto_lifted_services` lifts the singular
            # `name`/`kind`/`spec` into a one-element list only when this is empty).
            _open_block(cur, String("services"))
            services.append(_parse_service_spec(cur))
        elif f.text == String("validation_sets"):
            _open_block(cur, String("validation_sets"))
            validation_sets.append(_parse_validation_set(cur))
        elif f.text == String("pipeline"):
            _open_block(cur, String("pipeline"))
            pipeline = _parse_pipeline(cur)
        elif f.text == String("matrices"):
            _open_block(cur, String("matrices"))
            matrices.append(_parse_matrix(cur))
        elif f.text == String("outputs"):
            _open_block(cur, String("outputs"))
            outputs.append(_parse_deploy_output(cur))
        elif f.text == String("jobs"):
            _open_block(cur, String("jobs"))
            jobs.append(_parse_job_spec(cur))
        elif f.text == String("crons"):
            _open_block(cur, String("crons"))
            crons.append(_parse_cron_spec(cur))
        elif f.text == String("ephemeral"):
            _open_block(cur, String("ephemeral"))
            ephemeral = _parse_ephemeral_scope(cur)
        else:
            var known = List[String]()
            known.append(String("kind"))
            known.append(String("tenancy"))
            known.append(String("name"))
            known.append(String("build"))
            known.append(String("spec"))
            known.append(String("waves"))
            known.append(String("triggers"))
            known.append(String("services"))
            known.append(String("validation_sets"))
            known.append(String("pipeline"))
            known.append(String("matrices"))
            known.append(String("outputs"))
            known.append(String("jobs"))
            known.append(String("crons"))
            known.append(String("ephemeral"))
            raise Error(
                unknown_field_error(f.line, f.col, f.text, String("AppBundle"), known)
            )

    # `triggers` (continuous-deployment sources) ARE now authored via this parse
    # path (the trigger authoring-surface parse) — each `triggers { … }` block
    # accumulated above into `triggers`. ZERO authored triggers ⇒ an empty list
    # (one-shot, byte-identical to the prior always-empty behavior); ≥1 ⇒ the
    # continuous-deployment source set fans in onto this bundle's pipeline.
    # ★ `services` (field 7, the SVCREF-1 multi-service list) IS now authored via
    # this parse path — each `services { … }` block accumulated above. ZERO
    # authored services ⇒ an EMPTY list, which is the AUTO-LIFT signal: the
    # pipeline lifts the singular `kind`/`name`/`spec` into a one-element services
    # list, so every single-service bundle composes and re-emits byte-identically
    # to what it did before this arm existed. ≥1 ⇒ `services` is AUTHORITATIVE and
    # the singular `name`/`spec` are ignored (the singular `kind` still gates the
    # top-level `compose()` dispatch). A missed trailing arg would SILENTLY
    # misparse.
    return AppBundle(
        kind,
        name^,
        builds^,
        spec^,
        waves^,
        triggers^,
        services^,
        # The reshape — the parsed named validation
        # SETS + pipeline (fields 8, 9; empty/None when unauthored → byte-identical
        # to a pre-reshape bundle).
        validation_sets^,
        pipeline^,
        # The device/capability MATRICES (field 10; empty when unauthored →
        # byte-identical to a bundle without matrices). A missed trailing arg would SILENTLY misparse.
        matrices^,
        # The named DEPLOY OUTPUTS (field 11; empty when unauthored →
        # byte-identical to a bundle without outputs). A
        # missed trailing arg would SILENTLY misparse.
        outputs^,
        # The RUN-TO-COMPLETION JOBS (field 12), the SCHEDULED CALLS (field 13),
        # and the RUN-SCOPED LIFECYCLE permission (field 14). Empty/None when
        # unauthored → byte-identical to a bundle without them. A missed trailing arg would SILENTLY misparse.
        jobs^,
        crons^,
        ephemeral^,
        # ★ TENANCY (field 15) — the value the `tenancy:` arm above stores.
        # TENANCY_UNSPECIFIED when the document authors none.
        tenancy,
    )
