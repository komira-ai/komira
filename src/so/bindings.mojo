"""`komira_add_sql_binding` on values: a SQL name bound to a source.

`add_sql_binding(session, name, source, scope)` decodes `source`, the bytes
of a `komira.plan.v1.WireBoundSource` (`plan_proto.bound_source`), and binds
the SQL name `name` on the session to it, replacing any table of that name
(of any kind). Its one kind today is `files`, a `WireFileSource`:

- a local path (no scheme) binds as `register_parquet` does: the files are
  listed and their footers read at the call, through the engine's footer
  reader;
- an `s3://` (or `s3a://`) location, and an `az://`, `abfs://` or `abfss://`
  one, binds a Parquet object, or a glob of objects, of that store. The
  footers are read at the call, through the store, with the credential the
  source names; the table's source names the bucket by its descriptor, as a
  plan does, and the session keeps the bucket's settings and the credential's
  NAME (`BoundStore`). A statement on the session reads it through the file
  systems `store_opener` builds, revealing the credential's values from the
  session's secret store for that run only.

The source carries a credential's name, never its value: the value is
whatever was sealed under that name on the session (`komira_credential_seal`)
when the bucket is read. A binding that is refused leaves the session's tables
as they were.

Refusals, each `Error("<CODE>: ...")`, checked in this order: a scope other
than `KOMIRA_BIND_SESSION` (`BIND_SCOPE_UNSUPPORTED`); an empty name
(`TABLE_NAME_EMPTY`); bytes that are not a `WireBoundSource`, or one that
names no kind (`BIND_SOURCE_MALFORMED`); then the source's own refusals
(`STORAGE_URL_REFUSED`, `BIND_SCOPE_NOT_A_TABLE`, `BIND_SOURCE_UNSUPPORTED`,
`CREDENTIALS_NOT_FOUND`, `CREDENTIAL_UNBOUND`, `CREDENTIAL_KIND_MISMATCH`,
`STORAGE_REGION_UNKNOWN`, `BIND_STORE_CONFLICT`), and the store's or the
footer reader's errors as they come. No message holds a credential's value,
and a location with user information is never echoed.
"""

from arrow.schema import Field, Schema, SchemaBuilder
from aws_core import AwsClock, AwsCredential
from azure_blob import (
    AzureCredential,
    AzureFsConfig,
    azure_config_for,
    azure_fs_config_for_url,
    parse_azure_url,
)
from azure_core import AzureSas, AzureSharedKey
from compression.codec_libraries import probe_codec_libraries
from fs.glob import glob_match_path, has_glob, split_static_prefix
from http_core.transport.io_stream import Connector
from objectstore_s3 import (
    AddressingStyle,
    S3Config,
    s3_endpoint_is_plaintext,
    s3_standard_retry_policy,
)
from parquet.decode_helpers import field_from_schema_element
from parquet.file_reader import read_parquet_preamble
from parquet.metadata_parser import parse_full_metadata
from parquet_api.metadata import FileMetaData
from parquet_api.types import FieldRepetitionType
from parquet_footers.footer_cache import footer_error
from parquet_footers.parquet_files import (
    PARQUET_FILES_SCHEMA_MISMATCH,
    PARQUET_GLOB_NO_MATCH,
    resolve_parquet_source,
)
from plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_S3,
    FsDescriptorPod,
)
from plan_proto.bound_source import (
    AddressingStyleWire,
    WireBoundSource,
    WireFileSource,
    WireSourceAccess,
)
from proto_codec import decode_proto
from scan_source.parquet_source import ParquetSource
from sdk_exec.engine_context import RegisteredTable
from sdk_exec.secret_capability import SecretCapability
from secret_registry.credential_consumer import CredentialConsumer
from sql.sql_ast import HIVE_PARTITIONING_AUTO

