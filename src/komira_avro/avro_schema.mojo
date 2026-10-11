# =============================================================================
# avro_schema.mojo — Avro schema JSON parser + Parsing Canonical Form +
#                    CRC-64-AVRO ("Rabin") fingerprint + Avro->Arrow lattice.
# =============================================================================
#
# This module is the FOUNDATION for the rest of the Avro package. It:
#   1. Parses an Avro schema JSON string into an AvroSchema tree
#      (`AvroSchema.parse`).
#   2. Produces the Avro Parsing Canonical Form (PCF) per the spec
#      <https://avro.apache.org/docs/1.11.1/specification/#parsing-canonical-form-for-schemas>
#      (`AvroSchema.parsing_canonical_form`).
#   3. Computes the CRC-64-AVRO ("Rabin") 64-bit fingerprint of the PCF
#      (`AvroSchema.fingerprint`).
#   4. Maps Avro primitive + logical types to the core packages ArrowType lattice
#      (`avro_type_to_arrow`).
#   5. REJECTS recursive (cyclic) schemas on detect, via a name visit-stack
#      (as arrow-rs and DuckDB do; RECURSIVE_SCHEMA_NOT_SUPPORTED).
#      Recursive schemas are rejected
#      FOREVER in this design.
#
# Encapsulation: the public API exposes only typed values (AvroSchema,
# String, UInt64, ArrowType, raised errors). No UnsafePointer crosses any
# module boundary. Internal storage uses owned List/String only.
# =============================================================================

from komira_arrow.arrow_types import ArrowType

from .avro_names import (
    check_avro_fullname,
    check_avro_name,
    check_avro_namespace,
    latin1_default_bytes,
)
from .json_number import parse_json_int, scan_json_number
from .json_string import decode_json_string


# =============================================================================
# Avro type tags (internal discriminant for the parsed schema tree).
# =============================================================================
#
# Mirrors the Avro 1.11.1 type set the PCF + lattice need to distinguish.
# Logical types ride on top of a primitive `kind` + a `logical_type` string
# (matching the Avro JSON `{"type": ..., "logicalType": ...}` shape).

# =============================================================================
# Untrusted-input ceilings.
# =============================================================================
#
# The `avro.schema` JSON lives in the OCF header, i.e. it is supplied by
# whoever wrote the file. These three constants bound the quantities that
# schema text can name and that the decoder would otherwise hand to a slice, a
# recursion, or an allocation. All three are sanity ceilings orders of
# magnitude above anything real — their job is to make a hostile value
# unrepresentable, not to impose a product limit.

# Max `size` of an Avro `fixed`. It becomes a slice length on the block
# payload. The spec's own fixed logical types are 12 (`duration`) and 16
# (`uuid`) bytes; 64 MiB is absurdly generous.
comptime MAX_FIXED_SIZE: Int = 1 << 26

# Max structural nesting depth of the schema JSON *and* of the schema tree
# built from it. Both are unbounded mutual recursion on native stack frames;
# a header carrying a few hundred thousand `[` exhausts the thread stack
# (a SIGSEGV with the recursive frame repeated to the stack dump's
# 256-entry limit). Worker threads have smaller stacks than main, so
# the real limit is lower than what a main-thread experiment suggests. The
# deepest schema anyone writes by hand is single-digit; 256 is not a
# constraint on legitimate files.
comptime MAX_SCHEMA_DEPTH: Int = 256

comptime AVRO_KIND_NULL: Int = 0
comptime AVRO_KIND_BOOLEAN: Int = 1
comptime AVRO_KIND_INT: Int = 2
comptime AVRO_KIND_LONG: Int = 3
comptime AVRO_KIND_FLOAT: Int = 4
comptime AVRO_KIND_DOUBLE: Int = 5
comptime AVRO_KIND_BYTES: Int = 6
comptime AVRO_KIND_STRING: Int = 7
comptime AVRO_KIND_RECORD: Int = 8
comptime AVRO_KIND_ENUM: Int = 9
comptime AVRO_KIND_ARRAY: Int = 10
comptime AVRO_KIND_MAP: Int = 11
comptime AVRO_KIND_UNION: Int = 12
comptime AVRO_KIND_FIXED: Int = 13


@always_inline
def _write_kind_name[W: Writer](mut writer: W, kind: Int):
    """WRITE what `_kind_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a shared
    library can bind such a pair CROSSED, returning the wrong string or
    crashing its host."""
    if kind == AVRO_KIND_NULL:
        writer.write(String("null"))
        return
    elif kind == AVRO_KIND_BOOLEAN:
        writer.write(String("boolean"))
        return
    elif kind == AVRO_KIND_INT:
        writer.write(String("int"))
        return
    elif kind == AVRO_KIND_LONG:
        writer.write(String("long"))
        return
    elif kind == AVRO_KIND_FLOAT:
        writer.write(String("float"))
        return
    elif kind == AVRO_KIND_DOUBLE:
        writer.write(String("double"))
        return
    elif kind == AVRO_KIND_BYTES:
        writer.write(String("bytes"))
        return
    elif kind == AVRO_KIND_STRING:
        writer.write(String("string"))
        return
    elif kind == AVRO_KIND_RECORD:
        writer.write(String("record"))
        return
    elif kind == AVRO_KIND_ENUM:
        writer.write(String("enum"))
        return
    elif kind == AVRO_KIND_ARRAY:
        writer.write(String("array"))
        return
    elif kind == AVRO_KIND_MAP:
        writer.write(String("map"))
        return
    elif kind == AVRO_KIND_UNION:
        writer.write(String("union"))
        return
    elif kind == AVRO_KIND_FIXED:
        writer.write(String("fixed"))
        return
    writer.write(String("unknown"))
    return


@always_inline
def _kind_name(kind: Int) -> String:
    """Avro spec primitive/complex type-name for a kind tag.

    This is the canonical-form `"type"` string for primitives and named
    complex types.
    """
    var out = String()
    _write_kind_name(out, kind)
    return out^


@always_inline
def _kind_from_name(name: String) -> Int:
    """Map an Avro type-name string to its kind tag, or -1 if unknown."""
    if name == "null":
        return AVRO_KIND_NULL
    elif name == "boolean":
        return AVRO_KIND_BOOLEAN
    elif name == "int":
        return AVRO_KIND_INT
    elif name == "long":
        return AVRO_KIND_LONG
    elif name == "float":
        return AVRO_KIND_FLOAT
    elif name == "double":
        return AVRO_KIND_DOUBLE
    elif name == "bytes":
        return AVRO_KIND_BYTES
    elif name == "string":
        return AVRO_KIND_STRING
    elif name == "record":
        return AVRO_KIND_RECORD
    elif name == "enum":
        return AVRO_KIND_ENUM
    elif name == "array":
        return AVRO_KIND_ARRAY
    elif name == "map":
        return AVRO_KIND_MAP
    elif name == "fixed":
        return AVRO_KIND_FIXED
    elif name == "union":
        # Object-form union carrier (custom-attribute slot for arrow.union-*).
        # A union is normally a bare JSON array; the object form exists so the
        # union can carry a `logicalType` (e.g. "arrow.union-sparse").
        return AVRO_KIND_UNION
    return -1


