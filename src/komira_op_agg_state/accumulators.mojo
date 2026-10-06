# =============================================================================
# Accumulators — per-group aggregation state
# =============================================================================
#
# Extracted from aggregate.mojo. Contains:
#   - CountDistinctAccumulator: hash-set-based distinct counting
#   - AggAccumulator: per-group SUM/COUNT/MIN/MAX state
#   - MultiAggAccumulator: N-slot per-group accumulator for multiple aggs
# =============================================================================


# =============================================================================
# CountDistinctAccumulator
# =============================================================================


struct CountDistinctAccumulator(Movable, Copyable):
    """Counts distinct Int64 values using a Dict as a hash set."""

    var seen: Dict[Int, Bool]

    def __init__(out self, var seen: Dict[Int, Bool]):
        self.seen = seen^

    @staticmethod
    def create() -> CountDistinctAccumulator:
        """Create a new empty CountDistinctAccumulator."""
        return CountDistinctAccumulator(Dict[Int, Bool]())

    @always_inline
    def insert(mut self, value: Int):
        """Record a value as seen. Duplicates are ignored."""
        self.seen[value] = True

    def result(self) -> Int:
        """Return the count of distinct values seen."""
        return len(self.seen)


# =============================================================================
# AggAccumulator — Per-group running aggregation state
# =============================================================================


struct AggAccumulator(Movable, Copyable):
    """Tracks running SUM, COUNT, MIN, MAX for a single group."""

    var sum: Float64
    var count: Int
    var min_val: Float64
    var max_val: Float64

    def __init__(out self, sum: Float64, count: Int, min_val: Float64, max_val: Float64):
        self.sum = sum
        self.count = count
        self.min_val = min_val
        self.max_val = max_val

    @staticmethod
    def create() -> AggAccumulator:
        """Create a new accumulator with zero-state initialization."""
        return AggAccumulator(
            sum=0.0,
            count=0,
            min_val=Float64.MAX,
            max_val=Float64.MIN,
        )

    @always_inline
    def update(mut self, value: Float64):
        """Update this accumulator with a new value."""
        self.sum += value
        self.count += 1
        if value < self.min_val:
            self.min_val = value
        if value > self.max_val:
            self.max_val = value


# =============================================================================
# MultiAggAccumulator — Per-group state for N independent aggregations
# =============================================================================


struct MultiAggAccumulator(Movable, Copyable):
    """Tracks N independent aggregation results per group."""

    var sums: List[Float64]
    var counts: List[Int]
    var mins: List[Float64]
    var maxs: List[Float64]
    var num_aggs: Int

    def __init__(out self, var sums: List[Float64], var counts: List[Int],
                 var mins: List[Float64], var maxs: List[Float64], num_aggs: Int):
        self.sums = sums^
        self.counts = counts^
        self.mins = mins^
        self.maxs = maxs^
        self.num_aggs = num_aggs

    @staticmethod
    def create(num_aggs: Int) -> MultiAggAccumulator:
        """Create a new MultiAggAccumulator with zero-state initialization."""
        var sums = List[Float64]()
        var counts = List[Int]()
        var mins = List[Float64]()
        var maxs = List[Float64]()
        for _ in range(num_aggs):
            sums.append(0.0)
            counts.append(0)
            mins.append(Float64.MAX)
            maxs.append(Float64.MIN)
        return MultiAggAccumulator(sums^, counts^, mins^, maxs^, num_aggs)

    @always_inline
    def update(mut self, agg_index: Int, value: Float64):
        """Update a specific aggregation slot with a new value."""
        self.sums[agg_index] += value
        self.counts[agg_index] += 1
        if value < self.mins[agg_index]:
            self.mins[agg_index] = value
        if value > self.maxs[agg_index]:
            self.maxs[agg_index] = value

    @always_inline
    def update_count_only(mut self, agg_index: Int):
        """Update only the count for a COUNT(*) aggregation."""
        self.counts[agg_index] += 1

    @always_inline
    def avg(self, agg_index: Int) -> Float64:
        """Compute the average (SUM / COUNT) for a specific slot."""
        if self.counts[agg_index] > 0:
            return self.sums[agg_index] / Float64(self.counts[agg_index])
        return 0.0
