# =============================================================================
# kci_contract -- the one place that states every number, word and name kci
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
#   platform.mojo      the platform table (conda subdirs, released or reserved)
#   layout.mojo        produced file names, the release directory layout
#   verbs.mojo         verbs and action kinds
#   result.mojo        the result document, RunRecorder, MemoryRecorder
#
# Pure: no file I/O, no clock, no environment, no process.
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_contract.authored import authored_schema_version, skip_schema_version
from kci_contract.errors import (
    ERROR_BUILD_FAILED,
    ERROR_CANNOT_TELL,
    ERROR_CHANNEL,
    ERROR_CREDENTIAL,
    ERROR_DECLARATION,
    ERROR_FORMAT,
    ERROR_FORMAT_VERSION,
    ERROR_INTERNAL,
    ERROR_MEMBER,
    ERROR_PLATFORM,
    ERROR_PLATFORM_MISMATCH,
    ERROR_PUBLISH_DIFFERENT_BYTES,
    ERROR_PUBLISH_NEW_NAME,
    ERROR_PUBLISH_READ_BACK,
    ERROR_PUBLISH_UPLOAD,
    ERROR_RESULT_FILE,
    ERROR_REVISION,
    ERROR_REVISION_MISMATCH,
    ERROR_SET_HASH,
    ERROR_STAGE_ENVIRONMENT,
    ERROR_STAGE_KIND,
    ERROR_STAGE_UNKNOWN,
    ERROR_USAGE,
    ErrorRow,
    error_table,
    is_error_id,
    is_error_id_well_formed,
    require_error_id,
)
from kci_contract.exit_codes import (
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
    require_retry_for,
)
from kci_contract.formats import (
    FORMAT_ARTIFACT_DECLARATIONS,
    FORMAT_ARTIFACT_MANIFEST,
    FORMAT_CHANNELS,
    FORMAT_CONDA_METADATA,
    FORMAT_KEY,
    FORMAT_MACHINE,
    FORMAT_RELEASE_SET,
    FORMAT_RESULT,
    FORMAT_STAGES,
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
from kci_contract.layout import (
    ARTIFACT_MANIFEST_NAME,
    RELEASE_MANIFEST_NAME,
    member_dir,
    release_manifest_path,
    release_platform_dir,
)
from kci_contract.outcome import (
    OUTCOME_CANCELLED,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_INTERRUPTED,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
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
from kci_contract.platform import (
    PLATFORM_DARWIN_ARM64,
    PLATFORM_LINUX_ARM64,
    PLATFORM_LINUX_X86_64,
    PLATFORM_NOARCH,
    PlatformRow,
    conda_subdir_of,
    platform_of_conda_subdir,
    platform_row,
    platform_table,
    require_artifact_platform,
    require_member_platform,
    require_release_platform,
)
from kci_contract.result import (
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_BUILT,
    ARTIFACT_NOT_REACHED,
    ARTIFACT_UPLOADED,
    ARTIFACT_WOULD_UPLOAD,
    KCI_VERSION,
    STATUS_FINISHED,
    STATUS_RUNNING,
    MemoryRecorder,
    ResultAction,
    ResultArtifact,
    ResultError,
    RunRecorder,
    RunResult,
    all_artifact_actions,
    parse_result,
    render_result,
    reserved_result_keys,
)
from kci_contract.revision import ArtifactRef, is_full_commit_id, require_full_commit_id
from kci_contract.run_identity import (
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
from kci_contract.verbs import (
    ACTION_BUILD,
    ACTION_DEPLOY,
    ACTION_PUBLISH,
    VERB_BUILD,
    VERB_CI_CHECK,
    VERB_PUBLISH,
    VERB_RUN,
    VERB_STAGES,
    alias_action_kind,
    all_action_kinds,
    all_verbs,
    require_action_kind,
    require_verb,
)
