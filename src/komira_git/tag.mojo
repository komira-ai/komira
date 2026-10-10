# =============================================================================
# komira_git/tag.mojo -- annotated tag objects: parse and serialize.
# =============================================================================
#
# A tag's payload is
#
#     object <hex id> LF
#     type <commit|tree|blob|tag> LF
#     tag <name> LF
#     tagger <signature> LF       (absent in some early tags)
#     <extra headers>             (kept in order)
#     LF
#     <message>                   (a signature, if any, is part of it)
#
# `parse_tag` refuses what `git fsck` reports as an error for a tag: a
# missing or malformed `object`, `type` or `tag` line, an unknown type, a
# bad `tagger` signature and a NUL in the header. A missing `tagger` line is
# accepted (fsck reports it as information only), as is a tag name that is
# not a valid ref name. Like `parse_commit` it also refuses forms git
# accepts but does not write, so that an accepted tag serializes back to its
# own bytes: upper-case hex ids, a header with no empty line after it, extra
# whitespace before a `tagger` date, an extra header line holding no space,
# and a line starting with a space directly after `tag` or `tagger`.
# =============================================================================

from .bytes_util import _append_span, _append_str, _starts_with, _to_list
from .object_id import ObjectFormat, ObjectId, ObjectKind, hash_object
from .signature import (
    ExtraHeader,
    Signature,
    _header_end,
    _line_end,
    _parse_extra_headers,
    _parse_header_id,
    parse_signature,
)


struct Tag(Copyable, Movable):
    """An annotated tag: the object it names and that object's kind, the tag
    name (bytes), the tagger if any, extra headers and the message."""

    var object: ObjectId
    var target_kind: ObjectKind
    var name: List[UInt8]
    var tagger: Optional[Signature]
    var extra_headers: List[ExtraHeader]
    var message: List[UInt8]

    def __init__(
        out self,
        object: ObjectId,
        target_kind: ObjectKind,
        var name: List[UInt8],
        var tagger: Optional[Signature],
        var extra_headers: List[ExtraHeader],
        var message: List[UInt8],
    ):
        self.object = object
        self.target_kind = target_kind
        self.name = name^
        self.tagger = tagger^
        self.extra_headers = extra_headers^
        self.message = message^

    def format(self) -> ObjectFormat:
        """The object format (the tagged object id's)."""
        return self.object.format()

    def serialize(self) raises -> List[UInt8]:
        """The tag's payload. Refuses a name holding a line break or NUL."""
        for i in range(len(self.name)):
            var c = Int(self.name[i])
            if c == 10 or c == 0:
                raise Error("komira_git: tag: name holds a line break or NUL")
        var out = List[UInt8]()
        _append_str(out, "object ")
        self.object.append_hex_to(out)
        _append_str(out, "\ntype ")
        _append_str(out, self.target_kind.name())
        _append_str(out, "\ntag ")
        _append_span(out, Span(self.name))
        out.append(UInt8(10))
        if self.tagger:
            _append_str(out, "tagger ")
            self.tagger.value().append_to(out)
            out.append(UInt8(10))
        for i in range(len(self.extra_headers)):
            self.extra_headers[i].append_to(out)
        out.append(UInt8(10))
        _append_span(out, Span(self.message))
        return out^

    def id(self) raises -> ObjectId:
        """The tag's object id (`git hash-object -t tag` prints it)."""
        var payload = self.serialize()
        return hash_object(self.format(), ObjectKind.tag(), Span(payload))


def parse_tag(format: ObjectFormat, payload: Span[UInt8, _]) raises -> Tag:
    """Parse a tag payload of `format`, refusing every malformation the
    header of this file lists."""
    var hend = _header_end(payload, "tag")
    var pos = 0
    if not _starts_with(payload, pos, "object "):
        raise Error("komira_git: tag: missing 'object' line")
    var e = _line_end(payload, pos)
    var object = _parse_header_id(
        format, payload, pos + 7, e, "komira_git: tag: bad 'object' id"
    )
    pos = e + 1
    if pos >= hend or not _starts_with(payload, pos, "type "):
        raise Error("komira_git: tag: missing 'type' line")
    e = _line_end(payload, pos)
    var kind: ObjectKind
    try:
        kind = ObjectKind.from_name(payload[pos + 5 : e])
    except:
        raise Error("komira_git: tag: bad 'type' line")
    pos = e + 1
    if pos >= hend or not _starts_with(payload, pos, "tag "):
        raise Error("komira_git: tag: missing 'tag' line")
    e = _line_end(payload, pos)
    var name = _to_list(payload, pos + 4, e)
    pos = e + 1
    var tagger = Optional[Signature](None)
    if pos < hend and _starts_with(payload, pos, "tagger "):
        e = _line_end(payload, pos)
        tagger = Optional[Signature](
            parse_signature(payload[pos + 7 : e], "tag tagger")
        )
        pos = e + 1
    var extra = _parse_extra_headers(payload, pos, hend, "tag")
    return Tag(
        object,
        kind,
        name^,
        tagger^,
        extra^,
        _to_list(payload, hend + 1, len(payload)),
    )
