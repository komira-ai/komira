# =============================================================================
# test_plan_census_complete.mojo
# =============================================================================
#
# THE CENSUS IS COMPLETE: every field and every enum value `komira.plan.v1`
# declares has a row in one of the five census ledgers, and every row names
# one that exists. A field added to plan.proto without a census row fails
# here, so a number no census pins cannot ship.
#
# WHERE "DECLARED" COMES FROM. Not from a parser written here: from protoc.
# protoc parses the .proto files and hands their descriptors to the Mojo
# plugin, which writes into every generated message the field vocabulary its
# decoder declares (`expect_fields`, one `|`-separated group of spellings per
# field) and into every generated enum its value names (`known_json_names`).
# This test decodes each message through a decoder that only records that
# vocabulary (`_Vocab`), then walks the decoder once over every declared
# field by name to learn which ones it reads as a singular bool; and it reads
# each enum's names. The generated code carries no list of the messages and
# enums themselves, so that list is read from the .proto text of every file
# of the library's `srcs` (staged under protos/): every `message <Name> {` and
# `enum <Name> {` declaration, nested or not, split on any whitespace; a
# statement it cannot classify (or a `service`, `extend`, `group` or block
# comment) is refused. A declared type the census does not know fails
# (`_fields_of` and `_values_of` raise for it), as does a census type the
# .proto does not declare.
#
# ONE_HOT ROWS. A message with two or more singular bools must have a ONE_HOT
# row in its census file listing exactly those bools, and no other message
# may have one, so a bool added to such a message fails here until its test
# writes it alone.
#
# WHERE THE ROWS COME FROM. Each census file keeps its rows in one
# `comptime LEDGER = """ ... """` block, the same rows its own tests write
# bytes from (and fail on if one is not written). The census files are staged
# as data and their blocks read here, so a row exists in exactly one place.
# The numbers are not compared here: protoc's numbers are what the census
# files pin, against the bytes.
#
# The checks are also run over planted defects (a field or enum value with
# no row, a row naming a field, value or type that does not exist, a
# duplicate row, two rows spelling one field two ways, a new message or enum,
# declarations split by tabs or after a `}`, unclassifiable statements, a
# short ONE_HOT row, a new singular bool, a ONE_HOT row naming nothing), and
# each must be reported, so a comparison that cannot fail fails the build.
# =============================================================================

from std.os import listdir
from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_proto_codec import FieldKey, ProtoEnum, Serializable, WireDecoder
from komira_plan_proto.plan import (
    WireAggExpr,
    WireAggFn,
    WireAggregateNode,
    WireAlias,
    WireAsofJoinNode,
    WireAsofTolerance,
    WireBinaryOp,
    WireCast,
    WireCastToVarcharNode,
    WireColIdx,
    WireColRef,
    WireCorrelatedSubquery,
    WireCseRefNode,
    WireDistinctNode,
    WireExpr,
    WireExtract,
    WireField,
    WireFilterNode,
    WireFrame,
    WireInList,
    WireJoinNode,
    WireJsonExtract,
    WireLimitNode,
    WireMapGet,
    WireMathFn,
    WireMathFn2,
    WireParam,
    WireParquetSource,
    WirePartitionByNode,
    WirePartitionExpr,
    WirePartitionTopNNode,
    WirePartitionValueRow,
    WirePlan,
    WirePlanEnvelope,
    WireProjectNode,
    WirePushdownGate,
    WireRegexp,
    WireScalar,
    WireScanBinding,
    WireScanNode,
    WireScanSource,
    WireSchema,
    WireSortNode,
    WireStringFn,
    WireStringFnN,
    WireStringOp,
    WireStructField,
    WireStructFieldIdx,
    WireSubstring,
    WireTopNNode,
    WireUdf,
    WireUdfCall,
    WireUdfColumn,
    WireUnaryOp,
    WireUnionNode,
    WireViewRefNode,
    WireWhen,
    WireWhenCase,
    WireWindowFn,
    WireWriteTarget,
)
from komira_plan_proto.plan_vocabulary import (
    AggFn,
    ArrowType,
    AsofDirection,
    AsofToleranceKind,
    BinaryOp,
    ColSide,
    CorrelatedKind,
    DTypeCode,
    ExprTag,
    ExtractField,
    FrameBound,
    FrameUnits,
    JoinAlgo,
    JoinType,
    MathFn1,
    MathFn2,
    ParamTag,
    PlanTag,
    PushdownGateMode,
    RegexpOp,
    ScalarKind,
    ScalarTimeUnit,
    SnapshotPolicy,
    SourceOrientation,
    SourceType,
    SourceVariantTag,
    StringFn,
    StringFnN,
    StringOp,
    UnaryOp,
    WindowFn,
    WriteCompression,
    WriteFormat,
)


