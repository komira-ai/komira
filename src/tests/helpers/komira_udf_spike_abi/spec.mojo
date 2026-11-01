# The values the harness's UdfRuntime takes and returns (runtime.mojo):
# capabilities, the spec and its descriptor, outcomes and results, call
# options. No pointer: a Handle holds a runtime's pointer as an opaque Word.

from ._cabi import Word
from .contract import (
    FORM_BUNDLE,
    IMMUTABLE,
    NULL_MANUAL,
    OK,
    SHAPE_MAP_BATCHES_FRAME,
    SHAPE_MAP_BATCHES_FRAME_GROUPED,
    SHAPE_ROW,
    run_error,
    status_name,
)
from .descriptor import DESCRIPTOR_VERSION, DescField, Descriptor, DescriptorEdit, apply_edit, encode, sorted_by_name
from .values import Batch, Column, ColumnType, type_format

comptime KIND_UDF = 1
comptime KIND_CONTEXT = 2
comptime KIND_INSTANCE = 3
comptime KIND_FRAME = 4
comptime KIND_GROUPS = 5
comptime _MAX_FRAME_OUTPUTS = 1_000
"""run_frame's bound: a frame that has not ended after this many outputs is
a runtime fault (no case's frame comes near it)."""


@fieldwise_init
struct Capabilities(Copyable, Movable, Writable):
    """What describe returned (design section 4.2), plus whether the optional
    memory_report entry is present."""

    var runtime_id: String
    var runtime_abi: String
    var max_descriptor_version: UInt32
    var shapes: UInt32
    var devices: UInt32
    var features: UInt32
    var udf_class: UInt32
    var has_memory_report: Bool

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            self.runtime_id, " abi=", self.runtime_abi, " class=", self.udf_class, " shapes=", self.shapes,
            " devices=", self.devices, " features=", self.features,
        )


@fieldwise_init
struct CodeObject(Copyable, Movable):
    """One code object of a UdfRef: its role (a runtime-defined label) and
    the sha256 of its bytes, which the host stores under the code root
    named by the hex digest."""

    var role: String
    var sha256: List[UInt8]


@fieldwise_init
struct CodeSet(Copyable, Movable):
    """The code root and code objects a suite gives every case's spec. An
    empty set leaves each spec as its case wrote it."""

    var root: String
    var objects: List[CodeObject]

    @staticmethod
    def none() -> CodeSet:
        return CodeSet("", List[CodeObject]())


struct UdfSpec(Copyable, Movable):
    """A UdfRef as the host decoded it: what komira_udf_spec carries. `args`
    is the argument struct's fields, named by `arg_names` (`c<i>` past its
    end; for ROW and MAP_BATCHES_FRAME, the read set by name if set, else
    every input column); `result` the result type, one field for a column, a
    struct's fields when `result_is_table`; `code` the code objects under
    `code_root`.

    The descriptor: by default the harness derives it from the spec itself,
    as a producer records it at capture (descriptor_for), and `edit` changes
    what a case asks. With `descriptor_raw` the bytes in `descriptor` are
    sent as they are (non-canonical or malformed bytes)."""

    var shape: UInt32
    var form: Int32
    var entry: String
    var descriptor_version: UInt32
    var descriptor: List[UInt8]
    var descriptor_raw: Bool
    var edit: DescriptorEdit
    var args: List[ColumnType]
    var arg_names: List[String]
    var result: List[ColumnType]
    var result_is_table: Bool
    var state: Optional[ColumnType]
    var null_mode: Int32
    var stability: Int32
    var code_root: String
    var code: List[CodeObject]

    def __init__(out self, shape: UInt32, entry: String, var args: List[ColumnType], var result: List[ColumnType]):
        self.shape = shape
        self.form = FORM_BUNDLE
        self.entry = entry
        self.descriptor_version = DESCRIPTOR_VERSION
        self.descriptor = List[UInt8]()
        self.descriptor_raw = False
        self.edit = DescriptorEdit()
        self.args = args^
        self.arg_names = List[String]()
        self.result = result^
        self.result_is_table = False
        self.state = None
        self.null_mode = NULL_MANUAL
        self.stability = IMMUTABLE
        self.code_root = ""
        self.code = List[CodeObject]()


def descriptor_for(spec: UdfSpec) -> Descriptor:
    """The descriptor a producer records for `spec` (design section 3.1):
    its entry, its one shape and its signature. For ROW and
    MAP_BATCHES_FRAME the argument fields are recorded_fields (present, in
    the canonical order), not `args`. Then the case's edit."""
    var d = Descriptor(spec.entry, spec.shape)
    var fields = List[DescField]()
    for i in range(len(spec.args)):
        var name = spec.arg_names[i] if i < len(spec.arg_names) else "c" + String(i)
        fields.append(DescField(name, type_format(spec.args[i].type_id)))
    if spec.shape & (SHAPE_ROW | SHAPE_MAP_BATCHES_FRAME | SHAPE_MAP_BATCHES_FRAME_GROUPED) != 0:
        d.has_recorded = True
        d.fields = sorted_by_name(fields)
    else:
        d.args = fields^
    for i in range(len(spec.result)):
        d.result.append(DescField("c" + String(i), type_format(spec.result[i].type_id)))
    d.result_is_table = spec.result_is_table
    if spec.state:
        d.state = DescField("c0", type_format(spec.state.value().type_id))
    apply_edit(d, spec.edit)
    return d^