from .bound_store import BoundStore
from .credential_store import SessionSecretStore
from .credentials import SessionCredentials
from .session import Session
from .status import (
    KOMIRA_BIND_SESSION,
    KOMIRA_CRED_AWS_KEYS,
    KOMIRA_CRED_AWS_PROFILE,
    KOMIRA_CRED_AZURE_KEY,
    KOMIRA_CRED_AZURE_SAS,
    KOMIRA_FIELD_ACCOUNT,
    KOMIRA_FIELD_KEY,
    KOMIRA_FIELD_KEY_ID,
    KOMIRA_FIELD_SAS,
    KOMIRA_FIELD_SECRET,
    KOMIRA_FIELD_SESSION_TOKEN,
)
from .store_fs import (
    KernelStoreConnectors,
    StoreConnectors,
    StoreScanFs,
    kernel_store_connectors,
)

comptime BIND_SCOPE_UNSUPPORTED = "BIND_SCOPE_UNSUPPORTED"
"""Refusal: a binding scope other than `KOMIRA_BIND_SESSION`."""
comptime BIND_SOURCE_MALFORMED = "BIND_SOURCE_MALFORMED"
"""Refusal: the source bytes are not a `WireBoundSource` naming a kind."""
comptime BIND_SOURCE_UNSUPPORTED = "BIND_SOURCE_UNSUPPORTED"
"""Refusal: a source setting this library does not serve yet (Hive
partitioning or a signing service on files, an endpoint or region on a local
path, a region on Azure, `anonymous` or an `AwsProfile` on S3)."""
comptime BIND_SCOPE_NOT_A_TABLE = "BIND_SCOPE_NOT_A_TABLE"
"""Refusal: a location ending in `/` (a scope) bound as a table."""
comptime BIND_STORE_CONFLICT = "BIND_STORE_CONFLICT"
"""Refusal: a bucket another table of the session reads with other access
settings."""
comptime STORAGE_URL_REFUSED = "STORAGE_URL_REFUSED"
"""Refusal: a location or endpoint no store of this library reads."""
comptime STORAGE_REGION_UNKNOWN = "STORAGE_REGION_UNKNOWN"
"""Refusal: an S3 source with no region."""
comptime CREDENTIALS_NOT_FOUND = "CREDENTIALS_NOT_FOUND"
"""Refusal: a remote source naming no credential, or `ambient`."""
comptime CREDENTIAL_KIND_MISMATCH = "CREDENTIAL_KIND_MISMATCH"
"""Refusal: a credential of a kind its store does not take."""

comptime _AMBIENT = "ambient"
comptime _ANONYMOUS = "anonymous"


# ---- what the source asks for ----------------------------------------------


def _ascii_lower(s: String) -> String:
    return s.lower()


def _scheme_of(location: String) -> String:
    """The lower-cased scheme of `location` ("" when it has none)."""
    var sep = location.find("://")
    if sep <= 0:
        return String("")
    return _ascii_lower(String(location[byte=0:sep]))


def _has_user_info(location: String, container_at: Bool = False) -> Bool:
    """Whether the authority of `location` (between `://` and the next `/`)
    holds user information: an `@`, or, when `container_at` (Azure's
    `container@account.<svc>.core.windows.net` form, where the `@` ends the
    container), an `@` with a `:` before it (`user:password@`)."""
    var sep = location.find("://")
    if sep < 0:
        return False
    var rest = String(location[byte = sep + 3 : location.byte_length()])
    var slash = rest.find("/")
    var authority = rest.copy()
    if slash >= 0:
        authority = String(rest[byte=0:slash])
    var at = authority.find("@")
    if at < 0:
        return False
    if not container_at:
        return True
    return String(authority[byte=0:at]).find(":") >= 0


def _refuse(code: String, name: String, reason: String) -> Error:
    return Error(code + ": add_sql_binding name=" + name + ": " + reason)


