//! Decoding the `(komira.db.*)` custom options out of the raw descriptor
//! bytes (`prost-types` drops extensions on decode). The DbStorable and index
//! emitters read the resulting side-table.

use std::collections::BTreeMap;

use prost::Message;

// ===========================================================================
// The prost mirror — only the descriptor fields the options ride on.
//
// Field tags mirror `google/protobuf/descriptor.proto` for the structural
// fields (FileDescriptorProto.name=1 / .message_type=4; DescriptorProto
// .name=1 / .field=2 / .options=7 / .nested_type=3; FieldDescriptorProto
// .name=1 / .options=8), and `options.proto` for the extension fields.
// ===========================================================================

#[derive(Clone, PartialEq, Message)]
struct FileDescriptorSetMirror {
    #[prost(message, repeated, tag = "1")]
    file: Vec<FileDescriptorProtoMirror>,
}

#[derive(Clone, PartialEq, Message)]
struct FileDescriptorProtoMirror {
    #[prost(string, optional, tag = "1")]
    name: Option<String>,
    #[prost(string, optional, tag = "2")]
    package: Option<String>,
    #[prost(message, repeated, tag = "4")]
    message_type: Vec<DescriptorProtoMirror>,
}

#[derive(Clone, PartialEq, Message)]
struct DescriptorProtoMirror {
    #[prost(string, optional, tag = "1")]
    name: Option<String>,
    #[prost(message, repeated, tag = "2")]
    field: Vec<FieldDescriptorProtoMirror>,
    // Nested messages (tag 3) so nested DbStorable targets are reachable —
    // the lowerer flattens nested types, so the option table must too.
    #[prost(message, repeated, tag = "3")]
    nested_type: Vec<DescriptorProtoMirror>,
    #[prost(message, optional, tag = "7")]
    options: Option<MessageOptionsExt>,
}

#[derive(Clone, PartialEq, Message)]
struct FieldDescriptorProtoMirror {
    #[prost(string, optional, tag = "1")]
    name: Option<String>,
    #[prost(message, optional, tag = "8")]
    options: Option<FieldOptionsExt>,
}

/// The `(komira.db.*)` message-level extensions (see `options.proto`).
#[derive(Clone, PartialEq, Message)]
struct MessageOptionsExt {
    #[prost(string, optional, tag = "50001")]
    table: Option<String>,
    #[prost(string, optional, tag = "50002")]
    pk: Option<String>,
    #[prost(string, repeated, tag = "50003")]
    index: Vec<String>,
    #[prost(bool, optional, tag = "50004")]
    schema_only: Option<bool>,
    #[prost(string, repeated, tag = "50005")]
    unique_together: Vec<String>,
    #[prost(message, repeated, tag = "50006")]
    composite_index: Vec<DbCompositeIndexMirror>,
}

/// Prost mirror of `options.proto`'s `DbCompositeIndex` (its OWN fields start
/// at 1 — an ordinary message, not the 50006-numbered extension).
#[derive(Clone, PartialEq, Message)]
struct DbCompositeIndexMirror {
    #[prost(message, repeated, tag = "1")]
    fields: Vec<DbIndexFieldMirror>,
    #[prost(bool, optional, tag = "2")]
    unique: Option<bool>,
    #[prost(string, optional, tag = "3")]
    partial_where: Option<String>,
    // `DbQueryScope` enum: 0 = SCOPE_COLLECTION (default), 1 = COLLECTION_GROUP.
    #[prost(int32, optional, tag = "4")]
    scope: Option<i32>,
}

/// Prost mirror of `options.proto`'s `DbIndexField`.
#[derive(Clone, PartialEq, Message)]
struct DbIndexFieldMirror {
    #[prost(string, optional, tag = "1")]
    col: Option<String>,
    #[prost(bool, optional, tag = "2")]
    desc: Option<bool>,
}

/// The `(komira.db.*)` field-level extensions (see `options.proto`).
#[derive(Clone, PartialEq, Message)]
struct FieldOptionsExt {
    #[prost(string, optional, tag = "50101")]
    col_type: Option<String>,
    #[prost(string, optional, tag = "50102")]
    column: Option<String>,
    #[prost(string, optional, tag = "50103")]
    default: Option<String>,
    #[prost(string, optional, tag = "50104")]
    references: Option<String>,
    #[prost(bool, optional, tag = "50105")]
    unique: Option<bool>,
}