# =============================================================================
# AvroSchemaError — typed parse / validate errors.
# =============================================================================

comptime AVRO_ERR_MALFORMED_JSON: Int = 0
comptime AVRO_ERR_RECURSIVE_SCHEMA: Int = 1
comptime AVRO_ERR_UNKNOWN_TYPE: Int = 2
comptime AVRO_ERR_DECIMAL_PRECISION_TOO_LARGE: Int = 3
comptime AVRO_ERR_UNKNOWN_LOGICAL_TYPE: Int = 4


# =============================================================================
# A flat-arena AvroSchema node.
# =============================================================================
#
# The parsed schema is stored as a flat List[AvroNode] arena; child links are
# integer indices into the arena (NOT pointers). No stale-pointer hazard (no
# heap-owning fields beyond owned String/List which the arena owns directly)
# and avoids any recursive struct definition (Mojo cannot express a struct
# that contains a List[Self]).
#
# Index 0 is always the root node.

# =============================================================================
# AvroDefault — a captured field default value.
# =============================================================================
#
# Avro field `default` values are arbitrary JSON. We capture the
# *kinds* of defaults the resolution-rewriter can synthesize: null, bool,
# integer (int/long), double (float/double), string, and bytes (a JSON string
# read as Latin-1 bytes per the Avro spec). The `present` flag distinguishes
# "field has a declared default" from "no default". Defaults for complex types
# (records / arrays / maps) are captured as `present=False`
# (a missing complex-typed reader field with a complex default raises
# NO_DEFAULT_FOR_MISSING_FIELD).

comptime AVRO_DEFAULT_NONE: Int = 0     # no default declared
comptime AVRO_DEFAULT_NULL: Int = 1     # default is JSON null
comptime AVRO_DEFAULT_BOOL: Int = 2
comptime AVRO_DEFAULT_INT: Int = 3      # int or long
comptime AVRO_DEFAULT_DOUBLE: Int = 4   # float or double
comptime AVRO_DEFAULT_STRING: Int = 5
comptime AVRO_DEFAULT_BYTES: Int = 6    # JSON string read as Latin-1 bytes


@fieldwise_init
struct AvroDefault(Copyable, Movable):
    var kind: Int
    var bool_val: Bool
    var int_val: Int64
    var double_val: Float64
    var str_val: String
    # AVRO_DEFAULT_BYTES only: the default's code points read as byte values.
    var bytes_val: List[UInt8]

    @staticmethod
    def none() -> AvroDefault:
        return AvroDefault(
            kind=AVRO_DEFAULT_NONE,
            bool_val=False,
            int_val=Int64(0),
            double_val=Float64(0.0),
            str_val=String(""),
            bytes_val=List[UInt8](),
        )

    @always_inline
    def present(self) -> Bool:
        return self.kind != AVRO_DEFAULT_NONE


@fieldwise_init
struct AvroNode(Copyable, Movable):
    var kind: Int
    # Fully-qualified name for named types (record / enum / fixed). Empty for
    # anonymous / primitive types.
    var name: String
    # logicalType string ("decimal", "date", "timestamp-micros", "arrow.uint64",
    # ...). Empty if no logical type.
    var logical_type: String
    # For record: child field NODE indices, in declared (wire) order.
    # For union: branch NODE indices.
    # For array: single element NODE index (children[0]).
    # For map: single value NODE index (children[0]).
    var children: List[Int]
    # For record: field NAMES parallel to `children`.
    var field_names: List[String]
    # For enum: ordered symbol list.
    var symbols: List[String]
    # For fixed: byte size.
    var size: Int
    # For decimal logical type: precision + scale.
    var precision: Int
    var scale: Int
    # Type-level aliases for named types (record / enum / fixed). Parallel to
    # `name` — alternate fullnames a reader field may match against. Empty for
    # primitives / anonymous types. (Schema resolution.)
    var aliases: List[String]
    # For record: per-field declared `default` value, parallel to `children` /
    # `field_names`. Each entry is AvroDefault.none() if the field has no
    # default. (Schema resolution — defaults rule.)
    var field_defaults: List[AvroDefault]
    # For record: per-field alias lists, parallel to `children` / `field_names`.
    # Each entry is the field's declared `aliases` (empty if none). The reader
    # field matches a writer field by name OR by any alias.
    var field_aliases: List[List[String]]
    # For enum: the declared `default` symbol (empty if none). Used when a
    # writer symbol is absent from the reader's symbol set.
    var enum_default: String


# =============================================================================
# AvroSchema — parsed schema tree (flat arena) + canonical form + fingerprint.
# =============================================================================