# The census files, staged under `census/`. The .proto files are staged
# under `protos/` from the library's own `srcs` (BUCK), and every file there
# is scanned.
comptime _CENSUS = (
    "test_plan_field_numbers_scan.mojo test_plan_field_numbers_expr.mojo"
    + " test_plan_field_numbers_plan.mojo test_plan_enum_numbers_nodes.mojo"
    + " test_plan_enum_numbers_functions.mojo"
)


# ---- protoc's vocabulary, through the generated code -----------------------------


@fieldwise_init
struct _Shape(Copyable, Movable):
    """One message as protoc declared it: its field vocabulary, and the
    spelling group of each singular (non-repeated) bool field."""

    var accepted: String
    var bools: List[String]


struct _Vocab(WireDecoder):
    """A decoder that holds no message. It records the field vocabulary a
    generated `decode` declares (`expect_fields`); with `walk`, it then
    yields each declared field once, by its first spelling, and records
    which fields the generated body reads as a singular bool. Every read
    returns a default; a nested message is decoded by a non-walking
    `_Vocab`, so the walk does not recurse."""

    var accepted: String
    var walk: Bool
    var queue: List[String]
    var pos: Int
    var current: String
    var bools: List[String]

    def __init__(out self, walk: Bool):
        self.accepted = String("")
        self.walk = walk
        self.queue = List[String]()
        self.pos = 0
        self.current = String("")
        self.bools = List[String]()

    def next_field(mut self) raises -> FieldKey:
        if self.walk and self.pos < len(self.queue):
            self.current = self.queue[self.pos].copy()
            self.pos += 1
            return FieldKey(0, _split(self.current, "|")[0], False)
        return FieldKey.at_end()

    def expect_fields(mut self, message_name: StringSlice, accepted: StringSlice) raises:
        self.accepted = String(accepted)
        if self.walk:
            for group in _split(self.accepted, ","):
                self.queue.append(group.copy())

    def keep_null_fields(mut self, spellings: StringSlice):
        pass

    def skip(mut self) raises:
        raise Error("declared field `" + self.current + "` matched no branch of the generated decode")

    def read_string(mut self) raises -> String:
        return String("")

    def read_bytes(mut self) raises -> List[UInt8]:
        return List[UInt8]()

    def read_i64(mut self) raises -> Int64:
        return 0

    def read_i32(mut self) raises -> Int32:
        return 0

    def read_u64(mut self) raises -> UInt64:
        return 0

    def read_u32(mut self) raises -> UInt32:
        return 0

    def read_f64(mut self) raises -> Float64:
        return 0

    def read_f32(mut self) raises -> Float32:
        return 0

    def read_sint64(mut self) raises -> Int64:
        return 0

    def read_sint32(mut self) raises -> Int32:
        return 0

    def read_fixed64(mut self) raises -> UInt64:
        return 0

    def read_fixed32(mut self) raises -> UInt32:
        return 0

    def read_sfixed64(mut self) raises -> Int64:
        return 0

    def read_sfixed32(mut self) raises -> Int32:
        return 0

    def read_bool(mut self) raises -> Bool:
        self.bools.append(self.current.copy())
        return False

    def read_enum[En: ProtoEnum](mut self) raises -> En:
        return En.from_number(0)

    def read_message[M: Serializable](mut self) raises -> M:
        var d = _Vocab(False)
        return M.decode[_Vocab](d)

    def read_into_repeated_string(mut self, mut out: List[String]) raises:
        pass

    def read_into_repeated_i64(mut self, mut out: List[Int64]) raises:
        pass

    def read_into_repeated_i32(mut self, mut out: List[Int32]) raises:
        pass

    def read_into_repeated_u64(mut self, mut out: List[UInt64]) raises:
        pass

    def read_into_repeated_u32(mut self, mut out: List[UInt32]) raises:
        pass

    def read_into_repeated_f64(mut self, mut out: List[Float64]) raises:
        pass

    def read_into_repeated_f32(mut self, mut out: List[Float32]) raises:
        pass

    def read_into_repeated_sint64(mut self, mut out: List[Int64]) raises:
        pass

    def read_into_repeated_sint32(mut self, mut out: List[Int32]) raises:
        pass

    def read_into_repeated_fixed64(mut self, mut out: List[UInt64]) raises:
        pass

    def read_into_repeated_fixed32(mut self, mut out: List[UInt32]) raises:
        pass

    def read_into_repeated_sfixed64(mut self, mut out: List[Int64]) raises:
        pass

    def read_into_repeated_sfixed32(mut self, mut out: List[Int32]) raises:
        pass

    def read_into_repeated_bool(mut self, mut out: List[Bool]) raises:
        pass

    def read_into_repeated_enum[En: ProtoEnum](mut self, mut out: List[En]) raises:
        pass

    def read_into_repeated_message[M: Serializable](mut self, mut out: List[M]) raises:
        pass

    def read_into_string_string_map(mut self, mut out: Dict[String, String]) raises:
        pass

    def read_into_string_i32_map(mut self, mut out: Dict[String, Int32]) raises:
        pass

    def read_into_string_i64_map(mut self, mut out: Dict[String, Int64]) raises:
        pass

    def read_into_i64_string_map(mut self, mut out: Dict[Int64, String]) raises:
        pass

    def read_into_string_message_map[
        V: Serializable & Deinitable
    ](mut self, mut out: Dict[String, V]) raises:
        pass


