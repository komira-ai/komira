# UIDs and UIDVALIDITY, derived from names. These are not RFC 3501 section
# 2.3.1.1 UIDs; see README.md ("UIDs").

comptime _FNV_OFFSET: UInt64 = 14695981039346656037
comptime _FNV_PRIME: UInt64 = 1099511628211


def fnv1a64(s: String) -> UInt64:
    """FNV-1a, 64 bits, of the bytes of `s`."""
    var h = _FNV_OFFSET
    var bs = s.as_bytes()
    for i in range(len(bs)):
        h = h ^ UInt64(Int(bs[i]))
        h = h * _FNV_PRIME
    return h


def _fold31(h: UInt64) -> Int:
    """The top 31 bits of the hash as a positive number: never 0."""
    var v = Int((h >> UInt64(33)) & UInt64(0x7FFFFFFF))
    if v == 0:
        return 1
    return v


def assign_uid(leaf: String) -> Int:
    """The UID of the message stored under `leaf` (its content hash): 31 bits
    of a hash of the name. The same message always has the same UID, in any
    session and any folder. Two messages of one folder can share a UID (about
    even odds near 55,000 messages), and UIDs do not follow delivery order.
    Flags and EXPUNGE are keyed by leaf, so a shared UID never mixes them up;
    only a UID-addressed command (UID FETCH, UID STORE) names both."""
    return _fold31(fnv1a64(leaf))


def uidvalidity_for(scope: String) -> Int:
    """UIDVALIDITY of a folder, from its flag scope (`flag_scope`): constant
    for a folder name across restarts."""
    return _fold31(fnv1a64(scope))


def is_valid_leaf(leaf: String) -> Bool:
    """Sixteen lowercase hex digits: what `komira_mail_store` names a message.
    Anything else in a folder is not a message of this server."""
    var bs = leaf.as_bytes()
    if len(bs) != 16:
        return False
    for i in range(16):
        var c = bs[i]
        var digit = c >= 0x30 and c <= 0x39
        var lower = c >= 0x61 and c <= 0x66
        if not (digit or lower):
            return False
    return True