@fieldwise_init
struct AvroSchema(Movable):
    """Parsed Avro schema, post-parse, ready for canonicalization +
    fingerprinting + Arrow-type mapping.

    Internal storage is a flat arena of AvroNode; child links are arena
    indices. Because `_build_node` appends children before their parent, the
    root is the LAST-appended node — `root_idx` records it. No UnsafePointer.
    """

    var nodes: List[AvroNode]
    var root_idx: Int

    @staticmethod
    def parse(json: String) raises -> AvroSchema:
        """Parse an Avro schema JSON string into an AvroSchema.

        Rejects recursive schemas via a named-type visit-stack
        (RECURSIVE_SCHEMA_NOT_SUPPORTED). Raises on malformed JSON.
        """
        var parser = _JsonParser(json)
        var value = parser.parse_value()
        parser.skip_ws()
        if not parser.at_end():
            raise parser._malformed("trailing data after schema")

        var nodes = List[AvroNode]()
        var named_in_scope = List[String]()  # visit-stack for recursion detect
        var defined_names = List[String]()    # all named types seen (for named-ref)
        var root_idx = _build_node(value^, nodes, named_in_scope, defined_names)
        return AvroSchema(nodes^, root_idx)

    def root(self) -> Int:
        return self.root_idx

    def node(self, idx: Int) -> AvroNode:
        return self.nodes[idx].copy()

    def parsing_canonical_form(self) -> String:
        """Produce the Avro Parsing Canonical Form (PCF) of this schema.

        Per the Avro spec, PCF applies these transforms:
          [PRIMITIVES] convert primitive shorthands to their full names.
          [FULLNAMES]  replace short names with fullnames (we use the parsed
                       `name` which is already the fullname).
          [STRIP]      keep only attributes relevant to parsing:
                       type, name, fields, symbols, items, values, size.
          [ORDER]      order record fields as: name, type, fields, symbols,
                       items, values, size (object member order fixed).
          [STRINGS]    JSON-escape strings. The only strings emitted are
                       names and symbols, which `parse` has checked against
                       [A-Za-z_][A-Za-z0-9_]*, so none needs escaping.
          [INTEGERS]   eliminate quotes around and leading zeros in size.
          [WHITESPACE] eliminate all whitespace outside strings.
        """
        var out = String("")
        self._emit_canonical(self.root_idx, out)
        return out^

    def _emit_canonical(self, idx: Int, mut out: String):
        var n = self.nodes[idx].copy()
        var kind = n.kind

        if kind == AVRO_KIND_UNION:
            out += "["
            for i in range(len(n.children)):
                if i > 0:
                    out += ","
                self._emit_canonical(n.children[i], out)
            out += "]"
            return

        if (
            kind == AVRO_KIND_NULL
            or kind == AVRO_KIND_BOOLEAN
            or kind == AVRO_KIND_INT
            or kind == AVRO_KIND_LONG
            or kind == AVRO_KIND_FLOAT
            or kind == AVRO_KIND_DOUBLE
            or kind == AVRO_KIND_BYTES
            or kind == AVRO_KIND_STRING
        ):
            # PCF reduces a primitive to its bare type-name string. Logical
            # types are STRIPPED from PCF (the fingerprint identifies the
            # parsing shape, not logical annotations).
            out += '"'
            out += _kind_name(kind)
            out += '"'
            return

        if kind == AVRO_KIND_RECORD:
            out += '{"name":"'
            out += n.name
            out += '","type":"record","fields":['
            for i in range(len(n.children)):
                if i > 0:
                    out += ","
                out += '{"name":"'
                out += n.field_names[i]
                out += '","type":'
                self._emit_canonical(n.children[i], out)
                out += "}"
            out += "]}"
            return

        if kind == AVRO_KIND_ENUM:
            out += '{"name":"'
            out += n.name
            out += '","type":"enum","symbols":['
            for i in range(len(n.symbols)):
                if i > 0:
                    out += ","
                out += '"'
                out += n.symbols[i]
                out += '"'
            out += "]}"
            return

        if kind == AVRO_KIND_FIXED:
            out += '{"name":"'
            out += n.name
            out += '","type":"fixed","size":'
            out += String(n.size)
            out += "}"
            return

        if kind == AVRO_KIND_ARRAY:
            out += '{"type":"array","items":'
            self._emit_canonical(n.children[0], out)
            out += "}"
            return

        if kind == AVRO_KIND_MAP:
            out += '{"type":"map","values":'
            self._emit_canonical(n.children[0], out)
            out += "}"
            return

    def fingerprint(self) -> UInt64:
        """CRC-64-AVRO ("Rabin") fingerprint of the parsing canonical form."""
        var pcf = self.parsing_canonical_form()
        return crc_64_avro(pcf.as_bytes())


# =============================================================================
# Recursive-schema reject + node construction.
# =============================================================================
#
# Returns the arena index of the node just constructed.

