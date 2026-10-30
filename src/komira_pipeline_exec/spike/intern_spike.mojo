# =============================================================================
# intern_spike -- what dictionary interning costs, against hashing every row
# =============================================================================
#
# The spike of slice 4 of docs/design/lowering_and_pipeline.md (section 4.3,
# "Dictionary string keys"). It is a program, not a test of the library: it
# builds a workload shaped like a dictionary-encoded string group-by key and
# times the candidate layouts on it, so that the string sinks of slice 6 fix
# their table layout on numbers. It uses no komira package; the table is
# written here so that the only things measured are the layout choices.
#
# The workload. `WORKERS` workers each read `RGS` row groups of `ROWS` rows. A
# row group has a dictionary of `DICT` distinct strings (drawn from a universe
# of `GROUPS` strings, so the dictionaries of different row groups and workers
# overlap the way real ones do) and one code per row. The key of the group-by
# is the string; the aggregate is a count per distinct string.
#
# The layouts, each run to the same answer (checked against a direct count):
#
#   interned   the design of section 4.3. Per worker, per dictionary: hash each
#              dictionary entry ONCE, intern it into the worker's string table
#              (probe by hash, compare bytes on a hit) and record code -> id.
#              Per row: id = ids[code]; count[id] += 1. The table keeps the
#              64-bit hash beside each entry. Fragment merge: each worker's
#              table entries are probed into a merge table by their carried
#              hash and compared by bytes on a hit.
#   by value   the COLUMNAR method used on the dictionary column too: per row,
#              hash the decoded string and probe the worker's table. Same merge.
#   rehash     the interned layout with a merge that does not carry the hash:
#              every fragment entry is hashed again at merge.
#   shared     one string table for all workers (one id space, so the merge is
#              not needed and the id could route). Measured uncontended on one
#              thread: it prices the probes, not the contention (see below).
#
# The three costs the design asks for, and the line that reports each:
#
#   content hash per interned entry   `hash_per_entry_ns`, against
#                                     `hash_per_row_ns`; and `interned_total`
#                                     against `by_value_total` per row.
#   fragment merge per entry          `merge_carried_per_entry_ns` and
#                                     `merge_rehash_per_entry_ns`, as the group
#                                     count grows (the GROUPS column).
#   string-table memory per worker    `worker_table_bytes_each` and
#                                     `all_worker_tables_bytes` against
#                                     `merged_table_bytes`; `duplication` is
#                                     fragment entries per merged group.
#
# What this does not measure: the contention of a shared concurrent intern
# table. That needs threads on the dispatcher; a single-threaded program prices
# the table, not the cache-line traffic of W threads inserting into it.
# `shared_*` is therefore a lower bound for that alternative. The analysis in
# the design doc says what it adds.
#
# Output: one `RESULT <config> <metric>=<value>` line per number, best of
# `TRIALS` runs; the farm is not pinned, so read ratios, not absolutes. The
# last line is `OK`; a layout whose counts differ from the direct count prints
# `FAILED` and the reason and exits 1, which fails the run check. CI compiles
# this program (it is in the check set) but does not run it; the numbers come
# from running the `[run_check]` sub-target on the farm, and read the recorded
# stdout:
#
#   ./buck2 build 'komira//src/komira_pipeline_exec:intern_spike[run_check]' --show-output
#
# An interned entry that no row points at (a dictionary entry nothing used)
# holds a count of zero: it is not a group, and `merged_used_groups` against
# `merged_entries` counts them.

from std.sys import exit
from std.time import perf_counter_ns

comptime WORKERS = 8
comptime RGS = 4
comptime ROWS = 65536
comptime TRIALS = 3
comptime FNV_OFFSET: UInt64 = 0xCBF29CE484222325
comptime FNV_PRIME: UInt64 = 0x100000001B3


@always_inline
def mix(h: UInt64) -> UInt64:
    var x = h
    x = x ^ (x >> 33)
    x = x * UInt64(0xFF51AFD7ED558CCD)
    x = x ^ (x >> 33)
    return x


def hash_bytes(data: Span[UInt8, _], off: Int, n: Int) -> UInt64:
    """FNV-1a over the bytes, then an avalanche mix. Byte at a time on
    purpose: the same function serves every layout, so what differs is how
    often it runs."""
    var h = FNV_OFFSET
    for i in range(off, off + n):
        h = (h ^ UInt64(data[i])) * FNV_PRIME
    return mix(h)


