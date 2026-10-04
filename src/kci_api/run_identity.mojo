# =============================================================================
# src/kci_contract/run_identity.mojo -- who is running kci: `--run-id`,
#   `--attempt` and `--context key=value`, checked.
# =============================================================================
#
#   --run-id <id>        REQUIRED. 1 to 63 bytes of `[a-z0-9_-]`: label-safe,
#                        so the same id can later be stamped on cloud objects.
#                        kci mints none: a driver passes one (GitHub Actions:
#                        `gh-<run_id>`).
#   --attempt <n>        REQUIRED. A positive decimal integer, no sign, no
#                        leading zero. No default: an omitted attempt is a
#                        usage error, never "1".
#   --context key=value  optional, repeatable, at most 32. key
#                        `[a-z][a-z0-9_]{0,31}`, unique; value at most 256
#                        bytes of printable ASCII (0x20..0x7E). Recorded
#                        VERBATIM in the result document and NOT trusted:
#                        anyone who runs kci can write anything here, so no
#                        decision reads it and no produced artifact carries it.
#
# kci reads no CI vendor's environment variable for any of this.
# Pure functions over owned values; no pointer.
# =============================================================================

comptime RUN_ID_MAX_BYTES: Int = 63
comptime CONTEXT_MAX_ENTRIES: Int = 32
comptime CONTEXT_KEY_MAX_BYTES: Int = 32
comptime CONTEXT_VALUE_MAX_BYTES: Int = 256


struct ContextEntry(Copyable, Movable, Equatable):
    """One `--context key=value`.

    Layout: owned Strings. No pointer field."""

    var key: String
    var value: String

    def __init__(out self, var key: String, var value: String):
        self.key = key^
        self.value = value^

    def __eq__(self, other: Self) -> Bool:
        return self.key == other.key and self.value == other.value


def require_run_id(id: String) raises:
    """Refuse a run id outside the grammar (file header)."""
    var b = id.as_bytes()
    if len(b) == 0:
        raise Error(String("--run-id is EMPTY"))
    if len(b) > RUN_ID_MAX_BYTES:
        raise Error(
            String("--run-id is ") + String(len(b)) + String(" bytes; at most ")
            + String(RUN_ID_MAX_BYTES)
        )
    for i in range(len(b)):
        var c = Int(b[i])
        var ok = (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45
        if not ok:
            raise Error(
                String("--run-id '") + id
                + String("' holds a byte outside [a-z0-9_-] (label-safe ids only)")
            )


def parse_attempt(text: String) raises -> Int:
    """`--attempt`'s value as a positive integer (file header)."""
    var b = text.as_bytes()
    if len(b) == 0:
        raise Error(String("--attempt is EMPTY"))
    if len(b) > 9:
        raise Error(String("--attempt '") + text + String("' is too large"))
    var n = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            raise Error(String("--attempt '") + text + String("' is not a positive decimal integer"))
        n = n * 10 + (c - 48)
    if Int(b[0]) == 48:
        raise Error(String("--attempt '") + text + String("' is not a positive decimal integer"))
    return n


def require_attempt(n: Int) raises:
    if n <= 0:
        raise Error(String("--attempt ") + String(n) + String(" is not positive"))


def require_context_key(key: String) raises:
    var b = key.as_bytes()
    if len(b) == 0 or len(b) > CONTEXT_KEY_MAX_BYTES:
        raise Error(
            String("--context key '") + key + String("' is not 1 to ")
            + String(CONTEXT_KEY_MAX_BYTES) + String(" bytes")
        )
    for i in range(len(b)):
        var c = Int(b[i])
        var lower = c >= 97 and c <= 122
        var ok = lower if i == 0 else (lower or (c >= 48 and c <= 57) or c == 95)
        if not ok:
            raise Error(
                String("--context key '") + key + String("' is not [a-z][a-z0-9_]*")
            )


def require_context_value(key: String, value: String) raises:
    var b = value.as_bytes()
    if len(b) > CONTEXT_VALUE_MAX_BYTES:
        raise Error(
            String("--context ") + key + String(": the value is ") + String(len(b))
            + String(" bytes; at most ") + String(CONTEXT_VALUE_MAX_BYTES)
        )
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 32 or c > 126:
            raise Error(
                String("--context ") + key
                + String(": the value holds a byte outside printable ASCII (byte ")
                + String(i) + String(")")
            )


def parse_context_arg(arg: String) raises -> ContextEntry:
    """`key=value` (the first `=` splits) as a checked entry."""
    var eq = arg.find(String("="))
    if eq < 0:
        raise Error(String("--context '") + arg + String("' is not key=value"))
    var key = String(arg[byte = :eq])
    var value = String(arg[byte = eq + 1 :])
    require_context_key(key)
    require_context_value(key, value)
    return ContextEntry(key^, value^)


struct RunIdentity(Copyable, Movable):
    """`--run-id`, `--attempt` and every `--context`, in the order given.
    Built only through the checking constructor and `add_context`, so a
    value of this type obeys the grammar.

    Layout: owned values only. No pointer field."""

    var run_id: String
    var attempt: Int
    var context: List[ContextEntry]

    def __init__(out self, var run_id: String, attempt: Int) raises:
        require_run_id(run_id)
        require_attempt(attempt)
        self.run_id = run_id^
        self.attempt = attempt
        self.context = List[ContextEntry]()

    def add_context(mut self, var entry: ContextEntry) raises:
        """Add one checked entry; refuses a repeated key and the 33rd entry."""
        require_context_key(entry.key)
        require_context_value(entry.key, entry.value)
        for i in range(len(self.context)):
            if self.context[i].key == entry.key:
                raise Error(String("--context ") + entry.key + String(" is given twice"))
        if len(self.context) >= CONTEXT_MAX_ENTRIES:
            raise Error(
                String("--context is given more than ") + String(CONTEXT_MAX_ENTRIES)
                + String(" times")
            )
        self.context.append(entry^)

    def same_as(self, other: RunIdentity) -> Bool:
        if self.run_id != other.run_id or self.attempt != other.attempt:
            return False
        if len(self.context) != len(other.context):
            return False
        for i in range(len(self.context)):
            if not (self.context[i] == other.context[i]):
                return False
        return True