def _build_node(
    var value: _JsonValue,
    mut nodes: List[AvroNode],
    mut named_in_scope: List[String],
    mut defined_names: List[String],
) raises -> Int:
    # ---- A bare string: a primitive name OR a reference to a named type. ----
    if value.tag == _JSON_STRING:
        var name = value.str_val
        var k = _kind_from_name(name)
        if k >= 0 and k != AVRO_KIND_RECORD and k != AVRO_KIND_ENUM and k != AVRO_KIND_FIXED:
            # Bare primitive.
            var node = _empty_node(k)
            nodes.append(node^)
            return len(nodes) - 1
        # Otherwise it's a NAME — either a forward primitive-spelled complex,
        # or a reference to a previously-defined named type. A reference to a
        # name currently on the visit-stack is a CYCLE -> reject.
        if _contains(named_in_scope, name):
            raise Error(
                String("AvroSchemaError.RECURSIVE_SCHEMA_NOT_SUPPORTED: name=")
                + name
            )
        if _contains(defined_names, name):
            # A reference to an already-fully-defined named type. For PCF +
            # fingerprint purposes we materialize it as a record
            # placeholder carrying the name (the wire decoder resolves the
            # full definition; recursion is already excluded by the cycle
            # check above).
            var node = _empty_node(AVRO_KIND_RECORD)
            node.name = name
            nodes.append(node^)
            return len(nodes) - 1
        raise Error(
            String("AvroSchemaError.UNKNOWN_TYPE: ") + name
        )

    # ---- An array: a union. ----
    if value.tag == _JSON_ARRAY:
        var node = _empty_node(AVRO_KIND_UNION)
        var n_branches = len(value.arr_val)
        # Build branch indices. We must reserve the union node slot AFTER the
        # branches so child indices are stable; build children first.
        var child_idxs = List[Int]()
        for i in range(n_branches):
            var branch = value.arr_val[i].copy()
            var ci = _build_node(branch^, nodes, named_in_scope, defined_names)
            child_idxs.append(ci)
        node.children = child_idxs^
        nodes.append(node^)
        return len(nodes) - 1

    # ---- An object: a complex type or a primitive with attributes. ----
    if value.tag == _JSON_OBJECT:
        var type_str = _obj_get_string(value, "type")
        if type_str.byte_length() == 0:
            raise Error("AvroSchemaError.MALFORMED_JSON: object missing 'type'")
        var k = _kind_from_name(type_str)

        # Logical type annotation (rides on a primitive / fixed / bytes type).
        var logical = _obj_get_string(value, "logicalType")

        if k == AVRO_KIND_RECORD:
            var name = _obj_get_string(value, "name")
            check_avro_fullname("record name", name)
            check_avro_namespace(
                "record namespace", _obj_get_string(value, "namespace")
            )
            # Push name on visit-stack BEFORE descending into fields.
            named_in_scope.append(name)
            defined_names.append(name)
            var fields_val = _obj_get(value, "fields")
            if fields_val.tag != _JSON_ARRAY:
                raise Error("AvroSchemaError.MALFORMED_JSON: record 'fields' not array")
            var child_idxs = List[Int]()
            var fnames = List[String]()
            var fdefaults = List[AvroDefault]()
            var faliases = List[List[String]]()
            for i in range(len(fields_val.arr_val)):
                var fobj = fields_val.arr_val[i].copy()
                if fobj.tag != _JSON_OBJECT:
                    raise Error("AvroSchemaError.MALFORMED_JSON: field not object")
                var fname = _obj_get_string(fobj, "name")
                check_avro_name("field name", fname)
                var ftype = _obj_get(fobj, "type")
                var ci = _build_node(ftype^, nodes, named_in_scope, defined_names)
                child_idxs.append(ci)
                fnames.append(fname)
                # Capture the field's `default` (if any) + `aliases`.
                fdefaults.append(_capture_default(fobj, fname, nodes, ci))
                faliases.append(_capture_aliases(fobj))
            # Pop the record name off the visit-stack on the way out.
            _ = named_in_scope.pop()
            var node = _empty_node(AVRO_KIND_RECORD)
            node.name = name
            node.children = child_idxs^
            node.field_names = fnames^
            node.field_defaults = fdefaults^
            node.field_aliases = faliases^
            node.logical_type = logical
            node.aliases = _capture_aliases(value)
            nodes.append(node^)
            return len(nodes) - 1

        if k == AVRO_KIND_ENUM:
            var name = _obj_get_string(value, "name")
            check_avro_fullname("enum name", name)
            check_avro_namespace(
                "enum namespace", _obj_get_string(value, "namespace")
            )
            defined_names.append(name)
            var syms_val = _obj_get(value, "symbols")
            var syms = List[String]()
            if syms_val.tag == _JSON_ARRAY:
                for i in range(len(syms_val.arr_val)):
                    # A non-string symbol carries an empty str_val, which the
                    # name check refuses.
                    check_avro_name("enum symbol", syms_val.arr_val[i].str_val)
                    syms.append(syms_val.arr_val[i].str_val)
            var node = _empty_node(AVRO_KIND_ENUM)
            node.name = name
            node.symbols = syms^
            node.aliases = _capture_aliases(value)
            node.enum_default = _obj_get_string(value, "default")
            nodes.append(node^)
            return len(nodes) - 1

        if k == AVRO_KIND_FIXED:
            var name = _obj_get_string(value, "name")
            check_avro_fullname("fixed name", name)
            check_avro_namespace(
                "fixed namespace", _obj_get_string(value, "namespace")
            )
            defined_names.append(name)
            var sz = _obj_get_int(value, "size")
            # UNTRUSTED INPUT. `size` comes from the
            # `avro.schema` JSON in the file header and flows unvalidated into
            # `read_fixed(sz)` / `read_fixed_span(sz)` as a SLICE LENGTH. The
            # reader guards are overflow-proof, but a `fixed` whose declared width exceeds
            # any possible block payload is still a malformed schema and is
            # worth naming HERE, where the file is opened, rather than as a
            # confusing per-record truncation error.
            #
            # MAX_FIXED_SIZE is a sanity ceiling, not a product limit: no Avro
            # `fixed` in practice is anywhere near 64 MiB (the spec's own
            # `duration` is 12 bytes, `uuid` 16, `decimal` <= 32).
            if sz < 0 or sz > MAX_FIXED_SIZE:
                raise Error(
                    String("AvroSchemaError.FIXED_SIZE_OUT_OF_RANGE: fixed '")
                    + name
                    + "' declares size "
                    + String(sz)
                    + "; the accepted range is 0.."
                    + String(MAX_FIXED_SIZE)
                )
            var node = _empty_node(AVRO_KIND_FIXED)
            node.name = name
            node.size = sz
            node.logical_type = logical
            node.precision = _obj_get_int(value, "precision")
            node.scale = _obj_get_int(value, "scale")
            node.aliases = _capture_aliases(value)
            nodes.append(node^)
            return len(nodes) - 1

        if k == AVRO_KIND_UNION:
            # Object-form union carrier (custom-attribute slot): the
            # branches live under "branches" (a JSON array), and the union node
            # can carry a `logicalType` (e.g. "arrow.union-sparse") that a bare
            # array-form union cannot. Mirrors the array-form union branch
            # above, plus the logical_type stamp.
            var branches_val = _obj_get(value, "branches")
            if branches_val.tag != _JSON_ARRAY:
                raise Error(
                    "AvroSchemaError.MALFORMED_JSON: object-form union"
                    " 'branches' not array"
                )
            var u_child_idxs = List[Int]()
            for i in range(len(branches_val.arr_val)):
                var branch = branches_val.arr_val[i].copy()
                var ci = _build_node(
                    branch^, nodes, named_in_scope, defined_names
                )
                u_child_idxs.append(ci)
            var u_node = _empty_node(AVRO_KIND_UNION)
            u_node.children = u_child_idxs^
            u_node.logical_type = logical
            nodes.append(u_node^)
            return len(nodes) - 1

        if k == AVRO_KIND_ARRAY:
            var items = _obj_get(value, "items")
            var ci = _build_node(items^, nodes, named_in_scope, defined_names)
            var node = _empty_node(AVRO_KIND_ARRAY)
            node.children.append(ci)
            nodes.append(node^)
            return len(nodes) - 1

        if k == AVRO_KIND_MAP:
            var vals = _obj_get(value, "values")
            var ci = _build_node(vals^, nodes, named_in_scope, defined_names)
            var node = _empty_node(AVRO_KIND_MAP)
            node.children.append(ci)
            nodes.append(node^)
            return len(nodes) - 1

        if k >= 0:
            # Primitive expressed in object form (e.g. decimal over bytes:
            # {"type":"bytes","logicalType":"decimal","precision":..,"scale":..}).
            var node = _empty_node(k)
            node.logical_type = logical
            node.precision = _obj_get_int(value, "precision")
            node.scale = _obj_get_int(value, "scale")
            nodes.append(node^)
            return len(nodes) - 1

        raise Error(String("AvroSchemaError.UNKNOWN_TYPE: ") + type_str)

    raise Error("AvroSchemaError.MALFORMED_JSON: unexpected JSON value")


@always_inline
def _empty_node(kind: Int) -> AvroNode:
    return AvroNode(
        kind=kind,
        name=String(""),
        logical_type=String(""),
        children=List[Int](),
        field_names=List[String](),
        symbols=List[String](),
        size=0,
        precision=0,
        scale=0,
        aliases=List[String](),
        field_defaults=List[AvroDefault](),
        field_aliases=List[List[String]](),
        enum_default=String(""),
    )


@always_inline
def _contains(list: List[String], target: String) -> Bool:
    for i in range(len(list)):
        if list[i] == target:
            return True
    return False


def _resolve_named_ref(nodes: List[AvroNode], idx: Int) -> Int:
    """A by-name reference is built as a record placeholder carrying the name;
    when that name belongs to a fixed or an enum, return that node instead."""
    if nodes[idx].kind == AVRO_KIND_RECORD and len(nodes[idx].children) == 0:
        for j in range(len(nodes)):
            if nodes[j].name == nodes[idx].name and (
                nodes[j].kind == AVRO_KIND_FIXED
                or nodes[j].kind == AVRO_KIND_ENUM
            ):
                return j
    return idx


