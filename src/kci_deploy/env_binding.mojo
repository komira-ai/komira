# =============================================================================
# kci_deploy/env_binding.mojo -- the neutral resolved-environment value the
#   deploy facade consumes. A plain value type; the facade names no proto.
# =============================================================================
#
# WHY A NEUTRAL VALUE. The environment registry's wire shape is an authoring
# schema; the deploy library is provider-neutral and proto-free at its boundary
# and depends only on `kci_iac` and its own seams. The frontend (the CLI, a
# managed deployer) maps its own registry row into an `EnvBinding` at the door,
# which keeps the authoring schema out of the reconcile library.
#
# The Int codes below MIRROR the environment registry's enum ordinals, so a
# frontend maps a parsed enum value straight through.
#
# ENCAPSULATION: a flat value type of owned Strings, Ints and Bools. No
# pointer field, no wildcard origin.
# =============================================================================


# =============================================================================
# The CLOUD posture codes. A coarse cloud / on-prem posture that names no vendor
# product; the node-kind x cloud conformer matrix below this library selects the
# implementation.
# =============================================================================
comptime CLOUD_UNSPECIFIED: Int = 0
"""Proto zero. An authoring error at bind time: an environment must name its
posture. A well-formed frontend never hands this to the facade."""
comptime CLOUD_GCP: Int = 1
"""A public-cloud GCP posture."""
comptime CLOUD_AWS: Int = 2
"""A public-cloud AWS posture."""
comptime CLOUD_AZURE: Int = 3
"""A public-cloud Azure posture."""
comptime CLOUD_KUBERNETES: Int = 4
"""A Kubernetes posture."""
comptime CLOUD_LOCAL: Int = 5
"""A single-box local posture (a laptop, a local compose target), with ambient
credentials."""


# =============================================================================
# The DIRECT-APPLY governance codes: whether an environment may be mutated
# outside a pipeline run. The one code with library behaviour: `deploy_apply`
# gates on it.
# =============================================================================
comptime DIRECT_APPLY_UNSPECIFIED: Int = 0
"""Proto zero. Treated as the safe posture (PIPELINE_ONLY): an environment is
not directly mutable unless it explicitly opts in."""
comptime DIRECT_APPLY_ALLOWED: Int = 1
"""A development / personal environment: a direct apply is permitted."""
comptime DIRECT_APPLY_PIPELINE_ONLY: Int = 2
"""Only a pipeline run may mutate this environment; a direct apply is refused
by `deploy_apply`."""


# =============================================================================
# The ENVIRONMENT-KIND codes: LOCAL emulated versus CLOUD (the default).
# =============================================================================
comptime ENVIRONMENT_KIND_UNSPECIFIED: Int = 0
"""Proto zero. Read as CLOUD: an environment is not LOCAL unless it explicitly
opts in."""
comptime ENVIRONMENT_KIND_CLOUD: Int = 1
"""A cloud environment: a real cloud project with real service behaviour."""
comptime ENVIRONMENT_KIND_LOCAL: Int = 2
"""A local emulated environment: emulator-backed services and a single-box or
local-Kubernetes applier. `is_local()` is True."""


# =============================================================================
# The DEPLOY-PROVIDER codes: WHERE the workload runs, per environment. They
# mirror the deploy model's `DeployProvider` ordinals without making this
# library depend on that proto.
# =============================================================================
comptime DEPLOY_PROVIDER_UNSPECIFIED: Int = 0
"""Proto zero. A reader defaults it to CLOUD_RUN for a cloud environment."""
comptime DEPLOY_PROVIDER_CLOUD_RUN: Int = 1
"""Serverless containers (the cloud default)."""
comptime DEPLOY_PROVIDER_LAMBDA: Int = 2
"""AWS Lambda."""
comptime DEPLOY_PROVIDER_FUNCTIONS: Int = 3
"""Cloud Functions."""
comptime DEPLOY_PROVIDER_ECS: Int = 4
"""AWS ECS."""
comptime DEPLOY_PROVIDER_K8S: Int = 5
"""A Kubernetes Deployment (the local-environment applier target)."""
comptime DEPLOY_PROVIDER_GCE_VM: Int = 6
"""A GCE VM."""
comptime DEPLOY_PROVIDER_LOCAL_COMPOSE: Int = 7
"""A single-box docker-compose target."""


