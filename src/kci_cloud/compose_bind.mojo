# =============================================================================
# kci_cloud/compose_bind.mojo: the INPUT TYPES of a composite, and BINDINGS,
#   an input written into a field of a component.
# =============================================================================
#
# A composite's input reaches a component in one of two ways (composite.proto):
# where a `Value` or a `Ref` already stands, the component names it
# (`Value.input`, `Ref.input`; compose.mojo rewrites those), and anywhere
# else a BINDING writes it: `bind { component, field, input }`. This module
# is the second way, on a PRIMITIVE component. `field` is a path into the
# component's proto3 JSON (`service.port`, `container_job.image`,
# `service.env`): `bind_field` encodes the component, writes the value at the
# path and decodes the result STRICTLY, so a path the type does not have, or
# a value of the wrong type for it, is refused with the decoder's own
# words, never silently dropped. The first segment is the type's arm as the
# .proto names it (`container_job`); a later segment matches a member by its
# name as written or by its lowerCamel JSON name, and a member that is not
# there is written under the name as written (the decoder reads both).
#
# WHAT EACH TYPE WRITES (`BindValue`):
#   * STRING: a JSON string (from a literal only: a parameter or another
#     resource's output has no plain-field form);
#   * INT: a JSON number (the literal, a decimal integer);
#   * BOOL: `true`/`false` into a bool field; into a field whose message
#     has no fields (a flag such as `service.public`), true writes `{}` and
#     false removes the field. Which one is decided by the decoder: the bool
#     is tried first, then `{}`, and `{}` counts only if it is still there
#     when the result is encoded again (an empty map is not);
#   * IMAGE: the `Image`'s JSON;
#   * VALUE_MAP: its entries ADDED to the map at the path (created if the
#     component writes none); a key the component already writes is
#     refused.
#
# A BINDING NEVER WRITES A REFERENCE. A STRING written into `run_as.resource`
# would name a resource outside a closed definition. `binding_problem`, which
# load runs on every binding of a primitive component, writes a sample value
# of the input's type and refuses the binding when the component's
# references (`compose_refs.ref_sites`) are then anything other than they
# were (for a VALUE_MAP: other than they were plus the map's new entries).
#
# THE DEFINITION-SIDE RULES (`bind_problems`, run by load): a binding names a
# component and a declared input, never a REF input, and one binding per
# (component, field); on a primitive component `binding_problem` holds; on a
# nested instance the field is `composite.image_input.<name>` (IMAGE) or
# `composite.map_input.<name>` (VALUE_MAP) and `<name>` an input of the
# nested definition of the same type that the instance does not bind
# itself. A presence names a component and an optional input with no
# default, once per component.
#
# WHICH INPUTS AN INSTANCE SETS (`is_set`, `nested_set_names`): those it
# binds, and those with a default; an input a nested instance takes from an
# input of the enclosing definition (`Value.input`, `Ref.input`, a binding)
# is set only when that one is. Expansion reads this before anything is
# rewritten, so a reference into an absent component is refused wherever it
# stands in the list.
# =============================================================================

from komira_json import JsonValue, parse_json_value
from komira_proto_codec import decode_json, encode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.refs import Image, Value
from kci_resource_proto.resource import Resource

from kci_cloud.catalog import Catalog, body_field
from kci_cloud.compose_refs import literal_value, ref_sites


comptime INPUT_STRING: Int = 1
"""`kci.resource.v1.INPUT_STRING`."""
comptime INPUT_INT: Int = 2
"""`kci.resource.v1.INPUT_INT`."""
comptime INPUT_BOOL: Int = 3
"""`kci.resource.v1.INPUT_BOOL`."""
comptime INPUT_REF: Int = 5
"""`kci.resource.v1.INPUT_REF`."""
comptime INPUT_IMAGE: Int = 6
"""`kci.resource.v1.INPUT_IMAGE`."""
comptime INPUT_VALUE_MAP: Int = 9
"""`kci.resource.v1.INPUT_VALUE_MAP`."""

comptime INT_LITERAL_MAX_DIGITS: Int = 18
"""The most digits an INT literal has (it always fits an Int64)."""

comptime _SET: Int = 0
comptime _MERGE: Int = 1
comptime _REMOVE: Int = 2


