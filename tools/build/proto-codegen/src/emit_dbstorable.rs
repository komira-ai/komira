//! The DbStorable emitter: for each message carrying `(komira.db.table)`, a
//! `<stem>_db.mojo` with the row mapping and the per-backend DDL.

use crate::db_options::{DbFieldOptions, DbOptionTable};
use crate::ir::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Backend {
    Pg,
    Sqlite,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Logical {
    Uuid,
    Text,
    Int4,
    Int8,
    Float8,
    Float4,
    Bool,
    Bytes,
    Timestamptz,
    Jsonb,
    TextArray,
    Serial,
    BigSerial,
}

impl Logical {
    /// The Mojo *element* type (before the `Optional[..]` nullable wrap).
    fn mojo_type(self, json_mojo: &str) -> String {
        match self {
            Logical::Uuid => "Uuid".to_string(),
            Logical::Text => "String".to_string(),
            Logical::Int4 => "Int32".to_string(),
            Logical::Int8 => "Int64".to_string(),
            Logical::Float8 => "Float64".to_string(),
            Logical::Float4 => "Float32".to_string(),
            Logical::Bool => "Bool".to_string(),
            Logical::Bytes => "List[UInt8]".to_string(),
            Logical::Timestamptz => "Timestamptz".to_string(),
            // The nested struct's own Mojo type (a map → Dict, a repeated
            // message → List[M], a singular message → the nested struct).
            Logical::Jsonb => json_mojo.to_string(),
            Logical::TextArray => json_mojo.to_string(),
            Logical::Serial => "Int32".to_string(),
            Logical::BigSerial => "Int64".to_string(),
        }
    }

    fn pg_ddl(self) -> &'static str {
        match self {
            Logical::Uuid => "UUID",
            Logical::Text => "TEXT",
            Logical::Int4 => "INTEGER",
            Logical::Int8 => "BIGINT",
            Logical::Float8 => "DOUBLE PRECISION",
            Logical::Float4 => "REAL",
            Logical::Bool => "BOOLEAN",
            Logical::Bytes => "BYTEA",
            Logical::Timestamptz => "TIMESTAMPTZ",
            Logical::Jsonb => "JSONB",
            Logical::TextArray => "TEXT[]",
            Logical::Serial => "SERIAL",
            Logical::BigSerial => "BIGSERIAL",
        }
    }

    fn sqlite_ddl(self) -> &'static str {
        match self {
            Logical::Uuid => "BLOB",
            Logical::Text => "TEXT",
            Logical::Int4 => "INTEGER",
            Logical::Int8 => "INTEGER",
            Logical::Float8 => "REAL",
            Logical::Float4 => "REAL",
            Logical::Bool => "INTEGER",
            Logical::Bytes => "BLOB",
            Logical::Timestamptz => "INTEGER",
            Logical::Jsonb => "TEXT",
            Logical::TextArray => "TEXT",
            Logical::Serial => "INTEGER",
            Logical::BigSerial => "INTEGER",
        }
    }

    fn is_serial(self) -> bool {
        matches!(self, Logical::Serial | Logical::BigSerial)
    }

    fn logical_token(self) -> &'static str {
        match self {
            Logical::Uuid => "LOGICAL_UUID",
            Logical::Text => "LOGICAL_TEXT",
            Logical::Int4 => "LOGICAL_INT4",
            Logical::Int8 => "LOGICAL_INT8",
            Logical::Float8 => "LOGICAL_FLOAT8",
            Logical::Float4 => "LOGICAL_FLOAT4",
            Logical::Bool => "LOGICAL_BOOL",
            Logical::Bytes => "LOGICAL_BYTES",
            Logical::Timestamptz => "LOGICAL_TIMESTAMPTZ",
            Logical::Jsonb => "LOGICAL_JSONB",
            Logical::TextArray => "LOGICAL_TEXT_ARRAY",
            Logical::Serial => "LOGICAL_INT4",
            Logical::BigSerial => "LOGICAL_INT8",
        }
    }

    fn dbvalue_ctor(self) -> &'static str {
        match self {
            Logical::Uuid => "uuid",
            Logical::Text => "text",
            Logical::Int4 => "int4",
            Logical::Int8 => "int8",
            Logical::Float8 => "float8",
            Logical::Float4 => "float4",
            Logical::Bool => "bool_val",
            Logical::Bytes => "bytes",
            Logical::Timestamptz => "timestamptz",
            Logical::Jsonb => "jsonb",
            Logical::TextArray => "text_array",
            Logical::Serial => "int4",
            Logical::BigSerial => "int8",
        }
    }

    /// The `DbRow` getter (`row.get_<getter>(col)`) for `from_row`. The
    /// nullable form is `get_opt_<getter>` (handled at the call site).
    fn dbrow_getter(self) -> &'static str {
        match self {
            Logical::Uuid => "uuid",
            Logical::Text => "text",
            Logical::Int4 => "int4",
            Logical::Int8 => "int8",
            Logical::Float8 => "float8",
            Logical::Float4 => "float4",
            Logical::Bool => "bool",
            Logical::Bytes => "bytes",
            Logical::Timestamptz => "timestamptz",
            Logical::Jsonb => "jsonb",
            Logical::TextArray => "text_array",
            Logical::Serial => "int4",
            Logical::BigSerial => "int8",
        }
    }
}

/// The `DbStorable` emitter — one per generated `*_db.mojo` file.
pub struct DbEmitter<'a> {
    file: &'a IrFile,
    opts: &'a DbOptionTable,
    buf: String,
    indent: usize,
}

impl<'a> DbEmitter<'a> {
    pub fn new(file: &'a IrFile, opts: &'a DbOptionTable) -> Self {
        Self {
            file,
            opts,
            buf: String::new(),
            indent: 0,
        }
    }

    /// `true` if this file has at least one `(komira.db.table)` message —
    /// i.e. emitting a `*_db.mojo` is warranted. (`emit_db_model` skips
    /// files with no DbStorable target so no empty file is written.)
    pub fn has_db_target(file: &IrFile, opts: &DbOptionTable) -> bool {
        file.messages
            .iter()
            .any(|m| !m.is_map_entry && opts.table_for(&m.fq_name).is_some())
    }

    fn file_has_dbstorable_target(&self) -> bool {
        self.file.messages.iter().any(|m| {
            !m.is_map_entry
                && self
                    .opts
                    .table_for(&m.fq_name)
                    .is_some_and(|t| !t.schema_only)
        })
    }

