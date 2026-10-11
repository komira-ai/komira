# =============================================================================
# komira_test_pdp/table.mojo: `pdp_scenarios()`, the scenario table
#   (scenarios.mojo has the fixture, the step shape and the builders).
# =============================================================================
#
# Each scenario's name says what it proves. The safety-condition scenarios
# are built so that the decision point's two possible mistakes give
# different, wrong answers: a subject taken from the body instead of the
# token (the body names a subject that HOLDS the rule, the token one that
# does not) answers 200 true instead of 403, and a dropped comparison
# answers 200 false instead of 403.
# =============================================================================

from komira_test_pdp.pdp import PATH_EVALUATIONS, PolicyRule
from komira_test_pdp.reasons import (
    REASON_AUDIENCE_MISMATCH,
    REASON_BATCH_INVALID,
    REASON_BEARER_AUDIENCE,
    REASON_BEARER_INVALID,
    REASON_BEARER_MISSING,
    REASON_BEARER_NO_CLIENT_ID,
    REASON_BODY_NOT_JSON,
    REASON_CLIENT_MISMATCH,
    REASON_DECIDED,
    REASON_DUPLICATE_MEMBER,
    REASON_METHOD,
    REASON_NOT_FOUND,
    REASON_SUBJECT_MISMATCH,
    REASON_SUBJECT_TOKEN_INVALID,
    REASON_SUBJECT_TYPE_MISMATCH,
)
from komira_test_pdp.scenarios import (
    FIXTURE_KIND,
    FIXTURE_VERB,
    STEP_ALLOW,
    STEP_REVOKE,
    PdpScenario,
    PdpStep,
    ask,
    batch_json,
    decided,
    evaluation_json,
    refused,
    request,
)
from komira_test_pdp.tokens import SUBJECT_TYPE_CLIENT, SUBJECT_TYPE_USER


def _one(name: String, var step: PdpStep) -> PdpScenario:
    var steps = List[PdpStep]()
    steps.append(step^)
    return PdpScenario(name, steps^)


def _alice_read_n1(
    bearer: String,
    subject_type: String,
    subject_id: String,
    token_name: String,
    audience: String,
    want_status: Int,
    var want_reason: String,
) -> PdpStep:
    """`read` on note n1 (alice holds it), with every part of the request
    chosen by the caller; a 200 is expected to be true."""
    var want = decided(True) if want_status == 200 else refused()
    return request(
        bearer,
        evaluation_json(
            subject_type, subject_id, token_name, "read", FIXTURE_KIND, "n1", audience
        ),
        want_status,
        want^,
        want_reason^,
    )


