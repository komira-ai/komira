//! The `.proto` front-end: the descriptors of a `CodeGeneratorRequest`
//! lowered to an `IrModel`, with names resolved, nested types flattened and
//! map entries collapsed.

use std::collections::{BTreeMap, BTreeSet};

use prost_types::field_descriptor_proto::{Label as PbLabel, Type as PbType};
use prost_types::{
    DescriptorProto, EnumDescriptorProto, FieldDescriptorProto,
    FileDescriptorProto, ServiceDescriptorProto,
};

use crate::http_options::HttpRuleTable;
use crate::routing_options::RoutingRuleTable;
use crate::ir::*;
use crate::mojo_names::{escape_member, flatten, CollisionResolver};

#[derive(Clone)]
enum NamedType {
    Message { mojo_name: String, proto_path: String },
    Enum { mojo_name: String, proto_path: String },
}

impl NamedType {
    fn mojo_name(&self) -> &str {
        match self {
            NamedType::Message { mojo_name, .. } => mojo_name,
            NamedType::Enum { mojo_name, .. } => mojo_name,
        }
    }
    fn proto_path(&self) -> &str {
        match self {
            NamedType::Message { proto_path, .. } => proto_path,
            NamedType::Enum { proto_path, .. } => proto_path,
        }
    }
}

/// The lowering driver — holds the cross-file type table.
struct Lowerer {
    /// Fully-qualified proto name -> resolved type. Built in a first pass
    /// over all `proto_file` so forward / cross-file references resolve.
    /// `BTreeMap` (not `HashMap`) so any debug iteration is ordered.
    types: BTreeMap<String, NamedType>,
    /// The `package_prefix` opt value — the generated Mojo namespace.
    mojo_package: String,
    /// The `(google.api.http)` annotation overlay (REST-codegen). Empty for
    /// the gRPC / db / OpenAPI paths; populated by `lower_with_http_rules`
    /// from the descriptor-set re-decode (`http_options.rs`). Keyed by
    /// `(service_name, method_name)`.
    http_rules: HttpRuleTable,
    /// The `(google.api.routing)` annotation overlay (gRPC routing headers).
    /// Empty for paths that do not recover it; populated from the
    /// descriptor-set re-decode (`routing_options.rs`). Keyed by
    /// `(service_name, method_name)`.
    routing_rules: RoutingRuleTable,
    /// The module a cross-file import names, for the files whose own stem
    /// is not their module ([`ModuleNames`]).
    module_names: ModuleNames,
}

/// Lower the full request's descriptor set to the IR.
///
/// `proto_file` is every transitively-needed `FileDescriptorProto` (the
/// imports too); `file_to_generate` is the subset to actually emit. The
/// type table is built over ALL of `proto_file` (so imports resolve), but
/// the returned `IrModel.files` covers only `file_to_generate`.
///
/// This is the gRPC / db / OpenAPI path — no `(google.api.http)` overlay
/// (every `IrMethod.http_rule` is `None`). The REST path uses
/// [`lower_with_http_rules`] to thread the recovered annotation table.
pub fn lower(
    proto_file: &[FileDescriptorProto],
    file_to_generate: &[String],
    package_prefix: &str,
) -> Result<IrModel, String> {
    lower_with_http_rules(
        proto_file,
        file_to_generate,
        package_prefix,
        HttpRuleTable::default(),
    )
}

/// Lower the request, ALSO attaching the recovered `(google.api.routing)`
/// annotations (the gRPC routing-header rule). This is the gRPC path that
/// emits the `x-goog-request-params` header — it threads the routing overlay
/// but no http overlay (the two annotations are independent: a method may
/// carry routing without http, e.g. every GCS method).
pub fn lower_with_routing_rules(
    proto_file: &[FileDescriptorProto],
    file_to_generate: &[String],
    package_prefix: &str,
    routing_rules: RoutingRuleTable,
) -> Result<IrModel, String> {
    lower_with_http_and_routing_rules(
        proto_file,
        file_to_generate,
        package_prefix,
        HttpRuleTable::default(),
        routing_rules,
    )
}

pub fn lower_with_http_rules(
    proto_file: &[FileDescriptorProto],
    file_to_generate: &[String],
    package_prefix: &str,
    http_rules: HttpRuleTable,
) -> Result<IrModel, String> {
    lower_with_http_and_routing_rules(
        proto_file,
        file_to_generate,
        package_prefix,
        http_rules,
        RoutingRuleTable::default(),
    )
}

/// Lower the request, attaching BOTH the recovered `(google.api.http)` and
/// `(google.api.routing)` annotations. The two are independent overlays:
/// `http` drives the REST emit + the OpenAPI doc; `routing` drives the gRPC
/// `x-goog-request-params` header. Either may be `default()` when its path
/// does not recover it.
pub fn lower_with_http_and_routing_rules(
    proto_file: &[FileDescriptorProto],
    file_to_generate: &[String],
    package_prefix: &str,
    http_rules: HttpRuleTable,
    routing_rules: RoutingRuleTable,
) -> Result<IrModel, String> {
    lower_all(
        proto_file,
        file_to_generate,
        package_prefix,
        http_rules,
        routing_rules,
        &ModuleNames::new(),
    )
    .map(|(_, model)| model)
}

/// Which of the request's types and methods to emit.
///
/// The default emits everything in `file_to_generate`. `roots` and `methods`
/// PRUNE: only the types reachable from the named messages / enums and from
/// the request and response types of the named methods are emitted, and a
/// service keeps only its named methods (a service with none is dropped).
/// `messages_only` drops every service, keeping the messages its methods
/// reach.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Scope {
    /// Messages or enums, each named by its fully-qualified proto name
    /// (`pkg.Outer.Inner`) or by a suffix of it that names exactly one type
    /// (`Inner`, `Outer.Inner`). A leading `.` (`.pkg.Outer.Inner`) makes the
    /// name exact: it names that type alone, never one it is a suffix of.
    pub roots: Vec<String>,
    /// Methods, each named `Service.Method`, `pkg.Service.Method` or a bare
    /// `Method` that names exactly one method; a leading `.` makes the name
    /// exact, as for `roots`.
    pub methods: Vec<String>,
    pub messages_only: bool,
    /// Fields left out of their message, each named by its fully-qualified
    /// proto name (`pkg.Message.field`, a leading `.` optional): for a field
    /// the client's callers do not read and whose type the runtime cannot
    /// represent (one reaching a `google.protobuf.Api`, which `komira_wkt`
    /// does not provide, or a `map<string, int64>`, which
    /// `komira_proto_codec` does not decode). The generated message has no
    /// such member, so a response's value for it is skipped as an unknown
    /// key (a lenient JSON read skips one; a binary read skips an unknown
    /// field number), a request never sends it, and its type is reached
    /// through it no longer. A name that is not a field of a generated
    /// message is refused: a field of no message in the files to generate,
    /// and one of a message the scope prunes, which would leave out nothing.
    /// So is a member of a `oneof`.
    pub omit_fields: Vec<String>,
}