    fn file_has_schema_only_target(&self) -> bool {
        self.file.messages.iter().any(|m| {
            !m.is_map_entry
                && self
                    .opts
                    .table_for(&m.fq_name)
                    .is_some_and(|t| t.schema_only)
        })
    }

    /// Emit the whole `*_db.mojo` and return its source.
    pub fn emit(mut self) -> String {
        self.emit_header();
        for msg in &self.file.messages {
            if msg.is_map_entry {
                continue;
            }
            match self.opts.table_for(&msg.fq_name) {
                Some(table) if table.schema_only => self.emit_schema_message(msg),
                Some(_) => self.emit_db_message(msg),
                None => {
                    // A non-table message reachable only as a nested struct
                    // of a table message is emitted as a plain Mojo struct
                    // (no DbStorable impl) so the table's JSON field has a
                    // typed target. A message that is neither a table nor a
                    // nested target is skipped here (it belongs to the
                    // `_serde.mojo` emit target, not `_db.mojo`).
                    if self.is_nested_target(msg) {
                        self.emit_plain_struct(msg);
                    }
                }
            }
        }
        if self.file_has_bool_field() {
            self.emit_decode_bool_helper();
        }
        self.buf
    }

    /// The file-level `_db_decode_bool` helper — decodes a BOOL column from its
    /// canonical text carrier (`DbValue.bool_val` renders `true`/`false`;
    /// sqlite's INTEGER affinity may round-trip `1`/`0`). Emitted once per file
    /// that has a bool column, since `DbRow` ships no `get_bool` getter.
    fn emit_decode_bool_helper(&mut self) {
        self.line("# A BOOL column has no DbRow.get_bool getter — decode from the");
        self.line("# canonical text carrier (true/false, with 1/t accepted for the");
        self.line("# sqlite INTEGER-affinity round-trip).");
        self.line("def _db_decode_bool(row: DbRow, col: Int) raises -> Bool:");
        self.push_indent();
        self.line("var s = row.get_text(col)");
        self.line("return s == String(\"true\") or s == String(\"1\") or s == String(\"t\")");
        self.pop_indent();
        self.blank();
        self.blank();
    }

    // -- buffer primitives (mirror emit.rs) -----------------------------

    fn line(&mut self, text: &str) {
        if text.is_empty() {
            self.buf.push('\n');
            return;
        }
        for _ in 0..self.indent {
            self.buf.push_str("    ");
        }
        self.buf.push_str(text);
        self.buf.push('\n');
    }

    fn blank(&mut self) {
        self.buf.push('\n');
    }

    fn push_indent(&mut self) {
        self.indent += 1;
    }

    fn pop_indent(&mut self) {
        self.indent = self.indent.saturating_sub(1);
    }

    // -- header ---------------------------------------------------------

    fn emit_header(&mut self) {
        self.line("# GENERATED by protoc-gen-mojo (db_storable target) — do not hand-edit.");
        self.line(&format!("# Source: {}", self.file.proto_path));
        self.line(&format!("# proto package: {}", self.file.proto_package));
        self.line(&format!("# Mojo package:  {}", self.file.mojo_package));
        self.line("#");
        self.line("# Generated structs conform to komira_db.DbStorable:");
        self.line("# column_names / column_types / to_row / from_row /");
        self.line("# insert_sql / create_table_ddl. Backend-neutral logical types.");
        self.blank();
        self.line("from komira_db import (");
        if self.file_has_dbstorable_target() {
            self.line("    DbStorable,");
        }
        if self.file_has_schema_only_target() {
            self.line("    DbSchema,");
        }
        self.line("    SqlDatabase,");
        self.line("    DbValue,");
        self.line("    DbRow,");
        self.line("    DbColumn,");
        self.line("    Uuid,");
        self.line("    Timestamptz,");
        self.line("    LOGICAL_UUID,");
        self.line("    LOGICAL_TEXT,");
        self.line("    LOGICAL_INT4,");
        self.line("    LOGICAL_INT8,");
        self.line("    LOGICAL_FLOAT8,");
        self.line("    LOGICAL_FLOAT4,");
        self.line("    LOGICAL_BOOL,");
        self.line("    LOGICAL_BYTES,");
        self.line("    LOGICAL_TIMESTAMPTZ,");
        self.line("    LOGICAL_JSONB,");
        self.line("    LOGICAL_TEXT_ARRAY,");
        self.line(")");
        if self.file_has_json_field() {
            if self.file_has_message_json_field() {
                self.line(
                    "from komira_db.proto_json import (",
                );
                self.line("    to_proto_json,");
                self.line("    from_proto_json,");
                self.line("    message_from_proto_json,");
                self.line("    repeated_from_proto_json,");
                self.line(")");
            } else {
                self.line("from komira_db.proto_json import to_proto_json, from_proto_json");
            }
        }
        self.blank();
        self.blank();
    }

    // -- DbStorable message ---------------------------------------------

    fn emit_explicit_deinit(&mut self) {
        self.line("# PORT(1.0.0): explicit destructor — 1.0.0's `Deinitable`");
        self.line("# synthesis is not co-inductive and its cycle guard caches a");
        self.line("# negative. Field destructors still run; ownership is unchanged.");
        self.line("def __deinit__(deinit self):");
        self.push_indent();
        self.line("pass");
        self.pop_indent();
        self.blank();
    }

    fn emit_db_message(&mut self, msg: &IrMessage) {
        let table = self
            .opts
            .table_for(&msg.fq_name)
            .expect("emit_db_message called on a non-table message")
            .clone();

        self.line(&format!("# proto message {} ({})", msg.name, msg.fq_name));
        self.line(&format!("# DbStorable table `{}`", table.table));
        self.line("@fieldwise_init");
        self.line(&format!("struct {}(DbStorable):", msg.mojo_name));
        self.push_indent();
        self.line(&format!(
            "\"\"\"Generated DbStorable row type for proto `{}`.\"\"\"",
            msg.name
        ));
        self.blank();

        // comptime TABLE / PK.
        self.line(&format!(
            "comptime TABLE: StaticString = \"{}\"",
            table.table
        ));
        self.line(&format!("comptime PK: StaticString = \"{}\"", table.pk));
        self.blank();

        // -- struct fields, in field-NUMBER order (the stable identity) --
        let fields = self.db_fields(msg);
        for (field, logical, _opts) in &fields {
            let col = self.column_name(msg, field);
            self.line(&format!(
                "# field #{} `{}` -> column `{}` ({})",
                field.proto_field_number,
                field.name,
                col,
                logical.pg_ddl()
            ));
            self.line(&format!(
                "var {}: {}",
                field.name,
                self.field_mojo_type(*logical, field)
            ));
        }
        self.blank();
        self.emit_explicit_deinit();

        self.emit_column_names(msg, &fields);
        self.blank();
        self.emit_column_types(msg, &fields);
        self.blank();
        self.emit_create_table_ddl(msg, &table, &fields);
        self.blank();
        self.emit_create_table_ddl_backends(msg, &table, &fields);
        self.blank();
        self.emit_insert_sql(msg, &fields);
        self.blank();
        self.emit_to_row(&fields);
        self.blank();
        self.emit_from_row(msg, &fields);

        self.pop_indent();
        self.blank();
        self.blank();
    }

