# =============================================================================
# kci_release_machine -- the machine file: a release machine's stages and the
#   steps of each (format `kci.machine`).
# =============================================================================
#
#   graph.mojo  ReleaseMachine, Stage, StageStep, StageValidation,
#               `validate_release_machine`, and `resolve_selection` (`kci run
#               --only` against one stage)
#   parse.mojo  `parse_machine_file`, `machine_schema_version`,
#               `machine_field_names`
#
# `kci run --stage S` runs the steps of stage S and their validations; the
# workflow consistency check (kci_ci_check) holds a CI workflow to the same
# graph. This package reads text it is given: it opens
# no file.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_release_machine.graph import (
    EXTRA_CHANNEL_CONDA_FORGE,
    NAME_MAX_BYTES,
    VALIDATION_PROGRAM_DIR,
    VALIDATION_WAIT_MAX_SECONDS,
    ReleaseMachine,
    Stage,
    StageStep,
    StageValidation,
    Selection,
    is_digest_pinned_image,
    is_manual_gate_name,
    is_stage_or_step_name,
    joined_names,
    resolve_selection,
    validate_release_machine,
)
from kci_release_machine.parse import machine_field_names, machine_schema_version, parse_machine_file
