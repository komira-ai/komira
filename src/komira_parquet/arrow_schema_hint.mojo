# =============================================================================
# arrow_schema_hint: read the `ARROW:schema` footer key, when present
# =============================================================================
#
# In a Parquet file, Arrow `string`, `large_string` and `dictionary<string>`
# are byte-identical: all three are physical BYTE_ARRAY annotated
# ConvertedType.UTF8 / LogicalType.String, and the format has nowhere to say
# which Arrow string type a column came from. (`binary` is BYTE_ARRAY with no
# annotation, which the format can express; `decode_helpers` maps it.)
# Arrow writers (parquet-cpp, arrow-rs) record the Arrow schema in a
# key-value footer entry named `ARROW:schema`: a base64-encoded Arrow IPC
# Schema message. This module reads it.
#
# The key is optional. Most Parquet files are not written by an Arrow
# writer, and a file without the key reads exactly as it would if this
# module did not exist. Every entry point returns an EMPTY hint rather than
# raising, and a value that does not parse is treated as absent: an
# unreadable vendor extension is not a corrupt file. The consequence: the
# Arrow type a column reads back as depends on whether its writer recorded
# the key (`large_string` with it, `string` without).
#
# The footer is unverified, writer-supplied data, so `refine_from_hint` only
# ever picks another spelling of a type the physical layout already permits:
#     STRING -> STRING | LARGE_STRING | DICTIONARY (of utf8)
#     BINARY -> BINARY | LARGE_BINARY
#     anything else -> unchanged
# The decision is keyed on the spec-derived type, never on the hint alone.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow_ipc.ipc_flatbuf import (
    MESSAGE_HEADER_SCHEMA,
    TYPE_BINARY,
    TYPE_LARGE_BINARY,
    TYPE_LARGE_UTF8,
    TYPE_UTF8,
    flatbuf_reader_over,
    parse_ipc_message,
    read_message,
    read_schema,
)
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.metadata import FileMetaData, KeyValue


# The footer key. Case-sensitive; parquet-cpp and arrow-rs write exactly this.
comptime ARROW_SCHEMA_KEY = String("ARROW:schema")


# =============================================================================
# base64
# =============================================================================


@always_inline
def _b64_value(c: UInt8) -> Int:
    """Standard base64 alphabet to 0..63; -1 for any other byte (padding and
    whitespace included, which the caller skips)."""
    if c >= UInt8(65) and c <= UInt8(90):  # 'A'..'Z'
        return Int(c) - 65
    if c >= UInt8(97) and c <= UInt8(122):  # 'a'..'z'
        return Int(c) - 97 + 26
    if c >= UInt8(48) and c <= UInt8(57):  # '0'..'9'
        return Int(c) - 48 + 52
    if c == UInt8(43):  # '+'
        return 62
    if c == UInt8(47):  # '/'
        return 63
    return -1


