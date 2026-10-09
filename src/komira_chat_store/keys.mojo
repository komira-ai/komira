# =============================================================================
# komira_chat_store/keys.mojo -- ids, the subject key, the DM id and the
#   stored form of an id list.
# =============================================================================
#
# Every id the store is handed (user, channel, file) is 1 to 64 bytes of
# `A-Z a-z 0-9 _ -`. The service mints them; the store refuses any other
# shape, so an id can never hold the `,` an id list is joined with, nor a `/`
# a document store cannot name a document with.
#
# A DM's id is `dm-` and its sorted users joined by `.`: no other id holds a
# `.`, so a DM id is never a valid id of a channel `create_channel` makes, and
# two sets of users never share one. It is at most 3 + 9 * 64 + 8 = 587 bytes.
# =============================================================================

comptime MAX_ID_BYTES: Int = 64
# A DM holds 2 to 9 users.
comptime MIN_DM_USERS: Int = 2
comptime MAX_DM_USERS: Int = 9
comptime DM_ID_PREFIX: StaticString = "dm-"
comptime DM_ID_SEPARATOR: StaticString = "."


def is_valid_id(id: String) -> Bool:
    var b = id.as_bytes()
    var n = len(b)
    if n == 0 or n > MAX_ID_BYTES:
        return False
    for i in range(n):
        var c = Int(b[i])
        var ok = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("_")
            or c == ord("-")
        )
        if not ok:
            return False
    return True


def require_id(id: String, what: StaticString) raises:
    """Raises `komira_chat_store: invalid <what> "<id>"` unless `id` is a
    valid id."""
    if not is_valid_id(id):
        raise Error(
            String("komira_chat_store: invalid ")
            + what
            + String(' "')
            + id
            + String('"')
        )


def subject_key(iss: String, sub: String) -> String:
    """The key of a token's (iss, sub): the issuer's byte length, `:`, the
    issuer, then the subject. The length makes it injective: no two pairs
    share a key, whatever bytes either holds."""
    return String(iss.byte_length()) + String(":") + iss + sub


def join_ids(ids: List[String]) -> String:
    var out = String()
    for i in range(len(ids)):
        if i > 0:
            out += String(",")
        out += ids[i]
    return out^


def split_ids(s: String) -> List[String]:
    var out = List[String]()
    if s.byte_length() == 0:
        return out^
    for part in s.split(String(",")):
        out.append(String(part))
    return out^


def sorted_unique(ids: List[String]) -> List[String]:
    """`ids` in ascending byte order, each once."""
    var xs = ids.copy()
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j - 1] > xs[j]:
            var t = xs[j - 1]
            xs[j - 1] = xs[j]
            xs[j] = t^
            j -= 1
    var out = List[String]()
    for i in range(len(xs)):
        if len(out) == 0 or out[len(out) - 1] != xs[i]:
            out.append(xs[i])
    return out^


def dm_users(ids: List[String]) raises -> List[String]:
    """The users of a DM: `ids` sorted and deduplicated. Raises unless each is
    a valid id and there are 2 to 9 of them."""
    for i in range(len(ids)):
        require_id(ids[i], "user id")
    var users = sorted_unique(ids)
    if len(users) < MIN_DM_USERS or len(users) > MAX_DM_USERS:
        raise Error(
            String("komira_chat_store: a DM holds 2 to 9 distinct users, not ")
            + String(len(users))
        )
    return users^


def dm_channel_id(ids: List[String]) raises -> String:
    """The channel id of the DM between `ids` (in any order, repeats
    ignored): one set of users has one DM."""
    var users = dm_users(ids)
    var out = String(DM_ID_PREFIX)
    for i in range(len(users)):
        if i > 0:
            out += String(DM_ID_SEPARATOR)
        out += users[i]
    return out^