def _vocabulary[M: Serializable & ImplicitlyDestructible]() raises -> _Shape:
    var d = _Vocab(True)
    _ = M.decode[_Vocab](d)
    if d.accepted.byte_length() == 0:
        raise Error("a generated decoder declared no field vocabulary")
    if d.pos != len(d.queue):
        raise Error("the generated decoder stopped before every declared field was read")
    return _Shape(d.accepted.copy(), d.bools.copy())


def _fields_of(message: String) raises -> _Shape:
    """protoc's view of `message` (field vocabulary and single bools), as
    the generated decoder declares and reads it, or raise for a message this census does
    not know."""
    if message == "WireField":
        return _vocabulary[WireField]()
    elif message == "WireSchema":
        return _vocabulary[WireSchema]()
    elif message == "WireScalar":
        return _vocabulary[WireScalar]()
    elif message == "WireParam":
        return _vocabulary[WireParam]()
    elif message == "WirePushdownGate":
        return _vocabulary[WirePushdownGate]()
    elif message == "WireScanBinding":
        return _vocabulary[WireScanBinding]()
    elif message == "WireParquetSource":
        return _vocabulary[WireParquetSource]()
    elif message == "WirePartitionValueRow":
        return _vocabulary[WirePartitionValueRow]()
    elif message == "WireScanSource":
        return _vocabulary[WireScanSource]()
    elif message == "WireColRef":
        return _vocabulary[WireColRef]()
    elif message == "WireColIdx":
        return _vocabulary[WireColIdx]()
    elif message == "WireBinaryOp":
        return _vocabulary[WireBinaryOp]()
    elif message == "WireUnaryOp":
        return _vocabulary[WireUnaryOp]()
    elif message == "WireAlias":
        return _vocabulary[WireAlias]()
    elif message == "WireInList":
        return _vocabulary[WireInList]()
    elif message == "WireCast":
        return _vocabulary[WireCast]()
    elif message == "WireCorrelatedSubquery":
        return _vocabulary[WireCorrelatedSubquery]()
    elif message == "WireWhenCase":
        return _vocabulary[WireWhenCase]()
    elif message == "WireWhen":
        return _vocabulary[WireWhen]()
    elif message == "WireAggFn":
        return _vocabulary[WireAggFn]()
    elif message == "WireExtract":
        return _vocabulary[WireExtract]()
    elif message == "WireMathFn":
        return _vocabulary[WireMathFn]()
    elif message == "WireMathFn2":
        return _vocabulary[WireMathFn2]()
    elif message == "WireStringFn":
        return _vocabulary[WireStringFn]()
    elif message == "WireStringFnN":
        return _vocabulary[WireStringFnN]()
    elif message == "WireUdfCall":
        return _vocabulary[WireUdfCall]()
    elif message == "WireSubstring":
        return _vocabulary[WireSubstring]()
    elif message == "WireStringOp":
        return _vocabulary[WireStringOp]()
    elif message == "WireRegexp":
        return _vocabulary[WireRegexp]()
    elif message == "WireStructField":
        return _vocabulary[WireStructField]()
    elif message == "WireStructFieldIdx":
        return _vocabulary[WireStructFieldIdx]()
    elif message == "WireMapGet":
        return _vocabulary[WireMapGet]()
    elif message == "WireJsonExtract":
        return _vocabulary[WireJsonExtract]()
    elif message == "WireFrame":
        return _vocabulary[WireFrame]()
    elif message == "WireWindowFn":
        return _vocabulary[WireWindowFn]()
    elif message == "WireExpr":
        return _vocabulary[WireExpr]()
    elif message == "WireAggExpr":
        return _vocabulary[WireAggExpr]()
    elif message == "WireScanNode":
        return _vocabulary[WireScanNode]()
    elif message == "WireUdfColumn":
        return _vocabulary[WireUdfColumn]()
    elif message == "WireUdf":
        return _vocabulary[WireUdf]()
    elif message == "WireFilterNode":
        return _vocabulary[WireFilterNode]()
    elif message == "WireProjectNode":
        return _vocabulary[WireProjectNode]()
    elif message == "WireAggregateNode":
        return _vocabulary[WireAggregateNode]()
    elif message == "WireJoinNode":
        return _vocabulary[WireJoinNode]()
    elif message == "WireSortNode":
        return _vocabulary[WireSortNode]()
    elif message == "WireLimitNode":
        return _vocabulary[WireLimitNode]()
    elif message == "WireDistinctNode":
        return _vocabulary[WireDistinctNode]()
    elif message == "WireTopNNode":
        return _vocabulary[WireTopNNode]()
    elif message == "WireUnionNode":
        return _vocabulary[WireUnionNode]()
    elif message == "WirePartitionExpr":
        return _vocabulary[WirePartitionExpr]()
    elif message == "WirePartitionByNode":
        return _vocabulary[WirePartitionByNode]()
    elif message == "WirePartitionTopNNode":
        return _vocabulary[WirePartitionTopNNode]()
    elif message == "WireAsofTolerance":
        return _vocabulary[WireAsofTolerance]()
    elif message == "WireAsofJoinNode":
        return _vocabulary[WireAsofJoinNode]()
    elif message == "WireViewRefNode":
        return _vocabulary[WireViewRefNode]()
    elif message == "WireCseRefNode":
        return _vocabulary[WireCseRefNode]()
    elif message == "WireCastToVarcharNode":
        return _vocabulary[WireCastToVarcharNode]()
    elif message == "WirePlan":
        return _vocabulary[WirePlan]()
    elif message == "WireWriteTarget":
        return _vocabulary[WireWriteTarget]()
    elif message == "WirePlanEnvelope":
        return _vocabulary[WirePlanEnvelope]()
    raise Error("the census has no message " + message)