def _b64_decode_into_buffer(text: String) -> SharedAlignedBuffer[HeapRegion]:
    """Decode standard base64 into a fresh buffer.

    Bytes outside the alphabet (padding, newlines) are skipped rather than
    refused: this reads a third party's metadata string. A trailing group
    too short to name a whole byte is dropped.
    """
    var n = text.byte_length()
    var raw = text.as_bytes()
    # 3 bytes out per 4 in, rounded up, plus slack so an empty value still
    # allocates.
    var out = SharedAlignedBuffer[HeapRegion].heap_owned((n // 4) * 3 + 4)
    var written = 0
    var acc = 0
    var acc_bits = 0
    for i in range(n):
        var v = _b64_value(raw[i])
        if v < 0:
            continue
        acc = ((acc << 6) | v) & 0xFFFFFF
        acc_bits += 6
        if acc_bits >= 8:
            acc_bits -= 8
            out.write_u8_at(written, UInt8((acc >> acc_bits) & 0xFF))
            written += 1
    out.set_length(written)
    return out^


# =============================================================================
# The hint
# =============================================================================


struct ArrowSchemaHint(Movable, Copyable):
    """The BYTE_ARRAY-family Arrow types of the top-level fields an
    `ARROW:schema` footer entry declares.

    EMPTY is the normal case: the file carried no such key, or one that did
    not parse, and the caller reads as if there were no hint. The types are
    what the writer declared and are not authoritative: pass each through
    `refine_from_hint` with the spec-derived type before use.
    """

    var names: List[String]
    var types: List[ArrowType]

    def __init__(out self):
        self.names = List[String]()
        self.types = List[ArrowType]()

    def __init__(out self, var names: List[String], var types: List[ArrowType]):
        self.names = names^
        self.types = types^

    @always_inline
    def is_empty(self) -> Bool:
        return len(self.names) == 0

    def type_for_name(self, name: String) -> Optional[ArrowType]:
        """The declared type of the top-level field `name`. None when the
        name is absent, or declared more than once (an ambiguous name is not
        refined)."""
        var found = Optional[ArrowType](None)
        for i in range(len(self.names)):
            if self.names[i] == name:
                if found:
                    return None
                found = self.types[i]
        return found


def _ipc_type_tag_to_arrow_type(field_tag: UInt8, is_dict_encoded: Bool) -> Optional[ArrowType]:
    """The BYTE_ARRAY family of the Arrow Type union, and nothing else.

    Every other Arrow type is recoverable from standard Parquet metadata, so
    reading it here would add a second, writer-supplied source of truth.
    A dictionary-encoded field declares its VALUE type in the Type union;
    a utf8 value type under a dictionary encoding is
    `dictionary<index, utf8>`, which is ArrowType.DICTIONARY here. A
    dictionary of binary values has no ArrowType and is skipped.
    """
    if field_tag == TYPE_UTF8:
        if is_dict_encoded:
            return ArrowType.DICTIONARY
        return ArrowType.STRING
    if field_tag == TYPE_LARGE_UTF8:
        if is_dict_encoded:
            return ArrowType.DICTIONARY
        return ArrowType.LARGE_STRING
    if is_dict_encoded:
        return None
    if field_tag == TYPE_BINARY:
        return ArrowType.BINARY
    if field_tag == TYPE_LARGE_BINARY:
        return ArrowType.LARGE_BINARY
    return None


def parse_arrow_schema_value(value: String) -> ArrowSchemaHint:
    """Decode one `ARROW:schema` footer value into a hint. Never raises: bad
    base64, a truncated flatbuffer, a message that is not a Schema, all give
    an EMPTY hint."""
    try:
        var fb = _b64_decode_into_buffer(value)
        if fb.len() < 8:
            return ArrowSchemaHint()
        # An encapsulated IPC message: [0xFFFFFFFF][u32 size][flatbuffer],
        # or without the continuation marker from older writers;
        # `parse_ipc_message` accepts both.
        var frame = parse_ipc_message(fb)
        if frame.metadata_size <= 0:
            return ArrowSchemaHint()
        var meta = SharedAlignedBuffer[HeapRegion].heap_owned(frame.metadata_size)
        meta.copy_from_view_at(0, fb.view_range_ro(frame.metadata_pos, frame.metadata_size))
        meta.set_length(frame.metadata_size)

        var reader = flatbuf_reader_over(meta)
        var msg = read_message(reader, reader.read_root_offset())
        if msg.header_tag != MESSAGE_HEADER_SCHEMA:
            return ArrowSchemaHint()
        var desc = read_schema(reader, msg.header_table_pos)

        var names = List[String]()
        var types = List[ArrowType]()
        for i in range(len(desc.fields)):
            ref f = desc.fields[i]
            var at = _ipc_type_tag_to_arrow_type(f.type_tag, Bool(f.dictionary_encoding))
            if not at:
                continue
            names.append(f.name)
            types.append(at.value())
        return ArrowSchemaHint(names^, types^)
    except:
        return ArrowSchemaHint()


def arrow_schema_hint_from_kv(kv: Optional[List[KeyValue]]) -> ArrowSchemaHint:
    """Find `ARROW:schema` among a footer's key-value metadata and decode it.
    No list, no key, or a key with no value: an EMPTY hint."""
    if not kv:
        return ArrowSchemaHint()
    ref entries = kv.value()
    for i in range(len(entries)):
        if entries[i].key == ARROW_SCHEMA_KEY:
            if not entries[i].value:
                return ArrowSchemaHint()
            return parse_arrow_schema_value(entries[i].value.value())
    return ArrowSchemaHint()


def arrow_schema_hint_from_metadata(metadata: FileMetaData) -> ArrowSchemaHint:
    """`arrow_schema_hint_from_kv` over a parsed footer."""
    return arrow_schema_hint_from_kv(metadata.key_value_metadata)


# =============================================================================
# The guard
# =============================================================================


def refine_from_hint(spec_type: ArrowType, hint: Optional[ArrowType]) -> ArrowType:
    """Apply a footer hint to a spec-derived Arrow type, or ignore it.

        spec STRING (BYTE_ARRAY + UTF8) -> STRING | LARGE_STRING | DICTIONARY
        spec BINARY (bare BYTE_ARRAY)   -> BINARY | LARGE_BINARY
        anything else                   -> unchanged, hint ignored

    A footer claiming an INT64 column is a string cannot make it one. A
    DICTIONARY answer only labels the column; a caller that cannot build a
    dictionary-encoded Arrow column must not take it.
    """
    if not hint:
        return spec_type
    var h = hint.value()
    if spec_type == ArrowType.STRING:
        if h == ArrowType.STRING or h == ArrowType.LARGE_STRING or h == ArrowType.DICTIONARY:
            return h
        return spec_type
    if spec_type == ArrowType.BINARY:
        if h == ArrowType.BINARY or h == ArrowType.LARGE_BINARY:
            return h
        return spec_type
    return spec_type