impl Scope {
    /// True when nothing is pruned or dropped.
    pub fn is_everything(&self) -> bool {
        !self.prunes() && !self.messages_only && self.omit_fields.is_empty()
    }

    fn prunes(&self) -> bool {
        !self.roots.is_empty() || !self.methods.is_empty()
    }
}

/// [`lower_with_http_and_routing_rules`], then restricted to `scope`.
///
/// When `scope` prunes, a type reachable from it must be declared in a file
/// of `file_to_generate` (or be a well-known type of `komira_wkt`), and every
/// file of `file_to_generate` must keep at least one type or service: the
/// set of generated files is then exactly the closure, so a rule's
/// `bundle_only` cannot carry a file nothing uses.
///
/// `module_names` names the module of each generated file whose own stem is
/// not it ([`ModuleNames`]); a cross-file import names that module.
pub fn lower_scoped(
    proto_file: &[FileDescriptorProto],
    file_to_generate: &[String],
    package_prefix: &str,
    http_rules: HttpRuleTable,
    routing_rules: RoutingRuleTable,
    scope: &Scope,
    module_names: &ModuleNames,
) -> Result<IrModel, String> {
    let (lowerer, mut model) = lower_all(
        proto_file,
        file_to_generate,
        package_prefix,
        http_rules,
        routing_rules,
        module_names,
    )?;
    if scope.is_everything() {
        return Ok(model);
    }
    // Before the prune, so that the closure no longer reaches what an
    // omitted field's type reaches; checked again after it, so that a field
    // of a message the scope does not generate is not taken as omitted.
    let omitted = omit_fields(&mut model, &scope.omit_fields)?;
    if scope.prunes() {
        prune(&lowerer, &mut model, scope)?;
    }
    for (name, msg_fq) in &omitted {
        let generated = model
            .files
            .iter()
            .flat_map(|f| f.messages.iter())
            .any(|m| &m.fq_name == msg_fq);
        if !generated {
            return Err(format!(
                "omit_fields: `{name}` is a field of `{msg_fq}`, which this scope does \
                 not generate, so it leaves out nothing: drop it from omit_fields"
            ));
        }
    }
    if scope.messages_only {
        for file in &mut model.files {
            file.services.clear();
        }
    }
    for file in &mut model.files {
        if file.messages.iter().all(|m| m.is_map_entry)
            && file.enums.is_empty()
            && file.services.is_empty()
        {
            return Err(format!(
                "{} emits nothing under roots={:?} methods={:?} messages_only={}: \
                 drop it from the files to generate",
                file.proto_path, scope.roots, scope.methods, scope.messages_only
            ));
        }
        file.imports =
            lowerer.cross_file_imports(&file.proto_path, &file.messages, &file.services);
    }
    Ok(model)
}

/// Remove each field `names` names from its message (`Scope::omit_fields`).
/// Returns each name with the fully-qualified name of its message.
fn omit_fields(
    model: &mut IrModel,
    names: &[String],
) -> Result<Vec<(String, String)>, String> {
    let mut omitted = Vec::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    for name in names {
        let fq = if name.starts_with('.') { name.clone() } else { format!(".{name}") };
        if !seen.insert(fq.clone()) {
            return Err(format!("omit_fields names `{name}` twice"));
        }
        let Some((msg_fq, field)) = fq.rsplit_once('.') else {
            unreachable!("`fq` starts with a `.`")
        };
        let msg = model
            .files
            .iter_mut()
            .flat_map(|f| f.messages.iter_mut())
            .find(|m| m.fq_name == msg_fq)
            .ok_or_else(|| {
                format!(
                    "omit_fields: `{name}` names no field of a message in the files to \
                     generate (no message `{msg_fq}`)"
                )
            })?;
        let at = msg.fields.iter().position(|f| f.name == field).ok_or_else(|| {
            format!("omit_fields: message `{msg_fq}` has no field `{field}`")
        })?;
        if msg.fields[at].oneof_index.is_some() {
            return Err(format!(
                "omit_fields: `{name}` is a member of a oneof; leaving out one arm would \
                 change what the others mean"
            ));
        }
        msg.fields.remove(at);
        omitted.push((name.clone(), msg_fq.to_string()));
    }
    Ok(omitted)
}

/// Whether `fq` (`.pkg.A.B`) is named by `name`. A name with a leading `.`
/// (`.pkg.A.B`) is already fully qualified and names exactly that `fq`;
/// any other (`pkg.A.B`, `A.B`, `B`) names every `fq` it is a suffix of at
/// a `.` boundary. Matching a dotted name as a suffix would make
/// `.a.LogEntry` also name `.b.a.LogEntry`, an ambiguity its user could not
/// qualify away.
fn names(fq: &str, name: &str) -> bool {
    if name.starts_with('.') {
        return fq == name;
    }
    fq.strip_suffix(name)
        .is_some_and(|head| head.ends_with('.'))
}

/// The one candidate `name` selects, or an error naming the ambiguity.
fn select_one<'a>(
    what: &str,
    name: &str,
    candidates: impl Iterator<Item = &'a str>,
) -> Result<&'a str, String> {
    let hits: Vec<&str> = candidates.filter(|fq| names(fq, name)).collect();
    match hits.as_slice() {
        [one] => Ok(one),
        [] => Err(format!("{what} `{name}` is not declared in the files to generate")),
        many => Err(format!(
            "{what} `{name}` is ambiguous: it names {}; qualify it",
            many.join(", ")
        )),
    }
}