def _values_of(enum: String) raises -> String:
    """protoc's value names of `enum`, as the generated enum declares them,
    or raise for an enum this census does not know."""
    if enum == "PlanTag":
        return PlanTag.known_json_names()
    elif enum == "ExprTag":
        return ExprTag.known_json_names()
    elif enum == "AggFn":
        return AggFn.known_json_names()
    elif enum == "WindowFn":
        return WindowFn.known_json_names()
    elif enum == "FrameUnits":
        return FrameUnits.known_json_names()
    elif enum == "FrameBound":
        return FrameBound.known_json_names()
    elif enum == "JoinType":
        return JoinType.known_json_names()
    elif enum == "JoinAlgo":
        return JoinAlgo.known_json_names()
    elif enum == "AsofDirection":
        return AsofDirection.known_json_names()
    elif enum == "AsofToleranceKind":
        return AsofToleranceKind.known_json_names()
    elif enum == "CorrelatedKind":
        return CorrelatedKind.known_json_names()
    elif enum == "SourceType":
        return SourceType.known_json_names()
    elif enum == "SourceOrientation":
        return SourceOrientation.known_json_names()
    elif enum == "SourceVariantTag":
        return SourceVariantTag.known_json_names()
    elif enum == "BinaryOp":
        return BinaryOp.known_json_names()
    elif enum == "UnaryOp":
        return UnaryOp.known_json_names()
    elif enum == "StringOp":
        return StringOp.known_json_names()
    elif enum == "StringFn":
        return StringFn.known_json_names()
    elif enum == "StringFnN":
        return StringFnN.known_json_names()
    elif enum == "ColSide":
        return ColSide.known_json_names()
    elif enum == "MathFn1":
        return MathFn1.known_json_names()
    elif enum == "MathFn2":
        return MathFn2.known_json_names()
    elif enum == "ExtractField":
        return ExtractField.known_json_names()
    elif enum == "RegexpOp":
        return RegexpOp.known_json_names()
    elif enum == "ArrowType":
        return ArrowType.known_json_names()
    elif enum == "WriteFormat":
        return WriteFormat.known_json_names()
    elif enum == "WriteCompression":
        return WriteCompression.known_json_names()
    elif enum == "ScalarKind":
        return ScalarKind.known_json_names()
    elif enum == "ScalarTimeUnit":
        return ScalarTimeUnit.known_json_names()
    elif enum == "ParamTag":
        return ParamTag.known_json_names()
    elif enum == "PushdownGateMode":
        return PushdownGateMode.known_json_names()
    elif enum == "SnapshotPolicy":
        return SnapshotPolicy.known_json_names()
    elif enum == "DTypeCode":
        return DTypeCode.known_json_names()
    raise Error("the census has no enum " + enum)


