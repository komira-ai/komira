# =============================================================================
# kci_stage_graph -- the machine file: a release machine's stages and the
#   steps of each (format `kci.machine`).
# =============================================================================
#
#   graph.mojo  StageGraph, Stage, StageStep, StageValidation,
#               `validate_stage_graph`, and `resolve_selection` (`kci run
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

from kci_stage_graph.graph import (
    EXTRA_CHANNEL_CONDA_FORGE,
    NAME_MAX_BYTES,
    VALIDATION_TOOL_PIXI,
    Stage,
    StageGraph,
    StageStep,
    StageValidation,
    Selection,
    is_stage_or_step_name,
    joined_names,
    resolve_selection,
    validate_stage_graph,
)
from kci_stage_graph.parse import machine_field_names, machine_schema_version, parse_machine_file
