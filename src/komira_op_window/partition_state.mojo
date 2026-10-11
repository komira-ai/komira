# =============================================================================
# partition_state -- per-partition state holders for the typed window stage
# =============================================================================
#
# A typed window stage walks rows sorted by partition key and keeps, per
# window function, the state of the current partition. These holders carry
# that state and the current partition key, so the stage can tell when a row
# starts a new partition (`detect_boundary`) and reset (`reset_with`):
#
#   * `PartitionStateI64` / `PartitionStateF64`: one INT64 partition key, an
#     INT64 / FLOAT64 state.
#   * `PartitionStateI64I64` / `PartitionStateI64I64_F64`: a two-column INT64
#     key (a boundary when either column changes).
#   * `PartitionStateI64Paired` / `PartitionStateF64Paired`: a state and an
#     auxiliary slot (RANK's last key or tie count; AVG's running count).
#
# The keys are the values the stage extracted; a NULL key is the stage's to
# encode before it reaches these holders.
# =============================================================================


@fieldwise_init
struct PartitionStateI64(Copyable, Movable, Deinitable):
    """Per-partition window state holder for Int64-valued state.

    Fields:
      - current_partition_key: the Int64 key of the partition currently
        being processed.
      - state: the WindowFn's current state value.
      - has_started: False before the first row's partition is seen;
        True after init_partition for the first partition.

    Reset on partition boundary: detected by comparing the next row's
    partition-key against `current_partition_key`. On mismatch, call
    `reset_with(new_key, new_state)`.
    """

    var current_partition_key: Int64
    var state: Int64
    var has_started: Bool

    @staticmethod
    def new() -> PartitionStateI64:
        """Construct uninitialized state. `has_started=False` signals
        that the next row begins the first partition."""
        return PartitionStateI64(
            current_partition_key=Int64(0),
            state=Int64(0),
            has_started=False,
        )

    @always_inline
    def detect_boundary(self, candidate_key: Int64) -> Bool:
        """Return True if the candidate key starts a NEW partition
        (different from current; or this is the first row)."""
        if not self.has_started:
            return True
        return candidate_key != self.current_partition_key

    @always_inline
    def reset_with(mut self, new_key: Int64, new_state: Int64):
        """Reset state for a new partition.

        Called by WindowStage's `process_batch` on detected boundary.
        The `new_state` is computed by the WindowFn conformer's
        `init_partition()` method (e.g. RowNumber returns 0).
        """
        self.current_partition_key = new_key
        self.state = new_state
        self.has_started = True

    @always_inline
    def update_state(mut self, new_state: Int64):
        """Update the current state (e.g. RowNumber increments by 1
        per row). The WindowFn conformer's `advance` method computes
        the new state value; this writer commits it.
        """
        self.state = new_state



@fieldwise_init
struct PartitionStateF64(Copyable, Movable, Deinitable):
    """Per-partition window state holder for Float64-valued state."""

    var current_partition_key: Int64
    var state: Float64
    var has_started: Bool

    @staticmethod
    def new() -> PartitionStateF64:
        return PartitionStateF64(
            current_partition_key=Int64(0),
            state=Float64(0.0),
            has_started=False,
        )

    @always_inline
    def detect_boundary(self, candidate_key: Int64) -> Bool:
        if not self.has_started:
            return True
        return candidate_key != self.current_partition_key

    @always_inline
    def reset_with(mut self, new_key: Int64, new_state: Float64):
        self.current_partition_key = new_key
        self.state = new_state
        self.has_started = True

    @always_inline
    def update_state(mut self, new_state: Float64):
        self.state = new_state



@fieldwise_init
struct PartitionStateI64I64(Copyable, Movable, Deinitable):
    """Per-partition window state holder for composite (Int64, Int64)
    partition key + Int64-valued state.

    Fields:
      - current_partition_key_0: first key component of the current partition.
      - current_partition_key_1: second key component.
      - state: WindowFn current state value.
      - has_started: False before the first row's partition is seen.

    Boundary detection: candidate keys (k0, k1) differ from current pair
    on EITHER component → new partition.
    """

    var current_partition_key_0: Int64
    var current_partition_key_1: Int64
    var state: Int64
    var has_started: Bool

    @staticmethod
    def new() -> PartitionStateI64I64:
        return PartitionStateI64I64(
            current_partition_key_0=Int64(0),
            current_partition_key_1=Int64(0),
            state=Int64(0),
            has_started=False,
        )

    @always_inline
    def detect_boundary(
        self, candidate_key_0: Int64, candidate_key_1: Int64
    ) -> Bool:
        """Return True if (k0, k1) differs from current pair on either component
        (or this is the first row)."""
        if not self.has_started:
            return True
        return (
            candidate_key_0 != self.current_partition_key_0
            or candidate_key_1 != self.current_partition_key_1
        )

    @always_inline
    def reset_with(
        mut self,
        new_key_0: Int64,
        new_key_1: Int64,
        new_state: Int64,
    ):
        self.current_partition_key_0 = new_key_0
        self.current_partition_key_1 = new_key_1
        self.state = new_state
        self.has_started = True

    @always_inline
    def update_state(mut self, new_state: Int64):
        self.state = new_state



