# =============================================================================
# rule_scan -- run one `Rule` over a text and return the names it finds.
# =============================================================================
#
# `scan_rule` returns the entity names one rule finds in a text, in the order
# they occur, with repeats kept (the extractor drops duplicates across rules).
# The scan is a pure function of the rule and the text, linear in the text for
# every matcher but a token pattern, which is linear in the token times the
# pattern. It never reads past the text: a span is cut where a delimiter was
# found, and every comparison of a length is made by subtraction.
#
# Tokens are runs of non-whitespace bytes (space, tab, newline, carriage
# return). Leading `( [ { " '` and trailing `. , ; : ! ? ) ] } " '` are trimmed.
# Only ASCII bytes are trimmed or split on, so every cut falls between
# characters and every returned name is well-formed UTF-8.
# =============================================================================

from .rule import (
    RULE_DELIMITED,
    RULE_EMAIL,
    RULE_MAX_SPAN_BYTES,
    RULE_TOKEN_PATTERN,
    RULE_URL,
    RULE_VERB_PREFIX,
    RULE_WORD_LIST,
    Rule,
    ascii_lower,
)
from .rule_pattern import (
    is_leading_trim_byte,
    is_space_byte,
    is_trailing_trim_byte,
)


def _slice(text: String, lo: Int, hi: Int) -> String:
    """The bytes of `text` in `[lo, hi)`; the caller cuts between characters."""
    var b = text.as_bytes()
    var out = List[UInt8](capacity=hi - lo)
    for i in range(lo, hi):
        out.append(b[i])
    # SAFETY: callers cut at ASCII bytes or at the start or end of a delimiter
    # that matched whole in well-formed text, and UTF-8 is self-synchronising,
    # so a cut never falls inside a multi-byte sequence.
    return String(unsafe_from_utf8=Span(out))


def _is_ws(c: Int) -> Bool:
    return is_space_byte(c)


def _is_alpha(c: Int) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


def _is_alnum(c: Int) -> Bool:
    return _is_alpha(c) or (c >= 48 and c <= 57)


def _is_leading_punct(c: Int) -> Bool:
    return is_leading_trim_byte(c)


def _is_trailing_punct(c: Int) -> Bool:
    return is_trailing_trim_byte(c)


def tokens_of(text: String) -> List[String]:
    """The trimmed tokens of `text`, one per whitespace-separated run.

    A run that trims to nothing is kept as an empty string, so the position of
    a token after it is not lost.
    """
    var out = List[String]()
    var b = text.as_bytes()
    var n = len(b)
    var start = 0
    for i in range(n + 1):
        if i == n or _is_ws(Int(b[i])):
            if i > start:
                var lo = start
                var hi = i
                while lo < hi and _is_leading_punct(Int(b[lo])):
                    lo += 1
                while hi > lo and _is_trailing_punct(Int(b[hi - 1])):
                    hi -= 1
                out.append(_slice(text, lo, hi))
            start = i + 1
    return out^


def _in_terms(terms: List[String], lowered: String) -> Bool:
    for i in range(len(terms)):
        if terms[i] == lowered:
            return True
    return False


def _is_url_token(token: String) -> Bool:
    var b = token.as_bytes()
    var n = len(b)
    if n == 0 or not _is_alpha(Int(b[0])):
        return False
    var i = 1
    while i < n:
        var c = Int(b[i])
        if _is_alnum(c) or c == 43 or c == 46 or c == 45:
            i += 1
        else:
            break
    # `://` and then at least one byte.
    if n - i < 4:
        return False
    return Int(b[i]) == 58 and Int(b[i + 1]) == 47 and Int(b[i + 2]) == 47


def _is_email_local(c: Int) -> Bool:
    return _is_alnum(c) or c == 46 or c == 95 or c == 37 or c == 43 or c == 45


def _is_email_domain(c: Int) -> Bool:
    return _is_alnum(c) or c == 46 or c == 45


def _scan_emails(text: String) -> List[String]:
    var out = List[String]()
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        if Int(b[i]) != 64:
            i += 1
            continue
        var lo = i
        while lo > 0 and _is_email_local(Int(b[lo - 1])):
            lo -= 1
        while lo < i and Int(b[lo]) == 46:
            lo += 1  # a local part does not start with a dot
        var hi = i + 1
        while hi < n and _is_email_domain(Int(b[hi])):
            hi += 1
        var end = hi
        while end > i + 1 and (Int(b[end - 1]) == 46 or Int(b[end - 1]) == 45):
            end -= 1  # trailing sentence dots, and a dash, are not the domain
        # The domain is `label(.label)+`: no empty label, one dot at least.
        var ok = lo < i and end - (i + 1) >= 3
        var dots = 0
        var prev_dot = True  # a domain does not start with a dot
        for k in range(i + 1, end):
            var c = Int(b[k])
            if c == 46:
                if prev_dot:
                    ok = False
                dots += 1
                prev_dot = True
            else:
                if c == 45 and prev_dot:
                    ok = False  # a label does not start with a dash
                prev_dot = False
        if ok and dots > 0:
            out.append(_slice(text, lo, end))
        i = hi
    return out^


def _matches_at(b: Span[UInt8, _], at: Int, needle: String) -> Bool:
    var nb = needle.as_bytes()
    if len(b) - at < len(nb):
        return False
    for k in range(len(nb)):
        if b[at + k] != nb[k]:
            return False
    return True


def _scan_delimited(text: String, rule: Rule) -> List[String]:
    var out = List[String]()
    var b = text.as_bytes()
    var n = len(b)
    var open_len = len(rule.open_delim.as_bytes())
    var close_len = len(rule.close_delim.as_bytes())
    var i = 0
    while i < n:
        if not _matches_at(b, i, rule.open_delim):
            i += 1
            continue
        var body = i + open_len
        var j = body
        var found = -1
        while j < n and j - body <= RULE_MAX_SPAN_BYTES:
            if Int(b[j]) == 10:
                break
            if _matches_at(b, j, rule.close_delim):
                found = j
                break
            j += 1
        if found >= body:
            if found > body:
                out.append(_slice(text, body, found))
            i = found + close_len  # an empty span is skipped, not re-paired
        else:
            i += 1
    return out^


def scan_rule(rule: Rule, text: String) -> List[String]:
    """The names `rule` finds in `text`, in order of occurrence.

    Args:
        rule: The rule to run.
        text: The text to scan.

    Returns:
        The matched names; repeats are kept and none is empty.
    """
    if rule.kind == RULE_EMAIL:
        return _scan_emails(text)
    if rule.kind == RULE_DELIMITED:
        return _scan_delimited(text, rule)
    var out = List[String]()
    var toks = tokens_of(text)
    for t in range(len(toks)):
        var tok = toks[t]
        if len(tok.as_bytes()) == 0:
            continue
        if rule.kind == RULE_WORD_LIST:
            if _in_terms(rule.terms, ascii_lower(tok)):
                out.append(tok)
        elif rule.kind == RULE_VERB_PREFIX:
            if _in_terms(rule.terms, ascii_lower(tok)) and t + 1 < len(toks):
                var sub = toks[t + 1]
                if len(sub.as_bytes()) > 0 and _is_alpha(Int(sub.as_bytes()[0])):
                    out.append(tok + String(" ") + sub)
        elif rule.kind == RULE_TOKEN_PATTERN:
            if rule.patterns[0].matches(tok):
                out.append(tok)
        elif rule.kind == RULE_URL:
            if _is_url_token(tok):
                out.append(tok)
    return out^
