# =============================================================================
# komira_managed_mail_proto/tests/test_mail_goldens.mojo
#   Every komira.managed_mail.v1 message against its proto3-JSON golden and
#   against protoc's encoding of the same value.
# =============================================================================
#
# The inputs:
#   tests/goldens/mail_v1.golden     committed; one line per message: its
#                                    name, a space, the canonical proto3 JSON
#                                    of one value with every field set.
#   tests/fixtures/corpus.canonical.hex
#                                    committed; protoc's encoding of
#                                    tests/fixtures/corpus.txtpb, the same
#                                    values as protoc text: MailCorpus field
#                                    k+1 is the k-th message.
#   tests/fixtures/corpus.protoc.hex made in this build by the package's
#                                    `corpus_canonical` target: protoc's
#                                    encoding of corpus.txtpb under the
#                                    mail.proto being built.
#   mail.proto                       the package's own schema.
#
# What each test proves, per message, and the defect it catches:
#   test_json_goldens
#     1. the strict decoder reads the golden and the encoder writes it back
#        byte for byte: a renamed field or an added `json_name` changes a key,
#        and the strict decoder refuses the old key ("unknown field").
#     2. the value survives protobuf binary encode and decode: a field the
#        binary path drops comes back as its default and its key disappears.
#   test_protoc_corpus
#     3. this package decodes the committed protoc bytes for the value to the
#        golden: a changed field number (or wire type) leaves the committed
#        field unread, so its key is missing from the decode.
#     4. this package encodes that value to the committed bytes exactly.
#   test_protoc_still_writes_the_committed_bytes
#     5. protoc's encoding of corpus.txtpb under the schema being built is the
#        committed corpus.canonical.hex, message by message: a renumbered
#        field, a changed type, or a corpus.txtpb edited without regenerating
#        the bytes is reported with the message's name.
#   test_every_message_has_a_golden_and_a_corpus_field
#     the golden file names exactly the messages mail.proto declares, in
#     declaration order, and the corpus has one field per message: a message
#     added to mail.proto without a golden line (or one moved) is reported by
#     name. The declarations are found by a token scan (past comments and
#     strings, counting braces), not by line prefix: a `message <Name> {`
#     inside another message's braces is refused as nested, by line; a
#     top-level one not written `message <Name> {` at column 0 is refused
#     too. Tests 1-4 then hold `_check_all` to the golden order, so a message
#     with a golden line but no `_check` call fails there.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_proto_codec import (
    Serializable,
    decode_json,
    decode_proto,
    encode_json,
    encode_proto,
)

from komira_managed_mail_proto.mail import (
    ApiError,
    Attachment,
    CreateMailboxRequest,
    CreateMailboxResponse,
    DeleteMailboxRequest,
    DeleteMailboxResponse,
    Email,
    EmailAddress,
    EmailPart,
    Envelope,
    EraseSubjectRequest,
    EraseSubjectResponse,
    ErrorResponse,
    ExportMailboxRequest,
    GetEmailPartRequest,
    GetEmailRawRequest,
    GetEmailRequest,
    GetEmailResponse,
    GetSubmissionRequest,
    GetSubmissionResponse,
    GetThreadRequest,
    GetThreadResponse,
    InboundDelivery,
    InboundDeliveryResponse,
    InboundEnvelope,
    ListEmailsRequest,
    ListEmailsResponse,
    ListMailboxesRequest,
    ListMailboxesResponse,
    Mailbox,
    RawBodyReply,
    RawMessageRequest,
    RawMessageResponse,
    SendEmailRequest,
    SendEmailResponse,
    Submission,
    Subject,
    Thread,
    UpdateEmailRequest,
    UpdateEmailResponse,
)


comptime _GOLDENS: String = "src/komira_managed_mail_proto/tests/goldens/mail_v1.golden"
# The committed protoc encoding of tests/fixtures/corpus.txtpb.
comptime _CORPUS: String = "src/komira_managed_mail_proto/tests/fixtures/corpus.canonical.hex"
# protoc's encoding of the same text in this build (`:corpus_canonical`).
comptime _PROTOC_NOW: String = "src/komira_managed_mail_proto/tests/fixtures/corpus.protoc.hex"
# The package's own mail.proto, staged as test data.
comptime _PROTO: String = "src/komira_managed_mail_proto/mail.proto"

