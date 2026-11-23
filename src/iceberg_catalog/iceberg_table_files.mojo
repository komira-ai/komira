# =============================================================================
# iceberg_catalog/iceberg_table_files.mojo — the object store a table's files
#   are written to, addressed by the absolute URIs a catalog and a manifest
#   hold.
# =============================================================================
#
# A table's metadata names its files by URI (`s3://warehouse/db/t/data/...`).
# `TableFiles` is one object store and the URI prefix it serves
# (`s3://warehouse`): a URI under that prefix is the store key made of
# everything after the prefix and its `/`, and any other URI is refused before
# the store is touched, as
#
#     ICEBERG_LOCATION_REFUSED: <uri> is not under <prefix>, the store this
#     write was given
#
# so a table whose location or properties point somewhere the statement has no
# store for cannot make it write to the wrong place. A URI under the prefix
# that does not name one object by a normalized key (it ends in `/`, has a
# `.` or `..` segment, or repeats a `/`) is refused as
# `ICEBERG_LOCATION_REFUSED: <uri> does not name an object under <prefix>`.
#
# `put`, `get` and `delete` are the store's; a store error is raised as the
# store raised it. `clone` is a second handle on the same data (the store's own
# `clone`), which is how the writer of one statement and the caller that
# cleans up share the store.
# =============================================================================

from objectstore.path import Path
from objectstore.store import CloneableConditionalWriteStore

from .iceberg_rest_errors import ICEBERG_LOCATION_REFUSED


struct TableFiles[S: CloneableConditionalWriteStore](Movable):
    """An object store and the URI prefix it serves (module header)."""

    var _store: Self.S
    var _prefix: String

    def __init__(out self, var store: Self.S, var prefix: String):
        """`prefix` is the URI the store's root is, such as `s3://warehouse`;
        trailing `/` characters are dropped."""
        self._store = store^
        var p = prefix^
        while p.endswith(String("/")):
            p = String(p[byte=0 : p.byte_length() - 1])
        self._prefix = p^

    def prefix(self) -> String:
        """The URI prefix, without a trailing `/`."""
        return String(self._prefix)

    def clone(self) -> Self:
        """A second handle on the same store and prefix."""
        return Self(self._store.clone(), String(self._prefix))

    def key_of(self, uri: String) raises -> Path:
        """The store key of `uri`; raises `ICEBERG_LOCATION_REFUSED` when the
        URI is not under the prefix or does not name one object."""
        var head = self._prefix + String("/")
        if not uri.startswith(head):
            raise Error(
                String(ICEBERG_LOCATION_REFUSED)
                + String(": ")
                + uri
                + String(" is not under ")
                + self._prefix
                + String(", the store this write was given")
            )
        var rest = String(uri[byte=head.byte_length() : uri.byte_length()])
        var key = Path(String(""))
        var named = False
        if rest.byte_length() > 0 and not rest.endswith(String("/")):
            try:
                key = Path.parse(rest)
                named = key.raw() == rest
            except:
                named = False
        if not named:
            raise Error(
                String(ICEBERG_LOCATION_REFUSED)
                + String(": ")
                + uri
                + String(" does not name an object under ")
                + self._prefix
            )
        return key

    def put(self, uri: String, bytes: List[UInt8]) raises:
        """Write `bytes` at `uri`, replacing any object there."""
        _ = self._store.put(self.key_of(uri), bytes)

    def get(self, uri: String) raises -> List[UInt8]:
        """The bytes of the object at `uri`."""
        return self._store.get(self.key_of(uri))

    def delete(self, uri: String) raises:
        """Delete the object at `uri`; deleting an absent object succeeds."""
        self._store.delete(self.key_of(uri))