@fieldwise_init
struct PartitionStateI64I64_F64(Copyable, Movable, Deinitable):
    """Per-partition window state holder for composite (Int64, Int64)
    partition key + Float64-valued state.
    """

    var current_partition_key_0: Int64
    var current_partition_key_1: Int64
    var state: Float64
    var has_started: Bool

    @staticmethod
    def new() -> PartitionStateI64I64_F64:
        return PartitionStateI64I64_F64(
            current_partition_key_0=Int64(0),
            current_partition_key_1=Int64(0),
            state=Float64(0.0),
            has_started=False,
        )

    @always_inline
    def detect_boundary(
        self, candidate_key_0: Int64, candidate_key_1: Int64
    ) -> Bool:
        if not self.has_started:
            return True
        return (
            candidate_key_0 != self.current_partition_key_0
            or candidate_key_1 != self.current_partition_key_1
        )

    @always_inline
    def reset_with(
        mut self,
        new_key_0: Int64,
        new_key_1: Int64,
        new_state: Float64,
    ):
        self.current_partition_key_0 = new_key_0
        self.current_partition_key_1 = new_key_1
        self.state = new_state
        self.has_started = True

    @always_inline
    def update_state(mut self, new_state: Float64):
        self.state = new_state



@fieldwise_init
struct PartitionStateI64Paired(Copyable, Movable, Deinitable):
    """Per-partition window state holder for Int64 + auxiliary Int64 state.

    Fields:
      - current_partition_key: Int64 partition key.
      - state: primary state (running rank).
      - aux_state: auxiliary slot (e.g. last-seen sort key or tie counter).
      - has_started: bool.

    Used by Rank / DenseRank / similar paired-state WindowFns. The
    aux_state semantics are conformer-defined; the substrate just provides
    the second slot.
    """

    var current_partition_key: Int64
    var state: Int64
    var aux_state: Int64
    var has_started: Bool

    @staticmethod
    def new() -> PartitionStateI64Paired:
        return PartitionStateI64Paired(
            current_partition_key=Int64(0),
            state=Int64(0),
            aux_state=Int64(0),
            has_started=False,
        )

    @always_inline
    def detect_boundary(self, candidate_key: Int64) -> Bool:
        if not self.has_started:
            return True
        return candidate_key != self.current_partition_key

    @always_inline
    def reset_with(
        mut self, new_key: Int64, new_state: Int64, new_aux: Int64
    ):
        self.current_partition_key = new_key
        self.state = new_state
        self.aux_state = new_aux
        self.has_started = True

    @always_inline
    def update_state(mut self, new_state: Int64, new_aux: Int64):
        self.state = new_state
        self.aux_state = new_aux



@fieldwise_init
struct PartitionStateF64Paired(Copyable, Movable, Deinitable):
    """Per-partition window state holder for Float64 + auxiliary Float64
    state.

    Fields:
      - current_partition_key: Int64 partition key.
      - state: primary F64 state (running sum).
      - aux_state: auxiliary F64 state (running count as F64).
      - has_started: bool.

    Used by AvgOverFrameF64 and similar paired-state F64 WindowFns. The
    aux_state semantics are conformer-defined.
    """

    var current_partition_key: Int64
    var state: Float64
    var aux_state: Float64
    var has_started: Bool

    @staticmethod
    def new() -> PartitionStateF64Paired:
        return PartitionStateF64Paired(
            current_partition_key=Int64(0),
            state=Float64(0.0),
            aux_state=Float64(0.0),
            has_started=False,
        )

    @always_inline
    def detect_boundary(self, candidate_key: Int64) -> Bool:
        if not self.has_started:
            return True
        return candidate_key != self.current_partition_key

    @always_inline
    def reset_with(
        mut self, new_key: Int64, new_state: Float64, new_aux: Float64
    ):
        self.current_partition_key = new_key
        self.state = new_state
        self.aux_state = new_aux
        self.has_started = True

    @always_inline
    def update_state(mut self, new_state: Float64, new_aux: Float64):
        self.state = new_state
        self.aux_state = new_aux
