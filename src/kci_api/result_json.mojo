# =============================================================================
# src/kci_api/result_json.mojo -- the JSON helpers the result document's
#   renderer and parser share (result.mojo, result_deploy.mojo).
# =============================================================================
#
# `_Obj` writes an object's keys sorted bytewise; `_need`, `_s`, `_i`, `_b`
# read one key and refuse a missing key or the wrong JSON type, naming the
# document; `_note_unknown` records the keys a reader ignores. Not exported by
# the package: the result document's API is result.mojo's.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from komira_json import JSON_BOOL, JSON_NUMBER, JSON_STRING, JsonValue


struct _Obj(Movable):
    """An object under construction whose keys are written sorted."""

    var keys: List[String]
    var values: List[JsonValue]

    def __init__(out self):
        self.keys = List[String]()
        self.values = List[JsonValue]()

    def put(mut self, var key: String, var value: JsonValue):
        self.keys.append(key^)
        self.values.append(value^)

    def put_str(mut self, var key: String, s: String):
        self.put(key^, JsonValue.from_string(s.copy()))

    def put_int(mut self, var key: String, n: Int):
        self.put(key^, JsonValue.from_i64(Int64(n)))

    def build(mut self) raises -> JsonValue:
        var order = List[Int]()
        for i in range(len(self.keys)):
            order.append(i)
        for i in range(1, len(order)):
            var j = i
            while j > 0 and _less(self.keys[order[j]], self.keys[order[j - 1]]):
                var t = order[j]
                order[j] = order[j - 1]
                order[j - 1] = t
                j -= 1
        var doc = JsonValue.empty_object()
        for i in range(len(order)):
            doc.set_member(self.keys[order[i]].copy(), self.values[order[i]].copy())
        return doc^


def _less(a: String, b: String) -> Bool:
    var x = a.as_bytes()
    var y = b.as_bytes()
    var n = min(len(x), len(y))
    for i in range(n):
        if x[i] != y[i]:
            return x[i] < y[i]
    return len(x) < len(y)


def _str_array(items: List[String]) raises -> JsonValue:
    var a = JsonValue.empty_array()
    for i in range(len(items)):
        a.push(JsonValue.from_string(items[i].copy()))
    return a^



def _member(words: List[String], w: String) -> Bool:
    for i in range(len(words)):
        if words[i] == w:
            return True
    return False


def _is_sha256_hex(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) != 64:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
            return False
    return True



def _refuse(source: String, why: String) raises:
    raise Error(String("result '") + source + String("': ") + why)


def _need(doc: JsonValue, key: String, tag: Int, source: String, where: String) raises -> JsonValue:
    if not doc.has(key):
        _refuse(source, where + String("missing '") + key + String("'"))
    var v = doc.get(key)
    if v.kind_tag() != tag:
        _refuse(source, where + String("'") + key + String("' has the wrong JSON type"))
    return v^


def _s(doc: JsonValue, key: String, source: String, where: String = String("")) raises -> String:
    return _need(doc, key, JSON_STRING, source, where).as_string()


def _s_absent_empty(doc: JsonValue, key: String, source: String, where: String) raises -> String:
    """A string key added inside the major: "" when a document written before
    it has none; the wrong JSON type is still refused."""
    if not doc.has(key):
        return String("")
    return _s(doc, key, source, where)


def _i(doc: JsonValue, key: String, source: String, where: String = String("")) raises -> Int:
    var v = _need(doc, key, JSON_NUMBER, source, where)
    if not v.is_integral_number():
        _refuse(source, where + String("'") + key + String("' is not an integer"))
    return Int(v.as_int64())


def _b(doc: JsonValue, key: String, source: String, where: String = String("")) raises -> Bool:
    return _need(doc, key, JSON_BOOL, source, where).as_bool()


def _no_dup_keys(doc: JsonValue, source: String, where: String) raises:
    for i in range(doc.num_members()):
        for j in range(i):
            if doc.key_at(j) == doc.key_at(i):
                _refuse(source, where + String("'") + doc.key_at(i) + String("' is given twice"))


def _note_unknown(doc: JsonValue, known: List[String], where: String, mut ignored: List[String]) raises:
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        var ok = False
        for j in range(len(known)):
            if known[j] == key:
                ok = True
        if not ok:
            ignored.append(where + key)


def _keys(names: String) -> List[String]:
    var out = List[String]()
    var parts = names.split(String(" "))
    for i in range(len(parts)):
        out.append(String(parts[i]))
    return out^