def _check_endpoint(name: String, endpoint: String) raises:
    """An endpoint is `http://host[:port]` or `https://host[:port]`, with no
    user information, query or fragment."""
    if endpoint.byte_length() == 0:
        return
    if _has_user_info(endpoint):
        raise _refuse(
            STORAGE_URL_REFUSED, name, "an endpoint must not carry user information"
        )
    if endpoint.find("?") >= 0 or endpoint.find("#") >= 0:
        raise _refuse(
            STORAGE_URL_REFUSED,
            name,
            "an endpoint must not carry a query or a fragment",
        )
    var scheme = _scheme_of(endpoint)
    if scheme != "http" and scheme != "https":
        raise _refuse(
            STORAGE_URL_REFUSED,
            name,
            "an endpoint must start with http:// or https://",
        )


# ---- revealing a sealed credential -----------------------------------------


struct _Revealed(CredentialConsumer, Movable):
    """Copies the one value revealed to it."""

    var text: String

    def __init__(out self):
        self.text = String("")

    def consume(mut self, secret: Span[UInt8, _]) raises:
        self.text = String(StringSlice(from_utf8=secret))


def _reveal(c: SessionCredentials, name: String, field: Int32) raises -> String:
    """One field of the value sealed under `name`, through its
    `SecretCapability` over the session's secret store."""
    var consumer = _Revealed()
    SecretCapability(c.node_id_of(name, field)).open_connection_for[
        SessionSecretStore, _Revealed
    ](c.secret_bindings(), c.secret_store(), consumer)
    return consumer.text.copy()


def _aws_credential(c: SessionCredentials, name: String) raises -> AwsCredential:
    var token = String("")
    if c.has_field(name, KOMIRA_FIELD_SESSION_TOKEN):
        token = _reveal(c, name, KOMIRA_FIELD_SESSION_TOKEN)
    return AwsCredential(
        _reveal(c, name, KOMIRA_FIELD_KEY_ID),
        _reveal(c, name, KOMIRA_FIELD_SECRET),
        token^,
    )


def _azure_credential(
    c: SessionCredentials, store: BoundStore
) raises -> AzureCredential:
    if store.credential == _ANONYMOUS:
        return AzureCredential.anonymous()
    if c.kind_of(store.credential) == KOMIRA_CRED_AZURE_KEY:
        return AzureCredential.shared_key(
            AzureSharedKey(
                store.account, _reveal(c, store.credential, KOMIRA_FIELD_KEY)
            )
        )
    return AzureCredential.sas(
        AzureSas(_reveal(c, store.credential, KOMIRA_FIELD_SAS))
    )


def _s3_config(store: BoundStore) raises -> S3Config:
    var addressing = (
        AddressingStyle.path() if store.path_style else AddressingStyle.virtual_hosted()
    )
    return S3Config(
        store.region,
        endpoint=store.endpoint,
        addressing=addressing,
        retry=s3_standard_retry_policy(),
    )


def _add_store[
    S3C: Connector, AZC: Connector, K: AwsClock & Copyable & Deinitable
](
    mut opener: StoreScanFs[S3C, AZC, K],
    c: SessionCredentials,
    store: BoundStore,
) raises:
    """Serve `store`'s bucket on `opener`, with the values sealed under its
    credential's name now."""
    if store.scheme == FS_SCHEME_S3:
        opener.add_s3(store.bucket, _s3_config(store), _aws_credential(c, store.credential))
    else:
        opener.add_azure(
            store.bucket,
            AzureFsConfig(
                account=store.account,
                endpoint=store.endpoint,
                path_style=store.path_style,
            ),
            _azure_credential(c, store),
        )


def store_opener[
    S3C: Connector, AZC: Connector, K: AwsClock & Copyable & Deinitable
](
    session: Session, var connectors: StoreConnectors[S3C, AZC, K]
) raises -> StoreScanFs[S3C, AZC, K]:
    """The file systems one statement on `session` reads its bound object
    stores through: every bucket a bound table names, each with the values
    sealed under its credential's name when this is called. A scan of any
    other bucket is refused by the opener with `SCAN_FS_UNSERVED`.

    Raises:
        `CREDENTIAL_UNBOUND` or `CREDENTIALS_INVALID` when a credential a
        bound table names cannot be read (`SessionCredentials`); the store's
        own refusal of its settings.
    """
    var opener = StoreScanFs[S3C, AZC, K](connectors^)
    for i in range(len(session.bound_stores.stores)):
        ref store = session.bound_stores.stores[i]
        if not opener.serves(store.scheme, store.bucket):
            _add_store(opener, session.credentials, store)
    return opener^