# The number of `_check` calls in `_check_all`. The golden file is held to
# mail.proto's messages by `test_every_message_has_a_golden_and_a_corpus_field`
# and `_check_all` is held to the golden file by `_check`, so this is also the
# number of messages mail.proto declares.
comptime _MESSAGES: Int = 40

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
            raise Error("mail golden: a line without `<name> <json>`: " + line)
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
    """`line N: <text>` for the line of mail.proto holding byte `at`."""
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
    """The names of the messages mail.proto declares, in declaration order.

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
                raise Error("mail.proto: a `/*` comment is not closed")
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
                raise Error("mail.proto: a string is not closed")
            i += 1
            continue
        if c == UInt8(ord("{")):
            depth += 1
            i += 1
            continue
        if c == UInt8(ord("}")):
            depth -= 1
            if depth < 0:
                raise Error("mail.proto: a `}` closes nothing: " + _line_of(text, i))
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
                "mail.proto: a nested message has no golden line; declare it"
                + " at top level: "
                + _line_of(text, word_start)
            )
        if not canonical:
            raise Error(
                "mail.proto: a message declared other than `message <Name> {`"
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
    raise Error("mail corpus: a non-hex character (byte " + String(Int(c)) + ")")


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
        raise Error("mail corpus: an odd number of hex digits")
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
            raise Error("mail corpus: a varint runs past the end")
        var c = bytes[pos]
        pos += 1
        v |= Int(c & 0x7F) << shift
        if c < 0x80:
            return v
        shift += 7
        if shift > 63:
            raise Error("mail corpus: a varint longer than 10 bytes")


def _corpus_fields(path: String) raises -> List[List[UInt8]]:
    """The payload of each MailCorpus field, in order. Every field must be
    length-delimited and the fields must be 1, 2, 3, ... each once, so entry
    k is field k+1's bytes."""
    var bytes = _from_hex(_read(path))
    var out = List[List[UInt8]]()
    var pos = 0
    while pos < len(bytes):
        var tag = _varint(bytes, pos)
        var field_no = tag >> 3
        if tag & 7 != 2:
            raise Error(
                "mail corpus: field " + String(field_no) + " is not length-delimited"
            )
        if field_no != len(out) + 1:
            raise Error(
                "mail corpus: field "
                + String(field_no)
                + " where field "
                + String(len(out) + 1)
                + " was expected"
            )
        var n = _varint(bytes, pos)
        if pos + n > len(bytes):
            raise Error("mail corpus: field " + String(field_no) + " runs past the end")
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
            name + ": protoc's bytes (MailCorpus field " + String(k + 1) + ") decode to the golden",
        )
        assert_equal(
            _to_hex(encode_proto(from_protoc)),
            _to_hex(wire[k]),
            name + ": this encoder writes protoc's bytes",
        )




