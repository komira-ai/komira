# komira_iceberg_catalog

A read-only Iceberg catalog client. It resolves `namespace.table` to the
object-store location of the table's current `metadata.json`, through one seam,
`IcebergCatalog.load_table(namespace, table) -> ResolvedTable`, with two
implementations:

- `StorageBasedCatalog`: an in-memory map from `namespace.table` to a
  metadata location the caller registered. No network.
- `IcebergRestCatalog[T, P]`: the standard Iceberg REST protocol. On the first
  resolve it reads `GET /v1/config` once and caches the merged `defaults` and
  `overrides` (overrides win), including the catalog `prefix`; each resolve then
  reads `GET /v1/{prefix}/namespaces/{ns}/tables/{table}` with the namespace and
  table percent-encoded. It returns the `metadata-location`, the table's
  `metadata` object re-serialized as JSON text, and the per-table string
  `config`. A 404, any other non-200 status, a body that is not a JSON object,
  and a missing or empty `metadata-location` all raise.

The REST client is generic over a transport (`IcebergRestTransport`:
`HttpIcebergRestTransport[C]` over `komira_http_client`, or
`ScriptedIcebergRestTransport`, which answers from a queue and records each
request's path and `Authorization` header) and over a credential provider
(`CatalogCredentialProvider`; `StaticBearerToken` sends `Bearer <token>`, or no
header for an empty token).

It does not write: there is no create, update or commit of a table, and it does
not parse the table metadata, which it hands back as text. Reading the table's
data from its location is a table reader's job.

## Examples

A storage-based catalog resolves what was registered and refuses anything else:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_iceberg_catalog import StorageBasedCatalog

var catalog = StorageBasedCatalog()
catalog.register("db", "orders", "s3://wh/db/orders/metadata/00002.metadata.json")

var t = catalog.load_table("db", "orders")
assert_true(t.has_location())
assert_equal(t.metadata_location, "s3://wh/db/orders/metadata/00002.metadata.json")
assert_equal(t.metadata, "")  # a storage-based resolve knows only the location

var refused = False
try:
    _ = catalog.load_table("db", "missing")
except e:
    refused = String(e).find("no table registered for 'db.missing'") >= 0
assert_true(refused)
```

The REST client over the scripted transport, with canned catalog responses: the
config is read once, the prefix it names goes into the table path, the bearer
token goes on every request, and the location comes back from the response:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_iceberg_catalog import IcebergRestCatalog, ScriptedIcebergRestTransport, StaticBearerToken

var transport = ScriptedIcebergRestTransport()
transport.queue_response(
    200, '{"defaults":{"clients":"4"},"overrides":{"prefix":"prod"}}'
)
transport.queue_response(
    200,
    '{"metadata-location":"s3://wh/prod/db/orders/metadata/00003.metadata.json",'
    + '"metadata":{"format-version":2},'
    + '"config":{"write.parquet.compression-codec":"zstd"}}',
)
transport.queue_response(404, '{"error":{"message":"Table does not exist","code":404}}')

var catalog = IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken](
    "catalog", transport^, StaticBearerToken("token-123")
)
var t = catalog.load_table("db", "orders")
assert_equal(t.metadata_location, "s3://wh/prod/db/orders/metadata/00003.metadata.json")
assert_equal(t.config_value("write.parquet.compression-codec"), "zstd")
assert_true(t.metadata.find("format-version") >= 0)
assert_equal(catalog.prefix(), "prod")
assert_equal(catalog.config_value("clients"), "4")

# The second table is a 404: an error, never an empty location.
var not_found = False
try:
    _ = catalog.load_table("db", "gone")
except e:
    not_found = String(e).find("HTTP 404") >= 0
assert_true(not_found)

ref sent = catalog.transport_ref()
assert_equal(sent.call_count(), 3)  # /v1/config was read once, not per table
assert_equal(sent.call_path(0), "/v1/config")
assert_equal(sent.call_path(1), "/v1/prod/namespaces/db/tables/orders")
assert_equal(sent.call_auth(1), "Bearer token-123")
```
