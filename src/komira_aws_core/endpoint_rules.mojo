# =============================================================================
# komira_aws_core/endpoint_rules.mojo -- the endpoint ruleset interpreter
# =============================================================================
#
# An AWS service publishes how its endpoints are chosen as data: a Smithy
# endpoint ruleset (`endpoint-rule-set-1.json` next to each botocore service
# model). `EndpointRuleSet` evaluates any such ruleset against a set of
# parameters and returns either the endpoint (its URL, headers and
# properties, the `authSchemes` among them) or the error message the
# ruleset chose. Nothing in this file names a service, a region, an
# addressing style or an ARN shape: those are all branches of the data.
#
# The reference for every behaviour below is botocore's interpreter,
# `botocore/endpoint_provider.py`, at the release whose rulesets and test
# cases are pinned in third_party/botocore; that is the implementation the
# pinned test cases are checked against upstream.
#
#   - Rules are evaluated in order. A rule's conditions are function calls,
#     each of which may `assign` its result to a name; a condition holds
#     unless its result is false or unset. A rule whose conditions hold is
#     an `endpoint` (resolved and returned), an `error` (its message
#     returned), or a `tree` whose rules are evaluated in turn. A tree none
#     of whose rules apply falls through to the next rule, as in botocore.
#     When no top-level rule applies the ruleset is malformed (Smithy ends
#     every rule list in an unconditional rule), and resolving raises.
#   - Names assigned by a rule's conditions are seen by that rule and the
#     rules under it, never by its siblings. Assigning a name that is
#     already in scope is an error.
#   - A string containing a `{name}` or `{name#attr}` reference is a
#     template; `{{` and `}}` are literal braces in one.
#   - The standard library: isSet, not, stringEquals, booleanEquals,
#     substring, uriEncode, parseURL, isValidHostLabel, getAttr, and the AWS
#     functions aws.partition, aws.parseArn and aws.isVirtualHostableS3Bucket.
#     A ruleset calling any other function is refused when it is loaded.
#
# Inputs are parameters only: this file reads no environment, file or
# clock. The caller supplies the ruleset text, the partitions table
# (partitions.mojo) and each parameter value.
#
# Two kinds of failure are kept apart. An `error` rule is an ANSWER: the
# parameters name no endpoint, and `EndpointOutcome.error` says why in the
# ruleset's words. A raised Error is a FAULT: the ruleset is malformed
# (including one where no top-level rule applies), a function got arguments
# of the wrong type, or a parameter is missing or of the wrong type. Every
# raised message starts with `EndpointRules:`.
# =============================================================================

from komira_json import (
    JSON_ARRAY,
    JSON_BOOL,
    JSON_NULL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_value,
)

from ._regex import Regex
from ._text import ascii_lower, sub
from .partitions import AwsPartitionSet
from .sigv4 import uri_encode


# Nesting allowed in a ruleset document: deeper than the JSON default,
# because a ruleset nests a rule, its rules array and its conditions per
# level. The pinned S3 ruleset is about 40 deep.
comptime ENDPOINT_RULESET_MAX_DEPTH = 512


def _fault(what: String) -> Error:
    return Error("EndpointRules: " + what)


# -----------------------------------------------------------------------------
# Parameters and results
# -----------------------------------------------------------------------------


