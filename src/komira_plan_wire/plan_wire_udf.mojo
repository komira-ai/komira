# =============================================================================
# plan_wire_udf — `UdfRef` to bytes and back, and the checks on one `UdfRef`
# (docs/design/optimized_plan_udfs.md §10.2-§10.4, §10.7)
# =============================================================================
#
# A plan calls user functions by index into a list beside it: an optimized
# plan's `DeclaredNeeds.udfs`, a raw envelope's `WirePlanEnvelope.udfs`. This
# module converts one list entry between the wire message (`UdfRef` in
# `plan.proto`, imported here as `WireUdfRef`) and the IR
# (`komira_plan_ir.udf_ref.UdfRef`), and refuses, by name, an entry that is
# wrong on its own, before any plan node looks at it:
#
#   OPTIMIZED_UDF_RETURN_TYPE_MISSING   no `return_type` (§10.4, §10.5)
#   OPTIMIZED_UDF_RUNTIME_MALFORMED     `code` absent, `code.runtime` outside
#                                       the grammar, `form` unset, a PACKAGE
#                                       with no `entry`, a digest that is not
#                                       32 bytes (§10.3)
#   OPTIMIZED_UDF_ROW_NULL_MODE         a ROW that is not MANUAL (§10.4, §10.7)
#   OPTIMIZED_UDF_STEP_NOT_VOLATILE     a STEP that is not VOLATILE (§10.7)
#   OPTIMIZED_UDF_READ_SET_KIND         a read set on a kind other than ROW
#                                       and MAP_BATCHES_FRAME (§10.4)
#   OPTIMIZED_UDF_READ_SET_INVALID      an empty, repeated or unsorted name
#                                       (§10.4)
#   OPTIMIZED_UDF_READ_SET_ARG_MISMATCH a set read set whose names are not
#                                       `arg_types`' names, in order (§10.4)
#   PLAN_WIRE_MALFORMED                 an enum at UNSPECIFIED or outside its
#                                       values, and SKIP_NULL_FAST_PATH, which
#                                       the design refuses in a `UdfRef`
#                                       without naming a token (§10.7)
#
# The checks that need a plan node (the arm a `UdfRef` is called from, its
# arguments, its input columns) are `plan_wire_udf_check.mojo`.
#
# ★ PRESENCE SURVIVES BOTH WAYS. `read_set` unset decodes to `None` and set
# with no names to `Some([])`, and the encoder writes a set `read_set` even
# when it has no names: the generated encoder emits every set message field
# as its tag and a length, so the two values never share bytes. A test holds
# both directions (`test_plan_wire_udf_ref.mojo`).
#
# The tokens are named by the design and apply in both contexts: the arms are
# admitted in RAW too (§10.4), and an entry that is wrong is wrong in either.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field
from komira_proto_codec import decode_proto, encode_proto
from komira_plan_proto.plan import (
    CodeDigest as WireCodeDigest,
    CodeForm,
    UdfCode as WireUdfCode,
    UdfKind,
    UdfNullMode,
    UdfReadSet,
    UdfRef as WireUdfRef,
    UdfResources as WireUdfResources,
    UdfStability,
    WireField,
)
from komira_plan_proto.plan_vocabulary import DTypeCode
from komira_plan_expr.udf_data import (
    UDF_NULL_MANUAL,
    UDF_NULL_PROPAGATE,
    UDF_NULL_SKIP_NULL_FAST_PATH,
    UDF_STABILITY_IMMUTABLE,
    UDF_STABILITY_STABLE,
    UDF_STABILITY_VOLATILE,
)
from komira_plan_expr.udf_type import UdfType
from komira_plan_ir.udf_ref import (
    CodeDigest,
    UdfCode,
    UdfRef,
    UdfResources,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_ROW,
    UDF_REF_KIND_STEP,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    CODE_FORM_PACKAGE,
    CODE_FORM_VALUE,
    udf_ref_kind_name,
)

from .plan_wire_admit import PLAN_WIRE_MAX_BYTES, PLAN_WIRE_TOO_LARGE, _walk
from .plan_wire_codec import (
    PLAN_WIRE_MALFORMED,
    PLAN_WIRE_FIELD_CHILDREN_BOTH,
    _arrow_type_from_wire,
    _dtype_from_wire,
    _dtype_to_wire,
)


