# The spike descriptor, version 1, as a producer writes it: the message and
# canonical form komira_udf_spike_descriptor.h states, encoded here. The
# harness stands in for the producer, which records at capture the entry, the
# shapes and the signature (docs/design/udf_runtime_interface.md section
# 3.1); a runtime decodes and compares at validate. No pointer.

comptime DESCRIPTOR_VERSION: UInt32 = 1
"""The newest descriptor_version the spike runtimes read."""


@fieldwise_init
struct DescField(Copyable, Movable, Writable):
    """SpikeField: a name and an Arrow C Data format string (it stands for
    WireField). An empty name is not emitted."""

    var name: String
    var format: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.name, ":", self.format)


struct Descriptor(Copyable, Movable):
    """SpikeDescriptor. `has_recorded` gives recorded_fields its presence:
    True emits it even when both lists are empty."""

    var entry: String
    var shapes: UInt32
    var args: List[DescField]
    var result: List[DescField]
    var result_is_table: Bool
    var state: Optional[DescField]
    var has_recorded: Bool
    var fields: List[DescField]
    var key_fields: List[DescField]

    def __init__(out self, entry: String, shapes: UInt32):
        self.entry = entry
        self.shapes = shapes
        self.args = List[DescField]()
        self.result = List[DescField]()
        self.result_is_table = False
        self.state = None
        self.has_recorded = False
        self.fields = List[DescField]()
        self.key_fields = List[DescField]()


def bytes_less(a: String, b: String) -> Bool:
    """`a` before `b` in the order of their UTF-8 bytes (the canonical order
    of RecordedFields)."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var n = len(x) if len(x) < len(y) else len(y)
    for i in range(n):
        if x[i] != y[i]:
            return x[i] < y[i]
    return len(x) < len(y)


def sorted_by_name(fields: List[DescField]) -> List[DescField]:
    """`fields` in the canonical order (an insertion sort: lists are short)."""
    var out = List[DescField]()
    for i in range(len(fields)):
        var at = len(out)
        out.append(fields[i].copy())
        while at > 0 and bytes_less(out[at].name, out[at - 1].name):
            var t = out[at].copy()
            out[at] = out[at - 1].copy()
            out[at - 1] = t^
            at -= 1
    return out^


def _varint(mut out: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        out.append(UInt8(x & 0x7F) | 0x80)
        x >>= 7
    out.append(UInt8(x))


def _tag(mut out: List[UInt8], field: Int, wire_type: Int):
    _varint(out, UInt64(field << 3 | wire_type))


def _bytes(mut out: List[UInt8], field: Int, b: List[UInt8]):
    _tag(out, field, 2)
    _varint(out, UInt64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


def _string(mut out: List[UInt8], field: Int, s: String):
    """A string field, omitted when empty (its default)."""
    if s == "":
        return
    var b = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        b.append(sb[i])
    _bytes(out, field, b)


def _field(f: DescField) -> List[UInt8]:
    var out = List[UInt8]()
    _string(out, 1, f.name)
    _string(out, 2, f.format)
    return out^


def encode(d: Descriptor) -> List[UInt8]:
    """The canonical bytes of `d`: fields in ascending number, defaults
    omitted, recorded_fields emitted whenever present. The lists are encoded
    in the order given: a caller that wants canonical RecordedFields sorts
    them first (sorted_by_name), and one that wants to plant an unsorted list
    does not."""
    var out = List[UInt8]()
    _string(out, 1, d.entry)
    if d.shapes != 0:
        _tag(out, 2, 0)
        _varint(out, UInt64(d.shapes))
    for i in range(len(d.args)):
        _bytes(out, 3, _field(d.args[i]))
    for i in range(len(d.result)):
        _bytes(out, 4, _field(d.result[i]))
    if d.result_is_table:
        _tag(out, 5, 0)
        _varint(out, 1)
    if d.state:
        _bytes(out, 6, _field(d.state.value()))
    if d.has_recorded:
        var rf = List[UInt8]()
        for i in range(len(d.fields)):
            _bytes(rf, 1, _field(d.fields[i]))
        for i in range(len(d.key_fields)):
            _bytes(rf, 2, _field(d.key_fields[i]))
        _bytes(out, 7, rf)
    return out^


struct DescriptorEdit(Copyable, Movable):
    """What a case changes in the descriptor the harness derives from its
    spec: each set field replaces the derived one. `recorded` is 0 (derive),
    1 (absent) or 2 (`fields` and `key_fields`, in the order given)."""

    var entry: Optional[String]
    var shapes: Optional[UInt32]
    var args: Optional[List[DescField]]
    var result: Optional[List[DescField]]
    var state: Optional[DescField]
    var state_absent: Bool
    var recorded: Int
    var fields: List[DescField]
    var key_fields: List[DescField]

    def __init__(out self):
        self.entry = None
        self.shapes = None
        self.args = None
        self.result = None
        self.state = None
        self.state_absent = False
        self.recorded = 0
        self.fields = List[DescField]()
        self.key_fields = List[DescField]()


def apply_edit(mut d: Descriptor, e: DescriptorEdit):
    if e.entry:
        d.entry = e.entry.value()
    if e.shapes:
        d.shapes = e.shapes.value()
    if e.args:
        d.args = e.args.value().copy()
    if e.result:
        d.result = e.result.value().copy()
    if e.state:
        d.state = e.state.value().copy()
    if e.state_absent:
        d.state = None
    if e.recorded == 1:
        d.has_recorded = False
        d.fields = List[DescField]()
        d.key_fields = List[DescField]()
    elif e.recorded == 2:
        d.has_recorded = True
        d.fields = e.fields.copy()
        d.key_fields = e.key_fields.copy()