/// Restrict `model` to the closure of `scope.roots` and `scope.methods`.
fn prune(lowerer: &Lowerer, model: &mut IrModel, scope: &Scope) -> Result<(), String> {
    // Every emittable type of the files to generate, by fq-name. Map
    // entries are not types a user names; their key and value are reached
    // through `IrType::Map`.
    let mut declared: BTreeMap<&str, &IrMessage> = BTreeMap::new();
    let mut declared_enums: BTreeSet<&str> = BTreeSet::new();
    let mut methods: Vec<(String, &IrMethod)> = Vec::new();
    for file in &model.files {
        for m in file.messages.iter().filter(|m| !m.is_map_entry) {
            declared.insert(&m.fq_name, m);
        }
        for e in &file.enums {
            declared_enums.insert(&e.fq_name);
        }
        for svc in &file.services {
            for m in &svc.methods {
                let pkg = &file.proto_package;
                let fq = if pkg.is_empty() {
                    format!(".{}.{}", svc.name, m.name)
                } else {
                    format!(".{pkg}.{}.{}", svc.name, m.name)
                };
                methods.push((fq, m));
            }
        }
    }

    let mut pending: Vec<String> = Vec::new();
    for root in &scope.roots {
        let types = declared.keys().chain(declared_enums.iter()).copied();
        pending.push(select_one("root", root, types)?.to_string());
    }
    let mut kept_methods: BTreeSet<String> = BTreeSet::new();
    for name in &scope.methods {
        let fq = select_one("method", name, methods.iter().map(|(fq, _)| fq.as_str()))?;
        let (_, m) = methods.iter().find(|(f, _)| f == fq).expect("selected above");
        pending.push(m.input.fq_name.clone());
        pending.push(m.output.fq_name.clone());
        kept_methods.insert(fq.to_string());
    }

    // The closure, through message fields (map keys and values included).
    let mut reached: BTreeSet<String> = BTreeSet::new();
    while let Some(fq) = pending.pop() {
        if !reached.insert(fq.clone()) {
            continue;
        }
        if let Some(msg) = declared.get(fq.as_str()) {
            for field in &msg.fields {
                field_targets(&field.ty, &mut pending);
            }
        } else if !declared_enums.contains(fq.as_str()) && wkt_symbol(&fq).is_none() {
            let file = lowerer
                .types
                .get(&fq)
                .map(|t| t.proto_path().to_string())
                .unwrap_or_else(|| "a file not in the request".to_string());
            return Err(format!(
                "`{fq}` is reachable from roots={:?} methods={:?} but its file \
                 {file} is not generated: add it to the files to generate",
                scope.roots, scope.methods
            ));
        }
    }

    for file in &mut model.files {
        let pkg = file.proto_package.clone();
        // A map entry stays only when its own message, its DIRECT parent, is
        // reached: a reached `Outer` does not keep the entries of a pruned
        // `Outer.Inner`. The emitter skips entries, but the imports are
        // computed over them, so an orphaned one would import its value.
        file.messages.retain(|m| {
            if m.is_map_entry {
                m.fq_name
                    .rsplit_once('.')
                    .is_some_and(|(parent, _)| reached.contains(parent))
            } else {
                reached.contains(&m.fq_name)
            }
        });
        file.enums.retain(|e| reached.contains(&e.fq_name));
        for svc in &mut file.services {
            let prefix = if pkg.is_empty() {
                format!(".{}.", svc.name)
            } else {
                format!(".{pkg}.{}.", svc.name)
            };
            svc.methods
                .retain(|m| kept_methods.contains(&format!("{prefix}{}", m.name)));
        }
        file.services.retain(|s| !s.methods.is_empty());
    }
    Ok(())
}

/// Push the fq-names of the messages and enums `ty` refers to.
fn field_targets(ty: &IrType, out: &mut Vec<String>) {
    match ty {
        IrType::Message(t) | IrType::Enum(t) => out.push(t.fq_name.clone()),
        IrType::Map(k, v) => {
            field_targets(k, out);
            field_targets(v, out);
        }
        IrType::Scalar(_) => {}
        IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
    }
}

/// Lower every file of `file_to_generate`, returning the lowerer too (its
/// type table resolves the imports of a pruned model).
fn lower_all(
    proto_file: &[FileDescriptorProto],
    file_to_generate: &[String],
    package_prefix: &str,
    http_rules: HttpRuleTable,
    routing_rules: RoutingRuleTable,
    module_names: &ModuleNames,
) -> Result<(Lowerer, IrModel), String> {
    let mut lowerer = Lowerer {
        types: BTreeMap::new(),
        mojo_package: package_prefix.to_string(),
        http_rules,
        routing_rules,
        module_names: module_names.clone(),
    };

    // --- Pass 1: build the cross-file type table. ----------------------
    // Every message and enum, in every file, gets a resolved `mojo_name`.
    // A `CollisionResolver` PER FILE keeps names unique within a generated
    // `.mojo` (a cross-file collision is harmless — separate modules).
    for file in proto_file {
        let mut resolver = CollisionResolver::new();
        let pkg = file.package();
        let path = file.name().to_string();
        for msg in &file.message_type {
            register_message(&mut lowerer, &mut resolver, pkg, &path, &[], msg);
        }
        for en in &file.enum_type {
            register_enum(&mut lowerer, &mut resolver, pkg, &path, &[], en);
        }
    }

    // --- Pass 2: lower the files to generate. --------------------------
    let mut model = IrModel::default();
    for path in file_to_generate {
        let file = proto_file
            .iter()
            .find(|f| f.name() == path)
            .ok_or_else(|| format!("file_to_generate {path:?} not in proto_file"))?;
        model.files.push(lowerer.lower_file(file)?);
    }
    Ok((lowerer, model))
}

/// Register a message (and recursively its nested types) in the type table.
fn register_message(
    lowerer: &mut Lowerer,
    resolver: &mut CollisionResolver,
    pkg: &str,
    proto_path: &str,
    outer_path: &[String],
    msg: &DescriptorProto,
) {
    let mut path = outer_path.to_vec();
    path.push(msg.name().to_string());

    let fq = fq_name(pkg, &path);
    let mojo_name = resolver.resolve(&flatten(&path));
    lowerer.types.insert(
        fq,
        NamedType::Message {
            mojo_name,
            proto_path: proto_path.to_string(),
        },
    );

    for nested in &msg.nested_type {
        register_message(lowerer, resolver, pkg, proto_path, &path, nested);
    }
    for en in &msg.enum_type {
        register_enum(lowerer, resolver, pkg, proto_path, &path, en);
    }
}

/// Register an enum in the type table.
fn register_enum(
    lowerer: &mut Lowerer,
    resolver: &mut CollisionResolver,
    pkg: &str,
    proto_path: &str,
    outer_path: &[String],
    en: &EnumDescriptorProto,
) {
    let mut path = outer_path.to_vec();
    path.push(en.name().to_string());
    let fq = fq_name(pkg, &path);
    let mojo_name = resolver.resolve(&flatten(&path));
    lowerer.types.insert(
        fq,
        NamedType::Enum {
            mojo_name,
            proto_path: proto_path.to_string(),
        },
    );
}

/// Build the fully-qualified proto name protoc uses for `type_name`
/// references: a leading `.`, the package, then the dotted nested path.
fn fq_name(pkg: &str, path: &[String]) -> String {
    if pkg.is_empty() {
        format!(".{}", path.join("."))
    } else {
        format!(".{}.{}", pkg, path.join("."))
    }
}

