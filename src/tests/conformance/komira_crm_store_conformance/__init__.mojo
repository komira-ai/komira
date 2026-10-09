# =============================================================================
# komira_crm_store_conformance -- komira_crm's store, checked once against
#   every komira_db backend that runs in a build action.
# =============================================================================
#
#   targets.mojo   CrmTarget: a backend's factory of fresh databases
#   checks.mojo    the checks, generic over the target
#   suite.mojo     run_crm_suite: every check, one verdict naming each
#                  failure
# =============================================================================

from .targets import CrmTarget, Rt, new_rt
from .suite import run_crm_suite
