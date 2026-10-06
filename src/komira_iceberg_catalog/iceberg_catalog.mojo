# =============================================================================
# komira_iceberg_catalog/iceberg_catalog.mojo — the READ-path catalog-resolver
#   SEAM: `IcebergCatalog` + `ResolvedTable` + a storage-based conformer.
# =============================================================================
#
# WHAT THIS IS. The catalog-agnostic RESOLVE-ONLY seam the Iceberg READ path
# resolves a table through. Design decision: we WRITE Iceberg tables storage-based only (bucket+prefix),
# but we must CONSUME external REST catalogs on the READ path. A catalog is a
# READ-ONLY table-RESOLUTION layer: it maps `namespace.table` -> the object-store
# URI of the table's current `metadata.json`. ALL actual DATA access then stays
# bucket+prefix — the storage-based reader (an Iceberg table reader)
# consumes that URI. This seam does NOT commit, does NOT write, does NOT read
# data files — it RESOLVES.
#
# THE SEAM. `IcebergCatalog.load_table(namespace, table) -> ResolvedTable`. Two
# conformers ride the SAME seam so the read path is catalog-agnostic:
#   * `IcebergRestCatalog[T]` (iceberg_rest_catalog_client.mojo) — the STANDARD
#     Iceberg REST protocol (GET /v1/config + GET /v1/{prefix}/namespaces/{ns}/
#     tables/{tbl}), parsing the loadTable JSON into a ResolvedTable.
#   * `StorageBasedCatalog` (below) — the "Hadoop"/bucket+prefix resolver: a
#     table is at a KNOWN metadata-location; resolution is a pure map lookup, no
#     network. This is the OTHER conformer, proving the seam covers BOTH the REST
#     and the storage-based worlds without a leak.
#
# THE LOAD-BEARING OUTPUT is `ResolvedTable.metadata_location` — the object-store
# URI (e.g. `s3://bucket/db/table/metadata/00003-....metadata.json`) of the
# current metadata.json. The storage-based reader is handed exactly this URI. A
# resolution that yields an EMPTY metadata_location is a hard error at the client
# layer (fail loud, never a silent empty string).
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. Every field is an owned typed value
# (`String` / `List[String]`). `def`-based, Mojo 1.0.0b2.
# =============================================================================


# =============================================================================
# §0 — ResolvedTable — the resolve-only output every catalog conformer returns.
# =============================================================================


struct ResolvedTable(Copyable, Movable, Deinitable):
    """The result of resolving `namespace.table` through a catalog.

    Field layout:
      var metadata_location: String    — the LOAD-BEARING output: the object-
                                          store URI of the current metadata.json.
                                          This is the bucket+prefix location the
                                          storage-based reader consumes. NEVER
                                          empty on a successful resolution.
      var metadata: String             — the raw table-metadata JSON document (as
                                          returned in the REST loadTable response's
                                          `metadata` key, or "" for a storage-based
                                          resolution that only knows the location).
                                          SURFACED verbatim; the metadata.json
                                          PARSER is a flagged follow-on (see the
                                          module header of the REST client).
      var config_names: List[String]   — per-table config-override keys (parallel
                                          to config_values). From the loadTable
                                          `config` object; empty for storage-based.
      var config_values: List[String]  — per-table config-override values.

    a plain owned-field struct — only `String`/`List[String]` heap fields,
    no pointer field, no wildcard origin, lives only as a value in plain List[T]
    / as a return value. Not stored in any byte-slab."""

    var metadata_location: String
    var metadata: String
    var config_names: List[String]
    var config_values: List[String]

    def __init__(
        out self,
        var metadata_location: String,
        var metadata: String,
        var config_names: List[String],
        var config_values: List[String],
    ):
        self.metadata_location = metadata_location^
        self.metadata = metadata^
        self.config_names = config_names^
        self.config_values = config_values^

    @staticmethod
    def with_location(var metadata_location: String) -> ResolvedTable:
        """A ResolvedTable that carries only the metadata-location (the
        storage-based case — the reader needs only the URI). Empty metadata +
        empty config."""
        return ResolvedTable(
            metadata_location^,
            String(""),
            List[String](),
            List[String](),
        )

    def copy(self) -> Self:
        return ResolvedTable(
            String(self.metadata_location),
            String(self.metadata),
            self.config_names.copy(),
            self.config_values.copy(),
        )

    @always_inline
    def has_location(self) -> Bool:
        """True iff a non-empty metadata-location was resolved. The client
        layer asserts this (a missing/empty metadata-location is a hard error,
        NOT a silent empty string)."""
        return self.metadata_location.byte_length() > 0

    def config_value(self, name: String) -> String:
        """Look up a per-table config-override value by key; empty String if
        absent. (Case-sensitive, matching the REST `config` object keys.)"""
        for i in range(len(self.config_names)):
            if self.config_names[i] == name:
                return String(self.config_values[i])
        return String("")


