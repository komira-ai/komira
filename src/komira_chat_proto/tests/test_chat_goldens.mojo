# =============================================================================
# komira_chat_proto/tests/test_chat_goldens.mojo
#   Every komira.chat.v1 message against its proto3-JSON golden and against
#   protoc's encoding of the same value.
# =============================================================================
#
# The inputs, both committed:
#   tests/goldens/chat_v1.golden     one line per message: its name, a space,
#                                    the canonical proto3 JSON of one value
#                                    with every field set.
#   tests/fixtures/corpus.canonical.hex
#                                    protoc's encoding of tests/fixtures/
#                                    corpus.txtpb, the same values as protoc
#                                    text: ChatCorpus field k+1 is the k-th
#                                    message. The package's `chat_corpus_fixture`
#                                    target re-derives these bytes with protoc
#                                    on every build and fails if they differ.
#
# What each test proves, per message, and the defect it catches:
#   test_json_goldens
#     1. the strict decoder reads the golden and the encoder writes it back
#        byte for byte: a renamed field or an added `json_name` changes a key,
#        and the strict decoder refuses the old key ("unknown field").
#     2. the value survives protobuf binary encode and decode: a field the
#        binary path drops comes back as its default and its key disappears.
#   test_protoc_corpus
#     3. this package decodes protoc's bytes for the value to the golden: a
#        changed field number (or wire type) leaves protoc's field unread.
#     4. this package encodes that value to protoc's bytes exactly.
#   test_every_message_has_a_golden_and_a_corpus_field
#     the golden file names exactly the messages chat.proto declares, in
#     declaration order, and the corpus has one field per message: a message
#     added to chat.proto without a golden line (or one moved) is reported by
#     name. The declarations are found by a token scan (past comments and
#     strings, counting braces), not by line prefix: a `message <Name> {`
#     inside another message's braces is refused as nested, by line, wherever
#     it sits on its line and whatever protoc skips between its tokens
#     (spaces, tabs, newlines, CR, \v, \f, `//` and `/* */` comments); a
#     top-level one not written `message <Name> {` at column 0 is refused
#     too. Tests 1-4 then hold `_check_all` to the golden order, so a
#     message with a golden line but no `_check` call fails there.
#   test_protoc_accepted_the_corpus
#     the report of `chat_corpus_fixture` is staged: protoc decoded the
#     committed bytes to corpus.txtpb and encoded corpus.txtpb to them.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_proto_codec import (
    Serializable,
    decode_json,
    decode_proto,
    encode_json,
    encode_proto,
)

from komira_chat_proto.chat import (
    AddMembersRequest,
    AddMembersResponse,
    ApiError,
    Channel,
    ChannelSync,
    CompleteUploadRequest,
    CompleteUploadResponse,
    CreateChannelRequest,
    CreateChannelResponse,
    CreateUploadRequest,
    CreateUploadResponse,
    DeleteMessageRequest,
    DeleteMessageResponse,
    EditMessageRequest,
    EditMessageResponse,
    EraseSubjectRequest,
    EraseSubjectResponse,
    FileInfo,
    GetChannelRequest,
    GetChannelResponse,
    GetDownloadUrlRequest,
    GetDownloadUrlResponse,
    GetMeRequest,
    GetMeResponse,
    GetUserRequest,
    GetUserResponse,
    HttpHeader,
    JoinChannelRequest,
    JoinChannelResponse,
    LeaveChannelRequest,
    LeaveChannelResponse,
    ListChannelsRequest,
    ListChannelsResponse,
    ListMembersRequest,
    ListMembersResponse,
    ListMentionsRequest,
    ListMentionsResponse,
    ListMessagesRequest,
    ListMessagesResponse,
    ListThreadRequest,
    ListThreadResponse,
    ListUsersRequest,
    ListUsersResponse,
    MarkReadRequest,
    MarkReadResponse,
    Member,
    Message,
    OpenDmRequest,
    OpenDmResponse,
    ReadState,
    RemoveMemberRequest,
    RemoveMemberResponse,
    SearchMessagesRequest,
    SearchMessagesResponse,
    SendMessageRequest,
    SendMessageResponse,
    Subject,
    SyncRequest,
    SyncResponse,
    UpdateChannelRequest,
    UpdateChannelResponse,
    User,
)


