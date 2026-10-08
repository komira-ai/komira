# =============================================================================
# komira_git/ref_name.mojo -- ref name rules (git-check-ref-format).
# =============================================================================
#
# A ref name is valid when (git-check-ref-format(1), rules 1-10):
#   * it has at least two '/'-separated components (one is enough with
#     `allow_onelevel`), none of them empty, none starting with '.', none
#     ending with `.lock`;
#   * it holds no `..`, no `@{`, no byte below 0x20, no 0x7f, and none of
#     space `~ ^ : ? [ \\`;
#   * it holds no `*`, except one when `refspec_pattern` is set;
#   * it does not end with '.', and it is not the single character `@`.
# A leading '/', a trailing '/' and `//` are empty components.
# `normalize_ref_name` first drops leading slashes and folds runs of slashes
# into one (`git check-ref-format --normalize`), then applies the rules.
#
# The checks run in git's order (refs.c, `check_or_sanitize_refname`), so a
# name breaking two rules is refused for the same one git would hit first.
# =============================================================================

from .bytes_util import _hex_digit

comptime _OK: Int = 0
comptime _DOT: Int = 2
comptime _BRACE: Int = 3
comptime _BAD: Int = 4
comptime _STAR: Int = 5

comptime _B_SLASH: Int = 47
comptime _B_DOT: Int = 46
comptime _B_AT: Int = 64


def _disposition(c: Int) -> Int:
    """refs.c's `refname_disposition` for one byte ('/' is handled by the
    caller)."""
    if c < 32 or c == 127:
        return _BAD
    if c == 32 or c == 58 or c == 63 or c == 91 or c == 92 or c == 94 or c == 126:
        return _BAD  # space : ? [ \ ^ ~
    if c == _B_DOT:
        return _DOT
    if c == 123:
        return _BRACE
    if c == 42:
        return _STAR
    return _OK


def check_ref_name(
    name: Span[UInt8, _],
    allow_onelevel: Bool = False,
    refspec_pattern: Bool = False,
) raises:
    """Refuse a ref name breaking a rule in the header of this file; the
    message names the rule."""
    var pre = String("komira_git: bad ref name: ")
    var n = len(name)
    if n == 1 and Int(name[0]) == _B_AT:
        raise Error(pre + "is '@'")
    var star_allowed = refspec_pattern
    var components = 0
    var pos = 0
    while True:
        var start = pos
        var last = 0
        while pos < n and Int(name[pos]) != _B_SLASH:
            var c = Int(name[pos])
            var d = _disposition(c)
            if d == _DOT and last == _B_DOT:
                raise Error(pre + "contains '..'")
            if d == _BRACE and last == _B_AT:
                raise Error(pre + "contains '@{'")
            if d == _BAD:
                raise Error(
                    pre + "contains byte 0x" + _hex_digit(c >> 4)
                    + _hex_digit(c & 15)
                )
            if d == _STAR:
                if not star_allowed:
                    if refspec_pattern:
                        raise Error(pre + "contains more than one '*'")
                    raise Error(pre + "contains '*'")
                star_allowed = False
            last = c
            pos += 1
        var length = pos - start
        if length == 0:
            raise Error(pre + "has an empty component")
        if Int(name[start]) == _B_DOT:
            raise Error(pre + "has a component starting with '.'")
        if (
            length >= 5
            and Int(name[pos - 5]) == _B_DOT
            and Int(name[pos - 4]) == 108
            and Int(name[pos - 3]) == 111
            and Int(name[pos - 2]) == 99
            and Int(name[pos - 1]) == 107
        ):
            raise Error(pre + "has a component ending with '.lock'")
        components += 1
        if pos >= n:
            break
        pos += 1
    if Int(name[n - 1]) == _B_DOT:
        raise Error(pre + "ends with '.'")
    if not allow_onelevel and components < 2:
        raise Error(pre + "has one component (allow_onelevel is off)")


def check_ref_format(
    name: String, allow_onelevel: Bool = False, refspec_pattern: Bool = False
) raises:
    """`check_ref_name` over the bytes of `name`."""
    check_ref_name(name.as_bytes(), allow_onelevel, refspec_pattern)


def is_valid_ref_name(
    name: String, allow_onelevel: Bool = False, refspec_pattern: Bool = False
) -> Bool:
    """True when `check_ref_format` accepts `name`."""
    try:
        check_ref_name(name.as_bytes(), allow_onelevel, refspec_pattern)
    except:
        return False
    return True


def normalize_ref_name(
    name: String, allow_onelevel: Bool = False, refspec_pattern: Bool = False
) raises -> String:
    """`name` with leading slashes dropped and runs of slashes folded into
    one, then checked by `check_ref_name`; returns the folded name."""
    var b = name.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var prev = _B_SLASH
    for i in range(len(b)):
        var c = Int(b[i])
        if prev == _B_SLASH and c == _B_SLASH:
            continue
        out.append(b[i])
        prev = c
    check_ref_name(Span(out), allow_onelevel, refspec_pattern)
    # `out` is `name` (valid UTF-8) with some ASCII '/' bytes removed, which
    # cannot split a multi-byte sequence, so it is valid UTF-8 too.
    return String(unsafe_from_utf8=Span(out))
