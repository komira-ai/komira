# =============================================================================
# runtime -- one UDF runtime library opened, and the UDFs of one plan loaded
# =============================================================================
#
# `UdfRuntime` is one runtime library a session was given
# (`UdfRuntimeConfig`): opened with its options, its table checked, and its
# `describe` answer kept. It is shut down when it is dropped, which waits for
# the runtime's processes (komira/python's zygote) to end. A session holds one
# behind an `ArcPointer`, so every run's binding and every worker's instance
# keeps it alive until the last of them is gone.
#
# `UdfBinding` is the UDFs of one plan, by the index the plan's calls name,
# each admitted and loaded before any row is read (design
# udf_runtime_interface.md section 4.3, and optimized_plan_udf_runtime.md's
# admission checks 3 to 7, as a local run makes them):
#
#   - the runtime it names is the one the session holds
#     (`OPTIMIZED_ENV_RUNTIME_MISSING`, naming both);
#   - its kind is a call this engine hosts, SCALAR or MAP_BATCHES_COLUMN
#     through `call_batch`, and a shape the runtime reports
#     (`OPTIMIZED_UDF_KIND_UNSUPPORTED`);
#   - it has a return type (`OPTIMIZED_UDF_RETURN_TYPE_MISSING`), and under
#     NULL_PROPAGATE one the host can place back in the NULL rows: a
#     fixed-width, boolean or string type (`UDF_NULL_PROPAGATE_UNSUPPORTED`);
#   - every code object it names is a file of the code root, by its hex
#     sha256 (`OPTIMIZED_ENV_CODE_MISSING`, naming the digest), checked before
#     the runtime is asked anything;
#   - the runtime's `validate`, then its `load`, accept it (their statuses by
#     the table of `status.mojo`).
#
# The UDFs are unloaded when the binding is dropped, after every instance
# made from it (each holds the binding).
# =============================================================================

from std.memory import ArcPointer
from std.os.path import exists

from arrow.schema import Field, Schema, SchemaBuilder
from column_kernels.cross_batch_gather import _is_supported
from plan_expr.udf_data import (
    UDF_NULL_MANUAL,
    UDF_STABILITY_IMMUTABLE,
    UDF_STABILITY_STABLE,
)
from plan_expr.udf_type_field import udf_type_to_field
from plan_ir.udf_ref import (
    CODE_FORM_BUNDLE,
    CODE_FORM_PACKAGE,
    UDF_REF_KIND_MAP_BATCHES_COLUMN,
    UDF_REF_KIND_SCALAR,
    UdfRef,
    udf_ref_kind_name,
)

from ._abi import (
    ABI_MAJOR,
    REQUIRED_TABLE_BYTES,
    Handle,
    SpecValues,
    describe,
    free_host,
    load,
    open_runtime,
    shutdown,
    table_bytes,
    table_major,
    unload,
    validate,
)
from .status import (
    OPTIMIZED_ENV_CODE_MISSING,
    OPTIMIZED_ENV_RUNTIME_MISSING,
    OPTIMIZED_UDF_KIND_UNSUPPORTED,
    OPTIMIZED_UDF_RETURN_TYPE_MISSING,
    UDF_ERR_BAD_OPTION,
    UDF_RUNTIME_ABI_MISMATCH,
    UDF_RUNTIME_FAULT,
    UDF_RUNTIME_INIT_REFUSED,
    UDF_NULL_PROPAGATE_UNSUPPORTED,
    UDF_RUNTIME_OPTION_INVALID,
    status_code,
    status_name,
)

comptime DEFAULT_BATCH_DEADLINE_MS = 600000
"""The per-batch bound when a session sets none: ten minutes of one call
(`UdfRuntimeConfig.batch_deadline_ms`)."""

comptime SHAPE_SCALAR: UInt32 = 1
comptime SHAPE_ROW: UInt32 = 2
comptime SHAPE_MAP_BATCHES_COLUMN: UInt32 = 4