comptime _GOLDENS: String = "src/komira_chat_proto/tests/goldens/chat_v1.golden"
comptime _CORPUS: String = "src/komira_chat_proto/tests/fixtures/corpus.canonical.hex"
# The report of the package's `chat_corpus_fixture` target (protoc's check of
# the corpus), staged as test data.
comptime _PROTOC_REPORT: String = "src/komira_chat_proto/tests/fixtures/corpus_protoc_check.txt"
# The package's own chat.proto, staged as test data.
comptime _PROTO: String = "src/komira_chat_proto/chat.proto"

# The number of `_check` calls in `_check_all`. The golden file is held to
# chat.proto's messages by `test_every_message_has_a_golden_and_a_corpus_field`
# and `_check_all` is held to the golden file by `_check`, so this is also the
# number of messages chat.proto declares.
comptime _MESSAGES: Int = 62

comptime _LEG_JSON: Int = 0
comptime _LEG_PROTOC: Int = 1


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


@fieldwise_init
struct Goldens(Movable):
    var names: List[String]
    var jsons: List[String]


def _load_goldens() raises -> Goldens:
    """The golden lines in file order; `#` lines and empty lines are skipped."""
    var text = _read(_GOLDENS)
    var g = Goldens(List[String](), List[String]())
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i < len(b) and b[i] != UInt8(ord("\n")):
            continue
        var line = String(text[byte=start:i])
        start = i + 1
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var sp = line.find(" ")
        if sp <= 0:
            raise Error("chat golden: a line without `<name> <json>`: " + line)
        g.names.append(String(line[byte=0:sp]))
        g.jsons.append(String(line[byte=sp + 1 : line.byte_length()]))
    return g^


def _is_ident(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("_"))
    )


def _is_space(c: UInt8) -> Bool:
    return (
        c == UInt8(ord(" "))
        or c == UInt8(ord("\t"))
        or c == UInt8(ord("\n"))
        or c == UInt8(ord("\r"))
        or c == UInt8(11)  # \v
        or c == UInt8(12)  # \f
    )


def _skip_trivia(text: String, at: Int) -> Int:
    """The first byte at or after `at` that is not whitespace or a comment,
    as protoc's tokenizer skips them: space, tab, newline, CR, \\v, \\f,
    `// ...` to the end of the line and `/* ... */`. An unclosed `/*` runs
    to the end (the main scan raises on it)."""
    var b = text.as_bytes()
    var n = len(b)
    var j = at
    while j < n:
        if _is_space(b[j]):
            j += 1
            continue
        if b[j] == UInt8(ord("/")) and j + 1 < n and b[j + 1] == UInt8(ord("/")):
            while j < n and b[j] != UInt8(ord("\n")):
                j += 1
            continue
        if b[j] == UInt8(ord("/")) and j + 1 < n and b[j + 1] == UInt8(ord("*")):
            j += 2
            while j + 1 < n and not (
                b[j] == UInt8(ord("*")) and b[j + 1] == UInt8(ord("/"))
            ):
                j += 1
            j = min(j + 2, n)
            continue
        break
    return j


def _line_of(text: String, at: Int) -> String:
    """`line N: <text>` for the line of chat.proto holding byte `at`."""
    var b = text.as_bytes()
    var start = at
    while start > 0 and b[start - 1] != UInt8(ord("\n")):
        start -= 1
    var end = at
    while end < len(b) and b[end] != UInt8(ord("\n")):
        end += 1
    var n = 1
    for i in range(start):
        if b[i] == UInt8(ord("\n")):
            n += 1
    return "line " + String(n) + ": " + String(text[byte=start:end])


