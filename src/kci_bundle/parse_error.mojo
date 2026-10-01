# =============================================================================
# kci_bundle/parse_error.mojo — precise, position-carrying errors.
# =============================================================================
#
# The parse/validate error surface is the LLM SELF-CORRECTION channel: a bundle authored by an LLM
# gets a field-precise, position-carrying diagnostic it can act on WITHOUT a
# human — "line 12: unknown field 'imge' in Spec — did you mean 'image'?". Every
# error string this module builds carries a `line N, col M` prefix and, for an
# unknown field / enum value, a Levenshtein "did you mean" suggestion drawn from
# the CLOSED set of legal names.
#
# These are plain `String` builders — the parser raises `Error(<rendered>)` and
# a tool frontend returns it in-band as a self-correctable error. Keeping the
# rendering here (not scattered in the parser) makes the error goldens a single,
# reviewable surface.
#
# ENCAPSULATION: pure String helpers. No pointer, no wildcard origin. 1.0.0b2.
# =============================================================================


def pos_prefix(line: Int, col: Int) -> String:
    """The canonical `line N, col M: ` diagnostic prefix."""
    return (
        String("line ")
        + String(line)
        + String(", col ")
        + String(col)
        + String(": ")
    )


def _min3(a: Int, b: Int, c: Int) -> Int:
    var m = a
    if b < m:
        m = b
    if c < m:
        m = c
    return m


def edit_distance(a: String, b: String) -> Int:
    """The Levenshtein edit distance between `a` and `b` (case-sensitive) — the
    ranking function for the "did you mean" suggestion."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var la = len(ab)
    var lb = len(bb)
    if la == 0:
        return lb
    if lb == 0:
        return la
    # prev[j] = distance for a[:i-1] vs b[:j]; curr[j] for a[:i] vs b[:j].
    var prev = List[Int]()
    for j in range(lb + 1):
        prev.append(j)
    for i in range(1, la + 1):
        var curr = List[Int]()
        curr.append(i)
        for j in range(1, lb + 1):
            var cost = 0 if ab[i - 1] == bb[j - 1] else 1
            curr.append(
                _min3(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            )
        prev = curr^
    return prev[lb]


def suggest(name: String, candidates: List[String]) -> String:
    """The closest candidate to `name` by edit distance, or "" when none is close
    enough. The threshold is `min(2, len/2)`-ish: a suggestion is only offered
    when it is genuinely a near-miss (a typo), never a wild guess."""
    var best = String("")
    var best_d = 1 << 30
    for ref cand in candidates:
        var d = edit_distance(name, cand)
        if d < best_d:
            best_d = d
            best = String(cand)
    # Only suggest for a genuine near-miss: distance <= 2, and never more than
    # half the candidate's length (so "x" does not "correct" to "env").
    if best.byte_length() == 0:
        return String("")
    var cap = 2
    var half = best.byte_length() // 2
    if half < cap:
        cap = half
    if cap < 1:
        cap = 1
    if best_d <= cap:
        return best^
    return String("")


def suggest_enum(value: String, candidates: List[String]) -> String:
    """Like `suggest`, but enum-aware: a bare SUFFIX (`API`) is matched
    to its fully-prefixed value (`APP_KIND_API`) via a case-insensitive
    `_<VALUE>` suffix test FIRST — the schema-lock uses full prefixed value names,
    but hand-written bundles (and LLMs) often write the short form, so this
    is the highest-value self-correction. Falls back to edit distance."""
    var vup = value.upper()
    var needle = String("_") + vup
    for ref cand in candidates:
        var cup = cand.upper()
        if cup.endswith(needle):
            return String(cand)
    return suggest(value, candidates)


def _join_names(names: List[String]) -> String:
    var out = String("")
    for i in range(len(names)):
        if i > 0:
            out += String(", ")
        out += names[i]
    return out^


def unknown_field_error(
    line: Int,
    col: Int,
    field: String,
    container: String,
    known: List[String],
) -> String:
    """`line N: unknown field 'imge' in Spec — did you mean 'image'?`. When no
    near-miss suggestion exists, the legal field set is listed so the author can
    still self-correct."""
    var msg = (
        pos_prefix(line, col)
        + String("unknown field '")
        + field
        + String("' in ")
        + container
    )
    var s = suggest(field, known)
    if s.byte_length() > 0:
        return msg + String(" — did you mean '") + s + String("'?")
    return msg + String(" (known fields: ") + _join_names(known) + String(")")


def ambiguous_enum_error(
    line: Int,
    col: Int,
    value: String,
    enum_name: String,
    matches: List[String],
) -> String:
    """`line N: ambiguous value 'BAR' for enum X — matches A, B; use the full
    value name`. Fires when a short suffix alias is a suffix of MORE than one
    declared value (never for the shipped enums, but the rule is general)."""
    return (
        pos_prefix(line, col)
        + String("ambiguous value '")
        + value
        + String("' for enum ")
        + enum_name
        + String(" — matches ")
        + _join_names(matches)
        + String("; use the full value name")
    )


def unknown_enum_error(
    line: Int,
    col: Int,
    value: String,
    enum_name: String,
    known: List[String],
) -> String:
    """`line N: unknown value 'API' for enum AppKind — did you mean
    'APP_KIND_API'?`. The suggestion is the near-miss legal value; otherwise the
    legal value set is listed."""
    var msg = (
        pos_prefix(line, col)
        + String("unknown value '")
        + value
        + String("' for enum ")
        + enum_name
    )
    var s = suggest_enum(value, known)
    if s.byte_length() > 0:
        return msg + String(" — did you mean '") + s + String("'?")
    return msg + String(" (legal values: ") + _join_names(known) + String(")")
