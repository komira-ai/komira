# =============================================================================
# kci_cloud/compose_load.mojo: LOADING composite definitions, the first four
#   steps of expansion (compose.mojo): load and check every definition,
#   refuse containment cycles, check the instances at the top of a list, and
#   count what a list expands to.
# =============================================================================
#
# `Loader` holds the definitions kci was given (each with its key
# `<name>@<version>` and its digest) and the findings. Its checks are the
# definition-side rules of composite.proto's header; compose.mojo's
# `_Expander` runs them, and expands only after a load with no finding.
# =============================================================================

from komira_crypto import hex_lower_array_32, sha256
from komira_proto_codec import encode_proto
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.refs import Ref
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import Catalog, FIELD_COMPOSITE, body_field
from kci_cloud.compose_bind import (
    INPUT_IMAGE,
    INPUT_REF,
    INPUT_STRING,
    INPUT_VALUE_MAP,
    bind_problems,
    a_type,
    input_type_name,
    is_known_type,
    is_plain,
    literal_problem,
    nested_input_name,
)
from kci_cloud.compose_kci import kci_definition_problem
from kci_cloud.compose_refs import (
    SITE_REF,
    component_id_problem,
    definition_name_problem,
    ref_sites,
    snake_name_problem,
    version_problem,
)

comptime MAX_EXPANDED_PRIMITIVES: Int = 10000
"""The most primitives one list may expand to."""


def definition_digest(d: CompositeDefinition) raises -> String:
    """`sha256:<hex>` of `d`'s bytes as this kci encodes them."""
    var b = encode_proto(d)
    return String("sha256:") + hex_lower_array_32(sha256(Span(b)))


def definition_key(name: String, version: String) -> String:
    """`<name>@<version>`, how a definition is printed."""
    return name + String("@") + version


def is_composite(r: Resource) -> Bool:
    """True iff `r` is a composite instance (`Resource.body` 80)."""
    try:
        return body_field(r) == FIELD_COMPOSITE
    except:
        return False


def _q(s: String) -> String:
    return String("\"") + s + String("\"")