impl Lowerer {
    fn lower_file(&self, file: &FileDescriptorProto) -> Result<IrFile, String> {
        let pkg = file.package();
        let mut messages = Vec::new();
        let mut enums = Vec::new();

        // Top-level enums, then top-level messages (each flattening its
        // own nested types), in declaration order.
        for en in &file.enum_type {
            enums.push(self.lower_enum(pkg, &[], en));
        }
        for msg in &file.message_type {
            self.lower_message(pkg, &[], msg, &mut messages, &mut enums)?;
        }

        let services: Vec<IrService> = file
            .service
            .iter()
            .map(|s| self.lower_service(pkg, s))
            .collect();

        let imports = self.cross_file_imports(file.name(), &messages, &services);

        Ok(IrFile {
            proto_path: file.name().to_string(),
            proto_package: pkg.to_string(),
            mojo_package: self.mojo_package.clone(),
            messages,
            enums,
            services,
            imports,
        })
    }

    fn cross_file_imports(
        &self,
        this_path: &str,
        messages: &[IrMessage],
        services: &[IrService],
    ) -> Vec<IrImport> {
        let mut set: BTreeSet<IrImport> = BTreeSet::new();
        for msg in messages {
            for field in &msg.fields {
                self.collect_type_imports(this_path, &field.ty, &mut set);
            }
        }
        for svc in services {
            for m in &svc.methods {
                self.collect_typeref_import(this_path, &m.input, &mut set);
                self.collect_typeref_import(this_path, &m.output, &mut set);
            }
        }
        set.into_iter().collect()
    }

    /// Add the cross-file `import` for one resolved `TypeRef` (a service
    /// method's input/output type) to `set`, if it is declared in another
    /// `.proto`. A method type whose fq-name is not in the type table (an
    /// import not present in the request) is silently skipped — the same
    /// best-effort posture `method_type_ref` takes.
    fn collect_typeref_import(
        &self,
        this_path: &str,
        tref: &TypeRef,
        set: &mut BTreeSet<IrImport>,
    ) {
        if let Some(nt) = self.types.get(&tref.fq_name) {
            if nt.proto_path() != this_path {
                set.insert(self.import_for(&tref.fq_name, nt));
            }
        }
    }