# ---- one bound source --------------------------------------------------------


def _decode(name: String, var source: List[UInt8]) raises -> WireFileSource:
    var bound: WireBoundSource
    try:
        bound = decode_proto[WireBoundSource](source^)
    except:
        raise _refuse(
            BIND_SOURCE_MALFORMED,
            name,
            "the source is not a komira.plan.v1.WireBoundSource",
        )
    if bound._oneof0_case != 1 or not bound.files:
        raise _refuse(BIND_SOURCE_MALFORMED, name, "the source names no kind")
    return bound.files.value().copy()


def _access_of(files: WireFileSource) -> WireSourceAccess:
    if files.access:
        return files.access.value().copy()
    return WireSourceAccess(
        String(""), String(""), String(""), AddressingStyleWire(0), String("")
    )


def _path_style(access: WireSourceAccess) -> Bool:
    """Path-style addressing when the source asks for it, or by default on an
    endpoint of its own (an emulator); the provider's own endpoint is
    virtual-hosted by default."""
    var a = access.addressing.number()
    if a == AddressingStyleWire.ADDRESSING_STYLE_WIRE_PATH:
        return True
    if a == AddressingStyleWire.ADDRESSING_STYLE_WIRE_VHOST:
        return False
    return access.endpoint.byte_length() > 0


def _remote_credential(
    name: String, session: Session, credential: String, scheme: UInt8
) raises:
    """Refuse a credential the store of `scheme` cannot read with."""
    if credential.byte_length() == 0 or credential == _AMBIENT:
        raise _refuse(
            CREDENTIALS_NOT_FOUND,
            name,
            "the source names no credential, or ambient, which this library"
            " does not resolve; name a sealed credential",
        )
    if credential == _ANONYMOUS:
        if scheme == FS_SCHEME_S3:
            raise _refuse(
                BIND_SOURCE_UNSUPPORTED,
                name,
                "credential=anonymous: unsigned s3:// reads are not served",
            )
        return
    var kind = session.credentials.kind_of(credential)
    if scheme == FS_SCHEME_S3:
        if kind == KOMIRA_CRED_AWS_KEYS:
            return
        if kind == KOMIRA_CRED_AWS_PROFILE:
            raise _refuse(
                BIND_SOURCE_UNSUPPORTED,
                name,
                "credential=" + credential + ": an AwsProfile is not read by"
                " this library; seal AwsKeys",
            )
    elif kind == KOMIRA_CRED_AZURE_KEY or kind == KOMIRA_CRED_AZURE_SAS:
        return
    var store = String("s3://") if scheme == FS_SCHEME_S3 else String("az://")
    raise _refuse(
        CREDENTIAL_KIND_MISMATCH,
        name,
        "credential=" + credential + " does not fit a " + store + " source",
    )


struct _Remote(Movable):
    """A remote location resolved: the store, how it is reached, and the key
    (or key pattern) within its bucket."""

    var store: BoundStore
    var key: String

    def __init__(out self, var store: BoundStore, var key: String):
        self.store = store^
        self.key = key^


