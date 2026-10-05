# =============================================================================
# test_firestore_preconditions.mojo — the Firestore ATOMIC PRECONDITION primitives
#   (create_if_absent / update_if_unchanged) FALSIFIER — the two primitives
#   every atomic store over Firestore needs.
# =============================================================================
#
# WHAT THIS PROVES. A bare PATCH upsert carries no server-side precondition.
# An intent ledger's atomicity (a partial-UNIQUE index that ATOMICALLY rejects a
# second live INSERT) has NO port to a bare upsert — it needs Firestore's
# server-side PRECONDITION on a Commit write. This file falsifies the two
# primitives that carry that atomicity:
#
#   (a) create_if_absent(collection, doc_id, fields) — a `:commit` write carrying
#       `currentDocument: {"exists": false}`. It SUCCEEDS iff the doc does not
#       exist; a second create for the same id FAILS with a typed ALREADY_EXISTS
#       conflict (HTTP 409). This is the atomic conditional-create — the exact
#       analog of the partial-UNIQUE index's atomic INSERT-reject.
#   (b) update_if_unchanged(collection, doc_id, fields, expected_update_time) — a
#       `:commit` write carrying `currentDocument: {"updateTime": "<t>"}`. It
#       SUCCEEDS iff the doc's current updateTime equals `<t>`; a stale-updateTime
#       write FAILS with a typed PRECONDITION_FAILED conflict (HTTP 400/409). This
#       is single-doc optimistic version-CAS.
#
# THE MAPPING (asserted here on the request the generated client writes):
#   POST /v1/projects/{p}/databases/{db}/documents:commit
#   body {"database":..,"writes":[{..,"currentDocument":{"exists":false},
#         "update":{"name":"<full doc path>","fields":{..}}}],..}
#   -> 200 {"writeResults":[{"updateTime":".."}],"commitTime":".."}   (SUCCESS)
#   -> 409 {"error":{"code":409,"status":"ALREADY_EXISTS",..}}        (create conflict)
#   -> 400 {"error":{"code":400,"status":"FAILED_PRECONDITION",..}}   (updateTime conflict)
#
# The conflict is proven BEHAVIORALLY over a ScriptedFirestore (canned HTTP
# answers per request, ZERO sockets, ZERO network): the test queues the
# server's 409 / 400 and asserts the client maps it to the TYPED conflict (a
# caller branches on it), NOT a generic raise. The server-side atomicity itself
# is Firestore's guarantee; here we prove the CLIENT correctly USES the
# precondition and correctly CLASSIFIES the conflict, by its google.rpc.Code.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_gcp_firestore.firestore_value import (
    FsValue,
    FS_T_STRING,
    FS_T_INTEGER,
)
from komira_http_core.transport.scripted import ScriptedConnector
from komira_gcp_firestore.firestore_scripted import ScriptedFirestore
from komira_gcp_firestore.firestore_client import (
    FirestoreClient,
    FirestoreCommitResult,
    is_already_exists_error,
    is_precondition_failed_error,
)


comptime _PROJECT: String = "example-project"
comptime _DATABASE: String = "(default)"
comptime _BEARER: String = "ya29.test-access-token"


def _client(
    mut script: ScriptedFirestore,
) raises -> FirestoreClient[ScriptedConnector]:
    return FirestoreClient[ScriptedConnector](
        script.take_connector(), String(_PROJECT), String(_DATABASE), String(_BEARER)
    )


def _intent_fields(var row_id: String, var status: String) -> FsValue:
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("row_id"))
    vals.append(FsValue.string(row_id^))
    keys.append(String("status"))
    vals.append(FsValue.string(status^))
    return FsValue.map_of(keys^, vals^)


def _commit_ok(update_time: String) -> String:
    """A Firestore `:commit` success response echoing one write's updateTime."""
    var out = String("{")
    out += '"writeResults":[{"updateTime":"'
    out += update_time
    out += '"}],"commitTime":"'
    out += update_time
    out += '"}'
    return out^


def _error_envelope(code: Int, status: String, message: String) -> String:
    var out = String("{")
    out += '"error":{"code":'
    out += String(code)
    out += ',"status":"'
    out += status
    out += '","message":"'
    out += message
    out += '"}}'
    return out^


# =============================================================================
# (a) create_if_absent — SUCCESS builds the `:commit` write with
#     currentDocument.exists=false, and returns the write's updateTime.
# =============================================================================
def test_create_if_absent_success_builds_exists_false_precondition() raises:
    var t = ScriptedFirestore()
    t.queue_response(200, _commit_ok(String("2026-10-01T00:00:01.5Z")))
    var client = _client(t)

    var res = client.create_if_absent(
        String("resource_intent"),
        String("env__region__svc"),
        _intent_fields(String("row-abc"), String("PROVISIONING")),
    )
    assert_equal(res.update_time, String("2026-10-01T00:00:01.500Z"))

    # The op issued a POST to :commit with the currentDocument.exists=false
    # precondition and the full document path in the write.
    assert_equal(t.call_method(0), String("POST"))
    assert_equal(
        t.call_path(0),
        String(
            "/v1/projects/example-project/databases/%28default%29/documents:commit"
        ),
    )
    var body = t.call_body(0)
    assert_true(
        _contains(body, String('"currentDocument":{"exists":false}')),
        msg="create_if_absent MUST carry currentDocument.exists=false",
    )
    assert_true(
        _contains(
            body,
            String(
                'projects/example-project/databases/(default)/documents/'
                "resource_intent/env__region__svc"
            ),
        ),
        msg="the write's `update.name` MUST be the full doc path (doc-id = key)",
    )
    assert_true(
        _contains(body, String('"stringValue":"PROVISIONING"')),
        msg="the write carries the serialized fields",
    )


