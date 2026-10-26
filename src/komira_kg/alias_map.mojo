# =============================================================================
# alias_map -- a directed union-find over node ids.
# =============================================================================
#
# When resolution decides that node `alias` is node `canonical`, the caller
# records `union(alias, canonical)`. Before an edge is written, each endpoint is
# resolved to its canonical id, so no edge points at an id that was merged away.
#
# Directed: the second argument wins. `union(a, b)` then `union(b, c)` leaves
# `resolve(a) == c`, whatever order the two calls arrive in. Consistent claims
# (each id aliased to at most one canonical id, no cycles) give the same answer
# in every order. If one id is claimed as an alias of two different canonical
# ids, the two sets merge and the canonical id of the later call represents
# them, so the answer then depends on call order; a caller that wants a
# particular winner makes its claims consistent first.
#
# `resolve` compresses the path it walks, which is why it takes `mut self`: the
# rewrite is internal and never changes which id is canonical. An id never named
# in a `union` resolves to itself. Lookup by id is a linear scan: the map holds
# the mentions of one ingest, not a whole graph.
# =============================================================================


struct AliasMap(Copyable, Movable):
    """A directed union-find: `union(alias, canonical)` makes `resolve(alias)`
    return the canonical id; chains collapse; an unnamed id resolves to
    itself."""

    var _ids: List[Int64]
    var _parent: List[Int]

    def __init__(out self):
        """An empty map: every id resolves to itself."""
        self._ids = List[Int64]()
        self._parent = List[Int]()

    def _slot_of(self, nid: Int64) -> Int:
        for i in range(len(self._ids)):
            if self._ids[i] == nid:
                return i
        return -1

    def _ensure_slot(mut self, nid: Int64) -> Int:
        var s = self._slot_of(nid)
        if s >= 0:
            return s
        var fresh = len(self._ids)
        self._ids.append(nid)
        self._parent.append(fresh)
        return fresh

    def _find_root(mut self, slot: Int) -> Int:
        var root = slot
        while self._parent[root] != root:
            root = self._parent[root]
        var cur = slot
        while self._parent[cur] != root:
            var nxt = self._parent[cur]
            self._parent[cur] = root
            cur = nxt
        return root

    def union(mut self, alias_nid: Int64, canonical_nid: Int64):
        """Record that `alias_nid` is `canonical_nid`.

        The alias's set is pointed at the canonical's set, so the canonical id
        stays the representative. A self-union, and a pair already in one set,
        change nothing.

        Args:
            alias_nid: The id being merged away.
            canonical_nid: The id it resolves to.
        """
        if alias_nid == canonical_nid:
            return
        var a_slot = self._ensure_slot(alias_nid)
        var c_slot = self._ensure_slot(canonical_nid)
        var a_root = self._find_root(a_slot)
        var c_root = self._find_root(c_slot)
        if a_root == c_root:
            return
        self._parent[a_root] = c_root

    def resolve(mut self, nid: Int64) -> Int64:
        """The canonical id `nid` collapses to; `nid` itself when it was never
        named in a `union`.

        Args:
            nid: The id to resolve.

        Returns:
            The canonical id.
        """
        var s = self._slot_of(nid)
        if s < 0:
            return nid
        var root = self._find_root(s)
        return self._ids[root]

    def is_alias(mut self, nid: Int64) -> Bool:
        """True when `nid` resolves to a different id."""
        return self.resolve(nid) != nid

    def num_registered(self) -> Int:
        """The number of distinct ids named in a `union`."""
        return len(self._ids)