def _s3_remote(
    name: String, location: String, access: WireSourceAccess
) raises -> _Remote:
    var sep = location.find("://")
    var rest = String(location[byte = sep + 3 : location.byte_length()])
    var slash = rest.find("/")
    var bucket = rest.copy()
    var key = String("")
    if slash >= 0:
        bucket = String(rest[byte=0:slash])
        key = String(rest[byte = slash + 1 : rest.byte_length()])
    if bucket.byte_length() == 0:
        raise _refuse(STORAGE_URL_REFUSED, name, "an s3:// location names no bucket")
    if key.byte_length() == 0 or key.endswith("/"):
        raise _refuse(
            BIND_SCOPE_NOT_A_TABLE,
            name,
            location + " is a scope, not a table; name an object or a glob",
        )
    if access.region.byte_length() == 0:
        raise _refuse(
            STORAGE_REGION_UNKNOWN,
            name,
            location + " names no region; give the source its region",
        )
    if access.endpoint.byte_length() > 0:
        _ = s3_endpoint_is_plaintext(access.endpoint)
    var store = BoundStore(
        table=name.lower(),
        scheme=FS_SCHEME_S3,
        bucket=bucket^,
        credential=access.credential,
        endpoint=access.endpoint,
        region=access.region,
        path_style=_path_style(access),
        account=String(""),
    )
    return _Remote(store^, key^)


def _azure_remote(
    name: String, session: Session, location: String, access: WireSourceAccess
) raises -> _Remote:
    if access.region.byte_length() > 0:
        raise _refuse(
            BIND_SOURCE_UNSUPPORTED,
            name,
            "an az:// source takes no region",
        )
    var url = parse_azure_url(location)
    if url.path.byte_length() == 0 or url.path.endswith("/"):
        raise _refuse(
            BIND_SCOPE_NOT_A_TABLE,
            name,
            location + " is a scope, not a table; name a blob or a glob",
        )
    var account = String("")
    if access.credential != _ANONYMOUS:
        account = _reveal(
            session.credentials, access.credential, KOMIRA_FIELD_ACCOUNT
        )
    var config = azure_fs_config_for_url(
        url,
        AzureFsConfig(
            account=account^,
            endpoint=access.endpoint,
            path_style=_path_style(access),
        ),
    )
    _ = azure_config_for(config)
    var store = BoundStore(
        table=name.lower(),
        scheme=FS_SCHEME_AZURE,
        bucket=url.container,
        credential=access.credential,
        endpoint=config.endpoint,
        region=String(""),
        path_style=config.path_style,
        account=config.account,
    )
    return _Remote(store^, url.path)


def _flat_schema(url: String, meta: FileMetaData) raises -> Schema:
    """The Arrow schema of a flat file's footer, as the engine's footer reader
    gives it (`parquet_footers`)."""
    if len(meta.schema) == 0:
        raise Error(footer_error(url, "no schema in the footer"))
    for c in range(1, len(meta.schema)):
        ref e = meta.schema[c]
        var repeated = False
        if e.repetition_type:
            repeated = e.repetition_type.value() == FieldRepetitionType.REPEATED
        if e.num_children > 0 or repeated:
            raise Error(
                footer_error(
                    url,
                    "column '" + e.name
                    + "' is nested or repeated; only flat files are read",
                )
            )
    var sb = SchemaBuilder()
    for c in range(1, len(meta.schema)):
        sb.add_field(field_from_schema_element(meta.schema[c]))
    return sb.build()


def _schema_difference(first: Schema, other: Schema) -> String:
    """The first way `other` differs from `first` (names, types, decimal
    precision and scale, nullability), or "" when they agree."""
    if other.num_columns() != first.num_columns():
        return (
            "it has " + String(other.num_columns()) + " columns, the first"
            " file has " + String(first.num_columns())
        )
    for i in range(first.num_columns()):
        var n = first.field_name(i)
        if (
            other.field_name(i) != n
            or other.field_arrow_type(i) != first.field_arrow_type(i)
            or other.field_nullable(i) != first.field_nullable(i)
            or other.field_decimal_precision(i) != first.field_decimal_precision(i)
            or other.field_decimal_scale(i) != first.field_decimal_scale(i)
        ):
            return (
                "column " + String(i) + " ('" + other.field_name(i) + "') differs"
                " from the first file's ('" + n + "')"
            )
    return String("")


