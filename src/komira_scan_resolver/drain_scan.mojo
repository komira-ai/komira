# =============================================================================
# drain_scan: the bounded read, derived for every scan kind.
# =============================================================================
#
# `drain_scan` plans one execution's splits, reads each to its stop, and
# returns the rows as resident batches (`ScanOpened`) with the plan's resolved
# side channel. It is what lets an execution-time pass re-root a kind's scan
# leaf as an ordinary bound IN_MEMORY scan.
#
# It reads ONLY bounded plans: a plan that may still grow (`complete == False`)
# or a split with no stop is refused by name (`SCAN_READ_MODE_UNBOUNDED_DRAIN`),
# because draining a split that never ends either never returns or returns
# "everything up to now" and calls it the source. Following such a split is an
# engine's job, through the same `open_split` / `poll` surface.
#
# It owns the two budgets that span splits: the request's row `limit` and the
# caller's `max_bytes`. Both are cuts the read MAY stop at, checked between
# polls, and each poll is handed what is left of them. A poll returns its first
# unit whole (`SplitReader.poll`), so a cut overshoots by at most one unit.
# =============================================================================

from std.memory import ArcPointer

from komira_core.arrow.record_batch import RecordBatch
from komira_core.collections.slab import Slab
from komira_scan_resolver.scan_source_resolver import (
    ScanOpened,
    ScanRequest,
    ScanSourceResolver,
)
from komira_scan_resolver.scan_split import ScanSplit


comptime SCAN_READ_MODE_UNBOUNDED_DRAIN: StaticString = (
    "SCAN_READ_MODE_UNBOUNDED_DRAIN"
)
"""NAMED ERROR — `drain_scan` was asked to drain a plan that is not bounded: it
may still gain splits (`complete == False`), or one of its splits has no stop.
A drain of either would never end, or would end at "now" and report that as
the whole source."""

comptime SCAN_SPLIT_PLAN_INVALID: StaticString = "SCAN_SPLIT_PLAN_INVALID"
"""NAMED ERROR — a split plan whose read order cannot be derived: two splits
share a key, a split must read `after` a key the plan does not contain, or the
`after` lists form a cycle."""

comptime SCAN_SPLIT_STALLED: StaticString = "SCAN_SPLIT_STALLED"
"""NAMED ERROR — a bounded split answered IDLE during a drain: it has not
reached its stop and has nothing to read now. A drain cannot wait for it, and
ending it there would return fewer rows than the plan's stop promised."""

comptime DRAIN_NO_BYTE_BUDGET: Int64 = -1
"""`drain_scan`'s `max_bytes` when no byte budget applies."""


def split_read_order(splits: List[ScanSplit]) raises -> List[Int]:
    """The indexes of `splits` in an order that reads every split after each
    key in its `after` list, and otherwise in plan order. Raises
    `SCAN_SPLIT_PLAN_INVALID` naming the duplicate key, the unknown `after`
    key, or the splits left in a cycle."""
    var n = len(splits)
    for i in range(n):
        for j in range(i + 1, n):
            if splits[i].split_key == splits[j].split_key:
                raise Error(
                    String(SCAN_SPLIT_PLAN_INVALID)
                    + String(": two splits share the key '")
                    + splits[i].split_key
                    + String("'")
                )
    var deps = List[List[Int]]()
    for i in range(n):
        var mine = List[Int]()
        for a in range(len(splits[i].after)):
            var found = -1
            for j in range(n):
                if splits[j].split_key == splits[i].after[a]:
                    found = j
                    break
            if found < 0:
                raise Error(
                    String(SCAN_SPLIT_PLAN_INVALID)
                    + String(": split '")
                    + splits[i].split_key
                    + String("' reads after '")
                    + splits[i].after[a]
                    + String("', which is not in the plan")
                )
            mine.append(found)
        deps.append(mine^)
    var placed = List[Bool](length=n, fill=False)
    var order = List[Int]()
    while len(order) < n:
        var progressed = False
        for i in range(n):
            if placed[i]:
                continue
            var ready = True
            for d in range(len(deps[i])):
                if not placed[deps[i][d]]:
                    ready = False
                    break
            if ready:
                placed[i] = True
                order.append(i)
                progressed = True
                # Restart from the first split, so plan order wins among
                # every split that is ready.
                break
        if not progressed:
            var left = String("")
            for i in range(n):
                if not placed[i]:
                    if left.byte_length() > 0:
                        left += String(", ")
                    left += splits[i].split_key
            raise Error(
                String(SCAN_SPLIT_PLAN_INVALID)
                + String(": the `after` lists of [")
                + left
                + String("] form a cycle")
            )
    return order^


def drain_scan[
    RES: ScanSourceResolver
](
    resolver: RES, req: ScanRequest, max_bytes: Int64 = DRAIN_NO_BYTE_BUDGET
) raises -> ScanOpened:
    """Read the scan `req.binding` names, every split to its stop, into
    resident batches. Splits are read one at a time, in `split_read_order`.

    Refuses an unbounded plan (`SCAN_READ_MODE_UNBOUNDED_DRAIN`), an invalid
    one (`SCAN_SPLIT_PLAN_INVALID`) and a split that stalls before its stop
    (`SCAN_SPLIT_STALLED`), each by name. Stops early, between polls, once
    `req.limit` rows or `max_bytes` source bytes have been read; both are
    -1 for no bound. `ScanOpened.resolved` is the plan's `resolved`.
    """
    var plan = resolver.plan_splits(req)
    if not plan.complete:
        raise Error(
            String(SCAN_READ_MODE_UNBOUNDED_DRAIN)
            + String(": scan '")
            + req.binding.name
            + String("' of kind '")
            + req.binding.kind_name
            + String("' planned a split set that may still grow; a drain reads")
            + String(" only a complete plan")
        )
    for i in range(len(plan.splits)):
        if not plan.splits[i].is_bounded():
            raise Error(
                String(SCAN_READ_MODE_UNBOUNDED_DRAIN)
                + String(": split '")
                + plan.splits[i].split_key
                + String("' of scan '")
                + req.binding.name
                + String("' (kind '")
                + req.binding.kind_name
                + String("') has no stop; a drain reads only bounded splits")
            )
    var order = split_read_order(plan.splits)
    var batches = Slab[RecordBatch]()
    var rows: Int64 = 0
    var bytes: Int64 = 0
    var cut = False
    for k in range(len(order)):
        if cut:
            break
        ref split = plan.splits[order[k]]
        var reader = resolver.open_split(req, split)
        while True:
            if req.has_limit() and rows >= req.limit:
                cut = True
                break
            if max_bytes >= 0 and bytes >= max_bytes:
                cut = True
                break
            var rows_left: Int64 = -1
            if req.has_limit():
                rows_left = req.limit - rows
            var bytes_left: Int64 = -1
            if max_bytes >= 0:
                bytes_left = max_bytes - bytes
            var polled = reader.poll(rows_left, bytes_left)
            bytes += polled.source_bytes
            rows += Int64(polled.num_rows())
            if polled.batch:
                batches.append(polled.batch.take())
            if polled.is_end():
                break
            if polled.is_idle():
                raise Error(
                    String(SCAN_SPLIT_STALLED)
                    + String(": split '")
                    + split.split_key
                    + String("' of scan '")
                    + req.binding.name
                    + String("' (kind '")
                    + req.binding.kind_name
                    + String("') answered IDLE before its stop")
                )
    return ScanOpened(ArcPointer(batches^), plan.resolved.copy())
