# =============================================================================
# AN OBJECT NAME IS A BYTE STRING AND MUST SURVIVE THE SHALLOW LISTING EXACTLY
# =============================================================================
#
# ⛔ THE DEFECT CLASS THIS FILE EXISTS FOR: a per-byte `chr(Int(byte))` decode.
#
# `komira_objectstore/local_fs_conditional_store._list_dir_fnames` decodes the
# `komira_list_dir_shallow` C shim's records. Decoding them with
#
#     var s = String()
#     while j < i:
#         s += chr(Int(out_buf[j]))
#
# corrupts every non-ASCII name. The function mirrors komira_async's
# `_local_fs_list_dir_shallow`, so a defect in one is likely in the other.
# Other files here describe the same class (`komira_shuffle`'s `codec.mojo`,
# `delimiter_faithful_conditional_store.mojo`,
# `tests/test_delimiter_listing_byte_faithful.mojo`); a comment does not stop
# one call site being missed, which is the argument for a falsifier.
#
# `chr` maps a CODE POINT to its UTF-8 ENCODING, so a stored byte >= 0x80 is
# RE-ENCODED into two: `ß` (C3 9F) -> `ÃŸ` (C3 83 C2 9F). ASCII is the
# corruption's FIXED POINT, so every existing listing test passed over it.
# The consequence here is the same as on the filesystem side: the returned
# NAME does not exist, so the object cannot be read back.
#
# ⚠ THE ON-DISK FIXTURE AVOIDS DECOMPOSABLE CHARACTERS ON PURPOSE. `ü`
# (U+00FC) has a canonical decomposition, so a normalizing filesystem could
# hand back `u`+U+0308 and red the byte assertion for a reason that is not this
# defect. `ß`, `東京` and `𐍈` do not decompose, so NFC == NFD.
#
# ⚠ This file never asserts that two code paths AGREE — that is satisfied by
# both being wrong alike. It asserts the EXACT bytes of the name the fixture
# CREATED, and that the returned name still names a real file.
# =============================================================================

from komira_runtime_paths import test_tmpdir
from std.ffi import external_call
from std.testing import assert_equal, assert_true

from komira_objectstore.local_fs_conditional_store import _list_dir_fnames


# =============================================================================
# THE FIXTURE — all three multi-byte UTF-8 lead classes + an ASCII control
# =============================================================================

comptime _EXPECTED_NAME_BYTES: Int = 22  # 7 + 6 + 4 + 5


def _names() raises -> List[String]:
    return [
        String("straße"),  # 73 74 72 61 C3 9F 65   2-byte lead
        String("東京"),     # E6 9D B1 E4 BA AC      two 3-byte sequences
        String("𐍈"),       # F0 90 8D 88            one 4-byte sequence
        String("plain"),   # ASCII — the CONTROL
    ]


def _bytes_of(imm s: String) raises -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _hex(imm b: List[UInt8]) raises -> String:
    var digits: List[String] = [
        String("0"), String("1"), String("2"), String("3"),
        String("4"), String("5"), String("6"), String("7"),
        String("8"), String("9"), String("a"), String("b"),
        String("c"), String("d"), String("e"), String("f"),
    ]
    var out = String("")
    for i in range(len(b)):
        if i > 0:
            out += " "
        var v = Int(b[i])
        out += digits[v >> 4]
        out += digits[v & 15]
    return out^


def _same_bytes(imm a: String, imm b: String) raises -> Bool:
    var ab = _bytes_of(a)
    var bb = _bytes_of(b)
    if len(ab) != len(bb):
        return False
    for i in range(len(ab)):
        if ab[i] != bb[i]:
            return False
    return True


def _sh(cmd: String) raises:
    var cmd_local = cmd
    var rc = external_call["system", Int32](
        cmd_local.as_c_string_slice().unsafe_ptr()
    )
    if Int(rc) != 0:
        raise Error("shell command failed rc=" + String(Int(rc)) + ": " + cmd)


def _disk_root() raises -> String:
    var base = test_tmpdir()
    var pid = external_call["getpid", Int32]()
    var root = base + String("/objbytes_") + String(Int(pid))
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


# =============================================================================
# NON-VACUITY — without this, an all-ASCII fixture makes the file a tautology
# =============================================================================