    fn emit_schema_message(&mut self, msg: &IrMessage) {
        let table = self
            .opts
            .table_for(&msg.fq_name)
            .expect("emit_schema_message called on a non-table message")
            .clone();

        self.line(&format!("# proto message {} ({})", msg.name, msg.fq_name));
        self.line(&format!(
            "# DbSchema table `{}` (DDL-only — schema_only)",
            table.table
        ));
        self.line("@fieldwise_init");
        self.line(&format!("struct {}(DbSchema):", msg.mojo_name));
        self.push_indent();
        self.line(&format!(
            "\"\"\"Generated DbSchema (DDL-only) type for proto `{}`.\"\"\"",
            msg.name
        ));
        self.blank();

        self.line(&format!(
            "comptime TABLE: StaticString = \"{}\"",
            table.table
        ));
        self.blank();

        // The struct still carries its fields (a typed in-memory row is useful
        // even for an append-only table — the insert path can build one), but
        // the trait conformance is DbSchema, not DbStorable.
        let fields = self.db_fields(msg);
        for (field, logical, _opts) in &fields {
            let col = self.column_name(msg, field);
            self.line(&format!(
                "# field #{} `{}` -> column `{}` (pg {} / sqlite {})",
                field.proto_field_number,
                field.name,
                col,
                logical.pg_ddl(),
                logical.sqlite_ddl()
            ));
            self.line(&format!(
                "var {}: {}",
                field.name,
                self.field_mojo_type(*logical, field)
            ));
        }
        self.blank();
        self.emit_explicit_deinit();

        self.emit_column_names(msg, &fields);
        self.blank();
        self.emit_create_table_ddl_backends(msg, &table, &fields);

        self.pop_indent();
        self.blank();
        self.blank();
    }

    /// `column_names()` — the column list in field-number order.
    fn emit_column_names(&mut self, msg: &IrMessage, fields: &[FieldRow]) {
        self.line("@staticmethod");
        self.line("def column_names() -> List[String]:");
        self.push_indent();
        self.line("var out = List[String]()");
        for (field, _logical, _o) in fields {
            let col = self.column_name(msg, field);
            self.line(&format!("out.append(String(\"{col}\"))"));
        }
        self.line("return out^");
        self.pop_indent();
    }

    fn emit_column_types(&mut self, msg: &IrMessage, fields: &[FieldRow]) {
        self.line("@staticmethod");
        self.line("def column_types() -> List[DbColumn]:");
        self.push_indent();
        self.line("var out = List[DbColumn]()");
        for (field, logical, _o) in fields {
            let col = self.column_name(msg, field);
            let nullable = if is_nullable(field) { "True" } else { "False" };
            self.line(&format!(
                "out.append(DbColumn(\"{}\", {}, {}, {}))",
                col,
                field.proto_field_number,
                logical.logical_token(),
                nullable
            ));
        }
        self.line("return out^");
        self.pop_indent();
    }

    fn emit_create_table_ddl(
        &mut self,
        msg: &IrMessage,
        table: &crate::db_options::DbTableOptions,
        fields: &[FieldRow],
    ) {
        self.line("@staticmethod");
        self.line("def create_table_ddl() -> String:");
        self.push_indent();
        let ddl = self.build_ddl(msg, table, fields, Backend::Pg);
        self.line(&format!("return String(\"{ddl}\")"));
        self.pop_indent();
    }

    fn emit_create_table_ddl_backends(
        &mut self,
        msg: &IrMessage,
        table: &crate::db_options::DbTableOptions,
        fields: &[FieldRow],
    ) {
        self.line("@staticmethod");
        self.line("def create_table_ddl_pg() -> String:");
        self.push_indent();
        let pg = self.build_ddl(msg, table, fields, Backend::Pg);
        self.line(&format!("return String(\"{pg}\")"));
        self.pop_indent();
        self.blank();
        self.line("@staticmethod");
        self.line("def create_table_ddl_sqlite() -> String:");
        self.push_indent();
        let sqlite = self.build_ddl(msg, table, fields, Backend::Sqlite);
        self.line(&format!("return String(\"{sqlite}\")"));
        self.pop_indent();
    }

    fn build_ddl(
        &self,
        msg: &IrMessage,
        table: &crate::db_options::DbTableOptions,
        fields: &[FieldRow],
        backend: Backend,
    ) -> String {
        let pk_cols: Vec<&str> = table.pk.split(',').map(|s| s.trim()).collect();
        let mut col_defs: Vec<String> = Vec::new();
        for (field, logical, opts) in fields {
            let col = self.column_name(msg, field);
            let ddl_ty = match backend {
                Backend::Pg => logical.pg_ddl(),
                Backend::Sqlite => logical.sqlite_ddl(),
            };
            let mut def = format!("{col} {ddl_ty}");
            if logical.is_serial() {
                match backend {
                    Backend::Pg => def.push_str(" PRIMARY KEY"),
                    Backend::Sqlite => def.push_str(" PRIMARY KEY AUTOINCREMENT"),
                }
                col_defs.push(def);
                continue;
            }
            // single-column PK inline.
            let is_inline_pk = pk_cols.len() == 1 && pk_cols[0] == col;
            if is_inline_pk {
                def.push_str(" PRIMARY KEY");
            } else if !is_nullable(field) {
                def.push_str(" NOT NULL");
            }
            if opts.unique && !is_inline_pk {
                def.push_str(" UNIQUE");
            }
            if let Some(target) = &opts.references {
                def.push_str(&format!(" REFERENCES {target}"));
            }
            if let Some(d) = &opts.default {
                let now_default = d.trim().eq_ignore_ascii_case("NOW()");
                if !(now_default && backend == Backend::Sqlite) {
                    def.push_str(&format!(" DEFAULT {d}"));
                }
            }
            col_defs.push(def);
        }
        // composite PK as a trailing constraint.
        if pk_cols.len() > 1 {
            col_defs.push(format!("PRIMARY KEY ({})", pk_cols.join(", ")));
        }
        // composite UNIQUE as a trailing constraint (same shape as the
        // composite PK above). Emitted on both backends.
        if !table.unique_together.is_empty() {
            let cols: Vec<&str> = table
                .unique_together
                .iter()
                .map(|s| s.trim())
                .collect();
            col_defs.push(format!("UNIQUE ({})", cols.join(", ")));
        }
        format!(
            "CREATE TABLE IF NOT EXISTS {} (\\n    {}\\n)",
            table.table,
            col_defs.join(",\\n    ")
        )
    }