# ---- the declared types, from the .proto text ----------------------------------------


def _tokens(text: String) raises -> List[String]:
    """The tokens of `text` with `//` comments removed: words, and `{`, `}`
    and `;` each on their own, split on any whitespace."""
    if text.find("/*") >= 0:
        raise Error("the .proto text holds a /* */ comment, which the declaration scan does not read")
    var out = List[String]()
    for raw in text.split("\n"):
        var line = String(raw)
        var c = line.find("//")
        var code = String(line[byte=0:c]) if c >= 0 else line
        code = code.replace("\t", " ").replace("\r", " ").replace("\f", " ").replace("\v", " ")
        code = code.replace("{", " { ").replace("}", " } ").replace(";", " ; ")
        for w in code.split(" "):
            if w.byte_length() > 0:
                out.append(String(w))
    return out^


def _is_ident(w: String) -> Bool:
    var bytes = w.as_bytes()
    if len(bytes) == 0:
        return False
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        var letter = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
        if not letter and not (i > 0 and c >= 48 and c <= 57):
            return False
    return True


def _declared(text: String, kind: String) raises -> List[String]:
    """The name of every `<kind> <Name> {` declaration of `text`, nested or
    not, wherever its line breaks fall. A statement that starts with
    `message` or `enum` in any other shape, or with `service`, `extend` or
    `group`, is refused rather than skipped."""
    var t = _tokens(text)
    var out = List[String]()
    for i in range(len(t)):
        if i > 0 and t[i - 1] != "{" and t[i - 1] != "}" and t[i - 1] != ";":
            continue
        if t[i] == "service" or t[i] == "extend" or t[i] == "group":
            raise Error("the .proto declares a `" + t[i] + "`, which the census cannot classify")
        if t[i] != "message" and t[i] != "enum":
            continue
        if i + 2 >= len(t) or not _is_ident(t[i + 1]) or t[i + 2] != "{":
            var near = t[i + 1].copy() if i + 1 < len(t) else String("(end)")
            raise Error("a `" + t[i] + "` statement the declaration scan cannot classify, before `" + near + "`")
        if t[i] == kind:
            out.append(t[i + 1])
    return out^


