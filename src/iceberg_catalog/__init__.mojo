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
    `CommitClock`, `CommitIds` and `AppendSnapshotWriter` seams. With
    `AppendCommit.overwrite` it commits an `overwrite` snapshot that replaces
    every row of `main` (iceberg_commit_summary.mojo builds the summary).
  * The write sink: `write_table` (iceberg_write_sink.mojo) writes Arrow
    batches as data files through a `TableFiles` (an object store and the URI
    prefix it serves, iceberg_table_files.mojo), has a `StoreSnapshotWriter`
    (iceberg_store_writer.mojo) write the manifest once and a manifest list
    per attempt, and commits through `commit_append`, appending or
    overwriting.
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
(the committer's production clock and ids), and, for the write sink, iceberg
(data files, manifests), objectstore (the files' store), arrow (the batches),
containers and parquet_api (the codec).

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
    ICEBERG_LOCATION_REFUSED,
    ICEBERG_MANIFEST_LIST_UNSUPPORTED,
    ICEBERG_TYPE_UNSUPPORTED,
    ICEBERG_NULL_IN_REQUIRED_COLUMN,
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

from .iceberg_table_files import TableFiles

from .iceberg_store_writer import StoreSnapshotWriter

from .iceberg_write_sink import (
    TableWriteOutcome,
    table_schema_json,
    table_data_path,
    table_metadata_path,
    table_parquet_codec,
    write_table,
)

from .iceberg_rest_test_catalog import (
    CommitFault,
    InMemoryIcebergRestCatalog,
)
