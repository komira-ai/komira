# =============================================================================
# komira_json/duplicates.mojo: refuse an object that names a member twice.
# =============================================================================
#
# The parser keeps duplicate object keys in document order and `get` returns
# the first (see the package header). That is RFC 8259 behaviour, but formats
# built on JSON may require more: RFC 7515 section 5.2 and RFC 7519 section 4
# (JWS headers, JWT claims) and RFC 7517 section 4 (JWK members) require a
# parser either to reject duplicate member names or to use the last one. Two
# readers that pick different duplicates read two different documents, so a
# security-relevant reader refuses them: `refuse_duplicate_keys` is that check,
# run over a parsed value.
#
# Keys are compared after unescaping, so `{"a":1,"a":2}` names `a` twice.
# The walk visits every object at every depth, array elements included. It
# recurses once per nesting level, as `copy()` and destruction do; a parsed
# tree is at most `JSON_MAX_DEPTH` deep.
# =============================================================================

from std.collections import Set

from .value import JSON_ARRAY, JSON_OBJECT, JsonValue


def refuse_duplicate_keys(value: JsonValue) raises:
    """Raise if any object in `value`, at any depth, has two members with the
    same name (compared after unescaping).

    The error is `JsonError: duplicate object key '<name>'`, followed by
    ` at line <n>` when the second member came from parsed text (`key_line`
    is known). Returns normally for a value with no object, or whose objects
    all have distinct member names.
    """
    if value.kind == JSON_OBJECT:
        var seen = Set[String]()
        for i in range(len(value.obj_keys)):
            ref key = value.obj_keys[i]
            if key in seen:
                var msg = String("JsonError: duplicate object key '") + key + "'"
                var line = value.children[i].key_line
                if line > 0:
                    msg += String(" at line ") + String(line)
                raise Error(msg)
            seen.add(key)
    if value.kind == JSON_OBJECT or value.kind == JSON_ARRAY:
        for i in range(len(value.children)):
            refuse_duplicate_keys(value.children[i])
