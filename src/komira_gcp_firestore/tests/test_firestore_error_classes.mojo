# =============================================================================
# test_firestore_error_classes.mojo — the typed error classes, read off the
#   google.rpc.Code and never off Google's `error.message`.
# =============================================================================
#
# Each class decides what a caller does next, and two pairs of them are
# opposite in exactly that:
#
#   * A missing COMPOSITE INDEX (FAILED_PRECONDITION on a query) is PERMANENT:
#     Firestore never creates one, so the identical query fails forever until
#     an operator applies the index. A lost version CAS (FAILED_PRECONDITION on
#     a commit with an updateTime precondition) is the ordinary, retryable
#     race. Same code, opposite remedies: the METHOD decides.
#   * An absent DATABASE is a permanent configuration fault; an absent
#     DOCUMENT is an ordinary outcome a caller reads as empty. Firestore
#     answers both NOT_FOUND to a GetDocument, which is why the client reads
#     documents with BatchGetDocuments: a missing document is a `missing`
#     result inside a 200 there, so a NOT_FOUND status can only be the
#     database. No sentence of prose is consulted for either.
#
# And the error text keeps no byte of the body: `error.message` names
# projects, databases, documents and console URLs, so the generated client
# keeps only the method, the HTTP status and the code, and this client adds
# the operation and the document it was asked about.
#
# HERMETIC. Every answer is a String built in this file and served by a
# ScriptedFirestore: zero sockets, zero network, zero Firestore.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.transport.scripted import ScriptedConnector

from komira_gcp_firestore.firestore_value import FsValue
from komira_gcp_firestore.firestore_client import (
    FirestoreClient,
    is_already_exists_error,
    is_database_absent_error,
    is_database_precondition_error,
    is_not_found_error,
    is_precondition_failed_error,
)
from komira_gcp_firestore.firestore_scripted import ScriptedFirestore


comptime _SECRET: String = "secret-project-7"
"""In every error message the server sends; must never reach an error."""


def _envelope(code: Int, status: String) -> String:
    return (
        String('{"error":{"code":')
        + String(code)
        + ',"message":"The query requires an index for '
        + _SECRET
        + ' https://console.example/index?create=OPAQUE-PLACEHOLDER",'
        + '"status":"'
        + status
        + '"}}'
    )


def _client(mut script: ScriptedFirestore) raises -> FirestoreClient[ScriptedConnector]:
    return FirestoreClient[ScriptedConnector](
        script.take_connector(), String("example-project"), String("orders"), String("t")
    )


def _fields() -> FsValue:
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("state"))
    vals.append(FsValue.string(String("due")))
    return FsValue.map_of(keys^, vals^)


comptime _QUERY = '{"from":[{"collectionId":"jobs"}],"where":{"fieldFilter":{"field":{"fieldPath":"state"},"op":"EQUAL","value":{"stringValue":"due"}}}}'


def _query_error(status: Int, body: String) raises -> String:
    var script = ScriptedFirestore()
    script.queue_response(status, body)
    var client = _client(script)
    try:
        _ = client.run_query(String(_QUERY))
    except e:
        return String(e)
    raise Error("the query did not raise")


def _get_error(status: Int, body: String) raises -> String:
    var script = ScriptedFirestore()
    script.queue_response(status, body)
    var client = _client(script)
    try:
        _ = client.get_document(String("jobs"), String("a"))
    except e:
        return String(e)
    raise Error("the read did not raise")


def _create_error(status: Int, body: String) raises -> String:
    var script = ScriptedFirestore()
    script.queue_response(status, body)
    var client = _client(script)
    try:
        _ = client.create_if_absent(String("jobs"), String("a"), _fields())
    except e:
        return String(e)
    raise Error("the create did not raise")


def _cas_error(status: Int, body: String) raises -> String:
    return _cas_error_then(status, body, List[Int](), List[String]())


