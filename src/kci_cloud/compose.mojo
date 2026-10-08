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
#   1. LOAD every definition kci was given (compose_load.mojo): its name and
#      version grammar (a `kci.` name only as kci ships it, compose_kci.mojo),
#      its inputs (name, type, required or default), its components (ids of
#      the component grammar, unique, never reserved; an instance names a
#      definition that was given, binds its inputs by name and type, and
#      writes no `uses`, retention or metadata), every reference inside a
#      component (a definition is closed: `local` names a component,
#      `input` a REF input, `Value.input` a STRING, INT or BOOL input,
#      never `Ref.resource`), its bindings and presences
#      (compose_bind.mojo: each binding is tried on its component), its
#      exports and its declared outputs. Two definitions with one name and
#      version are refused unless their bytes are the same
#      (`definition_digest`).
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
#      `top`), unless it is ABSENT (its presence input is not set: unbound
#      at the top, or passed down from an input that is not set); a nested
#      instance recurses with its inputs bound in the enclosing one,
#      IMAGE and VALUE_MAP inputs included (as written, or passed down by a
#      binding of the enclosing definition). Every reference is REWRITTEN to name the full path
#      (`Ref.resource` alone): `local` -> `P/<local>`, `input` -> what the
#      instance bound, `path` -> one segment deeper per component, each
#      EXPORTED by its definition, and a reference that ends on an instance
#      reads one of its DECLARED outputs (`named`), which is followed to the
#      primitive that produces it. `Value.input` -> the bound value, else the
#      input's default; an optional input left unbound removes the value or
#      reference that names it. A reference outside every definition may use
#      `path` and `named` the same way; `local` and `input` are refused
#      there, and so is a `resource` holding `/` (a path into an instance
#      is `resource` + `path`, so the export check sees it). A path that
#      is missing, unexported or below a primitive, a reference that ends
#      on an instance without `named` (an instance has no object of its
#      own), and a reference that reaches an absent component, are refused
#      where they are used. Then each BINDING of the definition on a
#      primitive component writes the instance's value into it
#      (`compose_bind.bind_field`); an unset input writes nothing.
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

from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.refs import Image, Ref, Value
from kci_resource_proto.resource import Resource, ValueMap

from kci_cloud.catalog import Catalog, body_field
from kci_cloud.compose_bind import (
    BindValue,
    INPUT_IMAGE,
    INPUT_REF,
    INPUT_VALUE_MAP,
    bind_field,
    is_plain,
    is_set,
    nested_input_name,
    nested_set_names,
    presence_input,
)
from kci_cloud.compose_load import (
    Loader,
    MAX_EXPANDED_PRIMITIVES,
    definition_digest,
    definition_key,
    is_composite,
)
from kci_cloud.adapter import Finding
from kci_cloud.compose_refs import (
    SITE_REF,
    id_problem,
    ref_sites,
    ref_value,
    unrewritten,
    with_sites,
)


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


struct _Bound(Copyable, Movable):
    """The inputs an instance sets, already resolved: plain and REF inputs
    as `Value`s (`values`), IMAGE inputs (`images`), VALUE_MAP inputs
    (`maps`)."""

    var values: Dict[String, Value]
    var images: Dict[String, Image]
    var maps: Dict[String, ValueMap]

    def __init__(out self):
        self.values = Dict[String, Value]()
        self.images = Dict[String, Image]()
        self.maps = Dict[String, ValueMap]()

    def __init__(out self, *, copy: Self):
        self.values = copy.values.copy()
        self.images = copy.images.copy()
        self.maps = copy.maps.copy()


