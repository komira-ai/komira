# =============================================================================
# komira_chat_store_conformance/targets.mojo -- what a backend supplies to be
#   checked, and the runtime and helpers the checks share.
# =============================================================================
#
# A backend under test supplies a `ChatTarget`: `fresh()` hands back a new,
# empty chat database with the chat schema ready (a SQL backend runs
# `chat_migrations()` and `prepare_sql_connection`; a document store declares
# `CHAT_DOCUMENT_KEYS` and `CHAT_DOCUMENT_INDEXES`), and `second()` hands back
# another connection to the database `fresh()` last made. Writes through one
# are visible through the other at once, as two server processes sharing one
# database see each other's commits.
#
# Every check calls `fresh()` itself, so no check sees another's rows. Each
# check runs on a `BlockingRuntime[NoopSink]` of its own.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import Database

from komira_chat_store import ChatEvent, EventPage

comptime Rt = BlockingRuntime[NoopSink]

# A fixed clock: every check writes these times.
comptime T0: Int64 = 1790000000000


def new_rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


trait ChatTarget(Movable):
    comptime DB: Database

    def name(self) -> String:
        ...

    def fresh(mut self) raises -> Self.DB:
        """A new, empty chat database, ready for a ChatStore."""
        ...

    def second(mut self) raises -> Self.DB:
        """Another connection to the database `fresh()` last returned."""
        ...


def ids(*xs: StaticString) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def no_ids() -> List[String]:
    return List[String]()


def seqs_of(evs: List[ChatEvent]) -> String:
    """The events' seqs as `[1,2,3]`."""
    var out = String("[")
    for i in range(len(evs)):
        if i > 0:
            out += String(",")
        out += String(evs[i].seq)
    out += String("]")
    return out^


def bodies_of(evs: List[ChatEvent]) -> String:
    """The events' bodies as `[a|b|c]`."""
    var out = String("[")
    for i in range(len(evs)):
        if i > 0:
            out += String("|")
        out += evs[i].body
    out += String("]")
    return out^


def joined(xs: List[String]) -> String:
    var out = String("[")
    for i in range(len(xs)):
        if i > 0:
            out += String(",")
        out += xs[i]
    out += String("]")
    return out^


def assert_contiguous(page: EventPage, what: String) raises:
    """`page` is the whole timeline: seqs 1..head, each once, in order."""
    for i in range(len(page.events)):
        if page.events[i].seq != Int64(i + 1):
            raise Error(
                what
                + String(": the timeline is not 1..n with no gap: ")
                + seqs_of(page.events)
            )
    assert_equal(
        Int64(len(page.events)), page.head_seq, what + String(": head_seq")
    )


def assert_err(got: String, want: String, what: String) raises:
    """`got` is the text a call raised, exactly `want`."""
    assert_equal(got, want, what)


def returned() -> String:
    return String("<the call returned instead of raising>")
