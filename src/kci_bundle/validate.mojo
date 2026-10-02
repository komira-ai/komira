# =============================================================================
# kci_bundle/validate.mojo — the semantic pass over a parsed bundle.
# =============================================================================
#
# The SEMANTIC checks a purely-structural parse (`parser.mojo`) cannot catch,
# returning field-precise, self-correctable messages. A syntactically valid bundle can still be semantically wrong: a
# `from_build` that names no `BuildTarget`, an empty wave `env` symbol, a oneof
# with zero arms set, or a kind missing its required fields. Each of those is a
# convergence-breaking authoring bug the reconciler would otherwise hit at run
# time; catching it here is the LLM self-correction surface (parse-time errors
# raise; the semantic pass returns the FULL list so an author fixes everything in
# one round-trip, not one-at-a-time).
#
# `validate_bundle(bundle, reserved_org_id=...) -> List[String]` — an EMPTY
# list means valid.
#
# ENCAPSULATION: borrowed message reads + `mut errs: List[String]` accumulation.
# No pointer, no wildcard origin. Mojo 1.0.0b2.
# =============================================================================

from kci_bundle_proto.app_bundle import (
    AppParameter,
    ParamType,
    ParamMarker,
    AppBundle,
    AppKind,
    # ★ WHOSE ACCOUNT this workload runs in — the SECOND axis, orthogonal to
    # `kind` (the topology). Read here for the datastore PLACEMENT rule.
    Tenancy,
    ImageRef,
    BundleEnvVar,
    ValueFrom,
    AppSpec,
    RunContainer,
    # ★ The EPHEMERAL KOMIRA CALLER IDENTITIES a validate step declares
    # (`RunContainer.test_role`, field 9). Provisioning one WRITES
    # ROWS INTO KOMIRA'S OWN CONTROL PLANE, so every refusal below is load-time.
    TestRole,
    # The DIRECT VPC EGRESS attachment a validate step's JOB may carry
    # (`RunContainer.vpc_egress`, field 7). ABSENT => no `vpcAccess` on the
    # wire => the job egresses over the PUBLIC INTERNET.
    ValidateVpcEgress,
    ValidateStep,
    Wave,
    GateOn,
    # ⭐ `TELEMETRY_READ_JOB_VM_STATE` is refused by name (declared, not yet honoured).
    TelemetryRead,
    # The TRIGGER authoring surface — a named trigger + a one-arm-per-kind
    # payload oneof.
    TriggerSource,
    SourceKind,
    RegistryKind,
    # The reshape — named validation SETS + the
    # pipeline-STEP authoring surface.
    ValidationSet,
    # ⛔ The ENV RESTRICTION a validation set carries. The discriminator is its own field so that UNSPECIFIED can be REFUSED rather
    # than read as "permitted everywhere"; see `_check_validation_set_env_policy`
    # and the pipeline JOIN check.
    ValidationSetEnvPolicy,
    PipelineStep,
    StepKind,
    # The device/capability matrix
    # — fail-closed synth-time validation of the neutral matrix block.
    Matrix,
    MatrixCell,
    # The named DEPLOY OUTPUTS —
    # fail-closed synth-time validation (unique name; `from_served` names a real
    # served node the bundle composes).
    DeployOutput,
    # ADDITIONAL inbound routes the EDGE authenticates (`AppSpec.
    # secured_inbound_routes`; federated callers) —
    # validated by `_check_secured_inbound_routes`.
    SecuredInboundRoute,
    EdgeAuthPolicyKind,
    # ── Four optional capabilities. Each is checked at LOAD TIME, offline, from the bundle text
    #    alone — no credentials, no cloud. ─────────────────────────────────────
    IngressSpec,
    JobSpec,
    ExecuteJob,
    CronSpec,
    EphemeralScope,
    # ★ THE COLLECTION SHAPES this app's datastore holds
    # (`AppSpec.datastore_collections`, field 35). Only `DatastoreAccessPath` is
    # named: `_check_datastore_access_path` takes one — the SAME message under
    # both keys, so one checker covers the primary and the secondary paths and a
    # fix to one cannot silently miss the other. The collection itself is only
    # ever reached through `sp.datastore_collections`, so its type needs no
    # spelling here.
    DatastoreAccessPath,
)
from kci_bundle_proto.deploy_model import (
    # The app-declared index shapes (`AppSpec.index_tables`, field 29) — the
    # bundle-declared alternative to compiled-in index manifests.
    # ⚠ The messages are declared in deploy_model.proto. `DeploymentSpec.datastore_index_tables`
    # carries the identical shapes so the CP pipeline engine can ensure a managed
    # app's indexes in the CUSTOMER project; app_bundle.proto imports deploy_model.proto
    # and not the reverse, so the shared messages live in the imported file.
    BundleIndexTable,
    InboundNeed,
    DatastoreNeed,
)
from kci_bundle.parse_error import suggest
from kci_bundle.trigger_cadence import cron_cadence_us

# ★ THE ONE READER of a service's datastore identity (own XOR reference). The
# four-state policy lives THERE, not here, because the release CLI's deploy seam asks the
# SAME question one layer down and two copies of it could disagree about who
# provisions a customer's data.
from kci_bundle.datastore_identity import (
    datastore_identity_error,
    managed_app_placement_error,
    control_plane_database_namespace_error,
)


# The `TriggerSource.on` arm indices. The generated `_oneof0_case` is the 1-BASED
# ARM INDEX in declaration order, NOT the proto field number (6/7/8) — a wrong
# constant here is a SILENT wrong-arm read, never a compile error. Mirrors the
# compose pass's `TRIGGER_ARM_*` (`kci_deploy_compose`).
comptime _TRIGGER_ARM_GIT_PUSH: Int = 1
comptime _TRIGGER_ARM_SCHEDULE: Int = 2
comptime _TRIGGER_ARM_PACKAGE_PUBLISHED: Int = 3


# =============================================================================
# EDGE-RESERVED PROBE PATHS — the class guard
# =============================================================================
#
# ★ THE FACT. Google's serverless edge (the GFE fronting `*.run.app`) TERMINATES
# the EXACT path `/healthz` with its OWN 404 HTML error page. The request never
# reaches the Cloud Run service. With an identity token, on the plain service URL:
#
#     GET /healthz    -> 404, content-type: text/html, NO x-cloud-trace-context
#     GET /readyz     -> 200, x-cloud-trace-context present
#     GET /livez      -> 200, x-cloud-trace-context present
#     GET /healthz/   -> 401 (reaches the container: trace header present)
#     GET /healthzz   -> 401 (reaches the container)
#     GET /HEALTHZ    -> 401 (reaches the container; the reservation is
#                             case-SENSITIVE and EXACT, query string irrelevant)
#
# It fires BEFORE Cloud Run's IAM check: with NO bearer at all, `/healthz` still
# returns 404 while every other path returns 403. And it applies to every service.
#
# ⛔ WHY THIS IS EASY TO RE-DERIVE WRONG. The Cloud Run STARTUP PROBE reaches the
# container on `/healthz` JUST FINE — it is an internal prober dialing the
# container port directly, and it BYPASSES THE EDGE ENTIRELY. So "the startup
# probe works, therefore `/healthz` reaches the container" is a NON-SEQUITUR: it
# is true of the probe path and false of the ingress path. A revision can be
# `Ready=True` with a `/healthz` startup probe AND answer 404 on external
# `/healthz` AT THE SAME TIME. See the `is_readiness_probe` docstring.
#
# CONSEQUENCE FOR BUNDLES: a deploy gate probes THROUGH THE EDGE (an
# `http_check` dials the converged `deploy_url`). So an external probe aimed at
# `/healthz` gates on GOOGLE'S 404, not on the service — it can never pass, and
# if the expected status were ever authored as 404 it would pass VACUOUSLY
# without the container being consulted at all. Both failure modes are silent.
# Hence: authoring one is a bundle VALIDATION error.
#
# Serve `/healthz` on the container (the startup probe needs it — a revision
# whose `/healthz` 401s never starts) and probe `/readyz` from outside. They are
# THE SAME readiness answer.
comptime EDGE_RESERVED_PROBE_PATH: String = "/healthz"

# The externally-reachable readiness alias every service serves alongside
# `/healthz` — the path an external deploy probe must use instead.
comptime EDGE_SAFE_READINESS_PATH: String = "/readyz"

# The env var a probe run_container step carries its probe path in.
comptime PROBE_HEALTH_PATH_ENV: String = "CP_PROBE_HEALTH_PATH"


# =============================================================================
# ★ THE EPHEMERAL-LIFECYCLE DEADLINE PAIRING.
#
# ⛔ THE FAILURE THIS REFUSES AT LOAD. A validate step that declares
#   `<APP>_LIFECYCLE_MODE: "ephemeral"` runs the managed-app lifecycle: it CREATES
#   a real managed app in a real customer project, exercises it, then DELETES it.
#   The lifecycle's GUARANTEED bounded-poll wall is the sum of its six poll
#   budgets (deploy-run 2800s + app-ready 180s + revision 300s + destroy-run 600s
#   + cp-gone 120s + sweep-destroy 600s = 4600s), and a Cloud Run Job whose
#   `taskTemplate.timeout` is unauthored gets Google's documented 600s default.
#
#   4600 > 600. So an `ephemeral` step with no authored deadline is SIGKILLed
#   mid-lifecycle — necessarily AFTER the deploy POST, which is issued in the first
#   minute — and a SIGKILL runs NO in-process reap. **The run LEAVES A DEPLOYED APP
#   BEHIND IN A CUSTOMER PROJECT**, reports a bare non-zero exit with no rows and no
#   `VERDICT:` line, and the only recovery is a later run's stale-orphan sweep.
#
# ★ WHY A REFUSAL AND NOT A RAISED NUMBER. Pairing `ephemeral` with
#   `KOMIRA_VALIDATE_TASK_TIMEOUT_S` by hand is exactly the kind of pairing an
#   author forgets. The guard that cannot be forgotten is the one that makes the
#   unpaired bundle unloadable.
#
# ⚠ THE FLOOR IS RESTATED HERE, AND THAT DUPLICATION MUST BE GUARDED. The
#   authority is the managed-app lifecycle validator's budget table, which this
#   leaf cannot depend on without inverting the layering (that is a validator
#   library; this is a bundle parser). A test that links BOTH and asserts the
#   constants agree keeps a budget change from silently loosening this gate.
# =============================================================================
# ── ★ THE TWO ENDS OF THE LIFECYCLE COMPUTE-ENVIRONMENT STRING ──────────────
# The env a bootstrap step stamps to CREATE an environment, and the argv flag an
# app's e2e validator renders to LOOK ONE UP. Named once, here, so the refusal in
# `_check_lifecycle_env_pairing` can never quote a key or a flag that differs
# from the one it actually matched on.
comptime BOOTSTRAP_ENV_NAME_ENV: String = "KOMIRA_BOOTSTRAP_ENV_NAME"
comptime CP_ENV_NAME_FLAG: String = "cp-env-name"

comptime LIFECYCLE_MODE_ENV_SUFFIX: String = "_LIFECYCLE_MODE"
comptime LIFECYCLE_MODE_EPHEMERAL_VALUE: String = "ephemeral"
comptime LIFECYCLE_MODE_ARG_FLAG: String = "lifecycle-mode"
"""The RENDERED argv long flag (no leading `--`) a validate-step arg carries the
lifecycle mode on, because a binary's configuration arrives as flags, not env.

★ THE FLAG, NOT THE ARG NAME. `param_flag_for` lets an author state `flag:`
explicitly, so a predicate comparing `prm.name` to `"LIFECYCLE_MODE"` would miss
`args { name: "MODE" flag: "lifecycle-mode" }` — a step whose container receives
exactly the flag the binary parses, past a gate that could not see it. Two
spellings of "which arg is the mode" is how a predicate gets a hole nobody can
see; there is one spelling here.

⚠ THERE IS NO PER-APP PREFIX ON THIS SIDE, AND THAT IS NOT A WEAKENING. The env
key needed `<APP>_` to be scoped, so its guard had to SUFFIX-match and could be
fooled by length. An arg is scoped by the step it is authored on, so the flag is
one literal spelling for every app and the match is WHOLE — strictly less surface
than the suffix rule it complements, not more."""
comptime VALIDATE_TASK_TIMEOUT_ENV: String = "KOMIRA_VALIDATE_TASK_TIMEOUT_S"
comptime LIFECYCLE_GUARANTEED_POLL_FLOOR_S: Int = 4600
"""The managed-app lifecycle's GUARANTEED bounded-poll wall, in seconds — the sum
of its six poll budgets (2800 + 180 + 300 + 600 + 120 + 600).

★ THE DEPLOY-RUN BUDGET (2800s) is not `factor x an observation`: healthy deploy
runs have a long tail, so a budget derived from the slowest observed run fires
on healthy runs. 2800 is instead the largest deploy budget an authored 5400s
deadline admits while keeping 620s of headroom — more than the largest single
other budget.

★ THE DESTROY WAIT IS COUNTED TWICE. A stale-orphan sweep that issues a DELETE and
accepts a **202 ACCEPTED** has only QUEUED the destroy; deploying on top of a
teardown that is still running wedges the run. So the sweep polls that destroy
run to terminal on the same budget the close phase uses, and a run that sweeps an
orphan therefore waits for TWO destroy runs.

4600 against an authored 5400 leaves 800s, of which 180s is the
one-request-timeout-per-phase requirement `_required_deadline_s` adds — 620s of
true headroom. The lever for a slower deploy is a LARGER authored
`KOMIRA_VALIDATE_TASK_TIMEOUT_S`, never a smaller budget; a step authoring less
is refused below, which is the point.

MIRRORS the lifecycle validator's sleep floor; a test that links both pins them
equal. See the block above for why the mirror exists and why it is safe."""


def parse_positive_decimal(raw: String) -> Optional[Int]:
    """Strict digits-only positive-integer parse — the SAME grammar
    `cloud_run_job_validator.validate_task_timeout_s` applies to the rendered env,
    restated here so this gate accepts exactly the values that gate will honour.

    ⛔ A LENIENT PARSE WOULD MAKE THIS CHECK LIE. `"3600s"` (the likeliest authoring
    typo, since every other duration in the deploy surface is Duration-shaped) would
    truncate to 3600 and pass here — while the renderer rejects it, authors NO
    timeout, and the step runs under the 600s wall this exists to prevent. A value
    this gate accepts but the renderer drops is worse than no gate."""
    var bs = raw.as_bytes()
    if len(bs) == 0:
        return None
    var acc = 0
    for j in range(len(bs)):
        if bs[j] < 0x30 or bs[j] > 0x39:
            return None
        acc = acc * 10 + (Int(bs[j]) - 0x30)
    if acc <= 0:
        return None
    return Optional[Int](acc)


def ends_with_lifecycle_mode(name: String) -> Bool:
    """True iff `name` is `LIFECYCLE_MODE` or a `<PREFIX>_LIFECYCLE_MODE` key.

    ★ SUFFIX-MATCHED, NOT A LITERAL KEY LIST. The key is per-app by construction
    (for example `MAIL_LIFECYCLE_MODE`; the lifecycle library reads whatever key
    its caller names and has NO default app id). A gate keyed on an enumerated
    list of app prefixes would pass the FIRST bundle that introduces a new app —
    which is precisely the bundle nobody has reviewed yet.

    ⛔ THE BARE KEY COUNTS TOO. A length test demanding a name STRICTLY LONGER
    than `_LIFECYCLE_MODE` (15 bytes) would accept `MAIL_LIFECYCLE_MODE` (19) and
    reject `LIFECYCLE_MODE` (14) — the key a lifecycle step most commonly
    authors. The ephemeral-deadline refusal below — whose purpose is that a
    SIGKILL cannot leave a real managed app in a real customer project — would
    then govern only the prefixed keys, and an unarmed gate is
    indistinguishable from a satisfied one. The negative cases (`MODE`,
    `LIFECYCLE_MODEL`, `MAILLIFECYCLE_MODE`, `""`) keep "accept the bare key"
    from becoming "accept everything"."""
    var nb = name.as_bytes()
    var sb = LIFECYCLE_MODE_ENV_SUFFIX.as_bytes()
    # The BARE key: the suffix minus its separating underscore, matched whole.
    # Derived from `LIFECYCLE_MODE_ENV_SUFFIX` rather than typed a second time,
    # so a rename of the token cannot leave the two spellings disagreeing.
    if len(nb) == len(sb) - 1:
        for i in range(len(nb)):
            if nb[i] != sb[i + 1]:
                return False
        return True
    if len(nb) <= len(sb):
        return False
    var off = len(nb) - len(sb)
    for i in range(len(sb)):
        if nb[off + i] != sb[i]:
            return False
    return True


def is_edge_reserved_probe_path(path: String) -> Bool:
    """True iff `path` is terminated by Google's serverless edge before it can
    reach the container, making it unusable as an EXTERNAL deploy probe.

    EXACT match, not prefix and not case-insensitive: `/healthz/`,
    `/healthzz`, `/HEALTHZ` and `/health` all reach the container. A query string
    does not lift the reservation (`/healthz?x=1` is also 404-at-the-edge), but a
    bundle's probe path field carries no query, so an exact compare is the whole
    rule."""
    return path == EDGE_RESERVED_PROBE_PATH


def _edge_reserved_probe_error(label: String, path: String) -> String:
    """The self-correctable message for an external probe aimed at a reserved
    path. Names the replacement, so an author fixes it in one round-trip."""
    return (
        label
        + String(": '")
        + path
        + String(
            "' is RESERVED by Google's serverless edge — it is answered with the"
            " edge's own 404 before the request reaches the container (no"
            " x-cloud-trace-context, and it precedes the IAM check), so this gate can NEVER pass. The Cloud Run startup probe"
            " still uses '"
        )
        + EDGE_RESERVED_PROBE_PATH
        + String(
            "' — that prober dials the container directly and bypasses the edge"
            " — so keep serving it; an EXTERNAL probe must use '"
        )
        + EDGE_SAFE_READINESS_PATH
        + String("', which is the SAME readiness answer and does reach us.")
    )


def _has(name: String, names: List[String]) -> Bool:
    for ref n in names:
        if n == name:
            return True
    return False


def _join(names: List[String]) -> String:
    var out = String("")
    for i in range(len(names)):
        if i > 0:
            out += String(", ")
        out += names[i]
    return out^


def _check_from_build(
    mut errs: List[String], ctx: String, img: ImageRef, build_names: List[String]
):
    """A `from_build` arm must name an existing BuildTarget; a near-miss gets a
    `did you mean`, otherwise the legal set is listed."""
    if img._oneof0_case == 2:
        var target = img.from_build.value()
        if not _has(target, build_names):
            var msg = (
                ctx
                + String(".from_build '")
                + target
                + String("' does not name a build target")
            )
            var s = suggest(target, build_names)
            if s.byte_length() > 0:
                msg += String(" — did you mean '") + s + String("'?")
            else:
                msg += String(" (known: ") + _join(build_names) + String(")")
            errs.append(msg^)


def _check_image(
    mut errs: List[String],
    ctx: String,
    image: Optional[ImageRef],
    required: Bool,
    build_names: List[String],
):
    if not image:
        if required:
            errs.append(ctx + String(": 'image' is required"))
        return
    ref img = image.value()
    if img._oneof0_case == 0:
        errs.append(ctx + String(".image: set exactly one of {digest, from_build}"))
    else:
        _check_from_build(errs, ctx + String(".image"), img, build_names)


# ═══════════════════════════════════════════════════════════════════════════
#  ★ THE INTERNAL ORIGIN IS DIAGNOSTIC-ONLY
# ═══════════════════════════════════════════════════════════════════════════
#
# `VALUE_FROM_INTERNAL_ORIGIN_URL` resolves to the DIRECT `.run.app` service URL
# — the origin the API Gateway forwards to, reached WITHOUT the edge hop. It
# exists so that a validation PAIR — one step direct, one through the gateway —
# can still dial the origin when `VALUE_FROM_DEPLOY_URL` resolves to the gateway.
#
# ⛔ AND IT IS EXACTLY THE MARKER THAT MUST NOT REACH A SERVING WORKLOAD.
# The gateway is where auth, quota, the ApiConfig's declared surface and the
# scoped invoker grant live. A service configured with an origin URL routes
# production traffic around all four — and does it INVISIBLY, because the request
# SUCCEEDS. There is no failed health check, no error rate, nothing to attribute
# later; the only symptom is that a control the deploy believes it applied is not
# applied: a value that looks configured and is not.
#
# So the arm is legal on a `run_container` (a validate step — a DIAGNOSTIC that
# runs, reports, and exits) and REFUSED in the five places a resolved value
# reaches a workload that serves or does real work:
#   `spec.env`, `spec.parameters`, `jobs.env`,
#   `waves.env_override`, `waves.parameter_override`.
#
# ⚠ THE SEAM IS A FLAG ON THE SHARED HELPER, NOT A CHECK AT EACH CALL SITE.
# `_check_env` / `_check_parameters` have five and four callers respectively;
# a rule spelled at the call sites is a rule that a SIXTH caller silently opts
# out of. The parameter defaults to FALSE — refuse — so a new context added
# tomorrow inherits the refusal and must argue its way out, rather than inherit
# the permission and never be noticed. This is the same shape as the `service_ref`
# refusal that already had to distinguish a validate step from a served spec.
comptime _ORIGIN_MARKER_TOKEN: String = "VALUE_FROM_INTERNAL_ORIGIN_URL"

# ═══════════════════════════════════════════════════════════════════════════
#  ★★ THE VALIDATION-RUN OWNERSHIP ID IS ARGV-ONLY
# ═══════════════════════════════════════════════════════════════════════════
#
# `VALUE_FROM_VALIDATION_RUN_ID` resolves to the id of the RUN executing the
# step — a per-run value that `--enforce` later uses to decide whether it may
# delete a billing resource. It has TWO placement rules, and they are different
# rules with different reasons, which is why they are enforced at two sites:
#
#   (a) NOT ON A SERVED SPEC (`spec.env`, `spec.parameters`, `jobs.env`,
#       `waves.env_override`, `waves.parameter_override`) — a run id on a
#       SERVICE is the id of whichever deploy last rolled it, held forever. A
#       sweep that trusted that stamp would delete a production service
#       believing this run owned it: strictly worse than the leak the marker
#       closes. Gated by `diagnostic_step`, the same flag the internal origin
#       uses, so a SIXTH caller added tomorrow inherits the refusal.
#
#   (b) NOT ON ANY `env` CHANNEL AT ALL — including a `run_container`'s own
#       `env`, where the internal origin IS legal. A binary's configuration is
#       a FLAG; authoring the run id on env too would give one value two
#       spellings with different resolution semantics and no diagnostic when an
#       author picks the weaker one. This one is UNCONDITIONAL in
#       `_check_env` and does not consult `diagnostic_step`.
comptime _RUN_ID_MARKER_TOKEN: String = "VALUE_FROM_VALIDATION_RUN_ID"

# ═══════════════════════════════════════════════════════════════════════════
#  ★★ THE LIFECYCLE COMPUTE-ENVIRONMENT NAME IS ARGV-ONLY
# ═══════════════════════════════════════════════════════════════════════════
#
# `VALUE_FROM_LIFECYCLE_ENV_NAME` resolves to the name of the compute
# environment a managed-app release machine's lifecycle wave PRODUCES (its
# `bootstrap` step) and CONSUMES (its `*-e2e` step). The composer derives it
# ONCE per run from the resolved env binding and the RELEASE MACHINE name; no
# bundle authors the string.
#
# ⛔ THE DEFECT IT CLOSES IS A DIVERGENCE, NOT AN ABSENCE. A name authored
# TWICE per bundle — once as the producer's env key, once as the consumer's
# `--cp-env-name` literal — can disagree: the wave bootstraps one environment
# and then refuses because the OTHER name does not exist. `required: true` cannot see it, because a
# bound-but-wrong string satisfies `required` exactly as well as a correct one.
# A gate comparing the two literals would only make it DETECTABLE; resolving one
# value for both steps leaves nothing to disagree with.
#
# Its two placement rules are the run id's two rules, for the run id's two
# reasons:
#
#   (a) NOT ON A SERVED SPEC — the lifecycle environment is a property of a
#       VALIDATION WAVE, not of a workload that serves. Gated by
#       `diagnostic_step`, so a caller added tomorrow inherits the refusal.
#
#   (b) NOT ON ANY `env` CHANNEL AT ALL — a binary's configuration is a flag.
#       ⚠ THIS HALF IS THE LOAD-BEARING ONE FOR THIS MARKER, because the
#       PRODUCER side's natural spelling is an env var
#       (`KOMIRA_BOOTSTRAP_ENV_NAME`). An author arming a `bootstrap` step
#       will reach for that key by muscle memory; the refusal has to name the
#       argv form rather than say "illegal here", or the fix becomes deleting
#       the line — which restores the unbound consumer.
comptime _LIFECYCLE_ENV_MARKER_TOKEN: String = "VALUE_FROM_LIFECYCLE_ENV_NAME"


