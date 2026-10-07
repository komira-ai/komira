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
# vocabulary (`_Vocab`), and reads each enum's names. The generated code
# carries no list of the messages and enums themselves, so that list is read
# from the .proto text: every `message <Name> {` and `enum <Name> {` line,
# nested or not. A declared type the census does not know fails (`_fields_of`
# and `_values_of` raise for it), as does a census type the .proto does not
# declare.
#
# WHERE THE ROWS COME FROM. Each census file keeps its rows in one
# `comptime LEDGER = """ ... """` block, the same rows its own tests write
# bytes from (and fail on if one is not written). The census files are staged
# as data and their blocks read here, so a row exists in exactly one place.
# The numbers are not compared here: protoc's numbers are what the census
# files pin, against the bytes.
#
# The checks are also run over planted defects (a field protoc declares
# that no row lists, a row naming a field protoc does not declare, an enum
# value without a row, a new message in the .proto text), and each must be
# reported, so a comparison that cannot fail fails the build.
# =============================================================================

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
    ExcelErrorCode,
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


# The census files, staged under `census/`, and the .proto files.
comptime _CENSUS = (
    "test_plan_field_numbers_scan.mojo test_plan_field_numbers_expr.mojo"
    + " test_plan_field_numbers_plan.mojo test_plan_enum_numbers_nodes.mojo"
    + " test_plan_enum_numbers_functions.mojo"
)
comptime _PROTOS = "plan.proto plan_vocabulary.proto"


# ---- protoc's vocabulary, through the generated code -----------------------------


struct _Vocab(WireDecoder):
    """A decoder that holds no message: it records the field vocabulary a
    generated `decode` declares, then reports the end of the message. Every
    read is unreachable, since `next_field` yields no field."""

    var accepted: String

    def __init__(out self):
        self.accepted = String("")

    def next_field(mut self) raises -> FieldKey:
        return FieldKey.at_end()

    def expect_fields(mut self, message_name: StringSlice, accepted: StringSlice) raises:
        self.accepted = String(accepted)

    def keep_null_fields(mut self, spellings: StringSlice):
        pass

    def skip(mut self) raises:
        raise Error("_Vocab yields no field to skip")

    def read_string(mut self) raises -> String:
        raise Error("unreachable")

    def read_bytes(mut self) raises -> List[UInt8]:
        raise Error("unreachable")

    def read_i64(mut self) raises -> Int64:
        raise Error("unreachable")

    def read_i32(mut self) raises -> Int32:
        raise Error("unreachable")

    def read_u64(mut self) raises -> UInt64:
        raise Error("unreachable")

    def read_u32(mut self) raises -> UInt32:
        raise Error("unreachable")

    def read_f64(mut self) raises -> Float64:
        raise Error("unreachable")

    def read_f32(mut self) raises -> Float32:
        raise Error("unreachable")

    def read_sint64(mut self) raises -> Int64:
        raise Error("unreachable")

    def read_sint32(mut self) raises -> Int32:
        raise Error("unreachable")

    def read_fixed64(mut self) raises -> UInt64:
        raise Error("unreachable")

    def read_fixed32(mut self) raises -> UInt32:
        raise Error("unreachable")

    def read_sfixed64(mut self) raises -> Int64:
        raise Error("unreachable")

    def read_sfixed32(mut self) raises -> Int32:
        raise Error("unreachable")

    def read_bool(mut self) raises -> Bool:
        raise Error("unreachable")

    def read_enum[En: ProtoEnum](mut self) raises -> En:
        raise Error("unreachable")

    def read_message[M: Serializable](mut self) raises -> M:
        raise Error("unreachable")

    def read_into_repeated_string(mut self, mut out: List[String]) raises:
        raise Error("unreachable")

    def read_into_repeated_i64(mut self, mut out: List[Int64]) raises:
        raise Error("unreachable")

    def read_into_repeated_i32(mut self, mut out: List[Int32]) raises:
        raise Error("unreachable")

    def read_into_repeated_u64(mut self, mut out: List[UInt64]) raises:
        raise Error("unreachable")

    def read_into_repeated_u32(mut self, mut out: List[UInt32]) raises:
        raise Error("unreachable")

    def read_into_repeated_f64(mut self, mut out: List[Float64]) raises:
        raise Error("unreachable")

    def read_into_repeated_f32(mut self, mut out: List[Float32]) raises:
        raise Error("unreachable")

    def read_into_repeated_sint64(mut self, mut out: List[Int64]) raises:
        raise Error("unreachable")

    def read_into_repeated_sint32(mut self, mut out: List[Int32]) raises:
        raise Error("unreachable")

    def read_into_repeated_fixed64(mut self, mut out: List[UInt64]) raises:
        raise Error("unreachable")

    def read_into_repeated_fixed32(mut self, mut out: List[UInt32]) raises:
        raise Error("unreachable")

    def read_into_repeated_sfixed64(mut self, mut out: List[Int64]) raises:
        raise Error("unreachable")

    def read_into_repeated_sfixed32(mut self, mut out: List[Int32]) raises:
        raise Error("unreachable")

    def read_into_repeated_bool(mut self, mut out: List[Bool]) raises:
        raise Error("unreachable")

    def read_into_repeated_enum[En: ProtoEnum](mut self, mut out: List[En]) raises:
        raise Error("unreachable")

    def read_into_repeated_message[M: Serializable](mut self, mut out: List[M]) raises:
        raise Error("unreachable")

    def read_into_string_string_map(mut self, mut out: Dict[String, String]) raises:
        raise Error("unreachable")

    def read_into_string_i32_map(mut self, mut out: Dict[String, Int32]) raises:
        raise Error("unreachable")

    def read_into_string_i64_map(mut self, mut out: Dict[String, Int64]) raises:
        raise Error("unreachable")

    def read_into_i64_string_map(mut self, mut out: Dict[Int64, String]) raises:
        raise Error("unreachable")

    def read_into_string_message_map[
        V: Serializable & Deinitable
    ](mut self, mut out: Dict[String, V]) raises:
        raise Error("unreachable")


