# =============================================================================
# kci_ci_check -- the workflow consistency check: a hand-written CI workflow
#   held to the machine file's release machine (library code; used by the welded
#   test and by `kci run` at start-up).
# =============================================================================
#
#   workflow_reader.mojo  `read_workflow`: a RESTRICTED reader of the YAML
#                         subset a workflow uses; anything else is "cannot
#                         tell", never a pass
#   rules.mojo            `check_workflow`: every disagreement (R1 to R12;
#                         R6 holds a pull request workflow to the
#                         PULL_REQUEST stages);
#                         `check_running_workflow`: the start-up check `kci
#                         run` makes; `id_token_stages`: which stages publish
#                         by OIDC; `kci_run_calls`; `condition_expression`:
#                         the expression GitHub evaluates for a job's `if:`
#
# The machine file owns the release machine; the workflow is written by hand and
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
    CHECKOUT_ACTION,
    FARM_CONNECT_ACTION,
    PULL_REQUEST_BASE_EXPRESSION,
    SAME_REPOSITORY_CONDITION,
    ChannelsFile,
    KciRunCall,
    channels_paths,
    check_running_workflow,
    check_workflow,
    check_workflow_doc,
    condition_expression,
    id_token_stages,
    kci_run_calls,
)
