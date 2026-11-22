"""iceberg_catalog — the Iceberg catalog CLIENT: resolve, load, create and
commit tables through a catalog.

  * `IcebergCatalog` + `ResolvedTable` — the catalog-agnostic resolve seam
    (iceberg_catalog.mojo). Two conformers ride it:
      - `IcebergRestCatalog[T, P]` — the STANDARD Iceberg REST protocol: config,
        loadTable, createTable (staged or direct) and commitTable
        (iceberg_rest_catalog_client.mojo).
      - `StorageBasedCatalog` — the bucket+prefix resolver (no network).
  * The REST transport seam + its production/scripted conformers
    (iceberg_rest_transport.mojo): `IcebergRestTransport`,
    `HttpIcebergRestTransport[C]` (real HTTP over komira_http),
    `ScriptedIcebergRestTransport` (test double, zero network).
  * The typed commit vocabulary (iceberg_table_changes.mojo):
    `TableRequirement`, `TableUpdate`, `NewSnapshot`, `CreateTableRequest`,
    `commit_table_body`; and the typed `TableMetadata` a load, create or
    commit returns (iceberg_table_metadata.mojo).
  * The append committer (iceberg_commit.mojo): `commit_append`, with retries
    on 409, the unknown-outcome lookup, and the cleanup lists, over the
    `CommitClock`, `CommitIds` and `AppendSnapshotWriter` seams.
  * `InMemoryIcebergRestCatalog` (iceberg_rest_test_catalog.mojo): an
    in-process REST catalog that applies commits and can be scripted to
    fail, for tests.
  * The error tokens (iceberg_rest_errors.mojo): every message starts with
    one.

docs/design/iceberg_tables.md is the design. Not here yet: the staged-create
and replace committers, OAuth2 and SigV4 catalog credentials, vended
credentials, and multi-level namespaces.

A flat package, its own import root. It keeps the HTTP transport stack out
of the Iceberg format package; it depends on komira_http (the REST
transport), json (the JSON DOM), async_rt (`BlockingRuntime`), clock and uuid
(the committer's production clock and ids).

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
    IcebergRestMethod,
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
    LoadedTable,
    CommitResponse,
    COMMIT_APPLIED,
    COMMIT_CONFLICT,
    COMMIT_UNKNOWN,
    COMMIT_REFUSED,
    ENDPOINT_LOAD_TABLE,
    ENDPOINT_CREATE_TABLE,
    ENDPOINT_COMMIT_TABLE,
)

from .iceberg_rest_errors import (
    ICEBERG_NAMESPACE_NOT_FOUND,
    ICEBERG_TABLE_NOT_FOUND,
    ICEBERG_TABLE_ALREADY_EXISTS,
    ICEBERG_CATALOG_UNAUTHORIZED,
    ICEBERG_CATALOG_FORBIDDEN,
    ICEBERG_CATALOG_REJECTED,
    ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED,
    ICEBERG_CATALOG_UNAVAILABLE,
    ICEBERG_CATALOG_RESPONSE_INVALID,
    ICEBERG_COMMIT_CONFLICT,
    ICEBERG_COMMIT_STATE_UNKNOWN,
    ICEBERG_TABLE_REPLACED,
    ICEBERG_SCHEMA_INCOMPATIBLE,
    ICEBERG_WRITE_FORMAT_UNSUPPORTED,
)

from .iceberg_table_metadata import (
    SchemaField,
    TableSchema,
    TableSnapshot,
    TableMetadata,
    parse_table_metadata,
    parse_table_metadata_text,
)

from .iceberg_table_changes import (
    TableRequirement,
    TableUpdate,
    NewSnapshot,
    CreateTableRequest,
    commit_table_body,
)

from .iceberg_commit import (
    COMMIT_ID_SUMMARY_KEY,
    CommitClock,
    SystemCommitClock,
    ManualCommitClock,
    CommitIds,
    RandomCommitIds,
    SequenceCommitIds,
    AppendSnapshotWriter,
    AppendCommit,
    AppendCommitOutcome,
    CommitRetryBudget,
    commit_append,
)

from .iceberg_rest_test_catalog import (
    CommitFault,
    InMemoryIcebergRestCatalog,
)
