# =============================================================================
# komira_contacts_store_conformance -- contacts' store, checked once
#   against every db backend that runs in a build action.
# =============================================================================
#
#   targets.mojo   ContactsTarget: a backend's factory of fresh databases
#   checks.mojo    the checks, generic over the target
#   suite.mojo     run_contacts_suite: every check, one verdict naming each
#                  failure
# =============================================================================

from .targets import ContactsTarget, Rt, new_rt
from .suite import run_contacts_suite
