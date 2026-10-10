# `komira_gcp_firestore`

## Responsibility

Cloud Firestore as a document store, written on two clients generated at
build time from the pinned googleapis protos (nothing of them is copied
here):

- `komira_gcp_firestore_v1` (`:komira_gcp_firestore_v1`): BatchGetDocuments,
  Commit and RunQuery over REST.
- `komira_gcp_firestore_listen` (`:komira_gcp_firestore_listen`): the Listen
  messages and the gRPC call.

The methods are the ones Google's own Firestore client libraries use for the
same work: a document is read with BatchGetDocuments, written (created,
replaced, conditionally updated, deleted) with Commit, queried with RunQuery
and watched with Listen. This package writes and parses no Firestore wire
byte itself; it builds the generated messages and maps a failed call onto a
typed error by its `google.rpc.Code`, never by its message text.

The package's `__init__.mojo` exports nothing: import from its modules.

- `firestore_value`: the document value model. `FsValue` is one Firestore
  value (string, integer, double, boolean, null, timestamp, bytes,
  reference, geo point, array, map), with its REST JSON form
  (`serialize_fs_value`, `parse_fs_fields`) and its mapping onto
  komira_rowcell's `RowCell` (`fs_value_to_row_cell`): an integer beyond
  Int64 becomes its exact decimal text, never a wrapped number, and a nested
  array or map its JSON text.
- `firestore_client`: `FirestoreClient[C, S]`, with `get_document`,
  `create_document`, `patch_document`, `delete_document`, `run_query`, and the
  two atomic conditional writes `create_if_absent` and `update_if_unchanged`.
  A failure a caller acts on is typed: `is_not_found_error`,
  `is_already_exists_error`, `is_precondition_failed_error` (a lost
  compare-and-set: re-read and retry), `is_database_precondition_error` (a
  missing composite index: never retry) and `is_database_absent_error` (the
  database does not exist: a configuration fault, never "no data"). Production
  auth is komira_gcp_core's Application Default Credentials
  (`firestore_adc_token_source`, `firestore_cloud_client`).
- `firestore_endpoint`: where the client dials, the public endpoint or an
  emulator (`parse_firestore_endpoint`, `FirestoreEndpoint`).
- `document_store`: the key-value `DocumentStore` trait (get, put, delete,
  query) and `FirestoreDocumentStore`, its Firestore conformer. A get of an
  absent key is `None` and a delete of one is a no-op, not an error.
- `firestore_conditional_store` (with `firestore_store_errors`):
  komira_objectstore's `ConditionalWriteStore` on Firestore.
- The change stream: the Listen watch (`firestore_listen_client` over
  `firestore_listen_proto`) and a komira_snapshotter change-stream listener
  over it (`firestore_watch_*`, `firestore_cdc_cursor`).
- Test doubles: `firestore_scripted`'s `ScriptedFirestore` answers each
  request from a queue and records what was sent; `firestore_fake`'s
  `ExchangeConnector` passes each request to a stateful handler.

The package reads no environment, and none of its tests open a network
connection or need credentials or the emulator.

## Examples

Every example below runs as a test when the package is built, against
`ScriptedFirestore`: nothing leaves the process.

