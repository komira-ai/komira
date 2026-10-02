//! The composite-index emitter: the `(komira.db.composite_index)` options,
//! resolved against the emitted columns, rendered as a Terraform file and a
//! per-file textproto manifest.

use crate::db_options::{DbCompositeIndex, DbOptionTable, DbQueryScope};
use crate::emit_dbstorable::{DbEmitter, IndexColumnKind};
use crate::ir::{IrFile, IrMessage, IrModel};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedIndex {
    pub name: String,
    /// The physical DB table (from `(komira.db.table)`).
    pub table: String,
    /// The ordered `(physical_col, desc)` fields.
    pub fields: Vec<(String, bool)>,
    pub unique: bool,
    pub partial_where: Option<String>,
    /// The document-backend query scope.
    pub scope: DbQueryScope,
    /// The `# derives:` provenance line (the proto comment) if present, for the
    /// manifest + the generated `.tf` header. Empty when absent.
    pub derives: String,
    pub has_enum_text: bool,
}

/// The whole generated index artifact set for a model.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IndexEmit {
    /// One `(table, [ResolvedIndex...])` per table declaring composite indexes,
    /// in declaration order.
    pub tables: Vec<TableIndexes>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TableIndexes {
    pub table: String,
    pub indexes: Vec<ResolvedIndex>,
}

/// `true` if any table message in the model declares a `(komira.db.composite_index)`.
pub fn model_has_composite_index(model: &IrModel, opts: &DbOptionTable) -> bool {
    model.files.iter().any(|file| {
        file.messages.iter().any(|m| {
            !m.is_map_entry
                && opts
                    .table_for(&m.fq_name)
                    .is_some_and(|t| !t.composite_indexes.is_empty())
        })
    })
}

pub fn resolve_index_emit(model: &IrModel, opts: &DbOptionTable) -> Result<IndexEmit, String> {
    let mut tables: Vec<TableIndexes> = Vec::new();
    for file in &model.files {
        // One resolver per file — DbEmitter borrows this file + opts and does the
        // db_fields()/column_name()/resolve_logical() column resolution.
        let resolver = DbEmitter::new(file, opts);
        for msg in &file.messages {
            if msg.is_map_entry {
                continue;
            }
            let Some(table_opts) = opts.table_for(&msg.fq_name) else {
                continue;
            };
            if table_opts.composite_indexes.is_empty() {
                continue;
            }
            let mut indexes: Vec<ResolvedIndex> = Vec::new();
            for ci in &table_opts.composite_indexes {
                indexes.push(resolve_one_index(&resolver, msg, &table_opts.table, ci)?);
            }
            tables.push(TableIndexes {
                table: table_opts.table.clone(),
                indexes,
            });
        }
    }
    Ok(IndexEmit { tables })
}

/// Resolve one declared `DbCompositeIndex` on `msg` → a `ResolvedIndex`, or a
/// HARD codegen error.
fn resolve_one_index(
    resolver: &DbEmitter,
    msg: &IrMessage,
    table: &str,
    ci: &DbCompositeIndex,
) -> Result<ResolvedIndex, String> {
    if ci.fields.is_empty() {
        return Err(format!(
            "composite_index on table `{table}` has no fields — an index must \
             name at least one column",
        ));
    }
    let mut fields: Vec<(String, bool)> = Vec::new();
    let mut has_enum_text = false;
    for f in &ci.fields {
        let res = resolver.resolve_index_column(msg, &f.col);
        match res.kind {
            IndexColumnKind::Indexable => {}
            IndexColumnKind::Jsonb => {
                return Err(format!(
                    "composite_index on table `{table}` references column `{}` \
                     which resolves to a JSONB column — JSONB columns are NOT \
                     composite-indexable (§3.3). Promote the field to a top-level \
                     column, or use a hand pg expression/partial index.",
                    f.col
                ));
            }
            IndexColumnKind::TextArray => {
                return Err(format!(
                    "composite_index on table `{table}` references column `{}` \
                     which resolves to a repeated-scalar (TEXT[]) column — array \
                     membership is a per-backend automatic/client-side concern, \
                     not a portable composite (§3.3/§5.4). Remove it from the index.",
                    f.col
                ));
            }
            IndexColumnKind::Unknown => {
                return Err(format!(
                    "composite_index on table `{table}` references column `{}` \
                     which is NOT an emitted column (a oneof member, a \
                     removed/renamed field, or a typo) — an index over it would be \
                     a phantom (§3.3 D3-guard). Fix the column name.",
                    f.col
                ));
            }
        }
        if res.is_enum_text {
            has_enum_text = true;
        }
        fields.push((res.physical, f.desc));
    }


    let name = deterministic_index_name(table, &fields);
    Ok(ResolvedIndex {
        name,
        table: table.to_string(),
        fields,
        unique: ci.unique,
        partial_where: ci.partial_where.clone(),
        scope: ci.scope,
        derives: String::new(),
        has_enum_text,
    })
}