def _vocabulary[M: Serializable & ImplicitlyDestructible]() raises -> String:
    var d = _Vocab()
    _ = M.decode[_Vocab](d)
    if d.accepted.byte_length() == 0:
        raise Error("a generated decoder declared no field vocabulary")
    return d.accepted


def _fields_of(message: String) raises -> String:
    """protoc's field vocabulary of `message`, as the generated decoder
    declares it (`expect_fields`), or raise for a message this census does
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
    elif enum == "ExcelErrorCode":
        return ExcelErrorCode.known_json_names()
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


def _declared(text: String, kind: String) -> List[String]:
    """The name of every `<kind> <Name> {` line of `text`, comments aside."""
    var out = List[String]()
    var prefix = kind + " "
    for raw in text.split("\n"):
        var line = String(raw)
        var c = line.find("//")
        var kept = String(line[byte=0:c]) if c >= 0 else line
        var code = String(kept.strip())
        if not code.startswith(prefix):
            continue
        var rest = String(code[byte = prefix.byte_length() : code.byte_length()])
        var end = rest.find(" ")
        if end < 0:
            end = rest.find("{")
        if end < 0:
            end = rest.byte_length()
        out.append(String(rest[byte=0:end]))
    return out^


# ---- the census rows, from the census files --------------------------------------


def _ledger_rows(source: String, what: String) raises -> List[String]:
    """The `<Type>.<member>` of every row of `source`'s LEDGER block."""
    var out = List[String]()
    var inside = False
    var closed = False
    for raw in source.split("\n"):
        var line = String(String(raw).strip())
        if not inside:
            if line == 'comptime LEDGER = """':
                inside = True
            continue
        if line == '"""':
            closed = True
            break
        if line.byte_length() == 0:
            continue
        var sp = line.find(" ")
        out.append(String(line[byte=0:sp]) if sp >= 0 else line)
    if not closed or len(out) == 0:
        raise Error(what + ": no `comptime LEDGER` block with rows")
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


def _census(proto_text: String, rows: List[String]) -> List[String]:
    """Every problem with `rows` against the types `proto_text` declares and
    the vocabulary the generated code holds for each."""
    var problems = List[String]()
    var types = List[String]()
    for m in _declared(proto_text, "message"):
        types.append(m)
        try:
            _append(problems, _compare_message(m, _fields_of(m), rows))
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
        var known = False
        for k in range(len(types)):
            if types[k] == t:
                known = True
        if not known:
            problems.append("census row " + rows[i] + " names a type the .proto does not declare")
        for j in range(i):
            if rows[j] == rows[i]:
                problems.append("census row " + rows[i] + " is listed twice")
    return problems^


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


# ---- the test --------------------------------------------------------------------


def main() raises:
    var text = String("")
    for f in _split(String(_PROTOS), " "):
        text += Path(f).read_text() + "\n"
    var rows = List[String]()
    for f in _split(String(_CENSUS), " "):
        _append(rows, _ledger_rows(Path("census/" + f).read_text(), f))

    var problems = _census(text, rows)
    assert_equal(len(problems), 0, "the plan census is incomplete:" + _report(problems))
    var messages = len(_declared(text, "message"))
    var enums = len(_declared(text, "enum"))

    # Planted defects, each of which must be reported.
    var fewer = List[String]()
    for i in range(len(rows)):
        if rows[i] != "WireColRef.side" and rows[i] != "ColSide.COL_SIDE_LEFT":
            fewer.append(rows[i])
    var missing = _census(text, fewer)
    assert_true(_has(missing, "field `side` of WireColRef"), "a field with no row is reported" + _report(missing))
    assert_true(_has(missing, "value ColSide.COL_SIDE_LEFT"), "a value with no row is reported" + _report(missing))
    var extra = rows.copy()
    extra.append("WireColRef.colour")
    extra.append("ColSide.COL_SIDE_UP")
    extra.append("WireColRef.name")
    var stale = _census(text, extra)
    assert_true(_has(stale, "WireColRef.colour, which protoc"), "a row with no field is reported" + _report(stale))
    assert_true(_has(stale, "ColSide.COL_SIDE_UP, which protoc"), "a row with no value is reported" + _report(stale))
    assert_true(_has(stale, "WireColRef.name is listed twice"), "a duplicate row is reported" + _report(stale))
    var grown = _compare_message("WireColRef", _fields_of("WireColRef") + ",colour", rows)
    assert_true(_has(grown, "field `colour` of WireColRef"), "a new field is reported" + _report(grown))
    var added = _census(text + "\nmessage WireAdded {\n  string x = 1;\n}\nenum Added {\n  ADDED_ZERO = 0;\n}\n", rows)
    assert_true(_has(added, "message WireAdded"), "a new message is reported" + _report(added))
    assert_true(_has(added, "enum Added"), "a new enum is reported" + _report(added))

    print(
        "THE komira.plan.v1 CENSUS IS COMPLETE:", len(rows), "rows over", messages, "messages and", enums, "enums"
    )
