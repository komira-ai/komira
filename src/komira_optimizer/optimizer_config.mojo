# =============================================================================
# optimizer_config.mojo -- the optimizer's options, as one value.
#
# `OptimizerConfig` holds the fields documented on the struct, each with its
# default, and the two accessors that map a non-positive row limit to its
# default. A rule that takes the config states which fields it reads where that
# rule is defined.
#
# No global state and no environment reads: build it with `OptimizerConfig()`
# and assign the fields you change. Every default is the behaviour the optimizer
# has when nothing is set. There is no fieldwise constructor on purpose: eight
# positional Bool/Int arguments are easy to transpose without a compile error.
# =============================================================================

comptime AGG_INMEM_MAX_ROWS_DEFAULT: Int = 4_000_000
"""Default in-memory aggregate row ceiling (`OptimizerConfig.agg_inmem_max_rows`)."""

comptime FACT_STREAM_PROTECT_ROWS_DEFAULT: Int = 2_000_000
"""Default fact-stream protection threshold (`OptimizerConfig.fact_stream_protect_rows`)."""


struct OptimizerConfig(Copyable, Movable):
    """The optimizer's options. Construct with `OptimizerConfig()`.

    Fields:
        agg_cse_gate: The agg-CSE reachability gate (default True). When True,
            a plan with fewer than two grouped aggregate nodes skips the
            content-hash walk, which cannot fold anything on it. False runs the
            walk on every plan: that arm is the A/B baseline and the
            differential oracle. The two arms must agree on every value and may
            differ only in the hash-call counter.
        agg_cse_cheapkey: The agg-CSE cheap-key pre-grouping (default True).
            When True, the exact content hash is computed only for aggregate
            nodes whose cheap key is shared with another node. False hashes
            every grouped aggregate node (`collect_agg_subtree_hashes`); like
            the gate, the two arms must agree on every value.
        disable_scan_dedup: When True, scan sharing decides nothing: no
            scans share a read and every scan stays a Parquet source
            (default False).
        disable_scan_dedup_for_agg: When True, scan sharing skips a
            singleton scan whose only consumer (above Filter/Project) is an
            Aggregate, keeping it a Parquet source (default False).
        fact_stream_protect_rows: The raw row count above which a single-use
            fact scan feeding a join stays a Parquet source (default
            2,000,000).
            Read through `fact_stream_protect_threshold()`.
        agg_inmem_max_rows: The in-memory aggregate row ceiling (default
            4,000,000). A singleton scan feeding only an Aggregate above it
            stays a Parquet source. Read through `agg_inmem_ceiling_rows()`.
        semi_pushdown: Rule 11b, the SEMI/ANTI reducer pushdown
            (`optimizer_join.push_semi_reducers_down`, default True). False is
            the OFF arm: the rule returns its input plan
            unchanged.
        eager_agg: Cross-side eager aggregation
            (`optimizer_eager_agg.eager_aggregate_pushdown`, default True).
            `optimizer_driver.optimize` runs the pass on a plan with a join
            only when this is True; False skips it.
    """

    var agg_cse_gate: Bool
    var agg_cse_cheapkey: Bool
    var disable_scan_dedup: Bool
    var disable_scan_dedup_for_agg: Bool
    var fact_stream_protect_rows: Int
    var agg_inmem_max_rows: Int
    var semi_pushdown: Bool
    var eager_agg: Bool

    def __init__(out self):
        """Every option at its default."""
        self.agg_cse_gate = True
        self.agg_cse_cheapkey = True
        self.disable_scan_dedup = False
        self.disable_scan_dedup_for_agg = False
        self.fact_stream_protect_rows = FACT_STREAM_PROTECT_ROWS_DEFAULT
        self.agg_inmem_max_rows = AGG_INMEM_MAX_ROWS_DEFAULT
        self.semi_pushdown = True
        self.eager_agg = True

    def agg_inmem_ceiling_rows(self) -> Int:
        """The in-memory aggregate row ceiling. A non-positive value means the
        default, so the ceiling cannot be set to zero or below.
        """
        if self.agg_inmem_max_rows > 0:
            return self.agg_inmem_max_rows
        return AGG_INMEM_MAX_ROWS_DEFAULT

    def fact_stream_protect_threshold(self) -> Int:
        """The fact-stream protection row threshold. A non-positive value
        means the default."""
        if self.fact_stream_protect_rows > 0:
            return self.fact_stream_protect_rows
        return FACT_STREAM_PROTECT_ROWS_DEFAULT
