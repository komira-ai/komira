# =============================================================================
# komira_test_infra/config.mojo -- `TestInfraConfig`, read from a textproto
# file whose path the test runner passes as `--testinfra-config=<path>`.
# =============================================================================
#
# The file's schema is public; its values are not. They describe a private
# deployment (an object-store endpoint, a bucket, a key prefix, a path where a
# credentials file is mounted), so this library holds no default for any of
# them, and a missing field is an error, never a fallback:
#
#   object_store {
#     endpoint: "<url>"
#     region: "<region>"
#     bucket: "<bucket>"
#     run_prefix: "<stem>/"           # every run lives under <run_prefix><run_id>/
#     credentials_file: "<abs path>"  # an AWS shared-credentials file
#   }
#   max_lease_seconds: <int>          # a run's lease: creation + this
#   teardown_budget_seconds: <int>    # stop creating this long before the deadline
#
# ⛔ NO MESSAGE CARRIES A VALUE. A test's output can land in a public log, so
# every refusal names the FIELD (`object_store.endpoint`) and the line, and
# never what the field holds. The lexer's own refusals can quote a character
# of the line they refuse, so they are rewritten here to keep only the line.
# `TestInfraConfig` is deliberately not `Writable`: printing one is a compile
# error, not a review comment.
#
# The credentials file named by `credentials_file` is never opened here. The
# object-store client reads it, through its own credential chain.
# =============================================================================

from komira_textproto import (
    TOKEN_COLON,
    TOKEN_LBRACE,
    TOKEN_NUMBER,
    TOKEN_RBRACE,
    TOKEN_STRING,
    TOKEN_WORD,
    Token,
    lex,
)

from .seams import FileSource

comptime _SOURCE: String = "testinfra config"

comptime _F_ENDPOINT: String = "object_store.endpoint"
comptime _F_REGION: String = "object_store.region"
comptime _F_BUCKET: String = "object_store.bucket"
comptime _F_RUN_PREFIX: String = "object_store.run_prefix"
comptime _F_CREDENTIALS_FILE: String = "object_store.credentials_file"
comptime _F_MAX_LEASE: String = "max_lease_seconds"
comptime _F_TEARDOWN: String = "teardown_budget_seconds"


struct TestInfraConfig(Copyable, Movable):
    """The parsed config. Every field was present in the file; none has a
    default. Not `Writable`, on purpose (see the module header)."""

    var endpoint: String
    var region: String
    var bucket: String
    var run_prefix: String
    var credentials_file: String
    var max_lease_seconds: Int
    var teardown_budget_seconds: Int

    def __init__(
        out self,
        var endpoint: String,
        var region: String,
        var bucket: String,
        var run_prefix: String,
        var credentials_file: String,
        max_lease_seconds: Int,
        teardown_budget_seconds: Int,
    ):
        self.endpoint = endpoint^
        self.region = region^
        self.bucket = bucket^
        self.run_prefix = run_prefix^
        self.credentials_file = credentials_file^
        self.max_lease_seconds = max_lease_seconds
        self.teardown_budget_seconds = teardown_budget_seconds


def _at(line: Int) -> String:
    return String(_SOURCE) + ": line " + String(line) + ": "


def _lexer_line(message: String) -> Int:
    """The line number in a lexer refusal (`<source>: line N: ...`), or 0."""
    var at = message.find("line ")
    if at < 0:
        return 0
    var b = message.as_bytes()
    var i = at + 5
    var n = 0
    var any = False
    while i < len(b) and Int(b[i]) >= ord("0") and Int(b[i]) <= ord("9"):
        n = n * 10 + (Int(b[i]) - ord("0"))
        i += 1
        any = True
    return n if any else 0


struct _Seen(Copyable, Movable):
    var endpoint: Bool
    var region: Bool
    var bucket: Bool
    var run_prefix: Bool
    var credentials_file: Bool
    var object_store: Bool
    var max_lease: Bool
    var teardown: Bool

    def __init__(out self):
        self.endpoint = False
        self.region = False
        self.bucket = False
        self.run_prefix = False
        self.credentials_file = False
        self.object_store = False
        self.max_lease = False
        self.teardown = False


