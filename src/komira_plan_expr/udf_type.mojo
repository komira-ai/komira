# =============================================================================
# udf_type — the Arrow type of a UDF argument, result or state, nested to any
# depth (optimized_plan_udfs.md §10.3, §10.5)
# =============================================================================
#
# A `UdfRef` declares its argument types, its return type and an aggregate's
# state type as full Arrow types: `list<fixed_size_list<float32>>`, a struct
# inside a list. The engine's `Field` holds one level of children (three
# parallel lists of names, type ids and nullabilities), so it cannot be that
# type. `UdfType` is: a `Field`'s own facts plus `children`, each a whole
# `UdfType`.
#
# ⚠ A LEAF, LIKE `partition_frame`. `Expr` stores a `UdfType` on
# `EXPR_UDF_APPLY` (the call's type is its `UdfRef`'s return type), and
# `expr.mojo` must not import `komira_arrow.schema`, whose closure is ~50
# modules (`expr.mojo`'s header). So this module imports only `ArrowType`;
# the conversions to and from `Field` live in `expr_walk.mojo`, which already
# imports the schema.
# =============================================================================

from komira_arrow.arrow_types import ArrowType


struct UdfType(Movable, Writable):
    """One Arrow type with its name, as a `WireField` carries it, with the
    children recursive. For a column it is the column's field; for a table (a
    MAP_BATCHES_FRAME or STEP result) it is a struct whose children are the
    columns."""

    var name: String
    var arrow_type: ArrowType
    var dtype: DType
    var nullable: Bool
    var decimal_precision: Int
    var decimal_scale: Int
    var tz: String
    var dict_index_type: ArrowType
    var union_type_ids: List[Int]
    var flags: Int64
    var metadata_keys: List[String]
    var metadata_values: List[String]
    var children: List[UdfType]

    def __init__(
        out self,
        var name: String,
        arrow_type: ArrowType,
        dtype: DType,
        nullable: Bool,
        var children: List[UdfType] = List[UdfType](),
    ):
        self.name = name^
        self.arrow_type = arrow_type
        self.dtype = dtype
        self.nullable = nullable
        self.decimal_precision = 0
        self.decimal_scale = 0
        self.tz = String("")
        self.dict_index_type = ArrowType.NULL
        self.union_type_ids = List[Int]()
        self.flags = 0
        self.metadata_keys = List[String]()
        self.metadata_values = List[String]()
        self.children = children^

    def copy(self) -> Self:
        var kids = List[UdfType](capacity=len(self.children))
        for i in range(len(self.children)):
            kids.append(self.children[i].copy())
        var t = UdfType(
            self.name.copy(), self.arrow_type, self.dtype, self.nullable, kids^
        )
        t.decimal_precision = self.decimal_precision
        t.decimal_scale = self.decimal_scale
        t.tz = self.tz.copy()
        t.dict_index_type = self.dict_index_type
        t.union_type_ids = self.union_type_ids.copy()
        t.flags = self.flags
        t.metadata_keys = self.metadata_keys.copy()
        t.metadata_values = self.metadata_values.copy()
        return t^

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference (the
    # `StringFnNData` precedent). Field destructors still run.
    def __deinit__(deinit self):
        pass

    def depth(self) -> Int:
        """1 for a type with no children; 1 + the deepest child otherwise."""
        var d = 0
        for i in range(len(self.children)):
            var c = self.children[i].depth()
            if c > d:
                d = c
        return d + 1

    def write_to[W: Writer](self, mut writer: W):
        """Every fact, children included, so that the render of an
        `EXPR_UDF_APPLY` (which is plan identity) sees a changed type."""
        writer.write(
            "'", self.name, "':", Int(self.arrow_type.type_id),
            "/", self.dtype, "/", "N" if self.nullable else "R",
        )
        if self.decimal_precision != 0 or self.decimal_scale != 0:
            writer.write("/d", self.decimal_precision, ".", self.decimal_scale)
        if self.tz.byte_length() > 0:
            writer.write("/tz=", self.tz)
        if self.dict_index_type.type_id != ArrowType.NULL.type_id:
            writer.write("/dict=", Int(self.dict_index_type.type_id))
        if len(self.union_type_ids) > 0:
            writer.write("/u=[")
            for i in range(len(self.union_type_ids)):
                if i > 0:
                    writer.write(",")
                writer.write(self.union_type_ids[i])
            writer.write("]")
        if self.flags != 0:
            writer.write("/f=", self.flags)
        for i in range(len(self.metadata_keys)):
            writer.write("/m:", self.metadata_keys[i], "=")
            if i < len(self.metadata_values):
                writer.write(self.metadata_values[i])
        if len(self.children) > 0:
            writer.write("<")
            for i in range(len(self.children)):
                if i > 0:
                    writer.write(", ")
                self.children[i].write_to(writer)
            writer.write(">")


def udf_type_same(a: UdfType, b: UdfType, compare_name: Bool) -> Bool:
    """True when `a` and `b` are the same type: every fact equal (the
    dictionary index type only for a DICTIONARY), children compared
    recursively and in order, each child's name included. The root's name is
    compared only when `compare_name` is set: a column UDF's result takes its
    name from the expression that holds it, not from the type."""
    if compare_name and a.name != b.name:
        return False
    if a.arrow_type.type_id != b.arrow_type.type_id:
        return False
    if a.dtype != b.dtype or a.nullable != b.nullable:
        return False
    if (
        a.decimal_precision != b.decimal_precision
        or a.decimal_scale != b.decimal_scale
    ):
        return False
    if a.tz != b.tz or a.flags != b.flags:
        return False
    # The index type is a fact of a DICTIONARY only. The engine's `Field`
    # carries a default (INT32) on every field and a foreign producer writes
    # 0, so comparing it on any other type would refuse two equal types.
    if (
        a.arrow_type.type_id == ArrowType.DICTIONARY.type_id
        and a.dict_index_type.type_id != b.dict_index_type.type_id
    ):
        return False
    if len(a.union_type_ids) != len(b.union_type_ids):
        return False
    for i in range(len(a.union_type_ids)):
        if a.union_type_ids[i] != b.union_type_ids[i]:
            return False
    if not _strings_same(a.metadata_keys, b.metadata_keys):
        return False
    if not _strings_same(a.metadata_values, b.metadata_values):
        return False
    if len(a.children) != len(b.children):
        return False
    for i in range(len(a.children)):
        if not udf_type_same(a.children[i], b.children[i], True):
            return False
    return True


def _strings_same(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True
