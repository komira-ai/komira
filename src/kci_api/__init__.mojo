# =============================================================================
# kci_api -- the one place that states every number, word and name kci
#   owns: exit codes, outcomes, error ids, document formats and their schema
#   majors, produced file names, the release layout, the platform table, the
#   run identity flags, revision ids, verbs, and the result document.
# =============================================================================
#
#   authored.mojo      schema_version of an authored textproto file
#   outcome.mojo       the outcome and retry vocabularies
#   exit_codes.mojo    THE exit table
#   errors.mojo        stable error ids
#   formats.mojo       the format table and the version policy
#   run_identity.mojo  --run-id / --attempt / --context
#   revision.mojo      full commit ids, ArtifactRef(revision, platform, name)
#   platform.mojo      the platform table (conda subdirs, released or
#                      reserved; the OCI os/arch spelling)
#   layout.mojo        produced file names, the release directory layout,
#                      the default machine file
#   selection.mojo     `--only step:|validation:` selectors, step names, the
#                      FULL / SELECTIVE scope of a run
#   verbs.mojo         the one verb (`run`), step kinds, validation kinds
#   result.mojo        the result document, RunRecorder, MemoryRecorder
#   result_rows.mojo   its rows (steps, artifacts, validations, new names)
#   result_deploy.mojo the deploy keys of a step row (cell, landed, ...)
#   result_json.mojo   the JSON helpers its renderer and parser share
#
# Pure: no file I/O, no clock, no environment, no process.
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_api.authored import authored_schema_version, skip_schema_version
from kci_api.errors import (
    ERROR_BUILD_FAILED,
    ERROR_CANNOT_TELL,
    ERROR_CHANNEL,
    ERROR_CREDENTIAL,
    ERROR_ARTIFACT,
    ERROR_FORMAT,
    ERROR_FORMAT_VERSION,
    ERROR_IMAGE_PLATFORM,
    ERROR_IMAGE_PUSH,
    ERROR_INTERNAL,
    ERROR_MEMBER,
    ERROR_PLATFORM,
    ERROR_PLATFORM_MISMATCH,
    ERROR_PUBLISH_DIFFERENT_BYTES,
    ERROR_PUBLISH_READ_BACK,
    ERROR_PUBLISH_UPLOAD,
    ERROR_RESULT_FILE,
    ERROR_REVISION,
    ERROR_REVISION_MISMATCH,
    ERROR_SELECTOR,
    ERROR_SELECTOR_NO_MATCH,
    ERROR_SET_HASH,
    ERROR_STAGE_ENVIRONMENT,
    ERROR_STAGE_UNKNOWN,
    ERROR_USAGE,
    ERROR_VALIDATION,
    ERROR_AFFECTED,
    ERROR_AFFECTED_VACUOUS,
    ERROR_BREAK_GLASS_REASON,
    ERROR_BREAK_GLASS_REVISION,
    ERROR_PLAN_ON_RELEASE,
    ERROR_NOT_ON_MAIN,
    ERROR_SUPERSEDED,
    ERROR_WORKFLOW_MISMATCH,
    ErrorRow,
    error_table,
    is_error_id,
    is_error_id_well_formed,
    require_error_id,
)
from kci_api.exit_codes import (
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_INTERNAL,
    EXIT_LEFT_BEHIND,
    EXIT_OK,
    EXIT_PARTIAL,
    EXIT_REFUSED,
    EXIT_USAGE,
    EXIT_VALIDATION_FAILED,
    ExitRow,
    default_retry,
    exit_code_of,
    exit_table,
    promises_no_effect,
    require_retry_for,
)
from kci_api.formats import (
    FORMAT_ARTIFACTS,
    FORMAT_ARTIFACT_MANIFEST,
    FORMAT_CELLS,
    FORMAT_CHANNELS,
    FORMAT_CONDA_METADATA,
    FORMAT_KEY,
    FORMAT_MACHINE,
    FORMAT_RELEASE_SET,
    FORMAT_RESULT,
    KIND_AUTHORED,
    KIND_PRODUCED,
    SCHEMA_VERSION_KEY,
    FormatRow,
    check_authored_version,
    check_produced_version,
    current_major,
    format_row,
    format_table,
    produced_header,
    unknown_keys,
)
from kci_api.layout import (
    ARTIFACT_MANIFEST_NAME,
    DEFAULT_MACHINE_FILE,
    RELEASE_MANIFEST_NAME,
    member_dir,
    release_manifest_path,
    release_platform_dir,
)
from kci_api.outcome import (
    OUTCOME_CANCELLED,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_INTERRUPTED,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    OUTCOME_SUPERSEDED,
    OUTCOME_VALIDATION_FAILED,
    RETRY_NEEDS_HUMAN,
    RETRY_SAFE,
    RETRY_UNSAFE,
    all_outcomes,
    all_retries,
    is_outcome,
    outcome_rank,
    require_outcome,
    require_retry,
    worst_outcome,
)
from kci_api.platform import (
    PLATFORM_DARWIN_ARM64,
    PLATFORM_LINUX_ARM64,
    PLATFORM_LINUX_X86_64,
    PLATFORM_NOARCH,
    PlatformRow,
    conda_subdir_of,
    oci_platform_of,
    platform_of_conda_subdir,
    platform_of_oci,
    platform_row,
    platform_table,
    require_artifact_platform,
    require_member_platform,
    require_release_platform,
)
from kci_api.result import (
    KCI_VERSION,
    STATUS_FINISHED,
    STATUS_RUNNING,
    MemoryRecorder,
    RunRecorder,
    RunResult,
    parse_result,
    render_result,
)
from kci_api.result_deploy import (
    ResultDeploy,
    ResultFailedNode,
    ResultLanded,
    ResultOutput,
    deploy_step_keys,
)
from kci_api.result_rows import (
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_BUILT,
    ARTIFACT_NOT_REACHED,
    ARTIFACT_UPLOADED,
    ARTIFACT_WOULD_BUILD,
    ARTIFACT_WOULD_UPLOAD,
    CREDENTIAL_PROBE_MINTED,
    CREDENTIAL_PROBE_NOT_OIDC,
    CREDENTIAL_PROBE_NOT_UNDER_CI,
    CREDENTIAL_PROBE_NOT_RUN_NOTE,
    credential_probe_note,
    VALIDATION_ENVIRONMENT_CONTAINER,
    VALIDATION_ENVIRONMENT_ENV,
    VALIDATION_NOT_REACHED,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    WORKFLOW_NOT_REACHED,
    WORKFLOW_PATH_PREFIX,
    ResultArtifact,
    ResultError,
    ResultNewName,
    ResultStep,
    ResultValidation,
    ResultValidationCheck,
    all_artifact_effects,
    all_credential_probes,
    all_validation_effects,
    reserved_result_keys,
)
from kci_api.revision import ArtifactRef, is_full_commit_id, require_full_commit_id
from kci_api.run_identity import (
    CONTEXT_KEY_MAX_BYTES,
    CONTEXT_MAX_ENTRIES,
    CONTEXT_VALUE_MAX_BYTES,
    RUN_ID_MAX_BYTES,
    ContextEntry,
    RunIdentity,
    parse_attempt,
    parse_context_arg,
    require_attempt,
    require_context_key,
    require_context_value,
    require_run_id,
)
from kci_api.selection import (
    AFFECTED_VERDICT_AFFECTED,
    AFFECTED_VERDICT_WIDENED,
    SCOPE_FULL,
    SCOPE_SELECTIVE,
    SELECTOR_STEP,
    SELECTOR_VALIDATION,
    STEP_NAME_MAX_BYTES,
    Selector,
    is_step_name,
    parse_selector,
    parse_selectors,
    require_scope,
    run_evidence_line,
    scope_of,
)
from kci_api.verbs import (
    STEP_KIND_BUILD,
    STEP_KIND_DEPLOY,
    STEP_KIND_PUBLISH,
    VALIDATION_KIND_CONDA_INSTALL_ENV,
    VALIDATION_KIND_CONDA_INSTALL_SMOKE,
    VALIDATION_KIND_DEPLOY_PROBE,
    VERB_RUN,
    all_step_kinds,
    all_validation_kinds,
    all_verbs,
    require_step_kind,
    require_validation_kind,
    require_verb,
)