def _lifecycle_env_on_env_error(label: String) -> String:
    """The `env`-channel refusal (rule (b)). It names the ARGV fix because the
    author's INTENT is right and only the channel is wrong — and because the
    env-key spelling (`KOMIRA_BOOTSTRAP_ENV_NAME`) is the one an author reaches
    for, so "illegal here" reads as "this marker is not for you"."""
    return (
        label
        + String(": 'value_from: ")
        + _LIFECYCLE_ENV_MARKER_TOKEN
        + String(
            "' is not legal on an `env` entry, on a validate step or anywhere"
            " else. It is ARGV-ONLY.\n\n  A binary's configuration is a"
            " command-line FLAG. An env var cannot distinguish NEVER CONFIGURED"
            " from CONFIGURED EMPTY — both are the same bytes — and an empty"
            " compute-environment name is exactly the unbound consumer this"
            " marker exists to make unrepresentable.\n\n  ⚠ If a `bootstrap`"
            " step authors `env { name: \"KOMIRA_BOOTSTRAP_ENV_NAME\" value:"
            " \"…\" }`, declare it as an ARG instead:\n\n    args {\n      name:"
            " \"CP_ENV_NAME\"\n      type: PARAM_TYPE_STRING\n      required:"
            " true\n      flag: \"cp-env-name\"\n      value_from: "
        )
        + _LIFECYCLE_ENV_MARKER_TOKEN
        + String(
            "\n    }\n\n  which renders `--cp-env-name=<name>` — the SAME"
            " resolved string the consuming step is handed, from the SAME"
            " derivation, so the producer and the consumer cannot disagree."
        )
    )


def _lifecycle_env_misplaced_error(label: String) -> String:
    """The served-workload refusal (rule (a)). States the CONSEQUENCE: a served
    workload configured with a lifecycle environment name is claiming to be part
    of a validation wave it outlives."""
    return (
        label
        + String(": 'value_from: ")
        + _LIFECYCLE_ENV_MARKER_TOKEN
        + String(
            "' is legal ONLY on a `validate { run_container { args { … } } }`"
            " entry, and this is not one.\n\n  It resolves to the compute"
            " environment a RELEASE MACHINE's lifecycle wave produces and"
            " consumes — a per-wave, per-machine value the composer derives from"
            " the env binding and the machine name.\n\n  A workload that SERVES"
            " holds its configuration for as long as the revision runs, so a"
            " lifecycle environment name stamped here would outlive the wave"
            " that named it and would keep pointing at an environment a later"
            " `unbootstrap` may have destroyed.\n\n  If this step is a lifecycle"
            " validator, it belongs in a validate step's `args` — which is the"
            " one place this marker resolves."
        )
    )


def _run_id_on_env_error(label: String) -> String:
    """The `env`-channel refusal (rule (b)). It must name the ARGV fix, because
    the author's intent is right and only the channel is wrong — a bare "illegal
    here" sends them to delete the line, which is the outcome that leaks."""
    return (
        label
        + String(": 'value_from: ")
        + _RUN_ID_MARKER_TOKEN
        + String(
            "' is not legal on an `env` entry, on a validate step or anywhere"
            " else. It is ARGV-ONLY.\n\n  A binary's configuration is a"
            " command-line FLAG. Authoring it on env as well would give ONE value"
            " TWO spellings — a flag that is either omitted or `--x=`, and an env var"
            " for which 'never configured' and 'configured empty' are the same"
            " bytes. An author who picked the weaker channel would get no"
            " diagnostic.\n\n  Declare it as an ARG instead:\n\n    args {\n     "
            " name: \"VALIDATION_RUN_ID\"\n      type: PARAM_TYPE_STRING\n     "
            " required: true\n      value_from: "
        )
        + _RUN_ID_MARKER_TOKEN
        + String("\n    }\n\n  which renders `--validation-run-id=<id>`.")
    )


def _run_id_misplaced_error(label: String) -> String:
    """The served-workload refusal (rule (a)). States the CONSEQUENCE, not the
    rule: a stamp on a long-lived service is a licence to delete it."""
    return (
        label
        + String(": 'value_from: ")
        + _RUN_ID_MARKER_TOKEN
        + String(
            "' is legal ONLY on a `validate { run_container { args { … } } }`"
            " entry, and this is not one.\n\n  It resolves to the id of the"
            " VALIDATION RUN that is executing a step — a per-run value whose"
            " whole purpose is to let an unattended cloud-leak cleanup"
            " PROVE that this run created a billing resource before deleting"
            " it.\n\n  A workload that SERVES holds its configuration for as long"
            " as the revision runs, so stamping one here records the id of"
            " whichever deploy last rolled it — permanently, and long after that"
            " run ended. A sweep that then trusted the stamp would delete a"
            " PRODUCTION service believing it owned it. That is a larger failure"
            " than the unattributed leak this marker exists to close, and it"
            " would look correct at every step.\n\n  If this step is a diagnostic"
            " that must report under the run's ownership id, it belongs in a"
            " validate step's `args` — which is the one place this marker"
            " resolves."
        )
    )


def _internal_origin_misplaced_error(label: String) -> String:
    """The refusal, which must state the CONSEQUENCE and not merely the rule.

    "Illegal here" sends the author hunting for a syntax error. What they need to
    know is that the value they asked for is a documented way around the gateway,
    and that the fix is either to author the front door or to move the step."""
    return (
        label
        + String(": 'value_from: ")
        + _ORIGIN_MARKER_TOKEN
        + String(
            "' is legal ONLY on a `validate { run_container { … } }` step (its"
            " `env` or `args`), and this is not one.\n\n  It resolves to the"
            " DIRECT Cloud Run service URL — the origin behind the API Gateway."
            " Handing that to a workload that SERVES (or to a job that does real"
            " work) routes production traffic past the gateway, and therefore"
            " past the auth, the quota, the ApiConfig's declared surface and the"
            " scoped invoker grant that live only there.\n\n  It would not fail"
            " loudly: the request SUCCEEDS. There is no failed health check and"
            " no error rate — the only symptom is that a control this deploy"
            " believes it applied is silently not applied.\n\n  If this workload"
            " needs its own front door, use `value_from: VALUE_FROM_DEPLOY_URL`"
            " (the published endpoint). If it is a diagnostic that must prove the"
            " DIRECT path specifically, it belongs in a validate step — which is"
            " the one place this marker resolves."
        )
    )


# ═══════════════════════════════════════════════════════════════════════════
#  ⭐ JOB-VM FIELDS — DECLARED, AND REFUSED BY NAME UNTIL HONOURED
# ══════════════════════════════════════════════════════════════════════════════
#
# Validate REFUSES each of these authored fields by name until the deploy
# honours it. Every field below PARSES and RE-EMITS, and nothing composes,
# resolves or grants from any of them yet. A field that parses and is then
# silently ignored is the fail-quiet answer: the author reads the bundle as
# saying something the deploy never does. So each is refused HERE, offline,
# naming the field and what makes it honourable; that change deletes its arm:
#
#   VALUE_FROM_COMPUTE_ENV_{SERVICE_ACCOUNT,SUBNETWORK,ZONE,PROJECT,PLACER}
#       — on an ARG (validate step) and on a served PARAMETER. ⛔ On an `env`
#       entry it is refused PERMANENTLY: a binary's configuration is a flag, so
#       it is argv-only, the run id's and the lifecycle env name's rule (b). See
#       `compute_env_value_from_on_env_error`.
#   AppParameter.from_build (arm 6)
#   RunContainer.own_identity
#   RunContainer.reads_telemetry TELEMETRY_READ_JOB_VM_STATE
#   Wave.api_edge_services
#   BuildTarget.file_role
#   BuildTarget.repository_role
#
# ⚠ THE VALUE_FROM AND from_build ARMS SIT IN THE SHARED FAN-IN HELPERS
# (`_check_env`, `_check_parameter`), NOT IN A WALK OF KNOWN LOCATIONS, so every
# channel that validates an env var or a parameter inherits the refusal —
# including `w.env_override`, which a walk of known locations would miss.


def job_vm_s0_refusal(label: String, what: String, lands_in: String) -> String:
    """The ONE sentence every declared-but-not-honoured refusal uses, so each
    names the field, says it is declared-but-not-honoured, and names what makes
    it honourable."""
    return (
        label
        + String(": '")
        + what
        + String(
            "' is DECLARED but not yet honoured. It becomes honourable when "
        )
        + lands_in
        + String(
            ", which deletes this refusal; accepted before then it would parse,"
            " re-emit and be silently IGNORED by compose, so the bundle would say"
            " something the deploy never does. Remove it until then."
        )
    )


def compute_env_value_from_on_env_error(label: String, token: String) -> String:
    """⛔ THE PERMANENT `env`-CHANNEL REFUSAL of a `VALUE_FROM_COMPUTE_ENV_*` —
    rule (b) of the run id and the lifecycle env name, for the same reason: these
    five are a validator's EXPECT_* CONFIGURATION, rendered as `--expect-*`
    flags, and a binary's configuration is argv. So this is NOT a "not yet": the
    resolution lands on the ARGV channel and deletes the arg/parameter refusal,
    and this one stays.

    ONE sentence, PUBLIC, because two ladders say it: `validate_bundle`'s
    `_check_env` (offline) and the validate driver's `_resolve_env_entry` (the
    defence for a bundle that reached the driver without validating). It names
    the ARGV fix, because the author's intent is right and only the channel is
    wrong — a bare "illegal here" sends them to delete the line."""
    return (
        label
        + String(": 'value_from: ")
        + token
        + String(
            "' is not legal on an `env` entry, on a validate step or anywhere"
            " else. It is ARGV-ONLY, permanently — this is not a temporary"
            " refusal.\n\n  A binary's configuration is a command-line FLAG. A VALUE_FROM_COMPUTE_ENV_* value is a"
            " validator's EXPECT_* input, and an env var cannot distinguish"
            " NEVER CONFIGURED from CONFIGURED EMPTY — both are the same bytes,"
            " and an empty expectation graded against a VM is a hollow green."
            "\n\n  Declare it as an ARG instead:\n\n    args {\n      name:"
            " \"EXPECT_…\"\n      type: PARAM_TYPE_STRING\n      required:"
            " true\n      value_from: "
        )
        + token
        + String("\n    }\n\n  which renders `--expect-…=<value>`.")
    )


def is_compute_env_value_from(v: Int) -> Bool:
    """True iff `v` is one of the five `VALUE_FROM_COMPUTE_ENV_*` ordinals
    (8-12). One predicate, so the validator, the validate driver's two ladders
    and the eventual resolver key on the same set."""
    return (
        v == ValueFrom.VALUE_FROM_COMPUTE_ENV_SERVICE_ACCOUNT
        or v == ValueFrom.VALUE_FROM_COMPUTE_ENV_SUBNETWORK
        or v == ValueFrom.VALUE_FROM_COMPUTE_ENV_ZONE
        or v == ValueFrom.VALUE_FROM_COMPUTE_ENV_PROJECT
        or v == ValueFrom.VALUE_FROM_COMPUTE_ENV_PLACER
    )


def _check_env(
    mut errs: List[String],
    ctx: String,
    e: BundleEnvVar,
    diagnostic_step: Bool = False,
):
    """Validate ONE `BundleEnvVar`.

    `diagnostic_step` is TRUE only when `ctx` is a `run_container` validate step —
    a container that runs, reports and exits, and reaches no serving traffic. It
    gates the INTERNAL-ORIGIN arm and nothing else; every other arm behaves
    identically in both contexts, which is what keeps
    `VALUE_FROM_DEPLOY_URL` markers (and the ENV-derived arms) legal on a served
    spec. It DEFAULTS to False so a caller added later refuses by default."""
    var label = ctx + String(" env '") + e.name + String("'")
    if e.name.byte_length() == 0:
        errs.append(ctx + String(": an env var is missing its 'name'"))
    if e._oneof0_case == 0:
        errs.append(label + String(": set exactly one of {value, value_from}"))
    elif e._oneof0_case == 2:
        if e.value_from.value().value == ValueFrom.VALUE_FROM_UNSPECIFIED:
            errs.append(
                label
                + String(
                    ": 'value_from' must be a known reference (VALUE_FROM_DEPLOY_URL)"
                )
            )
        elif (
            e.value_from.value().value
            == ValueFrom.VALUE_FROM_INTERNAL_ORIGIN_URL
            and not diagnostic_step
        ):
            errs.append(_internal_origin_misplaced_error(label))
        elif (
            e.value_from.value().value
            == ValueFrom.VALUE_FROM_VALIDATION_RUN_ID
        ):
            # ⛔ UNCONDITIONAL — it does NOT consult `diagnostic_step`, and that
            # asymmetry with the arm above is the point. The internal origin is a
            # question of WHICH CONTEXT may name it; this is a question of WHICH
            # CHANNEL carries it, and the answer is argv in every context.
            errs.append(_run_id_on_env_error(label))
        elif (
            e.value_from.value().value
            == ValueFrom.VALUE_FROM_LIFECYCLE_ENV_NAME
        ):
            # ⛔ UNCONDITIONAL, for the reason directly above and one more that is
            # specific to this marker: the natural env-key spelling
            # (`KOMIRA_BOOTSTRAP_ENV_NAME`) must not stay legal. If this arm
            # consulted `diagnostic_step` that spelling would stay legal on
            # exactly the steps most likely to use it.
            errs.append(_lifecycle_env_on_env_error(label))
        elif is_compute_env_value_from(e.value_from.value().value):
            # ⛔ UNCONDITIONAL AND PERMANENT — the two arms above, for the same
            # reason: WHICH CHANNEL carries it, and the answer is argv in every
            # context. Not a `job_vm_s0_refusal`: their resolution lands on ARGV
            # and deletes only the arg/parameter refusal in `_check_parameter`.
            errs.append(
                compute_env_value_from_on_env_error(
                    label, e.value_from.value().json_name()
                )
            )


# ═══════════════════════════════════════════════════════════════════════════
#  ★ THE MANAGED-APP PARAMETERS (`AppSpec.parameters`, field 31)
# ═══════════════════════════════════════════════════════════════════════════
#
# The parameter NAME grammar. UPPER_SNAKE, <=64 chars. This is a check on the
# SHAPE OF A NAME and never on WHICH names exist — the same check the control
# plane applies, which is what lets the control plane stay generic.
comptime PARAM_NAME_MAX_LEN: Int = 64
# The `secret_ref` grammar. A SECRET parameter carries a HANDLE, never a value.
comptime PARAM_SECRET_SCHEME: String = "secret://"


def param_name_is_legal(name: String) -> Bool:
    """`^[A-Z][A-Z0-9_]{0,63}$` — the parameter-name grammar, shared verbatim
    with the control plane's generic validation.

    ⚠ THIS IS THE ONLY NAME RULE ANYWHERE IN THE SYSTEM, AND IT IS DELIBERATELY
    A RULE ABOUT SHAPE. Nothing may check a name against a LIST of known names:
    the moment any layer outside the bundle knows that `LOCAL_DOMAINS` is a
    thing, "the control plane understands only a generic concept of parameters"
    has become false."""
    if name.byte_length() == 0 or name.byte_length() > PARAM_NAME_MAX_LEN:
        return False
    var b = name.as_bytes()
    if not (b[0] >= UInt8(ord("A")) and b[0] <= UInt8(ord("Z"))):
        return False
    for i in range(1, len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("_"))
        )
        if not ok:
            return False
    return True


def param_flag_for(prm: AppParameter) -> String:
    """The argv LONG FLAG this parameter renders as, WITHOUT the leading `--`.

    An authored `flag` wins; otherwise DERIVED as `name.lower()` with `_` -> `-`.
    ONE derivation, used by the validator, by compose's argv render, and by any
    reader that needs to name the flag in a message — so a refusal can never
    quote a flag the container does not actually receive."""
    if prm.flag.byte_length() > 0:
        return prm.flag.copy()
    var out = String("")
    var b = prm.name.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord("_")):
            out += String("-")
        elif c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            out += String(chr(Int(c) + 32))
        else:
            out += String(chr(Int(c)))
    return out^


def is_lifecycle_mode_arg(prm: AppParameter) -> Bool:
    """True iff this validate-step ARG carries the managed-app lifecycle mode.

    ★ THE ARGV TWIN OF `ends_with_lifecycle_mode`. A binary's configuration is on
    argv, and the lifecycle mode is configuration. An ephemeral-deadline refusal
    (which keeps a SIGKILL from stranding a managed app in a customer project)
    that scanned `rc.env` ALONE would match NOTHING for a step that declares its
    mode in `args`: the refusal would be silently disarmed, and every
    step-scanning reader would iterate an empty list and stay green.

    ⛔ THAT FAILURE MODE FAILS OPEN. The gate that would merely annoy an author
    fails closed; the gate that protects a customer project fails open. Hence
    both predicates.

    ★ KEYED ON THE RENDERED FLAG, DERIVED THROUGH `param_flag_for` — never on
    `prm.name`, and never on the VALUE. See `LIFECYCLE_MODE_ARG_FLAG`.

    Falsifier: `test_validate.mojo`'s
    `test_the_ephemeral_gate_sees_an_ARGS_declared_mode` and its five siblings,
    whose negative arm (`MODE`, `LIFECYCLE_MODEL`, a `LOG_LEVEL` merely VALUED
    `ephemeral`) is what keeps "accept the mode arg" from becoming "accept every
    arg" — which would arm a 4600s deadline demand on every validate step."""
    return param_flag_for(prm) == LIFECYCLE_MODE_ARG_FLAG


