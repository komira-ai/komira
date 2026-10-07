# =============================================================================
# kci_cloud/compose.mojo: EXPANSION, a list with composite instances -> a list
#   of primitives.
# =============================================================================
#
# A composite (composite.proto) is data: a named graph of components with
# inputs, outputs and exports. A deploy step's list may hold INSTANCES of
# composites (`Resource.body` 80), at the top or as components of other
# definitions, to any depth. `expand` turns the list into primitives only,
# before validate checks anything per type, so the lowering and the engine
# never see a composite. It is pure (no cloud, no credentials) and
# deterministic, so its result is golden-testable. It runs in five steps,
# and a step with a finding stops the ones after it:
#
#   1. LOAD every definition kci was given: its name and version grammar,
#      its inputs (name, type, required or default), its components (ids of
#      the component grammar, unique, never reserved; an instance names a
#      definition that was given, binds its inputs by name and type, and
#      writes no `uses`, retention or metadata), every reference inside a
#      component (a definition is closed: `local` names a component,
#      `input` a REF input, `Value.input` a STRING input, never
#      `Ref.resource`), its exports and its declared outputs. Two
#      definitions with one name and version are refused unless their bytes
#      are the same (`definition_digest`).
#   2. CONTAINMENT CYCLES: "definition A has an instance of B" is an edge;
#      a cycle (A -> A, A -> B -> A, at any length) is refused, printed as
#      the cycle. After this the definitions form a DAG, so expansion ends.
#   3. THE TOP OF THE LIST: an instance's id (the resource id grammar, and
#      unique in the list), definition, version, digest, inputs and shape.
#   4. THE SIZE GUARD: a list that expands to more than
#      `MAX_EXPANDED_PRIMITIVES` primitives is refused before any is built
#      (a diamond of definitions multiplies), with each top-level
#      instance's count.
#   5. EXPANSION, per top-level instance `top`, recursively: component `c`
#      of the instance at path `P` becomes resource `P/c` (`P` starts as
#      `top`); a nested instance recurses with its inputs bound in the
#      enclosing one. Every reference is REWRITTEN to name the full path
#      (`Ref.resource` alone): `local` -> `P/<local>`, `input` -> what the
#      instance bound, `path` -> one segment deeper per component, each
#      EXPORTED by its definition, and a reference that ends on an instance
#      reads one of its DECLARED outputs (`named`), which is followed to the
#      primitive that produces it. `Value.input` -> the bound value, else the
#      input's default; an optional input left unbound removes the value or
#      reference that names it. A reference outside every definition may use
#      `path` and `named` the same way; `local` and `input` are refused
#      there, and so is a `resource` holding `/` (a path into an instance
#      is `resource` + `path`, so the export check sees it). A path that is missing, unexported or below a primitive, and a
#      reference that ends on an instance without `named` (an instance has
#      no object of its own), is refused where it is used.
#
# THE RESULT (`Expansion`): the authored primitives (rewritten when they
# reach into an instance) and every produced primitive, in list order with
# each instance's primitives in its place; the ids it produced; the
# findings; and the TREE, one line per resource: its path and either its
# type or the instance's definition, version and digest, so a plan can print
# what the list is made of, and a silently edited definition shows up as a
# new digest.
#
# OWNERSHIP AT EVERY DEPTH. A produced id holds `/`, and its owner is its
# first segment (`owner_of_node`, compose_refs.mojo): `deploy.lower_data`
# stamps every node of `top/a/b` as owned by `top`, so the closed world and
# retention hold below the top exactly as at it (deploy.mojo).
# =============================================================================

from komira_crypto import hex_lower_array_32, sha256
from komira_proto_codec import encode_proto
from kci_resource_proto.composite import CompositeDefinition, InputType
from kci_resource_proto.resource import Ref, Resource, Value

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import Catalog, FIELD_COMPOSITE, body_field
from kci_cloud.compose_refs import (
    RefSite,
    SITE_REF,
    component_id_problem,
    definition_name_problem,
    id_problem,
    ref_sites,
    ref_value,
    snake_name_problem,
    unrewritten,
    version_problem,
    with_sites,
)


comptime MAX_EXPANDED_PRIMITIVES: Int = 10000
"""The most primitives one list may expand to."""

comptime INPUT_STRING: Int = 1
"""`kci.resource.v1.INPUT_STRING`."""
comptime INPUT_REF: Int = 5
"""`kci.resource.v1.INPUT_REF`."""


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


