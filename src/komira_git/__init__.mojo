"""`komira_git` -- git's object model and wire primitives, in pure Mojo.

Objects: `ObjectFormat` (sha1, sha256), `ObjectKind`, `ObjectId` and
`hash_object`; trees (`Tree`, `TreeEntry`, `parse_tree`), commits (`Commit`,
`parse_commit`), annotated tags (`Tag`, `parse_tag`) and the signatures and
extra headers they carry; loose objects (`encode_loose`, `decode_loose`,
`read_loose`, `loose_path`). Every parser refuses what `git fsck` reports as
an error, so an accepted object serializes back to its own bytes and id.

Packs: `index_pack` and `index_thin_pack` (an `IndexedPack` of a
`PackIndex` and `PackEntryInfo`s), `read_pack_object`, `PackIndex` written and
read as an index v2 file (`serialize`, `parse_pack_index`), `apply_delta`,
and the `PackLimits` every reader enforces.

Wire: pkt-line framing (`append_pkt_*`, `read_pkt_line`) and the ref name
rules of `git check-ref-format` (`check_ref_format`, `normalize_ref_name`).

No I/O: every function maps bytes to values or values to bytes.
"""

from .object_id import ObjectFormat, ObjectId, ObjectKind, hash_object, object_header
from .tree import (
    MODE_BLOB,
    MODE_EXECUTABLE,
    MODE_GITLINK,
    MODE_SYMLINK,
    MODE_TREE,
    Tree,
    TreeEntry,
    is_valid_mode,
    mode_text,
    parse_tree,
    tree_entry_compare,
)
from .signature import ExtraHeader, Signature, parse_signature
from .commit import Commit, parse_commit
from .tag import Tag, parse_tag
from .loose import LOOSE_LEVEL, LooseObject, decode_loose, encode_loose, loose_path, read_loose
from .pkt_line import (
    PKT_DATA,
    PKT_DELIM,
    PKT_FLUSH,
    PKT_MAX_LENGTH,
    PKT_MAX_PAYLOAD,
    PKT_NEED_MORE,
    PKT_RESPONSE_END,
    PktLine,
    append_pkt_data,
    append_pkt_delim,
    append_pkt_flush,
    append_pkt_response_end,
    append_pkt_text,
    read_pkt_line,
)
from .ref_name import check_ref_format, check_ref_name, is_valid_ref_name, normalize_ref_name
from .pack_format import (
    PACK_OBJ_BLOB,
    PACK_OBJ_COMMIT,
    PACK_OBJ_OFS_DELTA,
    PACK_OBJ_REF_DELTA,
    PACK_OBJ_TAG,
    PACK_OBJ_TREE,
    PackLimits,
    PackObject,
)
from .delta import DeltaHeader, apply_delta, read_delta_header
from .pack_index import PACK_INDEX_DEFAULT_LARGE_OFFSET, PackIndex, parse_pack_index
from .pack_reader import (
    ExternalBases,
    IndexedPack,
    PackEntryInfo,
    index_pack,
    index_thin_pack,
    read_pack_object,
    read_thin_pack_object,
)