struct UdfRuntimeConfig(Copyable, Movable):
    """What a session is given to run UDFs with: the runtime library's path,
    the runtime's own options (`key=value` strings it reads at init; the
    engine passes them on unread), the directory of code objects named by
    their hex sha256, and the bound of one batch's call in milliseconds
    (0 is `DEFAULT_BATCH_DEADLINE_MS`)."""

    var library: String
    var options: List[String]
    var code_root: String
    var batch_deadline_ms: Int

    def __init__(
        out self,
        var library: String,
        var options: List[String],
        var code_root: String,
        batch_deadline_ms: Int = 0,
    ):
        self.library = library^
        self.options = options^
        self.code_root = code_root^
        self.batch_deadline_ms = batch_deadline_ms

    def deadline_ms(self) -> Int:
        """The bound of one batch's call, in milliseconds."""
        if self.batch_deadline_ms > 0:
            return self.batch_deadline_ms
        return DEFAULT_BATCH_DEADLINE_MS


struct UdfRuntime(Movable):
    """One runtime library, opened and initialized; shut down when dropped."""

    var config: UdfRuntimeConfig
    var runtime_id: String
    """`describe`'s runtime id (`komira/python`)."""
    var runtime_abi: String
    var shapes: UInt32
    """`describe`'s shape bits."""
    var _lib: Handle
    var _table: Handle
    var _rt: Handle
    var _host: Handle

    def __init__(
        out self,
        var config: UdfRuntimeConfig,
        var caps_id: String,
        var caps_abi: String,
        shapes: UInt32,
        lib: Handle,
        table: Handle,
        rt: Handle,
        host: Handle,
    ):
        self.config = config^
        self.runtime_id = caps_id^
        self.runtime_abi = caps_abi^
        self.shapes = shapes
        self._lib = lib
        self._table = table
        self._rt = rt
        self._host = host

    @staticmethod
    def open(var config: UdfRuntimeConfig) raises -> UdfRuntime:
        """Open `config.library`, init it with `config.options`, check its
        table and ask `describe`.

        Raises:
            UDF_RUNTIME_OPEN_FAILED or UDF_RUNTIME_MISSING_SYMBOL when the
            library does not load or has no init export;
            UDF_RUNTIME_OPTION_INVALID when init refuses an option, and
            UDF_RUNTIME_INIT_REFUSED for any other refusal, each with the
            runtime's message; UDF_RUNTIME_ABI_MISMATCH when the table is of
            another major or too short; UDF_RUNTIME_FAULT when describe fails
            (the runtime is shut down first).
        """
        var o = open_runtime(config.library, config.options)
        if o.refusal:
            ref e = o.refusal.value()
            var code = UDF_RUNTIME_OPTION_INVALID if e.code == UDF_ERR_BAD_OPTION else UDF_RUNTIME_INIT_REFUSED
            raise Error(
                String(code) + ": the UDF runtime " + config.library + " refused init ("
                + status_name(e.code) + "): " + e.message
            )
        if table_major(o.table) != ABI_MAJOR or table_bytes(o.table) < REQUIRED_TABLE_BYTES:
            var major = table_major(o.table)
            var size = table_bytes(o.table)
            if size >= REQUIRED_TABLE_BYTES:
                shutdown(o.table, o.rt)
            free_host(o.host)
            raise Error(
                String(UDF_RUNTIME_ABI_MISMATCH) + ": the UDF runtime " + config.library
                + " has a table of major " + String(major) + " and " + String(size)
                + " bytes; this engine needs major " + String(ABI_MAJOR) + " and "
                + String(REQUIRED_TABLE_BYTES) + " bytes"
            )
        var caps = describe(o.table, o.rt)
        if caps.status != 0:
            shutdown(o.table, o.rt)
            free_host(o.host)
            raise Error(
                String(UDF_RUNTIME_FAULT) + ": the UDF runtime " + config.library
                + " answered describe with " + status_name(caps.status)
            )
        return UdfRuntime(
            config^, caps.runtime_id^, caps.runtime_abi^, caps.shapes,
            o.lib, o.table, o.rt, o.host,
        )

    def table(self) -> Handle:
        return self._table

    def rt(self) -> Handle:
        return self._rt

    def __del__(deinit self):
        # Every binding and instance holds this runtime, so none is left:
        # shutdown is the last entry called, and no callback runs after it.
        shutdown(self._table, self._rt)
        free_host(self._host)