struct Loader(Movable):
    """The definitions kci was given, their keys and digests, and the
    findings of loading them and of the top of a list."""

    var catalog: Catalog
    var defs: List[CompositeDefinition]
    var keys: List[String]
    var digests: List[String]
    var findings: List[Finding]

    def __init__(out self, catalog: Catalog):
        self.catalog = catalog.copy()
        self.defs = List[CompositeDefinition]()
        self.keys = List[String]()
        self.digests = List[String]()
        self.findings = List[Finding]()

    def add(mut self, where: String, field: String, why: String):
        """One finding; an identical one is not repeated."""
        for i in range(len(self.findings)):
            ref f = self.findings[i]
            if f.resource_id == where and f.field_path == field and f.reason == why:
                return
        self.findings.append(Finding(FINDING_GRAPH, where, field, why))

    # ---- lookups -------------------------------------------------------------

    def find_def(self, name: String, version: String) -> Int:
        var key = definition_key(name, version)
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return i
        return -1

    def versions_of(self, name: String) -> String:
        var s = String("")
        for i in range(len(self.defs)):
            if self.defs[i].name == name:
                if s.byte_length() > 0:
                    s += String(", ")
                s += self.keys[i]
        return s^

    def component_at(self, d: Int, id: String) -> Int:
        ref comps = self.defs[d].component
        for k in range(len(comps)):
            if comps[k].id == id:
                return k
        return -1

    def exports(self, d: Int, id: String) -> Bool:
        ref ex = self.defs[d].export
        for k in range(len(ex)):
            if ex[k] == id:
                return True
        return False

    def input_type(self, d: Int, name: String) -> Int:
        """The declared type of input `name` of definition `d`, or -1."""
        ref ins = self.defs[d].input
        for k in range(len(ins)):
            if ins[k].name == name:
                return ins[k].type.value
        return -1

    def nested_def(self, d: Int, k: Int) -> Int:
        """The definition component `k` of `d` instantiates, or -1."""
        ref c = self.defs[d].component[k]
        if not is_composite(c):
            return -1
        ref ci = c.composite.value()
        return self.find_def(ci.definition, ci.version)

    # ---- 1. load --------------------------------------------------------------

    def load(mut self, definitions: List[CompositeDefinition]) raises:
        for i in range(len(definitions)):
            ref d = definitions[i]
            var key = definition_key(d.name, d.version)
            var digest = definition_digest(d)
            var seen = -1
            for k in range(len(self.keys)):
                if self.keys[k] == key:
                    seen = k
            if seen >= 0:
                if self.digests[seen] != digest:
                    self.add(
                        key,
                        String(""),
                        String("two definitions are named ")
                        + key
                        + String(" with different contents (")
                        + self.digests[seen]
                        + String(", ")
                        + digest
                        + String("); give a changed definition a new version"),
                    )
                continue
            var kci = kci_definition_problem(d.name, d.version, digest)
            if kci.byte_length() > 0:
                self.add(key, String("name"), kci)
            self.defs.append(d.copy())
            self.keys.append(key^)
            self.digests.append(digest^)
        for i in range(len(self.defs)):
            self.check_def(i)

    def check_def(mut self, i: Int) raises:
        var d = self.defs[i].copy()
        var key = self.keys[i].copy()
        var bad = definition_name_problem(d.name)
        if bad.byte_length() > 0:
            self.add(key, String("name"), bad)
        bad = version_problem(d.version)
        if bad.byte_length() > 0:
            self.add(key, String("version"), bad)
        for k in range(len(d.input)):
            ref inp = d.input[k]
            var at = String("input[") + inp.name + String("]")
            bad = snake_name_problem(inp.name, String("input name"))
            if bad.byte_length() > 0:
                self.add(key, at, bad)
            for q in range(k):
                if d.input[q].name == inp.name:
                    self.add(key, at, String("a second input named ") + _q(inp.name))
            var t = inp.type.value
            if not is_known_type(t):
                self.add(
                    key,
                    at + String(".type"),
                    String("input type ") + String(t) + String(" is not one this kci knows (INPUT_STRING, INPUT_INT, INPUT_BOOL, INPUT_REF, INPUT_IMAGE, INPUT_VALUE_MAP)"),
                )
            if inp.default:
                if inp.required:
                    self.add(key, at, String("a required input has no default"))
                if t == INPUT_REF:
                    self.add(key, at + String(".default"), String("a REF input has no default: it names a resource outside the composite"))
                elif t == INPUT_IMAGE or t == INPUT_VALUE_MAP:
                    self.add(key, at + String(".default"), a_type(t) + String(" input has no default"))
                elif inp.default.value()._oneof0_case != 1:
                    self.add(key, at + String(".default"), String("a default is a literal"))
                else:
                    var bad_lit = literal_problem(t, inp.default.value().literal.value())
                    if bad_lit.byte_length() > 0:
                        self.add(key, at + String(".default"), bad_lit)
        if len(d.component) == 0:
            self.add(key, String("component"), String("a definition has at least one component"))
        for k in range(len(d.component)):
            self.check_component(i, k)
        for k in range(len(d.export)):
            var at = String("export[") + String(k) + String("]")
            if self.component_at(i, d.export[k]) < 0:
                self.add(key, at, String("exports ") + _q(d.export[k]) + String(", which is not a component of ") + key)
            for q in range(k):
                if d.export[q] == d.export[k]:
                    self.add(key, at, String("exports ") + _q(d.export[k]) + String(" twice"))
        for k in range(len(d.output)):
            self.check_output(i, k)
        var nested = List[Optional[CompositeDefinition]]()
        for k in range(len(d.component)):
            var j = self.nested_def(i, k)
            if j >= 0:
                nested.append(self.defs[j].copy())
            else:
                nested.append(None)
        var probs = bind_problems(self.catalog, d, key, nested)
        for k in range(len(probs)):
            self.add(key, probs[k].field, probs[k].why)

    def check_component(mut self, i: Int, k: Int) raises:
        var c = self.defs[i].component[k].copy()
        var key = self.keys[i].copy()
        var at = String("component[") + c.id + String("]")
        var bad = component_id_problem(c.id)
        if bad.byte_length() > 0:
            self.add(key, at + String(".id"), bad)
        for q in range(k):
            if self.defs[i].component[q].id == c.id:
                self.add(key, at + String(".id"), String("a second component with this id"))
        if is_composite(c):
            self.check_instance(c, key, at + String("."), i)
        var sites = ref_sites(c)
        for s in range(len(sites)):
            ref site = sites[s]
            var why = String("")
            if site.kind == SITE_REF:
                why = self.static_ref(i, site.ref_.value())
            else:
                ref v = site.value.value()
                if v._oneof0_case == 3:
                    why = self.static_ref(i, v.ref_.value())
                elif v._oneof0_case == 4 and not is_composite(c):
                    var t = self.input_type(i, v.input.value())
                    if t < 0:
                        why = key + String(" declares no input ") + _q(v.input.value())
                    elif t == INPUT_REF:
                        why = String("input ") + _q(v.input.value()) + String(" is a REF input: a reference names it, ref { input: ... }")
                    elif not is_plain(t):
                        why = String("input ") + _q(v.input.value()) + String(" is ") + a_type(t) + String(" input: a binding writes it, bind { ... }")
            if why.byte_length() > 0:
                self.add(key, at + String(".") + site.path, why)

    def static_ref(self, i: Int, r: Ref) -> String:
        """What is wrong with reference `r` inside definition `i`, before it
        is instantiated (its base); empty when nothing is."""
        var n = Int(r.resource.byte_length() > 0) + Int(Bool(r.local)) + Int(Bool(r.input))
        if n > 1:
            return String("names more than one base (resource, local, input); a reference has exactly one")
        if r.resource.byte_length() > 0:
            return String(
                "a definition is closed: it names its own components with local, and a resource"
                " outside it through a REF input"
            )
        if r.local:
            if self.component_at(i, r.local.value()) < 0:
                return self.keys[i] + String(" has no component ") + _q(r.local.value())
        if r.input:
            var t = self.input_type(i, r.input.value())
            if t < 0:
                return self.keys[i] + String(" declares no input ") + _q(r.input.value())
            if t == INPUT_STRING:
                return String("input ") + _q(r.input.value()) + String(" is a STRING input: a value names it, { input: ... }")
            if t != INPUT_REF:
                return String("input ") + _q(r.input.value()) + String(" is ") + a_type(t) + String(" input, not a REF input: a reference names a REF input")
        return String("")

    def check_instance(mut self, c: Resource, where: String, prefix: String, in_def: Int) raises:
        """The shape, definition, digest and inputs of instance `c`; findings
        on `where`, fields under `prefix`. `in_def` is the definition it is
        a component of, or -1 at the top of the list."""
        ref ci = c.composite.value()
        if len(c.uses) > 0:
            self.add(where, prefix + String("uses"), String("an instance has no identity of its own: a component of its definition uses"))
        if c.retention.value != 0:
            self.add(where, prefix + String("retention"), String("an instance has no object of its own: each component of its definition sets its retention"))
        if c.physical_name or len(c.labels) > 0 or c.adopt.value != 0:
            self.add(where, prefix + String("composite"), String("an instance has no object of its own: physical_name, labels and adopt are written on the components of its definition"))
        var d = self.find_def(ci.definition, ci.version)
        if d < 0:
            var have = self.versions_of(ci.definition)
            self.add(
                where,
                prefix + String("composite.definition"),
                String("no definition ")
                + definition_key(ci.definition, ci.version)
                + String(" was given")
                + ((String(" (given: ") + have + String(")")) if have.byte_length() > 0 else String("")),
            )
            return
        if ci.digest and ci.digest.value() != self.digests[d]:
            self.add(
                where,
                prefix + String("composite.digest"),
                String("digest ") + ci.digest.value() + String(" is not the digest of ") + self.keys[d] + String(", ") + self.digests[d],
            )
        var e = self.defs[d].copy()
        var names = String("")
        for q in range(len(e.input)):
            names += (String(", ") if q > 0 else String("")) + e.input[q].name
        for entry in ci.input.items():
            var at = prefix + String("composite.input.") + entry.key
            var t = self.input_type(d, entry.key)
            ref v = entry.value
            if t < 0:
                self.add(where, at, self.keys[d] + String(" declares no input ") + _q(entry.key) + String(" (it declares: ") + names + String(")"))
                continue
            var arm = v._oneof0_case
            if t == INPUT_REF:
                if arm != 3 or v.ref_.value()._oneof0_case != 0:
                    self.add(where, at, String("a REF input takes a reference to a resource: ref { ... } with no output"))
                continue
            if not is_plain(t):
                var m = String("image_input") if t == INPUT_IMAGE else String("map_input")
                self.add(where, at, a_type(t) + String(" input is bound in ") + m)
                continue
            if arm == 0:
                self.add(where, at, String("has no value"))
            elif arm == 4:
                self.check_passed(where, at, v.input.value(), in_def, t)
            elif t != INPUT_STRING and arm != 1:
                self.add(where, at, a_type(t) + String(" input takes a literal, or an input of the enclosing definition"))
            elif arm == 1:
                var bad = literal_problem(t, v.literal.value())
                if bad.byte_length() > 0:
                    self.add(where, at, bad)
            elif arm == 3 and v.ref_.value()._oneof0_case == 0:
                self.add(where, at, String("a STRING input takes a value: name an output of the resource (standard or named)"))
        for entry in ci.image_input.items():
            var at = prefix + String("composite.image_input.") + entry.key
            var t = self.input_type(d, entry.key)
            if t != INPUT_IMAGE:
                self.add(where, at, self.keys[d] + String(" declares no IMAGE input ") + _q(entry.key) + String(" (it declares: ") + names + String(")"))
            elif entry.value._oneof0_case == 0:
                self.add(where, at, String("an image is a build step's output or a digest"))
        for entry in ci.map_input.items():
            var at = prefix + String("composite.map_input.") + entry.key
            var t = self.input_type(d, entry.key)
            if t != INPUT_VALUE_MAP:
                self.add(where, at, self.keys[d] + String(" declares no VALUE_MAP input ") + _q(entry.key) + String(" (it declares: ") + names + String(")"))
                continue
            for kv in entry.value.value.items():
                var vat = at + String(".") + kv.key
                var arm = kv.value._oneof0_case
                if arm == 0:
                    self.add(where, vat, String("has no value"))
                elif arm == 4:
                    self.check_passed(where, vat, kv.value.input.value(), in_def, -1)
                elif arm == 3 and kv.value.ref_.value()._oneof0_case == 0:
                    self.add(where, vat, String("a value names an output of the resource (standard or named)"))
        var by_bind = List[String]()
        if in_def >= 0:
            ref outer = self.defs[in_def]
            for k in range(len(outer.bind)):
                if outer.bind[k].component == c.id:
                    var n = nested_input_name(outer.bind[k].field)
                    if n.byte_length() > 0:
                        by_bind.append(n^)
        for q in range(len(e.input)):
            ref name = e.input[q].name
            var bound = name in ci.input or name in ci.image_input or name in ci.map_input
            for k in range(len(by_bind)):
                if by_bind[k] == name:
                    bound = True
            if e.input[q].required and not bound:
                self.add(where, prefix + String("composite.input"), String("required input ") + _q(name) + String(" of ") + self.keys[d] + String(" is not bound"))

    def check_passed(mut self, where: String, at: String, name: String, in_def: Int, t: Int):
        """`Value.input` `name`, bound to an input of plain type `t` (-1: a
        value of a VALUE_MAP, any plain type): an input of the enclosing
        definition `in_def` of that type."""
        var t_in = self.input_type(in_def, name) if in_def >= 0 else -1
        if in_def < 0:
            self.add(where, at, String("an input is only for references inside a composite definition"))
        elif t_in < 0:
            self.add(where, at, self.keys[in_def] + String(" declares no input ") + _q(name))
        elif t_in == INPUT_REF:
            self.add(where, at, String("input ") + _q(name) + String(" is a REF input: pass it down as ref { input: ... }"))
        elif not is_plain(t_in):
            self.add(where, at, String("input ") + _q(name) + String(" is ") + a_type(t_in) + String(" input: a binding passes it down"))
        elif t >= 0 and t_in != t:
            self.add(where, at, String("input ") + _q(name) + String(" is ") + a_type(t_in) + String(" input; this one takes ") + a_type(t))

    def check_output(mut self, i: Int, k: Int) raises:
        var o = self.defs[i].output[k].copy()
        var key = self.keys[i].copy()
        var at = String("output[") + o.name + String("]")
        var bad = snake_name_problem(o.name, String("output name"))
        if bad.byte_length() > 0:
            self.add(key, at, bad)
        for q in range(k):
            if self.defs[i].output[q].name == o.name:
                self.add(key, at, String("a second output named ") + _q(o.name))
        if not o.from_:
            self.add(key, at + String(".from"), String("an output says which value it is: from { local: ..., standard or named }"))
            return
        ref f = o.from_.value()
        if not f.local or f.resource.byte_length() > 0 or f.input:
            self.add(key, at + String(".from"), String("an output is a value of one of the definition's own components: its base is local"))
            return
        if f._oneof0_case == 0:
            self.add(key, at + String(".from"), String("an output is a value: write standard or named"))
            return
        var c = self.component_at(i, f.local.value())
        if c < 0:
            self.add(key, at + String(".from"), key + String(" has no component ") + _q(f.local.value()))
            return
        var comp = self.defs[i].component[c].copy()
        if not is_composite(comp):
            if f.path:
                self.add(key, at + String(".from"), String("a path goes below ") + _q(f.local.value()) + String(", a primitive"))
            elif f._oneof0_case == 2:
                self.add(key, at + String(".from"), String("named reads a composite's declared output; ") + _q(f.local.value()) + String(" is a primitive"))
            else:
                var out = f.standard.value().json_name()
                var field = body_field(comp)
                var t = self.catalog.index_of(field)
                if t >= 0 and not self.catalog.types[t].exposes_output(out):
                    self.add(key, at + String(".from"), _q(f.local.value()) + String(" (") + self.catalog.name_of(field) + String(") does not expose ") + out)
            return
        if not f.path and f._oneof0_case != 2:
            self.add(key, at + String(".from"), _q(f.local.value()) + String(" is a composite instance: read one of its declared outputs with named"))

    # ---- 2. containment cycles ----------------------------------------------------

    def check_cycles(mut self):
        var color = List[Int]()
        for _ in range(len(self.defs)):
            color.append(0)
        var stack = List[Int]()
        for i in range(len(self.defs)):
            if color[i] == 0:
                self.dfs(i, color, stack)

    def dfs(mut self, i: Int, mut color: List[Int], mut stack: List[Int]):
        color[i] = 1
        stack.append(i)
        for k in range(len(self.defs[i].component)):
            var j = self.nested_def(i, k)
            if j < 0:
                continue
            if color[j] == 1:
                var at = 0
                for s in range(len(stack)):
                    if stack[s] == j:
                        at = s
                # Print the cycle from its smallest key, so each cycle is
                # reported once whichever definition the walk started at.
                var cyc = List[Int]()
                for s in range(at, len(stack)):
                    cyc.append(stack[s])
                var lo = 0
                for s in range(len(cyc)):
                    if self.keys[cyc[s]] < self.keys[cyc[lo]]:
                        lo = s
                var text = String("")
                for s in range(len(cyc) + 1):
                    if s > 0:
                        text += String(" -> ")
                    text += self.keys[cyc[(lo + s) % len(cyc)]]
                self.add(self.keys[cyc[lo]].copy(), String("component"), String("a containment cycle: ") + text)
            elif color[j] == 0:
                self.dfs(j, color, stack)
        _ = stack.pop()
        color[i] = 2

    # ---- 4. the size guard ----------------------------------------------------------

    def count(self, i: Int, mut memo: List[Int]) -> Int:
        """The primitives definition `i` expands to, capped one above the
        limit (no overflow however wide the diamond)."""
        if memo[i] >= 0:
            return memo[i]
        var n = 0
        for k in range(len(self.defs[i].component)):
            var j = self.nested_def(i, k)
            n += self.count(j, memo) if j >= 0 else 1
            if n > MAX_EXPANDED_PRIMITIVES:
                n = MAX_EXPANDED_PRIMITIVES + 1
                break
        memo[i] = n
        return n