// ===========================================================================
// The public option model the emitter consumes.
// ===========================================================================

/// The `(komira.db.*)` options on one DbStorable message.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DbTableOptions {
    pub table: String,
    /// `(komira.db.pk)` — the primary-key column(s); default `"id"`.
    pub pk: String,
    /// `(komira.db.index)` — secondary index columns, in declaration order.
    pub indexes: Vec<String>,
    /// `(komira.db.schema_only)` — `true` marks this a DDL-only `DbSchema`
    /// target (per-backend `create_table_ddl_*` only; no DbStorable
    /// round-trip machinery). Default `false` (full DbStorable).
    pub schema_only: bool,
    /// `(komira.db.unique_together)` — a composite UNIQUE over these columns,
    /// in declaration order. Emits a trailing `UNIQUE (col_a, col_b)` table
    /// constraint on both backends. Empty when the table has no composite
    /// uniqueness.
    pub unique_together: Vec<String>,
    pub composite_indexes: Vec<DbCompositeIndex>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DbCompositeIndex {
    /// The ordered index fields (equality prefix first, range/order term last).
    pub fields: Vec<DbIndexField>,
    pub unique: bool,
    pub partial_where: Option<String>,
    /// The document-backend query scope (COLLECTION default vs
    /// COLLECTION_GROUP).
    pub scope: DbQueryScope,
}

/// One ordered field of a declared composite index.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DbIndexField {
    /// The column name as written in the proto option. May be a proto FIELD
    /// name that resolves to a different physical column via
    /// `(komira.db.column)`; `emit_index.rs` runs it through `column_name()`.
    pub col: String,
    /// `false` = ASCENDING (the Firestore-required explicit direction), `true`
    /// = DESCENDING.
    pub desc: bool,
}

/// The document-backend query scope for a composite index. Mirrors
/// `options.proto`'s `DbQueryScope` enum.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DbQueryScope {
    #[default]
    Collection,
    /// A collection-group (sub-collection) query.
    CollectionGroup,
}

impl DbQueryScope {
    /// Decode the proto `DbQueryScope` ordinal (0 = COLLECTION, 1 =
    /// COLLECTION_GROUP; any other / absent value defaults to COLLECTION).
    fn from_ordinal(v: Option<i32>) -> Self {
        match v {
            Some(1) => DbQueryScope::CollectionGroup,
            _ => DbQueryScope::Collection,
        }
    }
}

/// The `(komira.db.*)` options on one field.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DbFieldOptions {
    /// `(komira.db.col_type)` — explicit logical type (`"uuid"`,
    /// `"timestamptz"`); empty when inferred from the scalar kind.
    pub col_type: Option<String>,
    /// `(komira.db.column)` — physical column-name override.
    pub column: Option<String>,
    pub default: Option<String>,
    /// `(komira.db.references)` — FK target, e.g. `"jobs(id)"`. Appended as
    /// `REFERENCES <target>` on both backends. Absent for non-FK columns.
    pub references: Option<String>,
    /// `(komira.db.unique)` — `true` appends a column-level `UNIQUE` on both
    /// backends. Default `false`. A COMPOSITE unique is the message option
    /// `unique_together` instead.
    pub unique: bool,
}

/// The decoded DB-option side-table for one request.
///
/// Keyed by the fully-qualified proto name (`.komira.jobs.v1.Job`) for messages,
/// and `(message_fq, field_name)` for fields — the same keys the IR exposes
/// (`IrMessage.fq_name`, `IrField.name`), so the emitter joins the IR (types,
/// labels, numbers) against this overlay with no re-parse.
#[derive(Clone, Debug, Default)]
pub struct DbOptionTable {
    tables: BTreeMap<String, DbTableOptions>,
    fields: BTreeMap<(String, String), DbFieldOptions>,
}

impl DbOptionTable {
    /// Decode the `(komira.db.*)` options out of a `FileDescriptorSet`'s
    /// raw bytes (the `protoc --descriptor_set_out` output). Returns an
    /// empty table if the bytes carry no DB options at all.
    pub fn from_descriptor_set_bytes(bytes: &[u8]) -> Result<Self, String> {
        let fds = FileDescriptorSetMirror::decode(bytes)
            .map_err(|e| format!("db_options: decode FileDescriptorSet: {e}"))?;
        let mut table = DbOptionTable::default();
        for file in &fds.file {
            let pkg = file.package.as_deref().unwrap_or("");
            for msg in &file.message_type {
                table.collect_message(pkg, &[], msg);
            }
        }
        Ok(table)
    }

