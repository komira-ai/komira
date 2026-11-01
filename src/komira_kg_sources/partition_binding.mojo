# =============================================================================
# partition_binding -- which raw store and which lineage a partition lives in.
# =============================================================================
#
# A host that serves several partitions keeps each partition's raw records under
# one `RawStore` prefix and its graph under one snapshot lineage prefix.
# `PartitionBinding` records that choice for a partition, with the source it
# comes from; `PartitionBindingStore` keeps one binding object per partition on a
# `ConditionalWriteStore`.
#
#   * A partition binds exactly one raw store and one lineage, and a binding is
#     never changed: `bind` writes with create-if-absent, an identical second
#     bind reports `created = False`, and any other binding for the same
#     partition (another source, another store prefix, another lineage prefix) is
#     refused with an error naming what is bound. Re-pointing a partition is a
#     decision for the host, made by choosing a new partition id.
#   * The raw store prefix and the lineage prefix must differ and neither may lie
#     under the other, so the two kinds of object cannot share a directory.
#   * The source system, source kind and facet are opaque strings. The host
#     passes the set of source systems it knows when it builds the store, and a
#     bind of any other system is refused; it may also pass sets of source kinds
#     and facets (an empty set means the host does not constrain that field). The
#     sets are checked when a binding is made, not when one is read back.
#
# Stored form. One object per partition at `<prefix>/binding/<hash>.bind`, where
# the hash is `fnv1a64_hex` of the partition id. The hash is not trusted to be
# unique: the object records the partition id and a read that finds another
# raises. The body is
#     u8 format version (1)
#     six strings, each a u32 length and its bytes: partition id, source system,
#       source kind, facet, raw store prefix, lineage prefix
# in little-endian. A body that is truncated, names another version, holds a
# length past its end or text that is not UTF-8, or has bytes after the last
# string, is refused with an error naming the defect.
# =============================================================================

from komira_kg_format import fnv1a64_hex
from komira_objectstore.cas_manifest import is_not_found, is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from .framing import (
    check_prefix,
    check_text,
    expect_end,
    get_text,
    get_u8,
    is_hash_name,
    name_without_suffix,
    prefixes_nest,
    put_text,
    put_u8,
    sort_strings,
)

comptime BINDING_FORMAT_VERSION: Int = 1
"""The format version of a stored binding; the decoder accepts only this."""

comptime _WHO: String = "PartitionBindingStore"
comptime _SUFFIX: String = ".bind"


struct PartitionBinding(Copyable, Movable):
    """The raw store and lineage one partition uses, and where it comes from.

    Fields:
        partition_id: The partition; an opaque string, never empty.
        source_system: The host's name for the system the partition's records
            come from; must be in the host's set of known systems.
        source_kind: The host's name for the kind of source within the system.
        facet: An opaque label for the partition's records, "" for none.
        raw_prefix: The key prefix of the partition's `RawStore`.
        lineage_prefix: The key prefix of the partition's snapshot lineage.
    """

    var partition_id: String
    var source_system: String
    var source_kind: String
    var facet: String
    var raw_prefix: String
    var lineage_prefix: String

    def __init__(
        out self,
        var partition_id: String,
        var source_system: String,
        var source_kind: String,
        var facet: String,
        var raw_prefix: String,
        var lineage_prefix: String,
    ):
        self.partition_id = partition_id^
        self.source_system = source_system^
        self.source_kind = source_kind^
        self.facet = facet^
        self.raw_prefix = raw_prefix^
        self.lineage_prefix = lineage_prefix^

    def same_as(self, other: PartitionBinding) -> Bool:
        """Whether every field of the two bindings is equal."""
        return (
            self.partition_id == other.partition_id
            and self.source_system == other.source_system
            and self.source_kind == other.source_kind
            and self.facet == other.facet
            and self.raw_prefix == other.raw_prefix
            and self.lineage_prefix == other.lineage_prefix
        )


def encode_binding(binding: PartitionBinding) raises -> List[UInt8]:
    """The stored form of `binding` (see the file header).

    Raises:
        If a field is over the size limit.
    """
    var out = List[UInt8]()
    put_u8(out, BINDING_FORMAT_VERSION)
    put_text(out, binding.partition_id, "partition id")
    put_text(out, binding.source_system, "source system")
    put_text(out, binding.source_kind, "source kind")
    put_text(out, binding.facet, "facet")
    put_text(out, binding.raw_prefix, "raw store prefix")
    put_text(out, binding.lineage_prefix, "lineage prefix")
    return out^