struct StrTable(Movable):
    """Open addressing over distinct byte strings: slot -> entry, with the
    64-bit hash kept beside each entry (the carried hash)."""

    var slots: List[Int32]
    var mask: Int
    var hashes: List[UInt64]
    var starts: List[Int]
    var lens: List[Int]
    var data: List[UInt8]
    var counts: List[Int]

    def __init__(out self, capacity_pow2: Int = 1024):
        self.slots = List[Int32](length=capacity_pow2, fill=Int32(-1))
        self.mask = capacity_pow2 - 1
        self.hashes = List[UInt64]()
        self.starts = List[Int]()
        self.lens = List[Int]()
        self.data = List[UInt8]()
        self.counts = List[Int]()

    def size(self) -> Int:
        return len(self.hashes)

    def bytes(self) -> Int:
        """Memory held: slots, per-entry hash/start/len/count, string bytes."""
        return (
            len(self.slots) * 4
            + len(self.hashes) * (8 + 8 + 8 + 8)
            + len(self.data)
        )

    def _grow(mut self):
        var cap = len(self.slots) * 2
        self.slots = List[Int32](length=cap, fill=Int32(-1))
        self.mask = cap - 1
        for e in range(len(self.hashes)):
            var s = Int(self.hashes[e]) & self.mask
            while self.slots[s] != Int32(-1):
                s = (s + 1) & self.mask
            self.slots[s] = Int32(e)

    @always_inline
    def _same(self, e: Int, src: Span[UInt8, _], off: Int, n: Int) -> Bool:
        if self.lens[e] != n:
            return False
        var base = self.starts[e]
        for i in range(n):
            if self.data[base + i] != src[off + i]:
                return False
        return True

    def find_or_insert(
        mut self, h: UInt64, src: Span[UInt8, _], off: Int, n: Int
    ) -> Int:
        """The entry id of the string `src[off:off+n]` whose hash is `h`,
        added with a zero count when absent."""
        if (len(self.hashes) + 1) * 2 > len(self.slots):
            self._grow()
        var s = Int(h) & self.mask
        while True:
            var e = Int(self.slots[s])
            if e == -1:
                var id = len(self.hashes)
                self.hashes.append(h)
                self.starts.append(len(self.data))
                self.lens.append(n)
                for i in range(n):
                    self.data.append(src[off + i])
                self.counts.append(0)
                self.slots[s] = Int32(id)
                return id
            if self.hashes[e] == h and self._same(e, src, off, n):
                return e
            s = (s + 1) & self.mask


struct Dict(Movable):
    """One row group's dictionary and codes. `gid` is the universe id of each
    entry (kept for the check; no layout reads it)."""

    var data: List[UInt8]
    var offs: List[Int]
    var lens: List[Int]
    var gid: List[Int]
    var codes: List[Int32]

    def __init__(out self):
        self.data = List[UInt8]()
        self.offs = List[Int]()
        self.lens = List[Int]()
        self.gid = List[Int]()
        self.codes = List[Int32]()


def write_string(mut data: List[UInt8], g: Int, length: Int):
    """The string of universe id g: "key-" and 12 decimal digits, then 'x'
    to `length` bytes. The id is recoverable from the digits."""
    data.append(UInt8(ord("k")))
    data.append(UInt8(ord("e")))
    data.append(UInt8(ord("y")))
    data.append(UInt8(ord("-")))
    var digits = List[UInt8](length=12, fill=UInt8(ord("0")))
    var v = g
    var i = 11
    while v > 0:
        digits[i] = UInt8(ord("0") + v % 10)
        v //= 10
        i -= 1
    for d in range(12):
        data.append(digits[d])
    for _ in range(16, length):
        data.append(UInt8(ord("x")))


def gid_of(data: List[UInt8], start: Int) -> Int:
    var v = 0
    for i in range(12):
        v = v * 10 + Int(data[start + 4 + i]) - ord("0")
    return v


