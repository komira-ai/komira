# =============================================================================
# komira_crm_store_conformance/targets.mojo -- what a backend supplies to be
#   checked.
# =============================================================================
#
# `fresh()` hands back an empty `Database` the store's tables can be written
# to: a SQL backend creates them (komira_crm.sqlite_schema); a document
# backend needs nothing created and is given no composite index (the store
# needs none). Every check calls `fresh()` itself, so no check sees another's
# rows. `transactional()` says whether a write's operations commit together
# there: the change feed and a stage change's atomicity are claimed only
# where they do.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import Database

comptime Rt = BlockingRuntime[NoopSink]


def new_rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


trait CrmTarget(Movable):
    """A source of fresh, empty databases for the CRM store."""

    comptime DB: Database

    def name(self) -> String:
        ...

    def transactional(self) -> Bool:
        ...

    def fresh(mut self) raises -> Self.DB:
        ...
