# =============================================================================
# komira_git/protocol_types.mojo -- the values the protocol state machines
# exchange with their callers: refs as a server advertises them, and the
# arguments of protocol v2's ls-refs and fetch commands.
# =============================================================================

from .bytes_util import _append_str
from .object_id import ObjectFormat, ObjectId
from .pkt_line import append_pkt_data


struct AdvertisedRef(Copyable, Movable):
    """One ref as a server lists it: its name, the object it names (git's
    null id for an unborn HEAD), the ref it points at when it is a symbolic
    ref ("" otherwise), and for an annotated tag the object the tag peels to
    (the null id otherwise)."""

    var name: String
    var id: ObjectId
    var symref_target: String
    var peeled: ObjectId

    def __init__(
        out self,
        name: String,
        id: ObjectId,
        symref_target: String = "",
        peeled: Optional[ObjectId] = None,
    ):
        self.name = name
        self.id = id
        self.symref_target = symref_target
        if peeled:
            self.peeled = peeled.value()
        else:
            self.peeled = ObjectId.zero(id.format())

    def is_unborn(self) -> Bool:
        """True when the ref names no object yet (an unborn HEAD)."""
        return self.id.is_zero()

    def is_symref(self) -> Bool:
        return self.symref_target.byte_length() > 0

    def has_peeled(self) -> Bool:
        return not self.peeled.is_zero()


struct LsRefsArgs(Copyable, Movable):
    """The arguments of an ls-refs command (gitprotocol-v2, "ls-refs")."""

    var peel: Bool
    var symrefs: Bool
    var unborn: Bool
    var ref_prefixes: List[String]

    def __init__(out self):
        self.peel = False
        self.symrefs = False
        self.unborn = False
        self.ref_prefixes = List[String]()


struct FetchArgs(Copyable, Movable):
    """The arguments of a fetch command (gitprotocol-v2, "fetch"), as a
    server reads them and as a client writes them. `deepen` is 0 when the
    request has no `deepen <n>` line; `deepen_since` is None when it has no
    `deepen-since <timestamp>` line; `deepen_not` holds the <ref> of each
    `deepen-not <ref>` line as sent (the repository resolves it, as git's
    upload-pack expands it to one ref)."""

    var wants: List[ObjectId]
    var haves: List[ObjectId]
    var shallows: List[ObjectId]
    var deepen: Int
    var deepen_since: Optional[Int]
    var deepen_not: List[String]
    var deepen_relative: Bool
    var thin_pack: Bool
    var no_progress: Bool
    var include_tag: Bool
    var ofs_delta: Bool
    var wait_for_done: Bool
    var done: Bool

    def __init__(out self):
        self.wants = List[ObjectId]()
        self.haves = List[ObjectId]()
        self.shallows = List[ObjectId]()
        self.deepen = 0
        self.deepen_since = None
        self.deepen_not = List[String]()
        self.deepen_relative = False
        self.thin_pack = False
        self.no_progress = False
        self.include_tag = False
        self.ofs_delta = False
        self.wait_for_done = False
        self.done = False

    def asks_shallow(self) -> Bool:
        """The request names a shallow boundary (`shallow`) or asks for a
        new one (`deepen`, `deepen-since`, `deepen-not`): the response has
        a shallow-info section."""
        return (
            len(self.shallows) > 0
            or self.deepen > 0
            or Bool(self.deepen_since)
            or len(self.deepen_not) > 0
        )


def _bytes_less(a: String, b: String) -> Bool:
    """`a` sorts before `b` byte by byte (git's strcmp order of ref names)."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var n = len(x) if len(x) < len(y) else len(y)
    for i in range(n):
        if x[i] != y[i]:
            return x[i] < y[i]
    return len(x) < len(y)


def _sorted_by_name(refs: List[AdvertisedRef]) -> List[Int]:
    """The indices of `refs` in name order (stable)."""
    var order = List[Int](capacity=len(refs))
    for i in range(len(refs)):
        var j = len(order)
        order.append(i)
        while j > 0 and _bytes_less(refs[i].name, refs[order[j - 1]].name):
            order[j] = order[j - 1]
            j -= 1
        order[j] = i
    return order^


def _check_agent(agent: String) raises:
    """An agent string is printable ASCII without spaces, as git's
    git_user_agent_sanitized() makes it."""
    var b = agent.as_bytes()
    if len(b) == 0:
        raise Error("komira_git: the agent string is empty")
    for i in range(len(b)):
        if b[i] <= 32 or b[i] >= 127:
            raise Error(
                "komira_git: the agent string holds byte " + String(Int(b[i]))
                + ", not printable ASCII without spaces"
            )


def _parse_id(format: ObjectFormat, text: String) -> Optional[ObjectId]:
    """`text` as an object id of `format`, or None when it is not exactly
    one."""
    try:
        return ObjectId.parse_hex(format, text)
    except e:
        return None


def _text_pkt(mut out: List[UInt8], text: String) raises:
    """One data pkt-line holding the bytes of `text` (no LF added)."""
    append_pkt_data(out, text.as_bytes())


def _line_pkt(mut out: List[UInt8], text: String) raises:
    """One data pkt-line holding `text` and an LF."""
    var b = List[UInt8](capacity=text.byte_length() + 1)
    _append_str(b, text)
    b.append(10)
    append_pkt_data(out, Span(b))
