# =============================================================================
# kci_cell -- the cells file (format `kci.cells`).
# =============================================================================
#
# A cell is one closed world: one cloud, one place, owned by one machine. A
# DEPLOY step, or a PUBLISH step into a cell, names the cells file and picks
# one cell from it, the way a PUBLISH step names a channels file and picks one
# channel (kci_release_machine parses those steps; kci run does not run them
# yet).
# `cell.mojo` holds the types and the lookups; `parse.mojo` reads and checks
# a cells file with `parse_cells_file`.
#
# Deps: the textproto lexer and kci_api only, never kci_cloud: whether a
# cell's cloud is built in, and what its settings mean, is checked where the
# step runs.
# =============================================================================

from kci_cell.cell import (
    BOOTSTRAP_LEVEL_V1,
    Cell,
    CellSetting,
    cell_names,
    find_cell,
)
from kci_cell.parse import parse_cells_file
