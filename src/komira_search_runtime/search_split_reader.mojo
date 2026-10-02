# =============================================================================
# komira_search_runtime/search_split_reader.mojo -- reading ONE split of a
# `komira.search.index` scan.
# =============================================================================
#
# A search split is one published split object of an index, read at the
# execution's generation. Its rows are the split's hits for the scan's query,
# in the order `SearchCore` ranks them: score descending, then doc id
# ascending. That order is TOTAL, so the first k ranks of a read are the first
# k ranks of every longer read of the same split, and a position can be a
# rank.
#
# THE POSITION (version `SEARCH_SPLIT_POSITION_VERSION`), 9 bytes:
#   byte 0     the tag: `_AT_RANK` (the next row to read is rank `n`) or
#              `_DONE` (the split has been read to its end);
#   bytes 1-8  `n`, little-endian (0 for `_DONE`).
# A split is planned from rank 0 to `_DONE`. Resuming at rank n reads ranks
# n.. of the same query over the same split bytes (`QueryIR.from_offset`), so
# a resumed read returns exactly the rest.
#
# THE READER holds the split it reads (a parsed `SearchCore` over its own copy
# of the bytes), because the window between planning a scan and reading one of
# its splits is not bounded by one call and a store may reap a split once no
# generation it serves needs it.
#
# A poll returns the ranks it is allowed to (`max_rows`, at least one) as one
# batch. Without a row bound that is every remaining hit, so an unbounded
# read of a split is one ROWS poll and then END: the same batch, row for row,
# that `SearchCore.search` returns for the split. The split's byte length is
# reported as the source bytes of the reader's first poll (it parsed all of
# it); later polls report 0.
#
# ENCAPSULATION: no UnsafePointer in this file. The reader is erased by
# `ErasedScanSourceResolver.open_split` (komira_scan_resolver), which owns its
# SAFETY.
# =============================================================================

from komira_core.plan.expr import Expr
from komira_scan_resolver.scan_split import SplitPoll, SplitPosition, SplitReader

from komira_search.analyzer import AnalyzerConfig
from komira_search.source import QueryIR, SearchCore

from .search_source import search_split_hits


comptime SEARCH_SPLIT_POSITION_VERSION: UInt8 = 1
"""The version of the `komira.search.index` split-position encoding (the file
header). Bump it on any change to the encoding."""

comptime SEARCH_SPLIT_POSITION_INVALID: StaticString = (
    "SEARCH_SPLIT_POSITION_INVALID"
)
"""NAMED ERROR -- a split position whose bytes are not a search position: the
wrong length, an unknown tag, or a negative rank. Refused rather than read as
some other rank."""

comptime _AT_RANK: UInt8 = 0
comptime _DONE: UInt8 = 1
comptime _POSITION_LEN = 9


def search_split_position(kind_id: UInt32, done: Bool, rank: Int) -> SplitPosition:
    """The position `rank` of a split (`done` = read to its end; `rank` is
    then ignored and written as 0)."""
    var bytes = List[UInt8](capacity=_POSITION_LEN)
    bytes.append(_DONE if done else _AT_RANK)
    var n = UInt64(0) if done else UInt64(rank)
    for i in range(8):
        bytes.append(UInt8((n >> UInt64(8 * i)) & UInt64(0xFF)))
    return SplitPosition(kind_id, SEARCH_SPLIT_POSITION_VERSION, bytes^)


@fieldwise_init
struct SearchSplitAt(Copyable, Movable, Deinitable):
    """A decoded search position: `done`, or the next `rank` to read."""

    var done: Bool
    var rank: Int


def decode_search_split_position(
    position: SplitPosition, what: String
) raises -> SearchSplitAt:
    """Decode `position` (already checked for kind and version by the
    caller). Raises `SEARCH_SPLIT_POSITION_INVALID` naming `what`."""
    if len(position.bytes) != _POSITION_LEN:
        raise Error(
            String(SEARCH_SPLIT_POSITION_INVALID)
            + String(": the ")
            + what
            + String(" position has ")
            + String(len(position.bytes))
            + String(" bytes; a search position has ")
            + String(_POSITION_LEN)
        )
    var tag = position.bytes[0]
    if tag != _AT_RANK and tag != _DONE:
        raise Error(
            String(SEARCH_SPLIT_POSITION_INVALID)
            + String(": the ")
            + what
            + String(" position has tag ")
            + String(Int(tag))
        )
    var n = UInt64(0)
    for i in range(8):
        n |= UInt64(position.bytes[1 + i]) << UInt64(8 * i)
    if n > UInt64(0x7FFFFFFFFFFFFFFF):
        raise Error(
            String(SEARCH_SPLIT_POSITION_INVALID)
            + String(": the ")
            + what
            + String(" position's rank does not fit an Int64")
        )
    return SearchSplitAt(tag == _DONE, Int(n))


struct SearchSplitReader(SplitReader, Movable, Deinitable):
    """Reads one split's hits, by rank, from where it was opened to the end.

    Built by `SearchScanRuntime.open_split`, which checked the binding, the
    analyzer and the position before parsing the split."""

    var _core: SearchCore
    var _kind_id: UInt32
    var _field: String
    var _text: String
    var _cfg: AnalyzerConfig
    var _generation: Int64
    var _filter: Optional[Expr]
    var _at: Int
    var _done: Bool
    var _first_poll_bytes: Int64

    def __init__(
        out self,
        var core: SearchCore,
        kind_id: UInt32,
        var field: String,
        var text: String,
        var cfg: AnalyzerConfig,
        generation: Int64,
        var filter: Optional[Expr],
        at: SearchSplitAt,
        split_bytes: Int,
    ):
        self._core = core^
        self._kind_id = kind_id
        self._field = field^
        self._text = text^
        self._cfg = cfg^
        self._generation = generation
        self._filter = filter^
        self._at = at.rank
        self._done = at.done
        self._first_poll_bytes = Int64(split_bytes)

    def _position(self) -> SplitPosition:
        return search_split_position(self._kind_id, self._done, self._at)

    def poll(mut self, max_rows: Int64, max_bytes: Int64) raises -> SplitPoll:
        """The next ranks of the split as ONE batch: every remaining hit, or
        `max_rows` of them (at least one) when `max_rows` is set. END once the
        split has been read to its end. `max_bytes` does not split a poll: the
        split is parsed whole when it is opened."""
        if self._done:
            return SplitPoll.end(self._position())
        var remaining = self._core.doc_count() - self._at
        if remaining < 0:
            remaining = 0
        var want = remaining
        if max_rows >= Int64(0) and Int(max_rows) < want:
            want = Int(max_rows)
            if want < 1:
                want = 1
        var filter: Optional[Expr] = None
        if self._filter:
            filter = Optional(self._filter.value().copy())
        var q = QueryIR(
            self._field.copy(),
            self._text.copy(),
            want,
            self._cfg.copy(),
            self._generation,
            filter^,
            from_offset=self._at,
            match_all=(self._text == ""),
        )
        var batch = search_split_hits(self._core, q)
        var n = batch.num_rows()
        self._at += n
        # A page shorter than asked for is the end of the ranks; so is a read
        # past the split's doc count. A FULL page short of the doc count may
        # still have ranks after it, so the position stays a rank (a resume
        # from it reads the rest, possibly nothing).
        if n < want or self._at >= self._core.doc_count():
            self._done = True
        var bytes = self._first_poll_bytes
        self._first_poll_bytes = 0
        return SplitPoll.rows(batch^, self._position(), source_bytes=bytes)