# ---- the census rows, from the census files --------------------------------------


def _block(source: String, name: String, what: String, required: Bool) raises -> List[String]:
    """The non-empty lines of `source`'s `comptime <name> = \"\"\"` block."""
    var out = List[String]()
    var inside = False
    var closed = False
    var opener = "comptime " + name + ' = """'
    for raw in source.split("\n"):
        var line = String(String(raw).strip())
        if not inside:
            if line == opener:
                inside = True
            continue
        if line == '"""':
            closed = True
            break
        if line.byte_length() > 0:
            out.append(line)
    if inside and not closed:
        raise Error(what + ": the `" + name + "` block is not closed")
    if required and len(out) == 0:
        raise Error(what + ": no `comptime " + name + "` block with rows")
    return out^


def _ledger_rows(source: String, what: String) raises -> List[String]:
    """The `<Type>.<member>` of every row of `source`'s LEDGER block."""
    var out = List[String]()
    for line in _block(source, "LEDGER", what, True):
        var sp = line.find(" ")
        out.append(String(line[byte=0:sp]) if sp >= 0 else line)
    return out^


def _members(rows: List[String], type_name: String) -> List[String]:
    var out = List[String]()
    var prefix = type_name + "."
    for i in range(len(rows)):
        if rows[i].startswith(prefix):
            out.append(String(rows[i][byte = prefix.byte_length() : rows[i].byte_length()]))
    return out^


def _split(s: String, sep: String) -> List[String]:
    var out = List[String]()
    for p in s.split(sep):
        if p.byte_length() > 0:
            out.append(String(p))
    return out^


# ---- the comparisons -------------------------------------------------------------


def _compare_message(message: String, accepted: String, rows: List[String]) -> List[String]:
    """Each field group of `accepted` matched by exactly one census row of
    `message`, and each row by a group."""
    var problems = List[String]()
    var members = _members(rows, message)
    var used = List[Bool]()
    for _ in range(len(members)):
        used.append(False)
    for group in _split(accepted, ","):
        var spellings = _split(group, "|")
        var hits = 0
        for i in range(len(members)):
            for s in spellings:
                if members[i] == s:
                    hits += 1
                    used[i] = True
                    break
        if hits != 1:
            problems.append(
                "protoc declares field `" + group + "` of " + message + "; the census ledgers list it "
                + String(hits) + " times (want 1)"
            )
    for i in range(len(members)):
        if not used[i]:
            problems.append("the census ledgers list " + message + "." + members[i] + ", which protoc does not declare")
    return problems^


def _compare_one_hot(message: String, bools: List[String], one_hot: List[String]) -> List[String]:
    """`message` has a ONE_HOT row exactly when protoc declares two or more
    single bools in it, and the row lists exactly those bools."""
    var problems = List[String]()
    var row = List[String]()
    var found = 0
    for r in one_hot:
        var w = _split(r, " ")
        if len(w) > 0 and w[0] == message:
            found += 1
            row = List[String]()
            for i in range(1, len(w)):
                row.append(w[i])
    if found > 1:
        problems.append("the ONE_HOT rows list " + message + " " + String(found) + " times")
    var want = _join(bools) if len(bools) >= 2 else String("")
    var same = len(row) == len(bools) if len(bools) >= 2 else found == 0
    if same and len(bools) >= 2:
        for b in bools:
            var hit = False
            for x in row:
                for sp in _split(b, "|"):
                    if x == sp:
                        hit = True
            if not hit:
                same = False
    if not same:
        problems.append(
            "protoc declares the single bools `" + _join(bools) + "` of " + message
            + "; its ONE_HOT row is `" + _join(row) + "` (want `" + want + "`)"
        )
    return problems^


