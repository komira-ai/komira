# =============================================================================
# komira_test_pdp/scenarios.mojo: the scenario table any decision point that
#   claims the komira profile of AuthZEN 1.0 must pass.
# =============================================================================
#
# THE FIXTURE. One decision point, audience `FIXTURE_PDP_AUDIENCE`; two
# services, `notes` and `files` (their client ids are their audiences);
# two users, `alice` and `bob`. `fixture_tokens()` lists the tokens an issuer
# must mint for it, by name, with their claims (`expires_in_s` is relative to
# the decision point's clock: -1 is already expired). `fixture_kinds()`,
# `fixture_actions()` and `fixture_rules()` are the policy to load.
#
# THE TABLE. `pdp_scenarios()`: each scenario starts from a freshly loaded
# fixture and runs its steps in order. A step either changes the policy
# (`STEP_ALLOW`, `STEP_REVOKE`) or sends one request (`STEP_REQUEST`) and
# states the answer: the status and, for a 200, the decisions in order
# (one for `/access/v1/evaluation`, one per item for the batch). Request
# bodies and `Authorization` values are templates: `<<name>>` stands for
# the token the issuer minted under `name`.
#
# `want_reason` is this package's reason code (reasons.mojo). Only
# `TestPdp` reports one; a run against another decision point checks status
# and decisions alone (`run_scenario`'s `check_reasons`).
#
# THE RUNNER. `run_scenario[P: PdpEndpoint](pdp, scenario, tokens,
# check_reasons)` drives any decision point through the `PdpEndpoint` trait
# and returns "" or a description of every mismatch. `run_on_test_pdp`
# builds a `TestPdp` over a `TokenTable` holding the fixture tokens (each
# token is `tok.<name>`) and runs one scenario on it.
# =============================================================================

from komira_json import write_json_string

from komira_test_pdp.pdp import PATH_EVALUATION, PolicyRule
from komira_test_pdp.reasons import REASON_DECIDED
from komira_test_pdp.tokens import SUBJECT_TYPE_CLIENT, SUBJECT_TYPE_USER

comptime FIXTURE_PDP_AUDIENCE: String = "pdp"
comptime FIXTURE_NOW_S: Int64 = 1_900_000_000
comptime FIXTURE_KIND: String = "note"
comptime FIXTURE_VERB: String = "notes.share"

comptime STEP_REQUEST = 0
comptime STEP_ALLOW = 1
comptime STEP_REVOKE = 2


@fieldwise_init
struct FixtureToken(Copyable, Movable):
    """A token the issuer mints for the fixture, named `name`."""

    var name: String
    var subject_type: String
    var sub: String
    var aud: String
    var client_id: String
    var expires_in_s: Int64


def fixture_tokens() -> List[FixtureToken]:
    var u = SUBJECT_TYPE_USER
    var c = SUBJECT_TYPE_CLIENT
    var pdp = FIXTURE_PDP_AUDIENCE
    var out = List[FixtureToken]()
    # Bearers: the asking services' client tokens for the decision point.
    out.append(FixtureToken("notes_client", c, "notes", pdp, "notes", 300))
    out.append(FixtureToken("files_client", c, "files", pdp, "files", 300))
    out.append(FixtureToken("notes_client_for_files", c, "notes", "files", "notes", 300))
    out.append(FixtureToken("notes_client_no_client_id", c, "notes", pdp, "", 300))
    out.append(FixtureToken("notes_client_expired", c, "notes", pdp, "notes", -1))
    # Subject tokens: what reached the asking service.
    out.append(FixtureToken("alice_notes", u, "alice", "notes", "web", 300))
    out.append(FixtureToken("bob_notes", u, "bob", "notes", "web", 300))
    out.append(FixtureToken("alice_files", u, "alice", "files", "web", 300))
    out.append(FixtureToken("alice_notes_expired", u, "alice", "notes", "web", -1))
    out.append(FixtureToken("files_client_for_notes", c, "files", "notes", "files", 300))
    return out^


def fixture_kinds() -> List[String]:
    var out = List[String]()
    out.append(FIXTURE_KIND)
    return out^


def fixture_actions() -> List[String]:
    """Declared beyond read, write, delete and admin."""
    var out = List[String]()
    out.append(FIXTURE_VERB)
    return out^


def fixture_rules() -> List[PolicyRule]:
    var u = SUBJECT_TYPE_USER
    var k = FIXTURE_KIND
    var out = List[PolicyRule]()
    out.append(PolicyRule(u, "alice", "read", k, "n1"))
    out.append(PolicyRule(u, "alice", "write", k, "n1"))
    out.append(PolicyRule(u, "alice", "admin", k, "n2"))
    out.append(PolicyRule(u, "alice", FIXTURE_VERB, k, "n1"))
    out.append(PolicyRule(SUBJECT_TYPE_CLIENT, "files", "read", k, "n1"))
    return out^


