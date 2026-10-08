# =============================================================================
# komira_git/commit.mojo -- commit objects: parse and serialize.
# =============================================================================
#
# A commit's payload is
#
#     tree <hex id> LF
#     parent <hex id> LF          (zero or more)
#     author <signature> LF
#     committer <signature> LF
#     <extra headers>             (encoding, gpgsig, mergetag, ...; kept in order)
#     LF
#     <message>                   (any bytes, possibly empty)
#
# `parse_commit` refuses what `git fsck` reports for a commit: a missing or
# malformed `tree`, `parent`, `author` or `committer` line, a second
# `author` line, a bad signature (see signature.mojo), and a NUL in the
# header. It also refuses these forms git accepts, so that every accepted
# commit serializes back to its own bytes (git itself writes none of them):
#   * an id spelled in upper-case hex;
#   * a header block with no empty line after it (no message separator);
#   * more than one space, or a tab, between an ident's '>' and its date
#     (older git wrote these; see signature.mojo);
#   * an extra header line holding no space (no `key SP value` split);
#   * a line starting with a space directly after `committer` (a
#     continuation of a header komira does not keep as an extra header).
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


struct Commit(Copyable, Movable):
    """A commit: its tree, parents, author, committer, extra headers and
    message. Every id must share the tree's object format."""

    var tree: ObjectId
    var parents: List[ObjectId]
    var author: Signature
    var committer: Signature
    var extra_headers: List[ExtraHeader]
    var message: List[UInt8]

    def __init__(
        out self,
        tree: ObjectId,
        var parents: List[ObjectId],
        var author: Signature,
        var committer: Signature,
        var extra_headers: List[ExtraHeader],
        var message: List[UInt8],
    ):
        self.tree = tree
        self.parents = parents^
        self.author = author^
        self.committer = committer^
        self.extra_headers = extra_headers^
        self.message = message^

    def format(self) -> ObjectFormat:
        """The object format (the tree id's)."""
        return self.tree.format()

    def serialize(self) raises -> List[UInt8]:
        """The commit's payload. Refuses a parent of another object format."""
        var format = self.tree.format()
        var out = List[UInt8]()
        _append_str(out, "tree ")
        self.tree.append_hex_to(out)
        out.append(UInt8(10))
        for i in range(len(self.parents)):
            if self.parents[i].format() != format:
                raise Error(
                    "komira_git: commit: a " + self.parents[i].format().name()
                    + " parent in a " + format.name() + " commit"
                )
            _append_str(out, "parent ")
            self.parents[i].append_hex_to(out)
            out.append(UInt8(10))
        _append_str(out, "author ")
        self.author.append_to(out)
        out.append(UInt8(10))
        _append_str(out, "committer ")
        self.committer.append_to(out)
        out.append(UInt8(10))
        for i in range(len(self.extra_headers)):
            self.extra_headers[i].append_to(out)
        out.append(UInt8(10))
        _append_span(out, Span(self.message))
        return out^

    def id(self) raises -> ObjectId:
        """The commit's object id (`git hash-object -t commit` prints it)."""
        var payload = self.serialize()
        return hash_object(self.format(), ObjectKind.commit(), Span(payload))


def parse_commit(format: ObjectFormat, payload: Span[UInt8, _]) raises -> Commit:
    """Parse a commit payload of `format`, refusing every malformation the
    header of this file lists."""
    var hend = _header_end(payload, "commit")
    var pos = 0
    if not _starts_with(payload, pos, "tree "):
        raise Error("komira_git: commit: missing 'tree' line")
    var e = _line_end(payload, pos)
    var tree = _parse_header_id(
        format, payload, pos + 5, e, "komira_git: commit: bad 'tree' id"
    )
    pos = e + 1
    var parents = List[ObjectId]()
    while pos < hend and _starts_with(payload, pos, "parent "):
        e = _line_end(payload, pos)
        parents.append(
            _parse_header_id(
                format, payload, pos + 7, e,
                "komira_git: commit: bad 'parent' id",
            )
        )
        pos = e + 1
    if pos >= hend or not _starts_with(payload, pos, "author "):
        raise Error("komira_git: commit: missing 'author' line")
    e = _line_end(payload, pos)
    var author = parse_signature(payload[pos + 7 : e], "commit author")
    pos = e + 1
    if pos < hend and _starts_with(payload, pos, "author "):
        raise Error("komira_git: commit: more than one 'author' line")
    if pos >= hend or not _starts_with(payload, pos, "committer "):
        raise Error("komira_git: commit: missing 'committer' line")
    e = _line_end(payload, pos)
    var committer = parse_signature(payload[pos + 10 : e], "commit committer")
    pos = e + 1
    var extra = _parse_extra_headers(payload, pos, hend, "commit")
    return Commit(
        tree,
        parents^,
        author^,
        committer^,
        extra^,
        _to_list(payload, hend + 1, len(payload)),
    )