def _default_matches(kind: Int, tag: Int) -> Bool:
    """Whether a JSON default of `tag` is a value of Avro type `kind`
    (Avro field default table: numbers for int/long/float/double, strings
    for bytes/string/enum/fixed, objects for record/map)."""
    if kind == AVRO_KIND_NULL:
        return tag == _JSON_NULL
    if kind == AVRO_KIND_BOOLEAN:
        return tag == _JSON_BOOL
    if kind == AVRO_KIND_INT or kind == AVRO_KIND_LONG:
        return tag == _JSON_INT
    if kind == AVRO_KIND_FLOAT or kind == AVRO_KIND_DOUBLE:
        return tag == _JSON_INT or tag == _JSON_FLOAT
    if (
        kind == AVRO_KIND_BYTES
        or kind == AVRO_KIND_STRING
        or kind == AVRO_KIND_ENUM
        or kind == AVRO_KIND_FIXED
    ):
        return tag == _JSON_STRING
    if kind == AVRO_KIND_RECORD or kind == AVRO_KIND_MAP:
        return tag == _JSON_OBJECT
    if kind == AVRO_KIND_ARRAY:
        return tag == _JSON_ARRAY
    return False


def _default_target(
    nodes: List[AvroNode], type_idx: Int, tag: Int, fname: String
) raises -> Int:
    """The arena index of the type a field default of JSON `tag` is read as.
    For a non-union field it is the field's type. For a union it is the first
    branch the default matches (Avro spec: "Default values for union fields
    correspond to the first schema that matches in the union"), or the first
    branch when none matches. By-name references to a fixed or an enum are
    resolved to that node. The empty union `[]` has no branch, so a default
    on it is refused (INVALID_DEFAULT naming field `fname`)."""
    if nodes[type_idx].kind != AVRO_KIND_UNION:
        return _resolve_named_ref(nodes, type_idx)
    var n = len(nodes[type_idx].children)
    if n == 0:
        raise Error(
            String("AvroSchemaError.INVALID_DEFAULT: field '") + fname
            + "' has a default, but its type is the empty union, which has"
            " no branch to read it as"
        )
    for i in range(n):
        var b = _resolve_named_ref(nodes, nodes[type_idx].children[i])
        if _default_matches(nodes[b].kind, tag):
            return b
    return _resolve_named_ref(nodes, nodes[type_idx].children[0])


def _capture_default(
    fobj: _JsonValue, fname: String, nodes: List[AvroNode], type_idx: Int
) raises -> AvroDefault:
    """Capture a record field's `default` value.

    Avro field defaults are arbitrary JSON. We capture the scalar kinds the
    resolution-rewriter can synthesize. A `default` member that is absent
    yields AvroDefault.none(). Complex defaults (object / array) are treated
    as `none()` (a complex default is not synthesized).

    When the default is read as `bytes` or `fixed` (the field's type, or the
    union branch `_default_target` picks), it must be a JSON string; its code
    points are read as Latin-1 byte values (AVRO_DEFAULT_BYTES), and a fixed
    default must be exactly the fixed size."""
    # Detect presence: scan the object keys for "default".
    var found = False
    for i in range(len(fobj.obj_keys)):
        if fobj.obj_keys[i] == "default":
            found = True
            break
    if not found:
        return AvroDefault.none()
    var v = _obj_get(fobj, "default")
    var target = _default_target(nodes, type_idx, v.tag, fname)
    var tkind = nodes[target].kind
    if tkind == AVRO_KIND_BYTES or tkind == AVRO_KIND_FIXED:
        if v.tag != _JSON_STRING:
            raise Error(
                String("AvroSchemaError.INVALID_DEFAULT: field '")
                + fname
                + "' default for "
                + avro_kind_name(tkind)
                + " is not a JSON string"
            )
        var b = latin1_default_bytes(fname, v.str_val)
        if tkind == AVRO_KIND_FIXED and len(b) != nodes[target].size:
            raise Error(
                String("AvroSchemaError.INVALID_DEFAULT: field '")
                + fname
                + "' default is "
                + String(len(b))
                + " bytes; fixed '"
                + nodes[target].name
                + "' has size "
                + String(nodes[target].size)
            )
        return AvroDefault(
            kind=AVRO_DEFAULT_BYTES, bool_val=False, int_val=Int64(0),
            double_val=Float64(0.0), str_val=String(""), bytes_val=b^,
        )
    if v.tag == _JSON_NULL:
        return AvroDefault(
            kind=AVRO_DEFAULT_NULL, bool_val=False, int_val=Int64(0),
            double_val=Float64(0.0), str_val=String(""),
            bytes_val=List[UInt8](),
        )
    elif v.tag == _JSON_BOOL:
        return AvroDefault(
            kind=AVRO_DEFAULT_BOOL, bool_val=v.bool_val, int_val=Int64(0),
            double_val=Float64(0.0), str_val=String(""),
            bytes_val=List[UInt8](),
        )
    elif v.tag == _JSON_INT:
        return AvroDefault(
            kind=AVRO_DEFAULT_INT, bool_val=False, int_val=Int64(v.int_val),
            double_val=Float64(v.int_val), str_val=String(""),
            bytes_val=List[UInt8](),
        )
    elif v.tag == _JSON_FLOAT:
        return AvroDefault(
            kind=AVRO_DEFAULT_DOUBLE, bool_val=False, int_val=Int64(0),
            double_val=v.float_val, str_val=String(""),
            bytes_val=List[UInt8](),
        )
    elif v.tag == _JSON_STRING:
        return AvroDefault(
            kind=AVRO_DEFAULT_STRING, bool_val=False, int_val=Int64(0),
            double_val=Float64(0.0), str_val=v.str_val,
            bytes_val=List[UInt8](),
        )
    # Object / array default — not synthesized.
    return AvroDefault.none()


def _capture_aliases(obj: _JsonValue) -> List[String]:
    """Capture an `aliases` array (field-level or type-level). Empty if absent
    or not an array of strings."""
    var out = List[String]()
    var v = _obj_get(obj, "aliases")
    if v.tag == _JSON_ARRAY:
        for i in range(len(v.arr_val)):
            if v.arr_val[i].tag == _JSON_STRING:
                out.append(v.arr_val[i].str_val)
    return out^


# =============================================================================
# Avro -> Arrow type lattice.
# =============================================================================