pub fn deterministic_index_name(table: &str, fields: &[(String, bool)]) -> String {
    let mut s = format!("ix_{table}");
    for (col, desc) in fields {
        s.push('_');
        s.push_str(col);
        if *desc {
            s.push_str("_desc");
        }
    }
    s
}

// ===========================================================================
// Firestore-target validation + rendering of the one deterministic output file.
// ===========================================================================

pub fn validate_firestore_expressible(emit: &IndexEmit) -> Result<(), String> {
    for t in &emit.tables {
        for ix in &t.indexes {
            if ix.unique {
                return Err(format!(
                    "composite_index `{}` on table `{}` is UNIQUE, which Firestore \
                     cannot express — a unique composite is a Firestore deploy error \
                     (§5.2). Drop `unique` or target pg/Dynamo only.",
                    ix.name, t.table
                ));
            }
            if ix.partial_where.is_some() {
                return Err(format!(
                    "composite_index `{}` on table `{}` has a partial_where, which is \
                     pg-only — Firestore cannot express a partial index (§5.2).",
                    ix.name, t.table
                ));
            }
        }
    }
    Ok(())
}

pub fn render_manifest_textproto(emit: &IndexEmit) -> String {
    let mut out = String::new();
    out.push_str("# GENERATED by protoc-gen-mojo (composite-index target) — do not hand-edit.\n");
    out.push_str("# The backend-neutral DatastoreIndexManifest (service_contract_rfc.md §4.2).\n");
    out.push_str(
        "# The applier's ensure-indexes step (Phase 3) reads this to CreateIndex per backend.\n",
    );
    for t in &emit.tables {
        for ix in &t.indexes {
            out.push_str("tables {\n");
            out.push_str(&format!("  table: {:?}\n", t.table));
            out.push_str("  indexes {\n");
            out.push_str(&format!("    name: {:?}\n", ix.name));
            for (col, desc) in &ix.fields {
                out.push_str("    fields {\n");
                out.push_str(&format!("      col: {col:?}\n"));
                out.push_str(&format!("      desc: {desc}\n"));
                out.push_str("    }\n");
            }
            if ix.unique {
                out.push_str("    unique: true\n");
            }
            if let Some(pw) = &ix.partial_where {
                out.push_str(&format!("    partial_where: {pw:?}\n"));
            }
            match ix.scope {
                DbQueryScope::Collection => {
                    out.push_str("    scope: SCOPE_COLLECTION\n");
                }
                DbQueryScope::CollectionGroup => {
                    out.push_str("    scope: SCOPE_COLLECTION_GROUP\n");
                }
            }
            out.push_str("  }\n");
            out.push_str("}\n");
        }
    }
    out
}

