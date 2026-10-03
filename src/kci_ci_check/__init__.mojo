# =============================================================================
# kci_ci_check -- `kci ci check`: a hand-written CI workflow held to the
#   machine file's stage graph.
# =============================================================================
#
#   workflow_reader.mojo  `read_workflow`: a RESTRICTED reader of the YAML
#                         subset a workflow uses; anything else is "cannot
#                         tell", never a pass
#   rules.mojo            `check_workflow`: every disagreement (R1 to R10);
#                         `id_token_stages`: which stages need a CI identity
#                         token; `kci_run_calls`
#
# The machine file owns the stage graph; the workflow is written by hand and
# checked against it. This package reads text it is given: it opens no file.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_ci_check.workflow_reader import (
    CANNOT_TELL,
    NODE_LIST,
    NODE_MAP,
    NODE_SCALAR,
    WorkflowDoc,
    WorkflowNode,
    read_workflow,
)
from kci_ci_check.rules import (
    ChannelsFile,
    KciRunCall,
    channels_paths,
    check_workflow,
    check_workflow_doc,
    id_token_stages,
    kci_run_calls,
)
