# =============================================================================
# komira_test_pdp/pdp.mojo: `TestPdp`, an in-process AuthZEN 1.0 decision
#   point over an in-memory policy table, with revoke.
# =============================================================================
#
# `handle(method, path, authorization, body)` answers one HTTP request the
# way a decision point serving the komira profile of AuthZEN must (the
# public HTTP auth design, "The decision point"). In order:
#
#   1. path `/access/v1/evaluation` (one) or `/access/v1/evaluations`
#      (batch), else 404; method `POST`, else 405;
#   2. the bearer: `Authorization: Bearer <token68>` (scheme compared ASCII
#      case-insensitively, exactly one space). Absent or another scheme: 401
#      with a bare `Bearer` challenge. Malformed: 400 invalid_request. The
#      token must verify (`TokenVerifier`), its `aud` must equal this
#      decision point's audience, and it must carry a `client_id`; else 401
#      invalid_token;
#   3. the body: at most 64 KiB (413), then the shape (request.mojo, 400);
#   4. the safety conditions, each a 403 (the subject comes ONLY from the
#      subject token, never from the body):
#        - `subject.properties.token` verifies;
#        - `subject.type` equals the token's subject type;
#        - `subject.id` equals the token's `sub`;
#        - the token's `aud` equals `context.audience`;
#        - `context.audience` equals the bearer's `client_id`;
#   5. the decision, per resource: true only when the policy table holds a
#      rule (subject type, token `sub`, action, resource type, resource id)
#      and the resource type is declared. An action this decision point does
#      not know (not read, write, delete, admin and not declared) is judged as
#      `admin`, the strictest tier. Answered 200 with
#      `Cache-Control: no-store` and `{"decision": B}` (one) or
#      `{"evaluations": [{"decision": B}, ...]}` (batch, request order); with
#      `context.max_age_s` in each decision when one is set.
#
# Policy: `declare_kind`, `declare_action`, `allow(rule)` and `revoke(rule)`.
# An undeclared resource type is always denied: `allow` refuses a rule that
# names one, so no rule can match it.
# A revoke takes effect on the next request: there is no cache here (the
# only decision cache is the client's).
#
# Logging: none. `decisions()` keeps, per decided resource, only what the
# profile lets a decision point log (subject type, `sub`, action, resource
# type and id, the decision); never a token or the body. `request_count()`
# counts every `handle` call, so a client's cache can be tested by how often
# it asks.
# =============================================================================

from komira_json import JsonValue

from komira_test_pdp.reasons import (
    REASON_AUDIENCE_MISMATCH,
    REASON_BEARER_AUDIENCE,
    REASON_BEARER_INVALID,
    REASON_BEARER_MALFORMED,
    REASON_BEARER_MISSING,
    REASON_BEARER_NO_CLIENT_ID,
    REASON_BODY_TOO_LARGE,
    REASON_CLIENT_MISMATCH,
    REASON_DECIDED,
    REASON_METHOD,
    REASON_NOT_FOUND,
    REASON_SUBJECT_MISMATCH,
    REASON_SUBJECT_TOKEN_INVALID,
    REASON_SUBJECT_TYPE_MISMATCH,
)
from komira_test_pdp.request import (
    EvalRequest,
    ParseOutcome,
    parse_evaluation,
    parse_evaluations,
)
from komira_test_pdp.tokens import TokenVerifier, VerifiedToken

comptime PATH_EVALUATION: String = "/access/v1/evaluation"
comptime PATH_EVALUATIONS: String = "/access/v1/evaluations"
comptime MAX_BODY_BYTES: Int = 65536
comptime CACHE_CONTROL_NO_STORE: String = "no-store"
comptime STRICTEST_ACTION: String = "admin"


def base_actions() -> List[String]:
    """The actions every decision point knows: read, write, delete, admin."""
    var out = List[String]()
    out.append(String("read"))
    out.append(String("write"))
    out.append(String("delete"))
    out.append(String("admin"))
    return out^


@fieldwise_init
struct PolicyRule(Copyable, Movable, Equatable):
    """`subject` (of `subject_type`) may do `action` on the resource
    (`resource_type`, `resource_id`). Exact match on all five."""

    var subject_type: String
    var subject: String
    var action: String
    var resource_type: String
    var resource_id: String

    def __eq__(self, other: Self) -> Bool:
        return (
            self.subject_type == other.subject_type
            and self.subject == other.subject
            and self.action == other.action
            and self.resource_type == other.resource_type
            and self.resource_id == other.resource_id
        )