/// The manifest textproto output name for a given proto file: `<stem>_index_manifest.textproto`.
pub fn manifest_output_name(proto_path: &str) -> String {
    let basename = proto_path.rsplit('/').next().unwrap_or(proto_path);
    let stem = basename.rsplit_once('.').map(|(s, _)| s).unwrap_or(basename);
    format!("{stem}_index_manifest.textproto")
}

pub fn emit_index_model(
    model: &IrModel,
    opts: &DbOptionTable,
) -> Result<Vec<(String, String)>, String> {
    if !model_has_composite_index(model, opts) {
        return Ok(Vec::new());
    }

    let all = resolve_index_emit(model, opts)?;
    validate_firestore_expressible(&all)?;

    let mut out: Vec<(String, String)> = Vec::new();

    // Per-file manifest textprotos (declaration order).
    for file in &model.files {
        let file_emit = resolve_file_indexes(file, opts)?;
        if file_emit.tables.is_empty() {
            continue;
        }
        out.push((
            manifest_output_name(&file.proto_path),
            render_manifest_textproto(&file_emit),
        ));
    }

    Ok(out)
}

/// Resolve just one file's declared indexes (for the per-file manifest).
fn resolve_file_indexes(file: &IrFile, opts: &DbOptionTable) -> Result<IndexEmit, String> {
    let resolver = DbEmitter::new(file, opts);
    let mut tables: Vec<TableIndexes> = Vec::new();
    for msg in &file.messages {
        if msg.is_map_entry {
            continue;
        }
        let Some(table_opts) = opts.table_for(&msg.fq_name) else {
            continue;
        };
        if table_opts.composite_indexes.is_empty() {
            continue;
        }
        let mut indexes: Vec<ResolvedIndex> = Vec::new();
        for ci in &table_opts.composite_indexes {
            indexes.push(resolve_one_index(&resolver, msg, &table_opts.table, ci)?);
        }
        tables.push(TableIndexes {
            table: table_opts.table.clone(),
            indexes,
        });
    }
    Ok(IndexEmit { tables })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db_options::{
        DbCompositeIndex, DbFieldOptions, DbIndexField, DbTableOptions,
    };
    use crate::ir::{IrField, IrType, Label, ScalarKind};

    // ---- IR builders (a minimal in-memory model, no protoc) ---------------

    fn scalar_field(name: &str, num: u32, sk: ScalarKind, label: Label) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Scalar(sk),
            label,
            proto_field_number: num,
            json_name: name.to_string(),
            oneof_index: None,
        }
    }

    fn enum_field(name: &str, num: u32) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Enum(crate::ir::TypeRef {
                fq_name: ".komira.jobs.v1.Phase".to_string(),
                mojo_name: "Phase".to_string(),
            }),
            label: Label::Single,
            proto_field_number: num,
            json_name: name.to_string(),
            oneof_index: None,
        }
    }

    fn map_field(name: &str, num: u32) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Map(
                Box::new(IrType::Scalar(ScalarKind::String)),
                Box::new(IrType::Scalar(ScalarKind::String)),
            ),
            label: Label::Repeated,
            proto_field_number: num,
            json_name: name.to_string(),
            oneof_index: None,
        }
    }

    fn oneof_field(name: &str, num: u32) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Scalar(ScalarKind::String),
            label: Label::Single,
            proto_field_number: num,
            json_name: name.to_string(),
            oneof_index: Some(0),
        }
    }

    /// A `jobs`-shaped table message with the columns the tests reference.
    fn jobs_message() -> IrMessage {
        IrMessage {
            name: "Job".to_string(),
            mojo_name: "Job".to_string(),
            fq_name: ".komira.jobs.v1.Job".to_string(),
            is_map_entry: false,
            fields: vec![
                scalar_field("id", 1, ScalarKind::Bytes, Label::Single),
                enum_field("phase", 7),
                scalar_field("created_at", 15, ScalarKind::Int64, Label::Single),
                scalar_field("updated_at", 16, ScalarKind::Int64, Label::Single),
                scalar_field("last_heartbeat_at", 13, ScalarKind::Int64, Label::Optional),
                scalar_field("owner_id", 21, ScalarKind::Bytes, Label::Single),
                // repeated scalar -> TEXT[] (Logical::TextArray)
                scalar_field("labels", 17, ScalarKind::String, Label::Repeated),
                // map -> JSONB
                map_field("config", 4),
                // a oneof member -> NOT a column (filtered from db_fields)
                oneof_field("served_endpoint", 20),
            ],
            oneofs: vec![],
        }
    }

    fn file_with(messages: Vec<IrMessage>) -> IrFile {
        IrFile {
            proto_path: "example/v1/jobs.proto".to_string(),
            proto_package: "komira.jobs.v1".to_string(),
            mojo_package: "komira_rpc_storage".to_string(),
            messages,
            enums: vec![],
            services: vec![],
            imports: vec![],
        }
    }

    fn model_with(file: IrFile) -> IrModel {
        IrModel { files: vec![file] }
    }

    fn idx(cols: &[(&str, bool)]) -> DbCompositeIndex {
        DbCompositeIndex {
            fields: cols
                .iter()
                .map(|(c, d)| DbIndexField {
                    col: c.to_string(),
                    desc: *d,
                })
                .collect(),
            unique: false,
            partial_where: None,
            scope: DbQueryScope::Collection,
        }
    }

    /// Build a `DbOptionTable` with the `jobs` table + the given composite
    /// indexes, plus any field-column overrides.
    fn opts_with(indexes: Vec<DbCompositeIndex>) -> DbOptionTable {
        let mut opts = DbOptionTable::default();
        opts.insert_table_for_test(
            ".komira.jobs.v1.Job",
            DbTableOptions {
                table: "jobs".to_string(),
                pk: "id".to_string(),
                indexes: vec![],
                schema_only: false,
                unique_together: vec![],
                composite_indexes: indexes,
            },
        );
        opts
    }

    // ---- name determinism -------------------------------------------------

    #[test]
    fn deterministic_name_shape() {
        assert_eq!(
            deterministic_index_name("jobs", &[("phase".into(), false), ("created_at".into(), false)]),
            "ix_jobs_phase_created_at"
        );
        // A DESC field appends `_desc` so an ASC vs DESC variant over the SAME
        // columns gets a DISTINCT name (no HCL resource-name collision).
        assert_eq!(
            deterministic_index_name("jobs", &[("phase".into(), false), ("created_at".into(), true)]),
            "ix_jobs_phase_created_at_desc"
        );
    }

    #[test]
    fn asc_and_desc_over_same_columns_do_not_collide() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![
            idx(&[("phase", false), ("created_at", false)]),
            idx(&[("phase", false), ("created_at", true)]),
        ]);
        let emit = resolve_index_emit(&model, &opts).expect("resolve");
        let m = render_manifest_textproto(&emit);
        assert!(m.contains("name: \"ix_jobs_phase_created_at\""), "asc index:\n{m}");
        assert!(m.contains("name: \"ix_jobs_phase_created_at_desc\""), "desc index:\n{m}");
        // Each name appears exactly once (`..._desc` does not match `..._at"`).
        assert_eq!(
            m.matches("name: \"ix_jobs_phase_created_at\"").count(),
            1,
            "the ASC index name must be unique:\n{m}"
        );
    }

    // ---- happy path: the manifest carries the resolved physical shape -----

    #[test]
    fn emits_manifest_entry_with_physical_columns_in_order() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![idx(&[("phase", false), ("created_at", false)])]);
        let emit = resolve_index_emit(&model, &opts).expect("resolve");
        let m = render_manifest_textproto(&emit);

        assert!(m.contains("table: \"jobs\""), "table:\n{m}");
        assert!(m.contains("name: \"ix_jobs_phase_created_at\""), "name:\n{m}");
        assert!(m.contains("col: \"phase\""), "phase col:\n{m}");
        assert!(m.contains("col: \"created_at\""), "created_at col:\n{m}");
        assert!(m.contains("desc: false"), "ascending:\n{m}");
        assert!(m.contains("scope: SCOPE_COLLECTION"), "scope:\n{m}");
        // Column ORDER is load-bearing for a composite index.
        let phase_at = m.find("col: \"phase\"").expect("phase");
        let created_at = m.find("col: \"created_at\"").expect("created_at");
        assert!(phase_at < created_at, "prefix column must come first:\n{m}");
    }

    #[test]
    fn desc_field_renders_descending() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![idx(&[("phase", false), ("created_at", true)])]);
        let emit = resolve_index_emit(&model, &opts).expect("resolve");
        let m = render_manifest_textproto(&emit);
        assert!(m.contains("name: \"ix_jobs_phase_created_at_desc\""), "name:\n{m}");
        assert!(m.contains("desc: true"), "descending flag:\n{m}");
    }

    // ---- the manifest -----------------------------------------------------

    #[test]
    fn manifest_textproto_carries_resolved_index() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![idx(&[("phase", false), ("updated_at", false)])]);
        let emit = resolve_index_emit(&model, &opts).expect("resolve");
        let m = render_manifest_textproto(&emit);
        assert!(m.contains("table: \"jobs\""));
        assert!(m.contains("name: \"ix_jobs_phase_updated_at\""));
        assert!(m.contains("col: \"phase\""));
        assert!(m.contains("col: \"updated_at\""));
        assert!(m.contains("scope: SCOPE_COLLECTION"));
    }


    #[test]
    fn jsonb_column_is_a_hard_error() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![idx(&[("config", false), ("created_at", false)])]);
        let err = resolve_index_emit(&model, &opts).unwrap_err();
        assert!(err.contains("JSONB"), "expected JSONB error, got: {err}");
    }

    #[test]
    fn textarray_column_is_a_hard_error() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![idx(&[("labels", false)])]);
        let err = resolve_index_emit(&model, &opts).unwrap_err();
        assert!(err.contains("TEXT[]"), "expected TEXT[] error, got: {err}");
    }

    #[test]
    fn oneof_member_is_a_hard_error() {
        let model = model_with(file_with(vec![jobs_message()]));
        // served_endpoint is a oneof member -> filtered from db_fields -> unknown.
        let opts = opts_with(vec![idx(&[("phase", false), ("served_endpoint", false)])]);
        let err = resolve_index_emit(&model, &opts).unwrap_err();
        assert!(err.contains("NOT an emitted column"), "expected unknown-column error, got: {err}");
    }

    #[test]
    fn unknown_column_is_a_hard_error() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![idx(&[("phase", false), ("nonexistent", false)])]);
        let err = resolve_index_emit(&model, &opts).unwrap_err();
        assert!(err.contains("NOT an emitted column"), "got: {err}");
    }


    #[test]
    fn column_override_resolves_physical_name() {
        let model = model_with(file_with(vec![jobs_message()]));
        let mut opts = opts_with(vec![idx(&[("phase", false), ("created_at", false)])]);
        opts.insert_field_for_test(
            ".komira.jobs.v1.Job",
            "phase",
            DbFieldOptions {
                col_type: None,
                column: Some("phase_str".to_string()),
                default: None,
                references: None,
                unique: false,
            },
        );
        let emit = resolve_index_emit(&model, &opts).expect("resolve");
        let m = render_manifest_textproto(&emit);
        assert!(m.contains("name: \"ix_jobs_phase_str_created_at\""), "physical name in index name:\n{m}");
        assert!(m.contains("col: \"phase_str\""), "physical name in col:\n{m}");
        assert!(!m.contains("col: \"phase\""), "the proto field name must NOT leak:\n{m}");
    }


    #[test]
    fn unique_composite_is_a_firestore_deploy_error() {
        let model = model_with(file_with(vec![jobs_message()]));
        let mut ci = idx(&[("phase", false), ("created_at", false)]);
        ci.unique = true;
        let opts = opts_with(vec![ci]);
        let emit = resolve_index_emit(&model, &opts).expect("resolve ok (unique is fine to resolve)");
        let err = validate_firestore_expressible(&emit).unwrap_err();
        assert!(err.contains("UNIQUE"), "expected unique deploy error, got: {err}");
        // And it must fail the WHOLE emit, not just the validator in isolation —
        // this is what stops a Firestore-impossible index reaching a manifest.
        let emit_err = emit_index_model(&model, &opts).unwrap_err();
        assert!(emit_err.contains("UNIQUE"), "emit_index_model must reject it: {emit_err}");
    }

    #[test]
    fn partial_where_is_a_firestore_deploy_error() {
        let model = model_with(file_with(vec![jobs_message()]));
        let mut ci = idx(&[("phase", false), ("created_at", false)]);
        ci.partial_where = Some("phase = 'RUNNING'".to_string());
        let opts = opts_with(vec![ci]);
        let emit = resolve_index_emit(&model, &opts).expect("resolve");
        let err = validate_firestore_expressible(&emit).unwrap_err();
        assert!(err.contains("partial_where"), "expected partial deploy error, got: {err}");
        let emit_err = emit_index_model(&model, &opts).unwrap_err();
        assert!(emit_err.contains("partial_where"), "emit_index_model must reject it: {emit_err}");
    }

    // ---- determinism ------------------------------------------------------

    #[test]
    fn emission_is_deterministic() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![
            idx(&[("phase", false), ("updated_at", false)]),
            idx(&[("phase", false), ("last_heartbeat_at", false)]),
        ]);
        let a = emit_index_model(&model, &opts).expect("emit a");
        let b = emit_index_model(&model, &opts).expect("emit b");
        assert_eq!(a, b, "index emission is not deterministic");
    }

    #[test]
    fn empty_when_no_composite_index_declared() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![]);
        let out = emit_index_model(&model, &opts).expect("emit");
        assert!(out.is_empty(), "no composite_index -> no output file");
    }


    fn fixed_main_tf_tuples() -> Vec<(String, Vec<(String, bool)>)> {
        vec![
            ("jobs".into(), vec![("phase".into(), false), ("created_at".into(), false)]),
            ("jobs".into(), vec![("phase".into(), false), ("updated_at".into(), false)]),
            ("jobs".into(), vec![("phase".into(), false), ("last_heartbeat_at".into(), false)]),
            ("jobs".into(), vec![("owner_id".into(), false), ("phase".into(), false), ("created_at".into(), false)]),
        ]
    }

    #[test]
    fn generated_set_is_superset_of_fixed_main_tf_for_jobs() {
        let model = model_with(file_with(vec![jobs_message()]));
        let opts = opts_with(vec![
            idx(&[("phase", false), ("created_at", false)]),
            idx(&[("phase", false), ("updated_at", false)]),
            idx(&[("phase", false), ("last_heartbeat_at", false)]),
            idx(&[("owner_id", false), ("phase", false), ("created_at", false)]),
            idx(&[("phase", false), ("created_at", true)]),
            idx(&[("owner_id", false), ("created_at", true)]),
        ]);
        let emit = resolve_index_emit(&model, &opts).expect("resolve");

        // Build the generated tuple set.
        let mut gen_set: Vec<(String, Vec<(String, bool)>)> = Vec::new();
        for t in &emit.tables {
            for ix in &t.indexes {
                gen_set.push((t.table.clone(), ix.fields.clone()));
            }
        }

        for want in fixed_main_tf_tuples() {
            let present = gen_set.iter().any(|got| *got == want);
            assert!(
                present,
                "generated index set is MISSING the fixed-main.tf tuple {want:?}\n\
                 generated set: {gen_set:?}",
            );
        }
    }
}