def _proto_message_names() raises -> List[String]:
    """The names of the messages chat.proto declares, in declaration order.

    A token scan over the whole file, past `//` and `/* */` comments and
    quoted strings, counting braces. Every `message` keyword followed by
    trivia, an identifier, trivia and `{` is a declaration, wherever it sits
    on a line; trivia is what protoc skips between tokens (`_skip_trivia`:
    space, tab, newline, CR, \\v, \\f, `//` and `/* */` comments). One
    at brace depth 0, at column 0, written exactly `message <Name> {` (one
    space each side of the name, no comment), is a top-level message and
    is returned. Any other declaration raises, naming the line: inside
    braces it is a nested message, which no golden line can name; at depth
    0 in another layout it is refused so the declaration form stays one the
    reader can check.
    A `message` that is not followed by `<Name> {` (the field
    `string message = 2;`, the type `Message message = 1;`) is not a
    declaration."""
    var text = _read(_PROTO)
    var b = text.as_bytes()
    var names = List[String]()
    var depth = 0
    var i = 0
    var n = len(b)
    while i < n:
        var c = b[i]
        if c == UInt8(ord("/")) and i + 1 < n and b[i + 1] == UInt8(ord("/")):
            while i < n and b[i] != UInt8(ord("\n")):
                i += 1
            continue
        if c == UInt8(ord("/")) and i + 1 < n and b[i + 1] == UInt8(ord("*")):
            i += 2
            while i + 1 < n and not (
                b[i] == UInt8(ord("*")) and b[i + 1] == UInt8(ord("/"))
            ):
                i += 1
            if i + 1 >= n:
                raise Error("chat.proto: a `/*` comment is not closed")
            i += 2
            continue
        if c == UInt8(ord('"')) or c == UInt8(ord("'")):
            var q = c
            i += 1
            while i < n and b[i] != q:
                if b[i] == UInt8(ord("\\")):
                    i += 1
                i += 1
            if i >= n:
                raise Error("chat.proto: a string is not closed")
            i += 1
            continue
        if c == UInt8(ord("{")):
            depth += 1
            i += 1
            continue
        if c == UInt8(ord("}")):
            depth -= 1
            if depth < 0:
                raise Error("chat.proto: a `}` closes nothing: " + _line_of(text, i))
            i += 1
            continue
        if not _is_ident(c):
            i += 1
            continue
        var word_start = i
        while i < n and _is_ident(b[i]):
            i += 1
        if String(text[byte=word_start:i]) != "message":
            continue
        # `message` + trivia + identifier + trivia + `{`? Trivia is what
        # protoc skips between tokens: whitespace and comments.
        var j = _skip_trivia(text, i)
        if j == i or j >= n or not _is_ident(b[j]):
            continue
        var name_start = j
        while j < n and _is_ident(b[j]):
            j += 1
        var name_end = j
        j = _skip_trivia(text, j)
        if j >= n or b[j] != UInt8(ord("{")):
            continue
        var canonical = (
            (word_start == 0 or b[word_start - 1] == UInt8(ord("\n")))
            and name_start == i + 1
            and b[i] == UInt8(ord(" "))
            and j == name_end + 1
            and b[name_end] == UInt8(ord(" "))
        )
        if depth > 0:
            raise Error(
                "chat.proto: a nested message has no golden line; declare it"
                + " at top level: "
                + _line_of(text, word_start)
            )
        if not canonical:
            raise Error(
                "chat.proto: a message declared other than `message <Name> {`"
                + " at column 0: "
                + _line_of(text, word_start)
            )
        names.append(String(text[byte=name_start:name_end]))
        i = j  # the `{` is counted on the next pass
    return names^


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    raise Error("chat corpus: a non-hex character (byte " + String(Int(c)) + ")")


def _from_hex(text: String) raises -> List[UInt8]:
    """The bytes of a `.hex` fixture (lowercase digits; whitespace ignored)."""
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord(" ")) or c == UInt8(ord("\n")) or c == UInt8(ord("\t")):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) % 2 != 0:
        raise Error("chat corpus: an odd number of hex digits")
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _to_hex(bytes: List[UInt8]) -> String:
    comptime DIGITS = String("0123456789abcdef")
    var out = String("")
    for i in range(len(bytes)):
        out += String(DIGITS[byte = Int(bytes[i] >> 4)])
        out += String(DIGITS[byte = Int(bytes[i] & 0xF)])
    return out^


def _varint(bytes: List[UInt8], mut pos: Int) raises -> Int:
    var v = 0
    var shift = 0
    while True:
        if pos >= len(bytes):
            raise Error("chat corpus: a varint runs past the end")
        var c = bytes[pos]
        pos += 1
        v |= Int(c & 0x7F) << shift
        if c < 0x80:
            return v
        shift += 7
        if shift > 63:
            raise Error("chat corpus: a varint longer than 10 bytes")


def _corpus_fields() raises -> List[List[UInt8]]:
    """The payload of each ChatCorpus field, in order. Every field must be
    length-delimited and the fields must be 1, 2, 3, ... each once, so entry
    k is field k+1's bytes."""
    var bytes = _from_hex(_read(_CORPUS))
    var out = List[List[UInt8]]()
    var pos = 0
    while pos < len(bytes):
        var tag = _varint(bytes, pos)
        var field_no = tag >> 3
        if tag & 7 != 2:
            raise Error(
                "chat corpus: field " + String(field_no) + " is not length-delimited"
            )
        if field_no != len(out) + 1:
            raise Error(
                "chat corpus: field "
                + String(field_no)
                + " where field "
                + String(len(out) + 1)
                + " was expected"
            )
        var n = _varint(bytes, pos)
        if pos + n > len(bytes):
            raise Error("chat corpus: field " + String(field_no) + " runs past the end")
        var payload = List[UInt8]()
        for i in range(pos, pos + n):
            payload.append(bytes[i])
        out.append(payload^)
        pos += n
    return out^