def _param_int_is_legal(v: String) -> Bool:
    """A base-10 signed integer, and nothing else. Used to check an INT
    parameter's `default` / literal `value` AT DEPLOY rather than discovering it
    in a container's crash log."""
    if v.byte_length() == 0:
        return False
    var b = v.as_bytes()
    var start = 0
    if b[0] == UInt8(ord("-")) or b[0] == UInt8(ord("+")):
        if len(b) == 1:
            return False
        start = 1
    for i in range(start, len(b)):
        if not (b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9"))):
            return False
    return True


def _param_parse_i64(v: String) -> Int64:
    """Parse a base-10 signed integer WITHOUT raising. `validate_bundle` is a
    non-raising function that returns a list of errors, so it cannot call `atol`;
    and it must not, because the point of the caller is to REPORT a bad value
    rather than to abort on it. Only ever called after `_param_int_is_legal`."""
    var b = v.as_bytes()
    var neg = False
    var i = 0
    if len(b) > 0 and (b[0] == UInt8(ord("-")) or b[0] == UInt8(ord("+"))):
        neg = b[0] == UInt8(ord("-"))
        i = 1
    var acc = Int64(0)
    while i < len(b):
        acc = acc * Int64(10) + Int64(Int(b[i]) - ord("0"))
        i += 1
    return -acc if neg else acc


def _param_bool_is_legal(v: String) -> Bool:
    """`true|false|1|0`, case-insensitive — the spellings the shared argv reader
    accepts. Kept in lock-step with the shared argv reader's bool parser
    (`kci_params`)."""
    var s = v.lower()
    return (
        s == String("true")
        or s == String("false")
        or s == String("1")
        or s == String("0")
    )


def _check_parameter(
    mut errs: List[String],
    ctx: String,
    prm: AppParameter,
    is_override: Bool = False,
    diagnostic_step: Bool = False,
):
    """Validate ONE `AppParameter`.

    ⛔ EVERY RULE HERE REFUSES A DECLARATION THAT WOULD BE A LIE AT DEPLOY TIME.
    A constraint that cannot apply to its type is not a harmless no-op — it is a
    statement the author believes is being enforced, and it is not."""
    var label = ctx + String(" parameter '") + prm.name + String("'")
    if prm.name.byte_length() == 0:
        errs.append(ctx + String(": a parameter is missing its 'name'"))
        return
    if not param_name_is_legal(prm.name):
        errs.append(
            label
            + String(
                ": 'name' must match ^[A-Z][A-Z0-9_]{0,63}$ (UPPER_SNAKE). The"
                " name is a parameter ID, NOT an env key — the value reaches the"
                " container as --"
            )
            + param_flag_for(prm)
            + String("=<value> on argv.")
        )

    var ty = prm.type.value
    # An OVERRIDE is a PARTIAL declaration — it supplies the env-correct value and
    # INHERITS type / required / description / constraints from the spec-level
    # entry of the same name. Demanding a full re-declaration per wave would mean
    # three copies of every constraint and three places for them to drift.
    if ty == ParamType.PARAM_TYPE_UNSPECIFIED and not is_override:
        errs.append(
            label
            + String(
                ": 'type' is required (PARAM_TYPE_STRING | PARAM_TYPE_INT |"
                " PARAM_TYPE_BOOL | PARAM_TYPE_ENUM | PARAM_TYPE_SECRET)"
            )
        )

    # ── required vs default: a `required` parameter with a default can NEVER
    #    refuse, which makes `required` a lie. The refusal is the entire feature.
    if prm.required and prm.default.byte_length() > 0:
        errs.append(
            label
            + String(
                ": 'required: true' and a non-empty 'default' are contradictory —"
                " a parameter with a default can never be missing, so the deploy"
                " could never refuse and 'required' would be a false statement."
                " Drop one."
            )
        )

    # ── the DESCRIPTION is load-bearing on a required parameter: the deploy-time
    #    refusal quotes it verbatim, and that message is what an operator reads
    #    at 3am. A required parameter with no description refuses with no purpose.
    if prm.required and prm.description.byte_length() == 0 and not is_override:
        errs.append(
            label
            + String(
                ": a 'required' parameter must carry a 'description' — the"
                " deploy-time refusal quotes it VERBATIM, and a refusal that"
                " cannot say what the parameter is for sends the operator"
                " hunting."
            )
        )

    # ── constraints must be applicable to the type ──────────────────────────
    if len(prm.allowed_values) > 0 and ty != ParamType.PARAM_TYPE_ENUM:
        errs.append(
            label
            + String(
                ": 'allowed_values' applies only to PARAM_TYPE_ENUM — on any"
                " other type it is silently unenforced, which reads as a"
                " constraint and is not one."
            )
        )
    if ty == ParamType.PARAM_TYPE_ENUM and len(prm.allowed_values) == 0:
        errs.append(
            label
            + String(
                ": PARAM_TYPE_ENUM requires 'allowed_values' — an enum with no"
                " members accepts everything."
            )
        )
    if prm.regex.byte_length() > 0 and ty != ParamType.PARAM_TYPE_STRING:
        errs.append(
            label + String(": 'regex' applies only to PARAM_TYPE_STRING")
        )
    if (prm.has_min or prm.has_max) and ty != ParamType.PARAM_TYPE_INT:
        errs.append(
            label + String(": 'min'/'max' apply only to PARAM_TYPE_INT")
        )
    if prm.has_min and prm.has_max and prm.min > prm.max:
        errs.append(
            label
            + String(": 'min' (")
            + String(Int(prm.min))
            + String(") exceeds 'max' (")
            + String(Int(prm.max))
            + String(") — no value can satisfy it")
        )

    # ── SECRET custody. The published images are already secret-free (all 14
    #    `secret://` entries carry handles); what was missing is the contract.
    if ty == ParamType.PARAM_TYPE_SECRET:
        if prm._oneof0_case == 1:
            errs.append(
                label
                + String(
                    ": a PARAM_TYPE_SECRET must not carry a literal 'value' — a"
                    " secret literal in a checked-in bundle is exactly what this"
                    " model exists to prevent. Use"
                    " 'secret_ref: \"secret://<name>\"'."
                )
            )
        if prm.default.byte_length() > 0:
            errs.append(
                label
                + String(
                    ": a PARAM_TYPE_SECRET must not carry a 'default' — a default"
                    " secret is a secret in the bundle."
                )
            )
    if prm._oneof0_case == 2:
        if ty != ParamType.PARAM_TYPE_SECRET:
            errs.append(
                label
                + String(
                    ": 'secret_ref' requires 'type: PARAM_TYPE_SECRET' — the type"
                    " is what makes the value a REFERENCE on argv rather than"
                    " plaintext, and argv is readable by other processes on the"
                    " same machine (e.g. /proc/<pid>/cmdline on Linux, ps on any"
                    " Unix)."
                )
            )
        if not prm.secret_ref.value().startswith(PARAM_SECRET_SCHEME):
            errs.append(
                label
                + String(": 'secret_ref' must start with '")
                + String(PARAM_SECRET_SCHEME)
                + String("' (a handle, never a value)")
            )

    # ── a MARKER arm must name a real producer ───────────────────────────────
    if prm._oneof0_case == 3:
        if prm.marker.value().value == ParamMarker.PARAM_MARKER_UNSPECIFIED:
            errs.append(
                label
                + String(
                    ": 'marker' must name a registered producer"
                    " (PARAM_MARKER_PROJECT | PARAM_MARKER_REGION |"
                    " PARAM_MARKER_DATASTORE_DATABASE |"
                    " PARAM_MARKER_APP_DEPLOYMENT_ID |"
                    " PARAM_MARKER_APP_SIGNING_JWKS |"
                    " PARAM_MARKER_ORG_MAIL_DOMAIN |"
                    " PARAM_MARKER_ORG_ID)"
                )
            )
    if prm._oneof0_case == 4:
        if prm.value_from.value().value == ValueFrom.VALUE_FROM_UNSPECIFIED:
            errs.append(
                label
                + String(
                    ": 'value_from' must be a known reference"
                    " (VALUE_FROM_DEPLOY_URL | VALUE_FROM_EDGE_URL)"
                )
            )
        # ⛔ THE ARGV TWIN OF THE ENV RULE. Governing `env` and not `args` would
        # leave the ban bypassable by moving one line — and argv is the MORE
        # dangerous channel, not the less: `--target-url` is AUTHORITATIVE in
        # every CP validator and in the service binaries that take a flag.
        elif (
            prm.value_from.value().value
            == ValueFrom.VALUE_FROM_INTERNAL_ORIGIN_URL
            and not diagnostic_step
        ):
            errs.append(_internal_origin_misplaced_error(label))
        # ★★ THE RUN-ID MARKER ON A SERVED PARAMETER (rule (a)). Same
        # `diagnostic_step` seam as the arm above, for the same reason it is a
        # flag on the shared helper rather than a check at each of the four call
        # sites: a fifth caller added tomorrow inherits the refusal.
        elif (
            prm.value_from.value().value
            == ValueFrom.VALUE_FROM_VALIDATION_RUN_ID
            and not diagnostic_step
        ):
            errs.append(_run_id_misplaced_error(label))
        # ★★ THE LIFECYCLE ENV NAME ON A SERVED PARAMETER (rule (a)),
        # on the same `diagnostic_step` seam and for the same inheritance reason.
        elif (
            prm.value_from.value().value
            == ValueFrom.VALUE_FROM_LIFECYCLE_ENV_NAME
            and not diagnostic_step
        ):
            errs.append(_lifecycle_env_misplaced_error(label))
        # ⭐ JOB-VM — refused in EVERY context (served parameter, override AND
        # validate-step arg: until they are resolved the flag would be silently
        # OMITTED — an EXPECT_* compared against the validator's own default is
        # a hollow green).
        # ⚠ THIS is the refusal the resolution deletes for a validate-step ARG
        # (the argv channel is where these resolve). The `env`-channel refusal
        # in `_check_env` is permanent and is not this one.
        elif is_compute_env_value_from(prm.value_from.value().value):
            errs.append(
                job_vm_s0_refusal(
                    label,
                    String("value_from: ") + prm.value_from.value().json_name(),
                    String("the deploy resolves compute-environment values"),
                )
            )
    if prm._oneof0_case == 6:
        # ⭐ JOB-VM — `from_build` (field 18), refused in every context.
        errs.append(
            job_vm_s0_refusal(
                label,
                String("from_build: ") + prm.from_build.value(),
                String("the deploy resolves build outputs into parameters and args"),
            )
        )
    if prm._oneof0_case == 5:
        if prm.service_ref.value().service.byte_length() == 0:
            errs.append(
                label + String(": 'service_ref' is missing its 'service'")
            )

    # ── the literal / default must SATISFY the declared type. Checking it here
    #    is the difference between a typo caught at deploy with a name and a
    #    container that boots and misbehaves.
    var literal = String("")
    var has_literal = False
    if prm._oneof0_case == 1:
        literal = prm.value.value().copy()
        has_literal = True
    elif prm.default.byte_length() > 0:
        literal = prm.default.copy()
        has_literal = True
    if has_literal:
        if ty == ParamType.PARAM_TYPE_INT:
            if not _param_int_is_legal(literal):
                errs.append(
                    label
                    + String(": PARAM_TYPE_INT value '")
                    + literal
                    + String("' is not a base-10 integer")
                )
            else:
                var n = _param_parse_i64(literal)
                if prm.has_min and n < prm.min:
                    errs.append(
                        label
                        + String(": value '")
                        + literal
                        + String("' is below 'min' ")
                        + String(Int(prm.min))
                    )
                if prm.has_max and n > prm.max:
                    errs.append(
                        label
                        + String(": value '")
                        + literal
                        + String("' is above 'max' ")
                        + String(Int(prm.max))
                    )
        elif ty == ParamType.PARAM_TYPE_BOOL:
            if not _param_bool_is_legal(literal):
                errs.append(
                    label
                    + String(": PARAM_TYPE_BOOL value '")
                    + literal
                    + String("' is not true|false|1|0")
                )
        elif ty == ParamType.PARAM_TYPE_ENUM:
            if len(prm.allowed_values) > 0 and not _has(
                literal, prm.allowed_values
            ):
                errs.append(
                    label
                    + String(": PARAM_TYPE_ENUM value '")
                    + literal
                    + String("' is not in allowed_values {")
                    + _join(prm.allowed_values)
                    + String("}")
                )


def _check_parameters(
    mut errs: List[String],
    ctx: String,
    params: List[AppParameter],
    is_override: Bool = False,
    declared: List[String] = List[String](),
    diagnostic_step: Bool = False,
):
    """Validate a parameter LIST — every member, plus the two list-level rules:
    no duplicate NAME and no duplicate FLAG.

    ⚠ THE FLAG COLLISION IS THE ONE A NAME CHECK MISSES. `flag` defaults to a
    DERIVATION of `name`, so two distinct names can derive one flag once either
    authors an explicit `flag`. Two parameters rendering `--x=` twice is not a
    schema error the name check can see, and the container would silently take
    whichever its parser reached last."""
    var seen_names = List[String]()
    var seen_flags = List[String]()
    for ref prm in params:
        _check_parameter(errs, ctx, prm, is_override, diagnostic_step)
        if prm.name.byte_length() == 0:
            continue
        # ⛔ AN OVERRIDE MUST NAME A PARAMETER THE SPEC DECLARES. This is the rule
        # that matters most on this path: an override for an undeclared name is
        # silently ignored by compose, so the author sees a per-env value in the
        # bundle, believes it is bound, and the container is configured by
        # something else entirely — a value that LOOKS configured and is not —
        # and a typo in a wave block is exactly how it would arise.
        if is_override and not _has(prm.name, declared):
            errs.append(
                ctx
                + String(": parameter_override '")
                + prm.name
                + String(
                    "' does not match any 'parameters' entry in spec — an"
                    " override for an undeclared parameter is silently ignored,"
                    " so the bundle would state a per-env value that never"
                    " reaches the container. Declare it in spec.parameters."
                )
            )
        if _has(prm.name, seen_names):
            errs.append(
                ctx
                + String(": duplicate parameter name '")
                + prm.name
                + String("'")
            )
        else:
            seen_names.append(String(prm.name))
        var fl = param_flag_for(prm)
        if _has(fl, seen_flags):
            errs.append(
                ctx
                + String(" parameter '")
                + prm.name
                + String("': flag '--")
                + fl
                + String(
                    "' collides with another parameter's flag. Two parameters"
                    " rendering the same argv flag mean the container silently"
                    " takes one of them; set an explicit 'flag' on one."
                )
            )
        else:
            seen_flags.append(fl^)


# ── THE DATASTORE'S DATABASE NAME (`AppSpec.datastore_database`, field 27) ───
# The env-var-name SUFFIX that marks an env as naming the app's Firestore database.
# A SUFFIX, not one exact name, because different apps spell it differently
# (`KOMIRA_FIRESTORE_DATABASE`, `PIPELINE_MANAGER_FIRESTORE_DATABASE`, …), and a
# rule keyed on one of them would leave the others free to hold a literal. It is still an exact, statable rule (no value guessing), which is what
# separates it from a heuristic.
comptime DATASTORE_DATABASE_ENV_SUFFIX: String = "_FIRESTORE_DATABASE"
# The marker an env value must carry to be told the database id. Kept in lock-step
# with the deploy manifest mapper's `DATASTORE_DATABASE_TOKEN`, which substitutes it.
comptime DATASTORE_DATABASE_TOKEN: String = "${datastore_database}"


def _check_datastore_database(
    mut errs: List[String],
    ctx: String,
    sp: AppSpec,
    is_customer_tenancy: Bool,
):
    """Validate the service's DATASTORE IDENTITY — WHICH database, and WHO OWNS IT.

    ⛔ THE ABSENT VALUE IS AN ERROR, NOT A DEFAULT, and that is the whole design.
    Both possible defaults fail silently: a fixed `control-plane` would create the
    operator's database name in every account the `--env` binding names, customer
    accounts included, and DERIVING one from the app name would repoint every
    existing deploy at a fresh EMPTY database (create-if-absent succeeds, indexes get ensured, the deploy is green,
    and every document written before that day is invisible).

    ★ THE OWNERSHIP HALF IS DELEGATED, ON PURPOSE. The four-state own-XOR-reference
    policy lives in `datastore_identity.datastore_identity_error` — ONE function,
    which the release CLI's deploy seam also calls (as `resolve_datastore_identity`,
    which raises instead of accumulating). Two copies of a four-case policy is two
    things that can disagree about who provisions a customer's data, so there is
    one. This validator adds only what is genuinely local to authoring: the marker
    rule on the env that carries the address.

    THE `*_FIRESTORE_DATABASE` ENV MUST CARRY THE MARKER, NEVER A LITERAL. That env
    is how the app is TOLD the address, and a literal there is precisely how the
    STAMPED database and the ENSURED database come to differ. A database that is
    stamped but never ensured exists with ZERO composite indexes, so the first
    list-query returns a 400 FAILED_PRECONDITION and nothing in the deploy says
    so. Author `${datastore_database}`; the mapper substitutes the SAME string
    the deploy bakes into the index-ensure step — and, for a REFERENCED database, the
    same string it probes for existence."""
    var identity_error = datastore_identity_error(ctx, sp)
    if identity_error.byte_length() > 0:
        errs.append(identity_error^)

    # ★ THE PLACEMENT RULE: a managed app's database lives in the CUSTOMER's
    # project. Delegated for the same reason the ownership half above is — ONE
    # function, so the validator and any deploy-seam caller cannot disagree about
    # who holds a customer's data. Enforcing it here, at authoring time, covers
    # every bundle rather than a hand-written list.
    var placement_error = managed_app_placement_error(ctx, is_customer_tenancy, sp)
    if placement_error.byte_length() > 0:
        errs.append(placement_error^)

    # ★ THE OTHER HALF OF THE PARTITION (managed apps never reference the
    # control-plane database at all). The arm above stops a
    # managed app reaching INTO the operator's namespace; this one stops an operator
    # bundle reaching OUT of it. Both are needed for the id namespace to be a
    # DECISION PROCEDURE — while it overlaps, no gate downstream (in particular a
    # deployed-topology check) can tell an operator database from an app database
    # by name. Same delegation reason as its neighbour: ONE function, two
    # presentations.
    var namespace_error = control_plane_database_namespace_error(
        ctx, is_customer_tenancy, sp
    )
    if namespace_error.byte_length() > 0:
        errs.append(namespace_error^)
    for ref e in sp.env:
        if not e.name.endswith(DATASTORE_DATABASE_ENV_SUFFIX):
            continue
        # Only the literal-VALUE arm can hold a literal id; a `value_from`
        # reference is a different (already-checked) shape.
        if e._oneof0_case != 1:
            continue
        var authored = e.value.value().copy() if e.value else String("")
        if authored == DATASTORE_DATABASE_TOKEN:
            continue
        errs.append(
            ctx
            + String(" env '")
            + e.name
            + String("': must be authored as the marker \"")
            + DATASTORE_DATABASE_TOKEN
            + String(
                "\", not as a literal. This env is how the deployed app is TOLD"
                " which database to read, and the deploy resolves that SAME address"
                " from the bundle's `datastore_database` / `datastore_database_ref` —"
                " a literal here lets the two differ. A database that is stamped but"
                " never ensured exists with ZERO composite indexes, so the app's first"
                " list-query returns a 400 FAILED_PRECONDITION and nothing in the"
                " deploy says so. Author the marker; both sides then read the one"
                " string. Authored value was: '"
            )
            + authored
            + String("'.")
        )


def _check_datastore_collections(
    mut errs: List[String], ctx: String, sp: AppSpec
):
    """Validate `AppSpec.datastore_collections` — the collection shapes this
    service's datastore holds (field 35).

    ⛔ THE FIRST CHECK IS THE ONE THAT MATTERS, AND IT IS A SILENT DROP. The
    composer emits a kind-4 node ONLY when the spec declares a `DatastoreNeed` of
    SERVERLESS/DEDICATED (the compose pass's per-service node emission and its
    shared-infrastructure arm). So a collection authored beside `datastore: NONE` reaches
    NO node, is provisioned by NOTHING, and says nothing — the file reads as
    though the app's storage were shaped and the deploy is green. That is the
    exact fail-quiet this whole field exists to remove, one level up.

    THE REST ARE ALL OF ONE KIND: a shape whose EMPTY or HALF form is ACCEPTED
    HERE and REFUSED — or, worse, MATERIALIZED — later.
      * an empty `name` — on one arm the name IS the collection's address and is
        carried verbatim, so an empty one addresses a collection named "";
      * a duplicate `name` in one spec — two blocks for one collection read as
        though both applied, and on the arm that materializes them they are two
        writers over one address;
      * a missing `primary_access_path` — a collection with no identity, which
        is not a thing either cloud can hold;
      * a path with no `partition_field`, or a partition field with no type;
      * a half-authored ordered pair (a NAME with no TYPE or a TYPE with no
        NAME) — refused rather than resolved by dropping the half that was
        written, because EITHER half dropped produces a different collection;
      * a type token outside the closed neutral vocabulary;
      * a SECONDARY path with no `name` — that name is the index name on both
        clouds and is how a re-deploy recognises the index it already made;
      * a PRIMARY path WITH a name — the primary path has no name of its own on
        either cloud, so an authored one materializes into nothing;
      * a duplicate secondary-path name within one collection.

    ⛔⛔ WHY EVERY ONE OF THESE IS A REFUSAL AND NOT A DEFAULT. On the arm that
    materializes an access path the result is a KEY SCHEMA, and a key schema is
    IMMUTABLE: there is no update form that changes a partition key, a sort key
    or an attribute type, and the only path between two designs is
    destroy-and-recreate, which loses every row. A validator that supplied a
    missing half would make the answer permanent as well as wrong.

    ⚠ ONE RULE IS DELIBERATELY NOT HERE, AND ITS ABSENCE IS A STATED NON-DECISION
    RATHER THAN AN OMISSION: whether a service that REFERENCES a sibling's
    database (`datastore_database_ref`) may declare collection shapes.
    `_check_index_tables` above refuses exactly that for indexes, and the
    argument transfers on its face — but a referencing service DOES compose a
    kind-4 node (an adopt-probe), so the shapes are not provisioned by nothing
    the way a consumer's indexes are, and refusing here would block an authoring
    that may be correct. It is written down here rather than guessed.

    ⚠ AND THE THREE TYPE TOKENS ARE SPELLED IN THIS FILE, which is a SECOND copy
    of a vocabulary the composer and the AWS arm also spell. That is accepted on
    purpose: the field is a proto3 `string` (it must be — the tokens are neutral
    and each arm maps them), so the parser cannot resolve it against a closed set
    the way it does an enum, and the alternative to a second copy is discovering
    a typo at MAP time on the one axis where the wrong answer is permanent. The
    three tokens are the proto's own, stated in `DatastoreAccessPath.
    partition_field_type`."""
    if len(sp.datastore_collections) == 0:
        return
    if (
        sp.datastore.value != DatastoreNeed.DATASTORE_NEED_SERVERLESS
        and sp.datastore.value != DatastoreNeed.DATASTORE_NEED_DEDICATED
    ):
        errs.append(
            ctx
            + String(
                ": 'datastore_collections' is declared but 'datastore' is"
                " NONE/unstated. The composer emits a DATASTORE node ONLY for a"
                " SERVERLESS/DEDICATED need, so these collection shapes would"
                " reach NO node, be provisioned by NOTHING, and say nothing —"
                " the bundle would read as though this app's storage were"
                " shaped while the deploy created none of it. Declare"
                " `datastore: DATASTORE_NEED_SERVERLESS`, or delete the"
                " collections."
            )
        )
    var seen_names = List[String]()
    for i in range(len(sp.datastore_collections)):
        ref c = sp.datastore_collections[i]
        var cctx = (
            ctx + String(": datastore_collections[") + String(i) + String("]")
        )
        if c.name.byte_length() == 0:
            errs.append(
                cctx
                + String(
                    ": 'name' is required. It is carried VERBATIM and never"
                    " derived — on one arm it IS the table name, unique per"
                    " account and region, so a derived one silently ADOPTS or"
                    " COLLIDES with whatever already holds it."
                )
            )
        else:
            for j in range(len(seen_names)):
                if seen_names[j] == c.name:
                    errs.append(
                        cctx
                        + String(": duplicate 'name' \"")
                        + c.name
                        + String(
                            "\". Two blocks for one collection read as though"
                            " both applied; whichever is second is the only one"
                            " a name-keyed reader keeps, and on the arm that"
                            " materializes them they are two writers over one"
                            " address."
                        )
                    )
                    break
            seen_names.append(String(c.name))
        if not c.primary_access_path:
            errs.append(
                cctx
                + String(
                    ": 'primary_access_path' is required. A collection with no"
                    " primary access path is a table with no key, which is not"
                    " a thing that can exist — and a defaulted key is permanent"
                    " and destroys every row to correct."
                )
            )
        else:
            _check_datastore_access_path(
                errs,
                cctx + String(": primary_access_path"),
                c.primary_access_path.value(),
                False,
            )
        var seen_paths = List[String]()
        for k in range(len(c.secondary_access_paths)):
            ref sap = c.secondary_access_paths[k]
            var sctx = (
                cctx
                + String(": secondary_access_paths[")
                + String(k)
                + String("]")
            )
            _check_datastore_access_path(errs, sctx, sap, True)
            if sap.name.byte_length() == 0:
                continue
            for j in range(len(seen_paths)):
                if seen_paths[j] == sap.name:
                    errs.append(
                        sctx
                        + String(": duplicate 'name' \"")
                        + sap.name
                        + String(
                            "\" within this collection. The name is the index"
                            " name on both clouds and is how a re-deploy"
                            " recognises the index it already created."
                        )
                    )
                    break
            seen_paths.append(String(sap.name))


def _check_datastore_field_type(
    mut errs: List[String], ctx: String, field: String, token: String
):
    """One NEUTRAL field-type token, against the closed vocabulary the proto
    states. EMPTY is handled by the caller (it is a different sentence: "not
    stated" rather than "not a token")."""
    if token.byte_length() == 0:
        return
    if (
        token == String("string")
        or token == String("number")
        or token == String("bytes")
    ):
        return
    errs.append(
        ctx
        + String(": '")
        + field
        + String("' is \"")
        + token
        + String(
            "\", which is not one of the neutral tokens `string` / `number` /"
            " `bytes`. ⚠ Do NOT author a vendor's own attribute letters here —"
            " every arm reads this field and each maps the neutral token into"
            " its own vocabulary. There is deliberately no default: an"
            " attribute type is part of a key schema, a key schema is"
            " IMMUTABLE, and the only path from a wrong one to a right one"
            " destroys every row."
        )
    )


def _check_datastore_access_path(
    mut errs: List[String],
    ctx: String,
    p: DatastoreAccessPath,
    is_secondary: Bool,
):
    """One access path, primary or secondary. ONE function for both because they
    are the SAME message; `is_secondary` decides only the two rules that differ,
    and both are about the path's NAME — which the primary does not have on
    either cloud and the secondary REQUIRES."""
    if is_secondary and p.name.byte_length() == 0:
        errs.append(
            ctx
            + String(
                ": 'name' is required on a SECONDARY access path — it is the"
                " index name on both clouds, and it is how a re-deploy"
                " recognises the index it already created rather than making a"
                " second one."
            )
        )
    if not is_secondary and p.name.byte_length() > 0:
        errs.append(
            ctx
            + String(": 'name' is set to \"")
            + p.name
            + String(
                "\" on the PRIMARY access path. The primary path has no name of"
                " its own on either cloud (it is the collection's own"
                " identity), so an authored one materializes into nothing. A"
                " NAMED query shape is a `secondary_access_paths` block."
            )
        )
    if p.partition_field.byte_length() == 0:
        errs.append(
            ctx
            + String(
                ": 'partition_field' is required — it is the equality half of"
                " the query, it is chosen when the collection is created, and"
                " on one arm it can NEVER be changed."
            )
        )
    if p.partition_field_type.byte_length() == 0:
        errs.append(
            ctx
            + String(
                ": 'partition_field_type' is required. An untyped key would have"
                " to be defaulted, and a defaulted attribute type is permanent"
                " and uncorrectable — author `string`, `number` or `bytes`."
            )
        )
    _check_datastore_field_type(
        errs, ctx, String("partition_field_type"), p.partition_field_type
    )
    if (
        p.ordered_field.byte_length() == 0
        and p.ordered_field_type.byte_length() > 0
    ):
        errs.append(
            ctx
            + String(
                ": 'ordered_field_type' is set with no 'ordered_field'. A"
                " half-authored key is refused rather than resolved by dropping"
                " the half that was written — either half, dropped, produces a"
                " different and permanent collection."
            )
        )
    if (
        p.ordered_field.byte_length() > 0
        and p.ordered_field_type.byte_length() == 0
    ):
        errs.append(
            ctx
            + String(": 'ordered_field' \"")
            + p.ordered_field
            + String("\" has no 'ordered_field_type'.")
        )
    _check_datastore_field_type(
        errs, ctx, String("ordered_field_type"), p.ordered_field_type
    )


def _check_index_tables(mut errs: List[String], ctx: String, sp: AppSpec):
    """Validate `AppSpec.index_tables` — the composite-index shapes THIS bundle
    declares for the database it OWNS (field 29).

    ⛔ THE FIRST CHECK IS THE ONE THAT MATTERS: INDEXES MAY ONLY BE DECLARED BY
    THE OWNER. A bundle that names `datastore_database_ref` is a CONSUMER — the
    owner's deploy is the only thing that ensures indexes on that database, so a
    consumer's declaration provisions nothing. And it does not merely do nothing:
    the reference PROBE checks the live database against what the owner ensures,
    so a set nobody creates is a set the probe can never satisfy, and every
    consumer deploy is refused forever. One database, one owner, one
    declaration — the same rule fields 27/28 already carry, applied to the shapes.

    The remaining checks are all of one kind: a shape whose EMPTY form is
    ACCEPTED BY FIRESTORE and therefore invisible after deploy.
      * an empty `table` — the collection group is the URL path segment of the
        CreateIndex call, so an empty one addresses a group named "";
      * a table with no `indexes` — declares nothing while reading as though it
        did, which is the fail-quiet the whole change exists to remove;
      * an empty index `name` — the name is how a re-deploy recognises the index
        it already created; without one every deploy creates a duplicate;
      * an index with no `fields` — a composite index over nothing;
      * a duplicate index name within one table — the second silently replaces
        the first in any name-keyed reader;
      * an empty `col`;
      * `desc: true` together with `array_contains: true` — Firestore's array
        mode has NO direction, and an ORDERED index on an array column is a
        legal, DIFFERENT index that does not serve an `array-contains` query.
        That confusion creates READY, permanently useless indexes. The cloud
        will not tell you.

    `scope` needs no check here: the parser resolves it against a CLOSED
    two-token vocabulary and refuses anything else BY POSITION, which is a better
    diagnostic than a validate error can be."""
    if len(sp.index_tables) == 0:
        return
    if sp.datastore_database_ref.byte_length() > 0:
        errs.append(
            ctx
            + String(
                ": 'index_tables' may only be declared by the bundle that OWNS"
                " the database ('datastore_database'), never by one that"
                " REFERENCES it ('datastore_database_ref'). The owner's deploy is"
                " the only thing that ensures indexes, so shapes declared here"
                " would be provisioned by nothing — and the reference probe would"
                " then demand them of a live database forever, refusing every"
                " deploy of this bundle. Declare them in the owning bundle."
            )
        )
    var seen_tables = List[String]()
    for i in range(len(sp.index_tables)):
        ref t = sp.index_tables[i]
        var tctx = ctx + String(": index_tables[") + String(i) + String("]")
        if t.table.byte_length() == 0:
            errs.append(
                tctx
                + String(
                    ": 'table' is required (the collection group the indexes are"
                    " created on, e.g. \"widget\")"
                )
            )
        else:
            for j in range(len(seen_tables)):
                if seen_tables[j] == t.table:
                    errs.append(
                        tctx
                        + String(": duplicate 'table' \"")
                        + t.table
                        + String(
                            "\". Two blocks for one table read as though both"
                            " applied; whichever is second is the only one a"
                            " name-keyed reader keeps."
                        )
                    )
                    break
            seen_tables.append(String(t.table))
        if len(t.indexes) == 0:
            errs.append(
                tctx
                + String(
                    ": 'indexes' is required and must be non-empty. A table block"
                    " with no index declares nothing while reading as though it"
                    " did — which is exactly the fail-quiet bundle-declared"
                    " indexes exist to remove."
                )
            )
        var seen_names = List[String]()
        for j in range(len(t.indexes)):
            ref ix = t.indexes[j]
            var ictx = tctx + String(" indexes[") + String(j) + String("]")
            if ix.name.byte_length() == 0:
                errs.append(
                    ictx
                    + String(
                        ": 'name' is required — it is how a re-deploy recognises"
                        " the index it already created."
                    )
                )
            else:
                for k in range(len(seen_names)):
                    if seen_names[k] == ix.name:
                        errs.append(
                            ictx
                            + String(": duplicate index name \"")
                            + ix.name
                            + String("\" on table \"")
                            + t.table
                            + String("\".")
                        )
                        break
                seen_names.append(String(ix.name))
            if len(ix.fields) == 0:
                errs.append(
                    ictx
                    + String(
                        ": 'fields' is required and must be non-empty (a"
                        " composite index over no column indexes nothing)."
                    )
                )
            for k in range(len(ix.fields)):
                ref f = ix.fields[k]
                var fctx = ictx + String(" fields[") + String(k) + String("]")
                if f.col.byte_length() == 0:
                    errs.append(fctx + String(": 'col' is required."))
                if f.desc and f.array_contains:
                    errs.append(
                        fctx
                        + String(
                            ": 'desc' and 'array_contains' are mutually exclusive."
                            " Firestore's array-membership mode has no direction,"
                            " and an ORDERED index on an array column is a legal,"
                            " DIFFERENT index that does NOT serve an"
                            " 'array-contains' query. The cloud accepts it"
                            " silently, leaving a permanently useless index."
                        )
                    )


def _check_secured_inbound_routes(mut errs: List[String], sp: AppSpec):
    """Validate `AppSpec.secured_inbound_routes` — the ADDITIONAL routes the EDGE
    authenticates (federated callers).

    ⛔ EVERY CHECK HERE IS FAIL-CLOSED IN THE SAME DIRECTION: an under-specified
    secured route must be REFUSED, never rendered as something weaker. The reason
    is a property of the target: ESPv2 accepts a document whose operation names a
    `security` requirement that no `securityDefinitions` entry defines, and it
    leaves that route OPEN. So a route the author called secured, that renders
    without a definition, is a PUBLIC route that reads as a configured one — and
    for a webhook app that means anyone who can reach the gateway can POST into
    it. There is no shape of this that is safe to default.

    The checks, and what each one is preventing:
      * a secured route without `inbound: WEBHOOK` — there is no SINGLE_PATH edge
        to hang it on, so it would be silently DROPPED at compose;
      * an empty/relative `route_path` — an empty one renders a `paths:` key of
        `:` (rejected at ApiConfig create, but only after the deploy reported the
        render done);
      * a `route_path` equal to `inbound_route_path` — two `paths:` keys with one
        value means the LAST wins, so one of the two policies vanishes silently;
      * a DUPLICATE `route_path` among the secured routes — same collision;
      * `policy` UNSPECIFIED, or a policy the render cannot secure a route with;
      * an empty `sa_email` — renders a definition no token can satisfy;
      * two secured routes naming DIFFERENT service accounts — the render emits
        ONE definition, so one principal would silently replace the other and the
        pin would still read as configured.

    ⛔ THERE IS NO AUDIENCE CHECK HERE, AND ITS ABSENCE IS DELIBERATE. An authored
    `aud` could only be checked for SHAPE, never for CONTENT: the value has to
    equal the origin of the gateway that serves the route, and that hostname is
    generated at Gateway CREATE, after the ApiConfig. So there is no field (proto
    field 4, reserved), the
    parser refuses the spelling by name, and the conformer binds the audience
    from the live `Gateway.default_hostname`. A validator cannot check a string
    the cloud has not chosen yet; it can only make a wrong one look reviewed.

    The last two are also enforced at the render (`build_webhook_ingress_
    openapi` / `EdgeAuthPolicy.federated_sa_jwt`). Both layers are kept: this one
    names the BUNDLE FIELD the author must fix, and it fires at bundle validation
    with no cloud, no credentials and no deploy."""
    if len(sp.secured_inbound_routes) == 0:
        return
    if sp.inbound.value != InboundNeed.INBOUND_NEED_WEBHOOK:
        errs.append(
            String(
                "spec: 'secured_inbound_routes' requires 'inbound:"
                " INBOUND_NEED_WEBHOOK'. A secured route is an ADDITIONAL route on"
                " the single-path inbound edge; without that edge there is nothing"
                " to attach it to and it would be silently dropped at compose."
            )
        )
    var seen_paths = List[String]()
    var first_sa = String("")
    for i in range(len(sp.secured_inbound_routes)):
        ref r = sp.secured_inbound_routes[i]
        var ctx = String("spec: secured_inbound_routes[") + String(i) + String("]")
        if r.route_path.byte_length() == 0:
            errs.append(
                ctx
                + String(
                    # ⚠️ THE EXAMPLE IS DELIBERATELY NOT A REAL PRODUCTION ROUTE:
                    # an example inside an error message that copied one would be
                    # a copy that silently goes stale.
                    ": 'route_path' is required (e.g. \"/hooks/inbound\"). An"
                    " empty one renders a `paths:` key of `:` — the document is"
                    " rejected at ApiConfig create, but only after the deploy has"
                    " reported the render as done."
                )
            )
        elif not r.route_path.startswith(String("/")):
            errs.append(
                ctx
                + String(": 'route_path' must start with '/' (got '")
                + r.route_path
                + String("')")
            )
        if r.route_path.byte_length() > 0 and r.route_path == sp.inbound_route_path:
            errs.append(
                ctx
                + String(": 'route_path' ('")
                + r.route_path
                + String(
                    "') collides with 'inbound_route_path'. Two `paths:` keys with"
                    " the same value means the LAST one wins silently, so one of"
                    " the two policies would vanish from the served document with"
                    " nothing to observe it."
                )
            )
        if r.route_path.byte_length() > 0 and _has(r.route_path, seen_paths):
            errs.append(
                ctx
                + String(": duplicate secured 'route_path' '")
                + r.route_path
                + String("' (the same silent last-one-wins collision)")
            )
        if r.route_path.byte_length() > 0:
            seen_paths.append(String(r.route_path))
        if (
            r.policy.value
            != EdgeAuthPolicyKind.EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT
        ):
            # ★ THE FALSIFIER THE WHOLE FIELD EXISTS FOR. UNSPECIFIED lands here
            # and so does any future non-federated value, and both must REFUSE
            # rather than degrade: a route declared secured whose policy renders no
            # security DEFINITION emits a `security` requirement naming nothing,
            # and ESPv2 serves that route OPEN.
            errs.append(
                ctx
                + String(
                    ": 'policy' must be EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT."
                    " It is the only policy the edge render can actually secure a"
                    " route with; the pass-through policies are edge-WIDE by"
                    " construction, and securing a route with one would emit a"
                    " `security` requirement naming a definition that is never"
                    " rendered — which the gateway ACCEPTS, leaving the route open."
                )
            )
        if r.sa_email.strip().byte_length() == 0:
            errs.append(
                ctx
                + String(
                    ": 'sa_email' is required — it is BOTH the issuer the edge"
                    " matches AND the account whose published keys the edge"
                    " fetches, and an empty one renders a security definition no"
                    " token can satisfy (every request 401s, which reads as a"
                    " broken deploy rather than as this)."
                )
            )
        elif first_sa.byte_length() == 0:
            first_sa = String(r.sa_email)
        elif first_sa != r.sa_email:
            errs.append(
                ctx
                + String(": 'sa_email' ('")
                + r.sa_email
                + String("') differs from an earlier secured route's ('")
                + first_sa
                + String(
                    "'). The render emits ONE security definition for the whole"
                    " edge, so one of the two principals would be silently replaced"
                    " by the other while the pin still read as configured. Give"
                    " them separate deployments until the render emits per-route"
                    " definition names."
                )
            )


def _check_run_container(
    mut errs: List[String],
    ctx: String,
    rc: RunContainer,
    build_names: List[String],
    # ── ★ THE THREE FACTS A `test_role` REFUSAL NEEDS AND A `run_container` DOES
    #    NOT CARRY. ⛔ NONE OF THEM HAS A DEFAULT, for the reason
    #    `_run_validate_gates`' own parameter block records: a defaulted argument
    #    on a fan-in helper is a fail-quiet by construction — a future caller
    #    silently opts out of the axis and NOTHING goes red. Here the axis is a
    #    privilege refusal, so the fail-quiet arm mints a live control-plane
    #    identity for a bundle that was never allowed to ask for one. Omitting
    #    them is a COMPILE ERROR. ──
    #
    # The names this bundle actually serves — what `grants_on_service` must
    # resolve against.
    served_names: List[String],
    # NON-EMPTY iff this step is EXCLUDED from a resolved run. An excluded step
    # places no job, so a role provisioned for it is a live identity nobody
    # presents — see the refusal.
    excluded_because: String,
    # `tenancy: TENANCY_CONTROL_PLANE`, POSITIVELY. ⛔ Never `not is_customer`:
    # `Tenancy` has THREE members and UNSPECIFIED is the proto3 zero, so the
    # negated spelling treats a bundle that simply forgot to author `tenancy:` as
    # ours. (The same reasoning `deploy_is_control_plane` states verbatim.)
    is_control_plane: Bool,
    # The org a test role may never target (empty = none reserved). ⛔ NO
    # DEFAULT here either; only the public entry point carries one.
    reserved_org_id: String,
):
    _check_image(errs, ctx, rc.image, True, build_names)
    if rc.gate_on.value == GateOn.GATE_ON_UNSPECIFIED:
        errs.append(ctx + String(": 'gate_on' is required (GATE_ON_EXIT_CODE)"))
    for ref e in rc.env:
        # `diagnostic_step=True` — THE ONLY site that passes it. A `run_container`
        # validate step runs, reports and exits; it serves no traffic and holds no
        # revision, so it is the one context where naming the INTERNAL ORIGIN is a
        # measurement rather than a route around the gateway. Every other caller
        # of `_check_env` takes the default (False) and is refused.
        _check_env(errs, ctx, e, diagnostic_step=True)
        # ── ★ A `service_ref` ENV IS NOT RESOLVABLE ON A VALIDATE STEP ─────────
        #
        # `_check_env` is shared with `spec.env`, where arm 3 is CORRECT and
        # load-bearing (bundles compose their `run.invoker` grants from it), so the refusal cannot live there — it has to key on
        # the ARM *and* the CONTEXT, and this is the context.
        #
        # Here arm 3 resolves to EMPTY and is DROPPED WITHOUT A WORD: the
        # validate driver resolves it to `""` and skips every empty resolution.
        # The container then starts with the variable ABSENT — loud only if the
        # validator requires that key, and SILENT if it reads it with a default
        # (a probe that defaults a peer URL to `http://127.0.0.1:<port>` would
        # report green about localhost while the bundle reads as pointing at a
        # sibling service).
        #
        # ⚠ THIS IS THE CONSTRUCT THE SHAPE INVITES. "Endpoints are references
        # that resolve at deploy time, not literals" is the standing direction,
        # and `service_ref` is syntactically exactly that — so it is the first
        # thing an author reaches for, and today it fails quiet. A comment cannot
        # converge; this refusal is that comment given a wire.
        #
        # ⛔ INVERT, DO NOT DELETE, when the resolution lands. Once a validate step
        # CAN resolve a sibling endpoint, this becomes an assertion that the ref
        # RESOLVES. Deleting it would hand the silent drop back to the construct
        # the shape encourages.
        if e._oneof0_case == 3:
            errs.append(
                ctx
                + String(" env '")
                + e.name
                + String(
                    "': 'service_ref' resolves to NOTHING on a validate step."
                    " The arm is legal on `spec.env` (a SERVED container, where"
                    " compose emits the peer grant and the runtime URL comes"
                    " from the ServiceRegistry) but a validate step has no such"
                    " wire: the driver resolves it to an EMPTY string and drops"
                    " the variable, so the container runs with it ABSENT — green"
                    " about whatever default the validator falls back to. Until"
                    " validate-step reference resolution lands, either (a) have"
                    " the validator read the peer endpoint REGISTRY-FIRST from"
                    " `service/<name>` in the `<project>-bootstrap`"
                    " ServiceRegistry, or (b) author the literal peer URL."
                )
            )
        # EDGE-RESERVED PROBE PATH (see the block at the top of this file). A
        # probe run_container step carries its probe path as the
        # `CP_PROBE_HEALTH_PATH` env, and it dials the converged deploy_url —
        # i.e. THROUGH the edge. Aiming it at `/healthz` gates on Google's 404.
        # Only the LITERAL-`value` arm is checkable; a `value_from` reference
        # resolves at deploy time and carries no authored path.
        if e.name == PROBE_HEALTH_PATH_ENV and e._oneof0_case == 1:
            ref probe_path = e.value.value()
            if is_edge_reserved_probe_path(probe_path):
                errs.append(
                    _edge_reserved_probe_error(
                        ctx
                        + String(" env '")
                        + PROBE_HEALTH_PATH_ENV
                        + String("'"),
                        probe_path,
                    )
                )
    # ── ★ EPHEMERAL LIFECYCLE ⇒ AN AUTHORED DEADLINE THAT FITS THE BUDGET ─────
    #
    # ⛔ THE UNPAIRED SHAPE LEAVES A DEPLOYED APP IN A CUSTOMER PROJECT. A step
    # declaring `<APP>_LIFECYCLE_MODE: "ephemeral"` creates a real managed app and
    # then deletes it; its guaranteed polling wall is
    # `LIFECYCLE_GUARANTEED_POLL_FLOOR_S` and an unauthored `taskTemplate.timeout`
    # is Cloud Run's 600s. The task is SIGKILLed after the deploy POST and before
    # the delete, a SIGKILL runs NO reap, and the only net behind it is a later
    # run's stale-orphan sweep. See the lifecycle block at the top of this file.
    #
    # Only the LITERAL-`value` arm is checkable in both directions, and that is the
    # right scope: a `value_from` MODE resolves at deploy time and cannot be read
    # here, so this refuses only what it can actually prove.
    #
    # ★ TWO CHANNELS, ONE ASSERTION. The mode may be declared on env or on argv
    # (configuration belongs on argv), so the question "did this step declare an
    # ephemeral lifecycle?" has to be asked of BOTH `rc.env` and `rc.args`.
    # Everything below is untouched by that: the same `KOMIRA_VALIDATE_TASK_
    # TIMEOUT_S` lookup in `rc.env`, the same `parse_positive_decimal`, the same
    # floor, the same two refusal texts.
    #
    # ⛔ THE ENV ARM DOES NOT GO AWAY WHEN THE LAST BUNDLE CONVERTS. A bundle on
    # a branch, or a partially-converted one, can still author the env spelling,
    # and the guard that catches an unpaired env step must keep working until the
    # tree is provably free of them. Deleting it early re-opens the exact window
    # this two-source scan exists to close.
    var declared_ephemeral = String("")
    var declared_channel = String("")
    for ref e in rc.env:
        if (
            ends_with_lifecycle_mode(e.name)
            and e._oneof0_case == 1
            and e.value.value() == LIFECYCLE_MODE_EPHEMERAL_VALUE
        ):
            declared_ephemeral = e.name.copy()
            declared_channel = String("env")
            break
    if declared_ephemeral.byte_length() == 0:
        for ref a in rc.args:
            if (
                is_lifecycle_mode_arg(a)
                and a._oneof0_case == 1  # the LITERAL `value` arm
                and a.value.value() == LIFECYCLE_MODE_EPHEMERAL_VALUE
            ):
                declared_ephemeral = a.name.copy()
                declared_channel = String("arg")
                break
    if declared_ephemeral.byte_length() > 0:
        var authored_deadline = Optional[Int]()
        var raw_deadline = String("")
        var saw_key = False
        for ref e in rc.env:
            if e.name == VALIDATE_TASK_TIMEOUT_ENV and e._oneof0_case == 1:
                saw_key = True
                raw_deadline = e.value.value().copy()
                authored_deadline = parse_positive_decimal(raw_deadline)
                break
        if not authored_deadline:
            var why = String(
                "' but authors NO `KOMIRA_VALIDATE_TASK_TIMEOUT_S`"
            )
            if saw_key:
                why = (
                    String(
                        "' but its `KOMIRA_VALIDATE_TASK_TIMEOUT_S` is not a"
                        " positive whole number of SECONDS (got '"
                    )
                    + raw_deadline
                    + String(
                        "'; a Duration-shaped value like '3600s' is REJECTED by"
                        " the renderer and authors no timeout at all)"
                    )
                )
            errs.append(
                ctx
                + String(" run_container: declares ")
                + declared_channel
                + String(" '")
                + declared_ephemeral
                + String(": ephemeral")
                + why
                + String(
                    ". An ephemeral lifecycle CREATES a real managed app in a"
                    " real customer project and then deletes it; its guaranteed"
                    " polling wall is "
                )
                + String(LIFECYCLE_GUARANTEED_POLL_FLOOR_S)
                + String(
                    "s, and a Cloud Run Job with no authored"
                    " taskTemplate.timeout gets Google's 600s default. The task"
                    " is therefore SIGKILLed mid-lifecycle — after the deploy"
                    " POST, before the delete — and a SIGKILL runs NO reap, so"
                    " the run LEAVES THE DEPLOYED APP BEHIND. Author `env { name:"
                    ' "KOMIRA_VALIDATE_TASK_TIMEOUT_S" value: "3600" }` on this'
                    " step."
                )
            )
        elif authored_deadline.value() < LIFECYCLE_GUARANTEED_POLL_FLOOR_S:
            errs.append(
                ctx
                + String(" run_container: declares ")
                + declared_channel
                + String(" '")
                + declared_ephemeral
                + String(": ephemeral' with KOMIRA_VALIDATE_TASK_TIMEOUT_S=")
                + String(authored_deadline.value())
                + String("s, which is BELOW the lifecycle's guaranteed polling"
                         " wall of ")
                + String(LIFECYCLE_GUARANTEED_POLL_FLOOR_S)
                + String(
                    "s. The task cannot finish inside its own deadline, so it is"
                    " SIGKILLed after the deploy POST and before the delete,"
                    " running NO reap and LEAVING THE DEPLOYED APP BEHIND in a"
                    " customer project. Raise the deadline; do NOT shrink the"
                    " budgets to fit, which only moves the kill earlier in the"
                    " matrix."
                )
            )
    # ── `reads_secret` — a BARE Secret Manager id, offline-checkable ───────────
    # The name becomes a GRANT TARGET (compose_api._append_validate_step_secret_
    # grant_nodes -> a resource-scoped SetIamPolicy on `projects/<p>/secrets/
    # <name>`). A `projects/…` path or a `secret://…` URL would compose a node
    # that looks right, applies against a resource id that does not exist, and
    # leaves the container's own `:access` still 403ing — the exact silent shape
    # this field was added to end. Refused at load, where it costs nothing.
    for ref s in rc.reads_secret:
        if s.byte_length() == 0:
            errs.append(
                ctx
                + String(
                    ": 'reads_secret' entry is EMPTY — a grant with no target"
                    " resource. Name the Secret Manager secret, or delete the"
                    " line."
                )
            )
            continue
        if s.find(String("secret://")) == 0:
            errs.append(
                ctx
                + String(": 'reads_secret' entry '")
                + s
                + String(
                    "' is a `secret://` URL. That form is a SERVICE env mount"
                    " (compose_api turns it into a Cloud Run secretKeyRef); a"
                    " validate step has no such wire. Author the BARE secret"
                    " name."
                )
            )
            continue
        if s.find(String("projects/")) == 0 or s.find(String("/")) >= 0:
            errs.append(
                ctx
                + String(": 'reads_secret' entry '")
                + s
                + String(
                    "' is a resource PATH, not a secret name. The grant target"
                    " is the bare secret id (e.g."
                    " 'orders-oauth-client-secret'); the project and"
                    " the `projects/…/secrets/…` framing are added by the"
                    " conformer."
                )
            )
    # ── ★ `reads_telemetry` — the read-only observability planes (field 8) ────
    # Each entry composes ONE project-scoped READ grant for the identity this
    # step's job runs as. Two refusals, both offline:
    #
    #  * UNSPECIFIED — the proto3 zero. It would compose a Grant node carrying
    #    `CAPABILITY_UNSPECIFIED`, which `_role_for_capability` fail-fasts on at
    #    APPLY time, an hour later, naming an ordinal instead of the bundle line
    #    that wrote it. A privilege declaration that means nothing is refused at
    #    the line that wrote it.
    #  * A DUPLICATE — two entries compose two nodes binding the SAME
    #    `(projects/<P>, member, role)` triple under read-modify-write
    #    SetIamPolicy, the race `_append_validate_step_secret_grant_nodes` dedupes
    #    for. Deduping silently would hide an author's mistake, and the duplicate
    #    says nothing the single entry did not.
    for i in range(len(rc.reads_telemetry)):
        ref tr = rc.reads_telemetry[i]
        if tr.value == 0:
            errs.append(
                ctx
                + String(
                    ": 'reads_telemetry' entry is TELEMETRY_READ_UNSPECIFIED —"
                    " a grant for no capability. Name the plane"
                    " (TELEMETRY_READ_LOGS / TELEMETRY_READ_METRICS), or delete"
                    " the line."
                )
            )
            continue
        if tr.value == TelemetryRead.TELEMETRY_READ_JOB_VM_STATE:
            # ⭐ JOB-VM — the CUSTOMER-granted observe read.
            errs.append(
                job_vm_s0_refusal(
                    ctx,
                    String("reads_telemetry: TELEMETRY_READ_JOB_VM_STATE"),
                    String("the deploy composes the job-VM state read grant"),
                )
            )
            continue
        for j in range(i):
            if rc.reads_telemetry[j].value == tr.value:
                errs.append(
                    ctx
                    + String(": 'reads_telemetry' entry '")
                    + tr.json_name()
                    + String(
                        "' is DUPLICATED. Each plane composes ONE project-scoped"
                        " grant node; two nodes binding the same"
                        " (project, member, role) triple race each other under"
                        " read-modify-write SetIamPolicy. Declare it once."
                    )
                )
                break
    # ── ★ `args` — the ARGV this validator's entrypoint receives (field 5) ─────
    # Reuses `_check_parameters` WHOLE: the name shape, the type/constraint pairing,
    # the duplicate-NAME rule and — the one a name check misses — the duplicate-FLAG
    # rule, since two args rendering `--x=` twice mean the container silently takes
    # one of them. One message, one validator, no second spelling.
    # `diagnostic_step=True` for the same reason the `env` loop above passes it,
    # and it must be BOTH channels or neither: a rule that governed `env` and left
    # `args` open is bypassed by moving one line.
    _check_parameters(
        errs,
        ctx + String(" run_container"),
        rc.args,
        diagnostic_step=True,
    )
    # ⛔ AND THE THREE `source` ARMS THAT CANNOT MEAN ANYTHING HERE. Each is legal
    # on a managed-app parameter, so `_check_parameter` ACCEPTS it — and then it
    # renders WRONG on a validate step, which is exactly the silent shape this
    # field exists to end. Each is refused at load, where it costs nothing.
    for ref a in rc.args:
        if a._oneof0_case == 2:  # secret_ref
            errs.append(
                ctx
                + String(" run_container arg '")
                + a.name
                + String(
                    "': 'secret_ref' is refused on a validate-step arg. Argv is"
                    " readable by other processes on the same machine (e.g."
                    " /proc/<pid>/cmdline on Linux, ps on any Unix), and the"
                    " tokens appear in every `gcloud run jobs describe` and every"
                    " deploy audit log. A validator that needs a secret declares"
                    " it in 'reads_secret' and fetches it under its own identity,"
                    " or reads it from env."
                )
            )
        elif a._oneof0_case == 3:  # marker
            errs.append(
                ctx
                + String(" run_container arg '")
                + a.name
                + String(
                    "': 'marker' is refused on a validate-step arg. The"
                    " ParamMarker producers resolve against a MANAGED-APP"
                    " deployment (its org, its mail domain, its signing key); a"
                    " validate step has no such subject, so the marker would"
                    " resolve to nothing and render an empty flag."
                )
            )
        elif a._oneof0_case == 5:  # service_ref
            errs.append(
                ctx
                + String(" run_container arg '")
                + a.name
                + String(
                    "': 'service_ref' is refused on a validate-step arg TODAY."
                    " `ValueFrom` is SELF-scoped (see app_bundle.proto), so a"
                    " sibling service's endpoint resolves to NOTHING here and the"
                    " arg would render `--"
                )
                + param_flag_for(a)
                + String(
                    "=` — a flag that says 'configured to nothing' when the truth"
                    " is 'never resolved'. That empty-vs-absent confusion is the"
                    " whole reason this field exists. Until a cross-bundle ref"
                    " marker exists, author the peer URL as a literal 'value'."
                )
            )
    # ── ★ `vpc_egress` — the DIRECT VPC EGRESS attachment (field 7) ────────────
    # ABSENT is legal and is the default for every step that exists: no block =>
    # no `vpcAccess` on the CreateJob wire => the job egresses over the PUBLIC
    # INTERNET. What is refused here is a PRESENT block that Cloud Run would
    # reject, checked offline where it costs nothing instead of arriving as a
    # CreateJob error after a build and a push.
    if rc.vpc_egress:
        _check_validate_vpc_egress(errs, ctx, rc.vpc_egress.value())
    # ── ★ `test_role` — the EPHEMERAL KOMIRA CALLER IDENTITIES (field 9) ───────
    _check_test_roles(
        errs,
        ctx,
        rc.test_role,
        served_names,
        excluded_because,
        is_control_plane,
        reserved_org_id,
    )
    # ── ⭐ `own_identity` (field 10) — declared-not-honoured refusal ──────
    if rc.own_identity.byte_length() > 0:
        errs.append(
            job_vm_s0_refusal(
                ctx,
                String("own_identity: ") + rc.own_identity,
                String("the deploy graph creates step-owned identities"),
            )
        )


# =============================================================================
# ★ THE `test_role` REFUSALS (`RunContainer.test_role`, field 9).
# =============================================================================
#
# THE RESERVED CONTROL-PLANE ORG — CALLER-SUPPLIED, WITH A DEFAULT. A control
# plane may reserve one organization for its own machines, and a test role must
# never be provisioned into it. Which id that is belongs to the control plane's
# identity store, not to this package (which depends on `kci_bundle_proto` +
# `komira_proto_codec` and nothing else), so `validate_bundle` takes it as the
# `reserved_org_id` argument. A caller that links the identity store should pass
# the id it declares, so the refusal checks the authority rather than a copy.
# An EMPTY value means the control plane reserves no org, and the check is off.
comptime DEFAULT_RESERVED_ORG_ID: StaticString = (
    "00000000-0000-7000-8000-000000000001"
)
"""The default for `validate_bundle(reserved_org_id=...)`: a v7-shaped id whose
48-bit timestamp is zero, so the uuid generator cannot produce it."""


def _check_test_roles(
    mut errs: List[String],
    ctx: String,
    roles: List[TestRole],
    served_names: List[String],
    excluded_because: String,
    is_control_plane: Bool,
    reserved_org_id: String,
):
    """Refuse, at LOAD TIME, every `test_role` a deploy could not honour.

    ⛔ WHY ALL OF THESE ARE OFFLINE. Provisioning a test role MINTS A P-256
    KEYPAIR, WRITES A SECRET VERSION and INSERTS A ROW into Komira's own control
    plane. Every mistake below therefore costs a real identity somewhere before
    anyone can see it, and several of them cost one that CANNOT BE CLEANED UP —
    the secret handle is derived from `(app, org)` and AWS `DeleteSecret` is a
    soft delete whose name stays taken for up to 30 days. A refusal that arrives
    at apply time is a refusal that arrives after the damage.

    EMPTY `roles` is the ordinary state of a step and reaches NONE of
    these: the function returns having appended nothing, which is what makes the
    zero-behaviour-change property structural rather than asserted."""
    if len(roles) == 0:
        return

    # ── ⛔ 1. TENANCY. THE POSITIVE TEST, AND IT IS THE WHOLE FIELD'S FENCE. ──
    #
    # A `TENANCY_CUSTOMER` bundle's deploy PUBLISHES AND CREATES NOTHING
    # (`deploy_publishes_only`), so a test role on one would mint a live
    # control-plane identity for a machine that stands nothing up — and it would
    # do it in KOMIRA's control plane, on behalf of a bundle whose whole
    # declaration says it runs in someone else's account. An UNSPECIFIED tenancy
    # lands here too, deliberately: it is the value a bundle that declared
    # nothing carries, and "declared nothing" must fall through to the arm that
    # refuses, never to the arm that writes.
    if not is_control_plane:
        errs.append(
            ctx
            + String(
                ": declares 'test_role' but this bundle is not `tenancy:"
                " TENANCY_CONTROL_PLANE`. Provisioning a test role WRITES ROWS"
                " INTO KOMIRA'S OWN CONTROL PLANE — an `app_deployment` row, a"
                " P-256 signing key and a `resource_grant` — so only a bundle"
                " that runs there may cause one. A customer bundle's deploy"
                " publishes its image and creates nothing, so the identity would"
                " belong to no workload at all. Declare `tenancy:"
                " TENANCY_CONTROL_PLANE` on the bundle, or delete the block."
            )
        )

    # ── ⛔ 2. AN EXCLUDED STEP. `excluded_because` means the step is REMOVED from
    #    a resolved run — it places no job and buys no grant (the rule
    #    `_append_validate_step_secret_grant_nodes` already applies to the secret
    #    and telemetry planes, stated there as "places no job, buys no grant").
    #    A test role on one is strictly worse than a wasted grant: the deploy
    #    would mint a real, live, unrevoked-until-teardown caller identity for a
    #    step that never runs, and nothing downstream would ever mention it.
    if excluded_because.byte_length() > 0:
        errs.append(
            ctx
            + String(
                ": declares 'test_role' on a step that is EXCLUDED"
                " (`excluded_because` is set). An excluded step places no job, so"
                " the role would be provisioned — a real key, a real row, a real"
                " grant — and then presented to nothing. Delete the"
                " `excluded_because`, or delete the `test_role`; the two"
                " declarations contradict each other."
            )
        )

    var seen_names = List[String]()
    var seen_flags = List[String]()
    var seen_flag_roles = List[String]()
    for i in range(len(roles)):
        ref r = roles[i]
        var rctx = ctx + String(" test_role[") + String(i) + String("]")
        if r.name.byte_length() > 0:
            rctx = ctx + String(" test_role '") + r.name + String("'")

        # ── 3. NAME: required + unique WITHIN THE STEP. The name is half of the
        #    app name the `app_deployment` row is keyed on, so two roles sharing
        #    one would resolve to ONE identity — the second `provision_app_
        #    identity` ADOPTS the first's row and the step then presents the same
        #    caller twice while its report names two. A cross-tenant assertion
        #    built out of that is vacuous and looks green.
        if r.name.byte_length() == 0:
            errs.append(
                rctx
                + String(
                    ": 'name' is required. It is the role's symbol in every"
                    " refusal and in the provisioning report, and it is half of"
                    " the natural key the minted `app_deployment` row is stored"
                    " under."
                )
            )
        elif _has(r.name, seen_names):
            errs.append(
                rctx
                + String(
                    ": duplicate 'test_role' name. Two roles with one name key"
                    " ONE `app_deployment` row, so the second ADOPTS the first"
                    " and the step presents a single caller under two names — a"
                    " cross-tenant assertion built on that passes for a reason"
                    " unrelated to its claim."
                )
            )
        if r.name.byte_length() > 0:
            seen_names.append(String(r.name))

        # ── 4. ORG: required, and ⛔ NEVER THE RESERVED KOMIRA ORG. ──
        if r.org_id.byte_length() == 0:
            errs.append(
                rctx
                + String(
                    ": 'org_id' is required — it is the TENANCY this caller acts"
                    " in, and the mint anchors every entitlement read to it."
                    " There is no default: a role with no org would be"
                    " provisioned into whatever `--org-id` the deploy was invoked"
                    " with, which is the operator's org and not the subject of"
                    " any test."
                )
            )
        elif (
            reserved_org_id.byte_length() > 0 and r.org_id == reserved_org_id
        ):
            errs.append(
                rctx
                + String(": 'org_id' is THE RESERVED KOMIRA ORG (")
                + reserved_org_id
                + String(
                    "). A test role exists to present a CUSTOMER caller;"
                    " provisioning one into Komira's own tenancy COLLAPSES the"
                    " tenancy axis, so every cross-tenant row the step asserts"
                    " becomes vacuous while still reporting PASS. Name a real"
                    " test org."
                )
            )

        # ── 5. `grants_on_service` must name a service THIS bundle declares. A
        #    grant on a resource that does not exist is a row nothing reads: the
        #    step would then assert an entitlement it never held, and the failure
        #    surfaces as an authorization DENY that looks like an app defect.
        #    The likely mistake is a misspelling, so the refusal SUGGESTS — the
        #    `crons[].target` / `ValidateStep.service` shape.
        if r.grants_on_service.byte_length() == 0:
            errs.append(
                rctx
                + String(
                    ": 'grants_on_service' is required. It names the"
                    " `ServiceSpec.name` in THIS bundle whose deployment the"
                    " grant is recorded on, and it is where the target audience"
                    " is DERIVED from — which is what keeps an audience from"
                    " being hand-typed off a live deployment."
                )
            )
        elif len(served_names) > 0 and not _has(
            r.grants_on_service, served_names
        ):
            var gmsg = (
                rctx
                + String(": 'grants_on_service' names '")
                + r.grants_on_service
                + String("', which this bundle declares no service for")
            )
            var gsg = suggest(r.grants_on_service, served_names)
            if gsg.byte_length() > 0:
                gmsg += String(" — did you mean '") + gsg + String("'?")
            else:
                gmsg += (
                    String(" (declared: ") + _join(served_names) + String(")")
                )
            errs.append(
                gmsg
                + String(
                    ". A grant whose resource does not exist is a row nothing"
                    " reads, so the step would assert an entitlement it never"
                    " held and the DENY would read as an application defect."
                )
            )

        # ── 6. LEVEL. ⛔ UNSPECIFIED IS REFUSED, NOT DEFAULTED. The proto3 zero
        #    means "the author said nothing"; treating it as READ would make the
        #    two states the same bytes, which is the exact absent-vs-empty
        #    confusion the `TestRoleLevel` enum was given its own UNSPECIFIED to
        #    end. A grant carrying no level is also one the authorizer cannot
        #    interpret — it fails at READ time, far from the line that wrote it.
        if r.level.value == 0:
            errs.append(
                rctx
                + String(
                    ": 'level' is TEST_ROLE_LEVEL_UNSPECIFIED — a grant for no"
                    " access level. Name the level"
                    " (TEST_ROLE_LEVEL_READ / _WRITE / _DELETE). There is"
                    " deliberately no default: the zero ordinal means 'the author"
                    " said nothing', and silently reading it as READ would make"
                    " an unauthored privilege indistinguishable from an authored"
                    " one."
                )
            )

        # ── 7. THE FIVE FLAGS: a flag may not be claimed TWICE across the step's
        #    roles. Two roles rendering `--x=` twice means the container SILENTLY
        #    TAKES ONE — the identical rule `_check_parameters` enforces on
        #    `args`, and it must hold here for the same reason and more sharply:
        #    the value being silently dropped is WHICH IDENTITY the validator
        #    presents, so a two-org cross-tenant gate collapses into one org
        #    while both rows still report.
        _check_test_role_flag(
            errs,
            rctx,
            String("deployment_id_flag"),
            r.deployment_id_flag,
            seen_flags,
            seen_flag_roles,
        )
        _check_test_role_flag(
            errs,
            rctx,
            String("identity_secret_flag"),
            r.identity_secret_flag,
            seen_flags,
            seen_flag_roles,
        )
        _check_test_role_flag(
            errs,
            rctx,
            String("org_id_flag"),
            r.org_id_flag,
            seen_flags,
            seen_flag_roles,
        )
        _check_test_role_flag(
            errs,
            rctx,
            String("issuer_flag"),
            r.issuer_flag,
            seen_flags,
            seen_flag_roles,
        )
        # ★ `granted_on_flag` (field 9) — the TARGET deployment's flag. It
        # joins the SAME single-claim namespace as the other four, which is what
        # makes the shared-target authoring ("role A renders it, role B omits
        # it") a rule the loader states rather than a convention a reader has to
        # infer: a second role claiming it is a NAMED refusal here.
        _check_test_role_flag(
            errs,
            rctx,
            String("granted_on_flag"),
            r.granted_on_flag,
            seen_flags,
            seen_flag_roles,
        )


def _check_test_role_flag(
    mut errs: List[String],
    rctx: String,
    field: String,
    flag: String,
    mut seen_flags: List[String],
    mut seen_flag_roles: List[String],
):
    """One flag name, checked against every flag any role of this step already
    claimed. EMPTY is legal and means "do not render this value" — a role that
    only needs the deployment id and the secret handle says so by omitting the
    other two, and an omitted flag renders NOTHING rather than `--=<value>`."""
    if flag.byte_length() == 0:
        return
    for i in range(len(seen_flags)):
        if seen_flags[i] == flag:
            errs.append(
                rctx
                + String(": '")
                + field
                + String("' is '")
                + flag
                + String(
                    "', which is already claimed by "
                )
                + seen_flag_roles[i]
                + String(
                    ". Two values rendering onto ONE flag means the container"
                    " silently takes one of them — and what is silently dropped"
                    " here is WHICH IDENTITY the validator presents, so a"
                    " two-caller gate collapses to one caller while both rows"
                    " still report. Give each value its own flag."
                )
            )
            return
    seen_flags.append(String(flag))
    seen_flag_roles.append(rctx + String(" ") + field)


def _check_validate_vpc_egress(
    mut errs: List[String],
    ctx: String,
    ve: ValidateVpcEgress,
    field: String = String("vpc_egress"),
    unit: String = String("job"),
):
    """Offline checks on an authored `ValidateVpcEgress` block.

    ⛔ A HALF-FILLED ATTACHMENT IS NOT A PARTIAL ONE. Cloud Run rejects a
    `network_interfaces` entry missing either half, so a block naming only a
    network is not "egress with defaults" — it is a create that fails, and the
    render deliberately drops the whole attachment rather than emit it. If that
    drop happened silently the bundle would read as having VPC egress while the
    placed workload had none, which is precisely the prose-says-one-thing/
    wire-says-another failure this field was added to end. So both halves are
    REQUIRED the moment the block is present.

    ★ ONE CHECK, TWO SCOPES. The same payload is authored at
    `RunContainer.vpc_egress` (field 7 — ONE VALIDATE STEP'S JOB) and at
    `AppSpec.network_egress` (field 33 — the SERVED SERVICE), and the refusal is
    identical because Cloud Run's rejection is. `field`/`unit` name the scope in
    the message so the error points at the line the author actually wrote; they
    DEFAULT to the job spelling, which keeps that call site and its pinned test
    strings byte-identical."""
    if ve.network.byte_length() == 0:
        errs.append(
            ctx
            + String(": '")
            + field
            + String(
                "' declares no 'network'. A network_interfaces"
                " entry without a network is rejected by Cloud Run, and the"
                " render drops the whole attachment — so the "
            )
            + unit
            + String(
                " would egress over the public internet while the bundle reads"
                " as though it were on the VPC. Name the network (e.g."
                " 'default'), or delete the block."
            )
        )
    if ve.subnetwork.byte_length() == 0:
        errs.append(
            ctx
            + String(": '")
            + field
            + String(
                "' declares no 'subnetwork'. Direct VPC egress attaches to a"
                " subnetwork IN THE "
            )
            + unit.upper()
            + String(
                "'S OWN REGION; without one Cloud Run rejects the interface and"
                " the render drops the whole attachment — so the "
            )
            + unit
            + String(
                " would egress over the public internet while the bundle reads"
                " as though it were on the VPC. Name the subnetwork, or delete"
                " the block."
            )
        )
    # ⚠ THE ARM THAT SILENTLY DOES NOTHING FOR A `*.run.app` TARGET. A run.app
    # hostname resolves to a PUBLIC address, so under PRIVATE_RANGES_ONLY the
    # request does NOT take the VPC path and a private-ingress peer refuses the
    # caller exactly as it did with no attachment at all. That combination is
    # legal and correct for a validator talking to an internal IP, so it is NOT an
    # error — but it must not be reachable by accident, which is why the proto
    # default is ALL_TRAFFIC and this arm has to be written down explicitly.
    for ref t in ve.network_tags:
        if t.byte_length() == 0:
            errs.append(
                ctx
                + String(": '")
                + field
                + String(
                    "' has an EMPTY 'network_tags' entry. A tag is"
                    " what a firewall rule selects on; an empty one matches"
                    " nothing and hides a typo. Name it, or delete the line."
                )
            )


def _check_network_egress(mut errs: List[String], ctx: String, sp: AppSpec):
    """`AppSpec.network_egress` (field 33) — the SERVED SERVICE'S Direct VPC
    egress attachment.

    ABSENT is legal and is the default: no block => no
    `vpc_access` on the create/update body => the revision egresses over the
    PUBLIC INTERNET. What is refused here is a PRESENT block that Cloud Run would
    reject — checked OFFLINE, where it costs nothing, instead of arriving as a
    CreateService/UpdateService error after a build, a push and an hour of
    deploy. A half-authored block is the whole hazard: the render drops the
    attachment entirely, so the bundle would read as being on the VPC while the
    live revision was not, and the resulting edge-404 from a private-ingress peer
    is indistinguishable from an application 404."""
    if not sp.network_egress:
        return
    _check_validate_vpc_egress(
        errs,
        ctx,
        sp.network_egress.value(),
        String("network_egress"),
        String("service"),
    )


# ═══════════════════════════════════════════════════════════════════════════
# Four optional capabilities.
#
# ⚠ THE HOUSE RULE THESE FOLLOW: a field that CAN be checked at load time IS
# checked at load time, and one that cannot says WHY in the message it raises
# when it finally can. Everything below is checkable offline from the bundle text
# alone — no credentials, no cloud, no registry — which is what keeps bundle
# validation an offline verb.
# ═══════════════════════════════════════════════════════════════════════════

# The literal that must never appear as an ingress gateway identity. It is the
# member an org policy rejects AND the one that would make the backend itself
# public — the exact condition the ingress shape exists to route around.
comptime _PUBLIC_PRINCIPAL: String = "allUsers"


def _check_ingress(mut errs: List[String], ctx: String, sp: AppSpec):
    """`AppSpec.ingress` (field 30) — the ingress REALIZATION inputs.

    THE ONE STRUCTURAL RULE: an `ingress {}` block must correspond to an edge.
    The block would otherwise be authored, accepted, and do nothing — while
    reading, to the next person, as though the front door had been set up. That
    is the failure mode this refusal exists for, and it is the reason the block
    is refused rather than ignored.

    ── ★ WHICH SERVICES HAVE AN EDGE ──────
    "Only alongside an `inbound` NEED" would be the wrong spelling: the compose
    pass AUTO-PROVISIONS a CATCH_ALL edge for a served service that declares no
    `inbound` but DOES author an `ingress {}` block — the block being the place
    `caller_class` lives, so provisioning and securing are one authored fact. So
    an `ingress {}` on an inbound-less service is not inert; it is the trigger.

    ⛔ THE REFUSAL SURVIVES FOR `POLL`, AND THAT IS NOT AN OVERSIGHT. An author
    who wrote `INBOUND_NEED_POLL` said this app PULLS its work, and
    the compose pass deliberately does not auto-provision for it — so a block
    there really would configure nothing. UNSPECIFIED is the absence the
    auto-provisioned edge fills."""
    if not sp.ingress:
        return
    ref ing = sp.ingress.value()
    var need = sp.inbound.value
    if need == InboundNeed.INBOUND_NEED_POLL:
        errs.append(
            ctx
            + String(
                ": an 'ingress { … }' block is not meaningful with 'inbound:"
                " INBOUND_NEED_POLL'. A polled app pulls its work, so no edge is"
                " composed for it (edge auto-provisioning deliberately skips"
                " POLL) and every field in the block would be silently unused —"
                " while reading as though a front door had been configured."
                " Drop the block, or declare 'inbound: INBOUND_NEED_CLIENT' /"
                " 'INBOUND_NEED_WEBHOOK' / no inbound at all (which the deploy"
                " auto-provisions)."
            )
        )
    if ing.gateway_service_account == _PUBLIC_PRINCIPAL:
        errs.append(
            ctx
            + String(
                ": ingress 'gateway_service_account' must not be 'allUsers'. It"
                " is BOTH the identity the edge mints the backend-hop token as"
                " AND the member granted scoped invoker on the backend — so"
                " 'allUsers' would make the BACKEND ITSELF publicly invocable,"
                " which is the precise condition an edge-fronted private backend"
                " exists to avoid. (An org policy rejects it too, but that is a"
                " second line of defence, not this one.) Name a service"
                " account, or leave it empty for the self-provisioned gateway"
                " identity."
            )
        )


def _check_job_spec(
    mut errs: List[String],
    ctx: String,
    j: JobSpec,
    build_names: List[String],
):
    """One `AppBundle.jobs[]` entry — a run-to-completion container the deploy
    SHIPS. `name` and `image` are required for the same reason they are on a
    service: a job with no name cannot be referenced by an `execute_job` step, and
    a job with no image is a node the applier cannot create."""
    if j.name.byte_length() == 0:
        errs.append(ctx + String(": a job is missing its 'name'"))
    _check_image(errs, ctx, j.image, True, build_names)
    for ref e in j.env:
        _check_env(errs, ctx, e)
    if j.runtime_identity == _PUBLIC_PRINCIPAL:
        errs.append(
            ctx
            + String(
                ": job 'runtime_identity' must not be 'allUsers' — it is an"
                " IDENTITY THE CONTAINER RUNS AS, and 'allUsers' is not an"
                " identity anything can run as. Name a service account, or"
                " leave it empty to inherit the bundle's runtime identity."
            )
        )


comptime SERVED_NODE_REF_SUFFIX: String = "-svc"
"""The suffix the compose pass appends to a service NAME to get its served node
id (`<name>-svc`, the same string `serverless_node_id` appends on the GCP side).
Stated here because
`web_api_service_logical_id` is authored in the NODE-ID spelling while
`services[].name` is the SERVICE spelling, and the resolution below has to
bridge the two. This module is cloud-neutral, so it cannot import the GCP
constructor — so the copy must be pinned by a test that calls the GCP side's
`serverless_node_id` and asserts `serverless_node_id(n) == n +
SERVED_NODE_REF_SUFFIX`, so a rename on the composing side reds this constant
instead of silently matching nothing."""


def _spec_authors_web_topology(sp: AppSpec) -> String:
    """The NAME of the first front-door topology field `sp` authors, or `""`.

    ⚠ IT RETURNS A NAME, NOT A BOOL, and that is the whole reason it exists: a
    refusal that says "the spec also authors web topology" sends a reader to scan
    ~40 lines of `spec {}` looking for which line is the problem, and they will
    scan past it. The refusal names the line."""
    if sp.web_slug.byte_length() > 0:
        return String("web_slug")
    if sp.web_domain.byte_length() > 0:
        return String("web_domain")
    if len(sp.web_additional_domains) > 0:
        return String("web_additional_domains")
    if len(sp.web_api_path_prefixes) > 0:
        return String("web_api_path_prefixes")
    if sp.web_api_service_logical_id.byte_length() > 0:
        return String("web_api_service_logical_id")
    if len(sp.web_route_rules) > 0:
        return String("web_route_rules")
    return String("")


def _check_web_override(
    mut errs: List[String], bundle: AppBundle, served_names: List[String]
):
    """⛔⛔ `Wave.web_override` (field 8) IS **TOTAL**, NOT A MERGE — and these
    are the refusals that make that statement true rather than aspirational.

    ── WHY TOTAL, RESTATED HERE BECAUSE THIS IS WHERE IT IS ENFORCED ──────────
    Under a field-by-field merge ("a non-empty override field replaces the spec
    value") a wave CANNOT EXPRESS **ABSENT** — an empty `web_route_rules` reads
    as *inherit*. That is not a corner case: a pre-production environment often
    routes MORE paths than production (docs, debug endpoints, a DENY rule), so
    production's table is not the other's with blanks; it is a SHORTER TABLE.
    Under a merge a consolidated machine could not author production at all, and
    the failure mode is production SILENTLY INHERITING the other environment's
    routes — a front door quietly opening paths that environment does not have.

    FOUR REFUSALS, and each names what a merge would have swallowed:

      1. **BOTH PLACES AUTHORED.** Dead text that reads as live. A reviewer scans
         `spec {}` for the route table, because that is where a front-door bundle
         keeps it; a stale copy there hides the route table quietly shrinking,
         with the evidence sitting in plain sight.
      2. **A WAVE WITH NO OVERRIDE BESIDE A SIBLING THAT HAS ONE.** The dangerous
         asymmetry. Once any wave overrides, rule 1 forces the spec EMPTY — so
         the un-overridden wave inherits an empty slug, which falls back to
         `bundle.name`. BOTH environments then derive the SAME slug, and one
         env's L7 primitives are stood up against the other env's project.
      3. **AN INCOMPLETE OVERRIDE.** An empty slug is (2)'s collision written a
         second way; an empty domain makes `bundle_web_front_door_url(bundle,
         env)` return `""`, which is precisely the STATIC_FRONTEND gap that
         function was written to close (every authored validate step of that wave
         then probes NOTHING); an empty table is the merge semantic's ghost — a
         whole environment's api surface falling through to the SPA bucket and
         answering plausible statuses with `index.html`.
      4. **AN OVERRIDE ON A BUNDLE THAT COMPOSES NO FRONT DOOR.**
         `compose_static_frontend` is the ONLY reader and it runs for exactly one
         kind, so anywhere else the block is authored-and-ignored.

    ⚠ ABSENT EVERYWHERE ⇒ SILENT. A bundle authoring no override at all is the
    ordinary single-environment front door, and it must stay valid: that is the
    difference between an additive field and a migration."""
    var n_over = 0
    for i in range(len(bundle.waves)):
        if bundle.waves[i].web_override:
            n_over += 1
    if n_over == 0:
        return

    # (4) — the kind gate, FIRST, because every rule below is about a front door
    # and this bundle may not compose one at all.
    if bundle.kind.value != AppKind.APP_KIND_STATIC_FRONTEND:
        errs.append(
            String(
                "waves: a `web_override` block is only meaningful on an"
                " APP_KIND_STATIC_FRONTEND bundle — `compose_static_frontend` is"
                " its ONLY reader and it runs for exactly that kind. Authored"
                " here it is configuration nothing consumes: the text reads as a"
                " front door, and no front door is composed. This bundle's kind"
                " is "
            )
            + bundle.kind.json_name()
            + String(".")
        )
        return

    # (1) — both places authored. Checked against the singular spec AND every
    # named service's spec: a consolidated machine can carry a front door as a
    # `services[]` entry, and reading only `bundle.spec` would check the one
    # place the value is not authored (the `_check_web_api_service_ref`
    # precedent, one frame in, for the same reason).
    if bundle.spec:
        var dup = _spec_authors_web_topology(bundle.spec.value())
        if dup.byte_length() > 0:
            errs.append(
                String("spec: '")
                + dup
                + String(
                    "' is authored on the bundle-level spec while a wave authors"
                    " `web_override`. The per-wave override is TOTAL, not a"
                    " merge, so this line is DEAD TEXT that reads as live"
                    " configuration — and the spec is where a reviewer looks for"
                    " the front door. Move every `web_*` topology field into the"
                    " wave that needs it, or delete the override."
                )
            )
    for si in range(len(bundle.services)):
        ref sv = bundle.services[si]
        if sv.spec:
            var sdup = _spec_authors_web_topology(sv.spec.value())
            if sdup.byte_length() > 0:
                errs.append(
                    String("services['")
                    + sv.name
                    + String("'].spec: '")
                    + sdup
                    + String(
                        "' is authored beside a wave `web_override`. The"
                        " override is TOTAL — one place per wave, or neither."
                    )
                )

    # (2) + (3) — per wave.
    for i in range(len(bundle.waves)):
        ref w = bundle.waves[i]
        var wname = w.env.copy() if w.env.byte_length() > 0 else String(
            "waves["
        ) + String(i) + String("]")
        if not w.web_override:
            errs.append(
                String("wave '")
                + wname
                + String(
                    "': authors no `web_override` while a sibling wave does. The"
                    " override is TOTAL, so the spec-level topology must be"
                    " empty — which leaves this wave with NO slug and NO domain."
                    " An empty slug falls back to `bundle.name`, so BOTH"
                    " environments would derive the same slug and stand one"
                    " env's L7 primitives up against the other env's project."
                    " Author a `web_override` on every wave, or on none."
                )
            )
            continue
        ref o = w.web_override.value()
        if o.web_slug.byte_length() == 0:
            errs.append(
                String("wave '")
                + wname
                + String(
                    "': `web_override.web_slug` is required. It is the prefix"
                    " every L7 primitive self-derives from; empty falls back to"
                    " `bundle.name`, which under two waves is the same slug in"
                    " two projects."
                )
            )
        if o.web_domain.byte_length() == 0:
            errs.append(
                String("wave '")
                + wname
                + String(
                    "': `web_override.web_domain` is required. It is also this"
                    " wave's probe target (`bundle_web_front_door_url`), and an"
                    " empty one makes EVERY authored validate step of this wave"
                    " probe nothing at all — the STATIC_FRONTEND gap that"
                    " function exists to close."
                )
            )
        if len(o.web_route_rules) == 0:
            errs.append(
                String("wave '")
                + wname
                + String(
                    "': `web_override.web_route_rules` is required and must be"
                    " non-empty. An empty table is what a MERGE semantic would"
                    " have read as 'inherit'; under a TOTAL override it is a"
                    " front door that routes nothing to any api backend, so this"
                    " environment's whole api surface falls through to the SPA"
                    " bucket and answers plausible statuses with index.html. A"
                    " front door that genuinely routes nothing authors the"
                    " DEFAULT arm alone and says so."
                )
            )
        # The SAME sibling-resolution guard the spec path gets. It is scoped
        # `n_services > 1` inside, so it is silent for single-service front
        # doors and starts discriminating once the machine has siblings.
        _check_web_api_service_ref(
            errs,
            String("wave '") + wname + String("' web_override"),
            o.web_api_service_logical_id,
            served_names,
            len(bundle.services),
        )
        # ★★ EVERY RUNTIME-CONFIG KEY THE SPEC DECLARES MUST BE OVERRIDDEN BY
        # THIS WAVE — the thing that makes the spec-level placeholder safe.
        #
        # ⛔ THE DEFECT THIS PREVENTS: a placeholder such as
        # "https://REPLACE-WITH-PER-ENV-CALLBACK-HOST" COMMITTED AS A LIVE VALUE
        # (see `Wave.parameter_override`'s proto comment) — "an unconfigured
        # required input that became a plausible string instead of a refusal". On a STATIC_FRONTEND bundle the same
        # mistake is worse, because `spec.env` IS the runtime config: an
        # unoverridden key is stamped into the `config.json` a BROWSER fetches.
        #
        # ⭐ AND THE RULE NEEDS NO KEY VOCABULARY. It does not name
        # `VITE_FIREBASE_*` or import the eight-key projection allowlist — it
        # asserts over the SPEC'S OWN DECLARED KEYS, so a key added tomorrow is
        # covered with no edit here. A rule that had to list the keys would be a
        # second copy of the allowlist, and the copy is the drift.
        #
        # ⚠ SCOPED TO WAVES THAT OVERRIDE, on purpose. A single-wave front door
        # authoring its values directly on `spec.env` is the ordinary shape and
        # stays legal; this fires only for the consolidated
        # shape, where a spec value is by construction not any environment's.
        if bundle.spec:
            ref fsp = bundle.spec.value()
            for ei in range(len(fsp.env)):
                if fsp.env[ei]._oneof0_case != 1:
                    continue  # non-literal arms are not runtime config
                var covered = False
                for oi in range(len(w.env_override)):
                    if w.env_override[oi].name == fsp.env[ei].name:
                        covered = True
                if not covered:
                    errs.append(
                        String("wave '")
                        + wname
                        + String("': `spec.env` declares '")
                        + fsp.env[ei].name
                        + String(
                            "' but this wave's `env_override` does not supply it."
                            " On a front door with a per-wave `web_override` the"
                            " spec-level value is by construction NOT any"
                            " environment's — it is a placeholder — and"
                            " `spec.env` on this bundle kind IS the runtime"
                            " config, stamped into the `config.json` a BROWSER"
                            " fetches. An unsupplied key would serve that"
                            " placeholder as a live value, which is the defect"
                            " `Wave.parameter_override` was added to end. Add an"
                            " `env_override` for it on this wave."
                        )
                    )


def _check_web_api_service_ref(
    mut errs: List[String],
    ctx: String,
    api_service_logical_id: String,
    served_names: List[String],
    n_services: Int,
):
    """`AppSpec.web_api_service_logical_id` — the Cloud Run service the web front
    door's serverless NEG targets — RESOLVED AGAINST THIS BUNDLE'S OWN SERVICES
    when there are siblings to resolve it against.

    ⚠⚠ IT IS A FORWARD GUARD, scoped `n_services > 1`: for a single-service
    bundle its green says NOTHING about consistency. It starts discriminating
    when a web front door is in the same bundle as the API it fronts.

    WHAT IT IS FOR. A web bundle authors, for example,
    `web_api_service_logical_id: "orders-api-svc"`; the mapper strips the `-svc`
    and points the NEG at a Cloud Run service named `orders-api`. If the API is
    declared in a different bundle, nothing spans the two files, so nothing can
    check it — a constant passed between templates is hoped for, where a
    reference inside one template is checked. When they are siblings, the
    hoped-for constant becomes a checkable reference, and this is the check.

    ⚠ IT ONLY BITES WHERE IT CAN BE RIGHT — `n_services > 1`. A single-service
    bundle's front door legitimately names a service in ANOTHER bundle, and
    refusing it would red bundles for stating the only thing they can state.
    With siblings present the name is resolvable in-template, so an
    unresolvable one is an authoring error and is refused offline rather than
    discovered as a serverless NEG pointing at a service that does not exist — a
    failure whose symptom is a 502 at the front door with every node reading
    MATCHED.

    The `-svc` suffix is OPTIONAL in the authored value: both `orders-api-svc`
    (the node-id spelling) and `orders-api` (the service spelling) resolve,
    because the two are one rename apart and refusing the shorter one would teach
    nothing."""
    if api_service_logical_id.byte_length() == 0:
        return
    if n_services <= 1:
        return
    var bare = api_service_logical_id.copy()
    if bare.endswith(SERVED_NODE_REF_SUFFIX) and bare.byte_length() > (
        SERVED_NODE_REF_SUFFIX.byte_length()
    ):
        # The temporary is load-bearing under 1.0.0: assigning the slice
        # straight back into `bare` aliases the same String as both the
        # initializer's argument and its destination.
        var trimmed = String(
            bare[
                byte=0 : bare.byte_length()
                - SERVED_NODE_REF_SUFFIX.byte_length()
            ]
        )
        bare = trimmed^
    if _has(bare, served_names):
        return
    errs.append(
        ctx
        + String(": 'web_api_service_logical_id' names '")
        + api_service_logical_id
        + String("', which resolves to service '")
        + bare
        + String(
            "' — and this bundle declares no such service. The web front door's"
            " serverless NEG would target a Cloud Run service this deploy does not"
            " create, which fails as a 502 at the front door with every node"
            " reading MATCHED. Declared services: ["
        )
        + _join(served_names)
        + String(
            "]. In a multi-service bundle this is a SIBLING REFERENCE, not a"
            " cross-bundle constant."
        )
    )


def _check_cron_spec(
    mut errs: List[String],
    ctx: String,
    c: CronSpec,
    served_names: List[String],
):
    """One `AppBundle.crons[]` entry — a scheduled call into a SIBLING service.

    ★ THE TARGET CHECK IS THE LOAD-BEARING ONE. A cron whose target is not a
    service this bundle declares is a cron whose scoped invoker binding this
    deploy cannot make — so it would be created, would fire, would be refused, and
    the deploy that created it would be green. Resolving the name offline turns
    that into a build-time refusal, which is the only place it is cheap.

    ★ THE CRON EXPRESSION IS CHECKED FOR SHAPE ONLY (5 whitespace-separated
    fields), NOT SEMANTICS, AND THE LIMIT IS STATED RATHER THAN HIDDEN. A full
    cron grammar here would be a second implementation of the scheduler's parser
    and would disagree with it at the edges; five fields catches the mistakes that
    are actually made (a 6-field quartz expression, an `@weekly` alias, an empty
    string) without pretending to more authority than it has."""
    if c.name.byte_length() == 0:
        errs.append(ctx + String(": a cron is missing its 'name'"))
    if c.cron.byte_length() == 0:
        errs.append(
            ctx
            + String(
                ": cron 'cron' is required (a 5-field expression `m h dom mon"
                " dow`)"
            )
        )
    else:
        var fields = 0
        for part in c.cron.split():
            if String(part).byte_length() > 0:
                fields += 1
        if fields != 5:
            errs.append(
                ctx
                + String(": cron 'cron' has ")
                + String(fields)
                + String(
                    " whitespace-separated field(s); a 5-field expression `m h"
                    " dom mon dow` is required. A 6-field (quartz/seconds) form"
                    " or an `@weekly`-style alias is NOT accepted here — it"
                    " would be handed to a scheduler that reads the fields"
                    " shifted by one and fires at a different time than the"
                    " author wrote."
                )
            )
    if not c.target or c.target.value().service.byte_length() == 0:
        errs.append(
            ctx
            + String(
                ": cron 'target { service: \"<name>\" }' is required — it names"
                " the SIBLING service this cron calls. There is deliberately no"
                " 'uri' field: the url and the OIDC audience are both DERIVED"
                " from the target's observed serving address at apply time."
            )
        )
    elif not _has(c.target.value().service, served_names):
        var msg = (
            ctx
            + String(": cron target '")
            + c.target.value().service
            + String("' does not name a served service in this bundle")
        )
        var sg = suggest(c.target.value().service, served_names)
        if sg.byte_length() > 0:
            msg += String(" — did you mean '") + sg + String("'?")
        elif len(served_names) > 0:
            msg += String(" (served: ") + _join(served_names) + String(")")
        msg += String(
            ". A cron whose target this bundle does not declare is a cron whose"
            " invoker binding this deploy cannot make — it would fire, be"
            " refused, and report nothing."
        )
        errs.append(msg^)
    if c.path.byte_length() > 0 and not c.path.startswith(String("/")):
        errs.append(
            ctx
            + String(": cron 'path' ")
            + c.path
            + String(
                " must start with '/' — it is appended to the target's discovered"
                " serving origin, and a path without a leading slash concatenates"
                " into the HOSTNAME."
            )
        )
    if c.http_method.byte_length() > 0:
        var m = c.http_method.upper()
        if m != c.http_method:
            errs.append(
                ctx
                + String(": cron 'http_method' ")
                + c.http_method
                + String(" must be UPPERCASE (e.g. \"POST\")")
            )


def _check_ephemeral(mut errs: List[String], bundle: AppBundle):
    """`AppBundle.ephemeral` (field 14) — the bundle's PERMISSION to be deployed
    and destroyed as a throwaway run.

    ONE RULE, AND IT IS THE WHOLE MESSAGE. `keep_overridden_because` must be
    non-empty, because setting this block is what makes a data-protecting
    RETAIN_KEEP retention not apply — the single most dangerous instruction it is
    possible to put in a bundle. It is a string and not a bool for exactly the
    reason `ValidateStep.excluded_because` is: a bool can be flipped in a diff
    with no explanation, and an override that costs nothing to grant is an
    override nobody audits."""
    if not bundle.ephemeral:
        return
    ref e = bundle.ephemeral.value()
    if e.keep_overridden_because.byte_length() == 0:
        errs.append(
            String(
                "ephemeral: 'keep_overridden_because' is required and must say"
                " WHY. Declaring this block makes RETAIN_KEEP not apply, so a"
                " run-scoped teardown deletes nodes whose retention exists to"
                " protect data. That is correct for a throwaway run — the bucket"
                " IS the run — and catastrophic for anything else, so the"
                " justification travels with the override in the text a reviewer"
                " reads. There is deliberately no bool form."
            )
        )


def _check_validate_step(
    mut errs: List[String],
    ctx: String,
    v: ValidateStep,
    build_names: List[String],
    job_names: List[String],
    served_names: List[String],
    # ★ `tenancy: TENANCY_CONTROL_PLANE`, POSITIVELY — the fence on
    # `RunContainer.test_role`. ⛔ NO DEFAULT: see the block on
    # `_check_run_container`'s parameters. A defaulted `False` here would be
    # merely wrong-and-loud, but a defaulted `True` — the shape someone reaches
    # for when a call site does not have a bundle — would make the whole refusal
    # unreachable from a caller that forgot it.
    is_control_plane: Bool,
    # Threaded to `_check_run_container`; see `DEFAULT_RESERVED_ORG_ID`.
    reserved_org_id: String,
):
    var label = ctx + String(" validate '") + v.name + String("'")
    if v.name.byte_length() == 0:
        errs.append(ctx + String(": a validate step is missing its 'name'"))
    # ── ★ THE SERVICE AXIS (ValidateStep field 7) — WHICH SERVICE THIS STEP IS
    #    ABOUT. Checked against the names the bundle DECLARES, for the same reason
    #    `crons[].target` and `outputs[].from_served` are: a step addressed to a
    #    service that does not exist resolves to NO endpoint, and the driver's
    #    refusal would then land after the apply. Catch it offline, where it costs
    #    nothing.
    #
    #    ⚠ A MISSPELLING is the likely defect here, not an invented name, so the
    #    refusal SUGGESTS — the cron-target shape, adopted for the same reason. An
    #    EMPTY value stays legal and is the proto3 default: the ambiguity IT
    #    creates is a property of the DEPLOY (how many services actually
    #    converged), so `step_validate_target_url` refuses that one there, where
    #    the candidate list is observed rather than merely declared.
    if v.service.byte_length() > 0 and len(served_names) > 0:
        if not _has(v.service, served_names):
            var smsg = (
                label
                + String(": 'service' names '")
                + v.service
                + String("', which this bundle declares no service for")
            )
            var sg = suggest(v.service, served_names)
            if sg.byte_length() > 0:
                smsg += String(" — did you mean '") + sg + String("'?")
            else:
                smsg += (
                    String(" (declared: ") + _join(served_names) + String(")")
                )
            errs.append(
                smsg
                + String(
                    ". The value is a logical `ServiceSpec.name`; it is the"
                    " subject of this step's `http_check` host and of every"
                    " VALUE_FROM_DEPLOY_URL its run_container resolves."
                )
            )
    if v._oneof0_case == 0:
        errs.append(
            label
            + String(
                ": set exactly one of {http_check, run_container, execute_job}"
            )
        )
    elif v._oneof0_case == 1:
        ref hc = v.http_check.value()
        if hc.path.byte_length() == 0:
            errs.append(label + String(": http_check 'path' is required"))
        # EDGE-RESERVED PROBE PATH (see the block at the top of this file). An
        # `http_check` is a GET against the deployed URL — through the edge — so a
        # reserved path gates on Google's 404 rather than on our service.
        elif is_edge_reserved_probe_path(hc.path):
            errs.append(
                _edge_reserved_probe_error(
                    label + String(" http_check 'path'"), hc.path
                )
            )
        var status = Int(hc.expect_status)
        if status < 100 or status > 599:
            errs.append(
                label
                + String(": http_check 'expect_status' ")
                + String(status)
                + String(" is not a valid HTTP status (100–599)")
            )
        # ★ THE LATENCY BUDGET (`max_latency_ms`, field 3).
        # ⛔ A NEGATIVE VALUE IS REFUSED, NOT FLOORED. "Do not check latency"
        # already has exactly one spelling — OMIT the field, which leaves the
        # proto3 zero — so a negative number cannot be an expression of that
        # intent; it is a typo (`-1` reaching for "unset", a mis-signed
        # subtraction in a generator), and silently treating it as "unchecked"
        # reproduces this field's own founding defect one level up: an
        # assertion an author believes they wrote, which asserts nothing.
        var budget_ms = Int(hc.max_latency_ms)
        if budget_ms < 0:
            errs.append(
                label
                + String(": http_check 'max_latency_ms' ")
                + String(budget_ms)
                + String(
                    " is negative. Omit the field to leave latency UNCHECKED"
                    " (the default); a value must be a positive millisecond"
                    " budget for the whole probe request."
                )
            )
    elif v._oneof0_case == 2:
        _check_run_container(
            errs,
            label + String(" run_container"),
            v.run_container.value(),
            build_names,
            served_names,
            # THE STEP'S OWN EXCLUSION MARKER, threaded rather than re-derived:
            # a `test_role` on an excluded step is refused, and this is the only
            # frame that holds both facts.
            v.excluded_because,
            is_control_plane,
            reserved_org_id,
        )
    elif v._oneof0_case == 3:
        # EXECUTE a declared job and gate on its exit code. The
        # ref MUST resolve to a `AppBundle.jobs[]` entry: a step naming a job the
        # bundle does not declare is a gate that can never run, and a gate that
        # can never run is indistinguishable from a gate that passed.
        ref ej = v.execute_job.value()
        if ej.job.byte_length() == 0:
            errs.append(
                label
                + String(
                    ": execute_job 'job' is required (it names an"
                    " `AppBundle.jobs[].name`)"
                )
            )
        elif not _has(ej.job, job_names):
            var jmsg = (
                label
                + String(": execute_job 'job' '")
                + ej.job
                + String("' does not name a job this bundle declares")
            )
            var jsg = suggest(ej.job, job_names)
            if jsg.byte_length() > 0:
                jmsg += String(" — did you mean '") + jsg + String("'?")
            elif len(job_names) > 0:
                jmsg += String(" (jobs: ") + _join(job_names) + String(")")
            else:
                jmsg += String(" (this bundle declares no `jobs { … }` block)")
            errs.append(jmsg^)
        if ej.gate_on.value == GateOn.GATE_ON_UNSPECIFIED:
            errs.append(
                label
                + String(
                    " execute_job: 'gate_on' is required (GATE_ON_EXIT_CODE — the"
                    " execution's exit code IS the verdict)"
                )
            )


# ── ★ THE LIFECYCLE COMPUTE ENVIRONMENT: PRODUCER AND CONSUMER MUST AGREE ────
#
# ⛔ THE FAILURE THIS REFUSES. A wave whose consumer names an environment its
# producer did not create fails like this:
#
#     CP-IDENTITY: UNRESOLVED at login+users/me
#       (no compute environment named 'stage-orders-lifecycle' in this org)
#     [FAIL] lifecycle_precondition — UNBOUND: --cp-env-name … NOTHING WAS CREATED
#     Container called exit(1).
#
# A wave has TWO ends of one string and NOTHING joined them:
#
#   PRODUCER  a `run_container` env `KOMIRA_BOOTSTRAP_ENV_NAME: X` — the
#             bootstrap validator CREATES (or finds) the compute environment
#             called X.
#   CONSUMER  a `run_container` args entry rendering `--cp-env-name=Y` — an
#             app's e2e validator LISTS the environment called Y and REFUSES
#             when it is absent, deliberately never creating one ("a validator
#             that creates what it is supposed to find passes against a
#             bootstrap that does nothing").
#
# X and Y are two hand-typed strings in two different blocks of one file. When
# they disagree the run is not merely red — it is red HAVING CREATED A COMPUTE
# ENVIRONMENT, in a real customer project, that no consumer will ever name and
# no teardown will ever find. A typo therefore costs a LEAK, not a retry: a
# stale-orphan sweep reaps managed APPS inside an environment and never the
# environment itself. It is exactly the failure the pairing above was supposed
# to prevent, running in the direction that costs money.
#
# ── WHY *THIS* SHAPE AND NOT THE STRONGER ONE ────────────────────────────────
# The obvious stronger rule — "a consumer with no producer in its wave is
# refused" — is NOT what this function states, and the omission is deliberate
# rather than an oversight. A bundle may consume `--cp-env-name`
# against an environment authored by a DIFFERENT release machine or standing by
# hand. Refusing an unmatched consumer would refuse those bundles at COMPOSE,
# i.e. it would take a working machine down to enforce a rule about a machine
# that does not exist yet. The MISMATCH direction becomes load-bearing exactly
# when a wave arms a per-app bootstrap step — which is when the defect can be
# introduced.
#
# ── SCOPE: LITERALS AND UNEXCLUDED STEPS, IN ONE WAVE ────────────────────────
#   * LITERAL arms only, both sides. A `value_from` resolves at deploy time and
#     carries no authored string here; refusing what cannot be read would be a
#     refusal about nothing.
#   * An EXCLUDED step composes no job and creates no environment, so it is not
#     a producer and not a consumer. (An excluded bootstrap/unbootstrap step is
#     intentionally unwired; reading it as a live end of a string would refuse a
#     bundle that is correct.)
#   * ONE WAVE. The scheduler runs a wave's steps as one DAG; a producer in the
#     staging wave says nothing about a consumer in production, and joining them
#     would assert an ordering no scheduler provides.
def _check_lifecycle_env_pairing(
    mut errs: List[String], ctx: String, steps: List[ValidateStep]
):
    """Refuse a wave whose bootstrap CREATES one compute environment by name and
    whose e2e step LOOKS FOR a different one. FAILS LOUD at compose, where a
    human is reading, instead of after a real cloud write in a real customer
    project that nothing in this repo can find again."""
    var produced = List[String]()
    var produced_by = List[String]()
    var consumed = List[String]()
    var consumed_by = List[String]()
    for ref v in steps:
        # An excluded step places no job: it neither creates nor looks for one.
        if v.excluded_because.byte_length() > 0:
            continue
        if v._oneof0_case != 2:
            continue
        ref rc = v.run_container.value()
        for ref e in rc.env:
            if e.name == BOOTSTRAP_ENV_NAME_ENV and e._oneof0_case == 1:
                ref made = e.value.value()
                if made.byte_length() > 0:
                    produced.append(made.copy())
                    produced_by.append(v.name.copy())
        for ref a in rc.args:
            if param_flag_for(a) == CP_ENV_NAME_FLAG and a._oneof0_case == 1:
                ref want = a.value.value()
                if want.byte_length() > 0:
                    consumed.append(want.copy())
                    consumed_by.append(v.name.copy())
    # Nothing to join: a wave with no producer (the state of every managed-app
    # bundle that authors no bootstrap step) or no consumer is out of scope BY DESIGN —
    # see the block above.
    if len(produced) == 0 or len(consumed) == 0:
        return
    for ci in range(len(consumed)):
        var matched = False
        for pi in range(len(produced)):
            if produced[pi] == consumed[ci]:
                matched = True
                break
        if matched:
            continue
        var made_list = String("")
        for pi in range(len(produced)):
            if pi > 0:
                made_list += String(", ")
            made_list += (
                String("'")
                + produced[pi]
                + String("' (step '")
                + produced_by[pi]
                + String("')")
            )
        errs.append(
            ctx
            + String(" validate step '")
            + consumed_by[ci]
            + String("': looks for the compute environment '")
            + consumed[ci]
            + String("' (--")
            + CP_ENV_NAME_FLAG
            + String("), but the only environment this wave CREATES is ")
            + made_list
            + String(
                ". The consumer LISTS its environment by name and refuses when"
                " it is absent — it never creates one — so this wave bootstraps"
                " one environment and then fails looking for another. ⛔ AND THE"
                " RUN LEAKS: the created environment is a real cloud write in a"
                " real customer project that no step of this wave will ever name"
                " again, and NOTHING in this repo reaps one — the stale-orphan"
                " sweep reaps managed APPS inside an environment, never the"
                " environment itself. Make the two"
                " strings the same string, on the producer's `"
            )
            + BOOTSTRAP_ENV_NAME_ENV
            + String("` env or this step's `--")
            + CP_ENV_NAME_FLAG
            + String("` arg.")
        )


def _check_step_dag(
    mut errs: List[String], ctx: String, steps: List[ValidateStep]
):
    """Every `depends_on` in a step LIST must name a step IN THAT SAME LIST.

    WHY THIS IS A VALIDATION ERROR AND NOT A RUNTIME ONE. A
    `ValidateStep` list is a DAG the scheduler topo-sorts; a dep it cannot resolve
    means the dependent step is SKIPPED for a dependency that can never pass. That
    is the fail-quiet shape: the run reports green having never executed the
    assertion the step exists for. A guard asserting
    `len(validate_bundle(bundle)) == 0` covers a retargeted `depends_on` only
    because this check exists.

    Applied to BOTH carriers of `ValidateStep`s — a wave's `validate` list and a
    named `validation_sets[].steps` list — because the scheduler treats them
    identically. An EXCLUDED step (`excluded_because`) is still AUTHORED and so
    still a valid dep target: exclusion is a property of a RUN's resolution (the
    resolver CONTRACTS the node out of its dependents' deps), never of the
    authored DAG.
    """
    var names = List[String]()
    for ref s in steps:
        if s.name.byte_length() > 0:
            names.append(String(s.name))
    for ref s in steps:
        for ref d in s.depends_on:
            if d.byte_length() == 0:
                errs.append(
                    ctx
                    + String(" validate '")
                    + s.name
                    + String("': an empty 'depends_on' entry")
                )
                continue
            if d == s.name:
                errs.append(
                    ctx
                    + String(" validate '")
                    + s.name
                    + String("': 'depends_on' names ITSELF (a step cannot wait")
                    + String(" on its own completion)")
                )
                continue
            if not _has(d, names):
                errs.append(
                    ctx
                    + String(" validate '")
                    + s.name
                    + String("': 'depends_on' names '")
                    + d
                    + String(
                        "', which is not a step in this set — a dangling"
                        " dependency SKIPS the dependent step forever (rename the"
                        " dep, or add the step)"
                    )
                )


def _check_validation_set_env_policy(
    mut errs: List[String], sctx: String, vs: ValidationSet
):
    """⛔ THE INTERNAL CONSISTENCY of `ValidationSet.{env_policy, envs}`.

    ── WHY THE FIELD EXISTS, RESTATED HERE BECAUSE THIS IS WHERE IT IS ENFORCED ──
    A validation set may be DESTRUCTIVE: for example it SELF-PROVISIONS a real
    account on a live front door, seeds data, and then CASCADE-DELETES the org.
    Run against production it does that to production. Without this field the
    only thing stopping an editor writing `envs: "prod"` on the `STEP_KIND_TEST`
    step that names it would be the test SUITE's own guard, which fires after the
    job has been scheduled at the cloud — not the BUNDLE's, which fires offline
    before the first mutation.

    ⛔ REFUSE, NOT DEFAULT, AND THE POLARITY IS THE WHOLE DESIGN. A lone
    `repeated string envs` cannot express the difference between NEVER STATED and
    STATED EMPTY — absent and empty are the same bytes — so its absence would
    have to mean either "nowhere" (which breaks every bundle at once) or
    "everywhere" (which is the hole, rewritten). Lifting the discriminator into
    `env_policy`, whose ZERO value is an authoring error rather than a
    permission, is what makes "safe anywhere" a sentence somebody has to write.

    THREE REFUSALS HERE, each naming what the alternative swallows:

      1. **ANY_ENV BESIDE A NON-EMPTY `envs`.** The allowlist is then dead text
         that reads as live — a reviewer scanning for the restriction finds one,
         and nothing consults it. Same hazard as `_check_web_override`'s rule 1,
         and the same remedy: one place, or neither.
      2. **ENV_ALLOWLIST WITH AN EMPTY `envs`.** A set permitted in ZERO envs
         that a pipeline step nevertheless names. Reported here rather than left
         to read as a vacuous restriction that happens to refuse everything.
      3. **`envs` AUTHORED UNDER NO POLICY AT ALL.** The author wrote the
         restriction and did not arm it. Silently this is the most dangerous of
         the three: the file LOOKS restricted and the join check below, which
         keys on `env_policy`, would (before this rule) have nothing to read.

    ⚠ A set that authors NEITHER field is fine HERE. Its refusal is the JOIN —
    the point where a pipeline step tries to RUN it — because that is where the
    absence would otherwise become a silent "any env", and refusing it here would
    make an additive field a migration for every bundle."""
    var pol = vs.env_policy.value
    if pol == ValidationSetEnvPolicy.VALIDATION_SET_ENV_POLICY_ANY_ENV and len(
        vs.envs
    ) > 0:
        errs.append(
            sctx
            + String(
                ": `env_policy` is VALIDATION_SET_ENV_POLICY_ANY_ENV, which"
                " means EVERY env, while `envs` names "
            )
            + String(len(vs.envs))
            + String(
                " of them ("
            )
            + _join(vs.envs)
            + String(
                "). Nothing reads that list under ANY_ENV, so it is DEAD TEXT"
                " that reads as a restriction. Author"
                " VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST to make the list"
                " binding, or delete the `envs` lines."
            )
        )
    if pol == ValidationSetEnvPolicy.VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST and len(
        vs.envs
    ) == 0:
        errs.append(
            sctx
            + String(
                ": `env_policy` is VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST and"
                " `envs` is EMPTY, so this set is permitted in NO env and no"
                " pipeline step could ever run it. Name the envs it is safe in,"
                " or author VALIDATION_SET_ENV_POLICY_ANY_ENV if it is safe"
                " everywhere."
            )
        )
    if pol == ValidationSetEnvPolicy.VALIDATION_SET_ENV_POLICY_UNSPECIFIED and len(
        vs.envs
    ) > 0:
        errs.append(
            sctx
            + String(
                ": `envs` is authored ("
            )
            + _join(vs.envs)
            + String(
                ") but `env_policy` is unset, so the list binds NOTHING — the"
                " file reads as restricted and is not. Author `env_policy:"
                " VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST` to arm it."
            )
        )


def _step_kind_needs_sets(k: StepKind) -> Bool:
    """True iff a pipeline step KIND runs validation (so it must reference ≥1
    validation-set): `deploy_and_validate` (the in-step gate) and `test` (the
    ad-hoc named-set run). build/stage/deploy reference no set."""
    return (
        k.value == StepKind.STEP_KIND_DEPLOY_AND_VALIDATE
        or k.value == StepKind.STEP_KIND_TEST
    )


def _is_dotted_numeric(v: String) -> Bool:
    """True iff `v` is a NON-EMPTY dotted-numeric version — ≥1 '.'-separated
    component, each component non-empty + all ASCII digits (e.g. "13", "13.0",
    "14.5.1"). A LOCAL authoring-time check: `kci_bundle` stays a
    clean authoring leaf — deliberately NOT the coordinator's version parser."""
    var b = v.as_bytes()
    if len(b) == 0:
        return False
    var comp_len = 0
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord(".")):
            if comp_len == 0:
                return False  # empty component: leading '.', "1..2", or trailing
            comp_len = 0
        elif c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
            comp_len += 1
        else:
            return False
    return comp_len > 0  # last component non-empty (no trailing '.')