def _compare_enum(enum: String, known: String, rows: List[String]) -> List[String]:
    var problems = List[String]()
    var members = _members(rows, enum)
    var names = _split(known, ",")
    for n in names:
        var hits = 0
        for i in range(len(members)):
            if members[i] == n:
                hits += 1
        if hits != 1:
            problems.append(
                "protoc declares value " + enum + "." + n + "; the census ledgers list it "
                + String(hits) + " times (want 1)"
            )
    for i in range(len(members)):
        var found = False
        for n in names:
            if members[i] == n:
                found = True
        if not found:
            problems.append("the census ledgers list " + enum + "." + members[i] + ", which protoc does not declare")
    return problems^


def _census(proto_text: String, rows: List[String], one_hot: List[String]) raises -> List[String]:
    """Every problem with `rows` and `one_hot` against the types
    `proto_text` declares and the generated code's view of each."""
    var problems = List[String]()
    var types = List[String]()
    for m in _declared(proto_text, "message"):
        types.append(m)
        try:
            var shape = _fields_of(m)
            _append(problems, _compare_message(m, shape.accepted, rows))
            _append(problems, _compare_one_hot(m, shape.bools, one_hot))
        except e:
            problems.append("the .proto declares message " + m + ", which the census does not cover (" + String(e) + ")")
    for en in _declared(proto_text, "enum"):
        types.append(en)
        try:
            _append(problems, _compare_enum(en, _values_of(en), rows))
        except e:
            problems.append("the .proto declares enum " + en + ", which the census does not cover (" + String(e) + ")")
    for i in range(len(rows)):
        var dot = rows[i].find(".")
        var t = String(rows[i][byte=0:dot]) if dot >= 0 else rows[i]
        if not _in(types, t):
            problems.append("census row " + rows[i] + " names a type the .proto does not declare")
        for j in range(i):
            if rows[j] == rows[i]:
                problems.append("census row " + rows[i] + " is listed twice")
    for r in one_hot:
        var w = _split(r, " ")
        if len(w) == 0 or not _in(types, w[0]):
            problems.append("ONE_HOT row `" + r + "` names a message the .proto does not declare")
    return problems^


def _join(xs: List[String]) -> String:
    var out = String("")
    for i in range(len(xs)):
        out += (String(" ") if i > 0 else String("")) + xs[i]
    return out