def _check[
    T: Serializable & ImplicitlyDestructible
](
    leg: Int,
    k: Int,
    name: String,
    g: Goldens,
    wire: List[List[UInt8]],
    mut checked: Int,
) raises:
    assert_equal(k, checked, name + ": `_check_all` lists the messages in order, none skipped")
    checked += 1
    assert_equal(g.names[k], name, "golden line " + String(k) + " names the message")
    var golden = g.jsons[k]
    if leg == _LEG_JSON:
        var m = decode_json[T](golden)
        assert_equal(encode_json(m), golden, name + ": decode then encode of the golden")
        var back = decode_proto[T](encode_proto(m))
        assert_equal(encode_json(back), golden, name + ": protobuf binary round trip")
    else:
        var from_protoc = decode_proto[T](wire[k].copy())
        assert_equal(
            encode_json(from_protoc),
            golden,
            name + ": protoc's bytes (ChatCorpus field " + String(k + 1) + ") decode to the golden",
        )
        assert_equal(
            _to_hex(encode_proto(from_protoc)),
            _to_hex(wire[k]),
            name + ": this encoder writes protoc's bytes",
        )


def _check_all(leg: Int, g: Goldens, wire: List[List[UInt8]]) raises -> Int:
    """Checks every message, in the order chat.proto declares them; returns
    how many it checked."""
    var n = 0
    _check[Subject](leg, 0, "Subject", g, wire, n)
    _check[User](leg, 1, "User", g, wire, n)
    _check[Channel](leg, 2, "Channel", g, wire, n)
    _check[Member](leg, 3, "Member", g, wire, n)
    _check[Message](leg, 4, "Message", g, wire, n)
    _check[FileInfo](leg, 5, "FileInfo", g, wire, n)
    _check[ReadState](leg, 6, "ReadState", g, wire, n)
    _check[HttpHeader](leg, 7, "HttpHeader", g, wire, n)
    _check[ApiError](leg, 8, "ApiError", g, wire, n)
    _check[GetMeRequest](leg, 9, "GetMeRequest", g, wire, n)
    _check[GetMeResponse](leg, 10, "GetMeResponse", g, wire, n)
    _check[GetUserRequest](leg, 11, "GetUserRequest", g, wire, n)
    _check[GetUserResponse](leg, 12, "GetUserResponse", g, wire, n)
    _check[ListUsersRequest](leg, 13, "ListUsersRequest", g, wire, n)
    _check[ListUsersResponse](leg, 14, "ListUsersResponse", g, wire, n)
    _check[CreateChannelRequest](leg, 15, "CreateChannelRequest", g, wire, n)
    _check[CreateChannelResponse](leg, 16, "CreateChannelResponse", g, wire, n)
    _check[GetChannelRequest](leg, 17, "GetChannelRequest", g, wire, n)
    _check[GetChannelResponse](leg, 18, "GetChannelResponse", g, wire, n)
    _check[ListChannelsRequest](leg, 19, "ListChannelsRequest", g, wire, n)
    _check[ListChannelsResponse](leg, 20, "ListChannelsResponse", g, wire, n)
    _check[UpdateChannelRequest](leg, 21, "UpdateChannelRequest", g, wire, n)
    _check[UpdateChannelResponse](leg, 22, "UpdateChannelResponse", g, wire, n)
    _check[JoinChannelRequest](leg, 23, "JoinChannelRequest", g, wire, n)
    _check[JoinChannelResponse](leg, 24, "JoinChannelResponse", g, wire, n)
    _check[LeaveChannelRequest](leg, 25, "LeaveChannelRequest", g, wire, n)
    _check[LeaveChannelResponse](leg, 26, "LeaveChannelResponse", g, wire, n)
    _check[AddMembersRequest](leg, 27, "AddMembersRequest", g, wire, n)
    _check[AddMembersResponse](leg, 28, "AddMembersResponse", g, wire, n)
    _check[RemoveMemberRequest](leg, 29, "RemoveMemberRequest", g, wire, n)
    _check[RemoveMemberResponse](leg, 30, "RemoveMemberResponse", g, wire, n)
    _check[ListMembersRequest](leg, 31, "ListMembersRequest", g, wire, n)
    _check[ListMembersResponse](leg, 32, "ListMembersResponse", g, wire, n)
    _check[OpenDmRequest](leg, 33, "OpenDmRequest", g, wire, n)
    _check[OpenDmResponse](leg, 34, "OpenDmResponse", g, wire, n)
    _check[SendMessageRequest](leg, 35, "SendMessageRequest", g, wire, n)
    _check[SendMessageResponse](leg, 36, "SendMessageResponse", g, wire, n)
    _check[EditMessageRequest](leg, 37, "EditMessageRequest", g, wire, n)
    _check[EditMessageResponse](leg, 38, "EditMessageResponse", g, wire, n)
    _check[DeleteMessageRequest](leg, 39, "DeleteMessageRequest", g, wire, n)
    _check[DeleteMessageResponse](leg, 40, "DeleteMessageResponse", g, wire, n)
    _check[ListMessagesRequest](leg, 41, "ListMessagesRequest", g, wire, n)
    _check[ListMessagesResponse](leg, 42, "ListMessagesResponse", g, wire, n)
    _check[ListThreadRequest](leg, 43, "ListThreadRequest", g, wire, n)
    _check[ListThreadResponse](leg, 44, "ListThreadResponse", g, wire, n)
    _check[ListMentionsRequest](leg, 45, "ListMentionsRequest", g, wire, n)
    _check[ListMentionsResponse](leg, 46, "ListMentionsResponse", g, wire, n)
    _check[MarkReadRequest](leg, 47, "MarkReadRequest", g, wire, n)
    _check[MarkReadResponse](leg, 48, "MarkReadResponse", g, wire, n)
    _check[SyncRequest](leg, 49, "SyncRequest", g, wire, n)
    _check[ChannelSync](leg, 50, "ChannelSync", g, wire, n)
    _check[SyncResponse](leg, 51, "SyncResponse", g, wire, n)
    _check[CreateUploadRequest](leg, 52, "CreateUploadRequest", g, wire, n)
    _check[CreateUploadResponse](leg, 53, "CreateUploadResponse", g, wire, n)
    _check[CompleteUploadRequest](leg, 54, "CompleteUploadRequest", g, wire, n)
    _check[CompleteUploadResponse](leg, 55, "CompleteUploadResponse", g, wire, n)
    _check[GetDownloadUrlRequest](leg, 56, "GetDownloadUrlRequest", g, wire, n)
    _check[GetDownloadUrlResponse](leg, 57, "GetDownloadUrlResponse", g, wire, n)
    _check[SearchMessagesRequest](leg, 58, "SearchMessagesRequest", g, wire, n)
    _check[SearchMessagesResponse](leg, 59, "SearchMessagesResponse", g, wire, n)
    _check[EraseSubjectRequest](leg, 60, "EraseSubjectRequest", g, wire, n)
    _check[EraseSubjectResponse](leg, 61, "EraseSubjectResponse", g, wire, n)
    return n


