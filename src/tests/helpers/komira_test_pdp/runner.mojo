# =============================================================================
# komira_test_pdp/runner.mojo: running the scenario table against a decision
#   point.
# =============================================================================
#
# `run_scenario[P]` drives any `PdpEndpoint`. The caller supplies the tokens
# the issuer minted for the fixture as `NamedToken`s: every name a template
# uses must be there, including the names no issuer mints (`never_issued`,
# which must be a well-formed token the decision point has never seen). A
# template naming a token the caller did not supply is reported, not
# guessed.
#
# Per request step it checks, and reports every mismatch:
#   - the status;
#   - on a 200: `Cache-Control: no-store`, and the decisions read from the
#     body with komira_json (a top-level JSON boolean `decision`; for the
#     batch, a top-level `evaluations` array of objects with one each), in
#     order and of the stated count;
#   - that neither the body nor a header holds any token the step sent;
#   - with `check_reasons`, the reason code (`TestPdp` only).
#
# `fixture_test_pdp()` is a `TestPdp` over a `TokenTable` with the fixture
# loaded (token `<name>` is `fixture_token(name)`); other packages' tests can
# use it as a ready decision point. `run_on_test_pdp` runs one scenario on a
# fresh one.
# =============================================================================

from komira_json import JSON_ARRAY, JSON_BOOL, JSON_OBJECT, JsonValue
from komira_json import parse_json_value

from komira_test_pdp.pdp import PdpEndpoint, PdpReply, TestPdp
from komira_test_pdp.scenarios import (
    FIXTURE_NOW_S,
    FIXTURE_PDP_AUDIENCE,
    STEP_ALLOW,
    STEP_REQUEST,
    STEP_REVOKE,
    PdpScenario,
    PdpStep,
    fixture_actions,
    fixture_kinds,
    fixture_rules,
    fixture_tokens,
)
from komira_test_pdp.tokens import TokenTable, VerifiedToken

comptime NEVER_ISSUED: String = "never_issued"


@fieldwise_init
struct NamedToken(Copyable, Movable):
    var name: String
    var token: String


def fixture_token(name: String) -> String:
    """The token `TokenTable` holds for fixture token `name`."""
    return String("tok.") + name


def fixture_named_tokens() -> List[NamedToken]:
    """Every fixture token, plus `never_issued`, as the test decision point
    sees them."""
    var out = List[NamedToken]()
    var tokens = fixture_tokens()
    for i in range(len(tokens)):
        out.append(NamedToken(tokens[i].name, fixture_token(tokens[i].name)))
    out.append(NamedToken(NEVER_ISSUED, fixture_token(NEVER_ISSUED)))
    return out^


def fixture_test_pdp() raises -> TestPdp[TokenTable]:
    """A `TestPdp` with the fixture loaded, its clock at `FIXTURE_NOW_S`."""
    var table = TokenTable()
    var tokens = fixture_tokens()
    for i in range(len(tokens)):
        ref t = tokens[i]
        table.add(
            fixture_token(t.name),
            VerifiedToken(
                t.subject_type, t.sub, t.aud, t.client_id, FIXTURE_NOW_S + t.expires_in_s
            ),
        )
    var pdp = TestPdp(table^, FIXTURE_PDP_AUDIENCE, FIXTURE_NOW_S)
    var kinds = fixture_kinds()
    for i in range(len(kinds)):
        pdp.declare_kind(kinds[i])
    var actions = fixture_actions()
    for i in range(len(actions)):
        pdp.declare_action(actions[i])
    var rules = fixture_rules()
    for i in range(len(rules)):
        pdp.allow(rules[i])
    return pdp^


def resolve_template(template: String, tokens: List[NamedToken]) raises -> String:
    """`template` with every `<<name>>` replaced by that token. Raises naming
    the first name `tokens` does not hold, or on an unclosed `<<`."""
    var out = String("")
    var rest = template
    while True:
        var open = rest.find("<<")
        if open < 0:
            out += rest
            return out^
        var close = rest.find(">>", open + 2)
        if close < 0:
            raise Error("unclosed <<name>> in a template")
        var name = String(rest[byte = open + 2 : close])
        var found = False
        for i in range(len(tokens)):
            if tokens[i].name == name:
                out += String(rest[byte=0:open]) + tokens[i].token
                found = True
                break
        if not found:
            raise Error(String("no token supplied for <<") + name + ">>")
        var after = String(rest[byte = close + 2 :])
        rest = after^