    /// `insert_sql[D: SqlDatabase]()` — the column list + backend-dialect
    /// placeholders (`D.placeholder(i)` — pg `$N`, sqlite `?N`). Bound on
    /// `SqlDatabase` because it reaches the SQL-dialect `D.placeholder(i)`.
    /// The columns are the physical names (after a `(komira.db.column)`
    /// override), the same ones `column_names()` and the DDL use.
    fn emit_insert_sql(&mut self, msg: &IrMessage, fields: &[FieldRow]) {
        let cols: Vec<String> = fields
            .iter()
            .map(|(f, _, _)| self.column_name(msg, f))
            .collect();
        self.line("@staticmethod");
        self.line("def insert_sql[D: SqlDatabase]() -> String:");
        self.push_indent();
        self.line(&format!(
            "var sql = String(\"INSERT INTO \") + Self.TABLE + String(\" ({}) VALUES (\")",
            cols.join(", ")
        ));
        self.line(&format!("for i in range({}):", fields.len()));
        self.push_indent();
        self.line("if i > 0:");
        self.push_indent();
        self.line("sql += String(\", \")");
        self.pop_indent();
        self.line("sql += D.placeholder(i)");
        self.pop_indent();
        self.line("sql += String(\")\")");
        self.line("return sql^");
        self.pop_indent();
    }

    fn emit_to_row(&mut self, fields: &[FieldRow]) {
        self.line("def to_row(self) -> List[DbValue]:");
        self.push_indent();
        self.line("\"\"\"The value cascade — one DbValue per field (design §2.7.2).\"\"\"");
        self.line("var out = List[DbValue]()");
        for (field, logical, _o) in fields {
            self.emit_to_row_field(field, *logical);
        }
        self.line("return out^");
        self.pop_indent();
    }

    fn emit_to_row_field(&mut self, field: &IrField, logical: Logical) {
        let n = field.proto_field_number;
        let json = matches!(logical, Logical::Jsonb | Logical::TextArray);
        // A nullable (optional) SCALAR branches on presence. A UUID carries
        // its 16 raw bytes — `DbValue.uuid` takes `InlineArray[UInt8, 16]`, so
        // the present arm must unwrap the `Optional[Uuid]` AND read `.bytes()`
        // (matching the non-optional UUID path below). Every other scalar
        // passes `.value()` straight to its typed ctor.
        if is_nullable(field) && !json {
            let present = if logical == Logical::Uuid {
                format!("self.{}.value().bytes()", field.name)
            } else {
                format!("self.{}.value()", field.name)
            };
            self.line(&format!("if self.{}:", field.name));
            self.push_indent();
            self.line(&format!(
                "out.append(DbValue.{}({}))    # field {}",
                logical.dbvalue_ctor(),
                present,
                n
            ));
            self.pop_indent();
            self.line("else:");
            self.push_indent();
            self.line(&format!(
                "out.append(DbValue.null({}))",
                logical.logical_token()
            ));
            self.pop_indent();
            return;
        }
        match logical {
            Logical::Jsonb => {
                // map / message / repeated-message → canonical proto3 JSON.
                self.line(&format!(
                    "out.append(DbValue.jsonb(to_proto_json(self.{})))    # field {} (nested → JSON, §2.9.2)",
                    field.name, n
                ));
            }
            Logical::TextArray => {
                // repeated scalar → pg TEXT[] / sqlite JSON array.
                self.line(&format!(
                    "out.append(DbValue.text_array(self.{}))    # field {} (repeated scalar, §2.9.1)",
                    field.name, n
                ));
            }
            Logical::Uuid => {
                self.line(&format!(
                    "out.append(DbValue.uuid(self.{}.bytes()))    # field {}",
                    field.name, n
                ));
            }
            _ => {
                self.line(&format!(
                    "out.append(DbValue.{}(self.{}))    # field {}",
                    logical.dbvalue_ctor(),
                    field.name,
                    n
                ));
            }
        }
    }

    fn emit_from_row(&mut self, msg: &IrMessage, fields: &[FieldRow]) {
        self.line("@staticmethod");
        self.line("def from_row(row: DbRow, col_index: List[Int]) raises -> Self:");
        self.push_indent();
        self.line("\"\"\"The inverse value cascade — decode each field (design §4.3).\"\"\"");
        let mut ctor_args: Vec<String> = Vec::new();
        for (i, (field, logical, opts)) in fields.iter().enumerate() {
            let var = format!("_f{i}");
            self.emit_from_row_field(&var, i, field, *logical, opts);
            if self.from_row_local_needs_move(field, *logical) {
                ctor_args.push(format!("{var}^"));
            } else {
                ctor_args.push(var);
            }
        }
        self.line(&format!(
            "return {}({})",
            msg.mojo_name,
            ctor_args.join(", ")
        ));
        self.pop_indent();
    }