def decode_binding(body: List[UInt8]) raises -> PartitionBinding:
    """The binding stored in `body` (the inverse of `encode_binding`).

    Raises:
        If the body is empty or truncated, names an unknown format version,
        holds a length past the end or text that is not UTF-8, or has bytes
        after the last string.
    """
    var off = 0
    var version = get_u8(body, off, _WHO, "format version")
    if version != BINDING_FORMAT_VERSION:
        raise Error(
            _WHO
            + ": format version "
            + String(version)
            + " is not the supported "
            + String(BINDING_FORMAT_VERSION)
        )
    var partition_id = get_text(body, off, _WHO, "partition id")
    var source_system = get_text(body, off, _WHO, "source system")
    var source_kind = get_text(body, off, _WHO, "source kind")
    var facet = get_text(body, off, _WHO, "facet")
    var raw_prefix = get_text(body, off, _WHO, "raw store prefix")
    var lineage_prefix = get_text(body, off, _WHO, "lineage prefix")
    expect_end(body, off, _WHO)
    return PartitionBinding(
        partition_id^,
        source_system^,
        source_kind^,
        facet^,
        raw_prefix^,
        lineage_prefix^,
    )


def _contains(items: List[String], value: String) -> Bool:
    for i in range(len(items)):
        if items[i] == value:
            return True
    return False


def _joined(items: List[String]) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += ", "
        out += items[i]
    return out^


def _key_of(partition_id: String) -> String:
    return fnv1a64_hex(partition_id.as_bytes())