    /// Test-support: insert a table's options directly, keyed by fq-name.
    /// Used by the `emit_index` unit tests to build an option overlay in-memory
    /// without a protoc round-trip.
    #[cfg(test)]
    pub(crate) fn insert_table_for_test(&mut self, fq_name: &str, opts: DbTableOptions) {
        self.tables.insert(fq_name.to_string(), opts);
    }

    /// Test-support: insert a field's options directly.
    #[cfg(test)]
    pub(crate) fn insert_field_for_test(
        &mut self,
        msg_fq: &str,
        field_name: &str,
        opts: DbFieldOptions,
    ) {
        self.fields
            .insert((msg_fq.to_string(), field_name.to_string()), opts);
    }

    /// Collect one message + its nested messages (flattened, matching the
    /// lowerer's flattening), keying by fully-qualified name.
    fn collect_message(&mut self, pkg: &str, outer: &[String], msg: &DescriptorProtoMirror) {
        let mut path = outer.to_vec();
        path.push(msg.name.clone().unwrap_or_default());
        let fq = fq_name(pkg, &path);

        if let Some(opts) = &msg.options {
            if let Some(t) = &opts.table {
                self.tables.insert(
                    fq.clone(),
                    DbTableOptions {
                        table: t.clone(),
                        pk: opts.pk.clone().unwrap_or_else(|| "id".to_string()),
                        indexes: opts.index.clone(),
                        schema_only: opts.schema_only.unwrap_or(false),
                        unique_together: opts.unique_together.clone(),
                        composite_indexes: opts
                            .composite_index
                            .iter()
                            .map(|ci| DbCompositeIndex {
                                fields: ci
                                    .fields
                                    .iter()
                                    .map(|f| DbIndexField {
                                        col: f.col.clone().unwrap_or_default(),
                                        desc: f.desc.unwrap_or(false),
                                    })
                                    .collect(),
                                unique: ci.unique.unwrap_or(false),
                                partial_where: ci.partial_where.clone(),
                                scope: DbQueryScope::from_ordinal(ci.scope),
                            })
                            .collect(),
                    },
                );
            }
        }

        for field in &msg.field {
            let Some(name) = &field.name else { continue };
            if let Some(fo) = &field.options {
                let has_any = fo.col_type.is_some()
                    || fo.column.is_some()
                    || fo.default.is_some()
                    || fo.references.is_some()
                    || fo.unique.is_some();
                if has_any {
                    self.fields.insert(
                        (fq.clone(), name.clone()),
                        DbFieldOptions {
                            col_type: fo.col_type.clone(),
                            column: fo.column.clone(),
                            default: fo.default.clone(),
                            references: fo.references.clone(),
                            unique: fo.unique.unwrap_or(false),
                        },
                    );
                }
            }
        }

        for nested in &msg.nested_type {
            self.collect_message(pkg, &path, nested);
        }
    }

    /// The table options for a message fq-name — `Some` iff the message
    /// carries `(komira.db.table)` (i.e. is a DbStorable target).
    pub fn table_for(&self, fq_name: &str) -> Option<&DbTableOptions> {
        self.tables.get(fq_name)
    }

    /// The field options for `(message_fq, field_name)`. Returns a defaulted
    /// (all-`None`) value when the field carries no DB options, so callers
    /// never branch on presence for the common no-option field.
    pub fn field_for(&self, msg_fq: &str, field_name: &str) -> DbFieldOptions {
        self.fields
            .get(&(msg_fq.to_string(), field_name.to_string()))
            .cloned()
            .unwrap_or_default()
    }
}