def make_dict(groups: Int, dict_size: Int, length: Int, seed: Int) -> Dict:
    var d = Dict()
    var step = 7919
    if groups % step == 0:
        step = 104729
    var s = seed * 2654435761 + 12345
    var base = (s >> 8) % groups
    var n = min(dict_size, groups)
    for i in range(n):
        var g = (base + i * step) % groups
        d.offs.append(len(d.data))
        write_string(d.data, g, length)
        d.lens.append(length)
        d.gid.append(g)
    for _ in range(ROWS):
        s = (s * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
        d.codes.append(Int32((s >> 20) % n))
    return d^


def pow2_at_least(n: Int) -> Int:
    var c = 1024
    while c < n:
        c *= 2
    return c


def best_of(mut ns: Int, t0: Int):
    var dt = Int(perf_counter_ns()) - t0
    if dt < ns:
        ns = dt


def merge_into(
    mut merged: StrTable, ref frag: StrTable, carried: Bool
):
    for e in range(frag.size()):
        var h = frag.hashes[e]
        var span = Span(frag.data)
        if not carried:
            h = hash_bytes(span, frag.starts[e], frag.lens[e])
        var id = merged.find_or_insert(h, span, frag.starts[e], frag.lens[e])
        merged.counts[id] += frag.counts[e]


def check(ref merged: StrTable, ref oracle: List[Int], label: String) raises:
    """Every entry that counted a row has the oracle's count and every string
    the oracle counted is there. An interned entry that no row used (a
    dictionary entry nothing pointed at) holds a zero count and is not a
    group: `used_groups` is what a sink would emit."""
    var want = 0
    for g in range(len(oracle)):
        if oracle[g] > 0:
            want += 1
    var used = 0
    for e in range(merged.size()):
        var g = gid_of(merged.data, merged.starts[e])
        if merged.counts[e] != oracle[g]:
            raise Error(label + ": wrong count for string " + String(g))
        if merged.counts[e] > 0:
            used += 1
    if used != want:
        raise Error(label + ": " + String(used) + " groups, want " + String(want))


def used_groups(ref t: StrTable) -> Int:
    var n = 0
    for e in range(t.size()):
        if t.counts[e] > 0:
            n += 1
    return n


def run(groups: Int, dict_size: Int, length: Int) raises:
    var cfg = (
        "groups="
        + String(groups)
        + ",dict="
        + String(min(dict_size, groups))
        + ",len="
        + String(length)
    )
    var dicts = List[Dict]()
    var oracle = List[Int](length=groups, fill=0)
    var rows_total = 0
    var entries_total = 0
    for w in range(WORKERS):
        for r in range(RGS):
            var d = make_dict(groups, dict_size, length, w * RGS + r + 1)
            for i in range(len(d.codes)):
                oracle[d.gid[Int(d.codes[i])]] += 1
            rows_total += len(d.codes)
            entries_total += len(d.gid)
            dicts.append(d^)

    # Hashing alone: once per dictionary entry, once per row.
    var best_entry = Int.MAX
    var best_row = Int.MAX
    var sink = UInt64(0)
    for _ in range(TRIALS):
        var t0 = Int(perf_counter_ns())
        for k in range(len(dicts)):
            var span = Span(dicts[k].data)
            for e in range(len(dicts[k].offs)):
                sink ^= hash_bytes(span, dicts[k].offs[e], dicts[k].lens[e])
        best_of(best_entry, t0)
        t0 = Int(perf_counter_ns())
        for k in range(len(dicts)):
            var span = Span(dicts[k].data)
            for i in range(len(dicts[k].codes)):
                var c = Int(dicts[k].codes[i])
                sink ^= hash_bytes(span, dicts[k].offs[c], dicts[k].lens[c])
        best_of(best_row, t0)
    print("RESULT", cfg, "hash_per_entry_ns=", Float64(best_entry) / Float64(entries_total))
    print("RESULT", cfg, "hash_per_row_ns=", Float64(best_row) / Float64(rows_total))

    # interned: per worker, per dictionary intern once, then ids[code].
    var best_intern = 0
    var best_rows = 0
    var best_sum = Int.MAX
    var tables = List[StrTable]()
    for _ in range(TRIALS):
        var ts = List[StrTable]()
        var intern_ns = 0
        var rows_ns = 0
        for w in range(WORKERS):
            ts.append(StrTable())
            for r in range(RGS):
                ref d = dicts[w * RGS + r]
                var span = Span(d.data)
                var ids = List[Int](length=len(d.offs), fill=0)
                var t0 = Int(perf_counter_ns())
                for e in range(len(d.offs)):
                    var h = hash_bytes(span, d.offs[e], d.lens[e])
                    ids[e] = ts[w].find_or_insert(h, span, d.offs[e], d.lens[e])
                intern_ns += Int(perf_counter_ns()) - t0
                t0 = Int(perf_counter_ns())
                for i in range(len(d.codes)):
                    ts[w].counts[ids[Int(d.codes[i])]] += 1
                rows_ns += Int(perf_counter_ns()) - t0
        if intern_ns + rows_ns < best_sum:
            best_sum = intern_ns + rows_ns
            best_intern = intern_ns
            best_rows = rows_ns
            tables = ts^
    print("RESULT", cfg, "intern_per_entry_ns=", Float64(best_intern) / Float64(entries_total))
    print("RESULT", cfg, "interned_row_loop_per_row_ns=", Float64(best_rows) / Float64(rows_total))
    print("RESULT", cfg, "interned_total_per_row_ns=", Float64(best_intern + best_rows) / Float64(rows_total))

    # by value: hash every row's string, probe the worker's table.
    var best_val = Int.MAX
    var vtables = List[StrTable]()
    for _ in range(TRIALS):
        var ts = List[StrTable]()
        var t0 = Int(perf_counter_ns())
        for w in range(WORKERS):
            ts.append(StrTable())
            for r in range(RGS):
                ref d = dicts[w * RGS + r]
                var span = Span(d.data)
                for i in range(len(d.codes)):
                    var c = Int(d.codes[i])
                    var h = hash_bytes(span, d.offs[c], d.lens[c])
                    var id = ts[w].find_or_insert(h, span, d.offs[c], d.lens[c])
                    ts[w].counts[id] += 1
        var dt = Int(perf_counter_ns()) - t0
        if dt < best_val:
            best_val = dt
            vtables = ts^
    print("RESULT", cfg, "by_value_total_per_row_ns=", Float64(best_val) / Float64(rows_total))
    print("RESULT", cfg, "by_value_over_interned=", Float64(best_val) / Float64(best_intern + best_rows))

    # shared: one table for every worker, uncontended.
    var best_shared = Int.MAX
    for _ in range(TRIALS):
        var shared = StrTable()
        var t0 = Int(perf_counter_ns())
        for k in range(len(dicts)):
            ref d = dicts[k]
            var span = Span(d.data)
            var ids = List[Int](length=len(d.offs), fill=0)
            for e in range(len(d.offs)):
                var h = hash_bytes(span, d.offs[e], d.lens[e])
                ids[e] = shared.find_or_insert(h, span, d.offs[e], d.lens[e])
            for i in range(len(d.codes)):
                shared.counts[ids[Int(d.codes[i])]] += 1
        best_of(best_shared, t0)
        check(shared, oracle, "shared " + cfg)
    print("RESULT", cfg, "shared_total_per_row_ns=", Float64(best_shared) / Float64(rows_total))

    # Fragment merge, carried hash and rehash.
    var frag_entries = 0
    var all_bytes = 0
    for w in range(WORKERS):
        frag_entries += tables[w].size()
        all_bytes += tables[w].bytes()
    var best_carried = Int.MAX
    var best_rehash = Int.MAX
    var merged_bytes = 0
    var merged_groups = 0
    var merged_used = 0
    for _ in range(TRIALS):
        var m = StrTable()
        var t0 = Int(perf_counter_ns())
        for w in range(WORKERS):
            merge_into(m, tables[w], True)
        best_of(best_carried, t0)
        check(m, oracle, "interned+merge " + cfg)
        merged_bytes = m.bytes()
        merged_groups = m.size()
        merged_used = used_groups(m)
        var m2 = StrTable()
        t0 = Int(perf_counter_ns())
        for w in range(WORKERS):
            merge_into(m2, tables[w], False)
        best_of(best_rehash, t0)
        check(m2, oracle, "rehash+merge " + cfg)
    var mv = StrTable()
    for w in range(WORKERS):
        merge_into(mv, vtables[w], True)
    check(mv, oracle, "by value+merge " + cfg)
    print("RESULT", cfg, "fragment_entries=", frag_entries)
    print("RESULT", cfg, "merged_entries=", merged_groups)
    print("RESULT", cfg, "merged_used_groups=", merged_used)
    print("RESULT", cfg, "duplication=", Float64(frag_entries) / Float64(merged_groups))
    print("RESULT", cfg, "merge_carried_per_entry_ns=", Float64(best_carried) / Float64(frag_entries))
    print("RESULT", cfg, "merge_rehash_per_entry_ns=", Float64(best_rehash) / Float64(frag_entries))
    print("RESULT", cfg, "worker_table_bytes_each=", all_bytes // WORKERS)
    print("RESULT", cfg, "all_worker_tables_bytes=", all_bytes)
    print("RESULT", cfg, "merged_table_bytes=", merged_bytes)
    print("RESULT", cfg, "sink=", Int(sink & UInt64(1)))


def main():
    # Q1-like (four groups), then the group count grows by decades; the last
    # row varies the string length at 100,000 groups. A failed check prints
    # FAILED and its reason and exits 1, which fails the run check (a failed
    # run check records no stdout, so the reason is in this program's code path,
    # not in the build log).
    try:
        run(4, 4, 16)
        run(1000, 1000, 16)
        run(100000, 8192, 16)
        run(1000000, 8192, 16)
        run(100000, 8192, 48)
        print("OK")
    except e:
        print("FAILED", e)
        exit(1)
