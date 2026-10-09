# =============================================================================
# komira_test_pdp/request.mojo: reading an AuthZEN 1.0 evaluation request in
#   the komira profile.
# =============================================================================
#
# One evaluation (`POST /access/v1/evaluation`):
#
#   {"subject":  {"type": T, "id": S, "properties": {"token": TOKEN}},
#    "action":   {"name": A},
#    "resource": {"type": K, "id": R, "properties"?: {...}},
#    "context":  {"audience": AUD}}
#
# A batch (`POST /access/v1/evaluations`) shares `subject`, `action` and
# `context`, and lists the resources:
#
#   {"subject": ..., "action": ..., "context": ...,
#    "evaluations": [{"resource": {...}}, ...]}
#
# What is refused here (each a 400 with its reason, reasons.mojo):
#   - a body that is not one JSON object, or that names a member twice in any
#     object (RFC 8259 leaves duplicates to the reader; two readers that
#     pick different copies of `subject` would judge different requests);
#   - `subject` not an object, `type` or `id` not a string, `properties` not
#     an object, `properties.token` not a non-empty string;
#   - `action` not an object, `name` not a non-empty string;
#   - `resource` not an object, `type` not a non-empty string, `id` not a
#     string of 1 to 256 bytes, `properties` present and not an object;
#   - `context` not an object, `audience` not a string;
#   - batch: `evaluations` not an array of 1 to 100 items; an item that is
#     not an object holding exactly one member, `resource`; a top-level
#     `resource` beside `evaluations`. An item may not carry its own
#     `subject`, `action` or `context` (AuthZEN allows per-item overrides;
#     this profile shares them, so a per-item subject is refused rather
#     than silently ignored).
#
# Other top-level members are ignored (AuthZEN is extensible). Nothing here
# compares the subject with its token: that is the decision point's job
# (pdp.mojo), after both tokens verify.
# =============================================================================

from komira_json import (
    JSON_ARRAY,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_bytes,
)
from komira_json import refuse_duplicate_keys

from komira_test_pdp.reasons import (
    REASON_ACTION_INVALID,
    REASON_BATCH_INVALID,
    REASON_BODY_NOT_JSON,
    REASON_CONTEXT_INVALID,
    REASON_DUPLICATE_MEMBER,
    REASON_RESOURCE_INVALID,
    REASON_SUBJECT_INVALID,
)

comptime MAX_RESOURCE_ID_BYTES: Int = 256
comptime MAX_BATCH_ITEMS: Int = 100


@fieldwise_init
struct EvalResource(Copyable, Movable):
    var type: String
    var id: String


struct EvalRequest(Copyable, Movable):
    """A request that passed every shape check. `resources` has one entry
    for a single evaluation and 1 to 100 for a batch, in request order."""

    var subject_type: String
    var subject_id: String
    var subject_token: String
    var action: String
    var audience: String
    var resources: List[EvalResource]

    def __init__(out self):
        self.subject_type = String("")
        self.subject_id = String("")
        self.subject_token = String("")
        self.action = String("")
        self.audience = String("")
        self.resources = List[EvalResource]()


struct ParseOutcome(Movable):
    """A parsed request, or the reason it was refused (`reason` empty on
    success)."""

    var request: EvalRequest
    var reason: String

    def __init__(out self, var request: EvalRequest):
        self.request = request^
        self.reason = String("")

    def __init__(out self, *, refused: String):
        self.request = EvalRequest()
        self.reason = refused


def _member(obj: JsonValue, name: String, kind: Int) -> Optional[JsonValue]:
    """The member `name` of `obj` when it is of kind `kind`, else None."""
    if not obj.has(name):
        return None
    try:
        var v = obj.get(name)
        if v.kind_tag() != kind:
            return None
        return v^
    except:
        return None


def _string_member(obj: JsonValue, name: String) -> Optional[String]:
    var v = _member(obj, name, JSON_STRING)
    if not v:
        return None
    try:
        return v.value().as_string()
    except:
        return None


def _read_resource(obj: JsonValue) -> Optional[EvalResource]:
    """`{"type": K, "id": R, "properties"?: {...}}`, checked, or None."""
    if obj.kind_tag() != JSON_OBJECT:
        return None
    var kind = _string_member(obj, String("type"))
    var id = _string_member(obj, String("id"))
    if not kind or not id:
        return None
    if kind.value().byte_length() == 0:
        return None
    var n = id.value().byte_length()
    if n < 1 or n > MAX_RESOURCE_ID_BYTES:
        return None
    if obj.has(String("properties")):
        if not _member(obj, String("properties"), JSON_OBJECT):
            return None
    return EvalResource(kind.value(), id.value())


