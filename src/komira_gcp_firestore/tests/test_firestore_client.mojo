# =============================================================================
# test_firestore_client.mojo — the Firestore document client over the
#   generated REST client.
# =============================================================================
#
# Over a ScriptedFirestore (canned HTTP answers per request, ZERO sockets):
#
#   (1) get_document is a BatchGetDocuments naming the document's full
#       resource name, with the bearer attached, and the `found` document
#       (name/fields/createTime/updateTime) converts to typed FsValues.
#   (2) A `missing` result is the TYPED not-found error; a NOT_FOUND status
#       (only an absent database answers that here) is the typed
#       absent-database error, never not-found.
#   (3) create_document / patch_document are a Commit with one `update`
#       write carrying the typed fields; create's carries
#       `currentDocument.exists = false`, patch's no precondition.
#   (4) delete_document reads the document, then commits one `delete` write
#       conditioned on `exists = true`; a missing document is the typed
#       not-found error, read or raced.
#   (5) run_query posts RunQuery on the database root with the structured
#       query, and keeps the documents of the stream (a read-time-only
#       element carries none); a query that is not a StructuredQuery is
#       refused before anything is sent.
#   (6) The oneof arm numbers the client names (`BATCH_GET_FOUND`, ...) are
#       the generated decoder's: each arm's JSON decodes to its constant.
#   (7) A quota project goes out as `x-goog-user-project` on every request.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector

from komira_gcp_firestore.firestore_value import (
    FsValue,
    FS_T_STRING,
    FS_T_INTEGER,
)
from komira_proto_codec.codec import decode_json

from komira_gcp_firestore_v1.common import Precondition
from komira_gcp_firestore_v1.firestore import (
    BatchGetDocumentsResponse,
    RunQueryRequest,
)
from komira_gcp_firestore_v1.write import Write

from komira_gcp_firestore.firestore_client import (
    BATCH_GET_FOUND,
    BATCH_GET_MISSING,
    PRECONDITION_EXISTS,
    PRECONDITION_UPDATE_TIME,
    RUN_QUERY_STRUCTURED,
    WRITE_DELETE,
    WRITE_UPDATE,
    FirestoreClient,
    firestore_quota_project_headers,
    is_database_absent_error,
    is_not_found_error,
)
from komira_gcp_firestore.firestore_scripted import ScriptedFirestore


comptime _PROJECT: String = "example-project"
comptime _DATABASE: String = "(default)"
comptime _BEARER: String = "ya29.test-access-token"
comptime _DB_PATH: String = "/v1/projects/example-project/databases/%28default%29"
comptime _NAME: String = "projects/example-project/databases/(default)/documents/users/alice"


def _client(mut script: ScriptedFirestore) raises -> FirestoreClient[ScriptedConnector]:
    return FirestoreClient[ScriptedConnector](
        script.take_connector(), String(_PROJECT), String(_DATABASE), String(_BEARER)
    )


def _sample_document_json() -> String:
    """A Firestore document with a string + integer field."""
    return String(
        "{"
        + '"name":"' + _NAME + '",'
        + '"fields":{"email":{"stringValue":"alice@example.com"},'
        + '"visits":{"integerValue":"12"}},'
        + '"createTime":"2026-10-01T00:00:00.000001Z",'
        + '"updateTime":"2026-10-01T01:00:00.000001Z"'
        + "}"
    )


def _fields(var email: String, var visits: String) -> FsValue:
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("email"))
    vals.append(FsValue.string(email^))
    keys.append(String("visits"))
    vals.append(FsValue.integer(visits^))
    return FsValue.map_of(keys^, vals^)


def _commit_ok() -> String:
    return String(
        '{"writeResults":[{"updateTime":"2026-10-01T02:00:00.5Z"}],'
        + '"commitTime":"2026-10-01T02:00:00.5Z"}'
    )


