# =============================================================================
# udf_ref — one user function a plan calls (optimized_plan_udfs.md §10.3)
# =============================================================================
#
# A plan names a user function by its index in a list that travels beside
# it: an optimized plan's `DeclaredNeeds.udfs`, a raw envelope's `udfs`. The
# plan nodes hold the index (`EXPR_UDF_APPLY`, `PLAN_MAP_BATCHES`,
# `PLAN_STEP`); this module is the list's element, the IR twin of the wire
# message `UdfRef` in `komira_plan_proto/plan.proto`.
#
# ★ PRESENCE IS A TYPE, NOT A CONVENTION. `return_type`, `state_type` and
# `read_set` are `Optional`: an unset read set reads every input column and an
# empty one reads none (§10.2), and the two must never become one value. A
# `List[String]` whose emptiness meant "unset" would be exactly that defect.
#
# The kind, form, stability and null-mode values are the engine's own: the
# plan-wire codec maps each to its wire enum and refuses a value outside the
# set.
# =============================================================================

from komira_plan_expr.udf_type import UdfType


# The call shape (§10.2). Engine values; the wire `UdfKind` numbers them as
# the design does (SCALAR = 1 ... ROW = 6), and the codec maps one onto the
# other.
comptime UDF_REF_KIND_SCALAR: UInt8 = 0
comptime UDF_REF_KIND_MAP_BATCHES_COLUMN: UInt8 = 1
comptime UDF_REF_KIND_AGGREGATE: UInt8 = 2
comptime UDF_REF_KIND_STEP: UInt8 = 3
comptime UDF_REF_KIND_MAP_BATCHES_FRAME: UInt8 = 4
comptime UDF_REF_KIND_ROW: UInt8 = 5

# How the code is reached (§10.3, §10.6).
comptime CODE_FORM_PACKAGE: UInt8 = 0
comptime CODE_FORM_BUNDLE: UInt8 = 1
comptime CODE_FORM_VALUE: UInt8 = 2


def udf_ref_kind_name(kind: UInt8) -> String:
    """The design's name of a `UDF_REF_KIND_*` value, or `kind#<n>`."""
    if kind == UDF_REF_KIND_SCALAR:
        return "SCALAR"
    if kind == UDF_REF_KIND_MAP_BATCHES_COLUMN:
        return "MAP_BATCHES_COLUMN"
    if kind == UDF_REF_KIND_AGGREGATE:
        return "AGGREGATE"
    if kind == UDF_REF_KIND_STEP:
        return "STEP"
    if kind == UDF_REF_KIND_MAP_BATCHES_FRAME:
        return "MAP_BATCHES_FRAME"
    if kind == UDF_REF_KIND_ROW:
        return "ROW"
    return "kind#" + String(Int(kind))


struct CodeDigest(Movable):
    """One code object: a runtime-defined role and its sha256 (32 bytes)."""

    var role: String
    var sha256: List[UInt8]

    def __init__(out self, var role: String, var sha256: List[UInt8]):
        self.role = role^
        self.sha256 = sha256^

    def copy(self) -> Self:
        return Self(self.role.copy(), self.sha256.copy())


struct UdfCode(Movable):
    """Which runtime, which entry, which code objects (§10.3). `runtime` is
    an open, namespaced id the format never enumerates; `descriptor` is the
    runtime's own canonical bytes."""

    var runtime: String
    var form: UInt8
    var entry: String
    var code: List[CodeDigest]
    var descriptor_version: UInt32
    var descriptor: List[UInt8]

    def __init__(
        out self,
        var runtime: String,
        form: UInt8,
        var entry: String,
        var code: List[CodeDigest] = List[CodeDigest](),
        descriptor_version: UInt32 = 0,
        var descriptor: List[UInt8] = List[UInt8](),
    ):
        self.runtime = runtime^
        self.form = form
        self.entry = entry^
        self.code = code^
        self.descriptor_version = descriptor_version
        self.descriptor = descriptor^

    def copy(self) -> Self:
        var code = List[CodeDigest](capacity=len(self.code))
        for i in range(len(self.code)):
            code.append(self.code[i].copy())
        return Self(
            self.runtime.copy(), self.form, self.entry.copy(), code^,
            self.descriptor_version, self.descriptor.copy(),
        )