comptime OPTIMIZED_UDF_RETURN_TYPE_MISSING: String = "OPTIMIZED_UDF_RETURN_TYPE_MISSING"
comptime OPTIMIZED_UDF_RUNTIME_MALFORMED: String = "OPTIMIZED_UDF_RUNTIME_MALFORMED"
comptime OPTIMIZED_UDF_ROW_NULL_MODE: String = "OPTIMIZED_UDF_ROW_NULL_MODE"
comptime OPTIMIZED_UDF_STEP_NOT_VOLATILE: String = "OPTIMIZED_UDF_STEP_NOT_VOLATILE"
comptime OPTIMIZED_UDF_READ_SET_KIND: String = "OPTIMIZED_UDF_READ_SET_KIND"
comptime OPTIMIZED_UDF_READ_SET_INVALID: String = "OPTIMIZED_UDF_READ_SET_INVALID"
comptime OPTIMIZED_UDF_READ_SET_ARG_MISMATCH: String = "OPTIMIZED_UDF_READ_SET_ARG_MISMATCH"

comptime _SHA256_BYTES: Int = 32


# =============================================================================
# UdfType <-> WireField: the recursive half of `WireField` (§10.3)
# =============================================================================


def _udf_type_to_wire(t: UdfType) raises -> WireField:
    """`t` with its children written recursively into `children`, and the
    flat child lists (13-15) left empty, as §10.3 requires of a field that
    sets `children`."""
    var kids = List[WireField]()
    for i in range(len(t.children)):
        kids.append(_udf_type_to_wire(t.children[i]))
    var union_ids = List[Int64]()
    for i in range(len(t.union_type_ids)):
        union_ids.append(Int64(t.union_type_ids[i]))
    return WireField(
        t.name.copy(),
        UInt32(t.arrow_type.type_id),
        _dtype_to_wire(t.dtype),
        t.nullable,
        Int64(t.decimal_precision),
        Int64(t.decimal_scale),
        t.tz.copy(),
        UInt32(t.dict_index_type.type_id),
        union_ids^,
        t.flags,
        t.metadata_keys.copy(),
        t.metadata_values.copy(),
        List[String](),
        List[UInt32](),
        List[Bool](),
        kids^,
    )


def _udf_type_from_wire(w: WireField, where: String) raises -> UdfType:
    """A UDF type, to any depth. A field may carry its children either as
    `children` or, one level deep, as the flat lists 13-15; one that sets both
    is refused (`PLAN_WIRE_FIELD_CHILDREN_BOTH`). Flat children decode as
    children with no children of their own."""
    var at = where + " '" + String(w.name) + "'"
    var flat = (
        len(w.child_names) > 0
        or len(w.child_type_ids) > 0
        or len(w.child_nullables) > 0
    )
    if flat and len(w.children) > 0:
        raise Error(
            PLAN_WIRE_FIELD_CHILDREN_BOTH + ": " + at + " sets `children`"
            + " and the flat child lists (child_names, child_type_ids,"
            + " child_nullables) together; a field states its children one"
            + " way, so which list is the type is undefined"
        )
    if len(w.child_names) != len(w.child_type_ids) or len(w.child_names) != len(
        w.child_nullables
    ):
        raise Error(
            PLAN_WIRE_MALFORMED + ": " + at + ": the three child lists differ"
            + " in length"
        )
    if len(w.metadata_keys) != len(w.metadata_values):
        raise Error(
            PLAN_WIRE_MALFORMED + ": " + at + ": metadata keys/values differ"
            + " in length"
        )
    var kids = List[UdfType]()
    for i in range(len(w.children)):
        kids.append(_udf_type_from_wire(w.children[i], where))
    for i in range(len(w.child_names)):
        var ct = _arrow_type_from_wire(
            w.child_type_ids[i], at + ".child_type_ids[" + String(i) + "]"
        )
        # A flat child carries a type id and nothing else, so its DType is the
        # one `Field`'s arrow constructor derives, as `field_to_udf_type`
        # gives a flat child of an engine `Field`.
        kids.append(
            UdfType(
                String(w.child_names[i]), ct, Field(String(""), ct, True).dtype,
                w.child_nullables[i],
            )
        )
    var t = UdfType(
        String(w.name),
        _arrow_type_from_wire(w.arrow_type_id, at + ".arrow_type_id"),
        _dtype_from_wire(w.dtype_code),
        w.nullable,
        kids^,
    )
    t.decimal_precision = Int(w.decimal_precision)
    t.decimal_scale = Int(w.decimal_scale)
    t.tz = String(w.tz)
    t.dict_index_type = _arrow_type_from_wire(
        w.dict_index_type_id, at + ".dict_index_type_id"
    )
    var union_ids = List[Int]()
    for i in range(len(w.union_type_ids)):
        union_ids.append(Int(w.union_type_ids[i]))
    t.union_type_ids = union_ids^
    t.flags = w.flags
    t.metadata_keys = w.metadata_keys.copy()
    t.metadata_values = w.metadata_values.copy()
    return t^


