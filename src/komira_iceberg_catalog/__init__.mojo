"""komira_iceberg_catalog — the read-only Iceberg catalog CLIENT

  (RESOLVE-ONLY table resolution: one `IcebergCatalog` seam, a storage-based
  conformer and a REST conformer speaking the standard Iceberg REST protocol,
  plus the transport and credential seams the REST conformer uses).

Design decision: we WRITE Iceberg tables storage-based only (bucket+prefix), but
we must be able to CONSUME external REST catalogs on the READ path. A REST
catalog is a READ-ONLY table-RESOLUTION layer — it resolves `namespace.table`
-> the table's current metadata-location; ALL actual DATA access then stays
bucket+prefix (the storage-based reader, an Iceberg table reader,
consumes that location).

THIS PACKAGE (resolve-only):
  * `IcebergCatalog` + `ResolvedTable` — the catalog-agnostic READ-path seam
    (iceberg_catalog.mojo). Two conformers ride the SAME seam:
      - `IcebergRestCatalog[T, P]` — the STANDARD Iceberg REST protocol.
      - `StorageBasedCatalog` — the bucket+prefix resolver (no network).
  * The REST transport seam + its production/scripted conformers
    (iceberg_rest_transport.mojo): `IcebergRestTransport`,
    `HttpIcebergRestTransport[C]` (real HTTP over komira_http),
    `ScriptedIcebergRestTransport` (test double, zero network).
  * The bearer-token credential seam (iceberg_rest_catalog_client.mojo):
    `CatalogCredentialProvider` + `StaticBearerToken`.

OUT OF SCOPE (by design): any write/commit path (createTable,
updateTable/commitTable, 409-retry). Glue-native SigV4-for-`glue` + an OAuth2
token-exchange credential conformer + an inbound metadata.json PARSER are
documented FOLLOW-ONS, not part of this package.

A flat package, its own import root. It keeps the HTTP transport stack out
of any Iceberg writer package; it depends on komira_http (the REST transport), komira_json (the JSON DOM
parser `parse_json_value`) and komira_async (`BlockingRuntime`).

Encapsulation: the public API exposes only typed values, owned
`String`/`List[String]`, and the seam conformer structs. No UnsafePointer
crosses the module boundary; no wildcard origins; no unsafe_from_address.
"""

from .iceberg_catalog import (
    IcebergCatalog,
    ResolvedTable,
    StorageBasedCatalog,
)

from .iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
    IcebergRestTransport,
    ScriptedIcebergRestTransport,
    HttpIcebergRestTransport,
)

from .iceberg_rest_catalog_client import (
    ICEBERG_REST_PORT,
    ICEBERG_REST_API_ROOT,
    CatalogCredentialProvider,
    StaticBearerToken,
    IcebergRestCatalog,
)