def _write_avro_kind_name[W: Writer](mut writer: W, kind: Int):
    """WRITE what `avro_kind_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a shared
    library can bind such a pair CROSSED, returning the wrong string or
    crashing its host."""
    if kind == AVRO_KIND_NULL:
        writer.write(String("null"))
        return
    elif kind == AVRO_KIND_BOOLEAN:
        writer.write(String("boolean"))
        return
    elif kind == AVRO_KIND_INT:
        writer.write(String("int"))
        return
    elif kind == AVRO_KIND_LONG:
        writer.write(String("long"))
        return
    elif kind == AVRO_KIND_FLOAT:
        writer.write(String("float"))
        return
    elif kind == AVRO_KIND_DOUBLE:
        writer.write(String("double"))
        return
    elif kind == AVRO_KIND_BYTES:
        writer.write(String("bytes"))
        return
    elif kind == AVRO_KIND_STRING:
        writer.write(String("string"))
        return
    elif kind == AVRO_KIND_RECORD:
        writer.write(String("record"))
        return
    elif kind == AVRO_KIND_ENUM:
        writer.write(String("enum"))
        return
    elif kind == AVRO_KIND_ARRAY:
        writer.write(String("array"))
        return
    elif kind == AVRO_KIND_MAP:
        writer.write(String("map"))
        return
    elif kind == AVRO_KIND_UNION:
        writer.write(String("union"))
        return
    elif kind == AVRO_KIND_FIXED:
        writer.write(String("fixed"))
        return
    writer.write(String("kind#") + String(kind))
    return


def avro_kind_name(kind: Int) -> String:
    """Human-readable Avro physical type name (diagnostics only)."""
    var out = String()
    _write_avro_kind_name(out, kind)
    return out^


@always_inline
def _require_physical(
    n: AvroNode, logical: String, ok: Bool, expected: String
) raises:
    """Reject a logical-type annotation over an illegal physical type.

    Runs once per schema field at OCF-open, never per row.
    """
    if not ok:
        raise Error(
            String("AvroSchemaError.LOGICAL_TYPE_PHYSICAL_MISMATCH: logicalType '")
            + logical
            + "' requires an underlying Avro "
            + expected
            + ", but this node's physical type is "
            + avro_kind_name(n.kind)
            + " (the schema in the file header is not self-consistent)"
        )


def avro_node_to_arrow(schema: AvroSchema, idx: Int) raises -> ArrowType:
    """Map an Avro schema node to its Arrow type.

    Honors standard logical types (date / time / timestamp / decimal /
    duration) and the union[null, T] -> nullable T collapse.
    """
    var n = schema.node(idx)
    var kind = n.kind
    var logical = n.logical_type

    # ---- Logical-type overrides first. ----
    #
    # ⚠ UNTRUSTED INPUT. EVERY override below is
    # gated on the node's underlying PHYSICAL kind, and that gate is a memory-
    # safety property, not a nicety.
    #
    # The decoder picks the accumulator ARM from the ArrowType this function
    # returns (`ColumnAccVariant.create`), but dispatches the wire READ on the
    # node's `avro_kind` (`_decode_read_plan`). Those are two independent
    # decisions over the same attacker-supplied `avro.schema` JSON, and without
    # this guard nothing requires them to agree: `{"type":"long",
    # "logicalType":"decimal"}` would produce a DECIMAL128 accumulator paired
    # with an AVRO_KIND_LONG read, so the interpreter would evaluate
    # `self.accs[oi].i64.value()` on an Optional that is None (at ASSERT=none,
    # a SIGILL out of `Optional.value()`). Same shape for
    # date-over-string, timestamp-over-bytes, uuid-over-long, and the rest.
    #
    # The `arrow.*` override table has exactly this guard
    # (`avro_logical_arrow.mojo:_physical_matches`); this applies it to the
    # STANDARD Avro logical types.
    #
    # Behaviour on mismatch is to RAISE, not to silently fall through to the
    # physical type. The Avro spec's "ignore an invalid logical type" advice
    # assumes an implementation that reads the physical type either way; here
    # the two halves of the decoder have already diverged, and a file that
    # annotates a `long` as a `decimal` is malformed in a way the caller wants
    # to hear about rather than receive as silently-retyped data.
    if logical.byte_length() > 0:
        if logical == "decimal":
            _require_physical(
                n, logical, kind == AVRO_KIND_BYTES or kind == AVRO_KIND_FIXED,
                "bytes or fixed",
            )
            if n.precision > 76:
                raise Error("AvroSchemaError.DECIMAL_PRECISION_TOO_LARGE: limit=76")
            if n.precision <= 38:
                return ArrowType.DECIMAL128
            return ArrowType.DECIMAL256
        elif logical == "date":
            _require_physical(n, logical, kind == AVRO_KIND_INT, "int")
            return ArrowType.DATE32
        elif logical == "time-millis":
            _require_physical(n, logical, kind == AVRO_KIND_INT, "int")
            return ArrowType.TIME32_MS
        elif logical == "time-micros":
            _require_physical(n, logical, kind == AVRO_KIND_LONG, "long")
            return ArrowType.TIME64_US
        elif logical == "timestamp-millis":
            _require_physical(n, logical, kind == AVRO_KIND_LONG, "long")
            return ArrowType.TIMESTAMP_MS
        elif logical == "timestamp-micros":
            _require_physical(n, logical, kind == AVRO_KIND_LONG, "long")
            return ArrowType.TIMESTAMP_US
        elif logical == "local-timestamp-millis":
            _require_physical(n, logical, kind == AVRO_KIND_LONG, "long")
            return ArrowType.TIMESTAMP_MS
        elif logical == "local-timestamp-micros":
            _require_physical(n, logical, kind == AVRO_KIND_LONG, "long")
            return ArrowType.TIMESTAMP_US
        elif logical == "duration":
            _require_physical(n, logical, kind == AVRO_KIND_FIXED, "fixed(12)")
            return ArrowType.INTERVAL_MONTH_DAY_NANO
        elif logical == "uuid":
            # Avro 1.11 annotates `string`; the Arrow mapping also
            # accepts fixed(16). Either physical form decodes into BINARY.
            _require_physical(
                n,
                logical,
                kind == AVRO_KIND_STRING or kind == AVRO_KIND_FIXED,
                "string or fixed(16)",
            )
            return ArrowType.BINARY
        # Unknown logical type: fall through to underlying physical type.

    if kind == AVRO_KIND_NULL:
        return ArrowType.NULL
    elif kind == AVRO_KIND_BOOLEAN:
        return ArrowType.BOOL
    elif kind == AVRO_KIND_INT:
        return ArrowType.INT32
    elif kind == AVRO_KIND_LONG:
        return ArrowType.INT64
    elif kind == AVRO_KIND_FLOAT:
        return ArrowType.FLOAT32
    elif kind == AVRO_KIND_DOUBLE:
        return ArrowType.FLOAT64
    elif kind == AVRO_KIND_BYTES:
        return ArrowType.BINARY
    elif kind == AVRO_KIND_STRING:
        return ArrowType.STRING
    elif kind == AVRO_KIND_RECORD:
        return ArrowType.STRUCT
    elif kind == AVRO_KIND_ENUM:
        return ArrowType.DICTIONARY
    elif kind == AVRO_KIND_ARRAY:
        return ArrowType.LIST
    elif kind == AVRO_KIND_MAP:
        return ArrowType.MAP
    elif kind == AVRO_KIND_FIXED:
        return ArrowType.BINARY
    elif kind == AVRO_KIND_UNION:
        # union[null, T] / union[T, null] collapses to nullable Arrow T.
        if len(n.children) == 2:
            var c0 = schema.node(n.children[0])
            var c1 = schema.node(n.children[1])
            if c0.kind == AVRO_KIND_NULL:
                return avro_node_to_arrow(schema, n.children[1])
            elif c1.kind == AVRO_KIND_NULL:
                return avro_node_to_arrow(schema, n.children[0])
        # n>=3 or 2-without-null -> dense union.
        return ArrowType.UNION_DENSE
    raise Error("AvroSchemaError.UNKNOWN_TYPE in avro_node_to_arrow")


