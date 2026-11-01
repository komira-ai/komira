# =============================================================================
# query_config -- what the host decides about the query routes.
# =============================================================================
#
# The query routes take their knobs from a `QueryConfig` the host hands the
# server when it builds it. The synthesis prompt is one of them: it is the
# system text the language model is given with the evidence pack, and the host
# chooses it. `QueryConfig.default()` carries a neutral prompt
# (`DEFAULT_SYNTHESIS_PROMPT`) that names no subject matter.
#
# `similarity_floor` is the lowest cosine at which an entity's name embedding
# counts as a semantic match for the query. Its right value depends on the
# embedder the host runs, so a host that changes embedders changes it; the
# default is a starting point, not a calibration.
# =============================================================================

from std.math import isfinite

comptime DEFAULT_SYNTHESIS_PROMPT: String = (
    "You answer a question using only the evidence pack that follows it. The"
    " pack lists entities and the relations between them, retrieved from a"
    " graph, most relevant first. Do not state anything the pack does not"
    " support. If the pack does not answer the question, say so plainly. Be"
    " concise."
)
"""The system text sent to the model when the host gives none."""

comptime SYNTHESIS_PROMPT_MAX_BYTES: Int = 16384
"""The longest synthesis prompt a `QueryConfig` accepts."""

comptime DEFAULT_QUERY_K: Int = 16
comptime DEFAULT_QUERY_MAX_K: Int = 1000
comptime DEFAULT_QUERY_MAX_BYTES: Int = 4096
comptime DEFAULT_MAX_PARTITIONS: Int = 32
comptime DEFAULT_PER_PARTITION_CAP: Int = 64
comptime DEFAULT_SIMILARITY_FLOOR: Float64 = 0.5


struct QueryConfig(Copyable, Movable):
    """The knobs of the query routes.

    Fields:
        synthesis_prompt: The system text sent with the evidence pack.
        default_k: The node cap of a query that names none.
        max_k: The largest node cap a query may ask for.
        max_query_bytes: The longest query text accepted.
        max_partitions: The most partitions one federated query may name.
        per_partition_cap: The most semantic seeds (and the most text matches)
            one partition contributes to a federated query, before the merge.
        similarity_floor: The lowest cosine that counts as a semantic match.
    """

    var synthesis_prompt: String
    var default_k: Int
    var max_k: Int
    var max_query_bytes: Int
    var max_partitions: Int
    var per_partition_cap: Int
    var similarity_floor: Float64

    def __init__(
        out self,
        var synthesis_prompt: String,
        default_k: Int,
        max_k: Int,
        max_query_bytes: Int,
        max_partitions: Int,
        per_partition_cap: Int,
        similarity_floor: Float64,
    ) raises:
        """A checked configuration.

        Raises:
            If the prompt is empty or over `SYNTHESIS_PROMPT_MAX_BYTES`; a count
            or size is below 1; `default_k` is over `max_k`; or the floor is
            not a number in [-1, 1].
        """
        var n = len(synthesis_prompt.as_bytes())
        if n == 0:
            raise Error("the synthesis prompt must not be empty")
        if n > SYNTHESIS_PROMPT_MAX_BYTES:
            raise Error(
                "the synthesis prompt is over "
                + String(SYNTHESIS_PROMPT_MAX_BYTES)
                + " bytes"
            )
        if default_k < 1 or max_k < 1:
            raise Error("default_k and max_k must be at least 1")
        if default_k > max_k:
            raise Error("default_k must not be over max_k")
        if max_query_bytes < 1:
            raise Error("max_query_bytes must be at least 1")
        if max_partitions < 1:
            raise Error("max_partitions must be at least 1")
        if per_partition_cap < 1:
            raise Error("per_partition_cap must be at least 1")
        if not isfinite(similarity_floor) or similarity_floor < -1.0 or similarity_floor > 1.0:
            raise Error("similarity_floor must be a number in [-1, 1]")
        self.synthesis_prompt = synthesis_prompt^
        self.default_k = default_k
        self.max_k = max_k
        self.max_query_bytes = max_query_bytes
        self.max_partitions = max_partitions
        self.per_partition_cap = per_partition_cap
        self.similarity_floor = similarity_floor

    def __init__(out self, *, defaults: Bool):
        """The neutral configuration (see `default`); `defaults` only selects
        this overload."""
        self.synthesis_prompt = String(DEFAULT_SYNTHESIS_PROMPT)
        self.default_k = DEFAULT_QUERY_K
        self.max_k = DEFAULT_QUERY_MAX_K
        self.max_query_bytes = DEFAULT_QUERY_MAX_BYTES
        self.max_partitions = DEFAULT_MAX_PARTITIONS
        self.per_partition_cap = DEFAULT_PER_PARTITION_CAP
        self.similarity_floor = DEFAULT_SIMILARITY_FLOOR

    @staticmethod
    def default() -> QueryConfig:
        """The neutral configuration: `DEFAULT_SYNTHESIS_PROMPT` and the
        `DEFAULT_*` limits above."""
        return QueryConfig(defaults=True)
