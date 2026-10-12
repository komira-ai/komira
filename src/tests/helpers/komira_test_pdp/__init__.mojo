"""`komira_test_pdp`: an in-process AuthZEN 1.0 decision point for tests, and
the scenario table every decision point in the komira profile must pass.

Test-only (no conda package). Modules:
  - tokens.mojo    : `TokenVerifier`, `VerifiedToken`, and `TokenTable`, the
                     verifier over the tokens an issuer handed out.
  - pdp.mojo       : `TestPdp[V]`, the endpoint (`POST /access/v1/evaluation`
                     and `/access/v1/evaluations`) over an in-memory policy
                     table (`PolicyRule`, `allow`, `revoke`); `PdpReply`;
                     the `PdpEndpoint` trait a scenario drives.
  - request.mojo   : the request shape (`parse_evaluation`,
                     `parse_evaluations`).
  - reasons.mojo   : the reason code of every answer.
  - scenarios.mojo : the fixture (tokens, kinds, actions, rules), the step
                     shape and its builders.
  - table.mojo     : `pdp_scenarios()`, the table.
  - runner.mojo    : `run_scenario[P]`, `fixture_test_pdp()`,
                     `run_on_test_pdp`.
  - near_miss.mojo : `near_misses(s)`, the values an exact comparison must
                     refuse (for this package's tests and its users').

The public API holds owned values only; no pointers.
"""

from .tokens import (
    SUBJECT_TYPE_CLIENT,
    SUBJECT_TYPE_USER,
    TokenTable,
    TokenVerifier,
    VerifiedToken,
)
from .reasons import (
    REASON_ACTION_INVALID,
    REASON_AUDIENCE_MISMATCH,
    REASON_BATCH_INVALID,
    REASON_BEARER_AUDIENCE,
    REASON_BEARER_INVALID,
    REASON_BEARER_MALFORMED,
    REASON_BEARER_MISSING,
    REASON_BEARER_NO_CLIENT_ID,
    REASON_BODY_NOT_JSON,
    REASON_BODY_TOO_LARGE,
    REASON_CLIENT_MISMATCH,
    REASON_CONTEXT_INVALID,
    REASON_DECIDED,
    REASON_DUPLICATE_MEMBER,
    REASON_METHOD,
    REASON_NOT_FOUND,
    REASON_RESOURCE_INVALID,
    REASON_SUBJECT_INVALID,
    REASON_SUBJECT_MISMATCH,
    REASON_SUBJECT_TOKEN_INVALID,
    REASON_SUBJECT_TYPE_MISMATCH,
)
from .request import (
    MAX_BATCH_ITEMS,
    MAX_RESOURCE_ID_BYTES,
    EvalRequest,
    EvalResource,
    ParseOutcome,
    parse_evaluation,
    parse_evaluations,
)
from .pdp import (
    BEARER_ABSENT,
    BEARER_MALFORMED,
    BEARER_PRESENT,
    CACHE_CONTROL_NO_STORE,
    MAX_BODY_BYTES,
    PATH_EVALUATION,
    PATH_EVALUATIONS,
    STRICTEST_ACTION,
    BearerCredential,
    DecisionRecord,
    PdpEndpoint,
    PdpReply,
    PolicyRule,
    TestPdp,
    base_actions,
    bearer_token,
)
from .scenarios import (
    FIXTURE_KIND,
    FIXTURE_NOW_S,
    FIXTURE_PDP_AUDIENCE,
    FIXTURE_VERB,
    STEP_ALLOW,
    STEP_REQUEST,
    STEP_REVOKE,
    FixtureToken,
    PdpScenario,
    PdpStep,
    batch_json,
    evaluation_json,
    fixture_actions,
    fixture_kinds,
    fixture_rules,
    fixture_tokens,
    json_text,
)
from .table import pdp_scenarios
from .near_miss import near_misses
from .runner import (
    NEVER_ISSUED,
    NamedToken,
    fixture_named_tokens,
    fixture_test_pdp,
    fixture_token,
    read_decisions,
    resolve_template,
    run_on_test_pdp,
    run_scenario,
)
