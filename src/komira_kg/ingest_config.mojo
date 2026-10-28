# =============================================================================
# ingest_config -- the knobs of one ingest and the episode it ingests.
# =============================================================================
#
# `IngestConfig` holds the numbers the entity cascade and the contradiction test
# are run with; `EpisodeInput` is one piece of source text with its provenance.
# Both are plain values. `partition_id`, `facet` and `facet_source` are opaque
# strings the host chooses; this package gives them no meaning beyond equality.
# No clock is read: an episode carries the times it is stamped with.
# =============================================================================

from std.math import isfinite


@fieldwise_init
struct IngestConfig(Copyable, Movable):
    """The per-ingest knobs.

    Fields:
        max_gleanings: Extra "did you miss any?" passes after the first extract.
            A pass that finds nothing new ends the loop early. At least 0.
        cosine_k: How many existing entities, nearest first by name embedding,
            are tried as candidates for each mention. At least 1.
        jaccard_merge: The Jaccard floor above which a fuzzy name match merges
            without a judgment; a finite number in [0, 1].
        jaccard_escalate: The Jaccard floor above which a fuzzy match is put to
            the `LlmClient`'s `judge_same_entity`; a finite number in [0, 1].
        min_entropy: The Shannon-entropy floor, in bits, under which a name is
            too generic to merge on similarity; finite and at least 0.
        match_predicate: Whether a contradiction candidate must also share the
            new edge's predicate (the default is the node pair alone). The
            `edges` table stores no predicate, so an edge read back from a
            snapshot has "" and shares a predicate only with an edge added since
            the load that was given none; this knob is for a set built in one
            run.
        cross_unit_context: Whether the extract is given the names and summaries
            of the partition's existing entities as its `already_found`, so a
            re-read piece of a larger source can relate its new text to entities
            an unchanged piece introduced. Off by default: the first pass then
            sees an empty list.
    """

    var max_gleanings: Int
    var cosine_k: Int
    var jaccard_merge: Float64
    var jaccard_escalate: Float64
    var min_entropy: Float64
    var match_predicate: Bool
    var cross_unit_context: Bool

    @staticmethod
    def default() -> Self:
        """One gleaning pass, eight candidates, merge at 0.7, escalate at 0.4,
        an entropy floor of 2.0 bits, the node pair alone as the subject, and no
        cross-unit context."""
        return Self(1, 8, 0.7, 0.4, 2.0, False, False)

    def check(self) raises:
        """Refuse a knob no ingest can run with.

        Raises:
            If `max_gleanings` is negative, `cosine_k` is below 1,
            `jaccard_merge` or `jaccard_escalate` is not a finite number in
            [0, 1], or `min_entropy` is not a finite number of at least 0.
        """
        if self.max_gleanings < 0:
            raise Error(
                "IngestConfig: max_gleanings must be at least 0, got "
                + String(self.max_gleanings)
            )
        if self.cosine_k < 1:
            raise Error(
                "IngestConfig: cosine_k must be at least 1, got "
                + String(self.cosine_k)
            )
        if not isfinite(self.jaccard_merge) or not (
            0.0 <= self.jaccard_merge <= 1.0
        ):
            raise Error(
                "IngestConfig: jaccard_merge must be a finite number in [0, 1],"
                " got "
                + String(self.jaccard_merge)
            )
        if not isfinite(self.jaccard_escalate) or not (
            0.0 <= self.jaccard_escalate <= 1.0
        ):
            raise Error(
                "IngestConfig: jaccard_escalate must be a finite number in"
                " [0, 1], got "
                + String(self.jaccard_escalate)
            )
        if not isfinite(self.min_entropy) or self.min_entropy < 0.0:
            raise Error(
                "IngestConfig: min_entropy must be a finite number of at least"
                " 0, got "
                + String(self.min_entropy)
            )


struct EpisodeInput(Copyable, Movable):
    """One episode to ingest.

    Fields:
        uuid: The stable external id of the source; a re-sync of the same source
            uses the same id (it is the change gate's key, with the partition).
        partition_id: The opaque id of the partition the episode belongs to.
        body: The raw text to extract from.
        ts: The system (ingest) time, stamped as `created_at`.
        valid_at: The event time the episode refers to; the default `valid_at`
            of its facts.
        facet: An opaque label for the kind of source, "" for none. Stamped on
            the episode row and on the `attrs` of the entities it mints.
        facet_source: The id of the source the facet is attributed to, "" for
            none (a tombstone keys on it together with the facet).
    """

    var uuid: String
    var partition_id: String
    var body: String
    var ts: Int64
    var valid_at: Int64
    var facet: String
    var facet_source: String

    def __init__(
        out self,
        var uuid: String,
        var partition_id: String,
        var body: String,
        ts: Int64,
        valid_at: Int64,
        var facet: String = String(""),
        var facet_source: String = String(""),
    ):
        """An episode; `facet` and `facet_source` are "" when the host has
        none."""
        self.uuid = uuid^
        self.partition_id = partition_id^
        self.body = body^
        self.ts = ts
        self.valid_at = valid_at
        self.facet = facet^
        self.facet_source = facet_source^

    def with_facet(
        var self, var facet: String, var facet_source: String
    ) -> EpisodeInput:
        """This episode with its facet and facet source replaced.

        Args:
            facet: The opaque facet label.
            facet_source: The id of the source the facet is attributed to.

        Returns:
            The episode, moved.
        """
        self.facet = facet^
        self.facet_source = facet_source^
        return self^