# =============================================================================
# (1) get_document: BatchGetDocuments, bearer attached, fields converted.
# =============================================================================
def test_get_document_names_the_document_and_converts_it() raises:
    var script = ScriptedFirestore()
    script.queue_response(
        200,
        String('[{"found":') + _sample_document_json()
        + ',"readTime":"2026-10-01T03:00:00Z"}]',
    )
    var client = _client(script)
    var doc = client.get_document(String("users"), String("alice"))
    assert_equal(doc.name, String(_NAME))
    assert_true(doc.has_field(String("email")))
    assert_equal(doc.get_field(String("email")).type_tag, FS_T_STRING)
    assert_equal(doc.get_field(String("email")).as_string(), String("alice@example.com"))
    assert_equal(doc.get_field(String("visits")).type_tag, FS_T_INTEGER)
    assert_equal(doc.get_field(String("visits")).as_string(), String("12"))
    assert_equal(doc.create_time, String("2026-10-01T00:00:00.000001Z"))
    assert_equal(doc.update_time, String("2026-10-01T01:00:00.000001Z"))
    assert_equal(script.call_count(), 1)
    assert_equal(script.call_method(0), String("POST"))
    assert_equal(script.call_path(0), String(_DB_PATH) + "/documents:batchGet")
    assert_equal(script.call_host(0), String("firestore.googleapis.com"))
    assert_equal(script.call_bearer(0), String(_BEARER))
    assert_true(String('"documents":["') + _NAME + '"]' in script.call_body(0))


# =============================================================================
# (2) missing -> typed not-found; NOT_FOUND status -> typed absent database.
# =============================================================================
def test_missing_document_is_typed_not_found() raises:
    var script = ScriptedFirestore()
    script.queue_response(
        200,
        String('[{"missing":"') + _NAME + '","readTime":"2026-10-01T03:00:00Z"}]',
    )
    var client = _client(script)
    var raised = False
    try:
        _ = client.get_document(String("users"), String("alice"))
    except e:
        raised = True
        assert_true(is_not_found_error(String(e)), String(e))
        assert_false(is_database_absent_error(String(e)))
    assert_true(raised, msg="a missing document must raise")


def test_not_found_status_is_the_absent_database() raises:
    var script = ScriptedFirestore()
    script.queue_response(
        404,
        String(
            '{"error":{"code":404,"message":"The database (default) does not'
            + ' exist for project example-project","status":"NOT_FOUND"}}'
        ),
    )
    var client = _client(script)
    var raised = False
    try:
        _ = client.get_document(String("users"), String("alice"))
    except e:
        raised = True
        var text = String(e)
        assert_true(is_database_absent_error(text), text)
        assert_false(is_not_found_error(text), text)
        # Classified on the status, and no byte of the message kept.
        assert_false(String("does not exist") in text, text)
        assert_true(String("NOT_FOUND (code 5)") in text, text)
    assert_true(raised)


# =============================================================================
# (3) create / patch: a Commit with one update write.
# =============================================================================
def test_create_document_is_a_conditional_commit() raises:
    var script = ScriptedFirestore()
    script.queue_response(200, _commit_ok())
    var client = _client(script)
    var doc = client.create_document(
        String("users"), String("alice"),
        _fields(String("alice@example.com"), String("12")),
    )
    assert_equal(doc.name, String(_NAME))
    assert_equal(doc.update_time, String("2026-10-01T02:00:00.500Z"))
    assert_equal(doc.create_time, doc.update_time)
    assert_equal(script.call_count(), 1)
    assert_equal(script.call_method(0), String("POST"))
    assert_equal(script.call_path(0), String(_DB_PATH) + "/documents:commit")
    assert_equal(script.call_bearer(0), String(_BEARER))
    var body = script.call_body(0)
    assert_true(String('"currentDocument":{"exists":false}') in body, body)
    assert_true(String('"update":{"name":"') + _NAME + '"' in body, body)
    assert_true(String('"stringValue":"alice@example.com"') in body, body)
    assert_true(String('"integerValue":"12"') in body, body)