def _hex(digest: List[UInt8]) -> String:
    var digits = "0123456789abcdef"
    var out = String("")
    for i in range(len(digest)):
        var b = Int(digest[i])
        out += String(digits[byte=b >> 4])
        out += String(digits[byte=b & 15])
    return out^


def _shape_of(kind: UInt8) -> UInt32:
    if kind == UDF_REF_KIND_SCALAR:
        return SHAPE_SCALAR
    if kind == UDF_REF_KIND_MAP_BATCHES_COLUMN:
        return SHAPE_MAP_BATCHES_COLUMN
    return 0


def _form_of(form: UInt8) -> Int32:
    """The ABI's CodeForm (PACKAGE 1, BUNDLE 2, VALUE 3) of an engine form."""
    if form == CODE_FORM_PACKAGE:
        return 1
    if form == CODE_FORM_BUNDLE:
        return 2
    return 3


def _null_mode_of(mode: UInt8) -> Int32:
    """The ABI's null mode (MANUAL 1, PROPAGATE 2)."""
    return 1 if mode == UDF_NULL_MANUAL else 2


def _stability_of(stability: UInt8) -> Int32:
    """The ABI's stability (IMMUTABLE 1, STABLE 2, VOLATILE 3)."""
    if stability == UDF_STABILITY_IMMUTABLE:
        return 1
    if stability == UDF_STABILITY_STABLE:
        return 2
    return 3


def arg_schema(ref u: UdfRef) -> Schema:
    """The struct schema of `u`'s arguments: one field per `arg_types` entry,
    in call order."""
    var b = SchemaBuilder()
    for i in range(len(u.arg_types)):
        b.add_field(udf_type_to_field(u.arg_types[i]))
    return b.build()


def result_field(ref u: UdfRef) -> Field:
    """The field of `u`'s result (its return type; admission refused a UDF
    without one)."""
    return udf_type_to_field(u.return_type.value())


def spec_values(ref u: UdfRef, code_root: String) -> SpecValues:
    """The komira_udf_spec of `u`, in the ABI's numbering."""
    var roles = List[String]()
    var digests = List[List[UInt8]]()
    for i in range(len(u.code.code)):
        roles.append(u.code.code[i].role.copy())
        digests.append(u.code.code[i].sha256.copy())
    return SpecValues(
        Int32(_shape_of(u.kind)),
        _form_of(u.code.form),
        u.code.entry.copy(),
        u.code.descriptor_version,
        u.code.descriptor.copy(),
        arg_schema(u),
        result_field(u),
        _null_mode_of(u.null_mode),
        _stability_of(u.stability),
        code_root.copy(),
        roles^,
        digests^,
    )


def _udf_name(ref u: UdfRef, index: Int) -> String:
    return "UDF " + String(index) + " (" + u.code.entry + ", " + u.code.runtime + ")"


