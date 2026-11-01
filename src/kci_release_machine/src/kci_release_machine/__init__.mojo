# =============================================================================
# kci_release_machine -- the machine file: a release machine's stages and the
#   steps of each (format `kci.machine`).
# =============================================================================
#
#   graph.mojo  ReleaseMachine, Stage, StageStep, StageValidation,
#               `validate_release_machine`, and `resolve_selection` (`kci run
#               --only` against one stage)
#   deploy.mojo the rules of a step that writes into a cell (a DEPLOY
#               step, or a PUBLISH step into a cell): `validate_cell_steps`,
#               `require_cells_declared`, `cells_files_named`
#   probe.mojo  the fields of a DEPLOY_PROBE validation: `check_probe`,
#               `has_probe`, `is_probe_case_id`
#   parse.mojo  `parse_machine_file`, `machine_schema_version`,
#               `machine_field_names`
#
# `kci run --stage S` runs the steps of stage S and their validations; the
# workflow consistency check (kci_workflow_check) holds a CI workflow to the same
# graph. This package reads text it is given: it opens
# no file.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_release_machine.graph import (
    EXTRA_CHANNEL_CONDA_FORGE,
    NAME_MAX_BYTES,
    STAGE_TRIGGER_PULL_REQUEST,
    STAGE_TRIGGER_PUSH,
    VALIDATION_PROGRAM_DIR,
    VALIDATION_WAIT_DEFAULT_SECONDS,
    VALIDATION_WAIT_MAX_SECONDS,
    ReleaseMachine,
    Stage,
    StageStep,
    StageValidation,
    Selection,
    is_digest_pinned_image,
    is_stage_or_step_name,
    joined_names,
    probe_only_fields,
    resolve_selection,
    validate_release_machine,
)
from kci_release_machine.deploy import (
    PROMOTED_DEPLOY_REFUSAL,
    cells_files_named,
    is_relative_data_path,
    require_cells_declared,
    validate_cell_steps,
)
from kci_release_machine.probe import (
    PROBE_ARG_RUN_ID,
    PROBE_ARG_TARGET_URL,
    PROBE_TIMEOUT_MAX_SECONDS,
    check_probe,
    has_probe,
    is_probe_case_id,
)
from kci_release_machine.parse import machine_field_names, machine_schema_version, parse_machine_file
