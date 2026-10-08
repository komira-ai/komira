# =============================================================================
# komira_chat_store_conformance/probes.mojo -- SendProbes that act inside a
#   send, between its read of the channel's head and its insert.
# =============================================================================
#
#   InterleaveProbe  once armed, on the next attempt it sends a message
#                    through a second store (a second connection to the same
#                    database) to completion, then reads the channel after
#                    the seq the outer send is about to take minus one, as a
#                    client paging from its cursor would, and keeps what it
#                    saw.
#   CrashProbe       once armed, raises on the next attempt, standing for a
#                    process that dies before its insert.
# =============================================================================

from komira_db import Database

from komira_chat_store import ChatEvent, ChatStore, NoSendProbe, SendProbe

from .targets import Rt, T0, new_rt, no_ids

comptime INTERLEAVED_BODY: StaticString = "sent by the second connection"
comptime CRASH_TEXT: StaticString = "injected crash before the insert"


struct InterleaveProbe[DB: Database](SendProbe):
    var other: Optional[ChatStore[Self.DB, NoSendProbe]]
    var armed: Bool
    var channel_id: String
    var sender_user_id: String
    # Set when it fires: the seq its own message took, and the events the
    # reader saw after `seq - 1`.
    var other_seq: Int64
    var seen: List[ChatEvent]
    var fired_with_seq: Int64

    def __init__(
        out self,
        var other: ChatStore[Self.DB, NoSendProbe],
        channel_id: String,
        sender_user_id: String,
    ):
        self.other = Optional[ChatStore[Self.DB, NoSendProbe]](other^)
        self.armed = False
        self.channel_id = channel_id
        self.sender_user_id = sender_user_id
        self.other_seq = Int64(0)
        self.seen = List[ChatEvent]()
        self.fired_with_seq = Int64(0)

    def before_insert(mut self, channel_id: String, seq: Int64) raises:
        if not self.armed:
            return
        self.armed = False
        self.fired_with_seq = seq
        var rt = new_rt()
        ref reactor = rt.reactor()
        ref b = self.other.value()
        var ev = b.send_message[Rt](
            reactor,
            self.channel_id,
            self.sender_user_id,
            String(INTERLEAVED_BODY),
            Int64(0),
            String(),
            no_ids(),
            False,
            no_ids(),
            T0 + 50,
        )
        self.other_seq = ev.seq
        var page = b.events_after[Rt](reactor, self.channel_id, seq - 1, 100)
        self.seen = page.events.copy()


struct CrashProbe(SendProbe):
    var armed: Bool

    def __init__(out self):
        self.armed = False

    def before_insert(mut self, channel_id: String, seq: Int64) raises:
        if self.armed:
            self.armed = False
            raise Error(String(CRASH_TEXT))
