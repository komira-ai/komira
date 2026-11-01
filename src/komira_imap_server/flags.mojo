# Durable, shared message flags and EXPUNGE, on komira_comms_index.
#
# The schema is the substrate's generic keyed delta:
#   key   = the message's leaf (16 hex digits, its name in the store)
#   value = one byte, the flag bits below
#   op    = PUT (set this message's flags) or TOMBSTONE (EXPUNGE)
#
# The key is the leaf, not the UID: UIDs are 31 bits of a hash (uid.mojo) and
# two messages of a folder can share one, which must never make one message
# inherit, or lose to, the other's flags or EXPUNGE.
#
# Every mutation appends one immutable delta to a log on the same store as the
# messages, under `mail/<scope>/_flags` with the `/` of a folder written `~`
# (a character neither a mailbox nor a folder name holds, so no log's prefix
# lies under another's: a folder named `_flags` is safe); every read folds the
# log (last writer wins by sequence). So two connections to a mailbox, and a
# server that is restarted, see the same flags. `<scope>` is the mailbox for
# INBOX and `<mailbox>/<folder>` for another folder, so each folder has its
# own flags. The log is not under the mailbox's message tree: removing a
# mailbox by that prefix leaves its flag logs.
#
# The store handle is a clone of the one that holds the messages: the object
# store, not the handle, is the shared state.

from std.collections import Dict

from komira_comms_index import CommsIndex, KeyedDelta, key_bytes
from komira_objectstore.store import ConditionalWriteStore

from .parse import lower_ascii
from .uid import is_valid_leaf

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


struct FlagSnapshot(Movable):
    """The flags of a folder at one moment: the folded log, one entry per
    message (by leaf) that has flags. One fold answers any number of
    `flags_of` calls."""

    var _bits: Dict[String, UInt8]

    def __init__(out self):
        self._bits = Dict[String, UInt8]()

    def count(self) -> Int:
        return len(self._bits)

    def flags_of(self, leaf: String) -> UInt8:
        """The flag bits of the message `leaf`; 0 for a message with no flags,
        an expunged one, or one never flagged."""
        if leaf in self._bits:
            try:
                return self._bits[leaf]
            except:
                pass
        return UInt8(0)


def _log_prefix(scope: String) -> String:
    """The log's object prefix for a scope: `/` in the scope becomes `~`."""
    var out = String("")
    var bs = scope.as_bytes()
    for i in range(len(bs)):
        if bs[i] == 0x2F:
            out += String("~")
        else:
            out += chr(Int(bs[i]))
    return String("mail/") + out + "/" + _FLAG_SEGMENT


struct MailboxFlagStore[S: ConditionalWriteStore](Movable):
    """The durable flag state of one folder. Owns one `CommsIndex` over the
    store handle it was given (give it `store.clone()`).

    A handle that has written keeps the tail of the log it knows, so it does
    not see what another handle appends afterwards: open a new handle for
    each command (the server does), and a new handle reads the whole log.

    `flags_of` folds the log for one answer; to answer many, take one
    `snapshot()`. `set_flags` and `expunge` each append one delta. All three
    raise on a store failure. A `leaf` argument is the message's name in the
    store; the ones that are not 16 hex digits raise.

    One process at a time may write a store's flag logs: a delta carries the
    sequence number its writer guessed (the log's head plus one) and a second
    process can guess the same."""

    var _idx: CommsIndex[Self.S]

    def __init__(out self, var store: Self.S, scope: String):
        self._idx = CommsIndex[Self.S](store^, _log_prefix(scope))

    def snapshot(self) raises -> FlagSnapshot:
        """Fold the log into the live flags: one entry per message that has
        flags and was not expunged."""
        var state = self._idx.read_state()
        var out = FlagSnapshot()
        for i in range(state.len()):
            var leaf = String(unsafe_from_utf8=Span(state.keys[i]))
            if not is_valid_leaf(leaf):
                continue
            var b = UInt8(0)
            if len(state.values[i]) > 0:
                b = state.values[i][0] & FLAG_ALL
            out._bits[leaf] = b
        return out^

    def flags_of(self, leaf: String) raises -> UInt8:
        var snap = self.snapshot()
        return snap.flags_of(leaf)

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

    def set_flags(mut self, leaf: String, bits: UInt8) raises:
        """Durably set the flags of the message `leaf` to exactly `bits`."""
        if not is_valid_leaf(leaf):
            raise Error("flags: not a message leaf")
        var seq = self._idx.head_seq() + Int64(1)
        var value = List[UInt8]()
        value.append(bits & FLAG_ALL)
        _ = self._idx.put_delta(KeyedDelta.put(seq, key_bytes(leaf), value^))

    def expunge(mut self, leaf: String) raises:
        """Durably drop the flags of the message `leaf`: a tombstone in the
        log. The message itself is the caller's to delete."""
        if not is_valid_leaf(leaf):
            raise Error("flags: not a message leaf")
        var seq = self._idx.head_seq() + Int64(1)
        _ = self._idx.put_delta(KeyedDelta.tombstone(seq, key_bytes(leaf)))