def read_decisions(body: String, batch: Bool) -> Optional[List[Bool]]:
    """The decisions in a 200 body, or None when it does not hold them as
    the profile says (module header)."""
    try:
        var root = parse_json_value(body)
        if root.kind_tag() != JSON_OBJECT:
            return None
        var out = List[Bool]()
        if not batch:
            if not root.has("decision"):
                return None
            var d = root.get("decision")
            if d.kind_tag() != JSON_BOOL:
                return None
            out.append(d.as_bool())
            return out^
        if not root.has("evaluations"):
            return None
        var items = root.get("evaluations")
        if items.kind_tag() != JSON_ARRAY:
            return None
        for i in range(items.array_len()):
            var item = items.element_at(i)
            if item.kind_tag() != JSON_OBJECT or not item.has("decision"):
                return None
            var d = item.get("decision")
            if d.kind_tag() != JSON_BOOL:
                return None
            out.append(d.as_bool())
        return out^
    except:
        return None


def _bools_text(b: List[Bool]) -> String:
    var s = String("[")
    for i in range(len(b)):
        if i > 0:
            s += ","
        s += "true" if b[i] else "false"
    return s + "]"


def _leaks(reply: PdpReply, sent: List[String]) -> Bool:
    for i in range(len(sent)):
        ref t = sent[i]
        if t.byte_length() == 0:
            continue
        if (
            reply.body.find(t) >= 0
            or reply.www_authenticate.find(t) >= 0
            or reply.cache_control.find(t) >= 0
        ):
            return True
    return False


def _check_reply(
    reply: PdpReply, step: PdpStep, batch: Bool, check_reasons: Bool
) -> String:
    var fail = String("")
    if reply.status != step.want_status:
        fail += String(" status ") + String(reply.status) + " want " + String(step.want_status) + ";"
    if check_reasons and reply.reason != step.want_reason:
        fail += String(" reason ") + reply.reason + " want " + step.want_reason + ";"
    if reply.status == 200 and step.want_status == 200:
        if reply.cache_control != "no-store":
            fail += " no Cache-Control: no-store;"
        var got = read_decisions(reply.body, batch)
        if not got:
            fail += " unreadable decision body;"
        else:
            var g = got.value().copy()
            var same = len(g) == len(step.want_decisions)
            if same:
                for i in range(len(g)):
                    if g[i] != step.want_decisions[i]:
                        same = False
            if not same:
                fail += String(" decisions ") + _bools_text(g) + " want " + _bools_text(step.want_decisions) + ";"
    return fail^


def run_scenario[P: PdpEndpoint](
    mut pdp: P,
    scenario: PdpScenario,
    tokens: List[NamedToken],
    check_reasons: Bool,
) -> String:
    """Runs `scenario` on `pdp`; "" when every step answered as stated, else
    one line per mismatching step (module header)."""
    var report = String("")
    for i in range(len(scenario.steps)):
        ref step = scenario.steps[i]
        var where = scenario.name + " step " + String(i) + ":"
        try:
            if step.op == STEP_ALLOW:
                pdp.allow(step.rule)
                continue
            if step.op == STEP_REVOKE:
                if not pdp.revoke(step.rule):
                    report += where + " revoke found no rule\n"
                continue
            var body = resolve_template(step.body, tokens)
            var authorization = Optional[String](None)
            var sent = List[String]()
            for j in range(len(tokens)):
                if step.body.find(String("<<") + tokens[j].name + ">>") >= 0:
                    sent.append(tokens[j].token)
            if step.send_authorization:
                authorization = resolve_template(step.authorization, tokens)
                for j in range(len(tokens)):
                    if step.authorization.find(String("<<") + tokens[j].name + ">>") >= 0:
                        sent.append(tokens[j].token)
            var bytes = List[UInt8]()
            bytes.extend(Span(body.as_bytes()))
            var reply = pdp.handle(step.method, step.path, authorization, bytes)
            var batch = step.path.endswith("/evaluations")
            var fail = _check_reply(reply, step, batch, check_reasons)
            if _leaks(reply, sent):
                fail += " a token in the reply;"
            if fail.byte_length() != 0:
                report += where + fail + "\n"
        except e:
            report += where + " " + String(e) + "\n"
    return report^


def run_on_test_pdp(scenario: PdpScenario) -> String:
    """`scenario` on a fresh `fixture_test_pdp()`, reasons checked."""
    try:
        var pdp = fixture_test_pdp()
        return run_scenario(pdp, scenario, fixture_named_tokens(), True)
    except e:
        return scenario.name + ": fixture: " + String(e) + "\n"