def _version_components(v: String) -> List[Int]:
    """Split a `_is_dotted_numeric`-validated string into its integer components
    (manual base-10 fold — no stdlib parse dependency)."""
    var out = List[Int]()
    var b = v.as_bytes()
    var cur = 0
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord(".")):
            out.append(cur)
            cur = 0
        else:
            cur = cur * 10 + (Int(c) - ord("0"))
    out.append(cur)
    return out^


def _version_le(a: String, b: String) -> Bool:
    """component-wise a <= b for dotted-numeric versions (both assumed to pass
    `_is_dotted_numeric`). A missing trailing component is 0 ("13" == "13.0")."""
    var ac = _version_components(a)
    var bc = _version_components(b)
    var n = len(ac) if len(ac) > len(bc) else len(bc)
    for i in range(n):
        var av = ac[i] if i < len(ac) else 0
        var bv = bc[i] if i < len(bc) else 0
        if av < bv:
            return True
        if av > bv:
            return False
    return True  # equal


def _check_matrix_cell(
    mut errs: List[String], ctx: String, c: MatrixCell, build_names: List[String]
):
    """A matrix cell is EITHER native (`from_build` set) OR web (`browser` set) —
    never both, never neither.
    A NATIVE cell's `from_build` MUST name a declared BuildTarget (clones the
    `ImageRef.from_build` -> BuildTarget check — `_check_from_build`)."""
    var is_native = c.from_build.byte_length() > 0
    var is_web = c.browser.byte_length() > 0
    if is_native and is_web:
        errs.append(
            ctx
            + String(
                ": a matrix cell is EITHER native (set 'from_build') OR web (set"
                " 'browser'), never both"
            )
        )
    elif not is_native and not is_web:
        errs.append(
            ctx
            + String(
                ": a matrix cell must be native (set 'from_build' naming a build"
                " target) or web (set 'browser') — it is neither"
            )
        )
    # A NATIVE cell's from_build must resolve to a declared BuildTarget.
    if is_native and not _has(c.from_build, build_names):
        var msg = (
            ctx
            + String(".from_build '")
            + c.from_build
            + String("' does not name a build target")
        )
        var s = suggest(c.from_build, build_names)
        if s.byte_length() > 0:
            msg += String(" — did you mean '") + s + String("'?")
        elif len(build_names) > 0:
            msg += String(" (known: ") + _join(build_names) + String(")")
        errs.append(msg^)
    # os_version_min / os_version_max — authoring-time format + ordering. Each,
    # when present, MUST be dotted-numeric; if BOTH present, min <= max
    # (component-wise). Prevents a matrix ever emitting a malformed or inverted
    # version selector (fail-closed).
    var min_ok = c.os_version_min.byte_length() == 0 or _is_dotted_numeric(c.os_version_min)
    var max_ok = c.os_version_max.byte_length() == 0 or _is_dotted_numeric(c.os_version_max)
    if c.os_version_min.byte_length() > 0 and not min_ok:
        errs.append(
            ctx
            + String(".os_version_min '")
            + c.os_version_min
            + String(
                "' is not a dotted-numeric version (e.g. \"13\", \"13.0\","
                " \"14.5.1\")"
            )
        )
    if c.os_version_max.byte_length() > 0 and not max_ok:
        errs.append(
            ctx
            + String(".os_version_max '")
            + c.os_version_max
            + String(
                "' is not a dotted-numeric version (e.g. \"13\", \"13.0\","
                " \"14.5.1\")"
            )
        )
    if (
        c.os_version_min.byte_length() > 0
        and c.os_version_max.byte_length() > 0
        and min_ok
        and max_ok
        and not _version_le(c.os_version_min, c.os_version_max)
    ):
        errs.append(
            ctx
            + String(".os_version_min '")
            + c.os_version_min
            + String("' must be <= os_version_max '")
            + c.os_version_max
            + String("'")
        )