struct PdpStep(Copyable, Movable):
    """One step (module header). For STEP_REQUEST: `send_authorization`
    false means no `Authorization` header at all."""

    var op: Int
    var method: String
    var path: String
    var send_authorization: Bool
    var authorization: String
    var body: String
    var rule: PolicyRule
    var want_status: Int
    var want_decisions: List[Bool]
    var want_reason: String

    def __init__(
        out self,
        op: Int,
        var rule: PolicyRule,
    ):
        self.op = op
        self.method = String("")
        self.path = String("")
        self.send_authorization = False
        self.authorization = String("")
        self.body = String("")
        self.rule = rule^
        self.want_status = 0
        self.want_decisions = List[Bool]()
        self.want_reason = String("")

    def __init__(
        out self,
        *,
        var method: String,
        var path: String,
        send_authorization: Bool,
        var authorization: String,
        var body: String,
        want_status: Int,
        var want_decisions: List[Bool],
        var want_reason: String,
    ):
        self.op = STEP_REQUEST
        self.method = method^
        self.path = path^
        self.send_authorization = send_authorization
        self.authorization = authorization^
        self.body = body^
        self.rule = PolicyRule("", "", "", "", "")
        self.want_status = want_status
        self.want_decisions = want_decisions^
        self.want_reason = want_reason^


@fieldwise_init
struct PdpScenario(Copyable, Movable):
    var name: String
    var steps: List[PdpStep]


# -- builders -----------------------------------------------------------------


def json_text(s: String) -> String:
    """`s` as a JSON string literal."""
    var buf = List[UInt8]()
    write_json_string(buf, s)
    return String(unsafe_from_utf8=Span(buf))


def subject_json(subject_type: String, id: String, token_name: String) -> String:
    return (
        String('{"type":')
        + json_text(subject_type)
        + ',"id":'
        + json_text(id)
        + ',"properties":{"token":"<<'
        + token_name
        + '>>"}}'
    )


def resource_json(kind: String, id: String) -> String:
    return String('{"type":') + json_text(kind) + ',"id":' + json_text(id) + "}"


def evaluation_json(
    subject_type: String,
    subject_id: String,
    token_name: String,
    action: String,
    kind: String,
    id: String,
    audience: String,
) -> String:
    """One evaluation body in the profile's shape."""
    return (
        String('{"subject":')
        + subject_json(subject_type, subject_id, token_name)
        + ',"action":{"name":'
        + json_text(action)
        + '},"resource":'
        + resource_json(kind, id)
        + ',"context":{"audience":'
        + json_text(audience)
        + "}}"
    )


def batch_json(
    subject_type: String,
    subject_id: String,
    token_name: String,
    action: String,
    ids: List[String],
    audience: String,
) -> String:
    """A batch body over `FIXTURE_KIND` resources `ids`, in order."""
    var items = String("")
    for i in range(len(ids)):
        if i > 0:
            items += ","
        items += String('{"resource":') + resource_json(FIXTURE_KIND, ids[i]) + "}"
    return (
        String('{"subject":')
        + subject_json(subject_type, subject_id, token_name)
        + ',"action":{"name":'
        + json_text(action)
        + '},"context":{"audience":'
        + json_text(audience)
        + '},"evaluations":['
        + items
        + "]}"
    )


def request(
    bearer_name: String,
    var body: String,
    want_status: Int,
    var want_decisions: List[Bool],
    var want_reason: String,
    *,
    var path: String = PATH_EVALUATION,
) -> PdpStep:
    """A POST with `Authorization: Bearer <<bearer_name>>` ("" sends no
    header)."""
    var send = bearer_name.byte_length() != 0
    return PdpStep(
        method=String("POST"),
        path=path^,
        send_authorization=send,
        authorization=String("Bearer <<") + bearer_name + ">>",
        body=body^,
        want_status=want_status,
        want_decisions=want_decisions^,
        want_reason=want_reason^,
    )


def decided(decision: Bool) -> List[Bool]:
    var out = List[Bool]()
    out.append(decision)
    return out^


def refused() -> List[Bool]:
    return List[Bool]()


def ask(
    subject_name: String,
    subject_id: String,
    action: String,
    id: String,
    want: Bool,
) -> PdpStep:
    """`notes` asks about user `subject_id` (token `subject_name`) doing
    `action` on note `id`, and expects a 200 with decision `want`."""
    return request(
        "notes_client",
        evaluation_json(
            SUBJECT_TYPE_USER, subject_id, subject_name, action, FIXTURE_KIND, id, "notes"
        ),
        200,
        decided(want),
        REASON_DECIDED,
    )