def _in(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _append(mut out: List[String], more: List[String]):
    for i in range(len(more)):
        out.append(more[i])


def _report(problems: List[String]) -> String:
    var out = String("")
    for i in range(len(problems)):
        out += "\n  " + problems[i]
    return out


def _has(problems: List[String], needle: String) -> Bool:
    for i in range(len(problems)):
        if problems[i].find(needle) >= 0:
            return True
    return False


def _refuses(text: String, needle: String) -> Bool:
    """`_declared` raises on `text`, naming `needle`."""
    try:
        _ = _declared(text, "message")
    except e:
        return String(e).find(needle) >= 0
    return False


# ---- the test --------------------------------------------------------------------


def main() raises:
    var text = String("")
    var protos = 0
    for name in listdir("protos"):
        var f = String(name)
        assert_true(f.endswith(".proto"), "protos/ holds only the library's .proto srcs: " + f)
        text += Path("protos/" + f).read_text() + "\n"
        protos += 1
    assert_true(protos > 0, "no .proto staged under protos/")
    var rows = List[String]()
    var one_hot = List[String]()
    for f in _split(String(_CENSUS), " "):
        var source = Path("census/" + f).read_text()
        _append(rows, _ledger_rows(source, f))
        _append(one_hot, _block(source, "ONE_HOT", f, False))

    var problems = _census(text, rows, one_hot)
    assert_equal(len(problems), 0, "the plan census is incomplete:" + _report(problems))
    var messages = len(_declared(text, "message"))
    var enums = len(_declared(text, "enum"))

    # Planted defects, each of which must be reported.
    var fewer = List[String]()
    for i in range(len(rows)):
        if rows[i] != "WireColRef.side" and rows[i] != "ColSide.COL_SIDE_LEFT":
            fewer.append(rows[i])
    var missing = _census(text, fewer, one_hot)
    assert_true(_has(missing, "field `side` of WireColRef"), "a field with no row is reported" + _report(missing))
    assert_true(_has(missing, "value ColSide.COL_SIDE_LEFT"), "a value with no row is reported" + _report(missing))
    var extra = rows.copy()
    extra.append("WireColRef.colour")
    extra.append("ColSide.COL_SIDE_UP")
    extra.append("WireColRef.name")
    extra.append("WireNothing.x")
    extra.append("WireScanBinding.kindId")
    var stale = _census(text, extra, one_hot)
    assert_true(_has(stale, "WireColRef.colour, which protoc"), "a row with no field is reported" + _report(stale))
    assert_true(_has(stale, "ColSide.COL_SIDE_UP, which protoc"), "a row with no value is reported" + _report(stale))
    assert_true(_has(stale, "WireColRef.name is listed twice"), "a duplicate row is reported" + _report(stale))
    assert_true(
        _has(stale, "WireNothing.x names a type the .proto does not declare"),
        "a row naming an undeclared type is reported" + _report(stale),
    )
    assert_true(
        _has(stale, "field `kindId|kind_id` of WireScanBinding; the census ledgers list it 2 times"),
        "two rows spelling one field two ways are reported" + _report(stale),
    )
    var grown = _compare_message("WireColRef", _fields_of("WireColRef").accepted + ",colour", rows)
    assert_true(_has(grown, "field `colour` of WireColRef"), "a new field is reported" + _report(grown))
    var added = _census(text + "\nmessage WireAdded {\n  string x = 1;\n}\nenum Added {\n  ADDED_ZERO = 0;\n}\n", rows, one_hot)
    assert_true(_has(added, "message WireAdded"), "a new message is reported" + _report(added))
    assert_true(_has(added, "enum Added"), "a new enum is reported" + _report(added))
    var odd = _census(text + "\n}\tmessage\tWireTabbed {\n} message WireSameLine { }\n", rows, one_hot)
    assert_true(_has(odd, "message WireTabbed"), "a tab-separated declaration is read" + _report(odd))
    assert_true(_has(odd, "message WireSameLine"), "a declaration after `}` on one line is read" + _report(odd))
    assert_true(_refuses("message {\n}\n", "cannot classify"), "a declaration it cannot read is refused")
    assert_true(_refuses("service Plans {\n}\n", "service"), "a service is refused")
    assert_true(_refuses("/* x */ message A {\n}\n", "/* */"), "a block comment is refused")

    # ONE_HOT: a single bool protoc declares that the row lacks, and a row
    # for a message protoc does not declare.
    var shape = _fields_of("WireAggExpr")
    var more = shape.bools.copy()
    more.append("has_child4")
    var bool_added = _compare_one_hot("WireAggExpr", more, one_hot)
    assert_true(_has(bool_added, "has_child4` of WireAggExpr"), "a new single bool is reported" + _report(bool_added))
    var short_rows = List[String]()
    for r in one_hot:
        short_rows.append(r.copy() if not r.startswith("WireAggExpr ") else String("WireAggExpr has_child0 has_child1"))
    short_rows.append("WireNothing a b")
    var short = _census(text, rows, short_rows)
    assert_true(_has(short, "of WireAggExpr; its ONE_HOT row"), "a short ONE_HOT row is reported" + _report(short))
    assert_true(_has(short, "ONE_HOT row `WireNothing a b`"), "a ONE_HOT row naming nothing is reported" + _report(short))

    print(
        "THE komira.plan.v1 CENSUS IS COMPLETE:", len(rows), "rows and", len(one_hot), "one-hot rows over",
        messages, "messages and", enums, "enums in", protos, ".proto files"
    )
