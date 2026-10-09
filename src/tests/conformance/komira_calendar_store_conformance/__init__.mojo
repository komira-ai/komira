"""Test-only: komira_calendar_store's contract, generic over the backend.

  targets.mojo  CalendarTarget: what a backend supplies; the runtime and
                fixtures the checks share
  checks.mojo   the checks, each written once for every backend
  suite.mojo    run_calendar_suite: every check, then one verdict
"""

from .targets import CalendarTarget, Rt, new_rt, zones
from .suite import run_calendar_suite
