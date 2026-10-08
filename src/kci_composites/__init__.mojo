"""`kci_composites`: the composite definitions kci ships, `kci.job` and
`kci.app`, as data files (`definitions/*.json`), and the reader that loads
them the way any author's definition is loaded.

Modules:
  * definitions.mojo — `kci_definition_files` (the files, by resource name)
                       and `read_kci_definitions` (each read through
                       `komira_resources` and decoded strictly).
"""

from .definitions import (
    KCI_DEFINITIONS_DIR,
    kci_definition_files,
    read_kci_definitions,
)