    /// Add the cross-file `import` for one `IrType` (recursing into a map
    /// key/value) to `set`, if the type is declared in another `.proto`.
    fn collect_type_imports(
        &self,
        this_path: &str,
        ty: &IrType,
        set: &mut BTreeSet<IrImport>,
    ) {
        match ty {
            IrType::Message(tref) | IrType::Enum(tref) => {
                if let Some(nt) = self.types.get(&tref.fq_name) {
                    if nt.proto_path() != this_path {
                        set.insert(self.import_for(&tref.fq_name, nt));
                    }
                }
            }
            IrType::Map(k, v) => {
                self.collect_type_imports(this_path, k, set);
                self.collect_type_imports(this_path, v, set);
            }
            IrType::Scalar(_) => {}
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    /// Build the `IrImport` for a cross-file type. A well-known type
    /// (`.google.protobuf.*`) imports from the `komira_wkt` runtime
    /// package; any other imported type imports from the sibling generated
    /// module `<mojo_package>.<stem-of-the-declaring-proto>`.
    fn import_for(&self, fq_name: &str, nt: &NamedType) -> IrImport {
        if let Some(symbol) = wkt_symbol(fq_name) {
            return IrImport {
                module: "komira_wkt".to_string(),
                symbol: symbol.to_string(),
            };
        }
        // A user-imported `.proto`: the generated sibling module. The
        // `mojo_proto_library` rule emits a flat `<stem>.mojo` per file
        // under the `<mojo_package>` package directory.
        let stem = module_stem(nt.proto_path(), &self.module_names);
        IrImport {
            module: format!("{}.{}", self.mojo_package, stem),
            symbol: nt.mojo_name().to_string(),
        }
    }

    /// Lower a message, flattening its nested types into the same flat
    /// `messages` / `enums` vectors (Mojo has no nested-struct namespace).
    fn lower_message(
        &self,
        pkg: &str,
        outer_path: &[String],
        msg: &DescriptorProto,
        messages: &mut Vec<IrMessage>,
        enums: &mut Vec<IrEnum>,
    ) -> Result<(), String> {
        let mut path = outer_path.to_vec();
        path.push(msg.name().to_string());
        let fq = fq_name(pkg, &path);
        let mojo_name = self.resolved_mojo_name(&fq)?;

        let is_map_entry = msg
            .options
            .as_ref()
            .and_then(|o| o.map_entry)
            .unwrap_or(false);

        let synthetic_oneof: BTreeSet<i32> = msg
            .field
            .iter()
            .filter(|f| f.proto3_optional())
            .filter_map(|f| f.oneof_index)
            .collect();

        let mut oneofs: Vec<IrOneof> = Vec::new();
        // Map a descriptor `oneof_decl_index` -> the index into `oneofs`
        // (real oneofs only — synthetic ones are absent).
        let mut oneof_remap: BTreeMap<i32, u32> = BTreeMap::new();
        for (decl_idx, decl) in msg.oneof_decl.iter().enumerate() {
            let decl_idx = decl_idx as i32;
            if synthetic_oneof.contains(&decl_idx) {
                continue;
            }
            let arms: Vec<String> = msg
                .field
                .iter()
                .filter(|f| f.oneof_index == Some(decl_idx))
                .map(|f| escape_member(f.name()))
                .collect();
            oneof_remap.insert(decl_idx, oneofs.len() as u32);
            oneofs.push(IrOneof {
                name: escape_member(decl.name()),
                arms,
            });
        }

        // Fields. A `map<K,V>` field's type points at a synthetic
        // map-entry message — detect it and collapse to `IrType::Map`.
        let mut fields = Vec::new();
        for field in &msg.field {
            fields.push(self.lower_field(pkg, &path, msg, field, &oneof_remap)?);
        }

        messages.push(IrMessage {
            name: msg.name().to_string(),
            mojo_name,
            fq_name: fq,
            is_map_entry,
            fields,
            oneofs,
        });

        // Recurse into nested messages and enums (flattened).
        for en in &msg.enum_type {
            enums.push(self.lower_enum(pkg, &path, en));
        }
        for nested in &msg.nested_type {
            self.lower_message(pkg, &path, nested, messages, enums)?;
        }
        Ok(())
    }

    /// Lower one field, with map-entry collapse and `proto3_optional`
    /// presence.
    fn lower_field(
        &self,
        pkg: &str,
        msg_path: &[String],
        msg: &DescriptorProto,
        field: &FieldDescriptorProto,
        oneof_remap: &BTreeMap<i32, u32>,
    ) -> Result<IrField, String> {
        // The base IR type of the field, before label is considered.
        let raw_ty = self.lower_type(field)?;

        // Map-entry collapse. A `map<K,V>` field is `LABEL_REPEATED` and
        // its `type_name` points at a nested message with `map_entry =
        // true`; that message has field 1 = key, field 2 = value. If this
        // field references such a message, collapse to `IrType::Map`.
        let (ty, label) = if field.label() == PbLabel::Repeated {
            if let IrType::Message(ref tref) = raw_ty {
                if let Some(entry) = self.find_map_entry(pkg, msg_path, msg, &tref.fq_name) {
                    let kv = self.map_entry_kv(pkg, msg_path, msg, &entry)?;
                    (IrType::Map(Box::new(kv.0), Box::new(kv.1)), Label::Repeated)
                } else {
                    (raw_ty, Label::Repeated)
                }
            } else {
                (raw_ty, Label::Repeated)
            }
        } else if field.proto3_optional() {
            (raw_ty, Label::Optional)
        } else if matches!(raw_ty, IrType::Message(_)) && field.oneof_index.is_none() {
            (raw_ty, Label::Optional)
        } else {
            (raw_ty, Label::Single)
        };

        // A field in a SYNTHETIC oneof (proto3_optional) reports no
        // `oneof_index`; a field in a REAL oneof reports the remapped one.
        let oneof_index = if field.proto3_optional() {
            None
        } else {
            field
                .oneof_index
                .and_then(|i| oneof_remap.get(&i).copied())
        };

        Ok(IrField {
            name: escape_member(field.name()),
            ty,
            label,
            proto_field_number: field.number() as u32,
            json_name: field.json_name().to_string(),
            oneof_index,
        })
    }

    /// Resolve a field's descriptor type to the IR `IrType` (scalar,
    /// message ref, or enum ref — `Map` is handled by the caller).
    fn lower_type(&self, field: &FieldDescriptorProto) -> Result<IrType, String> {
        let scalar = match field.r#type() {
            PbType::Double => Some(ScalarKind::Double),
            PbType::Float => Some(ScalarKind::Float),
            PbType::Int64 => Some(ScalarKind::Int64),
            PbType::Sint64 => Some(ScalarKind::Sint64),
            PbType::Sfixed64 => Some(ScalarKind::Sfixed64),
            PbType::Uint64 => Some(ScalarKind::Uint64),
            PbType::Fixed64 => Some(ScalarKind::Fixed64),
            PbType::Int32 => Some(ScalarKind::Int32),
            PbType::Sint32 => Some(ScalarKind::Sint32),
            PbType::Sfixed32 => Some(ScalarKind::Sfixed32),
            PbType::Uint32 => Some(ScalarKind::Uint32),
            PbType::Fixed32 => Some(ScalarKind::Fixed32),
            PbType::Bool => Some(ScalarKind::Bool),
            PbType::String => Some(ScalarKind::String),
            PbType::Bytes => Some(ScalarKind::Bytes),
            PbType::Group | PbType::Message | PbType::Enum => None,
        };
        if let Some(s) = scalar {
            return Ok(IrType::Scalar(s));
        }
        // Message / enum / group — resolve `type_name`.
        let tn = field.type_name();
        if tn.is_empty() {
            return Err(format!("field {:?} has no type_name", field.name()));
        }
        let resolved = self
            .types
            .get(tn)
            .ok_or_else(|| format!("unresolved type reference {tn:?}"))?;
        let tref = TypeRef {
            fq_name: tn.to_string(),
            mojo_name: resolved.mojo_name().to_string(),
        };
        match resolved {
            NamedType::Message { .. } => Ok(IrType::Message(tref)),
            NamedType::Enum { .. } => Ok(IrType::Enum(tref)),
        }
    }

    /// Find the `DescriptorProto` of the map-entry message a `map<K,V>`
    /// field references, if it is one. Map-entry messages are nested in
    /// the message that declares the field.
    fn find_map_entry(
        &self,
        pkg: &str,
        msg_path: &[String],
        msg: &DescriptorProto,
        ref_fq: &str,
    ) -> Option<DescriptorProto> {
        for nested in &msg.nested_type {
            let mut np = msg_path.to_vec();
            np.push(nested.name().to_string());
            if fq_name(pkg, &np) == ref_fq {
                let is_entry = nested
                    .options
                    .as_ref()
                    .and_then(|o| o.map_entry)
                    .unwrap_or(false);
                if is_entry {
                    return Some(nested.clone());
                }
            }
        }
        None
    }

    /// Resolve a map-entry message's key (field 1) and value (field 2)
    /// types to IR types.
    fn map_entry_kv(
        &self,
        _pkg: &str,
        _msg_path: &[String],
        _msg: &DescriptorProto,
        entry: &DescriptorProto,
    ) -> Result<(IrType, IrType), String> {
        let key_f = entry
            .field
            .iter()
            .find(|f| f.number() == 1)
            .ok_or("map-entry message has no key field 1")?;
        let val_f = entry
            .field
            .iter()
            .find(|f| f.number() == 2)
            .ok_or("map-entry message has no value field 2")?;
        Ok((self.lower_type(key_f)?, self.lower_type(val_f)?))
    }

    fn lower_enum(
        &self,
        pkg: &str,
        outer_path: &[String],
        en: &EnumDescriptorProto,
    ) -> IrEnum {
        let mut path = outer_path.to_vec();
        path.push(en.name().to_string());
        let fq = fq_name(pkg, &path);
        let mojo_name = match self.types.get(&fq) {
            Some(NamedType::Enum { mojo_name, .. }) => mojo_name.clone(),
            _ => flatten(&path),
        };
        let values = en
            .value
            .iter()
            .map(|v| IrEnumValue {
                name: v.name().to_string(),
                mojo_name: escape_member(v.name()),
                number: v.number(),
            })
            .collect();
        IrEnum {
            name: en.name().to_string(),
            mojo_name,
            fq_name: fq,
            values,
        }
    }

    fn lower_service(&self, pkg: &str, svc: &ServiceDescriptorProto) -> IrService {
        let svc_name = svc.name().to_string();
        let methods = svc
            .method
            .iter()
            .map(|m| {
                let idempotent = m
                    .options
                    .as_ref()
                    .and_then(|o| o.idempotency_level)
                    .map(|l| {
                        // IDEMPOTENT = 2 in the descriptor enum.
                        l == prost_types::method_options::IdempotencyLevel::Idempotent
                            as i32
                    })
                    .unwrap_or(false);
                // The `(google.api.http)` annotation, recovered from the
                // descriptor-set re-decode and keyed by (service, method).
                // `None` for every gRPC / db / OpenAPI path (the overlay is
                // empty there); `Some` only for `rest`-target annotated
                // methods. The `rest`-mode validation (un-annotated method =
                // loud error; a streaming method = loud error) lives
                // at the emit boundary where `ProtocolMode` is known.
                let http_rule = self
                    .http_rules
                    .rule_for(&svc_name, m.name())
                    .map(|r| IrHttpRule {
                        verb: r.verb.ir_token().to_string(),
                        path_template: r.path_template.clone(),
                        body: r.body.clone(),
                        additional_bindings: r
                            .additional_bindings
                            .iter()
                            .map(|b| IrHttpRule {
                                verb: b.verb.ir_token().to_string(),
                                path_template: b.path_template.clone(),
                                body: b.body.clone(),
                                additional_bindings: Vec::new(),
                            })
                            .collect(),
                    });
                // The `(google.api.routing)` annotation, recovered from the
                // descriptor-set re-decode and keyed by (service, method).
                // `None` for every method without the annotation; `Some` for
                // GCP gRPC methods that carry it (GCS, Cloud Run, ...).
                let routing_rule = self
                    .routing_rules
                    .rule_for(&svc_name, m.name())
                    .map(|r| IrRoutingRule {
                        parameters: r
                            .parameters
                            .iter()
                            .map(|p| IrRoutingParameter {
                                field: p.field.clone(),
                                path_template: p.path_template.clone(),
                            })
                            .collect(),
                    });
                IrMethod {
                    name: m.name().to_string(),
                    input: self.method_type_ref(m.input_type()),
                    output: self.method_type_ref(m.output_type()),
                    client_streaming: m.client_streaming(),
                    server_streaming: m.server_streaming(),
                    idempotent,
                    http_rule,
                    routing_rule,
                }
            })
            .collect();
        let _ = pkg;
        IrService {
            name: svc_name,
            methods,
            // Filled after lowering from the recovered service options
            // (`service_options.rs`), on the paths that recover them.
            default_host: None,
            host_from_service_config: false,
        }
    }

    /// Resolve an RPC `input_type` / `output_type` to a `TypeRef`. If the
    /// type is unknown (an import not in the request), fall back to a
    /// best-effort flattened name from the fq path so emission still
    /// produces a coherent dump.
    fn method_type_ref(&self, fq: &str) -> TypeRef {
        let mojo_name = match self.types.get(fq) {
            Some(nt) => nt.mojo_name().to_string(),
            None => {
                // `.pkg.Outer.Inner` -> `Outer_Inner`.
                let tail = fq.trim_start_matches('.');
                let comps: Vec<String> =
                    tail.rsplit('.').take(1).map(|s| s.to_string()).collect();
                flatten(&comps)
            }
        };
        TypeRef {
            fq_name: fq.to_string(),
            mojo_name,
        }
    }

    fn resolved_mojo_name(&self, fq: &str) -> Result<String, String> {
        match self.types.get(fq) {
            Some(nt) => Ok(nt.mojo_name().to_string()),
            None => Err(format!("internal: {fq:?} missing from type table")),
        }
    }
}

fn wkt_symbol(fq_name: &str) -> Option<&'static str> {
    match fq_name {
        ".google.protobuf.Any" => Some("Any"),
        ".google.protobuf.Timestamp" => Some("Timestamp"),
        ".google.protobuf.Duration" => Some("Duration"),
        ".google.protobuf.Empty" => Some("Empty"),
        ".google.protobuf.FieldMask" => Some("FieldMask"),
        ".google.protobuf.Struct" => Some("Struct"),
        ".google.protobuf.Value" => Some("Value"),
        ".google.protobuf.ListValue" => Some("ListValue"),
        ".google.protobuf.NullValue" => Some("NullValue"),
        ".google.protobuf.DoubleValue" => Some("DoubleValue"),
        ".google.protobuf.FloatValue" => Some("FloatValue"),
        ".google.protobuf.Int64Value" => Some("Int64Value"),
        ".google.protobuf.UInt64Value" => Some("UInt64Value"),
        ".google.protobuf.Int32Value" => Some("Int32Value"),
        ".google.protobuf.UInt32Value" => Some("UInt32Value"),
        ".google.protobuf.BoolValue" => Some("BoolValue"),
        ".google.protobuf.StringValue" => Some("StringValue"),
        ".google.protobuf.BytesValue" => Some("BytesValue"),
        _ => None,
    }
}