def _cas_error_then(
    status: Int, body: String, more_status: List[Int], more_body: List[String]
) raises -> String:
    """The error of an `update_if_unchanged` whose commit is answered
    `status`/`body`, and any later request (the settling read) the `more_*`
    answers in order."""
    var script = ScriptedFirestore()
    script.queue_response(status, body)
    for i in range(len(more_status)):
        script.queue_response(more_status[i], more_body[i])
    var client = _client(script)
    try:
        _ = client.update_if_unchanged(
            String("jobs"), String("a"), _fields(), String("2026-10-01T00:00:01Z")
        )
    except e:
        return String(e)
    raise Error("the CAS did not raise")


def _classes(err: String) -> Int:
    """How many of the five classes `err` is."""
    var n = 0
    if is_not_found_error(err):
        n += 1
    if is_already_exists_error(err):
        n += 1
    if is_precondition_failed_error(err):
        n += 1
    if is_database_precondition_error(err):
        n += 1
    if is_database_absent_error(err):
        n += 1
    return n


def _no_body_byte(err: String) raises:
    assert_false(_SECRET in err, err)
    assert_false(String("OPAQUE-PLACEHOLDER") in err, err)
    assert_false(String("requires an index") in err, err)


def test_query_precondition_is_typed_permanent() raises:
    var err = _query_error(400, _envelope(400, String("FAILED_PRECONDITION")))
    assert_true(is_database_precondition_error(err), err)
    assert_false(is_precondition_failed_error(err), err)
    assert_equal(_classes(err), 1)
    # The line still says what failed and how.
    assert_true(String("run_query") in err, err)
    assert_true(String("POST RunQuery: HTTP 400, FAILED_PRECONDITION (code 9)") in err, err)
    _no_body_byte(err)


def test_transient_statuses_are_no_typed_class() raises:
    var cases = List[Int]()
    cases.append(500)
    cases.append(503)
    cases.append(429)
    var names = List[String]()
    names.append(String("INTERNAL"))
    names.append(String("UNAVAILABLE"))
    names.append(String("RESOURCE_EXHAUSTED"))
    for i in range(len(cases)):
        var err = _query_error(cases[i], _envelope(cases[i], names[i]))
        assert_equal(_classes(err), 0, err)
        assert_true(err.startswith("FirestoreClient.run_query: "), err)
        assert_true(names[i] in err, err)
        _no_body_byte(err)


def test_document_cas_conflict_class_is_unchanged() raises:
    # The same code on a CAS commit is the retryable race, not the database's.
    var err = _cas_error(400, _envelope(400, String("FAILED_PRECONDITION")))
    assert_true(is_precondition_failed_error(err), err)
    assert_false(is_database_precondition_error(err), err)
    assert_equal(_classes(err), 1)
    _no_body_byte(err)


def test_absent_database_by_status_on_every_method() raises:
    var body = _envelope(404, String("NOT_FOUND"))
    var on_get = _get_error(404, body)
    var on_query = _query_error(404, body)
    var on_create = _create_error(404, body)
    for err in [on_get, on_query, on_create]:
        assert_true(is_database_absent_error(err), err)
        assert_false(is_not_found_error(err), err)
        assert_equal(_classes(err), 1)
        _no_body_byte(err)
    # A bare 404 with no envelope at all is the same: the status decides.
    var bare = _get_error(404, String(""))
    assert_true(is_database_absent_error(bare), bare)


def test_missing_document_is_still_not_found() raises:
    var err = _get_error(
        200,
        String('[{"missing":"projects/example-project/databases/orders/documents/jobs/a"}]'),
    )
    assert_true(is_not_found_error(err), err)
    assert_false(is_database_absent_error(err), err)
    assert_equal(_classes(err), 1)


comptime _DOC_A = "projects/example-project/databases/orders/documents/jobs/a"


def _one(status: Int) -> List[Int]:
    var out = List[Int]()
    out.append(status)
    return out^


def _one_body(body: String) -> List[String]:
    var out = List[String]()
    out.append(body)
    return out^