def _check_all(leg: Int, g: Goldens, wire: List[List[UInt8]]) raises -> Int:
    """Checks every message, in the order mail.proto declares them; returns
    how many it checked."""
    var n = 0
    _check[EmailAddress](leg, 0, "EmailAddress", g, wire, n)
    _check[Mailbox](leg, 1, "Mailbox", g, wire, n)
    _check[Email](leg, 2, "Email", g, wire, n)
    _check[EmailPart](leg, 3, "EmailPart", g, wire, n)
    _check[Thread](leg, 4, "Thread", g, wire, n)
    _check[Envelope](leg, 5, "Envelope", g, wire, n)
    _check[Submission](leg, 6, "Submission", g, wire, n)
    _check[Attachment](leg, 7, "Attachment", g, wire, n)
    _check[ApiError](leg, 8, "ApiError", g, wire, n)
    _check[RawBodyReply](leg, 9, "RawBodyReply", g, wire, n)
    _check[ListMailboxesRequest](leg, 10, "ListMailboxesRequest", g, wire, n)
    _check[ListMailboxesResponse](leg, 11, "ListMailboxesResponse", g, wire, n)
    _check[CreateMailboxRequest](leg, 12, "CreateMailboxRequest", g, wire, n)
    _check[CreateMailboxResponse](leg, 13, "CreateMailboxResponse", g, wire, n)
    _check[DeleteMailboxRequest](leg, 14, "DeleteMailboxRequest", g, wire, n)
    _check[DeleteMailboxResponse](leg, 15, "DeleteMailboxResponse", g, wire, n)
    _check[ListEmailsRequest](leg, 16, "ListEmailsRequest", g, wire, n)
    _check[ListEmailsResponse](leg, 17, "ListEmailsResponse", g, wire, n)
    _check[GetEmailRequest](leg, 18, "GetEmailRequest", g, wire, n)
    _check[GetEmailResponse](leg, 19, "GetEmailResponse", g, wire, n)
    _check[GetEmailRawRequest](leg, 20, "GetEmailRawRequest", g, wire, n)
    _check[GetEmailPartRequest](leg, 21, "GetEmailPartRequest", g, wire, n)
    _check[UpdateEmailRequest](leg, 22, "UpdateEmailRequest", g, wire, n)
    _check[UpdateEmailResponse](leg, 23, "UpdateEmailResponse", g, wire, n)
    _check[GetThreadRequest](leg, 24, "GetThreadRequest", g, wire, n)
    _check[GetThreadResponse](leg, 25, "GetThreadResponse", g, wire, n)
    _check[SendEmailRequest](leg, 26, "SendEmailRequest", g, wire, n)
    _check[SendEmailResponse](leg, 27, "SendEmailResponse", g, wire, n)
    _check[GetSubmissionRequest](leg, 28, "GetSubmissionRequest", g, wire, n)
    _check[GetSubmissionResponse](leg, 29, "GetSubmissionResponse", g, wire, n)
    _check[ExportMailboxRequest](leg, 30, "ExportMailboxRequest", g, wire, n)
    _check[InboundEnvelope](leg, 31, "InboundEnvelope", g, wire, n)
    _check[InboundDelivery](leg, 32, "InboundDelivery", g, wire, n)
    _check[InboundDeliveryResponse](leg, 33, "InboundDeliveryResponse", g, wire, n)
    _check[RawMessageRequest](leg, 34, "RawMessageRequest", g, wire, n)
    _check[RawMessageResponse](leg, 35, "RawMessageResponse", g, wire, n)
    _check[ErrorResponse](leg, 36, "ErrorResponse", g, wire, n)
    _check[Subject](leg, 37, "Subject", g, wire, n)
    _check[EraseSubjectRequest](leg, 38, "EraseSubjectRequest", g, wire, n)
    _check[EraseSubjectResponse](leg, 39, "EraseSubjectResponse", g, wire, n)
    return n


def test_json_goldens() raises:
    var g = _load_goldens()
    assert_equal(_check_all(_LEG_JSON, g, List[List[UInt8]]()), _MESSAGES, "messages checked")


def test_protoc_corpus() raises:
    var g = _load_goldens()
    assert_equal(_check_all(_LEG_PROTOC, g, _corpus_fields(_CORPUS)), _MESSAGES, "messages checked")


def test_protoc_still_writes_the_committed_bytes() raises:
    var g = _load_goldens()
    var committed = _corpus_fields(_CORPUS)
    var now = _corpus_fields(_PROTOC_NOW)
    for k in range(min(len(committed), len(now))):
        assert_equal(
            _to_hex(now[k]),
            _to_hex(committed[k]),
            g.names[k]
            + ": protoc's encoding of corpus.txtpb (MailCorpus field "
            + String(k + 1)
            + ") is the committed corpus.canonical.hex",
        )
    assert_equal(len(now), len(committed), "MailCorpus fields protoc wrote")


def test_every_message_has_a_golden_and_a_corpus_field() raises:
    var g = _load_goldens()
    var declared = _proto_message_names()
    for k in range(min(len(declared), len(g.names))):
        assert_equal(
            g.names[k],
            declared[k],
            "golden line " + String(k) + " names mail.proto's message " + String(k),
        )
    for k in range(len(g.names), len(declared)):
        raise Error("mail.proto declares " + declared[k] + ", which has no golden line")
    for k in range(len(declared), len(g.names)):
        raise Error("golden line names " + g.names[k] + ", which mail.proto does not declare")
    assert_equal(len(g.names), _MESSAGES, "golden lines")
    assert_equal(len(_corpus_fields(_CORPUS)), _MESSAGES, "corpus fields")


def main() raises:
    var suite = TestSuite()
    suite.test[test_json_goldens]()
    suite.test[test_protoc_corpus]()
    suite.test[test_protoc_still_writes_the_committed_bytes]()
    suite.test[test_every_message_has_a_golden_and_a_corpus_field]()
    suite^.run()