def _native_os_ok_for_kind(os: String, kind: AppKind) -> Bool:
    """The typed-artifact matrix-dims constraint: does `os` fall in the OS FAMILY a typed app-kind's NATIVE cell may
    target? A DESKTOP app confines native cells to {macos, windows, linux}
    ("ubuntu" is the device-target `os` spelling of the linux slot, so
    BOTH tokens are accepted — a canonical desktop matrix authors
    `os:"ubuntu"`); a MOBILE app to {ios, android}. A LIBRARY (and every existing
    deployable-service kind) is UNCONSTRAINED — any os. Only called for NATIVE
    cells (`from_build` set); WEB cells (browser set) are orthogonal to app-kind
    and never constrained here."""
    var k = kind.value
    if k == AppKind.APP_KIND_DESKTOP_APPLICATION:
        return (
            os == String("macos")
            or os == String("windows")
            or os == String("linux")
            or os == String("ubuntu")
        )
    if k == AppKind.APP_KIND_MOBILE_APPLICATION:
        return os == String("ios") or os == String("android")
    return True  # LIBRARY + existing kinds: any os


def _kind_native_os_list(kind: AppKind) -> StaticString:
    """The human-readable allowed-OS set for a typed app-kind's NATIVE cell (used
    only to build the fail-closed message; only DESKTOP/MOBILE constrain)."""
    var k = kind.value
    if k == AppKind.APP_KIND_DESKTOP_APPLICATION:
        return "macos, windows, linux"
    if k == AppKind.APP_KIND_MOBILE_APPLICATION:
        return "ios, android"
    return ""