# =============================================================================
# CRC-64-AVRO ("Rabin") fingerprint.
# =============================================================================
#
# Per the Avro spec the 64-bit Rabin fingerprint uses the polynomial
# 0xc15d213aa4d7a795 with the standard CRC initialization
# EMPTY = 0xc15d213aa4d7a795. The reference algorithm:
#
#   long fp = EMPTY;
#   for each byte b:
#       fp = (fp >>> 8) ^ TABLE[(int)(fp ^ b) & 0xff];
#
# where TABLE[i] is derived by 8 right-shift-and-conditional-xor rounds with
# the polynomial. We compute the table once per call (256 entries, cheap) to
# avoid a comptime global; the canonical-form strings are short.

comptime _RABIN_EMPTY: UInt64 = 0xc15d213aa4d7a795


def _build_rabin_table() -> List[UInt64]:
    var table = List[UInt64]()
    for i in range(256):
        var fp = UInt64(i)
        for _j in range(8):
            # fp = (fp >>> 1) ^ (EMPTY & -(fp & 1))
            var mask = UInt64(0)
            if (fp & UInt64(1)) != 0:
                mask = _RABIN_EMPTY
            fp = (fp >> 1) ^ mask
        table.append(fp)
    return table^


def crc_64_avro(bytes: Span[UInt8, _]) -> UInt64:
    """CRC-64-AVRO ("Rabin") 64-bit fingerprint of a byte sequence.

    Matches the reference implementation in the Avro spec
    (SchemaNormalization.fingerprint64). Returns the 64-bit fingerprint as
    a UInt64; callers that need the canonical 8-byte little-endian on-wire
    form (Single-Object Encoding) can byte-split it.
    """
    var table = _build_rabin_table()
    var fp = _RABIN_EMPTY
    for i in range(len(bytes)):
        var b = bytes[i]
        var idx = Int((fp ^ UInt64(b)) & UInt64(0xff))
        fp = (fp >> 8) ^ table[idx]
    return fp


# =============================================================================
# Minimal recursive-descent JSON parser (Avro schema subset).
# =============================================================================
#
# Avro schemas are small JSON documents. We need a faithful DOM for objects /
# arrays / strings / integers; floats / true / false / null literals are
# accepted but only integers and strings are consumed by canonicalization.
#
# This parser is intentionally self-contained (no dependency on komira_json,
# which is columnar/structural-index oriented, not a general DOM). It owns its
# String input and produces an owned _JsonValue tree.

comptime _JSON_NULL: Int = 0
comptime _JSON_BOOL: Int = 1
comptime _JSON_INT: Int = 2
comptime _JSON_FLOAT: Int = 3
comptime _JSON_STRING: Int = 4
comptime _JSON_ARRAY: Int = 5
comptime _JSON_OBJECT: Int = 6


@fieldwise_init
struct _JsonValue(Copyable, Movable):
    var tag: Int
    var bool_val: Bool
    var int_val: Int
    var float_val: Float64
    var str_val: String
    var arr_val: List[_JsonValue]
    # Object: parallel keys + values.
    var obj_keys: List[String]
    var obj_vals: List[_JsonValue]

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


def _json_null() -> _JsonValue:
    """Factory for a NULL-tagged JSON value (used as the empty/default)."""
    return _JsonValue(
        tag=_JSON_NULL,
        bool_val=False,
        int_val=0,
        float_val=Float64(0.0),
        str_val=String(""),
        arr_val=List[_JsonValue](),
        obj_keys=List[String](),
        obj_vals=List[_JsonValue](),
    )


def _obj_get(value: _JsonValue, key: String) -> _JsonValue:
    """Return a copy of the object member named `key`, or a NULL value."""
    for i in range(len(value.obj_keys)):
        if value.obj_keys[i] == key:
            return value.obj_vals[i].copy()
    return _json_null()


def _obj_get_string(value: _JsonValue, key: String) -> String:
    var v = _obj_get(value, key)
    if v.tag == _JSON_STRING:
        return v.str_val
    return String("")


def _obj_get_int(value: _JsonValue, key: String) -> Int:
    var v = _obj_get(value, key)
    if v.tag == _JSON_INT:
        return v.int_val
    return 0