def test_patch_document_is_an_unconditional_commit() raises:
    var script = ScriptedFirestore()
    script.queue_response(200, _commit_ok())
    var client = _client(script)
    var doc = client.patch_document(
        String("users"), String("alice"),
        _fields(String("alice@example.com"), String("13")),
    )
    assert_equal(doc.update_time, String("2026-10-01T02:00:00.500Z"))
    assert_equal(doc.create_time, String(""))
    assert_equal(script.call_path(0), String(_DB_PATH) + "/documents:commit")
    var body = script.call_body(0)
    assert_false(String("currentDocument") in body, body)
    assert_true(String('"integerValue":"13"') in body, body)


# =============================================================================
# (4) delete: a read, then a Commit with one delete write that must find it.
# =============================================================================
def test_delete_document_reads_then_deletes_conditionally() raises:
    var script = ScriptedFirestore()
    script.queue_response(200, String('[{"found":') + _sample_document_json() + "}]")
    script.queue_response(200, String('{"writeResults":[{}],"commitTime":"2026-10-01T02:00:00Z"}'))
    var client = _client(script)
    client.delete_document(String("users"), String("alice"))
    assert_equal(script.call_count(), 2)
    assert_equal(script.call_path(0), String(_DB_PATH) + "/documents:batchGet")
    assert_equal(script.call_path(1), String(_DB_PATH) + "/documents:commit")
    var body = script.call_body(1)
    assert_true(String('"delete":"') + _NAME + '"' in body, body)
    assert_true(String('"currentDocument":{"exists":true}') in body, body)
    assert_false(String('"update"') in body, body)


def test_delete_of_a_missing_document_is_typed_not_found() raises:
    # The read says `missing`: nothing is written, and the caller is told.
    var script = ScriptedFirestore()
    script.queue_response(200, String('[{"missing":"') + _NAME + '"}]')
    var client = _client(script)
    var raised = False
    try:
        client.delete_document(String("users"), String("alice"))
    except e:
        raised = True
        assert_true(is_not_found_error(String(e)), String(e))
    assert_true(raised)
    assert_equal(script.call_count(), 1)
    # Gone between the read and the delete: the same answer.
    var raced = ScriptedFirestore()
    raced.queue_response(200, String('[{"found":') + _sample_document_json() + "}]")
    raced.queue_response(404, String('{"error":{"code":404,"status":"NOT_FOUND"}}'))
    var client2 = _client(raced)
    raised = False
    try:
        client2.delete_document(String("users"), String("alice"))
    except e:
        raised = True
        assert_true(is_not_found_error(String(e)), String(e))
    assert_true(raised)


# =============================================================================
# (5) run_query: RunQuery on the database root.
# =============================================================================
def test_run_query_decodes_streamed_documents() raises:
    var stream = String(
        "["
        + '{"readTime":"2026-10-01T00:00:00Z"},'
        + '{"document":{"name":"projects/p/databases/(default)/documents/users/a",'
        + '"fields":{"email":{"stringValue":"a@x.com"}}},'
        + '"readTime":"2026-10-01T00:00:01Z"},'
        + '{"document":{"name":"projects/p/databases/(default)/documents/users/b",'
        + '"fields":{"email":{"stringValue":"b@x.com"}}},'
        + '"readTime":"2026-10-01T00:00:02Z"}'
        + "]"
    )
    var script = ScriptedFirestore()
    script.queue_response(200, stream)
    var client = _client(script)
    var docs = client.run_query(String('{"from":[{"collectionId":"users"}]}'))
    assert_equal(len(docs), 2)
    assert_equal(docs[0].get_field(String("email")).as_string(), String("a@x.com"))
    assert_equal(docs[1].get_field(String("email")).as_string(), String("b@x.com"))
    assert_equal(script.call_method(0), String("POST"))
    assert_equal(script.call_path(0), String(_DB_PATH) + "/documents:runQuery")
    var body = script.call_body(0)
    assert_true(
        body.startswith(
            '{"structuredQuery":{'
        ),
        body,
    )
    assert_true(String('"structuredQuery":{') in body, body)
    assert_true(String('"collectionId":"users"') in body, body)