def _check_cell_app_kind_dims(
    mut errs: List[String], ctx: String, c: MatrixCell, kind: AppKind
):
    """Fail-closed the typed-artifact matrix-dims constraint on ONE cell: a
    DESKTOP/MOBILE app's NATIVE cell (`from_build` set) MUST target an os in the
    app's OS family — a MobileApplication with a `linux` native cell (or an
    unspecified-os native cell) is a device-farm MISROUTE, caught here at synth.
    LIBRARY + the deployable-service kinds are unconstrained (no-op). WEB cells
    are orthogonal — never touched."""
    var is_native = c.from_build.byte_length() > 0
    if not is_native:
        return
    if _native_os_ok_for_kind(c.os, kind):
        return
    var allowed = _kind_native_os_list(kind)
    if c.os.byte_length() == 0:
        errs.append(
            ctx
            + String(": a native cell of an ")
            + kind.json_name()
            + String(" must declare an 'os' in {")
            + allowed
            + String("}")
        )
    else:
        errs.append(
            ctx
            + String(": os '")
            + c.os
            + String("' is not valid for an ")
            + kind.json_name()
            + String(" native cell (allowed: ")
            + allowed
            + String(")")
        )


def validate_bundle(
    bundle: AppBundle,
    reserved_org_id: String = String(DEFAULT_RESERVED_ORG_ID),
) -> List[String]:
    """Return the list of semantic errors in `bundle` (empty == valid). Checks:
    kind/name present, per-kind required fields, from_build references resolve,
    every oneof has exactly one arm, every wave has a non-empty env, every NAMED
    validation set has a unique name + valid steps, and every pipeline step names
    a known validation-set.

    `reserved_org_id` is the control plane's reserved organization, which no
    `test_role` may target (empty = the control plane reserves none)."""
    var errs = List[String]()
    # The parameter NAMES the spec declares — collected during the spec check and
    # read by the per-wave `parameter_override` check below, which refuses an
    # override that names nothing (a silently-ignored per-env value).
    var spec_param_names = List[String]()

    # ★ IS THIS A MANAGED APP? Read ONCE, at the bundle level, and threaded to every
    # per-spec datastore check — because tenancy is a property of the BUNDLE and the
    # datastore is a property of the SPEC, and the placement rule is the one place
    # they meet. See `datastore_identity.managed_app_placement_error`.
    var is_customer_tenancy = bundle.tenancy.value == Tenancy.TENANCY_CUSTOMER
    # ★ AND THE OTHER SIDE OF THE SAME AXIS, WHICH IS **NOT** THE COMPLEMENT.
    # `Tenancy` has THREE members, so `not is_customer_tenancy` is
    # "CONTROL_PLANE **or** UNSPECIFIED" — and UNSPECIFIED is the proto3 zero, the
    # value a bundle that authored no `tenancy:` line carries. Written as the
    # negation, a bundle that simply forgot would be treated as Komira's own and
    # allowed to mint identities in Komira's control plane. Both predicates are
    # False for the same UNSPECIFIED bundle, deliberately; that is the safe arm.
    # (The release CLI's tenancy rule states the identical rule for the deploy
    # path and cannot be imported here — this package's dep line is
    # `kci_bundle_proto` + `komira_proto_codec` only.)
    var is_control_plane_tenancy = (
        bundle.tenancy.value == Tenancy.TENANCY_CONTROL_PLANE
    )

    # ── top-level required fields ──
    if bundle.kind.value == AppKind.APP_KIND_UNSPECIFIED:
        errs.append(
            String(
                "bundle: 'kind' is required (APP_KIND_API |"
                " APP_KIND_STATIC_FRONTEND | APP_KIND_DATA_PIPELINE |"
                " APP_KIND_SEARCH_CLUSTER)"
            )
        )
    if bundle.name.byte_length() == 0:
        errs.append(String("bundle: 'name' is required"))

    # ── build targets: names present + unique (referenced by symbol) ──
    var build_names = List[String]()
    for i in range(len(bundle.build)):
        ref b = bundle.build[i]
        if b.name.byte_length() == 0:
            errs.append(String("build[") + String(i) + String("]: 'name' is required"))
        elif _has(b.name, build_names):
            errs.append(
                String("build[")
                + String(i)
                + String("]: duplicate build name '")
                + b.name
                + String("'")
            )
        if b.name.byte_length() > 0:
            build_names.append(String(b.name))
        if b.dockerfile.byte_length() == 0:
            errs.append(
                String("build '") + b.name + String("': 'dockerfile' is required")
            )
        # ⭐ JOB-VM — the two build-target roles (fields 6/7).
        if b.file_role.value != 0:
            errs.append(
                job_vm_s0_refusal(
                    String("build '") + b.name + String("'"),
                    String("file_role: ") + b.file_role.json_name(),
                    String("the deploy stages file artifacts by role"),
                )
            )
        if b.repository_role.value != 0:
            errs.append(
                job_vm_s0_refusal(
                    String("build '") + b.name + String("'"),
                    String("repository_role: ") + b.repository_role.json_name(),
                    String("the deploy stages repository artifacts by role"),
                )
            )

    # ── the spec (image required for container-deploying kinds; port required
    # for API). A STATIC_FRONTEND deploys NO container — the SPA content is
    # PUBLISHED to the front door's bucket (a pipeline stage), so its `image` is
    # OPTIONAL (when present it rides the WebFrontend node's `content_digest`
    # for freshness/audit). ──
    # ⛔ THE SINGULAR `spec` IS NOT REQUIRED OF A MULTI-SERVICE BUNDLE, AND
    # DEMANDING ONE WOULD DEMAND A LIE (CP consolidation).
    # `compose_api` IGNORES `bundle.spec` outright when `services` is non-empty
    # (`_auto_lifted_services`: the list is AUTHORITATIVE), so a singular spec on
    # a six-service bundle is a block an author writes, a reviewer reads, and NO
    # deploy consults. Requiring it does not make anything safer; it makes the
    # file say something untrue. What the authoritative specs DO get is the same
    # per-spec checks, applied per service, at the loop below — which is the half
    # that actually matters and did not exist.
    if not bundle.spec:
        if len(bundle.services) == 0:
            errs.append(String("bundle: 'spec' is required"))
    else:
        ref sp = bundle.spec.value()
        # ★ SHARED INFRASTRUCTURE HAS NO IMAGE, AND THAT IS THE POINT OF THE KIND.
        # It owns resources and serves nothing; requiring an image
        # would force a decorative container that nothing calls, that costs money, and
        # that can fail a deploy while being unable to fail a test. The
        # STATIC_FRONTEND carve-out beside it is the same shape for a different
        # reason (its content is a bucket, not a container).
        var image_required = (
            bundle.kind.value != AppKind.APP_KIND_STATIC_FRONTEND
            and bundle.kind.value != AppKind.APP_KIND_SHARED_INFRASTRUCTURE
        )
        _check_image(errs, String("spec"), sp.image, image_required, build_names)
        for ref e in sp.env:
            _check_env(errs, String("spec"), e)
        # ★ THE MANAGED-APP PARAMETERS (field 31).
        _check_parameters(errs, String("spec"), sp.parameters)
        for ref prm in sp.parameters:
            if prm.name.byte_length() > 0:
                spec_param_names.append(String(prm.name))
        # ⛔ AND IT MUST NOT TRY TO SERVE. A shared-infrastructure bundle that
        # authors an image or a port is asking for a served node this kind does not
        # compose — so it would be authored, accepted, and silently absent from the
        # graph. Refuse it here instead: an author who wants a service wants a
        # different kind.
        if bundle.kind.value == AppKind.APP_KIND_SHARED_INFRASTRUCTURE:
            if sp.image:
                errs.append(
                    String(
                        "spec: an APP_KIND_SHARED_INFRASTRUCTURE bundle must not"
                        " author an 'image' — it owns resources and serves nothing,"
                        " and it composes NO ServerlessCompute node, so an authored"
                        " image would be silently unused. Use APP_KIND_API for a"
                        " served service."
                    )
                )
            if Int(sp.port) > 0:
                errs.append(
                    String(
                        "spec: an APP_KIND_SHARED_INFRASTRUCTURE bundle must not"
                        " author a 'port' — nothing listens. Use APP_KIND_API for a"
                        " served service."
                    )
                )
        if bundle.kind.value == AppKind.APP_KIND_API and Int(sp.port) <= 0:
            errs.append(
                String("spec: 'port' is required (> 0) for an APP_KIND_API bundle")
            )
        # API-EDGE authoring (spec fields 18-19):
        # `inbound_route_path` is REQUIRED iff `inbound: WEBHOOK` (the
        # SINGLE_PATH route — authored, never defaulted) and MUST be empty for
        # every other intent (CLIENT is CATCH_ALL; NONE/POLL have no route).
        if sp.inbound.value == InboundNeed.INBOUND_NEED_WEBHOOK:
            if sp.inbound_route_path.byte_length() == 0:
                errs.append(
                    String(
                        "spec: 'inbound_route_path' is required for 'inbound:"
                        " INBOUND_NEED_WEBHOOK' (the single inbound route, e.g."
                        " \"/mail/inbound\" — no baked default)"
                    )
                )
        elif sp.inbound_route_path.byte_length() > 0:
            errs.append(
                String(
                    "spec: 'inbound_route_path' is only valid with 'inbound:"
                    " INBOUND_NEED_WEBHOOK' (a CLIENT edge is catch-all; NONE/"
                    "POLL have no inbound route)"
                )
            )
        _check_secured_inbound_routes(errs, sp)
        _check_datastore_database(errs, String("spec"), sp, is_customer_tenancy)
        _check_index_tables(errs, String("spec"), sp)
        # ★ THE COLLECTION SHAPES (field 35) — checked here for the reason
        # `_check_index_tables` above is: a shape declared beside no datastore
        # need reaches no node and is provisioned by nothing.
        _check_datastore_collections(errs, String("spec"), sp)
        # THE INGRESS REALIZATION INPUTS (field 30).
        _check_ingress(errs, String("spec"), sp)
        # ★ THE SERVED SERVICE'S OUTBOUND PATH (field 33) — the `network_ingress`
        # sibling. Refused offline when half-authored; see `_check_network_egress`.
        _check_network_egress(errs, String("spec"), sp)

    # ── THE NAMED SERVICES' specs (SVCREF-1). A multi-service bundle's datastore
    # intent lives on `services[].spec`, NOT on the singular `spec`, so a check that
    # only read `bundle.spec` would let every named service declare a datastore with
    # no database name — which is the exact hole this field closes. The singular
    # `spec` is IGNORED at compose when `services` is non-empty, so this is where
    # the authoritative specs are. ──
    for i in range(len(bundle.services)):
        if not bundle.services[i].spec:
            continue
        # ★ THE SERVICE'S OWN CTX — its NAME, not just its ordinal. An operator
        # reading "services[3] spec: 'port' is required" has to count blocks; one
        # reading "service 'orders-api' spec" does not.
        var sctx = String("services[") + String(i) + String("] spec")
        if bundle.services[i].name.byte_length() > 0:
            sctx = String("service '") + bundle.services[i].name + String(
                "' spec"
            )
        ref ssp = bundle.services[i].spec.value()
        # ★ THE PER-SERVICE KIND, NOT THE BUNDLE'S. This is the whole reason the
        # checks below could not simply reuse the singular-spec block: in a
        # consolidated control plane ONE service is
        # APP_KIND_SHARED_INFRASTRUCTURE while the bundle is APP_KIND_API, so a
        # check keyed on `bundle.kind` would demand an image and a port from the
        # resource OWNER — which composes no served node and has nothing to
        # listen on.
        var skind = bundle.services[i].kind.value
        var s_image_required = (
            skind != AppKind.APP_KIND_STATIC_FRONTEND
            and skind != AppKind.APP_KIND_SHARED_INFRASTRUCTURE
        )
        _check_image(errs, sctx, ssp.image, s_image_required, build_names)
        for ref e in ssp.env:
            _check_env(errs, sctx, e)
        _check_parameters(errs, sctx, ssp.parameters)
        # ⚠ THE UNION, AND THAT IS THE POINT. `Wave.parameter_override` is
        # BUNDLE-scoped — it has no service axis — but `resolve_parameter_args`
        # walks each service's OWN `spec.parameters`, so an override reaches
        # exactly the services that DECLARE the name and is a no-op everywhere
        # else. Checking a multi-service bundle's overrides against the singular
        # spec's parameter list (which is empty) would refuse a real,
        # correctly-scoped override that only one sibling service declares; such an
        # override must stay legal.
        for ref prm in ssp.parameters:
            if prm.name.byte_length() > 0:
                spec_param_names.append(String(prm.name))
        if skind == AppKind.APP_KIND_SHARED_INFRASTRUCTURE:
            if ssp.image:
                errs.append(
                    sctx
                    + String(
                        ": an APP_KIND_SHARED_INFRASTRUCTURE service must not"
                        " author an 'image' — it owns resources and serves"
                        " nothing, and it composes NO ServerlessCompute node, so"
                        " an authored image would be silently unused. Use"
                        " APP_KIND_API for a served service."
                    )
                )
            if Int(ssp.port) > 0:
                errs.append(
                    sctx
                    + String(
                        ": an APP_KIND_SHARED_INFRASTRUCTURE service must not"
                        " author a 'port' — nothing listens. Use APP_KIND_API"
                        " for a served service."
                    )
                )
        if skind == AppKind.APP_KIND_API and Int(ssp.port) <= 0:
            errs.append(
                sctx
                + String(
                    ": 'port' is required (> 0) for an APP_KIND_API service"
                )
            )
        _check_secured_inbound_routes(errs, ssp)
        _check_datastore_database(
            errs,
            String("services[") + String(i) + String("] spec"),
            bundle.services[i].spec.value(),
            is_customer_tenancy,
        )
        _check_index_tables(
            errs,
            String("services[") + String(i) + String("] spec"),
            bundle.services[i].spec.value(),
        )
        # ★ THE COLLECTION SHAPES, PER NAMED SERVICE (field 35). Checked on
        # `services[].spec` as well as the singular `spec` for the reason the
        # per-service datastore check above states — a multi-service bundle
        # carries a spec per service and a check that only read `bundle.spec`
        # would let every named service author an unprovisioned collection.
        _check_datastore_collections(
            errs,
            String("services[") + String(i) + String("] spec"),
            bundle.services[i].spec.value(),
        )
        _check_ingress(
            errs,
            String("services[") + String(i) + String("] spec"),
            bundle.services[i].spec.value(),
        )
        # ★ THE OUTBOUND PATH, PER NAMED SERVICE (field 33). Checked on
        # `services[].spec` as well as the singular `spec` for the reason the
        # datastore check above states: a multi-service bundle's per-service
        # intent never touches `bundle.spec`, so a check that only read the
        # singular one would let every named service half-author the block.
        _check_network_egress(
            errs,
            String("services[") + String(i) + String("] spec"),
            bundle.services[i].spec.value(),
        )

    # ── The SERVED SERVICE NAMES this bundle composes. Derived ONCE, here,
    #    because THREE consumers need it: `outputs[].from_served`, a
    #    `crons[].target`, and (later) any other typed sibling reference. It used
    #    to be derived inline at the outputs loop; a second copy beside the crons
    #    would be one refactor away from disagreeing with the first. ──
    var served_names = List[String]()
    if len(bundle.services) > 0:
        for i in range(len(bundle.services)):
            if bundle.services[i].name.byte_length() > 0:
                served_names.append(String(bundle.services[i].name))
    elif bundle.name.byte_length() > 0:
        served_names.append(String(bundle.name))

    # ── ★ THE WEB FRONT DOOR'S SIBLING REFERENCE. Placed HERE, right
    #    after `served_names` is derived, because that list is what makes the
    #    reference resolvable — this is the "any other typed sibling reference"
    #    the comment above anticipated. Both the singular spec and every named
    #    service's spec are checked: a consolidated machine carries its web front
    #    door as a `services[]` entry, so reading only `bundle.spec` would check
    #    the one place the value is NOT authored. ──
    if bundle.spec:
        _check_web_api_service_ref(
            errs,
            String("spec"),
            bundle.spec.value().web_api_service_logical_id,
            served_names,
            len(bundle.services),
        )
    for i in range(len(bundle.services)):
        if not bundle.services[i].spec:
            continue
        var wctx_svc = String("services[") + String(i) + String("] spec")
        if bundle.services[i].name.byte_length() > 0:
            wctx_svc = String("service '") + bundle.services[i].name + String(
                "' spec"
            )
        _check_web_api_service_ref(
            errs,
            wctx_svc,
            bundle.services[i].spec.value().web_api_service_logical_id,
            served_names,
            len(bundle.services),
        )

    # ── RUN-TO-COMPLETION JOBS (field 12). Validated BEFORE the
    #    waves + validation sets because an `execute_job` step in either resolves
    #    its ref against this list — a step is checked against the jobs that were
    #    declared, never against a list that is still being built. ──
    var job_names = List[String]()
    for i in range(len(bundle.jobs)):
        ref j = bundle.jobs[i]
        var jctx = String("jobs[") + String(i) + String("]")
        if j.name.byte_length() > 0:
            if _has(j.name, job_names):
                errs.append(
                    jctx + String(": duplicate job name '") + j.name + String("'")
                )
            else:
                job_names.append(String(j.name))
            jctx = String("job '") + j.name + String("'")
        _check_job_spec(errs, jctx, j, build_names)

    # ── SCHEDULED CALLS (field 13) — unique name + a target that
    #    resolves to a service THIS bundle declares. ──
    var cron_names = List[String]()
    for i in range(len(bundle.crons)):
        ref c = bundle.crons[i]
        var cctx = String("crons[") + String(i) + String("]")
        if c.name.byte_length() > 0:
            if _has(c.name, cron_names):
                errs.append(
                    cctx + String(": duplicate cron name '") + c.name + String("'")
                )
            else:
                cron_names.append(String(c.name))
            cctx = String("cron '") + c.name + String("'")
        _check_cron_spec(errs, cctx, c, served_names)

    # ── RUN-SCOPED LIFECYCLE (field 14). ──
    _check_ephemeral(errs, bundle)

    # ★★ THE PER-WAVE WEB FRONT-DOOR TOPOLOGY (`Wave.web_override`, field 8) —
    #    the TOTAL-override rules. Whole-bundle scoped because two of the three
    #    are RELATIONS between waves and the spec, not properties of one wave.
    _check_web_override(errs, bundle, served_names)

    # ── waves: non-empty env symbol + valid validate steps ──
    if len(bundle.waves) == 0:
        errs.append(String("bundle: at least one wave is required"))
    for i in range(len(bundle.waves)):
        ref w = bundle.waves[i]
        var wctx = String("waves[") + String(i) + String("]")
        if w.env.byte_length() == 0:
            errs.append(wctx + String(": 'env' is required (a logical env symbol)"))
        else:
            wctx = String("wave '") + w.env + String("'")
        for ref v in w.validate:
            _check_validate_step(
                errs,
                wctx,
                v,
                build_names,
                job_names,
                served_names,
                is_control_plane_tenancy,
                reserved_org_id,
            )
        # …and the DAG the steps form: every `depends_on` resolves in this list.
        _check_step_dag(errs, wctx, w.validate)
        # …and that the wave's bootstrap CREATES the very environment its
        # e2e step LOOKS FOR. Two hand-typed strings whose disagreement
        # costs a leaked compute environment, not a retry.
        _check_lifecycle_env_pairing(errs, wctx, w.validate)
        # ★ THE PER-WAVE ENV OVERRIDES (Wave field 4).
        #
        # ⚠ `w.env_override` MUST go through `_check_env` like `run_container`,
        # `jobs`, `spec`, and the named services' specs: otherwise a wave
        # override with ZERO oneof arms set, or an `UNSPECIFIED` `value_from`,
        # would validate CLEAN and compose to a variable bound to nothing. A
        # shared helper is only as good as its call sites, and a context that
        # never calls it is silently exempt from every rule the helper states. It
        # is also why the INTERNAL-ORIGIN gate is a DEFAULT-FALSE parameter rather
        # than a per-call-site check — this loop inherits the refusal by
        # construction.
        for ref eo in w.env_override:
            _check_env(errs, wctx + String(" env_override"), eo)
        # ★ THE PER-WAVE PARAMETER OVERRIDES (Wave field 5). Checked against the
        # names the spec DECLARES, so an override that would be silently ignored
        # is refused instead.
        _check_parameters(
            errs, wctx, w.parameter_override, True, spec_param_names
        )
        # ⭐ JOB-VM — the per-service edge allow-list (Wave field 9).
        for ref svc in w.api_edge_services:
            errs.append(
                job_vm_s0_refusal(
                    wctx,
                    String("api_edge_services: ") + svc,
                    String("the deploy composes per-service API-edge allow-lists"),
                )
            )

    # ── TRIGGERS: named, uniquely, with exactly one arm, and a parseable cadence ──
    # Without these checks a SCHEDULE trigger could be authored with nowhere to
    # say WHEN and nothing would complain.
    var trigger_names = List[String]()
    for i in range(len(bundle.triggers)):
        ref t = bundle.triggers[i]
        var tctx = String("triggers[") + String(i) + String("]")
        # (a) NAME — required and unique. The name is the trigger's NODE IDENTITY
        # (`trigger-<name>`, `_append_trigger_nodes`), so a duplicate is not a
        # style problem: two triggers would compose onto ONE node and one of them
        # would silently cease to exist.
        if t.name.byte_length() == 0:
            errs.append(
                tctx
                + String(
                    ": 'name' is required — it is the trigger's node identity"
                    " (`trigger-<name>`)"
                )
            )
        else:
            if _has(t.name, trigger_names):
                errs.append(
                    tctx
                    + String(": duplicate trigger name '")
                    + t.name
                    + String(
                        "' — the name is the node identity, so two triggers"
                        " sharing one would compose onto a single node"
                    )
                )
            trigger_names.append(String(t.name))
            tctx = String("trigger '") + t.name + String("'")
        # (b) EXACTLY ONE ARM. Zero arms names no firing condition at all.
        if t._oneof0_case == 0:
            errs.append(
                tctx
                + String(
                    ": exactly one of 'git_push' | 'schedule' |"
                    " 'package_published' is required (the arm IS the event)"
                )
            )
        elif t._oneof0_case == _TRIGGER_ARM_GIT_PUSH:
            ref g = t.git_push.value()
            if g.source_kind.value == SourceKind.SOURCE_KIND_UNSPECIFIED:
                errs.append(
                    tctx
                    + String(
                        ": git_push 'source_kind' is required"
                        " (SOURCE_KIND_GIT_SELFHOSTED | SOURCE_KIND_GIT_EXTERNAL)"
                    )
                )
            if g.repo_ref.byte_length() == 0:
                errs.append(tctx + String(": git_push 'repo_ref' is required"))
            if g.ref_.byte_length() == 0:
                errs.append(
                    tctx + String(": git_push 'ref' is required (e.g. \"main\")")
                )
        elif t._oneof0_case == _TRIGGER_ARM_SCHEDULE:
            ref s = t.schedule.value()
            if s.cron.byte_length() == 0:
                errs.append(
                    tctx
                    + String(
                        ": schedule 'cron' is required (e.g. \"0 6 * * 1\" for a"
                        " weekly merge-from-live)"
                    )
                )
            else:
                # THE CADENCE MUST RESOLVE HERE, not at sweep time. A cron the
                # control plane cannot turn into an interval is an authoring bug,
                # and the only moment it is cheap to report is while the author is
                # looking at the file. `cron_cadence_us` raises with the reason.
                try:
                    _ = cron_cadence_us(s.cron)
                except e:
                    errs.append(tctx + String(": ") + String(e))
        elif t._oneof0_case == _TRIGGER_ARM_PACKAGE_PUBLISHED:
            ref p = t.package_published.value()
            if p.registry_kind.value == RegistryKind.REGISTRY_KIND_UNSPECIFIED:
                errs.append(
                    tctx
                    + String(
                        ": package_published 'registry_kind' is required"
                        " (REGISTRY_KIND_GITHUB_PACKAGES | REGISTRY_KIND_CODEWORKS)"
                    )
                )
            if p.package_ref.byte_length() == 0:
                errs.append(
                    tctx + String(": package_published 'package_ref' is required")
                )
    # (c) AT MOST ONE SCHEDULE. The control plane keeps ONE
    # `next_auto_update_at` per deployment, so a second declared cadence has
    # nowhere to be evaluated and which one wins would become a property of
    # authoring order. Reported as a semantic error rather than left to raise
    # inside the resolver, so the author sees it with every other error at once.
    var schedule_count = 0
    for i in range(len(bundle.triggers)):
        if bundle.triggers[i]._oneof0_case == _TRIGGER_ARM_SCHEDULE:
            schedule_count += 1
    if schedule_count > 1:
        errs.append(
            String("bundle: ")
            + String(schedule_count)
            + String(
                " schedule triggers are declared; a machine has exactly ONE"
                " merge-from-live cadence (the control plane keeps one clock per"
                " deployment)"
            )
        )

    # ── named validation SETS: unique name + valid steps ──
    # A set is DEFINED ONCE and referenced by name (by a pipeline step + by the
    # release CLI's test verb); it is NOT welded to an env. EMPTY is fine.
    var set_names = List[String]()
    for i in range(len(bundle.validation_sets)):
        ref vs = bundle.validation_sets[i]
        var sctx = String("validation_sets[") + String(i) + String("]")
        if vs.name.byte_length() == 0:
            errs.append(sctx + String(": 'name' is required (a validation-set name)"))
        elif _has(vs.name, set_names):
            errs.append(
                sctx
                + String(": duplicate validation-set name '")
                + vs.name
                + String("'")
            )
        if vs.name.byte_length() > 0:
            set_names.append(String(vs.name))
            sctx = String("validation_set '") + vs.name + String("'")
        for ref v in vs.steps:
            _check_validate_step(
                errs,
                sctx,
                v,
                build_names,
                job_names,
                served_names,
                is_control_plane_tenancy,
                reserved_org_id,
            )
        # The named-set carrier of the SAME DAG rule (the scheduler is the same).
        _check_step_dag(errs, sctx, vs.steps)
        # ⛔ The ENV RESTRICTION's internal consistency.
        # The JOIN half — a pipeline step naming this set in an env it does not
        # permit — is enforced in the pipeline loop below.
        _check_validation_set_env_policy(errs, sctx, vs)

    # ── device/capability MATRICES: unique name + each cell native-XOR-web +
    #    a native cell's from_build resolves (fail-closed at synth). AUTHORING
    #    validation ONLY — NO cell fan is emitted here. EMPTY is fine. ──
    var matrix_names = List[String]()
    for i in range(len(bundle.matrices)):
        ref mx = bundle.matrices[i]
        var mctx = String("matrices[") + String(i) + String("]")
        if mx.name.byte_length() == 0:
            errs.append(mctx + String(": 'name' is required (a matrix name)"))
        elif _has(mx.name, matrix_names):
            errs.append(
                mctx + String(": duplicate matrix name '") + mx.name + String("'")
            )
        if mx.name.byte_length() > 0:
            matrix_names.append(String(mx.name))
            mctx = String("matrix '") + mx.name + String("'")
        # A declared matrix MUST carry ≥1 cell — a `matrix_ref` to a zero-cell
        # matrix would silently fan to ZERO jobs (fail-open); flag here.
        if len(mx.cell) == 0:
            errs.append(mctx + String(": a matrix must declare at least one 'cell'"))
        # cell names: non-empty + UNIQUE WITHIN this matrix. The proto documents
        # `MatrixCell.name` as "unique per Matrix; a stable handle a job/verdict
        # references" — a duplicate is a verdict-to-cell ambiguity in the fan.
        var cell_names = List[String]()
        for j in range(len(mx.cell)):
            ref c = mx.cell[j]
            var cctx = mctx + String(".cell[") + String(j) + String("]")
            if c.name.byte_length() == 0:
                errs.append(cctx + String(": 'name' is required (a cell name)"))
            elif _has(c.name, cell_names):
                errs.append(
                    cctx
                    + String(": duplicate cell name '")
                    + c.name
                    + String("' (unique per matrix)")
                )
            if c.name.byte_length() > 0:
                cell_names.append(String(c.name))
                cctx = mctx + String(" cell '") + c.name + String("'")
            _check_matrix_cell(errs, cctx, c, build_names)
            # The typed-artifact matrix-dims constraint: confine a
            # DESKTOP/MOBILE app's NATIVE cells to the app's OS family
            # (fail-closed; LIBRARY + deployable-service kinds unconstrained).
            _check_cell_app_kind_dims(errs, cctx, c, bundle.kind)

    # ── the pipeline: each step's kind is set, envs non-empty, every
    #    validation_set_ref names a DECLARED set, and every matrix_ref names
    #    a DECLARED matrix. ──
    if bundle.pipeline:
        ref p = bundle.pipeline.value()
        for i in range(len(p.steps)):
            ref st = p.steps[i]
            var pctx = String("pipeline.steps[") + String(i) + String("]")
            if st.step_kind.value == StepKind.STEP_KIND_UNSPECIFIED:
                errs.append(
                    pctx
                    + String(
                        ": 'step_kind' is required (STEP_KIND_BUILD | STEP_KIND_STAGE"
                        " | STEP_KIND_DEPLOY | STEP_KIND_DEPLOY_AND_VALIDATE |"
                        " STEP_KIND_TEST)"
                    )
                )
            if len(st.envs) == 0:
                errs.append(
                    pctx + String(": at least one 'envs' target is required")
                )
            # deploy_and_validate / test MUST reference ≥1 validation-set (they run
            # validation); build/stage/deploy reference none.
            if _step_kind_needs_sets(st.step_kind) and len(
                st.validation_set_refs
            ) == 0:
                errs.append(
                    pctx
                    + String(
                        ": step_kind '"
                    )
                    + st.step_kind.json_name()
                    + String(
                        "' runs validation, so it requires at least one"
                        " 'validation_set_refs'"
                    )
                )
            # every ref must name a DECLARED validation set.
            for ref r in st.validation_set_refs:
                if not _has(r, set_names):
                    var msg = (
                        pctx
                        + String(".validation_set_refs '")
                        + r
                        + String("' does not name a validation_set")
                    )
                    var s = suggest(r, set_names)
                    if s.byte_length() > 0:
                        msg += String(" — did you mean '") + s + String("'?")
                    elif len(set_names) > 0:
                        msg += String(" (known: ") + _join(set_names) + String(")")
                    else:
                        msg += String(" (no validation_sets are declared)")
                    errs.append(msg^)
                    continue
                # ⛔⛔ THE JOIN — the reason the field exists. A step that RUNS a set (`deploy_and_validate` / `test`)
                # may only run it in an env that set PERMITS, and a set that
                # states NO policy may not be run at all.
                #
                # THIS IS WHERE "REFUSE, NOT DEFAULT" IS CASHED. Reading an unset
                # `env_policy` as "any env" here is exactly the hole: a set that
                # self-provisions a real account and CASCADE-DELETES the org would
                # be pointed at the production tenant by an editor changing this
                # step's `envs` to "prod", with nothing offline objecting. So the
                # ABSENCE of a policy is refused at the point of reference, where
                # the author is already writing the dangerous line — and a set
                # nothing references stays legal, which is what keeps the field
                # additive rather than a migration.
                if not _step_kind_needs_sets(st.step_kind):
                    continue
                for sj in range(len(bundle.validation_sets)):
                    ref vset = bundle.validation_sets[sj]
                    if vset.name != r:
                        continue
                    var vpol = vset.env_policy.value
                    if (
                        vpol
                        == ValidationSetEnvPolicy.VALIDATION_SET_ENV_POLICY_UNSPECIFIED
                    ):
                        errs.append(
                            pctx
                            + String(".validation_set_refs '")
                            + r
                            + String(
                                "' names a validation_set that states NO"
                                " `env_policy`, so nothing says which envs it is"
                                " safe to RUN in. An unset policy is NOT 'any"
                                " env' — a named set can create and destroy real"
                                " state in whatever env it is pointed at, so the"
                                " permission has to be written down. Author"
                                " `env_policy:"
                                " VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST` +"
                                " `envs` on validation_set '"
                            )
                            + r
                            + String(
                                "', or `env_policy:"
                                " VALIDATION_SET_ENV_POLICY_ANY_ENV` if it is"
                                " safe everywhere."
                            )
                        )
                        break
                    if (
                        vpol
                        != ValidationSetEnvPolicy.VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST
                    ):
                        break
                    for ref e in st.envs:
                        if _has(e, vset.envs):
                            continue
                        errs.append(
                            pctx
                            + String(": step_kind '")
                            + st.step_kind.json_name()
                            + String("' runs validation_set '")
                            + r
                            + String("' against env '")
                            + e
                            + String(
                                "', which that set does NOT permit. Its"
                                " `env_policy` is"
                                " VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST over"
                                " envs: "
                            )
                            + _join(vset.envs)
                            + String(
                                ". Point the step at a permitted env, or — if"
                                " this set really is safe in '"
                            )
                            + e
                            + String(
                                "' — add that env to the set's own `envs`, where"
                                " the decision is reviewable."
                            )
                        )
                    break
            # the matrix_ref (when set) must name a DECLARED matrix
            # (fail-closed). EMPTY ⇒ the step is not matrix-fanned.
            if st.matrix_ref.byte_length() > 0 and not _has(st.matrix_ref, matrix_names):
                var msg = (
                    pctx
                    + String(".matrix_ref '")
                    + st.matrix_ref
                    + String("' does not name a matrix")
                )
                var s = suggest(st.matrix_ref, matrix_names)
                if s.byte_length() > 0:
                    msg += String(" — did you mean '") + s + String("'?")
                elif len(matrix_names) > 0:
                    msg += String(" (known: ") + _join(matrix_names) + String(")")
                else:
                    msg += String(" (no matrices are declared)")
                errs.append(msg^)

    # ── the named DEPLOY OUTPUTS (fail-closed at synth). Each output: a
    #    non-empty UNIQUE `name`, and (the ONLY output kind built — the
    #    served-URL output) a `from_served`
    #    that names a REAL served service the bundle composes. `${ref:<bundle>.
    #    outputs.<name>}` resolution reads `service/<from_served>` → URL from the
    #    SAME registry `register_served_urls_over` writes (svcref/), so a
    #    `from_served` that names no composed service is a dangling reference that
    #    would never resolve — caught here. EMPTY ⇒ no outputs. ──
    #
    # The candidate served-service set: the authoritative list
    # (`bundle.services[].name`) when non-empty, else the singular `bundle.name`
    # (the auto-lifted single service). This mirrors `register_served_urls_over`,
    # which registers `service/<name>` for each served `<name>-svc` node the
    # bundle composes.
    var output_names = List[String]()
    for i in range(len(bundle.outputs)):
        ref o = bundle.outputs[i]
        var octx = String("outputs[") + String(i) + String("]")
        if o.name.byte_length() == 0:
            errs.append(octx + String(": 'name' is required (an output name)"))
        elif _has(o.name, output_names):
            errs.append(
                octx + String(": duplicate output name '") + o.name + String("'")
            )
        if o.name.byte_length() > 0:
            output_names.append(String(o.name))
            octx = String("output '") + o.name + String("'")
        # Only the SERVED-URL output kind is built: `from_served` is REQUIRED and
        # MUST name a served service the bundle composes (fail-closed; general
        # arbitrary-value output kinds are a later extension).
        if o.from_served.byte_length() == 0:
            errs.append(
                octx
                + String(
                    ": 'from_served' is required (only the served-URL output"
                    " kind is built — it names the served service whose URL this output"
                    " exposes)"
                )
            )
        elif not _has(o.from_served, served_names):
            var msg = (
                octx
                + String(".from_served '")
                + o.from_served
                + String("' does not name a served service in this bundle")
            )
            var s = suggest(o.from_served, served_names)
            if s.byte_length() > 0:
                msg += String(" — did you mean '") + s + String("'?")
            elif len(served_names) > 0:
                msg += String(" (served: ") + _join(served_names) + String(")")
            else:
                msg += String(" (this bundle composes no served service)")
            errs.append(msg^)

    return errs^
