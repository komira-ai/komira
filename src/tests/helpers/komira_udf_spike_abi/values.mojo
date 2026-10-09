# The values the binding takes and returns: column types, columns and
# batches. No pointer: runtime.mojo exports these as Arrow C Data arrays and
# imports a runtime's arrays back into them.

from std.memory import bitcast

comptime TYPE_INT64 = 1
"""Arrow int64, format "l"."""
comptime TYPE_FLOAT64 = 2
"""Arrow float64, format "g"."""
comptime TYPE_INT32 = 3
"""Arrow int32, format "i" (group ids)."""


def type_format(type_id: Int) -> String:
    """The Arrow C Data format string of a type."""
    if type_id == TYPE_INT64:
        return "l"
    if type_id == TYPE_FLOAT64:
        return "g"
    if type_id == TYPE_INT32:
        return "i"
    return "?"


def type_width(type_id: Int) -> Int:
    """Bytes per value."""
    return 4 if type_id == TYPE_INT32 else 8


def type_from_name(name: String) raises -> Int:
    if name == "int64":
        return TYPE_INT64
    if name == "float64":
        return TYPE_FLOAT64
    if name == "int32":
        return TYPE_INT32
    raise Error("UDF_TYPE_UNKNOWN: " + name)


def type_name(type_id: Int) -> String:
    if type_id == TYPE_INT64:
        return "int64"
    if type_id == TYPE_FLOAT64:
        return "float64"
    if type_id == TYPE_INT32:
        return "int32"
    return "?"


@fieldwise_init
struct ColumnType(Copyable, Movable, Writable):
    """One field: a type and whether it may hold nulls."""

    var type_id: Int
    var nullable: Bool

    def write_to(self, mut writer: Some[Writer]):
        writer.write(type_name(self.type_id), "" if self.nullable else " not null")


struct Column(Copyable, Movable, Sized, Writable):
    """A column of one primitive type. `bits` holds each row's value as 64
    bits (a float64's bit pattern; an int32 widened); `valid[i]` is False for
    a null. `offset` asks the exporter to place the rows at that Arrow array
    offset (rows before it are padding no reader may use), so a reader that
    ignores `offset` reads the padding."""

    var type_id: Int
    var bits: List[Int64]
    var valid: List[Bool]
    var offset: Int

    def __init__(out self, type_id: Int):
        self.type_id = type_id
        self.bits = List[Int64]()
        self.valid = List[Bool]()
        self.offset = 0

    def __len__(self) -> Int:
        return len(self.bits)

    def append_int(mut self, v: Int64):
        self.bits.append(v)
        self.valid.append(True)

    def append_float(mut self, v: Float64):
        self.bits.append(bitcast[DType.int64, 1](SIMD[DType.float64, 1](v)))
        self.valid.append(True)

    def append_null(mut self):
        self.bits.append(0)
        self.valid.append(False)

    def null_count(self) -> Int:
        var n = 0
        for i in range(len(self.valid)):
            if not self.valid[i]:
                n += 1
        return n

    def as_float(self, i: Int) -> Float64:
        return bitcast[DType.float64, 1](SIMD[DType.int64, 1](self.bits[i]))

    def write_to(self, mut writer: Some[Writer]):
        writer.write(type_name(self.type_id), "[")
        for i in range(len(self.bits)):
            if i > 0:
                writer.write(", ")
            if not self.valid[i]:
                writer.write("null")
            elif self.type_id == TYPE_FLOAT64:
                writer.write(self.as_float(i))
            else:
                writer.write(self.bits[i])
        writer.write("]")


struct Batch(Copyable, Movable, Writable):
    """A struct batch: columns of equal length, or none at all. `length` is
    authoritative (a zero-argument call has rows and no column)."""

    var columns: List[Column]
    var length: Int

    def __init__(out self, length: Int):
        self.columns = List[Column]()
        self.length = length

    def write_to(self, mut writer: Some[Writer]):
        writer.write("{", self.length, " rows")
        for i in range(len(self.columns)):
            writer.write("; ", self.columns[i])
        writer.write("}")