@fieldwise_init
struct DecisionRecord(Copyable, Movable):
    """What the decision point keeps of one decided resource (module
    header): no token, no body."""

    var subject_type: String
    var subject: String
    var action: String
    var resource_type: String
    var resource_id: String
    var decision: Bool


struct PdpReply(Copyable, Movable):
    """One HTTP answer. `www_authenticate` and `cache_control` are empty when
    the header is not sent. `reason` is for tests only (reasons.mojo); the
    body never carries it."""

    var status: Int
    var body: String
    var cache_control: String
    var www_authenticate: String
    var reason: String

    def __init__(
        out self,
        status: Int,
        var body: String,
        var reason: String,
        *,
        var cache_control: String = String(""),
        var www_authenticate: String = String(""),
    ):
        self.status = status
        self.body = body^
        self.reason = reason^
        self.cache_control = cache_control^
        self.www_authenticate = www_authenticate^


def _error_reply(
    status: Int, reason: String, www_authenticate: String = String("")
) -> PdpReply:
    """A JSON error envelope, `{"error": {"code", "message"}}`, that names only
    the status class: never which check refused."""
    var code: String
    if status == 400:
        code = String("bad_request")
    elif status == 401:
        code = String("unauthorized")
    elif status == 403:
        code = String("forbidden")
    elif status == 404:
        code = String("not_found")
    elif status == 405:
        code = String("method_not_allowed")
    else:
        code = String("payload_too_large")
    var err = JsonValue.empty_object()
    var env = JsonValue.empty_object()
    try:
        err.set_member(String("code"), JsonValue.from_string(code))
        err.set_member(String("message"), JsonValue.from_string(code))
        env.set_member(String("error"), err^)
    except:
        pass
    return PdpReply(
        status,
        env.serialize(),
        reason,
        cache_control=CACHE_CONTROL_NO_STORE,
        www_authenticate=www_authenticate,
    )


@always_inline
def _lower(c: UInt8) -> UInt8:
    return c + 0x20 if (c >= 0x41 and c <= 0x5A) else c


def _is_token68_byte(c: UInt8) -> Bool:
    return (
        (c >= 0x41 and c <= 0x5A)  # A-Z
        or (c >= 0x61 and c <= 0x7A)  # a-z
        or (c >= 0x30 and c <= 0x39)  # 0-9
        or c == 0x2D  # -
        or c == 0x2E  # .
        or c == 0x5F  # _
        or c == 0x7E  # ~
        or c == 0x2B  # +
        or c == 0x2F  # /
    )


comptime BEARER_ABSENT = 0
comptime BEARER_MALFORMED = 1
comptime BEARER_PRESENT = 2


@fieldwise_init
struct BearerCredential(Copyable, Movable):
    """What `bearer_token` found: `kind` is BEARER_ABSENT, BEARER_MALFORMED
    or BEARER_PRESENT, and `token` is set only for BEARER_PRESENT."""

    var kind: Int
    var token: String


def bearer_token(authorization: Optional[String]) -> BearerCredential:
    """BEARER_ABSENT when there is no Bearer credential (no header, or another
    scheme), BEARER_MALFORMED when the Bearer credential is malformed, and
    BEARER_PRESENT with the token otherwise. The scheme is the bytes before
    the first space (or all of them); `Bearer` matches ASCII
    case-insensitively and must be followed by exactly one space and a
    token68 (RFC 7235: the base64url and base64 alphabets, `.`, `~`, then
    `=` padding only at the end)."""
    if not authorization:
        return BearerCredential(BEARER_ABSENT, String(""))
    var value = authorization.value()
    var b = value.as_bytes()
    var n = len(b)
    var sp = 0
    while sp < n and b[sp] != 0x20:
        sp += 1
    if sp != 6:
        return BearerCredential(BEARER_ABSENT, String(""))
    var want = String("bearer")
    var w = want.as_bytes()
    for i in range(6):
        if _lower(b[i]) != w[i]:
            return BearerCredential(BEARER_ABSENT, String(""))
    var start = sp + 1
    if start >= n:  # `Bearer` alone, or `Bearer ` and nothing after it
        return BearerCredential(BEARER_MALFORMED, String(""))
    var end = n
    while end > start and b[end - 1] == 0x3D:  # trailing `=`
        end -= 1
    if end == start:
        return BearerCredential(BEARER_MALFORMED, String(""))
    for i in range(start, end):
        if not _is_token68_byte(b[i]):
            return BearerCredential(BEARER_MALFORMED, String(""))
    var token = String(value[byte=start:n])
    return BearerCredential(BEARER_PRESENT, token^)