def _sorted(var keys: List[String]) -> List[String]:
    for i in range(1, len(keys)):
        var j = i
        while j > 0 and keys[j - 1] > keys[j]:
            keys.swap_elements(j - 1, j)
            j -= 1
    return keys^


def _remote_source[
    S3C: Connector, AZC: Connector, K: AwsClock & Copyable & Deinitable
](
    name: String,
    session: Session,
    remote: _Remote,
    var connectors: StoreConnectors[S3C, AZC, K],
    node_id: Int,
) raises -> ParquetSource:
    """The keys `remote` names, listed now when it is a glob, and their
    footers read through the store: the catalog source of the table."""
    var opener = StoreScanFs[S3C, AZC, K](connectors^)
    _add_store(opener, session.credentials, remote.store)
    var fs = opener.open_scan_fs(remote.store.scheme, remote.store.bucket)
    var prefix = FsDescriptorPod.cloud(
        remote.store.scheme, remote.store.bucket, -1
    ).url_prefix() + "/"
    var keys = List[String]()
    if has_glob(remote.key):
        var parts = split_static_prefix(remote.key)
        var listed = fs.list(parts[0])
        for i in range(len(listed)):
            if glob_match_path(remote.key, listed[i]):
                keys.append(listed[i].copy())
        if len(keys) == 0:
            raise Error(
                String(PARQUET_GLOB_NO_MATCH)
                + ": no file matches '" + prefix + remote.key + "'"
            )
        keys = _sorted(keys^)
    else:
        keys.append(remote.key.copy())
    var first = Schema()
    for i in range(len(keys)):
        var preamble = read_parquet_preamble(fs, keys[i])
        var meta = parse_full_metadata(
            preamble.metadata_bytes.view_range_ro(0, preamble.metadata_length)
        )
        var schema = _flat_schema(prefix + keys[i], meta)
        if i == 0:
            first = schema^
            continue
        var diff = _schema_difference(first, schema)
        if diff.byte_length() > 0:
            raise Error(
                String(PARQUET_FILES_SCHEMA_MISMATCH)
                + ": '" + prefix + keys[i] + "': " + diff
            )
    return ParquetSource.partitioned(
        keys^, first^, List[Field](), List[List[String]]()
    ).with_fs_descriptor(
        FsDescriptorPod.cloud(remote.store.scheme, remote.store.bucket, node_id)
    )


def _check_conflict(name: String, session: Session, store: BoundStore) raises:
    """Refuse a bucket another table reads with other settings: a run reads
    each bucket through one file system."""
    for i in range(len(session.bound_stores.stores)):
        ref other = session.bound_stores.stores[i]
        if other.table == store.table:
            continue
        if other.scheme != store.scheme or other.bucket != store.bucket:
            continue
        if not other.same_access(store):
            raise _refuse(
                BIND_STORE_CONFLICT,
                name,
                FsDescriptorPod.cloud(store.scheme, store.bucket, -1).url_prefix()
                + " is read by table '" + other.table + "' with another"
                " credential or other settings; one session reads a bucket"
                " one way",
            )


def forget_table(mut session: Session, name: String):
    """Drop every trace of the table `name`: its catalog entry, its paths
    (`EngineContext.tables`) and its bound store."""
    _ = session.engine.catalog.remove(name)
    var key = name.lower()
    var kept = List[RegisteredTable]()
    for i in range(len(session.engine.tables)):
        if session.engine.tables[i].name != key:
            kept.append(session.engine.tables[i].copy())
    session.engine.tables = kept^
    session.bound_stores.forget(name)


def _check_local_access(name: String, access: WireSourceAccess) raises:
    """A local path is read under the process's identity, with no store
    settings."""
    if access.credential.byte_length() > 0 and access.credential != _AMBIENT:
        raise _refuse(
            CREDENTIAL_KIND_MISMATCH,
            name,
            "credential=" + access.credential + " does not fit a local path",
        )
    if (
        access.endpoint.byte_length() > 0
        or access.region.byte_length() > 0
        or access.addressing.number() != 0
    ):
        raise _refuse(
            BIND_SOURCE_UNSUPPORTED,
            name,
            "a local path takes no endpoint, region or addressing",
        )