/// The module a generated `.proto` is written as, for the files whose own
/// stem cannot be it: `proto path -> module stem`. A file named here is
/// `<stem>.mojo` and imported as `<package>.<stem>`; every other file keeps
/// [`proto_stem`]. Two cases need it: a basename that is not a Mojo module
/// name (`k8s.min.proto`), and two files of one package with the same
/// basename (`google/rpc/status.proto` beside `google/cloud/run/v2/status.proto`),
/// which the flat generated package cannot hold apart.
pub type ModuleNames = BTreeMap<String, String>;

/// The module stem `proto_path` is generated as under `names`.
pub fn module_stem(proto_path: &str, names: &ModuleNames) -> String {
    names
        .get(proto_path)
        .cloned()
        .unwrap_or_else(|| proto_stem(proto_path))
}

/// The flat module stem of a `.proto` path — `google/protobuf/foo.proto`
/// -> `foo`. Mirrors `emit::proto_to_mojo_path` (which appends `.mojo`).
pub fn proto_stem(proto_path: &str) -> String {
    let basename = proto_path.rsplit('/').next().unwrap_or(proto_path);
    basename
        .rsplit_once('.')
        .map(|(s, _)| s)
        .unwrap_or(basename)
        .to_string()
}

pub fn recursion_breaking_edges(file: &IrFile) -> BTreeSet<(String, String)> {
    recursion_breaking_edges_under(file, ContainerInlining::Never)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ContainerInlining {
    /// A `Repeated` field or a `Map` value never inlines — proto3's shape.
    Never,
    /// A container-typed field inlines its element, because the emitter wraps
    /// it in something that does (`Optional`). The AWS client emitter's shape.
    ViaOptionalWrapper,
}

fn cycle_target(ty: &IrType, label: Label, containers_inline: bool) -> Option<&str> {
    match ty {
        IrType::Message(t) => {
            if label == Label::Repeated && !containers_inline {
                None
            } else {
                Some(t.mojo_name.as_str())
            }
        }
        IrType::Map(_, v) => {
            if containers_inline {
                cycle_target(v, Label::Single, containers_inline)
            } else {
                None
            }
        }
        IrType::List(e) => {
            if containers_inline {
                cycle_target(e, Label::Single, containers_inline)
            } else {
                None
            }
        }
        _ => None,
    }
}

fn reference_targets(ty: &IrType) -> Vec<&str> {
    match ty {
        IrType::Message(t) => vec![t.mojo_name.as_str()],
        IrType::Map(k, v) => {
            let mut out = reference_targets(k);
            out.extend(reference_targets(v));
            out
        }
        IrType::List(e) => reference_targets(e),
        _ => Vec::new(),
    }
}

/// [`recursion_breaking_edges`], with the caller's container precondition
/// stated rather than assumed.
pub fn recursion_breaking_edges_under(
    file: &IrFile,
    containers: ContainerInlining,
) -> BTreeSet<(String, String)> {
    // mojo_name -> &IrMessage.
    let by_name: BTreeMap<&str, &IrMessage> =
        file.messages.iter().map(|m| (m.mojo_name.as_str(), m)).collect();

    let containers_inline = containers == ContainerInlining::ViaOptionalWrapper;

    let mut succ: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for msg in &file.messages {
        let out = succ.entry(msg.mojo_name.as_str()).or_default();
        for field in &msg.fields {
            for t in reference_targets(&field.ty) {
                // Only a message DECLARED IN THIS FILE is a node here; a
                // cross-file reference cannot close a cycle inside it.
                if by_name.contains_key(t) {
                    out.insert(t);
                }
            }
        }
    }

    let mut reaches: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for msg in &file.messages {
        let start = msg.mojo_name.as_str();
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        let mut stack: Vec<&str> =
            succ.get(start).into_iter().flatten().copied().collect();
        while let Some(n) = stack.pop() {
            if !seen.insert(n) {
                continue;
            }
            if let Some(next) = succ.get(n) {
                stack.extend(next.iter().copied());
            }
        }
        reaches.insert(start, seen);
    }

    // Box every INLINING edge whose SOURCE and TARGET share a strongly-
    // connected component OF THE REFERENCE GRAPH. `src` reaches `dst` by
    // definition (this field is a reference edge), so the test reduces to
    // "does `dst` reach back to `src`". A direct self-reference satisfies it:
    // `succ[src]` contains `src`, so `reaches[src]` does too.
    let mut boxed: BTreeSet<(String, String)> = BTreeSet::new();
    for msg in &file.messages {
        let src = msg.mojo_name.as_str();
        for field in &msg.fields {
            let Some(dst) = cycle_target(&field.ty, field.label, containers_inline)
            else {
                continue;
            };
            if reaches.get(dst).is_some_and(|r| r.contains(src)) {
                boxed.insert((src.to_string(), field.name.clone()));
            }
        }
    }
    boxed
}

#[cfg(test)]
mod nested_container_reference_edges {
    use super::*;

    fn msg_ref(name: &str) -> IrType {
        IrType::Message(TypeRef {
            fq_name: format!(".t.{name}"),
            mojo_name: name.to_string(),
        })
    }

    fn field(name: &str, ty: IrType) -> IrField {
        IrField {
            name: name.to_string(),
            ty,
            label: Label::Single,
            proto_field_number: 1,
            json_name: name.to_string(),
            oneof_index: None,
        }
    }

    fn message(name: &str, fields: Vec<IrField>) -> IrMessage {
        IrMessage {
            name: name.to_string(),
            mojo_name: name.to_string(),
            fq_name: format!(".t.{name}"),
            is_map_entry: false,
            fields,
            oneofs: Vec::new(),
        }
    }

    fn file(messages: Vec<IrMessage>) -> IrFile {
        IrFile {
            proto_path: "t/fixture.proto".to_string(),
            proto_package: "t".to_string(),
            mojo_package: "t".to_string(),
            messages,
            enums: Vec::new(),
            services: Vec::new(),
            imports: Vec::new(),
        }
    }

    fn boxed_under(f: &IrFile, c: ContainerInlining) -> BTreeSet<(String, String)> {
        recursion_breaking_edges_under(f, c)
    }

    fn is_boxed(edges: &BTreeSet<(String, String)>, m: &str, fld: &str) -> bool {
        edges.contains(&(m.to_string(), fld.to_string()))
    }

    #[test]
    fn a_cycle_closed_only_through_a_nested_list_is_seen() {
        let f = file(vec![
            message(
                "NestListHub",
                vec![
                    field("deep", IrType::List(Box::new(IrType::List(Box::new(
                        msg_ref("NestListHub"),
                    ))))),
                    field("leaf", msg_ref("NestListLeaf")),
                ],
            ),
            message("NestListLeaf", vec![field("v", IrType::Scalar(ScalarKind::String))]),
        ]);

        let edges = boxed_under(&f, ContainerInlining::ViaOptionalWrapper);
        assert!(
            is_boxed(&edges, "NestListHub", "deep"),
            "`List[List[Self]]` is the ONLY path NestListHub has back to itself, \
             so the `IrType::List` arm of `reference_targets` must recurse \
             through BOTH levels. Got: {edges:?}"
        );
        // NO OVER-BOXING: the leaf cannot get back.
        assert!(
            !is_boxed(&edges, "NestListHub", "leaf"),
            "NestListLeaf does not reach back, so `leaf` must stay inlined: {edges:?}"
        );
    }

    #[test]
    fn a_cycle_closed_only_through_a_list_of_maps_is_seen() {
        let f = file(vec![message(
            "NestMapHub",
            vec![field(
                "deep",
                IrType::List(Box::new(IrType::Map(
                    Box::new(IrType::Scalar(ScalarKind::String)),
                    Box::new(msg_ref("NestMapHub")),
                ))),
            )],
        )]);

        let edges = boxed_under(&f, ContainerInlining::ViaOptionalWrapper);
        assert!(
            is_boxed(&edges, "NestMapHub", "deep"),
            "`List[Dict[String, Self]]` is the ONLY path back, so BOTH the \
             `List` and the `Map` arm of `reference_targets` must recurse. \
             Got: {edges:?}"
        );
    }

    #[test]
    fn a_map_key_is_a_reference_edge_as_much_as_its_value() {
        let f = file(vec![
            message("KeyCycleHub", vec![field("wrap", msg_ref("KeyCycleWrapper"))]),
            message(
                "KeyCycleWrapper",
                vec![field(
                    "by_msg",
                    IrType::Map(
                        Box::new(msg_ref("KeyCycleCase")),
                        Box::new(IrType::Scalar(ScalarKind::String)),
                    ),
                )],
            ),
            message("KeyCycleCase", vec![field("condition", msg_ref("KeyCycleHub"))]),
        ]);

        let edges = boxed_under(&f, ContainerInlining::ViaOptionalWrapper);
        assert!(
            is_boxed(&edges, "KeyCycleHub", "wrap"),
            "the map KEY in KeyCycleWrapper.by_msg is the ONLY hop from \
             KeyCycleWrapper to KeyCycleCase; without it KeyCycleWrapper \
             reaches nothing and `wrap` unboxes. Got: {edges:?}"
        );
        assert!(
            is_boxed(&edges, "KeyCycleCase", "condition"),
            "the same component, entered from the other side: {edges:?}"
        );
    }

    #[test]
    fn a_cycle_closed_only_through_a_map_value_is_seen_under_proto3() {
        let f = file(vec![
            message("MapCycleHub", vec![field("wrap", msg_ref("MapCycleWrapper"))]),
            message(
                "MapCycleWrapper",
                vec![field(
                    "cases",
                    IrType::Map(
                        Box::new(IrType::Scalar(ScalarKind::String)),
                        Box::new(msg_ref("MapCycleCase")),
                    ),
                )],
            ),
            message(
                "MapCycleCase",
                vec![
                    field("condition", msg_ref("MapCycleHub")),
                    field("leaf", msg_ref("MapCycleLeaf")),
                ],
            ),
            message("MapCycleLeaf", vec![field("v", IrType::Scalar(ScalarKind::String))]),
        ]);

        let edges = boxed_under(&f, ContainerInlining::Never);
        assert!(
            is_boxed(&edges, "MapCycleHub", "wrap"),
            "MapCycleHub gets back to itself only through the map VALUE in \
             MapCycleWrapper.cases; the `Map` arm of `reference_targets` is \
             what makes that edge exist. Got: {edges:?}"
        );
        assert!(
            is_boxed(&edges, "MapCycleCase", "condition"),
            "the same cycle, entered from the other side: {edges:?}"
        );
        // A `map` field is ALREADY a `Dict` under `Never` — boxing re-shapes
        // INLINING edges only, so it is never in this set.
        assert!(
            !is_boxed(&edges, "MapCycleWrapper", "cases"),
            "a map field is already a Dict and must not be reported as boxed"
        );
        // NO OVER-BOXING.
        assert!(
            !is_boxed(&edges, "MapCycleCase", "leaf"),
            "MapCycleLeaf does not reach back, so `leaf` must stay inlined: {edges:?}"
        );
    }

    #[test]
    fn the_dynamodb_shape_reaches_itself_through_either_arm_alone() {
        let both = file(vec![message(
            "AttributeValue",
            vec![
                field("l", IrType::List(Box::new(msg_ref("AttributeValue")))),
                field(
                    "m",
                    IrType::Map(
                        Box::new(IrType::Scalar(ScalarKind::String)),
                        Box::new(msg_ref("AttributeValue")),
                    ),
                ),
            ],
        )]);
        let edges = boxed_under(&both, ContainerInlining::ViaOptionalWrapper);
        assert!(is_boxed(&edges, "AttributeValue", "l"), "{edges:?}");
        assert!(is_boxed(&edges, "AttributeValue", "m"), "{edges:?}");

        // The `List` arm alone suffices for BOTH fields...
        let list_only = file(vec![message(
            "AttributeValue",
            vec![field("l", IrType::List(Box::new(msg_ref("AttributeValue"))))],
        )]);
        assert!(
            is_boxed(
                &boxed_under(&list_only, ContainerInlining::ViaOptionalWrapper),
                "AttributeValue",
                "l"
            ),
            "a `list<Self>` member is a self-loop on its own"
        );

        let map_only = file(vec![message(
            "AttributeValue",
            vec![field(
                "m",
                IrType::Map(
                    Box::new(IrType::Scalar(ScalarKind::String)),
                    Box::new(msg_ref("AttributeValue")),
                ),
            )],
        )]);
        assert!(
            is_boxed(
                &boxed_under(&map_only, ContainerInlining::ViaOptionalWrapper),
                "AttributeValue",
                "m"
            ),
            "a `map<_, Self>` member is a self-loop on its own"
        );
    }
}

#[cfg(test)]
mod omitted_fields {
    use super::*;

    fn scalar(name: &str) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Scalar(ScalarKind::String),
            label: Label::Single,
            proto_field_number: 1,
            json_name: name.to_string(),
            oneof_index: None,
        }
    }

    fn model() -> IrModel {
        let mut arm = scalar("arm");
        arm.oneof_index = Some(0);
        IrModel {
            files: vec![IrFile {
                proto_path: "t/fixture.proto".to_string(),
                proto_package: "t".to_string(),
                mojo_package: "t".to_string(),
                messages: vec![IrMessage {
                    name: "Config".to_string(),
                    mojo_name: "Config".to_string(),
                    fq_name: ".t.Config".to_string(),
                    is_map_entry: false,
                    fields: vec![scalar("name"), scalar("apis"), scalar("title"), arm],
                    oneofs: Vec::new(),
                }],
                enums: Vec::new(),
                services: Vec::new(),
                imports: Vec::new(),
            }],
        }
    }

    fn field_names(m: &IrModel) -> Vec<String> {
        m.files[0].messages[0].fields.iter().map(|f| f.name.clone()).collect()
    }

    #[test]
    fn a_named_field_leaves_its_message_and_the_rest_stay_in_order() {
        for name in ["t.Config.apis", ".t.Config.apis"] {
            let mut m = model();
            omit_fields(&mut m, &[name.to_string()]).unwrap();
            assert_eq!(field_names(&m), ["name", "title", "arm"], "{name}");
        }
    }

    #[test]
    fn an_unknown_message_or_field_is_refused() {
        let mut m = model();
        let err = omit_fields(&mut m, &["t.Other.apis".to_string()]).unwrap_err();
        assert!(err.contains("no message `.t.Other`"), "{err}");
        let err = omit_fields(&mut m, &["t.Config.nope".to_string()]).unwrap_err();
        assert!(err.contains("has no field `nope`"), "{err}");
        assert_eq!(field_names(&m), ["name", "apis", "title", "arm"]);
    }

    #[test]
    fn a_oneof_arm_or_a_repeated_name_is_refused() {
        let mut m = model();
        let err = omit_fields(&mut m, &["t.Config.arm".to_string()]).unwrap_err();
        assert!(err.contains("member of a oneof"), "{err}");
        let err = omit_fields(&mut m, &["t.Config.apis".to_string(), ".t.Config.apis".to_string()])
            .unwrap_err();
        assert!(err.contains("twice"), "{err}");
    }

    #[test]
    fn omit_fields_alone_is_not_everything() {
        let scope = Scope { omit_fields: vec!["t.Config.apis".to_string()], ..Default::default() };
        assert!(!scope.is_everything());
    }
}