# =============================================================================
# (a') create_if_absent — a 409 ALREADY_EXISTS maps to the TYPED conflict, NOT a
#      generic raise. A caller branches on it (re-read + adopt).
# =============================================================================
def test_create_if_absent_conflict_is_typed_already_exists() raises:
    var t = ScriptedFirestore()
    t.queue_response(
        409,
        _error_envelope(
            409,
            String("ALREADY_EXISTS"),
            String("entity already exists: ..."),
        ),
    )
    var client = _client(t)

    var raised_already_exists = False
    var raised_other = False
    try:
        var _res = client.create_if_absent(
            String("resource_intent"),
            String("env__region__svc"),
            _intent_fields(String("row-def"), String("PROVISIONING")),
        )
    except e:
        if is_already_exists_error(String(e)):
            raised_already_exists = True
        else:
            raised_other = True
    assert_true(
        raised_already_exists,
        msg="a 409 ALREADY_EXISTS MUST map to the typed already-exists conflict",
    )
    assert_false(
        raised_other, msg="it must NOT be a generic/unclassified raise"
    )


# =============================================================================
# (b) update_if_unchanged — SUCCESS builds the `:commit` write with
#     currentDocument.updateTime=<t>, returns the new write's updateTime.
# =============================================================================
def test_update_if_unchanged_success_builds_update_time_precondition() raises:
    var t = ScriptedFirestore()
    t.queue_response(200, _commit_ok(String("2026-10-01T00:00:09.0Z")))
    var client = _client(t)

    var res = client.update_if_unchanged(
        String("resource_intent"),
        String("env__region__svc"),
        _intent_fields(String("row-abc"), String("ACTIVE")),
        String("2026-10-01T00:00:01.5Z"),  # expected current updateTime
    )
    assert_equal(res.update_time, String("2026-10-01T00:00:09Z"))
    assert_equal(t.call_method(0), String("POST"))
    assert_equal(
        t.call_path(0),
        String(
            "/v1/projects/example-project/databases/%28default%29/documents:commit"
        ),
    )
    var body = t.call_body(0)
    assert_true(
        _contains(
            body,
            String(
                '"currentDocument":{"updateTime":"2026-10-01T00:00:01.500Z"}'
            ),
        ),
        msg="update_if_unchanged MUST carry currentDocument.updateTime=<t>",
    )
    assert_true(
        _contains(body, String('"stringValue":"ACTIVE"')),
        msg="the write carries the new fields",
    )


# =============================================================================
# (b') update_if_unchanged — a 400 FAILED_PRECONDITION maps to the TYPED
#      precondition-failed conflict (a stale version-CAS loser), NOT a generic raise.
# =============================================================================
def test_update_if_unchanged_conflict_is_typed_precondition_failed() raises:
    var t = ScriptedFirestore()
    t.queue_response(
        400,
        _error_envelope(
            400,
            String("FAILED_PRECONDITION"),
            String("the stored version does not match the required base version"),
        ),
    )
    var client = _client(t)

    var raised_precondition = False
    var raised_other = False
    try:
        var _res = client.update_if_unchanged(
            String("resource_intent"),
            String("env__region__svc"),
            _intent_fields(String("row-abc"), String("ACTIVE")),
            String("2026-10-01T00:00:01.5Z"),  # STALE — the doc moved on
        )
    except e:
        if is_precondition_failed_error(String(e)):
            raised_precondition = True
        else:
            raised_other = True
    assert_true(
        raised_precondition,
        msg="a 400 FAILED_PRECONDITION MUST map to the typed precondition-failed"
        " conflict (the version-CAS loser)",
    )
    assert_false(
        raised_other, msg="it must NOT be a generic/unclassified raise"
    )