struct Expansion(Movable):
    """What `expand` made of a list: the primitives, the ids it produced
    (each a path `top/c1/.../ck`), the findings, and the printable tree."""

    var resources: List[Resource]
    var produced: List[String]
    var findings: List[Finding]
    var tree: String

    def __init__(out self):
        self.resources = List[Resource]()
        self.produced = List[String]()
        self.findings = List[Finding]()
        self.tree = String("")


struct _Ctx(Copyable, Movable):
    """Where a reference is resolved: inside the instance at `prefix` of
    definition `def_i` with `bindings` (its inputs, already resolved), or at
    the top of the list (`def_i` -1)."""

    var prefix: String
    var def_i: Int
    var bindings: Dict[String, Value]

    def __init__(out self, prefix: String, def_i: Int, var bindings: Dict[String, Value]):
        self.prefix = prefix.copy()
        self.def_i = def_i
        self.bindings = bindings^

    def __init__(out self, *, copy: Self):
        self.prefix = copy.prefix.copy()
        self.def_i = copy.def_i
        self.bindings = copy.bindings.copy()

    @staticmethod
    def top() -> _Ctx:
        return _Ctx(String(""), -1, Dict[String, Value]())


struct _Got(Movable):
    """A resolved reference or value: `err` set (refused), `drop` (an
    unbound optional input), or the rewritten `ref_` / `value`."""

    var err: String
    var drop: Bool
    var ref_: Optional[Ref]
    var value: Optional[Value]

    def __init__(out self, err: String, drop: Bool, var ref_: Optional[Ref], var value: Optional[Value]):
        self.err = err.copy()
        self.drop = drop
        self.ref_ = ref_^
        self.value = value^

    @staticmethod
    def refused(why: String) -> _Got:
        return _Got(why, False, None, None)

    @staticmethod
    def dropped() -> _Got:
        return _Got(String(""), True, None, None)

    @staticmethod
    def of_ref(r: Ref) -> _Got:
        return _Got(String(""), False, r.copy(), None)

    @staticmethod
    def of_value(v: Value) -> _Got:
        return _Got(String(""), False, None, v.copy())


def _q(s: String) -> String:
    return String("\"") + s + String("\"")


