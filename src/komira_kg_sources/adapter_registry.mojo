# =============================================================================
# adapter_registry -- an opaque surface tag mapped to the adapter that lowers it.
# =============================================================================
#
# A host reads many kinds of record and each kind has its own `SurfaceAdapter`,
# with its own `Source` type. A raw record is bytes plus a tag, so something has
# to turn the bytes into the adapter's `Source`. `RawSurfaceAdapter` is a
# `SurfaceAdapter` that also names its tag and parses bytes to its `Source`; the
# registry picks the adapter by tag, parses, lowers, and hands back the episodes.
#
# The adapters differ in type, and Mojo has no trait object, so the registry is a
# chain of types rather than a table: `EmptyAdapterRegistry` holds nothing, and
# `RegisteredAdapter[A, Rest]` holds one adapter in front of the registry `Rest`.
# `register` adds an adapter and returns the longer chain:
#
#     var registry = register(register(EmptyAdapterRegistry(), first), second)
#
# Every call is resolved by the compiler (no function pointer, no erased type, no
# pointer anywhere). A lookup compares the tag with each adapter's in the order
# they were registered, so the cost is linear in the number of adapters, which is
# a handful.
#
#   * a tag is registered once: `register` refuses an adapter whose tag is
#     already taken, and a tag that is empty, over the size limit or holds a
#     control byte;
#   * a tag nobody registered dispatches nothing: `lower_raw` returns no value
#     and calls no adapter, so the caller decides whether that is an error;
#   * an adapter that cannot parse or lower its bytes raises, and the registry
#     does not catch it.
# =============================================================================

from komira_kg import EpisodeInput, SurfaceAdapter

from .framing import check_text


trait RawSurfaceAdapter(SurfaceAdapter, Deinitable):
    """A `SurfaceAdapter` that also reads its own record type from raw bytes.

    Like `lower`, `surface_tag` and `parse` read no clock and no environment, so
    the same bytes always give the same episodes.
    """

    def surface_tag(self) -> String:
        """The tag a raw record carries when this adapter is the one that
        understands it. Fixed for the life of the adapter.
        """
        ...

    def parse(self, raw: List[UInt8]) raises -> Self.Source:
        """Read one record from the payload of a raw record.

        Args:
            raw: The payload bytes, exactly as stored.

        Returns:
            The record.

        Raises:
            If the bytes are not a record of this adapter's kind.
        """
        ...


trait AdapterRegistry(Movable, Deinitable):
    """Adapters looked up by surface tag. Conformers: `EmptyAdapterRegistry` and
    `RegisteredAdapter`; build one with `register`."""

    def has_tag(self, tag: String) -> Bool:
        """Whether an adapter is registered under `tag`."""
        ...

    def tags(self) -> List[String]:
        """The registered tags in registration order."""
        ...

    def lower_raw(
        self, tag: String, raw: List[UInt8], partition_id: String
    ) raises -> Optional[List[EpisodeInput]]:
        """Parse `raw` with the adapter registered under `tag` and lower the
        record.

        Args:
            tag: The surface tag of the raw record.
            raw: The record's payload.
            partition_id: The partition the episodes are for; the adapter stamps
                it on every episode.

        Returns:
            The episodes, or nothing if no adapter is registered under `tag`
            (no adapter was called).

        Raises:
            If the adapter cannot parse or lower the bytes.
        """
        ...


struct EmptyAdapterRegistry(AdapterRegistry):
    """A registry with no adapter: the start of every chain."""

    def __init__(out self):
        pass

    def has_tag(self, tag: String) -> Bool:
        return False

    def tags(self) -> List[String]:
        return List[String]()

    def lower_raw(
        self, tag: String, raw: List[UInt8], partition_id: String
    ) raises -> Optional[List[EpisodeInput]]:
        return Optional[List[EpisodeInput]]()


struct RegisteredAdapter[Adapter: RawSurfaceAdapter, Rest: AdapterRegistry](
    AdapterRegistry
):
    """One adapter in front of the registry `Rest`. Make one with `register`.

    Parameters:
        Adapter: The adapter's type.
        Rest: The registry of the adapters registered before it.
    """

    var _adapter: Self.Adapter
    var _rest: Self.Rest

    def __init__(out self, var adapter: Self.Adapter, var rest: Self.Rest):
        self._adapter = adapter^
        self._rest = rest^

    def has_tag(self, tag: String) -> Bool:
        return self._adapter.surface_tag() == tag or self._rest.has_tag(tag)

    def tags(self) -> List[String]:
        var out = self._rest.tags()
        out.append(self._adapter.surface_tag())
        return out^

    def lower_raw(
        self, tag: String, raw: List[UInt8], partition_id: String
    ) raises -> Optional[List[EpisodeInput]]:
        if self._adapter.surface_tag() == tag:
            var source = self._adapter.parse(raw)
            return Optional[List[EpisodeInput]](
                self._adapter.lower(source^, partition_id)
            )
        return self._rest.lower_raw(tag, raw, partition_id)


def register[
    Adapter: RawSurfaceAdapter, Rest: AdapterRegistry
](
    var registry: Rest, var adapter: Adapter
) raises -> RegisteredAdapter[Adapter, Rest]:
    """Add `adapter` to `registry` under its own surface tag.

    Args:
        registry: The registry so far (consumed).
        adapter: The adapter to add (consumed).

    Returns:
        The registry with the adapter in it.

    Raises:
        If the adapter's tag is empty, over the size limit or holds a control
        byte, or an adapter is already registered under it.
    """
    var tag = adapter.surface_tag()
    check_text("surface tag", tag, False)
    if registry.has_tag(tag):
        raise Error(
            "AdapterRegistry: an adapter is already registered under '"
            + tag
            + "'"
        )
    return RegisteredAdapter[Adapter, Rest](adapter^, registry^)