def input_type_name(t: Int) -> String:
    """`STRING`, `INT`, `BOOL`, `REF`, `IMAGE`, `VALUE_MAP`, or the number."""
    if t == INPUT_STRING:
        return String("STRING")
    if t == INPUT_INT:
        return String("INT")
    if t == INPUT_BOOL:
        return String("BOOL")
    if t == INPUT_REF:
        return String("REF")
    if t == INPUT_IMAGE:
        return String("IMAGE")
    if t == INPUT_VALUE_MAP:
        return String("VALUE_MAP")
    return String(t)


def a_type(t: Int) -> String:
    """`input_type_name(t)` with its article: `an INT`, `a STRING`."""
    var n = input_type_name(t)
    if t == INPUT_INT or t == INPUT_IMAGE:
        return String("an ") + n
    return String("a ") + n


def is_known_type(t: Int) -> Bool:
    return t == INPUT_STRING or t == INPUT_INT or t == INPUT_BOOL or t == INPUT_REF or t == INPUT_IMAGE or t == INPUT_VALUE_MAP


def is_plain(t: Int) -> Bool:
    """A type carried as a `Value` in `CompositeInstance.input`, and named
    in a component by `Value.input`: STRING, INT and BOOL."""
    return t == INPUT_STRING or t == INPUT_INT or t == INPUT_BOOL


def literal_problem(t: Int, text: String) -> String:
    """Why `text` is not a literal of plain type `t`, or empty. INT: an
    optional `-` and 1 to 18 decimal digits, no leading zero; BOOL: `true`
    or `false`; STRING: anything."""
    if t == INPUT_BOOL:
        if text == "true" or text == "false":
            return String("")
        return String("a BOOL input is true or false, not \"") + text + String("\"")
    if t != INPUT_INT:
        return String("")
    var b = text.as_bytes()
    var start = 1 if len(b) > 0 and Int(b[0]) == ord("-") else 0
    var n = len(b) - start
    var ok = n >= 1 and n <= INT_LITERAL_MAX_DIGITS
    for i in range(start, len(b)):
        if Int(b[i]) < ord("0") or Int(b[i]) > ord("9"):
            ok = False
    if ok and n > 1 and Int(b[start]) == ord("0"):
        ok = False
    if not ok:
        return String("an INT input is a decimal integer of at most ") + String(INT_LITERAL_MAX_DIGITS) + String(" digits, not \"") + text + String("\"")
    return String("")


def camel(s: String) -> String:
    """The lowerCamel JSON name of proto field name `s` (`run_as` ->
    `runAs`)."""
    var out = String("")
    var up = False
    for b in s.as_bytes():
        var c = Int(b)
        if c == ord("_"):
            up = True
            continue
        if up and c >= ord("a") and c <= ord("z"):
            c -= 32
        out += chr(c)
        up = False
    return out^


struct BindValue(Copyable, Movable):
    """The value one binding writes: `kind` is the input's type; `text` the
    literal of a plain type; `image` an IMAGE; `entries` a VALUE_MAP."""

    var kind: Int
    var text: String
    var image: Optional[Image]
    var entries: Dict[String, Value]

    def __init__(out self, kind: Int, text: String, var image: Optional[Image], var entries: Dict[String, Value]):
        self.kind = kind
        self.text = text.copy()
        self.image = image^
        self.entries = entries^

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self.text = copy.text.copy()
        self.image = copy.image.copy()
        self.entries = copy.entries.copy()

    @staticmethod
    def sample(t: Int) raises -> BindValue:
        """A value of type `t`, to try a binding on (`binding_problem`)."""
        var m = Dict[String, Value]()
        if t == INPUT_VALUE_MAP:
            m[String("KCI_SAMPLE")] = literal_value(String("x"))
        var img: Optional[Image] = None
        if t == INPUT_IMAGE:
            img = decode_json[Image](String('{"digest":"sha256:00"}'))
        var text = String("1") if t == INPUT_INT else (String("true") if t == INPUT_BOOL else String("x"))
        return BindValue(t, text, img^, m^)


struct Bound(Movable):
    """What `bind_field` made: the component, or why it could not."""

    var resource: Optional[Resource]
    var err: String

    def __init__(out self, var resource: Optional[Resource], err: String):
        self.resource = resource^
        self.err = err.copy()


def _segments(field: String) -> List[String]:
    var out = List[String]()
    for s in field.split("."):
        out.append(String(s))
    return out^