struct _Expander(Movable):
    var catalog: Catalog
    var defs: List[CompositeDefinition]
    var keys: List[String]
    var digests: List[String]
    var findings: List[Finding]
    var inst: Dict[String, Int]
    var prims: Dict[String, Int]
    var out: List[Resource]
    var produced: List[String]
    var tree: String

    def __init__(out self, catalog: Catalog):
        self.catalog = catalog.copy()
        self.defs = List[CompositeDefinition]()
        self.keys = List[String]()
        self.digests = List[String]()
        self.findings = List[Finding]()
        self.inst = Dict[String, Int]()
        self.prims = Dict[String, Int]()
        self.out = List[Resource]()
        self.produced = List[String]()
        self.tree = String("")

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
            if t != INPUT_STRING and t != INPUT_REF:
                self.add(key, at + String(".type"), String("input type ") + String(t) + String(" is not one this kci knows (INPUT_STRING, INPUT_REF)"))
            if inp.default:
                if inp.required:
                    self.add(key, at, String("a required input has no default"))
                if t == INPUT_REF:
                    self.add(key, at + String(".default"), String("a REF input has no default: it names a resource outside the composite"))
                elif inp.default.value()._oneof0_case != 1:
                    self.add(key, at + String(".default"), String("a default is a literal"))
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
                    elif t != INPUT_STRING:
                        why = String("input ") + _q(v.input.value()) + String(" is a REF input: a reference names it, ref { input: ... }")
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
            if t != INPUT_REF:
                return String("input ") + _q(r.input.value()) + String(" is a STRING input: a value names it, { input: ... }")
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
        if c.physical_name or len(c.labels) > 0 or c.adopt:
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
        for entry in ci.input.items():
            var at = prefix + String("composite.input.") + entry.key
            var t = self.input_type(d, entry.key)
            ref v = entry.value
            if t < 0:
                var names = String("")
                for q in range(len(e.input)):
                    names += (String(", ") if q > 0 else String("")) + e.input[q].name
                self.add(where, at, self.keys[d] + String(" declares no input ") + _q(entry.key) + String(" (it declares: ") + names + String(")"))
                continue
            var arm = v._oneof0_case
            if t == INPUT_REF:
                if arm != 3 or v.ref_.value()._oneof0_case != 0:
                    self.add(where, at, String("a REF input takes a reference to a resource: ref { ... } with no output"))
                continue
            if arm == 0:
                self.add(where, at, String("has no value"))
            elif arm == 3 and v.ref_.value()._oneof0_case == 0:
                self.add(where, at, String("a STRING input takes a value: name an output of the resource (standard or named)"))
            elif arm == 4:
                var t_in = self.input_type(in_def, v.input.value()) if in_def >= 0 else -1
                if in_def < 0:
                    self.add(where, at, String("an input is only for references inside a composite definition"))
                elif t_in < 0:
                    self.add(where, at, self.keys[in_def] + String(" declares no input ") + _q(v.input.value()))
                elif t_in == INPUT_REF:
                    self.add(where, at, String("input ") + _q(v.input.value()) + String(" is a REF input: pass it down as ref { input: ... }"))
        for q in range(len(e.input)):
            if e.input[q].required and e.input[q].name not in ci.input:
                self.add(where, prefix + String("composite.input"), String("required input ") + _q(e.input[q].name) + String(" of ") + self.keys[d] + String(" is not bound"))

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

    # ---- 5. expansion ---------------------------------------------------------------

    def index(mut self, prefix: String, d: Int):
        """Record every instance and primitive path below instance `prefix`
        of definition `d`."""
        self.inst[prefix] = d
        for k in range(len(self.defs[d].component)):
            var path = prefix + String("/") + self.defs[d].component[k].id
            var j = self.nested_def(d, k)
            if j >= 0:
                self.index(path, j)
            else:
                self.prims[path] = 1

    def resolve_ref(mut self, ctx: _Ctx, r: Ref) raises -> _Got:
        """`r` rewritten to name its full path (see the header)."""
        if (r.local and r.local.value().byte_length() == 0) or (r.input and r.input.value().byte_length() == 0):
            return _Got.refused(String("an empty base"))
        if r.path and r.path.value().byte_length() == 0:
            return _Got.refused(String("an empty path"))
        var has_res = r.resource.byte_length() > 0
        var n = Int(has_res) + Int(Bool(r.local)) + Int(Bool(r.input))
        if n > 1:
            return _Got.refused(String("names more than one base (resource, local, input); a reference has exactly one"))
        if n == 0:
            if r.path:
                return _Got.refused(String("a path below no base"))
            return _Got.of_ref(r)  # validate refuses a reference to nothing
        var target: String
        if ctx.def_i >= 0:
            # cov: unreachable: the three refusals below (a resource base, an
            # unknown local, an undeclared or STRING input used as a ref) are
            # refused first by load: check_component runs static_ref on every
            # ref and Value.ref site of a definition, compose_refs' walk covers
            # a nested instance's bindings, and check_output requires `from`
            # to name an existing local. Expansion runs only after a load with
            # no finding. Kept as refusals so a caller that skips load is
            # refused rather than accepted.
            if has_res:
                return _Got.refused(self.static_ref(ctx.def_i, r))
            if r.local:
                if self.component_at(ctx.def_i, r.local.value()) < 0:
                    return _Got.refused(self.static_ref(ctx.def_i, r))
                target = ctx.prefix + String("/") + r.local.value()
            else:
                var b = ctx.bindings.get(r.input.value())
                if not b:
                    if self.input_type(ctx.def_i, r.input.value()) != INPUT_REF:
                        return _Got.refused(self.static_ref(ctx.def_i, r))
                    return _Got.dropped()
                target = b.value().ref_.value().resource.copy()
        else:
            if not has_res:
                return _Got.refused(String("local and input are for references inside a composite definition"))
            var slash = r.resource.find("/")
            if slash >= 0:
                # An authored `resource` is one id: a path into an instance is
                # written as `resource` + `path`, so every segment of it meets
                # the export check below (`store/data` would skip it).
                return _Got.refused(
                    _q(r.resource)
                    + String(" is a path inside an instance: write resource ")
                    + _q(String(r.resource[byte=0:slash]))
                    + String(" with path ")
                    + _q(String(r.resource[byte = slash + 1 :]))
                    + String(", which names only exported components")
                )
            target = r.resource.copy()
        if r.path:
            var segs = r.path.value().split("/")
            for s in range(len(segs)):
                var seg = String(segs[s])
                var d = self.inst.get(target)
                if not d:
                    if target in self.prims:
                        return _Got.refused(String("path ") + _q(r.path.value()) + String(" goes below ") + _q(target) + String(", a primitive"))
                    return _Got.refused(String("path ") + _q(r.path.value()) + String(" goes below ") + _q(target) + String(", which is not a composite instance of this list"))
                var di = d.value()
                if seg.byte_length() == 0 or self.component_at(di, seg) < 0:
                    return _Got.refused(_q(target) + String(" (") + self.keys[di] + String(") has no component ") + _q(seg))
                if not self.exports(di, seg):
                    return _Got.refused(String("component ") + _q(seg) + String(" of ") + self.keys[di] + String(" is not exported, so nothing outside it may name it"))
                target = target + String("/") + seg
        var d = self.inst.get(target)
        if d:
            var di = d.value()
            if r._oneof0_case == 2:
                return self.output_of(target, di, r.named.value())
            if r._oneof0_case == 1:
                return _Got.refused(_q(target) + String(" is an instance of ") + self.keys[di] + String(": it exposes only the outputs it declares, read with named"))
            return _Got.refused(
                _q(target)
                + String(" is an instance of ")
                + self.keys[di]
                + String(", which has no object of its own: name an exported component with path, or a declared output with named")
            )
        return _Got.of_ref(Ref(target, None, None, None, r._oneof0_case, r.standard.copy(), r.named.copy()))

    def output_of(mut self, target: String, d: Int, name: String) raises -> _Got:
        """Declared output `name` of the instance `target` of definition `d`,
        followed to the primitive that produces it."""
        var outs = self.defs[d].output.copy()
        for k in range(len(outs)):
            if outs[k].name == name:
                return self.resolve_ref(_Ctx(target, d, Dict[String, Value]()), outs[k].from_.value())
        var names = String("")
        for k in range(len(outs)):
            names += (String(", ") if k > 0 else String("")) + outs[k].name
        return _Got.refused(self.keys[d] + String(" declares no output ") + _q(name) + String(" (it declares: ") + names + String(")"))

    def resolve_value(mut self, ctx: _Ctx, v: Value) raises -> _Got:
        if v._oneof0_case == 4:
            if ctx.def_i < 0:
                return _Got.refused(String("an input is only for values inside a composite definition"))
            var name = v.input.value()
            var b = ctx.bindings.get(name)
            if b:
                return _Got.of_value(b.value())
            var ins = self.defs[ctx.def_i].input.copy()
            for k in range(len(ins)):
                if ins[k].name == name and ins[k].type.value == INPUT_STRING:
                    if ins[k].default:
                        return _Got.of_value(ins[k].default.value())
                    return _Got.dropped()
            # cov: unreachable once load has no finding, every Value.input
            # inside definition `def_i` names one of its STRING inputs:
            # check_component refuses any other on a primitive component, and
            # check_instance (with `in_def`) on a nested instance's bindings.
            # resolve_value runs with `def_i` >= 0 only on those sites
            # (rewrite and bindings_of under instantiate), and expansion runs
            # only after a load with no finding. Kept as a refusal so a later
            # caller that skips load fails closed.
            return _Got.refused(self.keys[ctx.def_i] + String(" declares no STRING input ") + _q(name))
        if v._oneof0_case == 3:
            var g = self.resolve_ref(ctx, v.ref_.value())
            if g.err.byte_length() > 0 or g.drop:
                return g^
            return _Got.of_value(ref_value(g.ref_.value()))
        return _Got.of_value(v)

    def rewrite(mut self, ctx: _Ctx, r: Resource, id: String) raises -> Resource:
        """`r` as resource `id`, every reference resolved in `ctx`."""
        var sites = ref_sites(r)
        for s in range(len(sites)):
            var g: _Got
            if sites[s].kind == SITE_REF:
                g = self.resolve_ref(ctx, sites[s].ref_.value())
            else:
                g = self.resolve_value(ctx, sites[s].value.value())
            if g.err.byte_length() > 0:
                self.add(id, sites[s].path, g.err)
            elif g.drop:
                sites[s].drop = True
            elif sites[s].kind == SITE_REF:
                sites[s].ref_ = g.ref_.value().copy()
            else:
                sites[s].value = g.value.value().copy()
        var out = with_sites(r, sites)
        out.id = id.copy()
        return out^

    def bindings_of(mut self, ctx: _Ctx, c: Resource, d: Int, id: String) raises -> Dict[String, Value]:
        """The inputs instance `c` (now at `id`) binds, resolved in `ctx`: a
        REF input as `ref { resource: <full path> }`, a STRING input as its
        value. One bound to an unbound optional input is left out."""
        var bound = self.rewrite(ctx, c, id)
        var out = Dict[String, Value]()
        for entry in bound.composite.value().input.items():
            out[entry.key] = entry.value.copy()
        var ins = self.defs[d].input.copy()
        for k in range(len(ins)):
            if ins[k].required and ins[k].name not in out and ins[k].name in c.composite.value().input:
                self.add(
                    id,
                    String("composite.input.") + ins[k].name,
                    String("required input ") + _q(ins[k].name) + String(" of ") + self.keys[d] + String(" is bound to an input that is not set"),
                )
        return out^

    def instantiate(mut self, d: Int, prefix: String, var bindings: Dict[String, Value], depth: Int) raises:
        var ctx = _Ctx(prefix, d, bindings^)
        var comps = self.defs[d].component.copy()
        for k in range(len(comps)):
            ref c = comps[k]
            var id = prefix + String("/") + c.id
            var pad = String("")
            for _ in range(depth):
                pad += String("  ")
            var j = self.nested_def(d, k)
            if j >= 0:
                self.tree += pad + id + String(": ") + self.keys[j] + String(" ") + self.digests[j] + String("\n")
                var b = self.bindings_of(ctx, c, j, id)
                self.instantiate(j, id, b^, depth + 1)
                continue
            self.tree += pad + id + String(": ") + self.catalog.name_of(body_field(c)) + String("\n")
            self.out.append(self.rewrite(ctx, c, id))
            self.produced.append(id^)