Values, and how a document's fields read as cells. An integer is carried as
decimal text (as on Firestore's wire); one that fits Int64 becomes a LONG
cell, and one that does not keeps its exact digits as a STRING cell:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_gcp_firestore.firestore_value import FS_T_INTEGER, FS_T_MAP, FS_T_STRING, FsValue, fs_value_to_row_cell, parse_fs_fields, serialize_fs_value
from komira_rowcell import CELL_T_LONG, CELL_T_STRING

var fields = parse_fs_fields('{"email":{"stringValue":"ada@example.com"},"visits":{"integerValue":"3"}}')
assert_equal(fields.type_tag, FS_T_MAP)
assert_true(fields.map_has(String("visits")))
assert_false(fields.map_has(String("name")))
assert_equal(fields.map_get(String("email")).type_tag, FS_T_STRING)
assert_equal(fields.map_get(String("email")).as_string(), "ada@example.com")
assert_equal(fields.map_get(String("visits")).type_tag, FS_T_INTEGER)

var visits = fs_value_to_row_cell(fields.map_get(String("visits")))
assert_equal(visits.type_tag, CELL_T_LONG)
assert_equal(visits.as_long(), Int64(3))

var huge = fs_value_to_row_cell(FsValue.integer(String("18446744073709551615")))
assert_equal(huge.type_tag, CELL_T_STRING)
assert_equal(huge.as_string(), "18446744073709551615")

assert_equal(serialize_fs_value(FsValue.string(String("x"))), '{"stringValue":"x"}')
assert_equal(serialize_fs_value(FsValue.boolean(True)), '{"booleanValue":true}')
```

A key-value store over Firestore. `put` is one Commit that replaces the whole
document, `get` one BatchGetDocuments, and a key that is not there reads as
`None`:

```mojo
from komira_gcp_firestore.document_store import FirestoreDocumentStore
from komira_gcp_firestore.firestore_scripted import ScriptedFirestore
from komira_http_core.transport.scripted import ScriptedConnector

def profile(var email: String, var visits: String) -> FsValue:
    var keys = List[String]()
    var values = List[FsValue]()
    keys.append(String("email"))
    values.append(FsValue.string(email^))
    keys.append(String("visits"))
    values.append(FsValue.integer(visits^))
    return FsValue.map_of(keys^, values^)

def document_store(mut script: ScriptedFirestore) raises -> FirestoreDocumentStore[ScriptedConnector]:
    return FirestoreDocumentStore[ScriptedConnector](
        script.take_connector(), String("demo-project"), String("(default)"), String("test-bearer")
    )

var script = ScriptedFirestore()
script.queue_response(200, '{"writeResults":[{"updateTime":"2026-10-01T00:00:01Z"}]}')
script.queue_response(
    200,
    '[{"found":{"name":"projects/demo-project/databases/(default)/documents/profiles/ada",'
    + '"fields":{"email":{"stringValue":"ada@example.com"},"visits":{"integerValue":"3"}}}}]',
)
script.queue_response(200, '[{"missing":"projects/demo-project/databases/(default)/documents/profiles/bob"}]')
var store = document_store(script)

store.put(String("profiles"), String("ada"), profile(String("ada@example.com"), String("3")))
var ada = store.get(String("profiles"), String("ada"))
assert_true(Bool(ada))
assert_equal(ada.value().map_get(String("email")).as_string(), "ada@example.com")
assert_false(Bool(store.get(String("profiles"), String("bob"))))

assert_equal(script.call_count(), 3)
assert_equal(script.call_method(0), "POST")
assert_equal(script.call_path(0), "/v1/projects/demo-project/databases/%28default%29/documents:commit")
assert_true('"stringValue":"ada@example.com"' in script.call_body(0))
assert_equal(script.call_path(1), "/v1/projects/demo-project/databases/%28default%29/documents:batchGet")
assert_equal(script.call_bearer(1), "test-bearer")
```

A query returns each document's key (the last segment of its name) and its
fields; the structured query is read strictly before anything is sent:

```mojo
var script = ScriptedFirestore()
script.queue_response(
    200,
    '[{"document":{"name":"projects/demo-project/databases/(default)/documents/profiles/ada",'
    + '"fields":{"email":{"stringValue":"ada@example.com"}}},"readTime":"2026-10-01T00:00:01Z"},'
    + '{"document":{"name":"projects/demo-project/databases/(default)/documents/profiles/bob",'
    + '"fields":{"email":{"stringValue":"bob@example.com"}}},"readTime":"2026-10-01T00:00:01Z"}]',
)
var store = document_store(script)
var entries = store.query(String("profiles"), String('{"from":[{"collectionId":"profiles"}]}'))
assert_equal(entries[0].key, "ada")
assert_equal(entries[1].key, "bob")
assert_equal(entries[1].fields.map_get(String("email")).as_string(), "bob@example.com")
assert_equal(script.call_path(0), "/v1/projects/demo-project/databases/%28default%29/documents:runQuery")

var refused = False
try:
    _ = store.query(String("profiles"), String('{"form":[{"collectionId":"profiles"}]}'))
except:
    refused = True
assert_true(refused)
assert_equal(script.call_count(), 1)
```

A create that loses to an existing document raises the typed
already-exists error, which a caller tells apart from any other failure
without reading the message:

```mojo
from komira_gcp_firestore.firestore_client import FirestoreClient, is_already_exists_error, is_not_found_error

var script = ScriptedFirestore()
script.queue_response(
    409, '{"error":{"code":409,"status":"ALREADY_EXISTS","message":"Document already exists: ..."}}'
)
var client = FirestoreClient[ScriptedConnector](
    script.take_connector(), String("demo-project"), String("(default)"), String("test-bearer")
)
var failure = String()
try:
    _ = client.create_document(String("profiles"), String("ada"), profile(String("ada@example.com"), String("1")))
except e:
    failure = String(e)
assert_true(is_already_exists_error(failure))
assert_false(is_not_found_error(failure))
assert_equal(client.document_name(String("profiles"), String("ada")), "projects/demo-project/databases/(default)/documents/profiles/ada")
```

Where the client dials: an empty override is the public endpoint over TLS,
and `host:port` with `insecure` is an emulator over plain HTTP:

```mojo
from komira_gcp_firestore.firestore_endpoint import FIRESTORE_HOST, FIRESTORE_PORT, parse_firestore_endpoint

var cloud = parse_firestore_endpoint(String(""), False)
assert_equal(cloud.host, FIRESTORE_HOST)
assert_equal(cloud.port, FIRESTORE_PORT)
assert_true(cloud.is_https())

var emulator = parse_firestore_endpoint(String("firestore-emulator:8080"), True)
assert_equal(emulator.host, "firestore-emulator")
assert_equal(emulator.port, UInt16(8080))
assert_equal(emulator.scheme(), "http")
```
