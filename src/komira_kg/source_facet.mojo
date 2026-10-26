# =============================================================================
# source_facet -- the facet an entity carries, and the set of (source, facet)
#   pairs a query leaves out.
# =============================================================================
#
# A host stamps each episode with an opaque `facet` (a label for the kind of
# thing the source is: the graph fixes no list of them) and the id of the
# source it came from. The entities minted from the episode carry both in their
# existing `attrs` JSON column, as {"facet":"<facet>","facet_source":"<source>"}:
# no schema column is added, a stored entity with `{}` or "" attrs reads back
# as having no facet, and other members of an `attrs` object are not disturbed
# on read.
#
# `FacetTombstoneSet` is the set of (source, facet) pairs a query excludes. It
# is a result filter, not a deletion (the rows stay) and not access control
# (a caller that needs to withhold data enforces that where it authenticates).
# A pair is keyed by BOTH parts: excluding facet F of source S leaves every other
# facet of S, and F of every other source, alone. A tombstone whose source is ""
# is a wildcard that excludes the facet for every source.
# =============================================================================

from komira_json import JsonValue, parse_json_value


# The `attrs` member names the facet rides under.
comptime FACET_ATTR_KEY: String = "facet"
comptime FACET_SOURCE_ATTR_KEY: String = "facet_source"


def facet_attrs_json(facet: String, source: String) -> String:
    """The entity `attrs` JSON that carries a facet and its source.

    An empty `facet` gives `{}` (no facet: the source is not recorded either).
    An empty `source` leaves out the `facet_source` member. Text is escaped as
    JSON, so any facet or source string round-trips.

    Args:
        facet: The opaque facet label, or "".
        source: The id of the source, or "".

    Returns:
        A JSON object.
    """
    var obj = JsonValue.empty_object()
    if len(facet.as_bytes()) == 0:
        return obj.serialize()
    try:
        obj.set_member(String(FACET_ATTR_KEY), JsonValue.from_string(facet))
        if len(source.as_bytes()) > 0:
            obj.set_member(
                String(FACET_SOURCE_ATTR_KEY), JsonValue.from_string(source)
            )
    except:
        # set_member refuses only a non-object receiver, and this one is an
        # object, so this is unreachable; fall back to no facet.
        return String("{}")
    return obj.serialize()


def _string_member(attrs: String, key: String) -> String:
    if len(attrs.as_bytes()) == 0:
        return String("")
    try:
        var root = parse_json_value(attrs)
        if not root.is_object() or not root.has(key):
            return String("")
        var v = root.get(key)
        if not v.is_string():
            return String("")
        return v.as_string()
    except:
        return String("")


def facet_from_attrs(attrs: String) -> String:
    """The facet in an entity's `attrs` JSON; "" when `attrs` is empty, is not a
    JSON object, has no `facet` member, or holds a non-string there."""
    return _string_member(attrs, String(FACET_ATTR_KEY))


def facet_source_from_attrs(attrs: String) -> String:
    """The source id in an entity's `attrs` JSON; "" under the same conditions
    as `facet_from_attrs`."""
    return _string_member(attrs, String(FACET_SOURCE_ATTR_KEY))


struct FacetTombstoneSet(Copyable, Movable):
    """The (source, facet) pairs a query excludes. Empty on construction:
    nothing is excluded."""

    var _sources: List[String]
    var _facets: List[String]

    def __init__(out self):
        self._sources = List[String]()
        self._facets = List[String]()

    def disable(mut self, source: String, facet: String):
        """Exclude `facet` of `source`. Idempotent. A `source` of "" excludes
        `facet` for every source.

        Args:
            source: The source id, or "" for all sources.
            facet: The facet to exclude.
        """
        for i in range(len(self._sources)):
            if self._sources[i] == source and self._facets[i] == facet:
                return
        self._sources.append(source)
        self._facets.append(facet)

    def is_disabled(self, source: String, facet: String) -> Bool:
        """True when `facet` of `source` is excluded: an entry for exactly this
        pair, or a wildcard entry (source "") for this facet. An entry for one
        source never excludes another source, and an entry for one facet never
        excludes another facet.

        Args:
            source: The source id of the row under test ("" if unattributed).
            facet: The row's facet.
        """
        for i in range(len(self._sources)):
            if self._facets[i] != facet:
                continue
            if len(self._sources[i].as_bytes()) == 0 or self._sources[i] == source:
                return True
        return False

    def is_empty(self) -> Bool:
        return len(self._sources) == 0

    def num_entries(self) -> Int:
        """The number of distinct (source, facet) entries."""
        return len(self._sources)