/// `.pkg.Outer.Inner` — the protoc fully-qualified-name shape the IR uses.
/// Mirrors `lower.rs::fq_name` (kept local so this module is standalone).
fn fq_name(pkg: &str, path: &[String]) -> String {
    let mut s = String::from(".");
    if !pkg.is_empty() {
        s.push_str(pkg);
        s.push('.');
    }
    s.push_str(&path.join("."));
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fq_name_shape() {
        assert_eq!(fq_name("komira.jobs.v1", &["Job".into()]), ".komira.jobs.v1.Job");
        assert_eq!(
            fq_name("komira.jobs.v1", &["Job".into(), "Inner".into()]),
            ".komira.jobs.v1.Job.Inner"
        );
        assert_eq!(fq_name("", &["Top".into()]), ".Top");
    }

    #[test]
    fn empty_bytes_is_empty_table() {
        let t = DbOptionTable::from_descriptor_set_bytes(&[]).unwrap();
        assert!(t.table_for(".komira.jobs.v1.Job").is_none());
        assert_eq!(
            t.field_for(".komira.jobs.v1.Job", "id"),
            DbFieldOptions::default()
        );
    }

    /// Build FDS bytes for a single table message carrying `msg_opts`, by
    /// encoding through the SAME prost mirror the decode uses (the mirror
    /// derives both `encode`+`decode`). This is the faithful stand-in for what
    /// `protoc --descriptor_set_out` would write for an annotated `.proto`.
    fn fds_with_message_options(pkg: &str, msg_name: &str, msg_opts: MessageOptionsExt) -> Vec<u8> {
        let fds = FileDescriptorSetMirror {
            file: vec![FileDescriptorProtoMirror {
                name: Some("test.proto".to_string()),
                package: Some(pkg.to_string()),
                message_type: vec![DescriptorProtoMirror {
                    name: Some(msg_name.to_string()),
                    field: vec![],
                    nested_type: vec![],
                    options: Some(msg_opts),
                }],
            }],
        };
        fds.encode_to_vec()
    }

    #[test]
    fn mirror_roundtrip_composite_index_preserves_every_subfield() {
        let opts = MessageOptionsExt {
            table: Some("jobs".to_string()),
            pk: Some("id".to_string()),
            index: vec![],
            schema_only: None,
            unique_together: vec![],
            composite_index: vec![
                // A 2-field index with a DESC trailing field — the exact case
                // where a mistagged `desc` would silently become ASC.
                DbCompositeIndexMirror {
                    fields: vec![
                        DbIndexFieldMirror {
                            col: Some("phase".to_string()),
                            desc: Some(false),
                        },
                        DbIndexFieldMirror {
                            col: Some("created_at".to_string()),
                            desc: Some(true),
                        },
                    ],
                    unique: Some(true),
                    partial_where: Some("phase = 'RUNNING'".to_string()),
                    scope: Some(1), // COLLECTION_GROUP
                },
            ],
        };
        let bytes = fds_with_message_options("komira.jobs.v1", "Job", opts);

        let table = DbOptionTable::from_descriptor_set_bytes(&bytes).unwrap();
        let job = table
            .table_for(".komira.jobs.v1.Job")
            .expect("Job table option recovered");

        assert_eq!(job.table, "jobs");
        assert_eq!(job.composite_indexes.len(), 1, "one composite index");
        let ci = &job.composite_indexes[0];

        // Every field of DbCompositeIndex survives.
        assert!(ci.unique, "unique:true survived the mirror");
        assert_eq!(
            ci.partial_where.as_deref(),
            Some("phase = 'RUNNING'"),
            "partial_where survived"
        );
        assert_eq!(
            ci.scope,
            DbQueryScope::CollectionGroup,
            "scope COLLECTION_GROUP survived (ordinal 1)"
        );

        // Every field of every DbIndexField survives, IN ORDER — especially the
        // load-bearing `desc` flag.
        assert_eq!(ci.fields.len(), 2, "both index fields survived");
        assert_eq!(ci.fields[0].col, "phase");
        assert!(!ci.fields[0].desc, "field 0 is ASCENDING");
        assert_eq!(ci.fields[1].col, "created_at");
        assert!(
            ci.fields[1].desc,
            "field 1 is DESCENDING — the mistagged-desc regression this golden guards"
        );
    }

    #[test]
    fn mirror_roundtrip_absent_composite_index_is_empty() {
        let opts = MessageOptionsExt {
            table: Some("jobs".to_string()),
            pk: None,
            index: vec!["phase".to_string()],
            schema_only: None,
            unique_together: vec![],
            composite_index: vec![],
        };
        let bytes = fds_with_message_options("komira.jobs.v1", "Job", opts);
        let table = DbOptionTable::from_descriptor_set_bytes(&bytes).unwrap();
        let job = table.table_for(".komira.jobs.v1.Job").unwrap();
        assert!(
            job.composite_indexes.is_empty(),
            "no composite_index option -> empty vec"
        );
        assert_eq!(job.indexes, vec!["phase".to_string()]);
    }
}
