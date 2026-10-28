# =============================================================================
# rule -- one extraction rule: an entity type and a matcher, both host data.
# =============================================================================
#
# A `Rule` says "text that looks like THIS is an entity of type THAT". The type
# is an opaque string the host chooses (it may be empty); the package fixes no
# vocabulary. A matcher is one of:
#
#   word list       a token equal, ignoring ASCII case, to one of the words.
#   verb prefix     a token equal, ignoring ASCII case, to one of the words and
#                   followed by a token that starts with a letter: the entity
#                   is the two tokens joined by one space.
#   token pattern   a token that a `Pattern` (see rule_pattern) matches whole.
#   delimited       the text between an opening and a closing delimiter, on one
#                   line, not empty and at most `RULE_MAX_SPAN_BYTES` long.
#   email           an address: a local part, `@`, and a dotted domain.
#   url             a scheme (a letter, then letters, digits, `+`, `.` or `-`),
#                   then `://` and at least one more byte.
#
# A token is a run of non-whitespace bytes with the brackets, quotes and
# sentence punctuation named in `rule_scan` trimmed off both ends. Constructors
# refuse a rule that can never match (a word or pattern a token cannot hold), so a mistake in a rule set shows when the
# rule is built and not as a silent miss.
# =============================================================================

from .rule_pattern import (
    Pattern,
    is_leading_trim_byte,
    is_space_byte,
    is_trailing_trim_byte,
)

comptime RULE_WORD_LIST: Int = 0
comptime RULE_VERB_PREFIX: Int = 1
comptime RULE_TOKEN_PATTERN: Int = 2
comptime RULE_DELIMITED: Int = 3
comptime RULE_EMAIL: Int = 4
comptime RULE_URL: Int = 5

comptime RULE_MAX_SPAN_BYTES: Int = 200
"""The longest delimited span a rule accepts, in bytes."""


def ascii_lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= 65 and c <= 90:
            c += 32
        out.append(c)
    # SAFETY: only ASCII letters change, and ASCII never occurs inside a
    # multi-byte sequence, so the output is the well-formed input re-cased.
    return String(unsafe_from_utf8=Span(out))


def _lowered_words(words: List[String], who: String) raises -> List[String]:
    if len(words) == 0:
        raise Error(who + ": the word list is empty, so the rule never matches")
    var out = List[String](capacity=len(words))
    for i in range(len(words)):
        var b = words[i].as_bytes()
        if len(b) == 0:
            raise Error(who + ": word " + String(i) + " is empty")
        for k in range(len(b)):
            if is_space_byte(Int(b[k])):
                raise Error(
                    who
                    + ": word "
                    + String(i)
                    + " holds whitespace, and a token never does"
                )
        if is_leading_trim_byte(Int(b[0])):
            raise Error(
                who
                + ": word "
                + String(i)
                + " starts with a byte a token loses from its start, so it"
                " never matches"
            )
        if is_trailing_trim_byte(Int(b[len(b) - 1])):
            raise Error(
                who
                + ": word "
                + String(i)
                + " ends with a byte a token loses from its end, so it never"
                " matches"
            )
        out.append(ascii_lower(words[i]))
    return out^


struct Rule(Copyable, Movable):
    """One extraction rule. Build it with a static constructor.

    Fields:
        entity_type: The type label an entity found by this rule carries.
        kind: Which matcher this is (one of the `RULE_*` constants).
        terms: The lower-cased words of a word-list or verb-prefix rule.
        open_delim: The opening delimiter of a delimited rule.
        close_delim: The closing delimiter of a delimited rule.
        patterns: One compiled pattern for a token-pattern rule, else empty.
    """

    var entity_type: String
    var kind: Int
    var terms: List[String]
    var open_delim: String
    var close_delim: String
    var patterns: List[Pattern]

    def __init__(
        out self,
        var entity_type: String,
        kind: Int,
        var terms: List[String],
        var open_delim: String,
        var close_delim: String,
        var patterns: List[Pattern],
    ):
        self.entity_type = entity_type^
        self.kind = kind
        self.terms = terms^
        self.open_delim = open_delim^
        self.close_delim = close_delim^
        self.patterns = patterns^

    @staticmethod
    def word_list(
        var entity_type: String, words: List[String]
    ) raises -> Rule:
        """A rule for tokens equal (ignoring ASCII case) to one of `words`.

        Raises:
            If `words` is empty, or a word is empty, holds whitespace, starts
            with one of `( [ { " '` or ends with one of `. , ; : ! ? ) ] } " '`
            (a token never does, so the word could not match).
        """
        return Rule(
            entity_type^,
            RULE_WORD_LIST,
            _lowered_words(words, "Rule.word_list"),
            String(""),
            String(""),
            List[Pattern](),
        )

    @staticmethod
    def verb_prefix(
        var entity_type: String, verbs: List[String]
    ) raises -> Rule:
        """A rule for a verb token and the word after it, as one entity.

        Raises:
            If `verbs` is empty, or a verb is empty, holds whitespace, starts
            with one of `( [ { " '` or ends with one of `. , ; : ! ? ) ] } " '`.
        """
        return Rule(
            entity_type^,
            RULE_VERB_PREFIX,
            _lowered_words(verbs, "Rule.verb_prefix"),
            String(""),
            String(""),
            List[Pattern](),
        )

    @staticmethod
    def token_pattern(
        var entity_type: String, pattern: String
    ) raises -> Rule:
        """A rule for tokens a pattern matches whole.

        Raises:
            If the pattern does not compile or can match no token (see
            `Pattern.compile`).
        """
        var patterns = List[Pattern]()
        patterns.append(Pattern.compile(pattern))
        return Rule(
            entity_type^,
            RULE_TOKEN_PATTERN,
            List[String](),
            String(""),
            String(""),
            patterns^,
        )

    @staticmethod
    def delimited(
        var entity_type: String, var open_delim: String, var close_delim: String
    ) raises -> Rule:
        """A rule for the text between `open_delim` and `close_delim` on one line.

        Raises:
            If a delimiter is empty or holds a newline.
        """
        var ob = open_delim.as_bytes()
        var cb = close_delim.as_bytes()
        if len(ob) == 0 or len(cb) == 0:
            raise Error("Rule.delimited: a delimiter is empty")
        for i in range(len(ob)):
            if Int(ob[i]) == 10:
                raise Error("Rule.delimited: the opening delimiter has a newline")
        for i in range(len(cb)):
            if Int(cb[i]) == 10:
                raise Error("Rule.delimited: the closing delimiter has a newline")
        return Rule(
            entity_type^,
            RULE_DELIMITED,
            List[String](),
            open_delim^,
            close_delim^,
            List[Pattern](),
        )

    @staticmethod
    def quoted(var entity_type: String) raises -> Rule:
        """A rule for text between double quotes on one line."""
        return Rule.delimited(entity_type^, String('"'), String('"'))

    @staticmethod
    def email(var entity_type: String) -> Rule:
        """A rule for email addresses."""
        return Rule(
            entity_type^,
            RULE_EMAIL,
            List[String](),
            String(""),
            String(""),
            List[Pattern](),
        )

    @staticmethod
    def url(var entity_type: String) -> Rule:
        """A rule for URLs of any scheme."""
        return Rule(
            entity_type^,
            RULE_URL,
            List[String](),
            String(""),
            String(""),
            List[Pattern](),
        )