# =============================================================================
# (b'') REGRESSION GUARD — a 400 INVALID_ARGUMENT is NOT a CAS loss.
#
# BUG CLASS: mis-typed conflict. Firestore answers HTTP 400 for BOTH
# `FAILED_PRECONDITION` (the updateTime CAS lost) and `INVALID_ARGUMENT` (the write
# itself was refused — malformed value, bad precondition timestamp, size limit).
# A classifier that accepts `FAILED_PRECONDITION or HTTP 400` types BOTH as the
# precondition conflict. That verdict
# is benign all the way up the stack: `FirestoreDatabase._cas_write` maps it to
# False -> `conditional_update` returns 0 rows -> a store's version-checked
# transition re-reads a row nothing wrote to and raises `ConcurrentModification ... expected=N actual=N`
# — a version conflict between two EQUAL versions — which every caller swallows as
# "someone else won". A permanent rejection became an invisible benign retry.
#
# The client classifies on the google.rpc.Code (FAILED_PRECONDITION), so the
# INVALID_ARGUMENT envelope stays loud. The no-token arm below pins the bound:
# a 400 with no google.rpc.Status at all still classifies as a precondition
# conflict, so the fix cannot be "delete the fallback".
# =============================================================================
def test_update_if_unchanged_invalid_argument_is_not_a_cas_loss() raises:
    var t = ScriptedFirestore()
    t.queue_response(
        400,
        _error_envelope(
            400,
            String("INVALID_ARGUMENT"),
            String("Invalid value at 'writes[0].update.fields'"),
        ),
    )
    var client = _client(t)

    var raised_precondition = False
    var raised_loud = False
    var msg = String("")
    try:
        var _res = client.update_if_unchanged(
            String("jobs"),
            String("00000000-0000-7000-8000-000000000001"),
            _intent_fields(String("row-abc"), String("RUNNING")),
            String("2026-10-01T00:00:01.5Z"),
        )
    except e:
        msg = String(e)
        if is_precondition_failed_error(msg):
            raised_precondition = True
        else:
            raised_loud = True
    assert_false(
        raised_precondition,
        msg="a 400 INVALID_ARGUMENT is a REFUSED write, NOT a lost CAS — typing it"
        " as a precondition conflict makes it a benign, swallowed signal",
    )
    assert_true(
        raised_loud,
        msg="a refused write MUST surface loudly (the caller cannot skip it)",
    )
    assert_true(
        _contains(msg, String("INVALID_ARGUMENT")),
        msg="the loud error must name the real Google status token",
    )


def test_update_if_unchanged_untokened_400_still_reads_as_precondition() raises:
    """THE BOUND on the narrowing above: when the body carries NO `error.status`
    token at all (a bodyless / non-Google 4xx) the numeric fallback survives, so an
    unlabelled 400 is still the typed precondition conflict. This is what keeps the
    fix from being "stop classifying 400s"."""
    var t = ScriptedFirestore()
    t.queue_response(400, String("<html>bad request</html>"))
    var client = _client(t)

    var raised_precondition = False
    try:
        var _res = client.update_if_unchanged(
            String("jobs"),
            String("d"),
            _intent_fields(String("r"), String("A")),
            String("2026-10-01T00:00:01.5Z"),
        )
    except e:
        raised_precondition = is_precondition_failed_error(String(e))
    assert_true(
        raised_precondition,
        msg="a 400 with NO status token keeps the numeric precondition fallback",
    )


# =============================================================================
# The two conflict classifiers are DISJOINT — an already-exists is NOT a
# precondition-failed and vice-versa (a caller branches on the right one).
# =============================================================================
def test_conflict_classifiers_are_disjoint() raises:
    var t = ScriptedFirestore()
    # A create conflict is ONLY already-exists, not precondition-failed.
    t.queue_response(
        409, _error_envelope(409, String("ALREADY_EXISTS"), String("x"))
    )
    # An updateTime conflict is ONLY precondition-failed, not already-exists.
    t.queue_response(
        400, _error_envelope(400, String("FAILED_PRECONDITION"), String("y"))
    )
    var client = _client(t)

    var create_err = String("")
    try:
        var _r = client.create_if_absent(
            String("c"), String("d"), _intent_fields(String("r"), String("P"))
        )
    except e:
        create_err = String(e)
    assert_true(is_already_exists_error(create_err))
    assert_false(is_precondition_failed_error(create_err))

    var update_err = String("")
    try:
        var _r = client.update_if_unchanged(
            String("c"),
            String("d"),
            _intent_fields(String("r"), String("A")),
            String("2026-10-01T00:00:01.5Z"),
        )
    except e:
        update_err = String(e)
    assert_true(is_precondition_failed_error(update_err))
    assert_false(is_already_exists_error(update_err))


# ---- a tiny substring helper (no general search dep) ----
def _contains(haystack: String, needle: String) -> Bool:
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0 or len(nb) > len(hb):
        return len(nb) == 0
    for s in range(0, len(hb) - len(nb) + 1):
        var ok = True
        for j in range(len(nb)):
            if hb[s + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


def main() raises:
    test_create_if_absent_success_builds_exists_false_precondition()
    test_create_if_absent_conflict_is_typed_already_exists()
    test_update_if_unchanged_success_builds_update_time_precondition()
    test_update_if_unchanged_conflict_is_typed_precondition_failed()
    test_update_if_unchanged_invalid_argument_is_not_a_cas_loss()
    test_update_if_unchanged_untokened_400_still_reads_as_precondition()
    test_conflict_classifiers_are_disjoint()
    print("test_firestore_preconditions: ALL PASS")