    fn emit_from_row_field(
        &mut self,
        var: &str,
        i: usize,
        field: &IrField,
        logical: Logical,
        opts: &DbFieldOptions,
    ) {
        let json = matches!(logical, Logical::Jsonb | Logical::TextArray);
        if is_nullable(field) && !json {
            match logical {
                Logical::Uuid => {
                    self.line(&format!("var {} = Optional[Uuid]()", var));
                    self.line(&format!("if not row.is_null(col_index[{}]):", i));
                    self.push_indent();
                    self.line(&format!(
                        "{} = Optional[Uuid](Uuid(row.get_uuid(col_index[{}])))",
                        var, i
                    ));
                    self.pop_indent();
                }
                Logical::Bool => {
                    self.line(&format!("var {} = Optional[Bool]()", var));
                    self.line(&format!("if not row.is_null(col_index[{}]):", i));
                    self.push_indent();
                    self.line(&format!(
                        "{} = Optional[Bool](_db_decode_bool(row, col_index[{}]))",
                        var, i
                    ));
                    self.pop_indent();
                }
                _ => {
                    self.line(&format!(
                        "var {} = row.get_opt_{}(col_index[{}])",
                        var,
                        logical.dbrow_getter(),
                        i
                    ));
                }
            }
            return;
        }
        if !is_nullable(field) && !json {
            if let Some(sql_default) = opts.default.as_deref() {
                if let Some(mojo_default) = mojo_default_literal(logical, sql_default) {
                    self.emit_from_row_defaulted(var, i, logical, &mojo_default);
                    return;
                }
            }
        }
        match logical {
            Logical::Jsonb => {
                match &field.ty {
                    IrType::Message(r) => {
                        if field.label == Label::Repeated {
                            self.line(&format!(
                                "var {} = repeated_from_proto_json[{}](row.get_jsonb(col_index[{}]))",
                                var, r.mojo_name, i
                            ));
                        } else {
                            self.line(&format!(
                                "var {} = message_from_proto_json[{}](row.get_jsonb(col_index[{}]))",
                                var, r.mojo_name, i
                            ));
                        }
                    }
                    _ => {
                        // map / repeated-enum → the generic map/Dict codec.
                        let mojo_ty = self.json_mojo_type(field);
                        self.line(&format!(
                            "var {} = from_proto_json[{}](row.get_jsonb(col_index[{}]))",
                            var, mojo_ty, i
                        ));
                    }
                }
            }
            Logical::TextArray => {
                self.line(&format!(
                    "var {} = row.get_text_array(col_index[{}])",
                    var, i
                ));
            }
            Logical::Uuid => {
                self.line(&format!(
                    "var {} = Uuid(row.get_uuid(col_index[{}]))",
                    var, i
                ));
            }
            Logical::Bool => {
                self.line(&format!(
                    "var {} = _db_decode_bool(row, col_index[{}])",
                    var, i
                ));
            }
            _ => {
                self.line(&format!(
                    "var {} = row.get_{}(col_index[{}])",
                    var,
                    logical.dbrow_getter(),
                    i
                ));
            }
        }
    }

    fn emit_from_row_defaulted(
        &mut self,
        var: &str,
        i: usize,
        logical: Logical,
        default_expr: &str,
    ) {
        self.line(&format!("var {} = {}", var, default_expr));
        self.line(&format!("if not row.is_null(col_index[{}]):", i));
        self.push_indent();
        match logical {
            Logical::Bool => self.line(&format!(
                "{} = _db_decode_bool(row, col_index[{}])",
                var, i
            )),
            _ => self.line(&format!(
                "{} = row.get_{}(col_index[{}])",
                var,
                logical.dbrow_getter(),
                i
            )),
        }
        self.pop_indent();
    }

    fn from_row_local_needs_move(&self, field: &IrField, logical: Logical) -> bool {
        match logical {
            // A repeated scalar → `List[..]`.
            Logical::TextArray => true,
            // `bytes` → `List[UInt8]` (or `Optional[List[UInt8]]`), which is
            // not ImplicitlyCopyable: passed without `^` it does not compile.
            Logical::Bytes => true,
            // map → `Dict[..]`; repeated message / repeated enum → `List[..]`;
            // a SINGULAR message is the nested struct value (no Dict/List wrap).
            Logical::Jsonb => match &field.ty {
                IrType::Map(_, _) => true,
                IrType::Message(_) | IrType::Enum(_) => field.label == Label::Repeated,
                IrType::Scalar(_) => false,
                IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
            },
            _ => false,
        }
    }

    // -- nested (plain) struct emission ---------------------------------

    fn emit_plain_struct(&mut self, msg: &IrMessage) {
        self.line(&format!("# nested message {} ({})", msg.name, msg.fq_name));
        self.line("# (a nested struct — stored as JSON inside its parent's row, §2.9.1)");
        self.line("@fieldwise_init");
        self.line(&format!("struct {}(Copyable, Movable):", msg.mojo_name));
        self.push_indent();
        self.line(&format!(
            "\"\"\"Generated nested struct for proto `{}`.\"\"\"",
            msg.name
        ));
        self.blank();
        for field in &msg.fields {
            if field.oneof_index.is_some() {
                continue;
            }
            self.line(&format!(
                "# field #{} `{}`",
                field.proto_field_number, field.name
            ));
            self.line(&format!(
                "var {}: {}",
                field.name,
                self.nested_field_storage_type(field)
            ));
        }
        self.blank();
        // `emit_explicit_deinit` ends with its own blank, so only ONE more is
        // needed to keep the two-blank-line separation every other struct here
        // gets.
        self.emit_explicit_deinit();
        self.emit_explicit_copy_ctor(msg);
        self.pop_indent();
        self.blank();
    }

    /// An explicit copy constructor for the nested struct, so it is never
    /// trivially copyable. The nested struct is `Copyable`, and on Mojo 1.0.0
    /// the synthesized copy of a struct with an explicit `__deinit__` can be
    /// treated as trivial for some layouts, after which `List.copy()` copies
    /// the elements with a memcpy and the copy shares its String buffers with
    /// the original (see `emit.rs`, `emit_explicit_copy_ctor`). The DbStorable
    /// row and the DbSchema row are `Movable` only and are never copied.
    fn emit_explicit_copy_ctor(&mut self, msg: &IrMessage) {
        self.line("# Explicit so the struct is never trivially copyable: Mojo 1.0.0 can");
        self.line("# synthesize a trivial copy for some layouts, and `List.copy()` would");
        self.line("# then share String buffers between the copy and the original.");
        self.line("def __init__(out self, *, copy: Self):");
        self.push_indent();
        let names: Vec<&str> = msg
            .fields
            .iter()
            .filter(|f| f.oneof_index.is_none())
            .map(|f| f.name.as_str())
            .collect();
        if names.is_empty() {
            self.line("pass");
        }
        for n in names {
            self.line(&format!("self.{n} = copy.{n}.copy()"));
        }
        self.pop_indent();
        self.blank();
    }

    // -- field model ----------------------------------------------------

    fn db_fields(&self, msg: &IrMessage) -> Vec<FieldRow> {
        let mut rows: Vec<FieldRow> = msg
            .fields
            .iter()
            .filter(|f| f.oneof_index.is_none())
            .map(|f| {
                let opts = self.opts.field_for(&msg.fq_name, &f.name);
                let logical = self.resolve_logical(f, &opts);
                (f.clone(), logical, opts)
            })
            .collect();
        rows.sort_by_key(|(f, _, _)| f.proto_field_number);
        rows
    }