def _ids(a: String, b: String, c: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    out.append(c)
    return out^


def _bools(a: Bool, b: Bool, c: Bool) -> List[Bool]:
    var out = List[Bool]()
    out.append(a)
    out.append(b)
    out.append(c)
    return out^


def pdp_scenarios() -> List[PdpScenario]:
    var u = SUBJECT_TYPE_USER
    var c = SUBJECT_TYPE_CLIENT
    var out = List[PdpScenario]()

    # -- decisions ------------------------------------------------------------
    out.append(_one("a held rule is an allow", ask("alice_notes", "alice", "read", "n1", True)))
    out.append(_one("an action without a rule is a deny", ask("alice_notes", "alice", "delete", "n1", False)))
    out.append(_one("another resource id is a deny", ask("alice_notes", "alice", "read", "n3", False)))
    out.append(_one("another subject is a deny", ask("bob_notes", "bob", "read", "n1", False)))
    out.append(
        _one(
            "an undeclared resource type is a deny",
            request(
                "notes_client",
                evaluation_json(u, "alice", "alice_notes", "read", "folder", "n1", "notes"),
                200,
                decided(False),
                REASON_DECIDED,
            ),
        )
    )
    # An undeclared action is judged as admin: alice holds admin on n2 only.
    out.append(_one("an undeclared action is judged as admin (held)", ask("alice_notes", "alice", "notes.archive", "n2", True)))
    out.append(_one("an undeclared action is judged as admin (not held)", ask("alice_notes", "alice", "notes.archive", "n1", False)))
    # A declared verb is its own action, not admin: held on n1, not on n2.
    out.append(_one("a declared action is judged as itself (held)", ask("alice_notes", "alice", FIXTURE_VERB, "n1", True)))
    out.append(_one("a declared action is judged as itself (not held)", ask("alice_notes", "alice", FIXTURE_VERB, "n2", False)))
    out.append(
        _one(
            "a service subject is judged by its client token",
            _alice_read_n1("notes_client", c, "files", "files_client_for_notes", "notes", 200, REASON_DECIDED),
        )
    )

    # -- revoke ---------------------------------------------------------------
    var rule = PolicyRule(u, "alice", "read", FIXTURE_KIND, "n1")
    var steps = List[PdpStep]()
    steps.append(ask("alice_notes", "alice", "read", "n1", True))
    steps.append(PdpStep(STEP_REVOKE, rule.copy()))
    steps.append(ask("alice_notes", "alice", "read", "n1", False))
    steps.append(ask("alice_notes", "alice", "write", "n1", True))
    steps.append(PdpStep(STEP_ALLOW, rule.copy()))
    steps.append(ask("alice_notes", "alice", "read", "n1", True))
    out.append(PdpScenario("a revoke takes effect on the next request", steps^))

    # -- the safety conditions ------------------------------------------------
    # bob's token, the body naming alice (who holds the rule).
    out.append(
        _one(
            "subject mismatch is refused",
            _alice_read_n1("notes_client", u, "alice", "bob_notes", "notes", 403, REASON_SUBJECT_MISMATCH),
        )
    )
    out.append(
        _one(
            "subject type mismatch is refused",
            _alice_read_n1("notes_client", c, "alice", "alice_notes", "notes", 403, REASON_SUBJECT_TYPE_MISMATCH),
        )
    )
    out.append(
        _one(
            "a client subject named as a user is refused",
            _alice_read_n1("notes_client", u, "files", "files_client_for_notes", "notes", 403, REASON_SUBJECT_TYPE_MISMATCH),
        )
    )
    out.append(
        _one(
            "a subject token for another audience is refused",
            _alice_read_n1("notes_client", u, "alice", "alice_files", "notes", 403, REASON_AUDIENCE_MISMATCH),
        )
    )
    out.append(
        _one(
            "an audience other than the bearer's client is refused",
            _alice_read_n1("files_client", u, "alice", "alice_notes", "notes", 403, REASON_CLIENT_MISMATCH),
        )
    )
    out.append(
        _one(
            "an expired subject token is refused",
            _alice_read_n1("notes_client", u, "alice", "alice_notes_expired", "notes", 403, REASON_SUBJECT_TOKEN_INVALID),
        )
    )
    out.append(
        _one(
            "a subject token never issued is refused",
            _alice_read_n1("notes_client", u, "alice", "never_issued", "notes", 403, REASON_SUBJECT_TOKEN_INVALID),
        )
    )

    # -- the bearer -----------------------------------------------------------
    out.append(_one("no bearer is refused", _alice_read_n1("", u, "alice", "alice_notes", "notes", 401, REASON_BEARER_MISSING)))
    out.append(
        _one(
            "a bearer for another audience is refused",
            _alice_read_n1("notes_client_for_files", u, "alice", "alice_notes", "notes", 401, REASON_BEARER_AUDIENCE),
        )
    )
    out.append(
        _one(
            "a subject token as the bearer is refused",
            _alice_read_n1("alice_notes", u, "alice", "alice_notes", "notes", 401, REASON_BEARER_AUDIENCE),
        )
    )
    out.append(
        _one(
            "a bearer without a client id is refused",
            _alice_read_n1("notes_client_no_client_id", u, "alice", "alice_notes", "notes", 401, REASON_BEARER_NO_CLIENT_ID),
        )
    )
    out.append(
        _one(
            "an expired bearer is refused",
            _alice_read_n1("notes_client_expired", u, "alice", "alice_notes", "notes", 401, REASON_BEARER_INVALID),
        )
    )
    out.append(
        _one(
            "a bearer never issued is refused",
            _alice_read_n1("never_issued", u, "alice", "alice_notes", "notes", 401, REASON_BEARER_INVALID),
        )
    )

    # -- the body -------------------------------------------------------------
    out.append(_one("a body that is not JSON is refused", request("notes_client", "{", 400, refused(), REASON_BODY_NOT_JSON)))
    # The first `subject` is alice's own; the second names bob. A reader that
    # keeps either copy would answer something; the profile refuses both.
    var dup = (
        String('{"subject":{"type":"jwt_sub","id":"alice","properties":{"token":"<<alice_notes>>"}},')
        + '"subject":{"type":"jwt_sub","id":"bob","properties":{"token":"<<bob_notes>>"}},'
        + '"action":{"name":"read"},"resource":{"type":"note","id":"n1"},'
        + '"context":{"audience":"notes"}}'
    )
    out.append(_one("a repeated member is refused", request("notes_client", dup, 400, refused(), REASON_DUPLICATE_MEMBER)))

    # -- batch ----------------------------------------------------------------
    out.append(
        _one(
            "a batch answers in request order",
            request(
                "notes_client",
                batch_json(u, "alice", "alice_notes", "read", _ids("n1", "n3", "n2")^, "notes"),
                200,
                _bools(True, False, False),
                REASON_DECIDED,
                path=PATH_EVALUATIONS,
            ),
        )
    )
    out.append(
        _one(
            "batch subject mismatch is refused",
            request(
                "notes_client",
                batch_json(u, "alice", "bob_notes", "read", _ids("n1", "n1", "n1")^, "notes"),
                403,
                refused(),
                REASON_SUBJECT_MISMATCH,
                path=PATH_EVALUATIONS,
            ),
        )
    )
    var per_item = (
        String('{"subject":{"type":"jwt_sub","id":"bob","properties":{"token":"<<bob_notes>>"}},')
        + '"action":{"name":"read"},"context":{"audience":"notes"},"evaluations":['
        + '{"resource":{"type":"note","id":"n1"},'
        + '"subject":{"type":"jwt_sub","id":"alice","properties":{"token":"<<alice_notes>>"}}}]}'
    )
    out.append(
        _one(
            "a batch item with its own subject is refused",
            request("notes_client", per_item, 400, refused(), REASON_BATCH_INVALID, path=PATH_EVALUATIONS),
        )
    )

    # -- the endpoint ---------------------------------------------------------
    var get = request(
        "notes_client",
        evaluation_json(u, "alice", "alice_notes", "read", FIXTURE_KIND, "n1", "notes"),
        405,
        refused(),
        REASON_METHOD,
    )
    get.method = String("GET")
    out.append(_one("a GET is refused", get^))
    out.append(
        _one(
            "another path is not found",
            request(
                "notes_client",
                evaluation_json(u, "alice", "alice_notes", "read", FIXTURE_KIND, "n1", "notes"),
                404,
                refused(),
                REASON_NOT_FOUND,
                path=String("/access/v1/evaluation/"),
            ),
        )
    )
    return out^