struct UdfResources(ImplicitlyCopyable, Movable):
    """Per-worker resources (§10.8). 0 means "the host chooses" for each."""

    var worker_mem_bytes: UInt64
    var max_workers: UInt32
    var max_batch_rows: UInt32
    var max_runtime_ms: UInt64
    var max_concurrent_calls: UInt32

    def __init__(
        out self,
        worker_mem_bytes: UInt64 = 0,
        max_workers: UInt32 = 0,
        max_batch_rows: UInt32 = 0,
        max_runtime_ms: UInt64 = 0,
        max_concurrent_calls: UInt32 = 0,
    ):
        self.worker_mem_bytes = worker_mem_bytes
        self.max_workers = max_workers
        self.max_batch_rows = max_batch_rows
        self.max_runtime_ms = max_runtime_ms
        self.max_concurrent_calls = max_concurrent_calls


struct UdfRef(Movable):
    """One user function (§10.3). Its identity is its canonical wire bytes;
    the plan names it by its index in the list it belongs to.

    Fields:
        kind: a `UDF_REF_KIND_*` call shape.
        code: the runtime, entry and code objects.
        arg_types: the declared argument types, in call order. For ROW and
            MAP_BATCHES_FRAME, the columns the function receives: the read
            set's when it is set, else every input column, in input order.
        data_blobs: the sha256 of each captured value stored apart from the
            code.
        return_type: required by the format; `None` is what a message without
            one decodes to, and admission refuses it.
        stability: a `UDF_STABILITY_*` value (komira_plan_expr.udf_data).
        null_mode: `UDF_NULL_MANUAL` or `UDF_NULL_PROPAGATE`.
        resources: per-worker resources.
        state_type: AGGREGATE only; set iff the mergeable form.
        preserves_event_time: MAP_BATCHES_FRAME only.
        read_set: ROW and MAP_BATCHES_FRAME only. `None` reads every input
            column; `Some([])` reads none.
    """

    var kind: UInt8
    var code: UdfCode
    var arg_types: List[UdfType]
    var data_blobs: List[List[UInt8]]
    var return_type: Optional[UdfType]
    var stability: UInt8
    var null_mode: UInt8
    var resources: UdfResources
    var state_type: Optional[UdfType]
    var preserves_event_time: Bool
    var read_set: Optional[List[String]]

    def __init__(
        out self,
        kind: UInt8,
        var code: UdfCode,
        var arg_types: List[UdfType],
        var return_type: Optional[UdfType],
        stability: UInt8,
        null_mode: UInt8,
        var read_set: Optional[List[String]] = None,
        var state_type: Optional[UdfType] = None,
        var data_blobs: List[List[UInt8]] = List[List[UInt8]](),
        resources: UdfResources = UdfResources(),
        preserves_event_time: Bool = False,
    ):
        self.kind = kind
        self.code = code^
        self.arg_types = arg_types^
        self.data_blobs = data_blobs^
        self.return_type = return_type^
        self.stability = stability
        self.null_mode = null_mode
        self.resources = resources
        self.state_type = state_type^
        self.preserves_event_time = preserves_event_time
        self.read_set = read_set^

    def copy(self) -> Self:
        var args = List[UdfType](capacity=len(self.arg_types))
        for i in range(len(self.arg_types)):
            args.append(self.arg_types[i].copy())
        var ret = Optional[UdfType](None)
        if self.return_type:
            ret = Optional(self.return_type.value().copy())
        var state = Optional[UdfType](None)
        if self.state_type:
            state = Optional(self.state_type.value().copy())
        var rs = Optional[List[String]](None)
        if self.read_set:
            rs = Optional(self.read_set.value().copy())
        return Self(
            self.kind, self.code.copy(), args^, ret^, self.stability,
            self.null_mode, rs^, state^, self.data_blobs.copy(),
            self.resources, self.preserves_event_time,
        )