    fn resolve_logical(&self, field: &IrField, opts: &DbFieldOptions) -> Logical {
        let repeated = field.label == Label::Repeated;
        match &field.ty {
            IrType::Map(_, _) => Logical::Jsonb,
            // A repeated OR singular message → JSON object / array.
            IrType::Message(_) => Logical::Jsonb,
            IrType::Enum(_) if repeated => Logical::Jsonb,
            IrType::Enum(_) => Logical::Text,
            IrType::Scalar(_) if repeated => Logical::TextArray,
            IrType::Scalar(s) => match opts.col_type.as_deref() {
                Some("uuid") => Logical::Uuid,
                Some("timestamptz") => Logical::Timestamptz,
                Some("jsonb") => Logical::Jsonb,
                Some("serial") => Logical::Serial,
                Some("bigserial") => Logical::BigSerial,
                // an absent / unknown col_type falls through to the scalar map.
                _ => scalar_logical(*s),
            },
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    /// The Mojo storage type of a table field — the logical element type with
    /// the `Optional[..]` nullable wrap for `optional` fields, the `List[..]`
    /// wrap for repeated scalars, the nested-struct type for JSON fields.
    fn field_mojo_type(&self, logical: Logical, field: &IrField) -> String {
        match logical {
            Logical::Jsonb => self.json_mojo_type(field),
            Logical::TextArray => self.json_mojo_type(field),
            _ => {
                let base = logical.mojo_type("");
                if is_nullable(field) {
                    format!("Optional[{base}]")
                } else {
                    base
                }
            }
        }
    }

    fn json_mojo_type(&self, field: &IrField) -> String {
        match &field.ty {
            IrType::Map(k, v) => {
                format!("Dict[{}, {}]", ir_type_name(k), ir_type_name(v))
            }
            IrType::Message(r) => {
                if field.label == Label::Repeated {
                    format!("List[{}]", r.mojo_name)
                } else {
                    r.mojo_name.clone()
                }
            }
            IrType::Enum(r) => {
                if field.label == Label::Repeated {
                    format!("List[{}]", r.mojo_name)
                } else {
                    r.mojo_name.clone()
                }
            }
            IrType::Scalar(s) => {
                // repeated scalar.
                format!("List[{}]", s.mojo_type())
            }
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    /// The Mojo storage type for a nested (plain) struct's own field — same
    /// shaping as `emit.rs`'s message struct (Optional / List / Dict).
    fn nested_field_storage_type(&self, field: &IrField) -> String {
        match &field.ty {
            IrType::Map(k, v) => format!("Dict[{}, {}]", ir_type_name(k), ir_type_name(v)),
            IrType::Scalar(s) => match field.label {
                Label::Repeated => format!("List[{}]", s.mojo_type()),
                Label::Optional => format!("Optional[{}]", s.mojo_type()),
                Label::Single => s.mojo_type().to_string(),
            },
            IrType::Enum(r) | IrType::Message(r) => match field.label {
                Label::Repeated => format!("List[{}]", r.mojo_name),
                Label::Optional => format!("Optional[{}]", r.mojo_name),
                Label::Single => r.mojo_name.clone(),
            },
            IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
        }
    }

    fn column_name(&self, msg: &IrMessage, field: &IrField) -> String {
        let opts = self.opts.field_for(&msg.fq_name, &field.name);
        opts.column.unwrap_or_else(|| field.name.clone())
    }

    pub(crate) fn resolve_index_column(
        &self,
        msg: &IrMessage,
        written: &str,
    ) -> IndexColumnResolution {
        // Match against the emitted (non-oneof) field rows — by proto field name
        // OR by the resolved physical column name (override-aware).
        for (field, logical, _opts) in self.db_fields(msg) {
            let phys = self.column_name(msg, &field);
            if field.name == written || phys == written {
                let kind = match logical {
                    Logical::Jsonb => IndexColumnKind::Jsonb,
                    Logical::TextArray => IndexColumnKind::TextArray,
                    _ => IndexColumnKind::Indexable,
                };
                // An enum column stores its TEXT form (`resolve_logical` maps a
                // singular enum -> Logical::Text); ORDER BY on it is LEXICAL, not
                // ordinal. Flag it so the emitter can annotate the index.
                let is_enum_text = matches!(field.ty, IrType::Enum(_))
                    && field.label != Label::Repeated;
                return IndexColumnResolution {
                    physical: phys,
                    kind,
                    is_enum_text,
                };
            }
        }
        // Not a column at all — a oneof member (filtered from db_fields), a
        // removed/renamed field, or a typo.
        IndexColumnResolution {
            physical: written.to_string(),
            kind: IndexColumnKind::Unknown,
            is_enum_text: false,
        }
    }

    /// `true` if this non-table message is referenced (as a singular /
    /// repeated message field) by a table message in this file — i.e. it must
    /// be emitted as a nested struct here.
    fn is_nested_target(&self, candidate: &IrMessage) -> bool {
        self.file.messages.iter().any(|m| {
            !m.is_map_entry
                && self.opts.table_for(&m.fq_name).is_some()
                && m.fields
                    .iter()
                    .any(|f| matches!(&f.ty, IrType::Message(r) if r.fq_name == candidate.fq_name))
        })
    }

    fn file_has_json_field(&self) -> bool {
        self.file.messages.iter().any(|m| {
            !m.is_map_entry
                && self.opts.table_for(&m.fq_name).is_some()
                && m.fields.iter().any(|f| {
                    f.oneof_index.is_none()
                        && matches!(
                            self.resolve_logical(f, &self.opts.field_for(&m.fq_name, &f.name)),
                            Logical::Jsonb
                        )
                })
        })
    }

    fn file_has_bool_field(&self) -> bool {
        self.file.messages.iter().any(|m| {
            !m.is_map_entry
                // Only full DbStorable targets emit `from_row` (the sole caller
                // of `_db_decode_bool`); a schema-only table emits no decode.
                && self
                    .opts
                    .table_for(&m.fq_name)
                    .is_some_and(|t| !t.schema_only)
                && m.fields.iter().any(|f| {
                    f.oneof_index.is_none()
                        && self.resolve_logical(f, &self.opts.field_for(&m.fq_name, &f.name))
                            == Logical::Bool
                })
        })
    }

    fn file_has_message_json_field(&self) -> bool {
        self.file.messages.iter().any(|m| {
            !m.is_map_entry
                && self.opts.table_for(&m.fq_name).is_some()
                && m.fields.iter().any(|f| {
                    f.oneof_index.is_none() && matches!(&f.ty, IrType::Message(_))
                })
        })
    }
}

/// One resolved DbStorable field row: the IR field, its logical type, its
/// DB options.
type FieldRow = (IrField, Logical, DbFieldOptions);

fn scalar_logical(s: ScalarKind) -> Logical {
    match s {
        ScalarKind::Double => Logical::Float8,
        ScalarKind::Float => Logical::Float4,
        ScalarKind::Int64
        | ScalarKind::Uint64
        | ScalarKind::Sint64
        | ScalarKind::Fixed64
        | ScalarKind::Sfixed64 => Logical::Int8,
        ScalarKind::Int32
        | ScalarKind::Uint32
        | ScalarKind::Sint32
        | ScalarKind::Fixed32
        | ScalarKind::Sfixed32 => Logical::Int4,
        ScalarKind::Bool => Logical::Bool,
        ScalarKind::String => Logical::Text,
        ScalarKind::Bytes => Logical::Bytes,
    }
}

fn is_nullable(field: &IrField) -> bool {
    field.label == Label::Optional
}

fn mojo_default_literal(logical: Logical, sql_default: &str) -> Option<String> {
    let d = sql_default.trim();
    match logical {
        Logical::Text => {
            let inner = sql_string_literal_body(d)?;
            Some(format!("String({})", mojo_string_literal(&inner)))
        }
        Logical::Int4 => d.parse::<i32>().ok().map(|n| format!("Int32({n})")),
        Logical::Int8 => d.parse::<i64>().ok().map(|n| format!("Int64({n})")),
        Logical::Bool => match d.to_ascii_uppercase().as_str() {
            "TRUE" => Some("True".to_string()),
            "FALSE" => Some("False".to_string()),
            _ => None,
        },
        _ => None,
    }
}

fn sql_string_literal_body(d: &str) -> Option<String> {
    let b = d.as_bytes();
    if b.len() < 2 || b[0] != b'\'' || b[b.len() - 1] != b'\'' {
        return None;
    }
    Some(d[1..d.len() - 1].replace("''", "'"))
}

/// `s` as a double-quoted Mojo string literal (backslash + quote escaped).
fn mojo_string_literal(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The standalone Mojo type name of an `IrType` (a map key/value element).
fn ir_type_name(ty: &IrType) -> String {
    match ty {
        IrType::Scalar(s) => s.mojo_type().to_string(),
        IrType::Enum(r) => r.mojo_name.clone(),
        IrType::Message(r) => r.mojo_name.clone(),
        IrType::Map(_, _) => "Dict".to_string(),
        IrType::List(_) => unreachable!("{}", crate::ir::LIST_IS_AWS_FRONT_END_ONLY),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum IndexColumnKind {
    /// A top-level scalar/enum/uuid/timestamptz column — composite-indexable.
    Indexable,
    Jsonb,
    TextArray,
    /// The written name resolves to NO emitted column — a oneof member (filtered
    /// from `db_fields`), a removed/renamed field, or a typo.
    Unknown,
}

/// The result of resolving an index-referenced column against the emitted
/// column set: the physical column name + its index-classification.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct IndexColumnResolution {
    /// The physical column name (override-resolved).
    pub physical: String,
    /// The index-classification.
    pub kind: IndexColumnKind,
    pub is_enum_text: bool,
}

/// Emit the `*_db.mojo` files for a model + its decoded DB options. One
/// output file per IR file that has at least one `(komira.db.table)`
/// message. The output path is `<stem>_db.mojo` (alongside `emit.rs`'s
/// `<stem>.mojo`).
pub fn emit_db_model(model: &IrModel, opts: &DbOptionTable) -> Vec<(String, String)> {
    model
        .files
        .iter()
        .filter(|file| DbEmitter::has_db_target(file, opts))
        .map(|file| {
            let path = db_mojo_path(&file.proto_path);
            let source = DbEmitter::new(file, opts).emit();
            (path, source)
        })
        .collect()
}

pub fn db_mojo_path(proto_path: &str) -> String {
    let basename = proto_path.rsplit('/').next().unwrap_or(proto_path);
    let stem = basename
        .rsplit_once('.')
        .map(|(s, _)| s)
        .unwrap_or(basename);
    format!("{stem}_db.mojo")
}

#[cfg(test)]
mod mojo_100_deinit_tests {
    use super::*;
    use crate::db_options::DbTableOptions;
    use crate::ir::{IrField, IrFile, IrMessage, IrModel, IrType, Label, ScalarKind, TypeRef};

    fn scalar(name: &str, num: u32, kind: ScalarKind) -> IrField {
        IrField {
            name: name.to_string(),
            ty: IrType::Scalar(kind),
            label: Label::Single,
            proto_field_number: num,
            json_name: name.to_string(),
            oneof_index: None,
        }
    }

    fn msg(name: &str, fields: Vec<IrField>) -> IrMessage {
        IrMessage {
            name: name.to_string(),
            mojo_name: name.to_string(),
            fq_name: format!(".db.v1.{name}"),
            is_map_entry: false,
            fields,
            oneofs: vec![],
        }
    }

    /// A `DbStorable` row, a `DbSchema` (DDL-only) row, and a NESTED plain
    /// struct — the emitter's three struct shapes, in one file.
    fn model_and_opts() -> (IrModel, DbOptionTable) {
        let nested = msg("Payload", vec![scalar("blob", 1, ScalarKind::String)]);
        let row = msg(
            "Row",
            vec![
                scalar("id", 1, ScalarKind::String),
                IrField {
                    name: "payload".to_string(),
                    ty: IrType::Message(TypeRef {
                        fq_name: ".db.v1.Payload".to_string(),
                        mojo_name: "Payload".to_string(),
                    }),
                    label: Label::Optional,
                    proto_field_number: 2,
                    json_name: "payload".to_string(),
                    oneof_index: None,
                },
            ],
        );
        let ddl_only = msg("Audit", vec![scalar("id", 1, ScalarKind::String)]);

        let file = IrFile {
            proto_path: "db/v1/db.proto".to_string(),
            proto_package: "db.v1".to_string(),
            mojo_package: "komira_rpc_storage".to_string(),
            messages: vec![nested, row, ddl_only],
            enums: vec![],
            services: vec![],
            imports: vec![],
        };

        let mut opts = DbOptionTable::default();
        opts.insert_table_for_test(
            ".db.v1.Row",
            DbTableOptions {
                table: "rows".to_string(),
                pk: "id".to_string(),
                ..DbTableOptions::default()
            },
        );
        opts.insert_table_for_test(
            ".db.v1.Audit",
            DbTableOptions {
                table: "audits".to_string(),
                pk: "id".to_string(),
                schema_only: true,
                ..DbTableOptions::default()
            },
        );
        (IrModel { files: vec![file] }, opts)
    }

    /// THE FALSIFIER. Removing any one of the three `emit_explicit_deinit()`
    /// calls turns this red and names which shape lost it.
    #[test]
    fn every_emitted_struct_carries_the_explicit_destructor() {
        let (model, opts) = model_and_opts();
        let files = emit_db_model(&model, &opts);
        assert_eq!(files.len(), 1, "one file in, one file out");
        let src = &files[0].1;

        let structs = src.matches("\nstruct ").count();
        let deinits = src.matches("def __deinit__(deinit self):").count();
        assert_eq!(
            structs, 3,
            "fixture must reach all three shapes (DbStorable / DbSchema / nested); got:\n{src}"
        );
        assert_eq!(
            deinits, structs,
            "1.0.0's `Deinitable` synthesis is not co-inductive, so EVERY emitted \
             struct declares its destructor — {structs} structs but {deinits} \
             destructors; got:\n{src}"
        );
    }

    #[test]
    fn each_of_the_three_shapes_declares_its_own_destructor() {
        let (model, opts) = model_and_opts();
        let src = emit_db_model(&model, &opts).remove(0).1;
        for (decl, what) in [
            ("struct Row(DbStorable):", "the DbStorable row"),
            ("struct Audit(DbSchema):", "the DbSchema DDL-only row"),
            ("struct Payload(Copyable, Movable):", "the nested JSON struct"),
        ] {
            let at = src
                .find(decl)
                .unwrap_or_else(|| panic!("{what} is missing from the emit; got:\n{src}"));
            let body = &src[at..];
            let end = body[1..].find("\nstruct ").map(|i| i + 1).unwrap_or(body.len());
            assert!(
                body[..end].contains("def __deinit__(deinit self):"),
                "{what} must declare `__deinit__`; got:\n{}",
                &body[..end]
            );
        }
    }

    #[test]
    fn the_nested_copyable_struct_has_an_explicit_copy_constructor() {
        let (model, opts) = model_and_opts();
        let src = emit_db_model(&model, &opts).remove(0).1;
        let at = src
            .find("struct Payload(Copyable, Movable):")
            .unwrap_or_else(|| panic!("nested struct missing; got:\n{src}"));
        let body = &src[at..];
        let end = body[1..].find("\nstruct ").map(|i| i + 1).unwrap_or(body.len());
        let body = &body[..end];
        assert!(
            body.contains("def __init__(out self, *, copy: Self):"),
            "a Copyable struct with an explicit __deinit__ must not rely on a \
             synthesized copy (trivial on some layouts, Mojo 1.0.0); got:\n{body}"
        );
        assert!(
            body.contains(".copy()"),
            "every field is copied by its own copy; got:\n{body}"
        );
        // Only the Copyable struct gets one: the rows are Movable only.
        assert_eq!(
            src.matches("def __init__(out self, *, copy: Self):").count(),
            1,
            "only the nested Copyable struct carries a copy constructor; got:\n{src}"
        );
    }

    #[test]
    fn no_b2_idiom_reaches_the_generated_db_module() {
        let (model, opts) = model_and_opts();
        let src = emit_db_model(&model, &opts).remove(0).1;
        assert!(
            !src.contains("ImplicitlyDestructible"),
            "b2 trait name; 1.0.0 spells it `Deinitable`; got:\n{src}"
        );
        assert!(
            !src.contains("import Span"),
            "`Span` is a BUILTIN in 1.0.0 — importing it is an ERROR; got:\n{src}"
        );
        assert!(
            !src.contains("_type_is_eq"),
            "`_type_is_eq[A, B]()` is b2; 1.0.0 spells it `(A == B)`; got:\n{src}"
        );
    }
}

#[cfg(test)]
mod column_override_tests {
    use super::*;
    use crate::db_options::{DbFieldOptions, DbTableOptions};
    use crate::ir::{IrField, IrFile, IrMessage, IrModel, IrType, Label, ScalarKind};

    /// A `(komira.db.column)` override must name the column in every SQL
    /// output, not only in `column_names()` and the DDL: an INSERT that lists
    /// the field name fails at run time against the table the DDL created.
    #[test]
    fn a_renamed_column_is_renamed_in_the_insert_too() {
        let field = |name: &str, num: u32| IrField {
            name: name.to_string(),
            ty: IrType::Scalar(ScalarKind::String),
            label: Label::Single,
            proto_field_number: num,
            json_name: name.to_string(),
            oneof_index: None,
        };
        let row = IrMessage {
            name: "Row".to_string(),
            mojo_name: "Row".to_string(),
            fq_name: ".db.v1.Row".to_string(),
            is_map_entry: false,
            fields: vec![field("id", 1), field("display_name", 2)],
            oneofs: vec![],
        };
        let file = IrFile {
            proto_path: "db/v1/db.proto".to_string(),
            proto_package: "db.v1".to_string(),
            mojo_package: "db_v1".to_string(),
            messages: vec![row],
            enums: vec![],
            services: vec![],
            imports: vec![],
        };
        let mut opts = DbOptionTable::default();
        opts.insert_table_for_test(
            ".db.v1.Row",
            DbTableOptions {
                table: "rows".to_string(),
                pk: "id".to_string(),
                ..DbTableOptions::default()
            },
        );
        opts.insert_field_for_test(
            ".db.v1.Row",
            "display_name",
            DbFieldOptions {
                column: Some("caption".to_string()),
                ..DbFieldOptions::default()
            },
        );
        let src = emit_db_model(&IrModel { files: vec![file] }, &opts).remove(0).1;
        assert!(
            src.contains("out.append(String(\"caption\"))"),
            "column_names() carries the override; got:\n{src}"
        );
        assert!(
            src.contains("String(\" (id, caption) VALUES (\")"),
            "insert_sql lists the overridden column name; got:\n{src}"
        );
        assert!(
            !src.contains("(id, display_name)"),
            "insert_sql must not list the field name; got:\n{src}"
        );
    }
}