struct PartitionBindingStore[Store: ConditionalWriteStore](Movable):
    """Partition bindings on a conditional-write store, one object each (see the
    file header).

    Parameters:
        Store: The object store; the in-memory and local-file stores and the
            cloud stores all conform.
    """

    var _store: Self.Store
    var _prefix: String
    var _systems: List[String]
    var _kinds: List[String]
    var _facets: List[String]

    def __init__(
        out self,
        var store: Self.Store,
        var prefix: String,
        var known_source_systems: List[String],
        var known_source_kinds: List[String] = List[String](),
        var known_facets: List[String] = List[String](),
    ) raises:
        """Bindings under `<prefix>/binding/` on `store`.

        Args:
            store: The object store.
            prefix: The key prefix: not empty, no control byte, no leading or
                trailing '/', no '//'.
            known_source_systems: Every source system a binding may name. An
                empty list refuses every bind.
            known_source_kinds: The source kinds a binding may name; empty for
                no constraint.
            known_facets: The facets a binding may name; empty for no
                constraint.

        Raises:
            If the prefix is not acceptable.
        """
        check_prefix("binding store prefix", prefix)
        self._store = store^
        self._prefix = prefix^
        self._systems = known_source_systems^
        self._kinds = known_source_kinds^
        self._facets = known_facets^

    def prefix(self) -> String:
        """The key prefix this store writes under."""
        return self._prefix

    def _dir(self) -> String:
        return self._prefix + "/binding/"

    def _path_for(self, partition_id: String) raises -> Path:
        return Path.parse(self._dir() + _key_of(partition_id) + _SUFFIX)

    def validate(self, binding: PartitionBinding) raises:
        """Refuse a binding this store would not write.

        Raises:
            If the partition id, source system or source kind is empty or holds
            a control byte; if the system is not among the known systems, or the
            kind or facet is outside a non-empty known set; if a prefix is not
            acceptable; or if the raw store prefix and the lineage prefix are
            equal or nest.
        """
        check_text("partition id", binding.partition_id, False)
        check_text("source system", binding.source_system, False)
        check_text("source kind", binding.source_kind, False)
        check_text("facet", binding.facet, True)
        if not _contains(self._systems, binding.source_system):
            raise Error(
                _WHO
                + ": unknown source system '"
                + binding.source_system
                + "' (known: "
                + _joined(self._systems)
                + ")"
            )
        if len(self._kinds) > 0 and not _contains(self._kinds, binding.source_kind):
            raise Error(
                _WHO
                + ": unknown source kind '"
                + binding.source_kind
                + "' (known: "
                + _joined(self._kinds)
                + ")"
            )
        if len(self._facets) > 0 and not _contains(self._facets, binding.facet):
            raise Error(
                _WHO
                + ": unknown facet '"
                + binding.facet
                + "' (known: "
                + _joined(self._facets)
                + ")"
            )
        check_prefix("raw store prefix", binding.raw_prefix)
        check_prefix("lineage prefix", binding.lineage_prefix)
        if prefixes_nest(binding.raw_prefix, binding.lineage_prefix):
            raise Error(
                _WHO
                + ": the raw store prefix '"
                + binding.raw_prefix
                + "' and the lineage prefix '"
                + binding.lineage_prefix
                + "' must differ and neither may lie under the other"
            )

    def bind(mut self, binding: PartitionBinding) raises -> Bool:
        """Bind a partition, once.

        Args:
            binding: The binding to record.

        Returns:
            True if this call wrote the binding; False if the same binding was
            already recorded.

        Raises:
            If `validate` refuses the binding, if the partition is already bound
            to anything else (nothing is written), or if the store fails for any
            reason but the lost race.
        """
        self.validate(binding)
        var body = encode_binding(binding)
        var path = self._path_for(binding.partition_id)
        try:
            _ = self._store.conditional_put(
                path, body^, WritePrecondition.if_none_match_star()
            )
            return True
        except e:
            if not is_precondition(String(e)):
                raise e^
        var existing = self.get(binding.partition_id)
        if existing.same_as(binding):
            return False
        raise Error(
            _WHO
            + ".bind: partition '"
            + binding.partition_id
            + "' is already bound (system '"
            + existing.source_system
            + "', kind '"
            + existing.source_kind
            + "', facet '"
            + existing.facet
            + "', raw store '"
            + existing.raw_prefix
            + "', lineage '"
            + existing.lineage_prefix
            + "'); a partition binds one raw store and one lineage"
        )

    def find(self, partition_id: String) raises -> Optional[PartitionBinding]:
        """The binding of `partition_id`, or nothing if it is unbound.

        Raises:
            If the store fails for any reason but "not found", the object does
            not decode, or it holds another partition id (a hash collision).
        """
        check_text("partition id", partition_id, False)
        var path = self._path_for(partition_id)
        var body: List[UInt8]
        try:
            body = self._store.get(path)
        except e:
            if is_not_found(String(e)):
                return Optional[PartitionBinding]()
            raise e^
        var binding = decode_binding(body)
        if binding.partition_id != partition_id:
            raise Error(
                _WHO
                + ": the object at "
                + path.raw()
                + " holds the binding of another partition (a hash collision);"
                " refusing to use it"
            )
        return Optional[PartitionBinding](binding^)

    def get(self, partition_id: String) raises -> PartitionBinding:
        """The binding of `partition_id`.

        Raises:
            If the partition is unbound, or for any reason `find` raises.
        """
        var found = self.find(partition_id)
        if not found:
            raise Error(_WHO + ".get: partition '" + partition_id + "' is unbound")
        return found.take()

    def has(self, partition_id: String) raises -> Bool:
        """Whether `partition_id` is bound."""
        return Bool(self.find(partition_id))

    def list_bindings(self) raises -> List[PartitionBinding]:
        """Every binding, ordered by partition id.

        Raises:
            If the store fails, an object under the binding directory is not
            named like a binding, or one does not decode or sits under a name its
            partition id does not hash to.
        """
        var dir = self._dir()
        var listing = self._store.list_with_delimiter(Path.parse(dir.copy()))
        var ids = List[String]()
        var by_id = List[PartitionBinding]()
        for i in range(len(listing.objects)):
            var location = listing.objects[i].location.copy()
            var name = name_without_suffix(location, dir, _SUFFIX)
            if not is_hash_name(name):
                raise Error(
                    _WHO
                    + ".list_bindings: '"
                    + location
                    + "' is not a binding name"
                )
            var body = self._store.get(Path.parse(location.copy()))
            var binding = decode_binding(body)
            if _key_of(binding.partition_id) != name:
                raise Error(
                    _WHO
                    + ".list_bindings: the object at '"
                    + location
                    + "' holds a partition id that does not hash to its name"
                )
            ids.append(binding.partition_id.copy())
            by_id.append(binding^)
        var sorted_ids = ids.copy()
        sort_strings(sorted_ids)
        var out = List[PartitionBinding]()
        for s in range(len(sorted_ids)):
            for j in range(len(ids)):
                if ids[j] == sorted_ids[s]:
                    out.append(by_id[j].copy())
                    break
        return out^
