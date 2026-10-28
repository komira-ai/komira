# =============================================================================
# cd_global_dir — the grouped COUNT(DISTINCT) finalize's worker -> global group
# directory, built ONCE, as a per-worker gid map
# =============================================================================
#
# `CountDistinctAggSink._finalize_batch` reconciles every worker's private gid
# space onto one global one. `map_worker` asks the key Dict ONCE per (worker,
# group) cell and returns `wgid[g]`, the global gid of that worker's group `g`,
# which every later consumer indexes (the directory, the fixed-cell merge and
# each COUNT(DISTINCT) drain used to ask the Dict up to three times per cell).
# `runs[gg]` counts the cells that map onto `gg`, so the drain sizes each
# group's run list once instead of growing it by doubling. This shortens
# the serial gap between the scan and the first radix fork. A dense index over
# the key span instead of the Dict is no faster: once it is asked once per
# cell, the cell walk is the cost, not the Dict probe.
#
# ★ BYTE-EQUIVALENCE BY CONSTRUCTION. A global gid is assigned `len(self.keys)`
# at the moment its key is first seen, walking workers in the caller's order and
# each worker's groups in gid order — the SAME first-seen order the old loop
# used — so `keys` comes out identical INDEX FOR INDEX, and so does every row.
#
# ★ THE NULL GROUP never enters the Dict (there is no Int64 that means NULL). It gets its gid at its first appearance, exactly as the old
# loop placed it, and `null_gid` names it.
#
# No pointers, no origins: `List` / `Dict` only.
# =============================================================================


@always_inline
def _is_null_at(imm key_null: List[Bool], g: Int) -> Bool:
    """Mirrors `WorkerCDState.group_is_null`: defensive on length."""
    if g < 0 or g >= len(key_null):
        return False
    return key_null[g]


struct CdGlobalDir(Movable):
    """The global group directory and the per-worker gid maps.

    `keys[gg]` is global group `gg`'s key (a placeholder `0` for the NULL group,
    which `null_gid` names). `runs[gg]` counts the worker cells that map onto
    `gg` — the exact run-list length a per-group drain will need, so the caller
    can size it once instead of growing it by doubling."""

    var keys: List[Int]
    var runs: List[Int]
    var null_gid: Int
    var _map: Dict[Int, Int]

    def __init__(out self):
        self.keys = List[Int]()
        self.runs = List[Int]()
        self.null_gid = -1
        self._map = Dict[Int, Int]()

    @always_inline
    def _new_gid(mut self, key: Int) -> Int:
        var gg = len(self.keys)
        self.keys.append(key)
        self.runs.append(0)
        return gg

    def map_worker(
        mut self, imm keys: List[Int], imm key_null: List[Bool]
    ) raises -> List[Int]:
        """This worker's `wgid[g]` = global gid of its group `g`, assigning new
        global gids in first-seen order. Call once per worker, in worker
        order."""
        var n = len(keys)
        var out = List[Int](capacity=n)
        for g in range(n):
            var gg: Int
            if _is_null_at(key_null, g):
                if self.null_gid < 0:
                    self.null_gid = self._new_gid(0)
                gg = self.null_gid
            else:
                # `in` + `[]`, never `Dict.get`: `get` routes through a `try`
                # around the typed-raise `_find_ref`, which does not inline.
                var k = keys[g]
                if k in self._map:
                    gg = self._map[k]
                else:
                    gg = self._new_gid(k)
                    self._map[k] = gg
            self.runs[gg] += 1
            out.append(gg)
        return out^