def _type_name(catalog: Catalog, r: Resource) -> String:
    try:
        var field = body_field(r)
        var t = catalog.index_of(field)
        if t >= 0:
            return catalog.types[t].name.copy()
        return String("type field ") + String(field)
    except:
        return String("resource with no type")


def expand(catalog: Catalog, definitions: List[CompositeDefinition], resources: List[Resource]) raises -> Expansion:
    """`resources` with every composite instance expanded into primitives,
    in the five steps of the header. On a finding of steps 1 to 4 the
    result holds the findings only; on a finding of step 5 it also holds
    the primitives as far as they were rewritten, which a caller must not
    use (a refused reference is left as written). Raises only on a defect
    of kci itself: with no finding, a rewritten primitive that still holds
    a reference of the composite form (a reference position the walk does
    not know)."""
    var e = _Expander(catalog)
    var x = Expansion()
    e.load(definitions)
    if len(e.findings) == 0:
        e.check_cycles()
    if len(e.findings) == 0:
        for i in range(len(resources)):
            ref r = resources[i]
            if not is_composite(r):
                continue
            var bad = id_problem(r.id)
            if bad.byte_length() > 0:
                e.add(r.id if r.id.byte_length() > 0 else String("#") + String(i), String("id"), bad)
            for k in range(len(resources)):
                if k != i and resources[k].id == r.id:
                    e.add(r.id, String("id"), String("duplicate id"))
            e.check_instance(r, r.id, String(""), -1)
    if len(e.findings) == 0:
        var memo = List[Int]()
        for _ in range(len(e.defs)):
            memo.append(-1)
        var total = 0
        var per = String("")
        for i in range(len(resources)):
            ref r = resources[i]
            if not is_composite(r):
                total += 1
                continue
            var n = e.count(e.find_def(r.composite.value().definition, r.composite.value().version), memo)
            total += n
            per += (String(", ") if per.byte_length() > 0 else String("")) + r.id + String(": ") + (String(n) if n <= MAX_EXPANDED_PRIMITIVES else String("more than ") + String(MAX_EXPANDED_PRIMITIVES))
        if total > MAX_EXPANDED_PRIMITIVES:
            e.add(
                String("(list)"),
                String(""),
                String("the list expands to more than ")
                + String(MAX_EXPANDED_PRIMITIVES)
                + String(" primitives (")
                + per
                + String("); split it, or share fewer instances of a definition"),
            )
    if len(e.findings) > 0:
        x.findings = e.findings.copy()
        return x^
    for i in range(len(resources)):
        ref r = resources[i]
        if is_composite(r):
            e.index(r.id, e.find_def(r.composite.value().definition, r.composite.value().version))
        else:
            e.prims[r.id] = 1
    var top = _Ctx.top()
    for i in range(len(resources)):
        ref r = resources[i]
        if not is_composite(r):
            e.tree += r.id + String(": ") + _type_name(catalog, r) + String("\n")
            e.out.append(e.rewrite(top, r, r.id))
            continue
        var d = e.find_def(r.composite.value().definition, r.composite.value().version)
        e.tree += r.id + String(": ") + e.keys[d] + String(" ") + e.digests[d] + String("\n")
        var b = e.bindings_of(top, r, d, r.id)
        e.instantiate(d, r.id, b^, 1)
    for i in range(len(e.out) if len(e.findings) == 0 else 0):
        var key = unrewritten(e.out[i])
        if key.byte_length() > 0:
            raise Error(
                String("kci: expansion left a composite reference (")
                + key
                + String(") in \"")
                + e.out[i].id
                + String("\"; a reference field is missing from compose_refs._walk")
            )
    x.resources = e.out.copy()
    x.produced = e.produced.copy()
    x.findings = e.findings.copy()
    x.tree = e.tree.copy()
    return x^