def _member(node: JsonValue, seg: String) -> Int:
    """The index of the member named `seg`, or by its JSON name, or -1."""
    for i in range(len(node.obj_keys)):
        if node.obj_keys[i] == seg:
            return i
    var c = camel(seg)
    if c != seg:
        for i in range(len(node.obj_keys)):
            if node.obj_keys[i] == c:
                return i
    return -1


def _put(mut node: JsonValue, segs: List[String], i: Int, v: JsonValue, mode: Int) raises:
    """Write `v` at `segs[i:]` below `node` (set, merge or remove)."""
    if not node.is_object():
        raise Error(String("\"") + segs[i - 1] + String("\" is not a message or a map"))
    var k = _member(node, segs[i])
    if i < len(segs) - 1:
        if k < 0:
            node.set_member(segs[i].copy(), JsonValue.empty_object())
            k = len(node.children) - 1
        _put(node.children[k], segs, i + 1, v, mode)
        return
    if mode == _REMOVE:
        if k >= 0:
            _ = node.obj_keys.pop(k)
            _ = node.children.pop(k)
        return
    if mode == _MERGE:
        if k < 0:
            node.set_member(segs[i].copy(), JsonValue.empty_object())
            k = len(node.children) - 1
        if not node.children[k].is_object():
            raise Error(String("\"") + segs[i] + String("\" is not a map"))
        for j in range(v.num_members()):
            var key = v.key_at(j)
            if node.children[k].has(key):
                raise Error(String("key \"") + key + String("\" is written by the component and by the input"))
            node.children[k].set_member(key^, v.value_at(j))
        return
    if k >= 0:
        node.children[k] = v.copy()
    else:
        node.set_member(segs[i].copy(), v.copy())


def _attempt(root: JsonValue, segs: List[String], v: JsonValue, mode: Int) -> Bound:
    try:
        var j = root.copy()
        _put(j, segs, 0, v, mode)
        return Bound(decode_json[Resource](j.serialize()), String(""))
    except e:
        return Bound(None, String(e))


def _holds(r: Resource, segs: List[String]) -> Bool:
    """True iff `r`'s JSON has a member at `segs`."""
    try:
        var node = parse_json_value(encode_json(r))
        for i in range(len(segs)):
            var k = _member(node, segs[i])
            if k < 0:
                return False
            var next = node.children[k].copy()
            node = next^
        return True
    except:
        return False


def _json_of(v: BindValue) raises -> JsonValue:
    if v.kind == INPUT_INT:
        return JsonValue.from_number(v.text.copy())
    if v.kind == INPUT_IMAGE:
        return parse_json_value(encode_json(v.image.value()))
    if v.kind == INPUT_VALUE_MAP:
        var o = JsonValue.empty_object()
        var keys = List[String]()
        for e in v.entries.items():
            keys.append(e.key.copy())
        for i in range(1, len(keys)):
            var k = i
            while k > 0 and keys[k] < keys[k - 1]:
                var x = keys[k].copy()
                keys[k] = keys[k - 1].copy()
                keys[k - 1] = x^
                k -= 1
        for i in range(len(keys)):
            o.set_member(keys[i].copy(), parse_json_value(encode_json(v.entries[keys[i]])))
        return o^
    return JsonValue.from_string(v.text.copy())


def bind_field(r: Resource, field: String, v: BindValue) raises -> Bound:
    """`r` with `v` written at `field` (the header), or why not."""
    var segs = _segments(field)
    var root = parse_json_value(encode_json(r))
    if v.kind == INPUT_BOOL:
        var as_bool = _attempt(root, segs, JsonValue.from_bool(v.text == "true"), _SET)
        if as_bool.resource:
            return as_bool^
        var flag = _attempt(root, segs, JsonValue.empty_object(), _SET)
        if flag.resource and _holds(flag.resource.value(), segs):
            if v.text == "true":
                return flag^
            return _attempt(root, segs, JsonValue(), _REMOVE)
        return as_bool^
    return _attempt(root, segs, _json_of(v), _MERGE if v.kind == INPUT_VALUE_MAP else _SET)


def _site_keys(r: Resource) raises -> List[String]:
    """Each reference site of `r` as `path=json`, in the walk's order."""
    var out = List[String]()
    var sites = ref_sites(r)
    for i in range(len(sites)):
        ref s = sites[i]
        var j = encode_json(s.ref_.value()) if s.ref_ else encode_json(s.value.value())
        out.append(s.path + String("=") + j)
    return out^


