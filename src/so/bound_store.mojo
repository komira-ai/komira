"""The object stores a session's SQL bindings read, as plain values.

A table bound to an `s3://` or `az://` location (`bindings.add_sql_binding`)
is a Parquet source in the session's catalog whose descriptor names the store
and the bucket (`FsDescriptorPod`), as a plan names it. What reaching that
bucket takes is kept here, one `BoundStore` per bound table: the store, the
bucket (an Azure container), the NAME of the credential and the settings
(endpoint, region, addressing). No credential value is ever held here; the
run reveals the values from the session's credentials when it builds the
file systems it reads through (`bindings.store_opener`).
"""


@fieldwise_init
struct BoundStore(Copyable, Movable):
    """How one bound table's bucket is reached (module header)."""

    var table: String
    """The SQL name the table is bound under, lower-cased as the catalog
    folds it."""
    var scheme: UInt8
    """`plan_expr`'s `FS_SCHEME_S3` or `FS_SCHEME_AZURE`."""
    var bucket: String
    """The S3 bucket, or the Azure container."""
    var credential: String
    """The name of the sealed credential the store is read with, or
    `anonymous`."""
    var endpoint: String
    """The store's endpoint; "" for the provider's own."""
    var region: String
    """The S3 region requests are signed for; "" for Azure."""
    var path_style: Bool
    """Whether the bucket (S3) or the account (Azure) is addressed in the
    path rather than the host."""
    var account: String
    """The Azure storage account; "" for S3."""

    def same_access(self, other: BoundStore) -> Bool:
        """Whether `other` reaches its bucket the same way: the same store,
        bucket, credential name, endpoint, region, addressing and account."""
        return (
            self.scheme == other.scheme
            and self.bucket == other.bucket
            and self.credential == other.credential
            and self.endpoint == other.endpoint
            and self.region == other.region
            and self.path_style == other.path_style
            and self.account == other.account
        )


struct BoundStores(Movable):
    """The `BoundStore` of every table a session holds bound to an object
    store, and the scan node ids the catalog's sources carry."""

    var stores: List[BoundStore]
    var _next_node: Int

    def __init__(out self):
        """No store bound."""
        self.stores = List[BoundStore]()
        self._next_node = 0

    def next_node_id(mut self) -> Int:
        """A node id no source bound on this session carries yet."""
        var id = self._next_node
        self._next_node += 1
        return id

    def forget(mut self, table: String):
        """Drop the store of `table` (any case), if it has one."""
        var key = table.lower()
        var kept = List[BoundStore]()
        for i in range(len(self.stores)):
            if self.stores[i].table != key:
                kept.append(self.stores[i].copy())
        self.stores = kept^