trait PdpEndpoint(Movable, Deinitable):
    """A decision point a scenario can drive (scenarios.mojo): the HTTP
    endpoint, and the policy verbs a scenario uses to set up and change its
    rules. An adapter for another decision point implements the same three
    and reports `PdpReply.reason` as "" (the reason codes are this
    package's)."""

    def handle(
        mut self,
        method: String,
        path: String,
        authorization: Optional[String],
        body: List[UInt8],
    ) -> PdpReply:
        ...

    def allow(mut self, rule: PolicyRule) raises:
        ...

    def revoke(mut self, rule: PolicyRule) raises -> Bool:
        ...


struct TestPdp[V: TokenVerifier](PdpEndpoint, Movable, Deinitable):
    """An AuthZEN 1.0 decision point in the komira profile (module header).
    `audience` is this decision point's own audience: the `aud` a bearer must
    carry."""

    var verifier: Self.V
    var audience: String
    var now_s: Int64
    var _kinds: List[String]
    var _actions: List[String]
    var _rules: List[PolicyRule]
    var _decisions: List[DecisionRecord]
    var _requests: Int
    var _max_age_s: Int
    var _last_reason: String

    def __init__(out self, var verifier: Self.V, audience: String, now_s: Int64):
        self.verifier = verifier^
        self.audience = audience
        self.now_s = now_s
        self._kinds = List[String]()
        self._actions = base_actions()
        self._rules = List[PolicyRule]()
        self._decisions = List[DecisionRecord]()
        self._requests = 0
        self._max_age_s = -1
        self._last_reason = String("")

    # -- policy ---------------------------------------------------------------

    def declare_kind(mut self, kind: String) raises:
        """A resource type this decision point judges. An undeclared type is
        always denied."""
        if kind.byte_length() == 0:
            raise Error("TestPdp: empty resource type")
        if self._known(self._kinds, kind):
            raise Error("TestPdp: resource type declared twice")
        self._kinds.append(kind)

    def declare_action(mut self, action: String) raises:
        """An action beyond read, write, delete and admin (a service's own
        `<service>.<verb>`). An undeclared action is judged as admin."""
        if action.byte_length() == 0:
            raise Error("TestPdp: empty action")
        if self._known(self._actions, action):
            raise Error("TestPdp: action declared twice")
        self._actions.append(action)

    def allow(mut self, rule: PolicyRule) raises:
        """Adds a rule. Raises when its resource type or action is not
        declared (such a rule could never match), or when it is already
        in the table."""
        if not self._known(self._kinds, rule.resource_type):
            raise Error("TestPdp: rule names an undeclared resource type")
        if not self._known(self._actions, rule.action):
            raise Error("TestPdp: rule names an undeclared action")
        for i in range(len(self._rules)):
            if self._rules[i] == rule:
                raise Error("TestPdp: rule added twice")
        self._rules.append(rule.copy())

    def revoke(mut self, rule: PolicyRule) raises -> Bool:
        """Removes a rule; the next request is judged without it. True when
        the rule was in the table. Never raises (the signature is
        `PdpEndpoint`'s)."""
        for i in range(len(self._rules)):
            if self._rules[i] == rule:
                _ = self._rules.pop(i)
                return True
        return False

    def set_max_age_s(mut self, max_age_s: Int) raises:
        """Every decision then carries `context.max_age_s` (0 or more), which
        a client may use only to shorten its cache. -1 stops sending it."""
        if max_age_s < -1:
            raise Error("TestPdp: max_age_s below -1")
        self._max_age_s = max_age_s

    # -- what happened --------------------------------------------------------

    def request_count(self) -> Int:
        return self._requests

    def decisions(self) -> List[DecisionRecord]:
        return self._decisions.copy()

    def last_reason(self) -> String:
        return self._last_reason

    # -- the endpoint ---------------------------------------------------------

    def handle(
        mut self,
        method: String,
        path: String,
        authorization: Optional[String],
        body: List[UInt8],
    ) -> PdpReply:
        """Answers one request (module header). Never raises."""
        self._requests += 1
        var reply = self._answer(method, path, authorization, body)
        self._last_reason = reply.reason
        return reply^

    def _answer(
        mut self,
        method: String,
        path: String,
        authorization: Optional[String],
        body: List[UInt8],
    ) -> PdpReply:
        var batch: Bool
        if path == PATH_EVALUATION:
            batch = False
        elif path == PATH_EVALUATIONS:
            batch = True
        else:
            return _error_reply(404, REASON_NOT_FOUND)
        if method != "POST":
            return _error_reply(405, REASON_METHOD)

        # The bearer: the asking service's client token.
        var got = bearer_token(authorization)
        if got.kind == BEARER_ABSENT:
            return _error_reply(401, REASON_BEARER_MISSING, String("Bearer"))
        if got.kind == BEARER_MALFORMED:
            return _error_reply(
                400,
                REASON_BEARER_MALFORMED,
                String('Bearer error="invalid_request"'),
            )
        var invalid_token = String('Bearer error="invalid_token"')
        var bearer = self.verifier.verify(got.token, self.now_s)
        if not bearer:
            return _error_reply(401, REASON_BEARER_INVALID, invalid_token)
        if bearer.value().aud != self.audience:
            return _error_reply(401, REASON_BEARER_AUDIENCE, invalid_token)
        if bearer.value().client_id.byte_length() == 0:
            return _error_reply(401, REASON_BEARER_NO_CLIENT_ID, invalid_token)

        if len(body) > MAX_BODY_BYTES:
            return _error_reply(413, REASON_BODY_TOO_LARGE)
        var parsed = parse_evaluations(body) if batch else parse_evaluation(
            body
        )
        if parsed.reason.byte_length() != 0:
            return _error_reply(400, parsed.reason)
        ref req = parsed.request

        # The safety conditions: the subject comes only from the token.
        var subject_token = self.verifier.verify(req.subject_token, self.now_s)
        if not subject_token:
            return _error_reply(403, REASON_SUBJECT_TOKEN_INVALID)
        var token = subject_token.value().copy()
        if req.subject_type != token.subject_type:
            return _error_reply(403, REASON_SUBJECT_TYPE_MISMATCH)
        var subject = token.sub
        if req.subject_id != subject:
            return _error_reply(403, REASON_SUBJECT_MISMATCH)
        if token.aud != req.audience:
            return _error_reply(403, REASON_AUDIENCE_MISMATCH)
        if req.audience != bearer.value().client_id:
            return _error_reply(403, REASON_CLIENT_MISMATCH)

        return self._decide(token.subject_type, subject, req, batch)

    def _decide(
        mut self,
        subject_type: String,
        subject: String,
        req: EvalRequest,
        batch: Bool,
    ) -> PdpReply:
        var action = req.action
        if not self._known(self._actions, action):
            action = STRICTEST_ACTION
        var items = JsonValue.empty_array()
        var single = JsonValue.empty_object()
        try:
            for i in range(len(req.resources)):
                ref r = req.resources[i]
                # An undeclared type never matches: `allow` refuses a rule
                # that names one.
                var allowed = self._holds(
                    PolicyRule(subject_type, subject, action, r.type, r.id)
                )
                self._decisions.append(
                    DecisionRecord(
                        subject_type, subject, req.action, r.type, r.id, allowed
                    )
                )
                var one = JsonValue.empty_object()
                one.set_member(String("decision"), JsonValue.from_bool(allowed))
                if self._max_age_s >= 0:
                    var ctx = JsonValue.empty_object()
                    ctx.set_member(
                        String("max_age_s"),
                        JsonValue.from_i64(Int64(self._max_age_s)),
                    )
                    one.set_member(String("context"), ctx^)
                if batch:
                    items.push(one^)
                else:
                    single = one^
            if batch:
                var out = JsonValue.empty_object()
                out.set_member(String("evaluations"), items^)
                single = out^
        except:
            pass
        return PdpReply(
            200,
            single.serialize(),
            REASON_DECIDED,
            cache_control=CACHE_CONTROL_NO_STORE,
        )

    def _holds(self, rule: PolicyRule) -> Bool:
        for i in range(len(self._rules)):
            if self._rules[i] == rule:
                return True
        return False

    @staticmethod
    def _known(names: List[String], name: String) -> Bool:
        for i in range(len(names)):
            if names[i] == name:
                return True
        return False