def descriptor_bytes(spec: UdfSpec) -> List[UInt8]:
    """The bytes komira_udf_spec.descriptor carries for `spec`."""
    if spec.descriptor_raw:
        return spec.descriptor.copy()
    return encode(descriptor_for(spec))


struct Outcome(Copyable, Movable, Writable):
    """What an entry returned. `shape` and `cancel_was_set` are the call's
    (its UDF's shape; whether the host had set its cancel flag), which the
    error table reads for ERR_DEADLINE and ERR_KILLED."""

    var status: Int32
    var message: String
    var trace: String
    var row: Int64
    var group: Int64
    var fault: String
    var shape: UInt32
    var cancel_was_set: Bool

    def __init__(
        out self,
        status: Int32,
        message: String,
        trace: String,
        row: Int64,
        group: Int64,
        fault: String,
        shape: UInt32 = 0,
        cancel_was_set: Bool = False,
    ):
        self.status = status
        self.message = message
        self.trace = trace
        self.row = row
        self.group = group
        self.fault = fault
        self.shape = shape
        self.cancel_was_set = cancel_was_set

    @staticmethod
    def of(status: Int32) -> Outcome:
        return Outcome(status, "", "", -1, -1, "")

    def is_ok(self) -> Bool:
        return self.status == OK and self.fault == ""

    def run_error(self, at_call: Bool = True) -> String:
        """The fault's name when the host found one, else the status's
        (`at_call` False: the status came from validate or load)."""
        if self.fault != "":
            return String(self.fault.split(":")[0])
        return run_error(self.status, at_call, self.shape, self.cancel_was_set)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(status_name(self.status))
        if self.message != "":
            writer.write(" '", self.message, "'")
        if self.row >= 0:
            writer.write(" row=", self.row)
        if self.fault != "":
            writer.write(" fault=", self.fault)


def _rows(b: Batch, lo: Int, hi: Int) -> Batch:
    """Rows [lo, hi) of `b`, offsets dropped."""
    var out = Batch(hi - lo)
    for c in range(len(b.columns)):
        var col = Column(b.columns[c].type_id)
        for r in range(lo, hi):
            col.bits.append(b.columns[c].bits[r])
            col.valid.append(b.columns[c].valid[r])
        out.columns.append(col^)
    return out^


@fieldwise_init
struct Handle(Copyable, Movable):
    var _w: Word
    var kind: Int


@fieldwise_init
struct Opened(Copyable, Movable):
    var outcome: Outcome
    var handle: Handle


@fieldwise_init
struct CallResult(Copyable, Movable):
    var outcome: Outcome
    var column: Column


@fieldwise_init
struct FrameResult(Copyable, Movable):
    var outcome: Outcome
    var outputs: List[Batch]
    var pulls_before_first_output: Int
    var pulls: Int


@fieldwise_init
struct CallTimes(Copyable, Movable):
    """A timed loop on one thread: each call's ns, and the calls that
    failed, the outputs that were not what the loop expected, and the input
    arrays the runtime released (of len(samples_ns))."""

    var samples_ns: List[Int64]
    var failures: Int
    var mismatches: Int
    var released: Int


@fieldwise_init
struct ThreadTimes(Copyable, Movable):
    """A timed loop on several threads at once: the wall time, the process's
    CPU time (user and system) and the loop threads' own over the same span,
    the counts of CallTimes over every thread, the process's involuntary
    context switches, and the time inside the calls alone: summed over every
    thread, and the largest one thread's sum."""

    var wall_ns: Int64
    var process_cpu_ns: Int64
    var threads_cpu_ns: Int64
    var failures: Int
    var mismatches: Int
    var released: Int
    var involuntary_switches: Int64
    var calls_ns: Int64
    var calls_ns_max_thread: Int64


struct CallOptions(Copyable, Movable):
    """`cancel`: the cancel flag is set before the call. `cancel_during_call`:
    the host's now_ns callback sets the flag (a release store,
    native/cancel_flag.c) each time the runtime reads the host's clock during
    the call, so the flag goes up inside the call at the runtime's first
    clock read, never before the call starts, and no clock or thread decides
    when. `deadline_passed`: the deadline is one nanosecond after the host
    clock's zero, long past. `deadline_after_ns` (0: none): the deadline is
    that far in the future, on a virtual clock the host's now_ns answers
    during the call (1 ms per read, _host.arm_virtual_clock), so the runtime
    reaches it after a fixed number of its own clock reads."""

    var cancel: Bool
    var cancel_during_call: Bool
    var deadline_passed: Bool
    var deadline_after_ns: Int64
    var plant_extra_child: Bool
    """A host defect, test-only: the argument struct gets one child more than
    the bound schema (_host.device_struct)."""
    var plant_struct_offset: Bool
    """A host defect, test-only: the argument struct at offset 1."""

    def __init__(
        out self,
        cancel: Bool,
        cancel_during_call: Bool,
        deadline_passed: Bool,
        deadline_after_ns: Int64 = 0,
        plant_extra_child: Bool = False,
        plant_struct_offset: Bool = False,
    ):
        self.cancel = cancel
        self.cancel_during_call = cancel_during_call
        self.deadline_passed = deadline_passed
        self.deadline_after_ns = deadline_after_ns
        self.plant_extra_child = plant_extra_child
        self.plant_struct_offset = plant_struct_offset

    @staticmethod
    def plain() -> CallOptions:
        return CallOptions(False, False, False)


