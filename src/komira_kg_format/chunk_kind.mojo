# =============================================================================
# chunk_kind -- which kind of body a manifest chunk of the snapshot lineage holds.
# =============================================================================
#
# The lineage mixes three kinds of chunk: a base (`KgManifestBody`), a chain head
# (`KgChainBody`) and a delta (`KgDeltaBody`). Each begins with its own format
# version, so the kind is read from those eight bytes and never inferred from
# the chunk's position, its size or the neighbouring chunks. A delta is written
# before the chain head that names it, so a reader that looks at the newest
# chunk can meet a delta; `kg_chunk_kind` is how it knows.
# =============================================================================

from .delta_body import KG_CHAIN_FORMAT_VERSION, KG_DELTA_FORMAT_VERSION
from .manifest_body import KG_SNAPSHOT_FORMAT_VERSION
from .wire import get_i64_le


# A base: the full tables of a snapshot (`KgManifestBody`).
comptime KG_CHUNK_BASE: Int = 0
# A chain head: a base and the deltas over it (`KgChainBody`).
comptime KG_CHUNK_CHAIN: Int = 1
# A delta: one ingest's diff (`KgDeltaBody`).
comptime KG_CHUNK_DELTA: Int = 2


def kg_chunk_kind(bytes: List[UInt8]) raises -> Int:
    """The kind of a chunk body (`KG_CHUNK_BASE`, `KG_CHUNK_CHAIN` or
    `KG_CHUNK_DELTA`), read from its format version.

    Raises:
        On a body shorter than eight bytes or a version that is none of the three.
    """
    var who = String("kg_chunk_kind")
    var fmt = get_i64_le(bytes, 0, who)
    if fmt == KG_SNAPSHOT_FORMAT_VERSION:
        return KG_CHUNK_BASE
    if fmt == KG_CHAIN_FORMAT_VERSION:
        return KG_CHUNK_CHAIN
    if fmt == KG_DELTA_FORMAT_VERSION:
        return KG_CHUNK_DELTA
    raise Error(
        who
        + ": unknown chunk format version "
        + String(fmt)
        + " (expected "
        + String(KG_SNAPSHOT_FORMAT_VERSION)
        + " base, "
        + String(KG_CHAIN_FORMAT_VERSION)
        + " chain or "
        + String(KG_DELTA_FORMAT_VERSION)
        + " delta)"
    )