def test_a_query_that_is_not_a_structured_query_is_refused() raises:
    var script = ScriptedFirestore()
    var client = _client(script)
    var raised = False
    try:
        _ = client.run_query(String('{"form":[{"collectionId":"users"}]}'))
    except e:
        raised = True
        assert_true(String("not a google.firestore.v1.StructuredQuery") in String(e))
    assert_true(raised)
    assert_equal(script.call_count(), 0)


# =============================================================================
# (6) The oneof arm numbers, pinned against the generated decoder.
# =============================================================================
def test_oneof_arm_constants_are_the_generated_decoders() raises:
    assert_equal(
        decode_json[BatchGetDocumentsResponse](
            String('{"found":{"name":"x"}}')
        )._oneof0_case,
        BATCH_GET_FOUND,
    )
    assert_equal(
        decode_json[BatchGetDocumentsResponse](String('{"missing":"x"}'))._oneof0_case,
        BATCH_GET_MISSING,
    )
    assert_equal(
        decode_json[Precondition](String('{"exists":true}'))._oneof0_case,
        PRECONDITION_EXISTS,
    )
    assert_equal(
        decode_json[Precondition](
            String('{"updateTime":"2026-10-01T00:00:00Z"}')
        )._oneof0_case,
        PRECONDITION_UPDATE_TIME,
    )
    assert_equal(
        decode_json[Write](String('{"update":{"name":"x"}}'))._oneof0_case,
        WRITE_UPDATE,
    )
    assert_equal(
        decode_json[Write](String('{"delete":"x"}'))._oneof0_case, WRITE_DELETE
    )
    assert_equal(
        decode_json[RunQueryRequest](
            String('{"parent":"p","structuredQuery":{}}')
        )._oneof0_case,
        RUN_QUERY_STRUCTURED,
    )


# =============================================================================
# (7) The quota project header.
# =============================================================================
def test_a_quota_project_goes_out_on_every_request() raises:
    var script = ScriptedFirestore()
    script.queue_response(200, String("[{\"found\":") + _sample_document_json() + "}]")
    script.queue_response(200, _commit_ok())
    var client = FirestoreClient[ScriptedConnector](
        HttpClient[ScriptedConnector].with_defaults(script.take_connector()),
        String(_PROJECT),
        String(_DATABASE),
        String(_BEARER),
        firestore_quota_project_headers(String("billing-project")),
    )
    _ = client.get_document(String("users"), String("alice"))
    _ = client.patch_document(String("users"), String("alice"), _fields(String("a@x.com"), String("1")))
    for i in range(2):
        assert_true(
            String("x-goog-user-project: billing-project\r\n")
            in script.call_text(i).lower(),
            script.call_text(i),
        )
    # None named, none sent.
    assert_equal(firestore_quota_project_headers(String("")).len(), 0)


def main() raises:
    test_get_document_names_the_document_and_converts_it()
    test_missing_document_is_typed_not_found()
    test_not_found_status_is_the_absent_database()
    test_create_document_is_a_conditional_commit()
    test_patch_document_is_an_unconditional_commit()
    test_delete_document_reads_then_deletes_conditionally()
    test_delete_of_a_missing_document_is_typed_not_found()
    test_run_query_decodes_streamed_documents()
    test_a_query_that_is_not_a_structured_query_is_refused()
    test_oneof_arm_constants_are_the_generated_decoders()
    test_a_quota_project_goes_out_on_every_request()
    print("test_firestore_client: ALL PASS")