# =============================================================================
# The IN-ENV RUNNER mechanism: WHICH one-shot runner an environment has for
# executing an authored `validate { run_container {} }` step inside the
# environment.
#
# This is a different question from `EnvBinding.is_cloud_compute_env()`, which
# answers REACHABILITY (can the operator's box reach the deployed service
# directly). Reachability is a property of the bundle's ingress, not of the
# cloud, so it is not answered here. This section answers only: does the
# environment have a one-shot in-env runner, and which concrete object backs it.
#
# It is a mechanism, not a place. The operator-facing WHERE (local versus
# in-env) is the release CLI's `--runner`; this is the WHICH underneath it. A
# caller that must CREATE the runner cannot act on the word "in-env".
# =============================================================================
comptime IN_ENV_RUNNER_NONE: Int = 0
"""This environment has no one-shot in-env runner: a `run_container` validate
step runs as a local subprocess on the operator's box. Correct for a hermetic,
emulator or single-box local environment, whose services the operator's box can
reach.

It is also what Azure and on-prem Kubernetes get today. That is a stated gap,
not a claim about those targets: both have a one-shot runner (Container Apps
Jobs; a Kubernetes `Job`), and neither has an arm here. Read NONE as "this
function knows of none". The refusal for a cloud with no arm at all belongs at
the arm dispatch, not here: two refusal sites for one fact teach a caller to
bypass the first one it hits."""
comptime IN_ENV_RUNNER_CLOUD_RUN_JOB: Int = 1
"""GCP: a Cloud Run JOB in the target project."""
comptime IN_ENV_RUNNER_ECS_FARGATE_TASK: Int = 2
"""AWS: a one-shot ECS Fargate `RunTask` in the target account."""


def in_env_runner_for_cloud(cloud: Int, account_ref: String) -> Int:
    """WHICH one-shot in-env runner an environment with this `(cloud,
    account_ref)` has, as an `IN_ENV_RUNNER_*` code. Pure, and total over the
    five `CLOUD_*` ordinals plus the proto zero.

    `account_ref` is load-bearing on both cloud arms: a cloud environment bound
    to no account or project has nothing to create a job IN, so it has no in-env
    runner however its `cloud` reads. (This is not a reachability test and must
    not be reused as one.)

    Every ordinal is enumerated rather than tested with `!= CLOUD_LOCAL`, so
    adding a cloud is an edit here instead of a silent inheritance of whichever
    arm the `else` happens to be.

    It does not raise. It is consulted to pick a DEFAULT for the runner on every
    validate of every environment, and a raise here would make an unbindable
    environment fail at the validate gate instead of at the arm dispatch that
    owns the refusal."""
    if account_ref.byte_length() == 0:
        return IN_ENV_RUNNER_NONE
    if cloud == CLOUD_GCP:
        return IN_ENV_RUNNER_CLOUD_RUN_JOB
    if cloud == CLOUD_AWS:
        return IN_ENV_RUNNER_ECS_FARGATE_TASK
    if cloud == CLOUD_AZURE:
        # Container Apps Jobs is the mechanism; there is no Azure arm to name.
        return IN_ENV_RUNNER_NONE
    if cloud == CLOUD_KUBERNETES:
        # A `batch/v1` Job in the namespace; there is no Kubernetes arm yet.
        return IN_ENV_RUNNER_NONE
    if cloud == CLOUD_LOCAL:
        # A local environment's services are reachable from the operator's box,
        # so the subprocess is the right answer, not a degraded substitute.
        return IN_ENV_RUNNER_NONE
    # CLOUD_UNSPECIFIED and any ordinal not added here. NONE is the fail-safe
    # direction: it keeps the operator on the arm that needs no cloud, and the
    # arm dispatch refuses the environment by name.
    return IN_ENV_RUNNER_NONE