def test_a_cas_on_a_document_that_went_away_is_not_found() raises:
    # The commit's NOT_FOUND is settled by one read: `missing` is the
    # document gone.
    var err = _cas_error_then(
        404,
        _envelope(404, String("NOT_FOUND")),
        _one(200),
        _one_body(String('[{"missing":"') + _DOC_A + '"}]'),
    )
    assert_true(is_not_found_error(err), err)
    assert_equal(_classes(err), 1)
    _no_body_byte(err)


def test_a_cas_on_an_absent_database_is_the_absent_database() raises:
    # The same commit answer, but the settling read is NOT_FOUND too: the
    # DATABASE is absent, never a gone document.
    var err = _cas_error_then(
        404,
        _envelope(404, String("NOT_FOUND")),
        _one(404),
        _one_body(_envelope(404, String("NOT_FOUND"))),
    )
    assert_true(is_database_absent_error(err), err)
    assert_false(is_not_found_error(err), err)
    assert_equal(_classes(err), 1)
    _no_body_byte(err)


def test_a_cas_on_a_recreated_document_is_a_lost_race() raises:
    # NOT_FOUND on the commit, yet the read finds the document: it was
    # deleted and created again since the caller read it, so its version
    # moved on.
    var err = _cas_error_then(
        404,
        _envelope(404, String("NOT_FOUND")),
        _one(200),
        _one_body(
            String('[{"found":{"name":"')
            + _DOC_A
            + '","updateTime":"2026-10-02T00:00:00Z"}}]'
        ),
    )
    assert_true(is_precondition_failed_error(err), err)
    assert_equal(_classes(err), 1)


def test_a_contended_cas_commit_is_a_lost_race() raises:
    # Firestore answers a contended commit 409 ABORTED: the retryable lost
    # race, so the caller re-reads and retries. Labelled, and unlabelled (a
    # 409 with no status token derives ABORTED from the HTTP status).
    var err = _cas_error(409, _envelope(409, String("ABORTED")))
    assert_true(is_precondition_failed_error(err), err)
    assert_false(is_database_precondition_error(err), err)
    assert_equal(_classes(err), 1)
    _no_body_byte(err)
    var bare = _cas_error(409, String(""))
    assert_true(is_precondition_failed_error(bare), bare)
    assert_equal(_classes(bare), 1)
    # ABORTED is the CAS's alone: a plain create that contends is no class.
    var on_create = _create_error(409, _envelope(409, String("ABORTED")))
    assert_equal(_classes(on_create), 0, on_create)


def test_create_conflict_is_only_already_exists() raises:
    var err = _create_error(409, _envelope(409, String("ALREADY_EXISTS")))
    assert_true(is_already_exists_error(err), err)
    assert_equal(_classes(err), 1)
    _no_body_byte(err)


def test_a_request_that_got_no_answer_keeps_its_cause() raises:
    # A dial the connector refuses: no status, so no class, and the cause
    # (the transport's own text) is kept.
    var script = ScriptedFirestore()
    var connector = script.take_connector()
    connector.arm_connect_error(Int64(111))
    var client = FirestoreClient[ScriptedConnector](
        connector^, String("example-project"), String("orders"), String("t")
    )
    var err = String("")
    try:
        _ = client.get_document(String("jobs"), String("a"))
    except e:
        err = String(e)
    assert_true(err.startswith("FirestoreClient.get_document: jobs/a: "), err)
    assert_equal(_classes(err), 0, err)


def main() raises:
    test_query_precondition_is_typed_permanent()
    test_transient_statuses_are_no_typed_class()
    test_document_cas_conflict_class_is_unchanged()
    test_absent_database_by_status_on_every_method()
    test_missing_document_is_still_not_found()
    test_a_cas_on_a_document_that_went_away_is_not_found()
    test_a_cas_on_an_absent_database_is_the_absent_database()
    test_a_cas_on_a_recreated_document_is_a_lost_race()
    test_a_contended_cas_commit_is_a_lost_race()
    test_create_conflict_is_only_already_exists()
    test_a_request_that_got_no_answer_keeps_its_cause()
    print("test_firestore_error_classes: ALL PASS")
