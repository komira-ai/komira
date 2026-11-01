# =============================================================================
# sort_stage_buffer_spill -- the spill ledger of a SortBuffer
# =============================================================================
#
# `SortBuffer` spills its pre-sort rows as THSPLC chunks. The ledger records the
# chunks a buffer has written, in spill order (the order the rows were fed), and
# does the storage I/O: encode and write, read and decode, release. The buffer
# keeps the column work (emitting the spill image, appending a decoded image).
#
# Restore reads and decodes chunks WITHOUT releasing them; the buffer releases
# the chunks only after the rebuilt rows are in place, so a failed restore
# leaves the ledger and the storage as they were.
# =============================================================================

from komira_arrow.schema import RecordBatch, Schema
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.thsplc import THSPLCDecoder, THSPLCEncoder


struct SortSpillLedger(Movable):
    """The spilled chunks of one SortBuffer, oldest first, and the mid-restore
    flag `can_spill` reports."""

    var chunks: List[ChunkId]
    var restoring: Bool

    def __init__(out self):
        self.chunks = List[ChunkId]()
        self.restoring = False

    def count(self) -> Int:
        """Number of chunks written and not yet released by a restore."""
        return len(self.chunks)

    def ids(self) -> List[ChunkId]:
        """The outstanding chunk ids, oldest first."""
        return self.chunks.copy()

    def write[
        S: SpillStorage
    ](mut self, mut storage: S, var image: RecordBatch) raises:
        """Encode `image` as THSPLC bytes, write it to `storage`, and record the
        chunk after the rows already spilled."""
        var bytes = THSPLCEncoder.encode(image^)
        var chunk = storage.write_chunk(bytes^)
        self.chunks.append(chunk)

    def read[
        S: SpillStorage
    ](self, mut storage: S, index: Int, schema: Schema) raises -> RecordBatch:
        """Read and decode chunk `index` (spill order) against `schema`. The
        chunk stays in the ledger and in the storage."""
        var bytes = storage.read_chunk(self.chunks[index])
        return THSPLCDecoder.decode_zerocopy(bytes^, schema.copy())

    def release_all[S: SpillStorage](mut self, mut storage: S) raises:
        """Release every outstanding chunk and empty the ledger. Every chunk is
        attempted; the first storage error is raised after the ledger is
        empty."""
        var failed = False
        var first = String("")
        for ci in range(len(self.chunks)):
            try:
                storage.release_chunk(self.chunks[ci])
            except e:
                if not failed:
                    failed = True
                    first = String(e)
        self.chunks.clear()
        if failed:
            raise Error(
                String("SortBuffer: releasing a spill chunk failed: ") + first
            )