def in_env_runner_is_bound(runner_kind: Int) -> Bool:
    """Whether the `IN_ENV_RUNNER_*` mechanism `runner_kind` has a validate-gate
    arm bound today, i.e. whether a `run_container` step routed in-env would have
    something to run on.

    This is an arm census, not a second model. "AWS validates on Fargate" and
    "the Fargate validate arm is written" are different facts, and one predicate
    answering both can only do so by making one of them false. Keeping them apart
    lets the runner default answer what is actually built.

    Adding a member is a behaviour change on every environment whose cloud
    selects that mechanism: the env-derived runner default reads this predicate,
    so a new True moves every `run_container` step on those environments off the
    local subprocess. Add a member only when a dispatch branch calls a builder
    for it. Azure and Kubernetes are absent because `in_env_runner_for_cloud`
    returns NONE for both."""
    return (
        runner_kind == IN_ENV_RUNNER_CLOUD_RUN_JOB
        or runner_kind == IN_ENV_RUNNER_ECS_FARGATE_TASK
    )


def in_env_runner_name(runner_kind: Int) -> StaticString:
    """A human-readable label for an `IN_ENV_RUNNER_*` code, for reports and
    refusal messages: an operator is told which OBJECT the gate would create,
    never a code."""
    if runner_kind == IN_ENV_RUNNER_CLOUD_RUN_JOB:
        return "Cloud Run JOB"
    if runner_kind == IN_ENV_RUNNER_ECS_FARGATE_TASK:
        return "ECS Fargate RunTask"
    return "none (local subprocess)"