struct _JsonParser:
    var data: List[UInt8]
    var pos: Int

    def __init__(out self, text: String):
        self.data = List[UInt8]()
        var b = text.as_bytes()
        for i in range(len(b)):
            self.data.append(b[i])
        self.pos = 0

    def _malformed(self, reason: String) -> Error:
        """A MALFORMED_JSON error naming `reason` and the byte offset the
        parser stands on."""
        return Error(
            String("AvroSchemaError.MALFORMED_JSON: ")
            + reason
            + " at byte "
            + String(self.pos)
        )

    @always_inline
    def at_end(self) -> Bool:
        return self.pos >= len(self.data)

    @always_inline
    def _peek(self) -> UInt8:
        if self.at_end():
            return 0
        return self.data[self.pos]

    def skip_ws(mut self):
        while not self.at_end():
            var c = self.data[self.pos]
            if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D:
                self.pos += 1
            else:
                break

    def parse_value(mut self, depth: Int = 0) raises -> _JsonValue:
        # UNTRUSTED INPUT. parse_value / _parse_object /
        # _parse_array are unbounded MUTUAL RECURSION over native stack frames,
        # driven entirely by the `avro.schema` text in the file header. A few
        # hundred thousand `[` characters exhaust the thread stack (a SIGSEGV
        # with the recursive frame repeated all the way down the stack dump).
        # A stack overflow is not a bounds check, so this one
        # behaves identically at ASSERT=safe and ASSERT=none; it is bounded here
        # because it is the same defect class (an unvalidated quantity taken
        # from an untrusted header) and is a remote crash either way.
        #
        # The counter is threaded through the call rather than held on the
        # parser so it unwinds naturally and cannot be left stale by a raise.
        if depth > MAX_SCHEMA_DEPTH:
            raise Error(
                String("AvroSchemaError.SCHEMA_TOO_DEEP: JSON nesting exceeds ")
                + String(MAX_SCHEMA_DEPTH)
                + " levels"
            )
        self.skip_ws()
        if self.at_end():
            raise self._malformed("unexpected end of input")
        var c = self._peek()
        if c == UInt8(ord('"')):
            return self._parse_string()
        elif c == UInt8(ord("{")):
            return self._parse_object(depth)
        elif c == UInt8(ord("[")):
            return self._parse_array(depth)
        elif c == UInt8(ord("t")) or c == UInt8(ord("f")):
            return self._parse_bool()
        elif c == UInt8(ord("n")):
            return self._parse_null()
        elif c == UInt8(ord("-")) or (c >= UInt8(ord("0")) and c <= UInt8(ord("9"))):
            return self._parse_number()
        raise self._malformed("unexpected character")

    def _parse_string(mut self) raises -> _JsonValue:
        # Escapes (including UTF-16 surrogate pairs) and raw UTF-8 are decoded
        # byte-exact by `decode_json_string`; see json_string.mojo.
        var v = _json_null()
        v.tag = _JSON_STRING
        self.pos = decode_json_string(Span(self.data), self.pos, v.str_val)
        return v^

    def _parse_object(mut self, depth: Int) raises -> _JsonValue:
        self.pos += 1  # consume '{'
        var v = _json_null()
        v.tag = _JSON_OBJECT
        self.skip_ws()
        if self._peek() == UInt8(ord("}")):
            self.pos += 1
            return v^
        while True:
            self.skip_ws()
            if self._peek() != UInt8(ord('"')):
                raise self._malformed("object key not string")
            var key = self._parse_string()
            self.skip_ws()
            if self._peek() != UInt8(ord(":")):
                raise self._malformed("expected ':'")
            self.pos += 1
            var val = self.parse_value(depth + 1)
            v.obj_keys.append(key.str_val)
            v.obj_vals.append(val^)
            self.skip_ws()
            var c = self._peek()
            if c == UInt8(ord(",")):
                self.pos += 1
                continue
            elif c == UInt8(ord("}")):
                self.pos += 1
                break
            raise self._malformed("expected ',' or '}'")
        return v^

    def _parse_array(mut self, depth: Int) raises -> _JsonValue:
        self.pos += 1  # consume '['
        var v = _json_null()
        v.tag = _JSON_ARRAY
        self.skip_ws()
        if self._peek() == UInt8(ord("]")):
            self.pos += 1
            return v^
        while True:
            var elem = self.parse_value(depth + 1)
            v.arr_val.append(elem^)
            self.skip_ws()
            var c = self._peek()
            if c == UInt8(ord(",")):
                self.pos += 1
                continue
            elif c == UInt8(ord("]")):
                self.pos += 1
                break
            raise self._malformed("expected ',' or ']'")
        return v^

    def _parse_bool(mut self) raises -> _JsonValue:
        var v = _json_null()
        v.tag = _JSON_BOOL
        if self._match_literal("true"):
            v.bool_val = True
        elif self._match_literal("false"):
            v.bool_val = False
        else:
            raise self._malformed("bad boolean literal")
        return v^

    def _parse_null(mut self) raises -> _JsonValue:
        if not self._match_literal("null"):
            raise self._malformed("bad null literal")
        return _json_null()

    def _parse_number(mut self) raises -> _JsonValue:
        # The literal is checked against the RFC 8259 number grammar first
        # (json_number.mojo); the value parsers below rely on it.
        var start = self.pos
        var scan = scan_json_number(Span(self.data), start)
        self.pos = scan.end
        var v = _json_null()
        if scan.is_float:
            v.tag = _JSON_FLOAT
            # Parse the consumed digits as a Float64 (the substring start..pos)
            # via a small hand decimal parser (no stdlib atof). Used
            # by float-default capture; integer-typed JSON goes through
            # the _JSON_INT path below.
            v.float_val = _parse_decimal_f64(self.data, start, self.pos)
            return v^
        v.tag = _JSON_INT
        v.int_val = parse_json_int(Span(self.data), start, self.pos)
        return v^

    def _match_literal(mut self, lit: String) -> Bool:
        var b = lit.as_bytes()
        if self.pos + len(b) > len(self.data):
            return False
        for i in range(len(b)):
            if self.data[self.pos + i] != b[i]:
                return False
        self.pos += len(b)
        return True


def _parse_decimal_f64(data: List[UInt8], start: Int, end: Int) -> Float64:
    """Parse a decimal number (with optional sign / fraction / exponent) from
    `data[start:end]` into a Float64. Minimal — sufficient for Avro JSON
    `default` float literals. No NaN / Inf handling (not valid JSON numbers)."""
    var i = start
    var neg = False
    if i < end and data[i] == UInt8(ord("-")):
        neg = True
        i += 1
    var int_part: Float64 = 0.0
    while i < end and data[i] >= UInt8(ord("0")) and data[i] <= UInt8(ord("9")):
        int_part = int_part * 10.0 + Float64(Int(data[i] - UInt8(ord("0"))))
        i += 1
    var frac: Float64 = 0.0
    var scale: Float64 = 1.0
    if i < end and data[i] == UInt8(ord(".")):
        i += 1
        while i < end and data[i] >= UInt8(ord("0")) and data[i] <= UInt8(ord("9")):
            scale *= 10.0
            frac += Float64(Int(data[i] - UInt8(ord("0")))) / scale
            i += 1
    var val = int_part + frac
    # Exponent.
    if i < end and (data[i] == UInt8(ord("e")) or data[i] == UInt8(ord("E"))):
        i += 1
        var exp_neg = False
        if i < end and (data[i] == UInt8(ord("+")) or data[i] == UInt8(ord("-"))):
            exp_neg = data[i] == UInt8(ord("-"))
            i += 1
        var exp = 0
        while i < end and data[i] >= UInt8(ord("0")) and data[i] <= UInt8(ord("9")):
            exp = exp * 10 + Int(data[i] - UInt8(ord("0")))
            i += 1
        var factor: Float64 = 1.0
        for _e in range(exp):
            factor *= 10.0
        if exp_neg:
            val /= factor
        else:
            val *= factor
    return -val if neg else val