struct EndpointParams(Copyable, Movable):
    """The parameter values one resolution runs with, by ruleset parameter
    name. A parameter that is not set takes the ruleset's default."""

    var names: List[String]
    var values: List[JsonValue]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[JsonValue]()

    def _index(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def set_json(mut self, name: String, var value: JsonValue):
        """Sets `name` to `value`; a JSON null unsets it."""
        var i = self._index(name)
        if value.kind == JSON_NULL:
            if i >= 0:
                _ = self.names.pop(i)
                _ = self.values.pop(i)
            return
        if i >= 0:
            self.values[i] = value^
        else:
            self.names.append(name)
            self.values.append(value^)

    def set_string(mut self, name: String, value: String):
        self.set_json(name, JsonValue.from_string(value))

    def set_bool(mut self, name: String, value: Bool):
        self.set_json(name, JsonValue.from_bool(value))

    def set_string_array(mut self, name: String, values: List[String]):
        var a = JsonValue.empty_array()
        for i in range(len(values)):
            a.children.append(JsonValue.from_string(values[i]))
        self.set_json(name, a^)


struct ResolvedEndpoint(Copyable, Movable):
    """An endpoint a ruleset chose: the URL, the headers to send (an object
    of header name to an array of values), and the properties (an object;
    `authSchemes`, when present, says how to sign)."""

    var url: String
    var headers: JsonValue
    var properties: JsonValue

    def __init__(out self):
        self.url = String("")
        self.headers = JsonValue.empty_object()
        self.properties = JsonValue.empty_object()

    def __init__(
        out self, var url: String, var headers: JsonValue, var properties: JsonValue
    ):
        self.url = url^
        self.headers = headers^
        self.properties = properties^

    def auth_schemes(self) -> JsonValue:
        """The `authSchemes` property (an array), or an empty array."""
        for i in range(len(self.properties.obj_keys)):
            if self.properties.obj_keys[i] == "authSchemes":
                return self.properties.children[i].copy()
        return JsonValue.empty_array()


struct EndpointOutcome(Copyable, Movable):
    """What a resolution answered: an endpoint, or (`is_error`) the error
    message of the `error` rule that applied."""

    var is_error: Bool
    var error: String
    var endpoint: ResolvedEndpoint

    def __init__(out self):
        self.is_error = False
        self.error = String("")
        self.endpoint = ResolvedEndpoint()

    @staticmethod
    def of_error(var message: String) -> EndpointOutcome:
        var o = EndpointOutcome()
        o.is_error = True
        o.error = message^
        return o^

    @staticmethod
    def of_endpoint(var endpoint: ResolvedEndpoint) -> EndpointOutcome:
        var o = EndpointOutcome()
        o.endpoint = endpoint^
        return o^


# -----------------------------------------------------------------------------
# JSON helpers
# -----------------------------------------------------------------------------


def _find(v: JsonValue, key: String) -> Int:
    """The index of member `key` of object `v`, or -1."""
    if v.kind != JSON_OBJECT:
        return -1
    for i in range(len(v.obj_keys)):
        if v.obj_keys[i] == key:
            return i
    return -1


def _need(v: JsonValue, key: String, kind: Int, where: String) raises -> Int:
    var i = _find(v, key)
    if i < 0:
        raise _fault(where + " has no '" + key + "'")
    if v.children[i].kind != kind:
        raise _fault(where + ": '" + key + "' has the wrong JSON kind")
    return i


def _split(s: String, sep: UInt8) -> List[String]:
    """`s` split at every `sep` byte (Python's `str.split(sep)`)."""
    var out = List[String]()
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == sep:
            out.append(sub(s, start, i))
            start = i + 1
    out.append(sub(s, start, len(b)))
    return out^


def _is_digit(c: UInt8) -> Bool:
    return c >= 0x30 and c <= 0x39


def _is_alpha(c: UInt8) -> Bool:
    return (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A)


def _is_word(c: UInt8) -> Bool:
    return _is_alpha(c) or _is_digit(c) or c == 0x5F


def _truthy(v: JsonValue) -> Bool:
    """Python truthiness, which botocore's `not` applies."""
    if v.kind == JSON_NULL:
        return False
    if v.kind == JSON_BOOL:
        return v.bool_val
    if v.kind == JSON_STRING:
        return v.text.byte_length() > 0
    if v.kind == JSON_NUMBER:
        try:
            return Float64(v.text) != 0.0
        except:
            return True
    return len(v.children) > 0


def _kind_name(v: JsonValue) -> String:
    if v.kind == JSON_NULL:
        return "unset"
    if v.kind == JSON_BOOL:
        return "a boolean"
    if v.kind == JSON_NUMBER:
        return "a number"
    if v.kind == JSON_STRING:
        return "a string"
    if v.kind == JSON_ARRAY:
        return "an array"
    return "an object"


# -----------------------------------------------------------------------------
# URL and host functions
# -----------------------------------------------------------------------------


def _is_host_label(value: String) -> Bool:
    """One RFC 1123 label: 1 to 63 of ASCII [A-Za-z0-9-], not starting or
    ending with '-'. Stricter than botocore's VALID_HOST_LABEL_RE, whose `$`
    also matches before a final line feed and whose `\\d` also matches
    non-ASCII digits; both are refused here."""
    var b = value.as_bytes()
    var n = len(b)
    if n < 1 or n > 63:
        return False
    if b[0] == UInt8(ord("-")) or b[n - 1] == UInt8(ord("-")):
        return False
    for i in range(n):
        var c = b[i]
        if not (_is_alpha(c) or _is_digit(c) or c == UInt8(ord("-"))):
            return False
    return True


def is_valid_host_label(value: String, allow_subdomains: Bool) -> Bool:
    """The ruleset function `isValidHostLabel`: `value` is one host label,
    or with `allow_subdomains` a dot-separated run of them."""
    if not allow_subdomains:
        if value.find(".") >= 0:
            return False
        return _is_host_label(value)
    var labels = _split(value, UInt8(ord(".")))
    for i in range(len(labels)):
        if not _is_host_label(labels[i]):
            return False
    return True


def _remove_dot_segments(path: String) -> String:
    """botocore's `remove_dot_segments` (botocore/utils.py): RFC 3986
    section 5.2.4, with empty segments dropped as well."""
    var parts = _split(path, UInt8(ord("/")))
    var kept = List[String]()
    for i in range(len(parts)):
        var x = parts[i]
        if x.byte_length() == 0 or x == ".":
            continue
        if x == "..":
            if len(kept) > 0:
                _ = kept.pop()
        else:
            kept.append(x)
    var b = path.as_bytes()
    var out = String("")
    if len(b) > 0 and b[0] == UInt8(ord("/")):
        out += "/"
    for i in range(len(kept)):
        if i > 0:
            out += "/"
        out += kept[i]
    if len(b) > 0 and b[len(b) - 1] == UInt8(ord("/")) and len(kept) > 0:
        out += "/"
    return out^


struct _Url(Copyable, Movable):
    """The parts of a URL as Python's `urllib.parse.urlparse` splits them."""

    var ok: Bool
    var scheme: String
    var netloc: String
    var path: String
    var query: String

    def __init__(out self):
        self.ok = False
        self.scheme = String("")
        self.netloc = String("")
        self.path = String("")
        self.query = String("")


def _strip_url(value: String) -> String:
    """urlsplit's input cleaning: leading C0 controls and spaces dropped,
    and every tab, CR and LF removed."""
    var b = value.as_bytes()
    var out = List[UInt8]()
    var leading = True
    for i in range(len(b)):
        var c = b[i]
        if leading and c <= 0x20:
            continue
        leading = False
        if c == 0x09 or c == 0x0A or c == 0x0D:
            continue
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def _urlparse(value: String) -> _Url:
    var u = _Url()
    var s = _strip_url(value)
    var b = s.as_bytes()
    var n = len(b)
    var rest_at = 0
    # The scheme: an ASCII letter, then letters, digits, '+', '-', '.'.
    var colon = s.find(":")
    if colon > 0 and _is_alpha(b[0]):
        var all_ok = True
        for i in range(colon):
            var c = b[i]
            if not (
                _is_alpha(c)
                or _is_digit(c)
                or c == UInt8(ord("+"))
                or c == UInt8(ord("-"))
                or c == UInt8(ord("."))
            ):
                all_ok = False
                break
        if all_ok:
            u.scheme = ascii_lower(sub(s, 0, colon))
            rest_at = colon + 1
    var rest = sub(s, rest_at, n)
    var rb = rest.as_bytes()
    var rn = len(rb)
    var at = 0
    if rn >= 2 and rb[0] == UInt8(ord("/")) and rb[1] == UInt8(ord("/")):
        var delim = rn
        for i in range(2, rn):
            var c = rb[i]
            if c == UInt8(ord("/")) or c == UInt8(ord("?")) or c == UInt8(ord("#")):
                delim = i
                break
        u.netloc = sub(rest, 2, delim)
        at = delim
        var has_open = u.netloc.find("[") >= 0
        var has_close = u.netloc.find("]") >= 0
        if has_open != has_close:
            return u^  # "Invalid IPv6 URL"
    var tail = sub(rest, at, rn)
    var hash = tail.find("#")
    if hash >= 0:
        tail = sub(tail, 0, hash)
    var q = tail.find("?")
    if q >= 0:
        u.query = sub(tail, q + 1, tail.byte_length())
        tail = sub(tail, 0, q)
    # urlparse splits `;params` off the last path segment.
    var tb = tail.as_bytes()
    var last_slash = -1
    for i in range(len(tb)):
        if tb[i] == UInt8(ord("/")):
            last_slash = i
    var semi = -1
    for i in range(last_slash + 1, len(tb)):
        if tb[i] == UInt8(ord(";")):
            semi = i
            break
    if semi >= 0:
        tail = sub(tail, 0, semi)
    u.path = tail^
    u.ok = True
    return u^


def _hostinfo(netloc: String) -> String:
    """The part of `netloc` after any userinfo '@'."""
    var b = netloc.as_bytes()
    var at = -1
    for i in range(len(b)):
        if b[i] == UInt8(ord("@")):
            at = i
    return sub(netloc, at + 1, len(b))


def _url_host_and_port(netloc: String, mut host: String, mut port: String):
    """urlparse's `hostname` (before lower-casing) and raw port text."""
    var hi = _hostinfo(netloc)
    var ob = hi.find("[")
    if ob >= 0:
        var bracketed = sub(hi, ob + 1, hi.byte_length())
        var cb = bracketed.find("]")
        if cb < 0:
            host = bracketed
            port = String("")
            return
        host = sub(bracketed, 0, cb)
        var after = sub(bracketed, cb + 1, bracketed.byte_length())
        var c = after.find(":")
        port = sub(after, c + 1, after.byte_length()) if c >= 0 else String("")
        return
    var c = hi.find(":")
    if c >= 0:
        host = sub(hi, 0, c)
        port = sub(hi, c + 1, hi.byte_length())
    else:
        host = hi
        port = String("")


def _hostname_lower(host: String) -> String:
    """urlparse's `hostname`: lower-cased up to a '%' zone suffix."""
    var p = host.find("%")
    if p < 0:
        return ascii_lower(host)
    return ascii_lower(sub(host, 0, p)) + sub(host, p, host.byte_length())


# RFC 3986 IPv6address (section 3.2.2) with an RFC 6874 zone id, inside the
# brackets of an IP-literal; the shape botocore's IPV6_ADDRZ_RE checks.
def _ipv6_literal_pattern() -> String:
    var h16 = String("[0-9A-Fa-f]{1,4}")
    var v4 = String("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}")
    var ls32 = "(?:" + h16 + ":" + h16 + "|" + v4 + ")"
    var forms = List[String]()
    forms.append("(?:" + h16 + ":){6}" + ls32)
    forms.append("::(?:" + h16 + ":){5}" + ls32)
    forms.append("(?:" + h16 + ")?::(?:" + h16 + ":){4}" + ls32)
    forms.append("(?:(?:" + h16 + ":)?" + h16 + ")?::(?:" + h16 + ":){3}" + ls32)
    forms.append("(?:(?:" + h16 + ":){0,2}" + h16 + ")?::(?:" + h16 + ":){2}" + ls32)
    forms.append("(?:(?:" + h16 + ":){0,3}" + h16 + ")?::" + h16 + ":" + ls32)
    forms.append("(?:(?:" + h16 + ":){0,4}" + h16 + ")?::" + ls32)
    forms.append("(?:(?:" + h16 + ":){0,5}" + h16 + ")?::" + h16)
    forms.append("(?:(?:" + h16 + ":){0,6}" + h16 + ")?::")
    var any = String("(?:")
    for i in range(len(forms)):
        if i > 0:
            any += "|"
        any += forms[i]
    any += ")"
    var zone = String("(?:%25|%)(?:[A-Za-z0-9._!\\-~]|%[a-fA-F0-9]{2})+")
    return "^\\[" + any + "(?:" + zone + ")?\\]$"


comptime _IPV4_PATTERN = "^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$"


# -----------------------------------------------------------------------------
# The scope
# -----------------------------------------------------------------------------


struct _Scope(Movable):
    """The names in scope: the parameters, then each assignment. A rule
    truncates the scope back when it is done, so its assignments are seen
    only by the rules under it."""

    var names: List[String]
    var values: List[JsonValue]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[JsonValue]()

    def find(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def push(mut self, name: String, var value: JsonValue):
        self.names.append(name)
        self.values.append(value^)

    def truncate(mut self, n: Int):
        while len(self.names) > n:
            _ = self.names.pop()
            _ = self.values.pop()


# -----------------------------------------------------------------------------
# The ruleset
# -----------------------------------------------------------------------------


def _is_template(s: String) -> Bool:
    """botocore's TEMPLATE_STRING_RE, `\\{[a-zA-Z#]+\\}`, found anywhere."""
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        if b[i] == UInt8(ord("{")):
            var j = i + 1
            while j < len(b) and (_is_alpha(b[j]) or b[j] == UInt8(ord("#"))):
                j += 1
            if j > i + 1 and j < len(b) and b[j] == UInt8(ord("}")):
                return True
        i += 1
    return False


def _known_function(name: String) -> Bool:
    return (
        name == "isSet"
        or name == "not"
        or name == "stringEquals"
        or name == "booleanEquals"
        or name == "substring"
        or name == "uriEncode"
        or name == "parseURL"
        or name == "isValidHostLabel"
        or name == "getAttr"
        or name == "aws.partition"
        or name == "aws.parseArn"
        or name == "aws.isVirtualHostableS3Bucket"
    )


def _arity(name: String) -> Int:
    if name == "substring":
        return 4
    if (
        name == "stringEquals"
        or name == "booleanEquals"
        or name == "isValidHostLabel"
        or name == "getAttr"
        or name == "aws.isVirtualHostableS3Bucket"
    ):
        return 2
    return 1


struct EndpointRuleSet(Copyable, Movable):
    """One service's endpoint ruleset, loaded and checked, with the
    partition table its `aws.partition` calls read."""

    var _doc: JsonValue
    var _rules: Int  # index of `rules` in _doc
    var _param_names: List[String]
    var _param_types: List[String]  # "string", "boolean", "stringarray"
    var _param_defaults: List[JsonValue]
    var _param_required: List[Bool]
    var _partitions: AwsPartitionSet
    var _ipv4: Regex
    var _ipv6: Regex

    def __init__(
        out self, ruleset_json: String, var partitions: AwsPartitionSet
    ) raises:
        """Loads an `endpoint-rule-set-1.json` document. Every rule, every
        function call and every parameter declaration is checked here, so
        a ruleset this interpreter cannot evaluate is refused at load, not
        on the first resolution that reaches the bad branch."""
        self._doc = parse_json_value(ruleset_json, ENDPOINT_RULESET_MAX_DEPTH)
        self._partitions = partitions^
        self._ipv4 = Regex(_IPV4_PATTERN)
        self._ipv6 = Regex(_ipv6_literal_pattern())
        self._param_names = List[String]()
        self._param_types = List[String]()
        self._param_defaults = List[JsonValue]()
        self._param_required = List[Bool]()
        if self._doc.kind != JSON_OBJECT:
            raise _fault("the ruleset document is not an object")
        var vi = _need(self._doc, "version", JSON_STRING, "the ruleset")
        if not self._doc.children[vi].text.startswith("1."):
            raise _fault(
                "ruleset version '"
                + self._doc.children[vi].text
                + "' is not a 1.x version"
            )
        var pi = _need(self._doc, "parameters", JSON_OBJECT, "the ruleset")
        ref params = self._doc.children[pi]
        for i in range(len(params.obj_keys)):
            var name = params.obj_keys[i]
            ref spec = params.children[i]
            var where = "parameter '" + name + "'"
            if spec.kind != JSON_OBJECT:
                raise _fault(where + " is not an object")
            var ty = ascii_lower(
                spec.children[_need(spec, "type", JSON_STRING, where)].text
            )
            if ty != "string" and ty != "boolean" and ty != "stringarray":
                raise _fault(where + " has unknown type '" + ty + "'")
            var d = _find(spec, "default")
            var r = _find(spec, "required")
            self._param_names.append(name)
            self._param_types.append(ty)
            self._param_defaults.append(
                spec.children[d].copy() if d >= 0 else JsonValue.null()
            )
            self._param_required.append(
                r >= 0
                and spec.children[r].kind == JSON_BOOL
                and spec.children[r].bool_val
            )
        self._rules = _need(self._doc, "rules", JSON_ARRAY, "the ruleset")
        ref rules = self._doc.children[self._rules]
        for i in range(len(rules.children)):
            _check_rule(rules.children[i], "rules[" + String(i) + "]")

    def parameter_names(self) -> List[String]:
        """The parameters the ruleset declares, in document order."""
        return self._param_names.copy()

    # ---- resolution -----------------------------------------------------

    def resolve(self, params: EndpointParams) raises -> EndpointOutcome:
        """Evaluates the ruleset for `params`. A parameter the ruleset does
        not declare, a value of the wrong type, and a required parameter
        with neither a value nor a default are refused (raised)."""
        var scope = _Scope()
        for i in range(len(params.names)):
            var known = False
            for j in range(len(self._param_names)):
                if self._param_names[j] == params.names[i]:
                    known = True
            if not known:
                raise _fault(
                    "'" + params.names[i] + "' is not a parameter of this ruleset"
                )
        for j in range(len(self._param_names)):
            ref name = self._param_names[j]
            var k = params._index(name)
            if k >= 0:
                ref v = params.values[k]
                var ty = self._param_types[j]
                var ok: Bool
                if ty == "string":
                    ok = v.kind == JSON_STRING
                elif ty == "boolean":
                    ok = v.kind == JSON_BOOL
                else:
                    ok = v.kind == JSON_ARRAY
                    for e in range(len(v.children)):
                        if v.children[e].kind != JSON_STRING:
                            ok = False
                if not ok:
                    raise _fault(
                        "parameter '" + name + "' is " + _kind_name(v)
                        + ", not of type " + ty
                    )
                scope.push(name, v.copy())
            elif self._param_defaults[j].kind != JSON_NULL:
                scope.push(name, self._param_defaults[j].copy())
            elif self._param_required[j]:
                raise _fault("required parameter '" + name + "' is not set")
        var res = EndpointOutcome()
        ref rules = self._doc.children[self._rules]
        for i in range(len(rules.children)):
            if self._eval_rule(rules.children[i], scope, res):
                return res^
        # A well-formed ruleset ends in a rule without conditions, so
        # reaching here means the data is malformed: a fault, not an answer.
        raise _fault("no rule of the ruleset applies to the given parameters")

    def _eval_rule(
        self, rule: JsonValue, mut scope: _Scope, mut res: EndpointOutcome
    ) raises -> Bool:
        var mark = len(scope.names)
        var done = False
        ref conds = rule.children[_find(rule, "conditions")]
        var holds = True
        for i in range(len(conds.children)):
            var r = self._call(conds.children[i], scope)
            if r.kind == JSON_NULL or (r.kind == JSON_BOOL and not r.bool_val):
                holds = False
                break
        if holds:
            var ty = rule.children[_find(rule, "type")].text
            if ty == "endpoint":
                res = EndpointOutcome.of_endpoint(
                    self._endpoint(rule.children[_find(rule, "endpoint")], scope)
                )
                done = True
            elif ty == "error":
                var e = self._resolve(rule.children[_find(rule, "error")], scope)
                if e.kind != JSON_STRING:
                    raise _fault("an error rule's message is " + _kind_name(e))
                res = EndpointOutcome.of_error(e.text)
                done = True
            else:
                ref subs = rule.children[_find(rule, "rules")]
                for i in range(len(subs.children)):
                    if self._eval_rule(subs.children[i], scope, res):
                        done = True
                        break
        scope.truncate(mark)
        return done

    def _endpoint(
        self, ep: JsonValue, mut scope: _Scope
    ) raises -> ResolvedEndpoint:
        var url = self._resolve(ep.children[_find(ep, "url")], scope)
        if url.kind != JSON_STRING:
            raise _fault("an endpoint url resolved to " + _kind_name(url))
        var props = JsonValue.empty_object()
        var pi = _find(ep, "properties")
        if pi >= 0:
            props = self._properties(ep.children[pi], scope)
        var headers = JsonValue.empty_object()
        var hi = _find(ep, "headers")
        if hi >= 0:
            ref hs = ep.children[hi]
            for i in range(len(hs.obj_keys)):
                var vals = JsonValue.empty_array()
                ref items = hs.children[i]
                for k in range(len(items.children)):
                    var v = self._resolve(items.children[k], scope)
                    if v.kind != JSON_STRING:
                        raise _fault(
                            "header '" + hs.obj_keys[i] + "' resolved to "
                            + _kind_name(v)
                        )
                    vals.push(v^)
                headers.set_member(hs.obj_keys[i], vals^)
        return ResolvedEndpoint(url.text, headers^, props^)

    def _properties(self, v: JsonValue, scope: _Scope) raises -> JsonValue:
        """botocore's `resolve_properties`: templates resolved at any depth
        of arrays and objects; every other value as written."""
        if v.kind == JSON_ARRAY:
            var a = JsonValue.empty_array()
            for i in range(len(v.children)):
                a.push(self._properties(v.children[i], scope))
            return a^
        if v.kind == JSON_OBJECT:
            var o = JsonValue.empty_object()
            for i in range(len(v.obj_keys)):
                o.set_member(v.obj_keys[i], self._properties(v.children[i], scope))
            return o^
        if v.kind == JSON_STRING and _is_template(v.text):
            return JsonValue.from_string(self._format(v.text, scope))
        return v.copy()

    def _resolve(self, v: JsonValue, mut scope: _Scope) raises -> JsonValue:
        """An argument or result value: a function call, a reference (unset
        when the name is not in scope), a template, or a literal."""
        if v.kind == JSON_OBJECT:
            if _find(v, "fn") >= 0:
                # A call in argument position cannot assign (the load-time
                # check refuses that), so it leaves the scope as it was.
                return self._call(v, scope)
            var r = _find(v, "ref")
            if r >= 0:
                var k = scope.find(v.children[r].text)
                if k < 0:
                    return JsonValue.null()
                return scope.values[k].copy()
            return v.copy()
        if v.kind == JSON_STRING and _is_template(v.text):
            return JsonValue.from_string(self._format(v.text, scope))
        return v.copy()

    def _format(self, template: String, scope: _Scope) raises -> String:
        """A template: each `{name}` or `{name#attr#...}` replaced by the
        string it names; `{{` and `}}` are literal braces."""
        var b = template.as_bytes()
        var n = len(b)
        var out = String("")
        var lit = 0
        var i = 0
        while i < n:
            var c = b[i]
            if c == UInt8(ord("{")):
                out += sub(template, lit, i)
                if i + 1 < n and b[i + 1] == UInt8(ord("{")):
                    out += "{"
                    i += 2
                    lit = i
                    continue
                var j = i + 1
                while j < n and b[j] != UInt8(ord("}")):
                    j += 1
                if j >= n:
                    raise _fault("template '" + template + "' has an unclosed '{'")
                out += self._template_value(sub(template, i + 1, j), template, scope)
                i = j + 1
                lit = i
            elif c == UInt8(ord("}")):
                out += sub(template, lit, i)
                if i + 1 < n and b[i + 1] == UInt8(ord("}")):
                    out += "}"
                    i += 2
                    lit = i
                    continue
                raise _fault("template '" + template + "' has a single '}'")
            else:
                i += 1
        out += sub(template, lit, n)
        return out^

    def _template_value(
        self, field: String, template: String, scope: _Scope
    ) raises -> String:
        var path = _split(field, UInt8(ord("#")))
        var k = scope.find(path[0])
        if k < 0:
            raise _fault(
                "template '" + template + "' names '" + path[0]
                + "', which is not in scope"
            )
        var v = scope.values[k].copy()
        for p in range(1, len(path)):
            var m = _find(v, path[p])
            if m < 0:
                raise _fault(
                    "template '" + template + "': '" + path[0] + "' has no '"
                    + path[p] + "'"
                )
            var next_v = v.children[m].copy()
            v = next_v^
        if v.kind != JSON_STRING:
            raise _fault(
                "template '" + template + "': '" + field + "' is " + _kind_name(v)
            )
        return v.text

    # ---- function calls -------------------------------------------------

    def _call(self, call: JsonValue, mut scope: _Scope) raises -> JsonValue:
        var name = call.children[_find(call, "fn")].text
        ref argv = call.children[_find(call, "argv")]
        var args = List[JsonValue]()
        for i in range(len(argv.children)):
            args.append(self._resolve(argv.children[i], scope))
        var result = self._apply(name, args)
        var a = _find(call, "assign")
        if a >= 0:
            var target = call.children[a].text
            if scope.find(target) >= 0:
                raise _fault(
                    "assignment to '" + target
                    + "', which is already in scope and cannot be overwritten"
                )
            scope.push(target, result.copy())
        return result^

    def _apply(self, name: String, args: List[JsonValue]) raises -> JsonValue:
        if name == "isSet":
            return JsonValue.from_bool(args[0].kind != JSON_NULL)
        if name == "not":
            return JsonValue.from_bool(not _truthy(args[0]))
        if name == "stringEquals":
            if args[0].kind != JSON_STRING or args[1].kind != JSON_STRING:
                raise _fault(
                    "stringEquals needs two strings, got " + _kind_name(args[0])
                    + " and " + _kind_name(args[1])
                )
            return JsonValue.from_bool(args[0].text == args[1].text)
        if name == "booleanEquals":
            if args[0].kind != JSON_BOOL or args[1].kind != JSON_BOOL:
                raise _fault(
                    "booleanEquals needs two booleans, got " + _kind_name(args[0])
                    + " and " + _kind_name(args[1])
                )
            return JsonValue.from_bool(args[0].bool_val == args[1].bool_val)
        if name == "substring":
            return _substring(args)
        if name == "uriEncode":
            if args[0].kind == JSON_NULL:
                return JsonValue.null()
            if args[0].kind != JSON_STRING:
                raise _fault("uriEncode needs a string, got " + _kind_name(args[0]))
            return JsonValue.from_string(uri_encode(args[0].text))
        if name == "parseURL":
            return self._parse_url(args[0])
        if name == "isValidHostLabel":
            if args[0].kind != JSON_STRING:
                return JsonValue.from_bool(False)
            return JsonValue.from_bool(
                is_valid_host_label(args[0].text, _flag(args[1], name))
            )
        if name == "getAttr":
            if args[1].kind != JSON_STRING:
                raise _fault("getAttr needs a string path")
            return _get_attr(args[0], args[1].text)
        if name == "aws.partition":
            if args[0].kind == JSON_NULL:
                return self._partitions.default_outputs()
            if args[0].kind != JSON_STRING:
                raise _fault("aws.partition needs a string, got " + _kind_name(args[0]))
            return self._partitions.lookup(args[0].text)
        if name == "aws.parseArn":
            return _parse_arn(args[0])
        if name == "aws.isVirtualHostableS3Bucket":
            if args[0].kind != JSON_STRING:
                return JsonValue.from_bool(False)
            return JsonValue.from_bool(
                self._virtual_hostable(args[0].text, _flag(args[1], name))
            )
        raise _fault("unknown function '" + name + "'")  # cov: unreachable _check_call refuses an unknown function when the ruleset loads

    def _virtual_hostable(self, value: String, allow_subdomains: Bool) -> Bool:
        """`aws.isVirtualHostableS3Bucket`, as botocore evaluates it: at least
        3 bytes, no upper case, not an IPv4 address, and a valid host label
        (each label, with `allow_subdomains`)."""
        if value.byte_length() < 3:
            return False
        if ascii_lower(value) != value:
            return False
        if self._ipv4.matches(value):
            return False
        return is_valid_host_label(value, allow_subdomains)

    def _parse_url(self, v: JsonValue) raises -> JsonValue:
        """`parseURL`: scheme, authority, path, normalizedPath and isIp of
        an http or https URL with no query; unset for anything else
        (including a port that is not a number from 0 to 65535)."""
        if v.kind == JSON_NULL:
            return JsonValue.null()
        if v.kind != JSON_STRING:
            raise _fault("parseURL needs a string, got " + _kind_name(v))
        var u = _urlparse(v.text)
        if not u.ok:
            return JsonValue.null()
        var host = String("")
        var port = String("")
        _url_host_and_port(u.netloc, host, port)
        var pb = port.as_bytes()
        if len(pb) > 0:
            var num = 0
            for i in range(len(pb)):
                if not _is_digit(pb[i]):
                    return JsonValue.null()
                num = num * 10 + Int(pb[i] - 0x30)
                if num > 65535:
                    return JsonValue.null()
        if u.scheme != "https" and u.scheme != "http":
            return JsonValue.null()
        if u.query.byte_length() > 0:
            return JsonValue.null()
        if u.netloc.find("[") >= 0:
            # urlsplit refuses a bracketed host that is not an IPv6 address
            # (or a `v` IPvFuture form) and anything between '@' and '['.
            var hi = _hostinfo(u.netloc)
            if hi.find("[") != 0:
                return JsonValue.null()
            # Nothing but a ':port' may follow the ']'.
            var cb = hi.find("]")
            if cb >= 0 and cb + 1 < hi.byte_length():
                if hi.as_bytes()[cb + 1] != UInt8(ord(":")):
                    return JsonValue.null()
            var hb = host.as_bytes()
            var future = len(hb) > 0 and hb[0] == UInt8(ord("v"))
            if not future and not self._ipv6.matches("[" + host + "]"):
                return JsonValue.null()
        var normalized = String("/")
        if u.path.byte_length() > 0:
            normalized = uri_encode(_remove_dot_segments(u.path), keep_slash=True)
        if not normalized.endswith("/"):
            normalized += "/"
        var is_ip = False
        if host.byte_length() > 0:
            var lowered = _hostname_lower(host)
            is_ip = self._ipv4.matches(lowered)
            var unsafe = (
                v.text.find("\t") >= 0
                or v.text.find("\r") >= 0
                or v.text.find("\n") >= 0
            )
            if not is_ip and not unsafe:
                is_ip = self._ipv6.matches("[" + lowered + "]")
        var o = JsonValue.empty_object()
        o.set_member("scheme", JsonValue.from_string(u.scheme))
        o.set_member("authority", JsonValue.from_string(u.netloc))
        o.set_member("path", JsonValue.from_string(u.path))
        o.set_member("normalizedPath", JsonValue.from_string(normalized))
        o.set_member("isIp", JsonValue.from_bool(is_ip))
        return o^


def _flag(v: JsonValue, fn_name: String) raises -> Bool:
    if v.kind != JSON_BOOL:
        raise _fault(fn_name + " needs a boolean, got " + _kind_name(v))
    return v.bool_val


def _int_arg(v: JsonValue, fn_name: String) raises -> Int:
    if v.kind != JSON_NUMBER or not v.is_integral_number():
        raise _fault(fn_name + " needs an integer, got " + _kind_name(v))
    return Int(v.as_int64())


def _substring(args: List[JsonValue]) raises -> JsonValue:
    """`substring(value, start, stop, reverse)`: bytes [start, stop) of an
    ASCII `value`, counted from the end with `reverse`; unset when the
    range is empty or past the end, or `value` is not ASCII."""
    if args[0].kind != JSON_STRING:
        raise _fault("substring needs a string, got " + _kind_name(args[0]))
    var start = _int_arg(args[1], "substring")
    var stop = _int_arg(args[2], "substring")
    var reverse = _flag(args[3], "substring")
    ref s = args[0].text
    var b = s.as_bytes()
    var n = len(b)
    if start >= stop or n < stop:
        return JsonValue.null()
    for i in range(n):
        if b[i] >= 0x80:
            return JsonValue.null()
    if reverse:
        return JsonValue.from_string(sub(s, n - stop, n - start))
    return JsonValue.from_string(sub(s, start, stop))


def _get_attr(value: JsonValue, path: String) raises -> JsonValue:
    """`getAttr(value, path)`: `path` is dot-separated attribute names, the
    last of which may carry an `[index]`; an index past the end, or into an
    unset value, is unset."""
    var cur = value.copy()
    var parts = _split(path, UInt8(ord(".")))
    for p in range(len(parts)):
        ref part = parts[p]
        var b = part.as_bytes()
        var lb = part.find("[")
        var is_index = (
            lb >= 0
            and len(b) > lb + 2
            and b[len(b) - 1] == UInt8(ord("]"))
        )
        if is_index:
            for i in range(lb + 1, len(b) - 1):
                if not _is_digit(b[i]):
                    is_index = False
            for i in range(lb):
                if not _is_word(b[i]):
                    is_index = False
        if is_index:
            var idx = 0
            for i in range(lb + 1, len(b) - 1):
                idx = idx * 10 + Int(b[i] - 0x30)
                if idx > 1_000_000_000:
                    idx = 1_000_000_000
            if lb > 0:
                if cur.kind != JSON_OBJECT:
                    raise _fault("getAttr '" + path + "' on " + _kind_name(cur))
                var m = _find(cur, sub(part, 0, lb))
                if m < 0:
                    return JsonValue.null()
                var next_cur = cur.children[m].copy()
                cur = next_cur^
            if cur.kind == JSON_NULL:
                return JsonValue.null()
            if cur.kind != JSON_ARRAY:
                raise _fault("getAttr '" + path + "' indexes " + _kind_name(cur))
            if idx >= len(cur.children):
                return JsonValue.null()
            return cur.children[idx].copy()
        if cur.kind != JSON_OBJECT:
            raise _fault("getAttr '" + path + "' on " + _kind_name(cur))
        var m = _find(cur, part)
        if m < 0:
            raise _fault("getAttr '" + path + "': no attribute '" + part + "'")
        var next_cur = cur.children[m].copy()
        cur = next_cur^
    return cur^


def _parse_arn(v: JsonValue) raises -> JsonValue:
    """`aws.parseArn`: `arn:partition:service:region:account:resource`,
    with partition, service and resource non-empty; unset otherwise.
    `resourceId` is the resource split at every ':' and '/'."""
    if v.kind == JSON_NULL:
        return JsonValue.null()
    if v.kind != JSON_STRING:
        raise _fault("aws.parseArn needs a string, got " + _kind_name(v))
    ref s = v.text
    if not s.startswith("arn:"):
        return JsonValue.null()
    var b = s.as_bytes()
    var cuts = List[Int]()
    for i in range(len(b)):
        if b[i] == UInt8(ord(":")) and len(cuts) < 5:
            cuts.append(i)
    if len(cuts) < 5:
        return JsonValue.null()
    var partition = sub(s, cuts[0] + 1, cuts[1])
    var service = sub(s, cuts[1] + 1, cuts[2])
    var region = sub(s, cuts[2] + 1, cuts[3])
    var account = sub(s, cuts[3] + 1, cuts[4])
    var resource = sub(s, cuts[4] + 1, len(b))
    if (
        partition.byte_length() == 0
        or service.byte_length() == 0
        or resource.byte_length() == 0
    ):
        return JsonValue.null()
    var ids = JsonValue.empty_array()
    var rb = resource.as_bytes()
    var start = 0
    for i in range(len(rb)):
        if rb[i] == UInt8(ord(":")) or rb[i] == UInt8(ord("/")):
            ids.push(JsonValue.from_string(sub(resource, start, i)))
            start = i + 1
    ids.push(JsonValue.from_string(sub(resource, start, len(rb))))
    var o = JsonValue.empty_object()
    o.set_member("partition", JsonValue.from_string(partition))
    o.set_member("service", JsonValue.from_string(service))
    o.set_member("region", JsonValue.from_string(region))
    o.set_member("accountId", JsonValue.from_string(account))
    o.set_member("resourceId", ids^)
    return o^


# -----------------------------------------------------------------------------
# The load-time check
# -----------------------------------------------------------------------------


def _check_call(v: JsonValue, where: String, may_assign: Bool) raises:
    if v.kind != JSON_OBJECT:
        raise _fault(where + " is not a function call")
    var fi = _need(v, "fn", JSON_STRING, where)
    var name = v.children[fi].text
    if not _known_function(name):
        raise _fault(where + " calls unknown function '" + name + "'")
    var ai = _need(v, "argv", JSON_ARRAY, where)
    ref argv = v.children[ai]
    if len(argv.children) != _arity(name):
        raise _fault(
            where + ": " + name + " takes " + String(_arity(name))
            + " arguments, not " + String(len(argv.children))
        )
    for i in range(len(v.obj_keys)):
        var k = v.obj_keys[i]
        if k == "assign":
            if not may_assign:
                raise _fault(where + ": a nested call may not assign")
            if v.children[i].kind != JSON_STRING:
                raise _fault(where + ": 'assign' is not a string")
        elif k != "fn" and k != "argv" and k != "documentation":
            raise _fault(where + " has unknown key '" + k + "'")
    for i in range(len(argv.children)):
        _check_value(argv.children[i], where + ".argv[" + String(i) + "]")


def _check_value(v: JsonValue, where: String) raises:
    if v.kind == JSON_OBJECT:
        if _find(v, "fn") >= 0:
            _check_call(v, where, False)
        elif _find(v, "ref") >= 0:
            _ = _need(v, "ref", JSON_STRING, where)
            if len(v.obj_keys) != 1:
                raise _fault(where + ": a reference has keys besides 'ref'")


def _check_rule(rule: JsonValue, where: String) raises:
    if rule.kind != JSON_OBJECT:
        raise _fault(where + " is not an object")
    var ti = _need(rule, "type", JSON_STRING, where)
    var ty = rule.children[ti].text
    var ci = _need(rule, "conditions", JSON_ARRAY, where)
    ref conds = rule.children[ci]
    for i in range(len(conds.children)):
        _check_call(conds.children[i], where + ".conditions[" + String(i) + "]", True)
    var body = String("")
    if ty == "endpoint":
        body = "endpoint"
        var ei = _need(rule, "endpoint", JSON_OBJECT, where)
        ref ep = rule.children[ei]
        var ui = _find(ep, "url")
        if ui < 0:
            raise _fault(where + ".endpoint has no 'url'")
        _check_value(ep.children[ui], where + ".endpoint.url")
        for i in range(len(ep.obj_keys)):
            var k = ep.obj_keys[i]
            if k == "headers":
                ref hs = ep.children[i]
                if hs.kind != JSON_OBJECT:
                    raise _fault(where + ".endpoint.headers is not an object")
                for h in range(len(hs.children)):
                    if hs.children[h].kind != JSON_ARRAY:
                        raise _fault(where + ".endpoint.headers values must be arrays")
                    for e in range(len(hs.children[h].children)):
                        _check_value(
                            hs.children[h].children[e], where + ".endpoint.headers"
                        )
            elif k == "properties":
                if ep.children[i].kind != JSON_OBJECT:
                    raise _fault(where + ".endpoint.properties is not an object")
            elif k != "url":
                raise _fault(where + ".endpoint has unknown key '" + k + "'")
    elif ty == "error":
        body = "error"
        var ei = _find(rule, "error")
        if ei < 0:
            raise _fault(where + " has no 'error'")
        _check_value(rule.children[ei], where + ".error")
    elif ty == "tree":
        body = "rules"
        var ri = _need(rule, "rules", JSON_ARRAY, where)
        ref subs = rule.children[ri]
        for i in range(len(subs.children)):
            _check_rule(subs.children[i], where + ".rules[" + String(i) + "]")
    else:
        raise _fault(where + " has unknown rule type '" + ty + "'")
    for i in range(len(rule.obj_keys)):
        var k = rule.obj_keys[i]
        if k != "type" and k != "conditions" and k != "documentation" and k != body:
            raise _fault(where + " has unknown key '" + k + "'")