# =============================================================================
# The enums: engine value + 1 on the wire, 0 refused
# =============================================================================


def _enum_from_wire(n: Int, count: Int, what: String) raises -> UInt8:
    """Wire `n` of an enum with `count` values after UNSPECIFIED, as the
    engine value `n - 1`. 0 and anything past the last value are refused:
    proto3 keeps an unknown enum number intact, and guessing one would
    change what the function is."""
    if n <= 0 or n > count:
        raise Error(
            PLAN_WIRE_MALFORMED + ": " + what + " is " + String(n) + ", which"
            + (" is UNSPECIFIED" if n == 0 else " is not one of its values")
        )
    return UInt8(n - 1)


# =============================================================================
# UdfRef <-> WireUdfRef
# =============================================================================


def _udf_ref_to_wire(u: UdfRef) raises -> WireUdfRef:
    var args = List[WireField]()
    for i in range(len(u.arg_types)):
        args.append(_udf_type_to_wire(u.arg_types[i]))
    var digests = List[WireCodeDigest]()
    for i in range(len(u.code.code)):
        digests.append(
            WireCodeDigest(u.code.code[i].role.copy(), u.code.code[i].sha256.copy())
        )
    var code = WireUdfCode(
        u.code.runtime.copy(),
        CodeForm(Int(u.code.form) + 1),
        u.code.entry.copy(),
        digests^,
        u.code.descriptor_version,
        u.code.descriptor.copy(),
    )
    var ret = Optional[WireField](None)
    if u.return_type:
        ret = Optional(_udf_type_to_wire(u.return_type.value()))
    var state = Optional[WireField](None)
    if u.state_type:
        state = Optional(_udf_type_to_wire(u.state_type.value()))
    # ★ A SET READ SET IS WRITTEN EVEN WHEN IT HAS NO NAMES. `Some([])` reads no
    # column and `None` reads every column (§10.2); writing nothing for the
    # empty one would give the two the same bytes, and so the same identity.
    var rs = Optional[UdfReadSet](None)
    if u.read_set:
        rs = Optional(UdfReadSet(u.read_set.value().copy()))
    return WireUdfRef(
        UdfKind(Int(u.kind) + 1),
        Optional(code^),
        args^,
        u.data_blobs.copy(),
        ret^,
        UdfStability(Int(u.stability) + 1),
        UdfNullMode(Int(u.null_mode) + 1),
        Optional(
            WireUdfResources(
                u.resources.worker_mem_bytes,
                u.resources.max_workers,
                u.resources.max_batch_rows,
                u.resources.max_runtime_ms,
                u.resources.max_concurrent_calls,
            )
        ),
        state^,
        u.preserves_event_time,
        rs^,
    )


