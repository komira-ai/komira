# =============================================================================
# komira_calendar_store_conformance/targets.mojo -- what a backend supplies to
#   be checked, and what the checks share.
# =============================================================================
#
# `fresh()` hands back a new, empty calendar database (a SQL backend applies
# `calendar_migrations()`; a document store declares
# CALENDAR_DOCUMENT_INDEXES). `reopen()` hands back another connection to the
# database `fresh()` last made: what a restarted server process opens. Every
# check calls `fresh()` itself, so no check sees another's rows; each runs on
# a `BlockingRuntime[NoopSink]` of its own.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_calendar_ics import ZoneTable
from komira_datetime import posix_zone
from komira_db import Database

comptime Rt = BlockingRuntime[NoopSink]

# A fixed clock: every check writes these times.
comptime T0: Int64 = 1790000000000


def new_rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


def zones() raises -> ZoneTable:
    """America/New_York from its POSIX rule (EST5EDT), so no zone data is
    read."""
    var z = ZoneTable()
    z.add(posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0"))
    return z^


trait CalendarTarget(Movable):
    comptime DB: Database

    def name(self) -> String:
        ...

    def fresh(mut self) raises -> Self.DB:
        """A new, empty calendar database."""
        ...

    def reopen(mut self) raises -> Self.DB:
        """Another connection to the database `fresh()` last returned."""
        ...