struct _Parser(Movable):
    var toks: List[Token]
    var pos: Int

    def __init__(out self, var toks: List[Token]):
        self.toks = toks^
        self.pos = 0

    def at_end(self) -> Bool:
        return self.pos >= len(self.toks)

    def peek_kind(self) -> Int:
        if self.at_end():
            return -1
        return self.toks[self.pos].kind

    def line(self) -> Int:
        if self.at_end():
            if len(self.toks) == 0:
                return 1
            return self.toks[len(self.toks) - 1].line
        return self.toks[self.pos].line

    def take(mut self, what: String) raises -> Token:
        if self.at_end():
            raise Error(_at(self.line()) + "expected " + what + " but reached the end of the file")
        var t = self.toks[self.pos].copy()
        self.pos += 1
        return t^

    def scalar_colon(mut self, field: String) raises:
        var t = self.take("':' after " + field)
        if t.kind != TOKEN_COLON:
            raise Error(_at(t.line) + field + ": expected ':' after the field name")

    def string_value(mut self, field: String) raises -> String:
        self.scalar_colon(field)
        var t = self.take("a value for " + field)
        if t.kind != TOKEN_STRING:
            raise Error(_at(t.line) + field + ": expected a quoted string")
        return t.text

    def int_value(mut self, field: String) raises -> Int:
        self.scalar_colon(field)
        var t = self.take("a value for " + field)
        if t.kind != TOKEN_NUMBER:
            raise Error(_at(t.line) + field + ": expected a whole number")
        var b = t.text.as_bytes()
        if len(b) == 0 or len(b) > 9:
            raise Error(_at(t.line) + field + ": expected a whole number below 10^9")
        var v = 0
        for i in range(len(b)):
            var c = Int(b[i])
            if c < ord("0") or c > ord("9"):
                raise Error(_at(t.line) + field + ": expected a whole number (digits only)")
            v = v * 10 + (c - ord("0"))
        return v


def _refuse_duplicate(seen: Bool, line: Int, field: String) raises:
    if seen:
        raise Error(_at(line) + field + ": set more than once")