struct _Ctx(Copyable, Movable):
    """Where a reference is resolved: inside the instance at `prefix` of
    definition `def_i` with `bindings` (its inputs, already resolved), or at
    the top of the list (`def_i` -1)."""

    var prefix: String
    var def_i: Int
    var bindings: Dict[String, Value]
    var bound: _Bound

    def __init__(out self, prefix: String, def_i: Int, var bound: _Bound):
        self.prefix = prefix.copy()
        self.def_i = def_i
        self.bindings = bound.values.copy()
        self.bound = bound^

    def __init__(out self, *, copy: Self):
        self.prefix = copy.prefix.copy()
        self.def_i = copy.def_i
        self.bindings = copy.bindings.copy()
        self.bound = copy.bound.copy()

    @staticmethod
    def top() -> _Ctx:
        return _Ctx(String(""), -1, _Bound())


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
    var l: Loader
    var inst: Dict[String, Int]
    var prims: Dict[String, Int]
    var absent: Dict[String, String]
    var out: List[Resource]
    var produced: List[String]
    var tree: String

    def __init__(out self, catalog: Catalog):
        self.l = Loader(catalog)
        self.inst = Dict[String, Int]()
        self.prims = Dict[String, Int]()
        self.absent = Dict[String, String]()
        self.out = List[Resource]()
        self.produced = List[String]()
        self.tree = String("")

    # ---- 5. expansion ---------------------------------------------------------------

    def index(mut self, prefix: String, d: Int, set_names: List[String]):
        """Record every instance and primitive path below instance `prefix`
        of definition `d`, which sets inputs `set_names`, and every ABSENT
        component (its presence input not set) with the reason."""
        self.inst[prefix] = d
        var e = self.l.defs[d].copy()
        for k in range(len(e.component)):
            ref c = e.component[k]
            var path = prefix + String("/") + c.id
            var by = presence_input(e, c.id)
            if by.byte_length() > 0 and not is_set(e, set_names, by):
                self.absent[path] = String("input ") + _q(by) + String(" of ") + self.l.keys[d] + String(" is not set")
                continue
            var j = self.l.nested_def(d, k)
            if j >= 0:
                self.index(path, j, nested_set_names(e, set_names, c))
            else:
                self.prims[path] = 1

    def absent_why(self, path: String) -> String:
        """Why component `path` is absent, as a refusal, or empty."""
        var why = self.absent.get(path)
        if not why:
            return String("")
        return String("component ") + _q(path) + String(" is absent: ") + why.value()

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
                return _Got.refused(self.l.static_ref(ctx.def_i, r))
            if r.local:
                if self.l.component_at(ctx.def_i, r.local.value()) < 0:
                    return _Got.refused(self.l.static_ref(ctx.def_i, r))
                target = ctx.prefix + String("/") + r.local.value()
            else:
                var b = ctx.bindings.get(r.input.value())
                if not b:
                    if self.l.input_type(ctx.def_i, r.input.value()) != INPUT_REF:
                        return _Got.refused(self.l.static_ref(ctx.def_i, r))
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
        var gone = self.absent_why(target)
        if gone.byte_length() > 0:
            return _Got.refused(gone)
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
                if seg.byte_length() == 0 or self.l.component_at(di, seg) < 0:
                    return _Got.refused(_q(target) + String(" (") + self.l.keys[di] + String(") has no component ") + _q(seg))
                if not self.l.exports(di, seg):
                    return _Got.refused(String("component ") + _q(seg) + String(" of ") + self.l.keys[di] + String(" is not exported, so nothing outside it may name it"))
                target = target + String("/") + seg
                gone = self.absent_why(target)
                if gone.byte_length() > 0:
                    return _Got.refused(gone)
        var d = self.inst.get(target)
        if d:
            var di = d.value()
            if r._oneof0_case == 2:
                return self.output_of(target, di, r.named.value())
            if r._oneof0_case == 1:
                return _Got.refused(_q(target) + String(" is an instance of ") + self.l.keys[di] + String(": it exposes only the outputs it declares, read with named"))
            return _Got.refused(
                _q(target)
                + String(" is an instance of ")
                + self.l.keys[di]
                + String(", which has no object of its own: name an exported component with path, or a declared output with named")
            )
        return _Got.of_ref(Ref(target, None, None, None, r._oneof0_case, r.standard.copy(), r.named.copy()))

    def output_of(mut self, target: String, d: Int, name: String) raises -> _Got:
        """Declared output `name` of the instance `target` of definition `d`,
        followed to the primitive that produces it."""
        var outs = self.l.defs[d].output.copy()
        for k in range(len(outs)):
            if outs[k].name == name:
                return self.resolve_ref(_Ctx(target, d, _Bound()), outs[k].from_.value())
        var names = String("")
        for k in range(len(outs)):
            names += (String(", ") if k > 0 else String("")) + outs[k].name
        return _Got.refused(self.l.keys[d] + String(" declares no output ") + _q(name) + String(" (it declares: ") + names + String(")"))

    def resolve_value(mut self, ctx: _Ctx, v: Value) raises -> _Got:
        if v._oneof0_case == 4:
            if ctx.def_i < 0:
                return _Got.refused(String("an input is only for values inside a composite definition"))
            var name = v.input.value()
            var b = ctx.bindings.get(name)
            if b:
                return _Got.of_value(b.value())
            var ins = self.l.defs[ctx.def_i].input.copy()
            for k in range(len(ins)):
                if ins[k].name == name and is_plain(ins[k].type.value):
                    if ins[k].default:
                        return _Got.of_value(ins[k].default.value())
                    return _Got.dropped()
            # cov: unreachable once load has no finding, every Value.input
            # inside definition `def_i` names one of its STRING, INT or BOOL inputs:
            # check_component refuses any other on a primitive component, and
            # check_instance (with `in_def`) on a nested instance's bindings.
            # resolve_value runs with `def_i` >= 0 only on those sites
            # (rewrite and bindings_of under instantiate), and expansion runs
            # only after a load with no finding. Kept as a refusal so a later
            # caller that skips load fails closed.
            return _Got.refused(self.l.keys[ctx.def_i] + String(" declares no STRING, INT or BOOL input ") + _q(name))
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
                self.l.add(id, sites[s].path, g.err)
            elif g.drop:
                sites[s].drop = True
            elif sites[s].kind == SITE_REF:
                sites[s].ref_ = g.ref_.value().copy()
            else:
                sites[s].value = g.value.value().copy()
        var out = with_sites(r, sites)
        out.id = id.copy()
        return out^

    def bindings_of(mut self, ctx: _Ctx, c: Resource, d: Int, id: String) raises -> _Bound:
        """The inputs instance `c` (now at `id`) of definition `d` sets,
        resolved in `ctx`: a REF input as `ref { resource: <full path> }`, a
        plain input as its value, an IMAGE or VALUE_MAP input as written or
        as a binding of the enclosing definition passes it down. One bound
        to an unset optional input is left out."""
        var bound = self.rewrite(ctx, c, id)
        var out = _Bound()
        ref ci = bound.composite.value()
        for entry in ci.input.items():
            out.values[entry.key] = entry.value.copy()
        for entry in ci.image_input.items():
            out.images[entry.key] = entry.value.copy()
        for entry in ci.map_input.items():
            out.maps[entry.key] = entry.value.copy()
        var passed = List[String]()
        if ctx.def_i >= 0:
            var outer = self.l.defs[ctx.def_i].copy()
            for k in range(len(outer.bind)):
                ref b = outer.bind[k]
                var name = nested_input_name(b.field)
                if b.component != c.id or name.byte_length() == 0:
                    continue
                passed.append(name.copy())
                var img = ctx.bound.images.get(b.input)
                if img:
                    out.images[name] = img.value().copy()
                var m = ctx.bound.maps.get(b.input)
                if m:
                    out.maps[name] = m.value().copy()
        var ins = self.l.defs[d].input.copy()
        for k in range(len(ins)):
            ref n = ins[k].name
            var written = n in c.composite.value().input
            for q in range(len(passed)):
                if passed[q] == n:
                    written = True
            var have = n in out.values or n in out.images or n in out.maps
            if ins[k].required and not have and written:
                self.l.add(
                    id,
                    String("composite.input.") + n,
                    String("required input ") + _q(n) + String(" of ") + self.l.keys[d] + String(" is bound to an input that is not set"),
                )
        return out^

    def bind_value(self, ctx: _Ctx, name: String) raises -> Optional[BindValue]:
        """The value input `name` of the instance in `ctx` writes through a
        binding, or None when it is not set."""
        var t = self.l.input_type(ctx.def_i, name)
        if t == INPUT_IMAGE:
            var img = ctx.bound.images.get(name)
            if not img:
                return None
            return BindValue(t, String(""), img.value().copy(), Dict[String, Value]())
        if t == INPUT_VALUE_MAP:
            var m = ctx.bound.maps.get(name)
            if not m:
                return None
            return BindValue(t, String(""), None, m.value().value.copy())
        var v = ctx.bound.values.get(name)
        if not v:
            for k in range(len(self.l.defs[ctx.def_i].input)):
                ref inp = self.l.defs[ctx.def_i].input[k]
                if inp.name == name and inp.default:
                    v = inp.default.value().copy()
        if not v:
            return None
        ref got = v.value()
        if got._oneof0_case != 1:
            raise Error(
                String("input ")
                + _q(name)
                + String(" is ")
                + (String("a parameter") if got._oneof0_case == 2 else String("another resource's output"))
                + String(": a binding writes a literal into a plain field")
            )
        return BindValue(t, got.literal.value(), None, Dict[String, Value]())

    def bound_primitive(mut self, ctx: _Ctx, c: Resource, id: String) raises -> Resource:
        """Primitive component `c` as resource `id`: its references
        rewritten, then each binding of its definition on it written."""
        var r = self.rewrite(ctx, c, id)
        ref binds = self.l.defs[ctx.def_i].bind
        for k in range(len(binds)):
            if binds[k].component != c.id:
                continue
            var at = String("bind[") + String(k) + String("] ") + binds[k].field
            try:
                var bv = self.bind_value(ctx, binds[k].input)
                if not bv:
                    continue
                var got = bind_field(r, binds[k].field, bv.value())
                if not got.resource:
                    self.l.add(id, at, String("input ") + _q(binds[k].input) + String(": ") + got.err)
                    continue
                r = got.resource.value().copy()
            except e:
                self.l.add(id, at, String(e))
        return r^

    def instantiate(mut self, d: Int, prefix: String, var bound: _Bound, depth: Int) raises:
        var ctx = _Ctx(prefix, d, bound^)
        var comps = self.l.defs[d].component.copy()
        for k in range(len(comps)):
            ref c = comps[k]
            var id = prefix + String("/") + c.id
            if id in self.absent:
                continue
            var pad = String("")
            for _ in range(depth):
                pad += String("  ")
            var j = self.l.nested_def(d, k)
            if j >= 0:
                self.tree += pad + id + String(": ") + self.l.keys[j] + String(" ") + self.l.digests[j] + String("\n")
                var b = self.bindings_of(ctx, c, j, id)
                self.instantiate(j, id, b^, depth + 1)
                continue
            self.tree += pad + id + String(": ") + self.l.catalog.name_of(body_field(c)) + String("\n")
            self.out.append(self.bound_primitive(ctx, c, id))
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
    e.l.load(definitions)
    if len(e.l.findings) == 0:
        e.l.check_cycles()
    if len(e.l.findings) == 0:
        for i in range(len(resources)):
            ref r = resources[i]
            if not is_composite(r):
                continue
            var bad = id_problem(r.id)
            if bad.byte_length() > 0:
                e.l.add(r.id if r.id.byte_length() > 0 else String("#") + String(i), String("id"), bad)
            for k in range(len(resources)):
                if k != i and resources[k].id == r.id:
                    e.l.add(r.id, String("id"), String("duplicate id"))
            e.l.check_instance(r, r.id, String(""), -1)
    if len(e.l.findings) == 0:
        var memo = List[Int]()
        for _ in range(len(e.l.defs)):
            memo.append(-1)
        var total = 0
        var per = String("")
        for i in range(len(resources)):
            ref r = resources[i]
            if not is_composite(r):
                total += 1
                continue
            var n = e.l.count(e.l.find_def(r.composite.value().definition, r.composite.value().version), memo)
            total += n
            per += (String(", ") if per.byte_length() > 0 else String("")) + r.id + String(": ") + (String(n) if n <= MAX_EXPANDED_PRIMITIVES else String("more than ") + String(MAX_EXPANDED_PRIMITIVES))
        if total > MAX_EXPANDED_PRIMITIVES:
            e.l.add(
                String("(list)"),
                String(""),
                String("the list expands to more than ")
                + String(MAX_EXPANDED_PRIMITIVES)
                + String(" primitives (")
                + per
                + String("); split it, or share fewer instances of a definition"),
            )
    if len(e.l.findings) > 0:
        x.findings = e.l.findings.copy()
        return x^
    for i in range(len(resources)):
        ref r = resources[i]
        if is_composite(r):
            ref ci = r.composite.value()
            var set_names = List[String]()
            for entry in ci.input.items():
                set_names.append(entry.key.copy())
            for entry in ci.image_input.items():
                set_names.append(entry.key.copy())
            for entry in ci.map_input.items():
                set_names.append(entry.key.copy())
            e.index(r.id, e.l.find_def(ci.definition, ci.version), set_names)
        else:
            e.prims[r.id] = 1
    var top = _Ctx.top()
    for i in range(len(resources)):
        ref r = resources[i]
        if not is_composite(r):
            e.tree += r.id + String(": ") + _type_name(catalog, r) + String("\n")
            e.out.append(e.rewrite(top, r, r.id))
            continue
        var d = e.l.find_def(r.composite.value().definition, r.composite.value().version)
        e.tree += r.id + String(": ") + e.l.keys[d] + String(" ") + e.l.digests[d] + String("\n")
        var b = e.bindings_of(top, r, d, r.id)
        e.instantiate(d, r.id, b^, 1)
    for i in range(len(e.out) if len(e.l.findings) == 0 else 0):
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
    x.findings = e.l.findings.copy()
    x.tree = e.tree.copy()
    return x^
