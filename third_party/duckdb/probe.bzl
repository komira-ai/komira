"""Throwaway probe: what the pinned DuckDB CLI reports for the tpch extension."""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/sql:defs.bzl", "DuckdbInfo")

_SCRIPT = r'''
BB="$1"; DUCK="$2"; EXTGZ="$3"; OUT="$4"
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "$DUCK" in /*) ;; *) DUCK="$PWD/$DUCK" ;; esac
case "$EXTGZ" in /*) ;; *) EXTGZ="$PWD/$EXTGZ" ;; esac
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
"$BB" mkdir -p "$OUT/home" "$OUT/a" "$OUT/b" "$OUT/c" "$OUT/d" "$OUT/e"
R="$OUT/report.txt"
export HOME="$OUT/home"
: > "$R"
say() { printf '\n==== %s\n' "$*" >> "$R"; }
D() { # D <label> <sql...>: one duckdb run, each arg one statement, errors kept, no -bail
  label="$1"; shift
  say "$label"
  F="$OUT/stmts.sql"; : > "$F"
  for s in "$@"; do printf '%s;\n' "$s" >> "$F"; done
  "$DUCK" -no-init -batch -cmd ".mode line" -cmd "SET autoinstall_known_extensions=false" -cmd "SET autoload_known_extensions=false" -f "$F" :memory: >> "$R" 2>&1
  echo "[exit status $?]" >> "$R"
}
say "busybox applets"; "$BB" --list | "$BB" tr '\n' ' ' >> "$R"
"$BB" gunzip -c "$EXTGZ" > "$OUT/a/tpch.duckdb_extension"
say "gunzipped size and sha256"; "$BB" wc -c "$OUT/a/tpch.duckdb_extension" >> "$R"; "$BB" sha256sum "$OUT/a/tpch.duckdb_extension" >> "$R" 2>&1
say "footer text (last 700 bytes, printable only)"; "$BB" tail -c 540 "$OUT/a/tpch.duckdb_extension" | "$BB" tr -c '[:print:]' ' ' | "$BB" tr -s ' ' >> "$R"; echo >> "$R"
A="$OUT/a/tpch.duckdb_extension"
# same bytes, other directory, same file name
"$BB" cp "$A" "$OUT/b/tpch.duckdb_extension"
# same bytes, other file name
"$BB" cp "$A" "$OUT/c/renamed.duckdb_extension"
# corrupted: 4 bytes in the middle replaced
SZ=$("$BB" wc -c < "$A")
"$BB" head -c 1000000 "$A" > "$OUT/d/tpch.duckdb_extension"
printf 'XXXX' >> "$OUT/d/tpch.duckdb_extension"
"$BB" tail -c +1000005 "$A" >> "$OUT/d/tpch.duckdb_extension"
# truncated by 100 bytes
"$BB" head -c $((SZ - 100)) "$A" > "$OUT/e/tpch.duckdb_extension"

D "version, settings, builtin (loaded) extensions" \
  "PRAGMA version" "SELECT version()" \
  "SELECT name, value FROM duckdb_settings() WHERE name IN ('extension_directory','custom_extension_repository','allow_unsigned_extensions','allow_community_extensions','autoinstall_known_extensions','autoload_known_extensions','enable_external_access')" \
  "SELECT * FROM duckdb_extensions() WHERE loaded"
D "tpch row BEFORE LOAD, all columns; then dbgen before LOAD" \
  "SELECT * FROM duckdb_extensions() WHERE extension_name='tpch'" \
  "CALL dbgen(sf=0.01)" \
  "SELECT count(*) AS n FROM information_schema.tables"
D "LOAD pinned file (a/), row AFTER, dbgen works, row counts" \
  "LOAD '$A'" \
  "SELECT * FROM duckdb_extensions() WHERE extension_name='tpch'" \
  "SELECT loaded::VARCHAR AS loaded_txt, coalesce(install_path,'') AS install_path FROM duckdb_extensions() WHERE extension_name='tpch'" \
  "SELECT * FROM duckdb_extensions() WHERE loaded" \
  "CALL dbgen(sf=0.01)" \
  "SELECT count(*) AS lineitem_rows FROM lineitem"
D "LOAD same bytes from b/ (same name, other dir): row AFTER" \
  "LOAD '$OUT/b/tpch.duckdb_extension'" \
  "SELECT * FROM duckdb_extensions() WHERE extension_name='tpch'" \
  "CALL dbgen(sf=0.01)"
D "LOAD a/ then LOAD b/ in one session (second load)" \
  "LOAD '$A'" "LOAD '$OUT/b/tpch.duckdb_extension'" \
  "SELECT * FROM duckdb_extensions() WHERE extension_name='tpch'"
D "LOAD same bytes under another file name (c/renamed)" \
  "LOAD '$OUT/c/renamed.duckdb_extension'" \
  "SELECT * FROM duckdb_extensions() WHERE extension_name IN ('tpch','renamed')" \
  "SELECT * FROM duckdb_extensions() WHERE loaded"
D "LOAD corrupted copy (d/, 4 bytes changed)" \
  "LOAD '$OUT/d/tpch.duckdb_extension'" \
  "SELECT * FROM duckdb_extensions() WHERE extension_name='tpch'" \
  "CALL dbgen(sf=0.01)"
D "LOAD truncated copy (e/, last 100 bytes cut)" \
  "LOAD '$OUT/e/tpch.duckdb_extension'" \
  "SELECT * FROM duckdb_extensions() WHERE extension_name='tpch'"
D "LOAD a path that does not exist" \
  "LOAD '$OUT/nope/tpch.duckdb_extension'"
D "LOAD 'tpch' by name with autoinstall/autoload off and no network" \
  "LOAD tpch" \
  "SELECT * FROM duckdb_extensions() WHERE extension_name='tpch'"
D "LOAD pinned file, then LOAD tpch by name" \
  "LOAD '$A'" "LOAD tpch" \
  "SELECT * FROM duckdb_extensions() WHERE extension_name='tpch'"
D "extension version functions after LOAD" \
  "LOAD '$A'" \
  "SELECT extension_name, extension_version, install_mode, installed_from FROM duckdb_extensions() WHERE extension_name='tpch'" \
  "SELECT * FROM duckdb_functions() WHERE function_name IN ('dbgen','tpch','tpch_queries') LIMIT 3"
say "end"; "$BB" cat "$R"
'''

def _impl(ctx):
    dist = ctx.attrs.duckdb[DuckdbInfo]
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("probe", dir = True)
    ctx.actions.run(
        cmd_args(bb, "sh", "-uc", _SCRIPT, "sh", bb, dist.binary, ctx.attrs.ext[DefaultInfo].default_outputs[0], out.as_output()),
        env = {
            "LC_ALL": "C",
            "LD_LIBRARY_PATH": cmd_args(dist.native_libs, format = "{}/lib"),
            "TZ": "UTC",
        },
        category = "duckdb_tpch_probe",
    )
    return [DefaultInfo(default_output = out)]

duckdb_tpch_probe = rule(
    impl = _impl,
    attrs = {
        "duckdb": attrs.exec_dep(providers = [DuckdbInfo]),
        "ext": attrs.dep(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)