def parse_test_infra_config(text: String) raises -> TestInfraConfig:
    """Parse the config text. Every field is required; an unknown, repeated
    or mistyped field raises naming the field, and no message carries a
    value."""
    var toks: List[Token]
    try:
        toks = lex(text, String(_SOURCE))
    except e:
        raise Error(
            _at(_lexer_line(String(e)))
            + "not valid textproto (the lexer refused this line; its text is not shown)"
        )
    var p = _Parser(toks^)
    var seen = _Seen()
    var endpoint = String("")
    var region = String("")
    var bucket = String("")
    var run_prefix = String("")
    var credentials_file = String("")
    var max_lease = 0
    var teardown = 0
    var prefix_line = 0
    var teardown_line = 0
    var endpoint_line = 0
    var cred_line = 0

    while not p.at_end():
        var name = p.take("a field name")
        if name.kind != TOKEN_WORD:
            raise Error(_at(name.line) + "expected a field name")
        if name.text == "object_store":
            _refuse_duplicate(seen.object_store, name.line, "object_store")
            seen.object_store = True
            if p.peek_kind() == TOKEN_COLON:
                _ = p.take("':'")
            var open_brace = p.take("'{' after object_store")
            if open_brace.kind != TOKEN_LBRACE:
                raise Error(_at(open_brace.line) + "object_store: expected '{'")
            while True:
                if p.at_end():
                    raise Error(_at(p.line()) + "object_store: missing '}'")
                if p.peek_kind() == TOKEN_RBRACE:
                    _ = p.take("'}'")
                    break
                var f = p.take("a field name")
                if f.kind != TOKEN_WORD:
                    raise Error(_at(f.line) + "object_store: expected a field name")
                if f.text == "endpoint":
                    _refuse_duplicate(seen.endpoint, f.line, _F_ENDPOINT)
                    seen.endpoint = True
                    endpoint_line = f.line
                    endpoint = p.string_value(_F_ENDPOINT)
                elif f.text == "region":
                    _refuse_duplicate(seen.region, f.line, _F_REGION)
                    seen.region = True
                    region = p.string_value(_F_REGION)
                elif f.text == "bucket":
                    _refuse_duplicate(seen.bucket, f.line, _F_BUCKET)
                    seen.bucket = True
                    bucket = p.string_value(_F_BUCKET)
                elif f.text == "run_prefix":
                    _refuse_duplicate(seen.run_prefix, f.line, _F_RUN_PREFIX)
                    seen.run_prefix = True
                    prefix_line = f.line
                    run_prefix = p.string_value(_F_RUN_PREFIX)
                elif f.text == "credentials_file":
                    _refuse_duplicate(seen.credentials_file, f.line, _F_CREDENTIALS_FILE)
                    seen.credentials_file = True
                    cred_line = f.line
                    credentials_file = p.string_value(_F_CREDENTIALS_FILE)
                else:
                    raise Error(_at(f.line) + "unknown field " + _shown_name("object_store.", f.text))
        elif name.text == "max_lease_seconds":
            _refuse_duplicate(seen.max_lease, name.line, _F_MAX_LEASE)
            seen.max_lease = True
            max_lease = p.int_value(_F_MAX_LEASE)
        elif name.text == "teardown_budget_seconds":
            _refuse_duplicate(seen.teardown, name.line, _F_TEARDOWN)
            seen.teardown = True
            teardown_line = name.line
            teardown = p.int_value(_F_TEARDOWN)
        else:
            raise Error(_at(name.line) + "unknown field " + _shown_name("", name.text))

    var missing = List[String]()
    if not seen.endpoint:
        missing.append(String(_F_ENDPOINT))
    if not seen.region:
        missing.append(String(_F_REGION))
    if not seen.bucket:
        missing.append(String(_F_BUCKET))
    if not seen.run_prefix:
        missing.append(String(_F_RUN_PREFIX))
    if not seen.credentials_file:
        missing.append(String(_F_CREDENTIALS_FILE))
    if not seen.max_lease:
        missing.append(String(_F_MAX_LEASE))
    if not seen.teardown:
        missing.append(String(_F_TEARDOWN))
    if len(missing) > 0:
        var msg = String(_SOURCE) + ": missing required field"
        if len(missing) > 1:
            msg += "s"
        msg += ": "
        for i in range(len(missing)):
            if i > 0:
                msg += ", "
            msg += missing[i]
        raise Error(msg)

    _require_nonempty(endpoint, _F_ENDPOINT)
    _require_nonempty(region, _F_REGION)
    _require_nonempty(bucket, _F_BUCKET)
    _require_nonempty(run_prefix, _F_RUN_PREFIX)
    _require_nonempty(credentials_file, _F_CREDENTIALS_FILE)
    if not (endpoint.startswith("http://") or endpoint.startswith("https://")):
        raise Error(_at(endpoint_line) + _F_ENDPOINT + ": must start with http:// or https://")
    if not run_prefix.endswith("/") or run_prefix.startswith("/"):
        raise Error(
            _at(prefix_line) + _F_RUN_PREFIX + ": must end with '/' and must not start with '/'"
        )
    if _has_dot_segment(run_prefix):
        raise Error(_at(prefix_line) + _F_RUN_PREFIX + ": must not hold a '.' or '..' segment")
    if not credentials_file.startswith("/"):
        raise Error(_at(cred_line) + _F_CREDENTIALS_FILE + ": must be an absolute path")
    if max_lease <= 0:
        raise Error(String(_SOURCE) + ": " + _F_MAX_LEASE + ": must be positive")
    if teardown <= 0 or teardown >= max_lease:
        raise Error(
            _at(teardown_line)
            + _F_TEARDOWN
            + ": must be positive and below "
            + _F_MAX_LEASE
        )
    return TestInfraConfig(
        endpoint^,
        region^,
        bucket^,
        run_prefix^,
        credentials_file^,
        max_lease,
        teardown,
    )


def _shown_name(parent: String, name: String) -> String:
    """`name` when it is a plain identifier, else a placeholder. A misplaced
    VALUE (an unquoted host name, say) lexes as a bareword and arrives here
    as a "field name"; only identifier-shaped words are echoed, so a dotted
    host or a URL fragment never is."""
    var b = name.as_bytes()
    var ok = len(b) > 0 and len(b) <= 40
    for i in range(len(b)):
        var c = Int(b[i])
        var lower = c >= ord("a") and c <= ord("z")
        var digit = c >= ord("0") and c <= ord("9")
        if not (lower or c == ord("_") or (digit and i > 0)):
            ok = False
    if ok:
        return parent + name
    return parent + "(name not shown: not an identifier)"


def _require_nonempty(value: String, field: String) raises:
    if value.byte_length() == 0:
        raise Error(String(_SOURCE) + ": " + field + ": must not be empty")


def _has_dot_segment(path: String) -> Bool:
    for seg in path.split("/"):
        if seg == "." or seg == "..":
            return True
    return False


def load_test_infra_config[F: FileSource](path: String, mut files: F) raises -> TestInfraConfig:
    """Read and parse the config file at `path`. A read failure names the
    path (a path is not a deployment fact); a parse failure names the field."""
    var text: String
    try:
        text = files.read(path)
    except:
        raise Error(String(_SOURCE) + ": cannot read the file named by --testinfra-config")
    return parse_test_infra_config(text)
