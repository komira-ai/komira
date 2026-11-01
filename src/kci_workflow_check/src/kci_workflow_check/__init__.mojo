# =============================================================================
# kci_workflow_check -- the workflow consistency check: a hand-written CI workflow
#   held to the machine file's release machine (library code; used by the welded
#   test and by `kci run` at start-up).
# =============================================================================
#
#   workflow_reader.mojo  `read_workflow`: a FAIL-CLOSED reader of a strict
#                         YAML subset (its header); anything else is
#                         "cannot tell", never a pass
#   rules.mojo            `check_workflow`: every disagreement (R1 to R12,
#                         R14 to R22), for the release workflow (kci.yml) or,
#                         with `pull_request_file`, the pull request's check
#                         (pr.yml, `check_pull_request_workflow`);
#                         `check_running_workflow`: the start-up check `kci
#                         run` makes; `id_token_stages`: which stages publish
#                         by OIDC; `kci_run_calls`
#   pull_request.mojo     R6: pr.yml's one job runs the PULL_REQUEST stage
#                         (same-repository pull requests only, `contents:
#                         read` and the farm connection's token); the
#                         release-only condition readers
#                         (`excludes_pull_request`);
#                         `condition_expression`: the expression GitHub
#                         evaluates for a job's `if:`
#   auto_promotion.mojo   R15 to R22: continuous auto-promotion (main-only
#                         stages, one concurrency group, the push filter,
#                         the manual run's inputs, the set hash handed on,
#                         the prod line, the revision checked by the
#                         workflow, a push never a dry run) and R4's
#                         permission allow-list;
#                         `documentation_filter_findings`: the push filter
#                         held to release_version.sh
#   kci_run_calls.mojo    `kci_run_calls`: every `kci run` of a script
#
# The machine file owns the release machine; the workflow is written by hand and
# checked against it. This package reads text it is given: it opens no file.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_workflow_check.workflow_reader import (
    CANNOT_TELL,
    NODE_LIST,
    NODE_MAP,
    NODE_SCALAR,
    WorkflowDoc,
    WorkflowNode,
    read_workflow,
)
from kci_workflow_check.pull_request import (
    CHANGE_BASE_LINE,
    CHANGE_BASE_VARIABLE,
    CHECKOUT_ACTION,
    EVENT_BASE_EXPRESSION,
    PULL_REQUEST_EVENT,
    PULL_REQUEST_RUNNER,
    SAME_REPOSITORY_CONDITION,
    condition_expression,
    excludes_pull_request,
)
from kci_workflow_check.auto_promotion import (
    CHECKOUT_REF,
    CONCURRENCY_CANCEL,
    CONCURRENCY_GROUP,
    MAIN_ONLY_STEP,
    MAIN_ONLY_STEP_RUN,
    MAIN_REF_TERM,
    PROD_LINE_STEP,
    PUSH_EVENT_TERM,
    REVISION_STEP,
    REVISION_STEP_RUN,
    break_glass_environment_expression,
    documentation_filter_findings,
    documentation_paths,
)
from kci_workflow_check.kci_run_calls import KciRunCall, kci_run_calls
from kci_workflow_check.rules import (
    FARM_CONNECT_ACTION,
    ChannelsFile,
    channels_paths,
    check_running_workflow,
    check_pull_request_workflow,
    check_workflow,
    check_workflow_doc,
    id_token_stages,
)