def admit(ref u: UdfRef, index: Int, ref runtime: UdfRuntime) raises:
    """The checks a UDF passes before the runtime is asked about it (the
    module header's first four)."""
    if u.code.runtime != runtime.runtime_id:
        raise Error(
            String(OPTIMIZED_ENV_RUNTIME_MISSING) + ": " + _udf_name(u, index)
            + " needs the runtime " + u.code.runtime + ", and this session holds "
            + runtime.runtime_id
        )
    var shape = _shape_of(u.kind)
    if shape == 0 or (runtime.shapes & shape) == 0:
        raise Error(
            String(OPTIMIZED_UDF_KIND_UNSUPPORTED) + ": " + _udf_name(u, index) + " is a "
            + udf_ref_kind_name(u.kind) + " call; this engine runs SCALAR and"
            " MAP_BATCHES_COLUMN calls the runtime reports"
        )
    if not u.return_type:
        raise Error(String(OPTIMIZED_UDF_RETURN_TYPE_MISSING) + ": " + _udf_name(u, index) + " has no return type")
    var ret = u.return_type.value().arrow_type
    if u.null_mode != UDF_NULL_MANUAL and not _is_supported(ret):
        raise Error(
            String(UDF_NULL_PROPAGATE_UNSUPPORTED) + ": " + _udf_name(u, index) + " returns "
            + String(ret) + ", which this engine cannot place back in the NULL rows of a"
            " NULL_PROPAGATE call yet; declare it null_mode='manual'"
        )
    for i in range(len(u.code.code)):
        var name = _hex(u.code.code[i].sha256)
        var path = runtime.config.code_root + "/" + name
        if not exists(path):
            raise Error(
                String(OPTIMIZED_ENV_CODE_MISSING) + ": " + _udf_name(u, index) + " needs the code object "
                + name + " (" + u.code.code[i].role + "), and the code root "
                + runtime.config.code_root + " has no such file"
            )


struct UdfBinding(Movable):
    """The UDFs of one plan, loaded by the index its calls name; unloaded
    when dropped. An empty binding (a plan with no UDF) holds no runtime."""

    var _runtime: Optional[ArcPointer[UdfRuntime]]
    var _refs: List[UdfRef]
    var _udfs: List[Handle]

    def __init__(out self):
        """The binding of a plan with no UDF."""
        self._runtime = None
        self._refs = List[UdfRef]()
        self._udfs = List[Handle]()

    @staticmethod
    def bind(runtime: ArcPointer[UdfRuntime], ref refs: List[UdfRef]) raises -> UdfBinding:
        """Admit, validate and load each of `refs` on `runtime`, in order.

        Raises:
            The first refusal (the module header's checks), naming the UDF
            by its index, entry and runtime; the UDFs loaded before it are
            unloaded.
        """
        var b = UdfBinding()
        b._runtime = Optional(runtime)
        ref rt = runtime[]
        for i in range(len(refs)):
            admit(refs[i], i, rt)
            var v = spec_values(refs[i], rt.config.code_root)
            var checked = validate(rt.table(), rt.rt(), v)
            if checked.code != 0:
                raise Error(
                    status_code(checked.code) + ": " + _udf_name(refs[i], i) + " was refused by validate ("
                    + status_name(checked.code) + "): " + checked.error.message
                )
            var loaded = load(rt.table(), rt.rt(), v)
            if loaded.code != 0:
                raise Error(
                    status_code(loaded.code) + ": " + _udf_name(refs[i], i) + " did not load ("
                    + status_name(loaded.code) + "): " + loaded.error.message
                )
            b._refs.append(refs[i].copy())
            b._udfs.append(loaded.made)
        return b^

    def count(self) -> Int:
        """How many UDFs are loaded."""
        return len(self._refs)

    def ref_at(self, index: Int) -> ref [self._refs] UdfRef:
        """The `UdfRef` of UDF `index` (0 <= index < count())."""
        return self._refs[index]

    def refs(self) -> List[UdfRef]:
        """Copies of every `UdfRef`, in index order."""
        var out = List[UdfRef](capacity=len(self._refs))
        for i in range(len(self._refs)):
            out.append(self._refs[i].copy())
        return out^

    def runtime(self) -> ArcPointer[UdfRuntime]:
        """The runtime the UDFs are loaded on (count() > 0)."""
        return self._runtime.value()

    def udf_handle(self, index: Int) -> Handle:
        return self._udfs[index]

    def name_of(self, index: Int) -> String:
        """`UDF <index> (<entry>, <runtime>)`, as the errors name it."""
        return _udf_name(self._refs[index], index)

    def __del__(deinit self):
        if not self._runtime:
            return
        ref rt = self._runtime.value()[]
        for i in range(len(self._udfs)):
            unload(rt.table(), self._udfs[i])