# =============================================================================
# EnvBinding -- the resolved environment value the facade consumes.
# =============================================================================
struct EnvBinding(Copyable, Movable, Deinitable):
    """One symbol -> concrete-environment binding, resolved by the frontend from
    its registry and handed to the deploy facade:
      * `name`         -- the logical environment name, for reporting and the
                          governance-refusal message.
      * `cloud`        -- the coarse CLOUD_* posture.
      * `account_ref`  -- the account / project NAME (for reporting). Empty for
                          a purely local environment.
      * `region`       -- the deploy region NAME. Empty where the posture has
                          no region concept.
      * `direct_apply` -- the DIRECT_APPLY_* governance policy. `deploy_apply`
                          refuses a direct apply to a PIPELINE_ONLY environment.

    The remaining fields are read through accessors (raw storage is prefixed
    `_`): the LOCAL / CLOUD kind, the deploy provider, the datastore and object
    store bindings (a real resource for a cloud environment, or an emulator
    endpoint plus a plaintext flag for a local one), the build behaviour, the
    numeric project id, the release channel the environment aliases, and the
    stage it belongs to.

    Two constructors: a 5-argument one that fills every other field with cloud
    defaults, and a full one the environment registry maps a parsed row into."""

    var name: String
    var cloud: Int
    var account_ref: String
    var region: String
    var direct_apply: Int
    var _kind: Int
    var _deploy_provider: Int
    var _firestore_project: String
    var _firestore_emulator_endpoint: String
    var _firestore_insecure: Bool
    # The Firestore database holding this environment's deploy bookkeeping. ""
    # means "none" and is never silently promoted to a default.
    var _firestore_database: String
    var _gcs_bucket: String
    var _gcs_emulator_endpoint: String
    var _gcs_insecure: Bool
    var _build_in_pod: Bool
    var _project_number: String
    # The release channel this environment aliases; "" means none and is never
    # silently promoted to a default.
    var _release_channel: String
    # The stage (cross-cloud release ring) this environment belongs to; "" means
    # none. Many environments may share one stage.
    var _stage: String
    # The AWS arms of the datastore and object-store bindings. Empty means the
    # environment authored no such binding.
    var _dynamodb_table: String
    var _dynamodb_emulator_endpoint: String
    var _dynamodb_insecure: Bool
    var _s3_bucket: String
    var _s3_emulator_endpoint: String
    var _s3_insecure: Bool

    def __init__(
        out self,
        name: String,
        cloud: Int,
        account_ref: String,
        region: String,
        direct_apply: Int,
    ):
        """The 5-argument constructor. Every other field takes its cloud
        default: kind CLOUD, provider CLOUD_RUN, no emulator endpoints, local
        build."""
        self.name = name.copy()
        self.cloud = cloud
        self.account_ref = account_ref.copy()
        self.region = region.copy()
        self.direct_apply = direct_apply
        self._kind = ENVIRONMENT_KIND_CLOUD
        self._deploy_provider = DEPLOY_PROVIDER_CLOUD_RUN
        self._firestore_project = String("")
        self._firestore_emulator_endpoint = String("")
        self._firestore_insecure = False
        self._gcs_bucket = String("")
        self._gcs_emulator_endpoint = String("")
        self._gcs_insecure = False
        self._build_in_pod = False
        self._project_number = String("")
        self._release_channel = String("")
        self._stage = String("")
        self._firestore_database = String("")
        self._dynamodb_table = String("")
        self._dynamodb_emulator_endpoint = String("")
        self._dynamodb_insecure = False
        self._s3_bucket = String("")
        self._s3_emulator_endpoint = String("")
        self._s3_insecure = False

    def __init__(
        out self,
        name: String,
        cloud: Int,
        account_ref: String,
        region: String,
        direct_apply: Int,
        kind: Int,
        deploy_provider: Int,
        firestore_project: String,
        firestore_emulator_endpoint: String,
        firestore_insecure: Bool,
        gcs_bucket: String,
        gcs_emulator_endpoint: String,
        gcs_insecure: Bool,
        build_in_pod: Bool,
        project_number: String = String(""),
        release_channel: String = String(""),
        firestore_database: String = String(""),
        dynamodb_table: String = String(""),
        dynamodb_emulator_endpoint: String = String(""),
        dynamodb_insecure: Bool = False,
        s3_bucket: String = String(""),
        s3_emulator_endpoint: String = String(""),
        s3_insecure: Bool = False,
        stage: String = String(""),
    ):
        """The full constructor the environment registry maps a parsed row
        into."""
        self.name = name.copy()
        self.cloud = cloud
        self.account_ref = account_ref.copy()
        self.region = region.copy()
        self.direct_apply = direct_apply
        self._kind = kind
        self._deploy_provider = deploy_provider
        self._firestore_project = firestore_project.copy()
        self._firestore_emulator_endpoint = firestore_emulator_endpoint.copy()
        self._firestore_insecure = firestore_insecure
        self._gcs_bucket = gcs_bucket.copy()
        self._gcs_emulator_endpoint = gcs_emulator_endpoint.copy()
        self._gcs_insecure = gcs_insecure
        self._build_in_pod = build_in_pod
        self._project_number = project_number.copy()
        self._release_channel = release_channel.copy()
        self._stage = stage.copy()
        self._firestore_database = firestore_database.copy()
        self._dynamodb_table = dynamodb_table.copy()
        self._dynamodb_emulator_endpoint = dynamodb_emulator_endpoint.copy()
        self._dynamodb_insecure = dynamodb_insecure
        self._s3_bucket = s3_bucket.copy()
        self._s3_emulator_endpoint = s3_emulator_endpoint.copy()
        self._s3_insecure = s3_insecure

    def with_region(self, new_region: String) -> Self:
        """A copy of this binding with `region` replaced and every other field
        carried over unchanged."""
        return Self(
            self.name,
            self.cloud,
            self.account_ref,
            new_region,
            self.direct_apply,
            self._kind,
            self._deploy_provider,
            self._firestore_project,
            self._firestore_emulator_endpoint,
            self._firestore_insecure,
            self._gcs_bucket,
            self._gcs_emulator_endpoint,
            self._gcs_insecure,
            self._build_in_pod,
            self._project_number,
            self._release_channel,
            self._firestore_database,
            self._dynamodb_table,
            self._dynamodb_emulator_endpoint,
            self._dynamodb_insecure,
            self._s3_bucket,
            self._s3_emulator_endpoint,
            self._s3_insecure,
            self._stage,
        )

    def is_local(self) -> Bool:
        """True iff this is a LOCAL emulated environment. UNSPECIFIED and CLOUD
        both return False: an environment is not local unless explicit."""
        return self._kind == ENVIRONMENT_KIND_LOCAL

    def deploy_provider(self) -> Int:
        """The DEPLOY_PROVIDER_* ordinal: where the workload runs."""
        return self._deploy_provider

    def firestore_project(self) -> String:
        """The real Firestore project id (cloud environment); empty for a local
        environment, which carries `firestore_emulator_endpoint()` instead."""
        return self._firestore_project.copy()

    def firestore_database(self) -> String:
        """The raw Firestore database id holding this environment's deploy
        bookkeeping, or "" for none. Never promoted to a default here: a caller
        that needs one must decide what an empty value means for it."""
        return self._firestore_database.copy()

    def firestore_emulator_endpoint(self) -> String:
        """The Firestore emulator host:port (local environment); empty for a
        cloud environment."""
        return self._firestore_emulator_endpoint.copy()

    def firestore_insecure(self) -> Bool:
        """True iff the Firestore emulator is reached over plaintext."""
        return self._firestore_insecure

    def gcs_bucket(self) -> String:
        """The real GCS bucket (cloud environment); empty for a local
        environment, which carries `gcs_emulator_endpoint()` instead."""
        return self._gcs_bucket.copy()

    def gcs_emulator_endpoint(self) -> String:
        """The GCS emulator host:port (local environment); empty for a cloud
        environment."""
        return self._gcs_emulator_endpoint.copy()

    def gcs_insecure(self) -> Bool:
        """True iff the GCS emulator is reached over plaintext."""
        return self._gcs_insecure

    def dynamodb_table(self) -> String:
        """The DynamoDB table this environment's datastore binding names (cloud
        AWS environment), or "" when it authored none. Never defaulted."""
        return self._dynamodb_table.copy()

    def dynamodb_emulator_endpoint(self) -> String:
        """A DynamoDB Local host:port (local environment); empty for a cloud
        environment."""
        return self._dynamodb_emulator_endpoint.copy()

    def dynamodb_insecure(self) -> Bool:
        """True iff the DynamoDB emulator is reached over plaintext."""
        return self._dynamodb_insecure

    def s3_bucket(self) -> String:
        """The S3 bucket this environment's object-store binding names (cloud
        AWS environment), or "" when it authored none."""
        return self._s3_bucket.copy()

    def s3_emulator_endpoint(self) -> String:
        """An S3-compatible emulator host:port (local environment); empty for a
        cloud environment."""
        return self._s3_emulator_endpoint.copy()

    def s3_insecure(self) -> Bool:
        """True iff the S3 emulator is reached over plaintext."""
        return self._s3_insecure

    def tls_skip_verify(self) -> Bool:
        """The raw requested TLS skip-verify posture: True iff either GCP
        emulator binding asked for plaintext. A caller decides whether to honour
        it; for a cloud environment it is False and the peer certificate is
        verified against the public trust store."""
        return self._firestore_insecure or self._gcs_insecure

    def build_in_pod(self) -> Bool:
        """True iff `build` runs the in-pod build path for this environment;
        False selects the local build path."""
        return self._build_in_pod

    def project_number(self) -> String:
        """The numeric GCP project id, or "" when not authored. A grant keyed on
        a project's service agent is emitted only when this is non-empty."""
        return self._project_number.copy()

    def release_channel(self) -> String:
        """The raw release channel this environment aliases, or "" for none.
        Never promoted to a default: a defaulted channel would publish to a
        destination nobody chose."""
        return self._release_channel.copy()

    def stage(self) -> String:
        """The raw stage (cross-cloud release ring) this environment belongs
        to, or "" for none. Absent and empty are the same bytes on the wire, so
        this is never defaulted."""
        return self._stage.copy()

    def allows_direct_apply(self) -> Bool:
        """True iff a direct (non-pipeline) apply is permitted. UNSPECIFIED is
        treated as PIPELINE_ONLY (fail-safe). The single predicate
        `deploy_apply` branches on."""
        return self.direct_apply == DIRECT_APPLY_ALLOWED

    def is_cloud_compute_env(self) -> Bool:
        """True iff this is a GCP posture bound to a project: the operator's box
        reaches the deployed service through the cloud rather than directly.
        Answers reachability only; `in_env_runner()` answers which runner."""
        return self.cloud == CLOUD_GCP and self.account_ref.byte_length() > 0

    def in_env_runner(self) -> Int:
        """The `IN_ENV_RUNNER_*` mechanism for this environment
        (`in_env_runner_for_cloud` over its cloud and account)."""
        return in_env_runner_for_cloud(self.cloud, self.account_ref)

    def cloud_name(self) -> StaticString:
        """The lower-case name of the CLOUD_* posture, for reports."""
        if self.cloud == CLOUD_GCP:
            return "gcp"
        if self.cloud == CLOUD_AWS:
            return "aws"
        if self.cloud == CLOUD_AZURE:
            return "azure"
        if self.cloud == CLOUD_KUBERNETES:
            return "kubernetes"
        if self.cloud == CLOUD_LOCAL:
            return "local"
        return "unspecified"