def add_sql_binding_with[
    S3C: Connector, AZC: Connector, K: AwsClock & Copyable & Deinitable
](
    mut session: Session,
    name: String,
    var source: List[UInt8],
    scope: Int32,
    var connectors: StoreConnectors[S3C, AZC, K],
) raises:
    """`add_sql_binding`, reading a remote source's footers through the
    connectors and clock `connectors` gives (module header).

    Raises:
        The refusals of the module header; nothing is bound then.
    """
    if scope != KOMIRA_BIND_SESSION:
        raise Error(
            String(BIND_SCOPE_UNSUPPORTED)
            + ": add_sql_binding scope="
            + String(scope)
            + ": only KOMIRA_BIND_SESSION (1) binds a source"
        )
    if name.byte_length() == 0:
        raise Error("TABLE_NAME_EMPTY: a table name must not be empty")
    var files = _decode(name, source^)
    var access = _access_of(files)
    var location = files.location.copy()
    var scheme = _scheme_of(location)
    var azure = scheme == "az" or scheme == "abfs" or scheme == "abfss"
    if _has_user_info(location, azure):
        raise _refuse(
            STORAGE_URL_REFUSED,
            name,
            "a location must not carry user information; a credential is"
            " named by the source, never written into its location",
        )
    if access.signing_service.byte_length() > 0:
        raise _refuse(
            BIND_SOURCE_UNSUPPORTED, name, "a file source takes no signing service"
        )
    _check_endpoint(name, access.endpoint)
    probe_codec_libraries()
    if scheme.byte_length() == 0:
        _check_local_access(name, access)
        var local = resolve_parquet_source(
            session.engine.footers, location, HIVE_PARTITIONING_AUTO, True
        )
        forget_table(session, name)
        session.engine.catalog.add_parquet_source(name, local^)
        session.engine.tables.append(RegisteredTable(name.lower(), location))
        return
    if files.hive_partitioning:
        raise _refuse(
            BIND_SOURCE_UNSUPPORTED,
            name,
            "Hive partitioning is not read from an object store yet",
        )
    var store_scheme: UInt8
    if scheme == "s3" or scheme == "s3a":
        store_scheme = FS_SCHEME_S3
    elif azure:
        store_scheme = FS_SCHEME_AZURE
    else:
        raise _refuse(
            STORAGE_URL_REFUSED,
            name,
            "no store of this library reads '" + scheme + "://' locations;"
            " s3:// and az:// (abfs://, abfss://) are read",
        )
    if location.find("?") >= 0 or location.find("#") >= 0:
        raise _refuse(
            STORAGE_URL_REFUSED,
            name,
            "a location must not carry a query or a fragment",
        )
    _remote_credential(name, session, access.credential, store_scheme)
    var remote: _Remote
    if store_scheme == FS_SCHEME_S3:
        remote = _s3_remote(name, location, access)
    else:
        remote = _azure_remote(name, session, location, access)
    _check_conflict(name, session, remote.store)
    var node_id = session.bound_stores.next_node_id()
    var ps = _remote_source(name, session, remote, connectors^, node_id)
    forget_table(session, name)
    session.engine.catalog.add_parquet_source(name, ps^)
    session.bound_stores.stores.append(remote.store.copy())


def add_sql_binding(
    mut session: Session, name: String, var source: List[UInt8], scope: Int32
) raises:
    """Bind the SQL name `name` on `session` to the `WireBoundSource` in
    `source`, replacing any table of that name: what `komira_add_sql_binding`
    does (module header). A remote source's footers are read through
    http_client's kernel connectors, plaintext only for an `http://`
    endpoint.

    Raises:
        The refusals of the module header; nothing is bound then.
    """
    add_sql_binding_with(
        session, name, source^, scope, kernel_store_connectors()
    )
