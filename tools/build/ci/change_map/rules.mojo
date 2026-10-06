"""The widening and inert patterns, read from a data file (see rules.txt)."""

from buildtools.bytes import join, read_file, split_words, substr, suffix, to_string


struct Rule(Copyable, Movable):
    """One `widen` line: the pattern and why a match widens."""

    var pattern: String
    var reason: String

    def __init__(out self, var pattern: String, var reason: String):
        self.pattern = pattern^
        self.reason = reason^


struct Rules(Copyable, Movable):
    """The `widen` rules in file order, the `inert` patterns and the
    `universe`: the target patterns whose targets are the whole graph."""

    var widen: List[Rule]
    var inert: List[String]
    var universe: List[String]

    def __init__(out self):
        self.widen = List[Rule]()
        self.inert = List[String]()
        self.universe = List[String]()

    def widen_reason(self, path: String) -> String:
        """`<pattern>: <reason>` of the first widen rule `path` matches, or
        the empty string."""
        for i in range(len(self.widen)):
            if pattern_matches(self.widen[i].pattern, path):
                return self.widen[i].pattern + String(": ") + self.widen[i].reason
        return String("")

    def is_inert(self, path: String) -> Bool:
        for i in range(len(self.inert)):
            if pattern_matches(self.inert[i], path):
                return True
        return False


def pattern_matches(pattern: String, path: String) -> Bool:
    """`dir/**` and `text*` match by prefix, `*text` by suffix, anything
    else exactly."""
    var n = pattern.byte_length()
    if pattern.endswith(String("/**")):
        return path.startswith(substr(pattern, 0, n - 2))
    if pattern.endswith(String("*")):
        return path.startswith(substr(pattern, 0, n - 1))
    if pattern.startswith(String("*")):
        return path.endswith(suffix(pattern, 1))
    return path == pattern


def _check_pattern(pattern: String, line_no: Int) raises:
    var body = pattern.copy()
    if body.endswith(String("/**")):
        body = substr(body, 0, body.byte_length() - 3)
    elif body.endswith(String("*")):
        body = substr(body, 0, body.byte_length() - 1)
    elif body.startswith(String("*")):
        body = suffix(body, 1)
    if body.find(String("*")) >= 0 or body.byte_length() == 0:
        raise Error(
            String("rules line ") + String(line_no) + String(": pattern '") + pattern
            + String("' is not a path, `dir/**`, `text*` or `*text`")
        )


def parse_rules(text: String) raises -> Rules:
    """Parse the data file. A line it cannot read is an error: a pattern
    that silently matched nothing would be a widening that never fires."""
    var rules = Rules()
    var lines = text.split(String("\n"))
    for i in range(len(lines)):
        var words = split_words(String(lines[i]))
        if len(words) == 0 or words[0].startswith(String("#")):
            continue
        var kind = words[0]
        if len(words) < 2:
            raise Error(String("rules line ") + String(i + 1) + String(": '") + kind + String("' has no pattern"))
        if kind == String("universe"):
            if len(words) != 2:
                raise Error(String("rules line ") + String(i + 1) + String(": a universe rule is `universe <target pattern>`"))
            rules.universe.append(words[1])
            continue
        _check_pattern(words[1], i + 1)
        if kind == String("widen"):
            if len(words) < 3:
                raise Error(String("rules line ") + String(i + 1) + String(": a widen rule needs a reason"))
            var rest = List[String]()
            for k in range(2, len(words)):
                rest.append(words[k])
            rules.widen.append(Rule(words[1], join(rest, String(" "))))
        elif kind == String("inert"):
            if len(words) != 2:
                raise Error(String("rules line ") + String(i + 1) + String(": an inert rule is `inert <pattern>`"))
            rules.inert.append(words[1])
        else:
            raise Error(String("rules line ") + String(i + 1) + String(": unknown rule kind '") + kind + String("'"))
    return rules^


def read_rules(path: String) raises -> Rules:
    return parse_rules(to_string(read_file(path)))