def _read_shared(root: JsonValue, mut req: EvalRequest) -> String:
    """Reads `subject`, `action` and `context` into `req`; the refusal
    reason, or "" when all three are well formed."""
    var subject = _member(root, String("subject"), JSON_OBJECT)
    if not subject:
        return REASON_SUBJECT_INVALID
    var s = subject.value().copy()
    var stype = _string_member(s, String("type"))
    var sid = _string_member(s, String("id"))
    var props = _member(s, String("properties"), JSON_OBJECT)
    if not stype or not sid or not props:
        return REASON_SUBJECT_INVALID
    var token = _string_member(props.value(), String("token"))
    if not token or token.value().byte_length() == 0:
        return REASON_SUBJECT_INVALID

    var action = _member(root, String("action"), JSON_OBJECT)
    if not action:
        return REASON_ACTION_INVALID
    var name = _string_member(action.value(), String("name"))
    if not name or name.value().byte_length() == 0:
        return REASON_ACTION_INVALID

    var context = _member(root, String("context"), JSON_OBJECT)
    if not context:
        return REASON_CONTEXT_INVALID
    var audience = _string_member(context.value(), String("audience"))
    if not audience:
        return REASON_CONTEXT_INVALID

    req.subject_type = stype.value()
    req.subject_id = sid.value()
    req.subject_token = token.value()
    req.action = name.value()
    req.audience = audience.value()
    return String("")


def _parse_root(body: List[UInt8]) -> Optional[JsonValue]:
    try:
        var root = parse_json_bytes(body)
        if root.kind_tag() != JSON_OBJECT:
            return None
        return root^
    except:
        return None


def _has_duplicates(root: JsonValue) -> Bool:
    try:
        refuse_duplicate_keys(root)
        return False
    except:
        return True


def parse_evaluation(body: List[UInt8]) -> ParseOutcome:
    """One evaluation (module header)."""
    var root = _parse_root(body)
    if not root:
        return ParseOutcome(refused=REASON_BODY_NOT_JSON)
    if _has_duplicates(root.value()):
        return ParseOutcome(refused=REASON_DUPLICATE_MEMBER)
    var req = EvalRequest()
    var why = _read_shared(root.value(), req)
    if why.byte_length() != 0:
        return ParseOutcome(refused=why)
    var res = _member(root.value(), String("resource"), JSON_OBJECT)
    if not res:
        return ParseOutcome(refused=REASON_RESOURCE_INVALID)
    var r = _read_resource(res.value())
    if not r:
        return ParseOutcome(refused=REASON_RESOURCE_INVALID)
    req.resources.append(r.value().copy())
    return ParseOutcome(req^)


def parse_evaluations(body: List[UInt8]) -> ParseOutcome:
    """A batch (module header)."""
    var root = _parse_root(body)
    if not root:
        return ParseOutcome(refused=REASON_BODY_NOT_JSON)
    if _has_duplicates(root.value()):
        return ParseOutcome(refused=REASON_DUPLICATE_MEMBER)
    var req = EvalRequest()
    var why = _read_shared(root.value(), req)
    if why.byte_length() != 0:
        return ParseOutcome(refused=why)
    if root.value().has(String("resource")):
        return ParseOutcome(refused=REASON_BATCH_INVALID)
    var items = _member(root.value(), String("evaluations"), JSON_ARRAY)
    if not items:
        return ParseOutcome(refused=REASON_BATCH_INVALID)
    var n = items.value().array_len()
    if n < 1 or n > MAX_BATCH_ITEMS:
        return ParseOutcome(refused=REASON_BATCH_INVALID)
    for i in range(n):
        try:
            var item = items.value().element_at(i)
            if item.kind_tag() != JSON_OBJECT or item.num_members() != 1:
                return ParseOutcome(refused=REASON_BATCH_INVALID)
            var res = _member(item, String("resource"), JSON_OBJECT)
            if not res:
                return ParseOutcome(refused=REASON_BATCH_INVALID)
            var r = _read_resource(res.value())
            if not r:
                return ParseOutcome(refused=REASON_RESOURCE_INVALID)
            req.resources.append(r.value().copy())
        except:
            return ParseOutcome(refused=REASON_BATCH_INVALID)
    return ParseOutcome(req^)