def test_fixture_is_actually_non_ascii() raises:
    """NON-VACUITY GUARD FOR EVERY OTHER TEST IN THIS FILE.

    ⛔ THE OLD DECODE IS THE IDENTITY ON ASCII, so an all-ASCII fixture makes
    the byte assertions below pass against the DEFECTIVE decode. Swapping
    `straße` for `strasse` would fail nothing.

    Four properties: a byte >= 0x80 exists; all three multi-byte lead classes
    (C0-DF, E0-EF, F0-F7) appear; an all-ASCII CONTROL name is present; and the
    exact stored byte total, so a substitution preserving the class set still
    reds.
    """
    var ns = _names()
    var total = 0
    var n_high = 0
    var saw_2b = False
    var saw_3b = False
    var saw_4b = False
    var saw_ascii_control = False
    for i in range(len(ns)):
        var b = _bytes_of(ns[i])
        total += len(b)
        var this_high = 0
        for j in range(len(b)):
            var v = Int(b[j])
            if v >= 0x80:
                this_high += 1
                n_high += 1
            if v >= 0xC0 and v <= 0xDF:
                saw_2b = True
            if v >= 0xE0 and v <= 0xEF:
                saw_3b = True
            if v >= 0xF0 and v <= 0xF7:
                saw_4b = True
        if this_high == 0:
            saw_ascii_control = True

    if n_high == 0:
        raise Error(
            "VACUOUS FIXTURE: no name holds a byte >= 0x80, so every byte"
            " assertion in this file passes against the DEFECTIVE"
            " per-code-point `chr` decode. See this file's header."
        )
    if not saw_2b:
        raise Error("VACUOUS FIXTURE: no 2-byte (C0-DF) lead byte present")
    if not saw_3b:
        raise Error("VACUOUS FIXTURE: no 3-byte (E0-EF) lead byte present")
    if not saw_4b:
        raise Error("VACUOUS FIXTURE: no 4-byte (F0-F7) lead byte present")
    if not saw_ascii_control:
        raise Error("VACUOUS FIXTURE: no all-ASCII CONTROL name")
    assert_equal(total, _EXPECTED_NAME_BYTES)


# =============================================================================
# FALSIFIER — `local_fs_conditional_store._list_dir_fnames`
# =============================================================================


def test_shallow_file_listing_reproduces_name_bytes_exactly() raises:
    """SITE: `komira_objectstore/local_fs_conditional_store._list_dir_fnames`.

    Asserts the EXACT bytes of each name the fixture CREATED, and — the
    property that does not depend on knowing them — that every returned name
    still resolves to a real file (a re-encoded name does not).

    Killed by: restoring `s += chr(Int(out_buf[j]))` in `_list_dir_fnames`.
    """
    var root = _disk_root()
    var names = _names()
    for i in range(len(names)):
        _sh(
            String("printf 'X' > '")
            + root
            + String("/")
            + names[i]
            + String(".obj'")
        )
    # A subdirectory too: the 'D'-tagged record must still be filtered out
    # AFTER the decode change (the tag is read before the name run).
    _sh(String("mkdir -p '") + root + String("/東京dir'"))

    var listed = _list_dir_fnames(root)
    assert_equal(len(listed), len(names))
    for i in range(len(names)):
        var want = names[i] + String(".obj")
        var found = False
        for j in range(len(listed)):
            if _same_bytes(listed[j], want):
                found = True
                break
        if not found:
            var got0 = String("")
            if len(listed) > 0:
                got0 = _hex(_bytes_of(listed[0]))
            raise Error(
                "_list_dir_fnames did not reproduce the on-disk name '"
                + want
                + "'. Wanted ["
                + _hex(_bytes_of(want))
                + "], first listed ["
                + got0
                + "]. If every byte >= 0x80 doubled, the per-code-point `chr`"
                " decode is back — see this file's header."
            )
    # Every returned name must still name a real file. `test -f` is the
    # filesystem's own answer to "does this path exist"; a mojibaked name
    # fails it.
    for j in range(len(listed)):
        _sh(String("test -f '") + root + String("/") + listed[j] + String("'"))
    _sh(String("rm -rf '") + root + String("'"))


def main() raises:
    test_fixture_is_actually_non_ascii()
    test_shallow_file_listing_reproduces_name_bytes_exactly()
    print("test_local_fs_store_list_bytes_non_ascii: ALL PASS")