# =============================================================================
# §1 — IcebergCatalog — the RESOLVE-ONLY seam.
# =============================================================================


trait IcebergCatalog(Movable, Deinitable):
    """The READ-path catalog every Iceberg-table resolution goes through. ONE
    method: `load_table(namespace, table) -> ResolvedTable`. A REST catalog
    resolves over HTTP; a storage-based catalog resolves by a known location.
    No UnsafePointer crosses the boundary — two `String`s in, a `ResolvedTable`
    out.

    RESOLVE-ONLY: there is no `create_table` / `update_table` / `commit` on this
    trait BY DESIGN — the catalog is a read-only table-resolution layer (a design
    decision). Writes stay storage-based."""

    def load_table(
        mut self, namespace: String, table: String
    ) raises -> ResolvedTable:
        """Resolve `namespace.table` -> its current metadata-location (+ the raw
        metadata JSON + per-table config, when the catalog surfaces them). RAISES
        on a resolution failure — a 404 namespace/table, a transport error, a
        malformed loadTable response, or a MISSING metadata-location (fail loud,
        never a silent empty string)."""
        ...


# =============================================================================
# §2 — StorageBasedCatalog — the bucket+prefix conformer (no network).
# =============================================================================


struct StorageBasedCatalog(IcebergCatalog, Movable, Deinitable):
    """The "Hadoop"/bucket+prefix catalog conformer: a table's current
    metadata-location is KNOWN (registered up front, or derived by a
    version-hint pointer read the caller has already done), so resolution is a
    pure in-memory map lookup — ZERO network. This is the OTHER `IcebergCatalog`
    conformer, proving the seam covers the storage-based world too: the read
    path can be handed EITHER an `IcebergRestCatalog` or a `StorageBasedCatalog`
    and behaves identically (it calls `load_table` and consumes the returned
    metadata-location).

    Register `namespace.table -> metadata_location` via `register`. `load_table`
    resolves the composed `namespace.table` key.

    a plain owned-field struct — `List[String]` key/value registries, no
    pointer field, no wildcard origin."""

    var _keys: List[String]
    var _locations: List[String]

    def __init__(out self):
        self._keys = List[String]()
        self._locations = List[String]()

    def register(
        mut self,
        namespace: String,
        table: String,
        var metadata_location: String,
    ):
        """Register the KNOWN current metadata-location for `namespace.table`.
        The storage-based resolver's whole job (in the read path the caller
        typically derives this from the version-hint pointer / a fixed prefix)."""
        self._keys.append(_table_key(namespace, table))
        self._locations.append(metadata_location^)

    def load_table(
        mut self, namespace: String, table: String
    ) raises -> ResolvedTable:
        var key = _table_key(namespace, table)
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return ResolvedTable.with_location(String(self._locations[i]))
        raise Error(
            String("IcebergCatalogError: no table registered for '")
            + key
            + String("' (StorageBasedCatalog)")
        )


# =============================================================================
# §3 — shared helper.
# =============================================================================


def _table_key(namespace: String, table: String) -> String:
    """The `namespace.table` identity key. Pure — used by both the storage-based
    registry and the REST path segment building (which additionally
    percent-encodes; see the REST client)."""
    return namespace + String(".") + table
