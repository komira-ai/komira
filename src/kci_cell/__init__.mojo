# =============================================================================
# kci_cell -- the cells file (format `kci.cells`).
# =============================================================================
#
# A cell is one closed world: one cloud, one place, owned by one machine. A
# DEPLOY step will name the cells file and pick one cell from it, the way a
# PUBLISH step names a channels file and picks one channel (that wiring is not
# built yet; kci_release_machine still refuses a DEPLOY step).
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
