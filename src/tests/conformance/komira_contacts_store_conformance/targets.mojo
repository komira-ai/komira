# =============================================================================
# komira_contacts_store_conformance/targets.mojo -- what a backend supplies to
#   be checked.
# =============================================================================
#
# `fresh()` hands back an empty `Database` the store's tables can be written
# to: a SQL backend creates them (contacts.sqlite_schema), a document
# backend declares the composite index the store needs
# (contacts.composite_indexes). Every check calls `fresh()` itself, so
# no check sees another's rows.
# =============================================================================

from async_rt.ops.waker_sink import NoopSink
from async_rt.runtime.blocking_runtime import BlockingRuntime

from db import Database

comptime Rt = BlockingRuntime[NoopSink]


def new_rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


trait ContactsTarget(Movable):
    """A source of fresh, empty databases for the contacts store."""

    comptime DB: Database

    def name(self) -> String:
        ...

    def fresh(mut self) raises -> Self.DB:
        ...
