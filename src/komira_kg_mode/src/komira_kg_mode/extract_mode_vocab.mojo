# =============================================================================
# komira_kg_mode/extract_mode_vocab.mojo -- the extraction-mode vocabulary: two
#   ordinals, a fail-safe parse of a name and a fail-safe normalisation of a
#   stored integer.
# =============================================================================
#
# Two modes exist. RULES extracts with typed rules and no generative model, so
# no document body leaves the process; it is the default. MODEL reads raw bodies
# through a model the host injects. MODEL is the one mode that changes where data
# goes, so every ambiguous input resolves away from it: it is chosen only by
# spelling its name exactly (case aside) or by storing its ordinal.
#
# The ordinals are stored in a graph spec, so their values are fixed: a new mode
# takes a new number and an existing number never changes meaning.
#
# The package has no dependencies: a spec package and an extractor package both
# need the vocabulary and neither may depend on the other, so it lives in a leaf
# that depends on nothing. It reads no environment; the host passes the name it
# got from a flag.
# =============================================================================


comptime EXTRACT_MODE_RULES: Int = 0
"""Extraction by typed rules, with no generative model. The default."""

comptime EXTRACT_MODE_MODEL: Int = 1
"""Extraction by an injected model that reads raw document bodies. Opt-in."""

comptime EXTRACT_MODE_COUNT: Int = 2
"""How many mode ordinals exist; they are `0 .. EXTRACT_MODE_COUNT - 1`."""

comptime KgExtractMode = Int
"""Alias for the mode type, so call sites read as intent."""


def is_known_extract_mode(mode: Int) -> Bool:
    """True when `mode` is one of the declared ordinals."""
    return mode == EXTRACT_MODE_RULES or mode == EXTRACT_MODE_MODEL


def normalize_extract_mode(mode: Int) -> KgExtractMode:
    """Resolve a stored integer mode: an unknown ordinal becomes RULES.

    An ordinal from a newer writer or a damaged row is ambiguous, and the only
    safe answer is the mode that sends no data to a model. A known ordinal comes
    back unchanged, so a stored MODEL stays MODEL.
    """
    if is_known_extract_mode(mode):
        return mode
    return EXTRACT_MODE_RULES


def parse_extract_mode(raw: String) -> KgExtractMode:
    """Resolve a mode from a name the host got from a flag.

    - `"rules"` gives RULES and `"model"` gives MODEL, in any ASCII case.
    - The empty string and every other string give RULES.

    A misspelling never turns a model on. The unknown-name arm is deliberate:
    it does not raise and does not warn and proceed.
    """
    if _equals_ignore_ascii_case(raw, "model"):
        return EXTRACT_MODE_MODEL
    return EXTRACT_MODE_RULES


def extract_mode_name(mode: Int) -> StaticString:
    """The canonical lowercase name of a mode, for logs and API output.

    An unknown ordinal renders as `unknown`, never as a mode it is not.
    """
    if mode == EXTRACT_MODE_RULES:
        return "rules"
    if mode == EXTRACT_MODE_MODEL:
        return "model"
    return "unknown"


def _equals_ignore_ascii_case(s: String, lower: StaticString) -> Bool:
    """True when `s` equals the all-lowercase ASCII `lower`, folding only the
    ASCII letters A-Z of `s`."""
    var a = s.as_bytes()
    var b = lower.as_bytes()
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        var c = Int(a[i])
        if c >= 65 and c <= 90:
            c += 32
        if c != Int(b[i]):
            return False
    return True
