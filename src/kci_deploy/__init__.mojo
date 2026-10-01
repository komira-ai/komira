"""`kci_deploy` -- the DEPLOY LIBRARY.

The one library boundary all deploy mechanics live behind. It wraps the
provider-neutral `kci_iac` reconcile engine (plan_graph / apply_graph /
destroy_graph) with the two frontend-terminated seams -- a CREDS provider and a
REPORTER -- plus the environment-governance gate, over a neutral `EnvBinding`
value. Every frontend (a CLI, a managed deployer) binds over this same library;
the only forks are the creds conformer and the reporter, both chosen at the
binary's main.

Modules:
  * env_binding.mojo          -- `EnvBinding` (the resolved environment the
                                 facade consumes; proto-free) and the CLOUD_* /
                                 DIRECT_APPLY_* / ENVIRONMENT_KIND_* /
                                 DEPLOY_PROVIDER_* / IN_ENV_RUNNER_* codes.
  * creds_provider.mojo       -- the `CredsProvider` seam,
                                 `StaticTokenCredsProvider` (tests) and
                                 `AmbientCredsProvider` (self-deploy).
  * reporter.mojo             -- the `Reporter` seam and `StdoutReporter` /
                                 `JsonLinesReporter` / `CaptureReporter`.
  * deploy.mojo               -- the facade: `deploy_plan` / `deploy_apply` /
                                 `deploy_destroy` / `deploy_rollback` /
                                 `deploy_status` and their outcomes.
  * data_plane_readiness.mojo -- the wait for an API edge's data plane to stop
                                 refusing requests after an IAM grant.
  * validate.mojo             -- the deploy-and-validate loop:
                                 `poll_until_converged`, the `Validator` /
                                 `DagValidator` seams, `run_validation_gate`
                                 and the parallel `run_validation_dag`.
  * deploy_fault.mojo         -- the deploy-fault raise protocol (PERMANENT /
                                 IN-FLIGHT markers) shared by raisers and the
                                 reconciler; import it as
                                 `kci_deploy.deploy_fault`.

The library depends only on `kci_iac` (and `komira_core` through it) and
`kci_logs` (the run-log tail a failing validate step prints). It names no
cloud SDK, no transport and no proto: a frontend maps its own environment row
into an `EnvBinding` at the door.
"""

from kci_deploy.env_binding import (
    EnvBinding,
    CLOUD_UNSPECIFIED,
    CLOUD_GCP,
    CLOUD_AWS,
    CLOUD_AZURE,
    CLOUD_KUBERNETES,
    CLOUD_LOCAL,
    DIRECT_APPLY_UNSPECIFIED,
    DIRECT_APPLY_ALLOWED,
    DIRECT_APPLY_PIPELINE_ONLY,
    ENVIRONMENT_KIND_UNSPECIFIED,
    ENVIRONMENT_KIND_CLOUD,
    ENVIRONMENT_KIND_LOCAL,
    DEPLOY_PROVIDER_UNSPECIFIED,
    DEPLOY_PROVIDER_CLOUD_RUN,
    DEPLOY_PROVIDER_LAMBDA,
    DEPLOY_PROVIDER_FUNCTIONS,
    DEPLOY_PROVIDER_ECS,
    DEPLOY_PROVIDER_K8S,
    DEPLOY_PROVIDER_GCE_VM,
    DEPLOY_PROVIDER_LOCAL_COMPOSE,
    IN_ENV_RUNNER_NONE,
    IN_ENV_RUNNER_CLOUD_RUN_JOB,
    IN_ENV_RUNNER_ECS_FARGATE_TASK,
    in_env_runner_for_cloud,
    in_env_runner_is_bound,
    in_env_runner_name,
)
from kci_deploy.creds_provider import (
    CredsProvider,
    StaticTokenCredsProvider,
    AmbientCredsProvider,
)
from kci_deploy.reporter import (
    Reporter,
    StdoutReporter,
    JsonLinesReporter,
    CaptureReporter,
    verb_label,
)
from kci_deploy.deploy import (
    DeployPlanOutcome,
    DeployApplyOutcome,
    DeployDestroyOutcome,
    deploy_plan,
    deploy_apply,
    deploy_destroy,
    partial_apply_report,
    deploy_rollback,
    DeploymentStatus,
    deploy_status,
    DEPLOY_STATUS_CONVERGING,
    DEPLOY_STATUS_HEALTHY,
    DEPLOY_STATUS_FAILED,
    DEPLOY_STATUS_NOTFOUND,
    ApplyOutcome,
    APPLY_CREATED,
    APPLY_UPDATED,
    APPLY_NOOP,
)
from kci_deploy.data_plane_readiness import (
    DataPlaneProbe,
    DataPlaneReadiness,
    await_data_plane_ready,
    edge_readiness_probe_url,
    is_invoker_refusal,
    is_data_plane_ready,
    DATA_PLANE_UNREACHABLE,
    HTTP_FORBIDDEN,
    EDGE_READINESS_PATH,
)
from kci_deploy.validate import (
    Validator,
    ValidationOutcome,
    ConvergeOutcome,
    PollBudget,
    ScriptedValidator,
    parse_verdict,
    verdict_label,
    render_validator_output_tail,
    render_validator_output_elsewhere,
    render_validator_output_read_by_the_tool,
    DEFAULT_MAX_OUTPUT_LINES,
    DEFAULT_MAX_OUTPUT_LINE_BYTES,
    poll_until_converged,
    run_validation_gate,
    run_all_validation_gates,
    VALIDATION_PASS,
    VALIDATION_FAIL,
    VALIDATION_INDETERMINATE,
    DagValidator,
    derived_step_poll_attempts,
    IDENTICAL_OUTCOME_LIMIT,
    IDENTICAL_OUTCOME_MIN_WALL_S,
    derived_identical_outcome_rounds,
    identical_outcome_stop_is_due,
    run_validation_dag,
    step_teardown_reason,
    TEARDOWN_PATH_SCHEDULER_FAULT,
    TEARDOWN_PATH_WAVE_COMPLETED,
    StepResult,
    DagOutcome,
    STEP_PASS,
    STEP_FAIL,
    STEP_SKIPPED,
    step_status_label,
    DagEventLog,
    ScriptedDagValidator,
)
