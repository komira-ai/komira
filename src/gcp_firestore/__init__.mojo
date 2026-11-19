"""`gcp_firestore` — the Firestore (Google Cloud) document datastore.

Written on the two clients generated beside it from the pinned googleapis
protos: `komira_gcp_firestore_v1` (BatchGetDocuments, Commit and RunQuery
over REST) and `komira_gcp_firestore_listen` (the Listen messages and the
gRPC call). Nothing here writes or parses a Firestore wire byte.

  * The document VALUE model (`firestore_value`): `FsValue`, its mapping onto
    rowcell's `RowCell` (an integer beyond Int64 becomes a canonical
    decimal STRING, a nested map or array a JSON STRING), and its conversion
    to and from the generated `Value`.
  * The document client (`firestore_client`): `FirestoreClient[C, S]`: get,
    create, replace, delete, query and the two atomic conditional writes, with
    the typed errors (`is_not_found_error`, `is_already_exists_error`, ...),
    and production auth through gcp_core's Application Default
    Credentials (`firestore_adc_token_source`, `firestore_cloud_client`).
  * Where it dials (`firestore_endpoint`): the public endpoint or an emulator.
  * The stores a caller writes against: the key-value `DocumentStore`
    (`document_store`) and objectstore's `ConditionalWriteStore`
    (`firestore_conditional_store`, with its error taxonomy in
    `firestore_store_errors`).
  * The change stream: the Listen watch (`firestore_listen_client`, over the
    generated messages in `firestore_listen_proto`) and a snapshotter
    change-stream listener over it (`firestore_watch_*`,
    `firestore_cdc_cursor`).
  * A scripted Firestore for tests (`firestore_scripted`).

The transport is http_client's; the gRPC framing grpc's; the cell
model rowcell's. The package depends on no query engine.
"""