def binding_problem(catalog: Catalog, c: Resource, field: String, t: Int) raises -> String:
    """Why binding an input of type `t` to `field` of primitive component `c`
    is refused at load, or empty: the field's first segment is not `c`'s
    type, the sample value does not decode there, or writing it changes a
    reference of `c` (the header)."""
    var arm = catalog.name_of(body_field(c))
    var segs = _segments(field)
    for i in range(len(segs)):
        if segs[i].byte_length() == 0:
            return String("a binding's field is a path of non-empty segments, ") + arm + String(".<field>")
    if len(segs) < 2 or segs[0] != arm:
        return String("a binding writes a field of its component, which is a ") + arm + String(": ") + arm + String(".<field>")
    var got = bind_field(c, field, BindValue.sample(t))
    if not got.resource:
        return a_type(t) + String(" input cannot be written to ") + field + String(": ") + got.err
    var before = _site_keys(c)
    var after = _site_keys(got.resource.value())
    var added = len(after) - len(before)
    var same = added >= 0 and (added == 0 or t == INPUT_VALUE_MAP)
    var k = 0
    for i in range(len(after)):
        if k < len(before) and after[i] == before[k]:
            k += 1
        elif not after[i].startswith(field + String(".")) or t != INPUT_VALUE_MAP:
            same = False
    if not same or k != len(before):
        return String("a binding writes a plain field, never a reference: ") + field + String(" is (or is inside) a reference or a value, which names an input where it stands")
    return String("")


# ---- the definition-side rules of bindings and presences ---------------------------------


struct Problem(Copyable, Movable):
    """One load finding of a definition: the field and why."""

    var field: String
    var why: String

    def __init__(out self, field: String, why: String):
        self.field = field.copy()
        self.why = why.copy()


def def_input_type(d: CompositeDefinition, name: String) -> Int:
    """The declared type of input `name` of `d`, or -1."""
    for k in range(len(d.input)):
        if d.input[k].name == name:
            return d.input[k].type.value
    return -1


def def_input_set_by_default(d: CompositeDefinition, name: String) -> Bool:
    """True iff input `name` of `d` has a default (so it is always set)."""
    for k in range(len(d.input)):
        if d.input[k].name == name:
            return Bool(d.input[k].default)
    return False


def is_set(d: CompositeDefinition, set_names: List[String], name: String) -> Bool:
    """True iff an instance of `d` that binds `set_names` sets input
    `name`: it binds it, or the input has a default."""
    for i in range(len(set_names)):
        if set_names[i] == name:
            return True
    return def_input_set_by_default(d, name)


def presence_input(d: CompositeDefinition, component: String) -> String:
    """The input component `component` of `d` exists by, or empty."""
    for k in range(len(d.presence)):
        if d.presence[k].component == component:
            return d.presence[k].if_input.copy()
    return String("")


comptime IMAGE_INPUT_FIELD = "composite.image_input."
"""A binding of an IMAGE input into a nested instance: this, then the name."""
comptime MAP_INPUT_FIELD = "composite.map_input."
"""A binding of a VALUE_MAP input into a nested instance: this, then the name."""


def nested_input_name(field: String) -> String:
    """The nested instance's input a binding `field` names
    (`composite.image_input.<name>` or `composite.map_input.<name>`), or
    empty."""
    for p in [String(IMAGE_INPUT_FIELD), String(MAP_INPUT_FIELD)]:
        if field.startswith(p):
            return String(field[byte = p.byte_length() :])
    return String("")


def nested_set_names(d: CompositeDefinition, set_names: List[String], c: Resource) -> List[String]:
    """The inputs that nested instance `c`, a component of `d` in an
    instance of `d` that binds `set_names`, sets: each it binds, except one
    passed down from an input of `d` that is not set (`Value.input`,
    `Ref.input`), and each a binding of `d` passes down from a set input."""
    var out = List[String]()
    ref ci = c.composite.value()
    for e in ci.input.items():
        ref v = e.value
        var passed = String("")
        if v._oneof0_case == 4:
            passed = v.input.value().copy()
        elif v._oneof0_case == 3 and v.ref_.value().input:
            passed = v.ref_.value().input.value().copy()
        if passed.byte_length() == 0 or is_set(d, set_names, passed):
            out.append(e.key.copy())
    for e in ci.image_input.items():
        out.append(e.key.copy())
    for e in ci.map_input.items():
        out.append(e.key.copy())
    for k in range(len(d.bind)):
        ref b = d.bind[k]
        var name = nested_input_name(b.field)
        if b.component == c.id and name.byte_length() > 0 and is_set(d, set_names, b.input):
            out.append(name^)
    return out^