def _udf_ref_from_wire(w: WireUdfRef, index: Int) raises -> UdfRef:
    """Entry `index` of a `UdfRef` list, decoded and checked on its own
    (`_check_udf_ref`)."""
    var at = "UdfRef " + String(index)
    var kind = _enum_from_wire(w.kind.number(), 6, at + " kind")
    if not w.code:
        raise Error(
            OPTIMIZED_UDF_RUNTIME_MALFORMED + ": " + at + " has no `code`, so"
            + " it names no runtime and no entry"
        )
    ref wc = w.code.value()
    if wc.form.number() == 0:
        raise Error(
            OPTIMIZED_UDF_RUNTIME_MALFORMED + ": " + at + " code.form is"
            + " CODE_FORM_UNSPECIFIED; the form is the one code fact the"
            + " format reads, and it must be set"
        )
    var form = _enum_from_wire(wc.form.number(), 3, at + " code.form")
    var digests = List[CodeDigest]()
    for i in range(len(wc.code)):
        digests.append(
            CodeDigest(String(wc.code[i].role), wc.code[i].sha256.copy())
        )
    var code = UdfCode(
        String(wc.runtime), form, String(wc.entry), digests^,
        wc.descriptor_version, wc.descriptor.copy(),
    )
    var args = List[UdfType]()
    for i in range(len(w.arg_types)):
        args.append(
            _udf_type_from_wire(w.arg_types[i], at + " arg_types[" + String(i) + "]")
        )
    var ret = Optional[UdfType](None)
    if w.return_type:
        ret = Optional(_udf_type_from_wire(w.return_type.value(), at + " return_type"))
    var state = Optional[UdfType](None)
    if w.state_type:
        state = Optional(_udf_type_from_wire(w.state_type.value(), at + " state_type"))
    var rs = Optional[List[String]](None)
    if w.read_set:
        rs = Optional(w.read_set.value().columns.copy())
    var res = UdfResources()
    if w.resources:
        ref r = w.resources.value()
        res = UdfResources(
            r.worker_mem_bytes, r.max_workers, r.max_batch_rows,
            r.max_runtime_ms, r.max_concurrent_calls,
        )
    var u = UdfRef(
        kind,
        code^,
        args^,
        ret^,
        _enum_from_wire(w.stability.number(), 3, at + " stability"),
        _enum_from_wire(w.null_mode.number(), 3, at + " null_mode"),
        rs^,
        state^,
        w.data_blobs.copy(),
        res,
        w.preserves_event_time,
    )
    _check_udf_ref(u, index)
    return u^


# =============================================================================
# The checks on one entry
# =============================================================================


def _runtime_part_ok(p: String) -> Bool:
    """`[a-z0-9][a-z0-9._-]{0,62}` (udf_runtime_interface.md §3.1)."""
    var b = p.as_bytes()
    if len(b) == 0 or len(b) > 63:
        return False
    for i in range(len(b)):
        var c = b[i]
        var alnum = (c >= 0x61 and c <= 0x7A) or (c >= 0x30 and c <= 0x39)
        if i == 0:
            if not alnum:
                return False
        elif not (alnum or c == 0x2E or c == 0x5F or c == 0x2D):
            return False
    return True


def udf_runtime_id_is_valid(runtime: String) -> Bool:
    """True when `runtime` is `<namespace>/<name>`, each part matching
    `[a-z0-9][a-z0-9._-]{0,62}` (udf_runtime_interface.md §3.1). Total."""
    var parts = runtime.split("/")
    if len(parts) != 2:
        return False
    return _runtime_part_ok(String(parts[0])) and _runtime_part_ok(
        String(parts[1])
    )


