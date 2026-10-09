# =============================================================================
# komira_http_auth/dup_keys.mojo: refuse a JSON document with a repeated
#   object key, at any depth.
# =============================================================================
#
# `{"alg":"RS256","alg":"none"}` is valid JSON with no defined winner, and two
# readers that pick differently (one takes the first, one the last) see two
# different tokens. komira_json keeps duplicates and returns the first, so
# every JOSE header, JWT payload and JWK Set read here goes through this
# check first. Keys are compared after unescaping, so `"a"` and `"a"`
# are the same key.
#
# A shared `komira_json` function for this is in review separately; this
# private copy goes away when it lands.
# =============================================================================

from komira_json import JsonValue, JSON_OBJECT


def refuse_duplicate_keys(v: JsonValue) raises:
    """Raises if any object in `v` has a key twice."""
    if v.kind == JSON_OBJECT:
        for i in range(len(v.obj_keys)):
            for j in range(i):
                if v.obj_keys[i] == v.obj_keys[j]:
                    raise Error(String("komira_http_auth: duplicate JSON key"))
    for i in range(len(v.children)):
        refuse_duplicate_keys(v.children[i])
