# =============================================================================
# kci_stage_graph -- the machine file: a release machine's stages and the
#   steps of each (format `kci.machine`).
# =============================================================================
#
#   graph.mojo  StageGraph, Stage, StageStep and `validate_stage_graph`
#   parse.mojo  `parse_machine_file`, `machine_schema_version`,
#               `machine_field_names`
#
# `kci run --stage S` runs the steps of stage S; kci_ci_check holds a CI
# workflow to the same graph. This package reads text it is given: it opens
# no file.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_stage_graph.graph import (
    NAME_MAX_BYTES,
    Stage,
    StageGraph,
    StageStep,
    is_stage_or_step_name,
    joined_names,
    validate_stage_graph,
)
from kci_stage_graph.parse import machine_field_names, machine_schema_version, parse_machine_file
