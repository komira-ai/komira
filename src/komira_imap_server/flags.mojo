# Durable, shared message flags and EXPUNGE, on komira_comms_index.
#
# The schema is the substrate's generic keyed delta:
#   key   = the message UID as decimal text
#   value = one byte, the flag bits below
#   op    = PUT (set this message's flags) or TOMBSTONE (EXPUNGE)
#
# Every mutation appends one immutable delta to a log on the same store as the
# messages, under `mail/<scope>/_flags`; every read folds the log (last writer
# wins by sequence). So two connections to a mailbox, and a server that is
# restarted, see the same flags. `<scope>` is the mailbox for INBOX and
# `<mailbox>/<folder>` for another folder, so each folder has its own flags.
#
# The store handle is a clone of the one that holds the messages: the object
# store, not the handle, is the shared state.

from komira_comms_index import CommsIndex, KeyedDelta, key_bytes
from komira_objectstore.store import ConditionalWriteStore

from .parse import lower_ascii
from .sets import ascending_order

comptime FLAG_SEEN: UInt8 = 0x01
comptime FLAG_ANSWERED: UInt8 = 0x02
comptime FLAG_FLAGGED: UInt8 = 0x04
comptime FLAG_DELETED: UInt8 = 0x08
comptime FLAG_DRAFT: UInt8 = 0x10
# All five together.
comptime FLAG_ALL: UInt8 = 0x1F

comptime _FLAG_SEGMENT: String = "_flags"


def flags_to_text(bits: UInt8) -> String:
    """The flags as the inside of an IMAP flag list, in a fixed order and
    separated by single spaces: `\\Seen \\Answered \\Flagged \\Deleted
    \\Draft`. No bits is the empty string."""
    var out = String("")
    var first = True
    if (bits & FLAG_SEEN) != 0:
        out += String("\\Seen")
        first = False
    if (bits & FLAG_ANSWERED) != 0:
        if not first:
            out += String(" ")
        out += String("\\Answered")
        first = False
    if (bits & FLAG_FLAGGED) != 0:
        if not first:
            out += String(" ")
        out += String("\\Flagged")
        first = False
    if (bits & FLAG_DELETED) != 0:
        if not first:
            out += String(" ")
        out += String("\\Deleted")
        first = False
    if (bits & FLAG_DRAFT) != 0:
        if not first:
            out += String(" ")
        out += String("\\Draft")
    return out^


def flag_bit_of(name: String) -> UInt8:
    """The bit of a system flag name, any letter case (`\\Seen`), or 0 for
    anything else (`\\Recent`, a keyword)."""
    var lower = lower_ascii(name)
    if lower == "\\seen":
        return FLAG_SEEN
    if lower == "\\answered":
        return FLAG_ANSWERED
    if lower == "\\flagged":
        return FLAG_FLAGGED
    if lower == "\\deleted":
        return FLAG_DELETED
    if lower == "\\draft":
        return FLAG_DRAFT
    return UInt8(0)


def flag_scope(mailbox: String, folder: String) -> String:
    """The name a folder's flags (and its UIDVALIDITY) are kept under:
    `mailbox` for INBOX, `mailbox/folder` for any other folder. `folder` is
    the normalized name."""
    if folder == "INBOX":
        return mailbox
    return mailbox + String("/") + folder


def _parse_uid(key: List[UInt8]) -> Int:
    """The number a decimal key spells, or -1 if it is not one."""
    if len(key) == 0 or len(key) > 18:
        return -1
    var v = 0
    for i in range(len(key)):
        var c = key[i]
        if c < 0x30 or c > 0x39:
            return -1
        v = v * 10 + Int(c - 0x30)
    return v


struct FlagSnapshot(Movable):
    """The flags of a folder at one moment: the folded log, as UIDs in
    ascending order with their bits. One fold answers any number of
    `flags_of` calls, each a binary search."""

    var _uids: List[Int]
    var _bits: List[UInt8]

    def __init__(out self):
        self._uids = List[Int]()
        self._bits = List[UInt8]()

    def count(self) -> Int:
        return len(self._uids)

    def flags_of(self, uid: Int) -> UInt8:
        """The flag bits of `uid`; 0 for a message with no flags, an expunged
        one, or one never flagged."""
        var lo = 0
        var hi = len(self._uids) - 1
        while lo <= hi:
            var mid = (lo + hi) // 2
            var here = self._uids[mid]
            if here == uid:
                return self._bits[mid]
            if here < uid:
                lo = mid + 1
            else:
                hi = mid - 1
        return UInt8(0)


struct MailboxFlagStore[S: ConditionalWriteStore](Movable):
    """The durable flag state of one folder. Owns one `CommsIndex` over the
    store handle it was given (give it `store.clone()`).

    A handle that has written keeps the tail of the log it knows, so it does
    not see what another handle appends afterwards: open a new handle for
    each command (the server does), and a new handle reads the whole log.

    `flags_of` folds the log for one answer; to answer many, take one
    `snapshot()`. `set_flags` and `expunge` each append one delta. All three
    raise on a store failure."""

    var _idx: CommsIndex[Self.S]

    def __init__(out self, var store: Self.S, scope: String):
        self._idx = CommsIndex[Self.S](
            store^, String("mail/") + scope + "/" + _FLAG_SEGMENT
        )

    def snapshot(self) raises -> FlagSnapshot:
        """Fold the log into the live flags: one entry per message that has
        flags and was not expunged."""
        var state = self._idx.read_state()
        var uids = List[Int]()
        var bits = List[UInt8]()
        for i in range(state.len()):
            var uid = _parse_uid(state.keys[i])
            if uid < 0:
                continue
            var b = UInt8(0)
            if len(state.values[i]) > 0:
                b = state.values[i][0] & FLAG_ALL
            uids.append(uid)
            bits.append(b)
        var order = ascending_order(uids)
        var out = FlagSnapshot()
        for k in range(len(order)):
            out._uids.append(uids[order[k]])
            out._bits.append(bits[order[k]])
        return out^

    def flags_of(self, uid: Int) raises -> UInt8:
        var snap = self.snapshot()
        return snap.flags_of(uid)

    def log_length(self) raises -> Int:
        """How many chunks the log has now (the deltas since the last
        compaction, plus the base): what a command folds."""
        return Int(self._idx.num_live_chunks())

    def compact_if_longer_than(mut self, live_chunks: Int):
        """Fold the log into one base chunk when it has more than
        `live_chunks` chunks, so the next fold reads one chunk and not one per
        STORE ever made. The flags are the same before and after. A failure is
        ignored: compaction only saves work."""
        try:
            if self._idx.num_live_chunks() > Int64(live_chunks):
                _ = self._idx.compact()
        except:
            pass

    def set_flags(mut self, uid: Int, bits: UInt8) raises:
        """Durably set the flags of `uid` to exactly `bits`."""
        var seq = self._idx.head_seq() + Int64(1)
        var value = List[UInt8]()
        value.append(bits & FLAG_ALL)
        _ = self._idx.put_delta(KeyedDelta.put(seq, key_bytes(String(uid)), value^))

    def expunge(mut self, uid: Int) raises:
        """Durably drop the flags of `uid`: a tombstone in the log. The
        message itself is the caller's to delete."""
        var seq = self._idx.head_seq() + Int64(1)
        _ = self._idx.put_delta(KeyedDelta.tombstone(seq, key_bytes(String(uid))))