def _q(s: String) -> String:
    return String("\"") + s + String("\"")


def bind_problems(
    catalog: Catalog, d: CompositeDefinition, key: String, nested: List[Optional[CompositeDefinition]]
) raises -> List[Problem]:
    """Every load finding of `d`'s bindings and presences. `nested[k]` is
    the definition component `k` instantiates, when it is an instance of a
    definition that was given."""
    var out = List[Problem]()
    for k in range(len(d.bind)):
        ref b = d.bind[k]
        var at = String("bind[") + String(k) + String("]")
        var ci = -1
        for q in range(len(d.component)):
            if d.component[q].id == b.component:
                ci = q
        if ci < 0:
            out.append(Problem(at + String(".component"), key + String(" has no component ") + _q(b.component)))
        var t = def_input_type(d, b.input)
        if t < 0:
            out.append(Problem(at + String(".input"), key + String(" declares no input ") + _q(b.input)))
        elif t == INPUT_REF:
            out.append(Problem(at + String(".input"), String("a REF input is not bound: it is used where it stands, ref { input: ") + _q(b.input) + String(" }")))
        for q in range(k):
            if d.bind[q].component == b.component and d.bind[q].field == b.field:
                out.append(Problem(at, String("a second binding of ") + b.component + String(".") + b.field))
        if ci < 0 or t < 0 or t == INPUT_REF:
            continue
        ref c = d.component[ci]
        if not c.composite:
            var why = binding_problem(catalog, c, b.field, t)
            if why.byte_length() > 0:
                out.append(Problem(at + String(".field"), why))
            continue
        var want = String(IMAGE_INPUT_FIELD) if t == INPUT_IMAGE else (String(MAP_INPUT_FIELD) if t == INPUT_VALUE_MAP else String(""))
        if want.byte_length() == 0:
            out.append(Problem(at + String(".field"), a_type(t) + String(" input passes down as composite.input.<name> { input: ") + _q(b.input) + String(" }")))
            continue
        var name = String(b.field[byte = want.byte_length() :]) if b.field.startswith(want) else String("")
        if name.byte_length() == 0:
            out.append(Problem(at + String(".field"), a_type(t) + String(" input passes down to an instance as ") + want + String("<name>")))
            continue
        if (t == INPUT_IMAGE and name in c.composite.value().image_input) or (t == INPUT_VALUE_MAP and name in c.composite.value().map_input):
            out.append(Problem(at + String(".field"), String("input ") + _q(name) + String(" is bound twice: by the instance and by a binding")))
        if not nested[ci]:
            continue  # the instance's own finding names the missing definition
        ref nd = nested[ci].value()
        var t2 = def_input_type(nd, name)
        if t2 < 0:
            out.append(Problem(at + String(".field"), nd.name + String("@") + nd.version + String(" declares no input ") + _q(name)))
        elif t2 != t:
            out.append(Problem(at + String(".field"), String("input ") + _q(name) + String(" of ") + nd.name + String("@") + nd.version + String(" is ") + a_type(t2) + String(" input, and ") + _q(b.input) + String(" is ") + a_type(t) + String(" input")))
    for k in range(len(d.presence)):
        ref p = d.presence[k]
        var at = String("presence[") + String(k) + String("]")
        var ci = -1
        for q in range(len(d.component)):
            if d.component[q].id == p.component:
                ci = q
        if ci < 0:
            out.append(Problem(at + String(".component"), key + String(" has no component ") + _q(p.component)))
        for q in range(k):
            if d.presence[q].component == p.component:
                out.append(Problem(at, String("a second presence of ") + _q(p.component)))
        var t = def_input_type(d, p.if_input)
        if t < 0:
            out.append(Problem(at + String(".if_input"), key + String(" declares no input ") + _q(p.if_input)))
            continue
        for q in range(len(d.input)):
            if d.input[q].name == p.if_input and (d.input[q].required or d.input[q].default):
                out.append(Problem(at + String(".if_input"), String("input ") + _q(p.if_input) + String(" is always set (required, or with a default): a presence follows an optional input with no default")))
    return out^
