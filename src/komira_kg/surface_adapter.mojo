# =============================================================================
# surface_adapter -- the seam between a source record and the episodes it becomes.
# =============================================================================
#
# A host reads many kinds of record (each its own typed value) and the graph
# ingests one kind of input, `EpisodeInput`. A `SurfaceAdapter` is the one place
# that lowers a record of its own `Source` type to a list of episodes; a new kind
# of record is one new conformer, and nothing in ingest, resolution or the store
# changes. This package ships the trait and no conformer: an adapter for any
# particular kind of document or service belongs to the host. Which adapter
# handles a given request is the host's choice, by whatever opaque tag it keeps
# (the tag is not part of this trait).
#
# THE CONTENT RULE, which every conformer must keep: `lower` feeds the record's
# real text into the episodes' `body`, verbatim, split only at whole-record
# boundaries. A short header (a subject line, a speaker prefix) may precede it; a
# summary or a paraphrase of the text must not replace it, since the graph can
# only extract what the body says. `uuid` must be stable for the same record
# (so a re-sync hits the change gate) and `valid_at` is the record's own time.
# =============================================================================

from .ingest_config import EpisodeInput


trait SurfaceAdapter(Movable):
    """Lower one source record to the episodes the graph ingests.

    Each conformer binds `Source`, the record type it understands, and keeps the
    content rule of the file header. It may hold configuration (a split size, a
    header format); `lower` must not read a clock or the environment, so the same
    record lowers to the same episodes.
    """

    comptime Source: Movable

    def lower(
        self, var source: Self.Source, partition_id: String
    ) raises -> List[EpisodeInput]:
        """Lower `source` to episodes.

        Args:
            source: The record (consumed; lowered once).
            partition_id: The partition the caller ingests into; the adapter
                stamps it on every episode and never chooses one.

        Returns:
            The episodes in order, at least one for a record with any text, each
            carrying the record's text verbatim in its `body`.

        Raises:
            If the record cannot be lowered (malformed, or text that cannot be
            split on a record boundary).
        """
        ...