def test_json_goldens() raises:
    var g = _load_goldens()
    assert_equal(_check_all(_LEG_JSON, g, List[List[UInt8]]()), _MESSAGES, "messages checked")


def test_protoc_corpus() raises:
    var g = _load_goldens()
    assert_equal(_check_all(_LEG_PROTOC, g, _corpus_fields()), _MESSAGES, "messages checked")


def test_every_message_has_a_golden_and_a_corpus_field() raises:
    var g = _load_goldens()
    var declared = _proto_message_names()
    for k in range(min(len(declared), len(g.names))):
        assert_equal(
            g.names[k],
            declared[k],
            "golden line " + String(k) + " names chat.proto's message " + String(k),
        )
    for k in range(len(g.names), len(declared)):
        raise Error("chat.proto declares " + declared[k] + ", which has no golden line")
    for k in range(len(declared), len(g.names)):
        raise Error("golden line names " + g.names[k] + ", which chat.proto does not declare")
    assert_equal(len(g.names), _MESSAGES, "golden lines")
    assert_equal(len(_corpus_fields()), _MESSAGES, "corpus fields")


def test_protoc_accepted_the_corpus() raises:
    var report = _read(_PROTOC_REPORT)
    assert_true(
        report.find("\nPASS corpus komira.chat.v1.corpus.ChatCorpus: ") >= 0,
        "protoc's corpus check report: " + report,
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_json_goldens]()
    suite.test[test_protoc_corpus]()
    suite.test[test_every_message_has_a_golden_and_a_corpus_field]()
    suite.test[test_protoc_accepted_the_corpus]()
    suite^.run()