def _check_udf_ref(u: UdfRef, index: Int) raises:
    """The refusals one `UdfRef` earns on its own (this module's header)."""
    var at = "UdfRef " + String(index) + " (" + udf_ref_kind_name(u.kind) + ")"
    if not udf_runtime_id_is_valid(u.code.runtime):
        raise Error(
            OPTIMIZED_UDF_RUNTIME_MALFORMED + ": " + at + " code.runtime '"
            + u.code.runtime + "' is not `<namespace>/<name>` with each part"
            + " matching [a-z0-9][a-z0-9._-]{0,62}"
        )
    if u.code.form == CODE_FORM_PACKAGE and u.code.entry.byte_length() == 0:
        raise Error(
            OPTIMIZED_UDF_RUNTIME_MALFORMED + ": " + at + " is a PACKAGE"
            + " reference with an empty `entry`, so it names no function in"
            + " the package"
        )
    for i in range(len(u.code.code)):
        if len(u.code.code[i].sha256) != _SHA256_BYTES:
            raise Error(
                OPTIMIZED_UDF_RUNTIME_MALFORMED + ": " + at + " code.code["
                + String(i) + "] ('" + u.code.code[i].role + "') has a sha256"
                + " of " + String(len(u.code.code[i].sha256)) + " bytes, not 32"
            )
    if not u.return_type:
        raise Error(
            OPTIMIZED_UDF_RETURN_TYPE_MISSING + ": " + at + " has no"
            + " `return_type`. Every return type is explicit in the plan"
            + " (§10.5): node output schemas, predicate placement and typed"
            + " kernels are decided from it before the plan runs"
        )
    if u.null_mode == UDF_NULL_SKIP_NULL_FAST_PATH:
        raise Error(
            PLAN_WIRE_MALFORMED + ": " + at + " null_mode is"
            + " SKIP_NULL_FAST_PATH, a Mojo-registry optimization a `UdfRef`"
            + " may not use (§10.7)"
        )
    if u.kind == UDF_REF_KIND_ROW and u.null_mode != UDF_NULL_MANUAL:
        raise Error(
            OPTIMIZED_UDF_ROW_NULL_MODE + ": " + at + " is not MANUAL. Under"
            + " PROPAGATE a null in a field read on only some branches would"
            + " drop a row the function would have computed (§10.2)"
        )
    if u.kind == UDF_REF_KIND_STEP and u.stability != UDF_STABILITY_VOLATILE:
        raise Error(
            OPTIMIZED_UDF_STEP_NOT_VOLATILE + ": " + at + " is not VOLATILE;"
            + " a step runs exactly once per run, and every call counts (§10.7)"
        )
    if not u.read_set:
        return
    if u.kind != UDF_REF_KIND_ROW and u.kind != UDF_REF_KIND_MAP_BATCHES_FRAME:
        raise Error(
            OPTIMIZED_UDF_READ_SET_KIND + ": " + at + " sets `read_set`; only"
            + " a ROW or a MAP_BATCHES_FRAME declares the columns it reads, and"
            + " every other kind reads exactly its arguments (§10.2)"
        )
    ref names = u.read_set.value()
    for i in range(len(names)):
        if names[i].byte_length() == 0:
            raise Error(
                OPTIMIZED_UDF_READ_SET_INVALID + ": " + at + " read_set["
                + String(i) + "] is empty"
            )
        # Strictly ascending, which also refuses a repeated name: the two
        # rules of §10.4 are one comparison.
        if i > 0 and not (names[i - 1] < names[i]):
            raise Error(
                OPTIMIZED_UDF_READ_SET_INVALID + ": " + at + " read_set is not"
                + " strictly ascending by UTF-8 bytes: '" + names[i - 1]
                + "' then '" + names[i] + "' (a repeated name is not"
                + " ascending)"
            )
    if len(u.arg_types) != len(names):
        raise Error(
            OPTIMIZED_UDF_READ_SET_ARG_MISMATCH + ": " + at + " read_set has "
            + String(len(names)) + " names and arg_types "
            + String(len(u.arg_types)) + " entries; a set read set lists the"
            + " columns received, one `arg_types` entry each"
        )
    for i in range(len(names)):
        if u.arg_types[i].name != names[i]:
            raise Error(
                OPTIMIZED_UDF_READ_SET_ARG_MISMATCH + ": " + at + " arg_types["
                + String(i) + "] is named '" + u.arg_types[i].name
                + "' where read_set names '" + names[i] + "'"
            )


# =============================================================================
# The public surface: one entry as bytes
# =============================================================================


def udf_ref_to_bytes(u: UdfRef) raises -> List[UInt8]:
    """The `UdfRef` message of `u`. A set `read_set` is written even when it
    has no names, so `None` and `Some([])` encode differently.

    ⚠ NOT THE CANONICAL FORM OF optimized_plan.md §7.1: the generated encoder
    writes scalars at their defaults. The canonical encoder, which also omits
    them, is a later stage; it keeps the presence rule this one has."""
    return encode_proto(_udf_ref_to_wire(u))


def udf_ref_from_bytes(var bytes: List[UInt8]) raises -> UdfRef:
    """Decode and check one `UdfRef` message (the refusals in this module's
    header). Size and nesting are bounded before the bytes are parsed, as for
    a plan: `WireField.children` nests."""
    if len(bytes) > PLAN_WIRE_MAX_BYTES:
        raise Error(
            PLAN_WIRE_TOO_LARGE + ": a UdfRef of " + String(len(bytes))
            + " bytes exceeds the " + String(PLAN_WIRE_MAX_BYTES) + "-byte cap"
        )
    var depth = 0
    _walk(bytes, depth)
    var w = decode_proto[WireUdfRef](bytes^)
    return _udf_ref_from_wire(w, 0)
