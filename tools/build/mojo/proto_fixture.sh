# proto_fixture.sh -- protoc reading and writing wire fixtures, inside a build
# action (proto_fixture.bzl, which says what a fixture is and what each leg
# can and cannot see).
#
# usage: busybox sh proto_fixture.sh <busybox> <protoc dir> check <report> \
#            <n> <proto path dir>... <m> <import path>... -- \
#            {<stem> <root> <hex> <txtpb> <canonical hex> <canonical producer>}...
#        busybox sh proto_fixture.sh <busybox> <protoc dir> encode <out hex> \
#            <n> <proto path dir>... <m> <import path>... -- <root> <txtpb>
#
# <protoc dir> holds bin/protoc and include/ (the well-known types and
# google/protobuf/descriptor.proto). <canonical producer> is 1 when the
# fixture's .hex may be byte-identical to its .canonical.hex, else 0. check
# runs legs 0-5 over each fixture, reports every failure on stderr with its
# leg, and writes <report> (one PASS line per fixture) only if all of them
# passed. encode writes protoc --encode=<root> of <txtpb> as hex text:
# lowercase, 64 digits a line.
set -eu

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

[ "$#" -ge 7 ] || { echo "proto_fixture: usage error" >&2; exit 2; }
BB=$(abspath "$1")
PROTOC_DIR=$(abspath "$2")
MODE=$3
OUT=$4
shift 4

T=$("$BB" mktemp -d "$PWD/.komira_proto_fixture.XXXXXX")
trap '"$BB" rm -rf "$T"' EXIT
"$BB" mkdir -p "$T/bin" "$T/tmp" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
TMPDIR="$T/tmp"
HOME="$T/home"
export PATH TMPDIR HOME

PROTO_PATHS=""
N=$1; shift
while [ "$N" -gt 0 ]; do
    PROTO_PATHS="$PROTO_PATHS --proto_path=$(abspath "$1")"
    shift; N=$((N - 1))
done
PROTO_PATHS="$PROTO_PATHS --proto_path=$PROTOC_DIR/include"
FILES=""
N=$1; shift
while [ "$N" -gt 0 ]; do
    FILES="$FILES $1"
    shift; N=$((N - 1))
done
[ "${1:-}" = -- ] || { echo "proto_fixture: usage error (no --)" >&2; exit 2; }
shift

protoc() { # <protoc option>...: over the schema; stdin to stdout
    # shellcheck disable=SC2086
    "$PROTOC_DIR/bin/protoc" $PROTO_PATHS "$@" $FILES
}

# hexdigits <hex file>: its hex digits, lowercase, on one line.
hexdigits() {
    tr -d ' \t\r\n' < "$1" | tr 'ABCDEF' 'abcdef'
}

# unhex <hex file> <binary out>: the bytes of a hex fixture; prints why not and
# fails for a character other than a hex digit or white space, an odd number
# of digits, or no digits at all.
unhex() {
    digits=$(hexdigits "$1")
    case "$digits" in
        "") echo "holds no bytes"; return 1 ;;
        *[!0-9a-f]*) echo "holds a character that is neither a hex digit nor white space"; return 1 ;;
    esac
    if [ $((${#digits} % 2)) != 0 ]; then
        echo "holds an odd number of hex digits (${#digits})"
        return 1
    fi
    # One octal escape per byte, which printf turns into the byte (\000 too).
    esc=$(printf '%s\n' "$digits" | fold -w 2 | awk '
        BEGIN { h = "0123456789abcdef" }
        { printf "\\%03o", (index(h, substr($0, 1, 1)) - 1) * 16 + index(h, substr($0, 2, 1)) - 1 }')
    # shellcheck disable=SC2059
    printf "$esc" > "$2"
}

# tohex <binary> : the hex format proto_encode writes.
tohex() {
    od -An -v -tx1 < "$1" | tr -d ' \n' | fold -w 64
    echo
}

# The root a .txtpb names on its first line, or nothing.
txtpb_root() {
    sed -n '1s/^# proto-message: \([^ ][^ ]*\)$/\1/p' "$1"
}

indent() { sed 's/^/        /'; }

case "$MODE" in
encode)
    [ "$#" = 2 ] || { echo "proto_fixture: encode takes <root> <txtpb>" >&2; exit 2; }
    ROOT=$1
    TXTPB=$2
    named=$(txtpb_root "$TXTPB")
    if [ "$named" != "$ROOT" ]; then
        echo "proto_encode: $TXTPB must begin with the line '# proto-message: $ROOT'; its first line is: $(head -n 1 "$TXTPB")" >&2
        exit 1
    fi
    if ! protoc "--encode=$ROOT" < "$TXTPB" > "$T/out.bin" 2> "$T/err"; then
        echo "proto_encode: protoc refused to encode $TXTPB as $ROOT:" >&2
        indent < "$T/err" >&2
        exit 1
    fi
    if [ ! -s "$T/out.bin" ]; then
        echo "proto_encode: $TXTPB encodes to zero bytes (every field at its default): no fixture to write" >&2
        exit 1
    fi
    tohex "$T/out.bin" > "$OUT"
    exit 0
    ;;
check) ;;
*) echo "proto_fixture: unknown mode '$MODE'" >&2; exit 2 ;;
esac

[ "$#" -gt 0 ] && [ $(($# % 6)) = 0 ] || { echo "proto_fixture: check takes groups of <stem> <root> <hex> <txtpb> <canonical hex> <canonical producer>" >&2; exit 2; }

# The schema as a table, from protoc's own descriptor set (never from a list
# or a grep of the .proto): `M <message>` for every message, `F <message>
# <field> <number> <label> <type> <type name or ->` for every field of one.
# Legs 0 and 5 read it.
if ! protoc --include_imports "--descriptor_set_out=$T/schema.pb" < /dev/null 2> "$T/schema.err" ||
    ! "$PROTOC_DIR/bin/protoc" "--proto_path=$PROTOC_DIR/include" --decode=google.protobuf.FileDescriptorSet \
        google/protobuf/descriptor.proto < "$T/schema.pb" > "$T/schema.txt" 2>> "$T/schema.err"; then
    echo "proto_fixture: SCHEMA: protoc cannot write or read the schema's descriptor set:" >&2
    indent < "$T/schema.err" >&2
    exit 1
fi
awk '
    function unquote(v) { gsub(/"/, "", v); return v }
    {
        line = $0
        sub(/^ +/, "", line)
        if (line ~ /^[a-z_]+ \{$/) {
            d++
            k[d] = substr(line, 1, length(line) - 2)
            full[d] = full[d - 1]
            if (k[d] == "field" && (k[d - 1] == "message_type" || k[d - 1] == "nested_type")) {
                infield = d
                fname = ""; fnum = ""; flabel = ""; ftype = ""; ftn = "-"
            }
            next
        }
        if (line == "}") {
            if (d == infield) {
                print "F", full[d - 1], fname, fnum, flabel, ftype, ftn
                infield = 0
            }
            d--
            next
        }
        key = line; sub(/:.*/, "", key)
        val = line; sub(/^[^:]*: /, "", val)
        if (d == 1 && k[1] == "file" && key == "package") {
            full[1] = unquote(val)
        } else if ((k[d] == "message_type" || k[d] == "nested_type") && key == "name") {
            full[d] = (full[d - 1] == "" ? "" : full[d - 1] ".") unquote(val)
            print "M", full[d]
        } else if (d == infield) {
            if (key == "name") fname = unquote(val)
            else if (key == "number") fnum = val
            else if (key == "label") flabel = val
            else if (key == "type") ftype = val
            else if (key == "type_name") { ftn = unquote(val); sub(/^\./, "", ftn) }
        }
    }' "$T/schema.txt" > "$T/schema.tsv"
# A parse that lost a field would make legs 0 and 5 check nothing while
# passing: every field of every message must be in the table, complete.
nfields=$(grep -c '^ *field {$' "$T/schema.txt" || true)
nrows=$(grep -c '^F ' "$T/schema.tsv" || true)
nmalformed=$(grep -cvE '^(M [^ ]+|F [^ ]+ [^ ]+ [0-9]+ LABEL_[A-Z]+ TYPE_[A-Z0-9]+ [^ ]+)$' "$T/schema.tsv" || true)
if [ "$nrows" != "$nfields" ] || [ "$nmalformed" != 0 ]; then
    echo "proto_fixture: SCHEMA: the descriptor set holds $nfields field(s), but its table is not one complete row for each:" >&2
    head -n 20 "$T/schema.tsv" | indent >&2
    exit 1
fi

# toptags <hex file>: `<field number> <times>` for each field number at the
# top level of the bytes (a group is skipped whole). Stops at bytes that are
# not a message, which leg 1 reports.
toptags() {
    hexdigits "$1" | awk '
        BEGIN { h = "0123456789abcdef" }
        function byte(   b) {
            if (p >= n) { broken = 1; return 0 }
            b = (index(h, substr(s, 2 * p + 1, 1)) - 1) * 16 + index(h, substr(s, 2 * p + 2, 1)) - 1
            p++
            return b
        }
        function varint(   v, m, b) {
            v = 0; m = 1
            do { b = byte(); v += (b % 128) * m; m *= 128 } while (b >= 128 && !broken)
            return v
        }
        # The length is read into `len` before `p` moves: busybox awk reads
        # `p` before calling the function in `p += varint()`, so the length
        # bytes varint() consumed would be lost.
        function skip(w,   depth, t, len) {
            if (w == 0) varint()
            else if (w == 1) p += 8
            else if (w == 2) { len = varint(); p += len }
            else if (w == 5) p += 4
            else if (w == 3) {
                depth = 1
                while (depth > 0 && !broken) {
                    t = varint()
                    if (t % 8 == 3) depth++
                    else if (t % 8 == 4) depth--
                    else skip(t % 8)
                }
            } else broken = 1
            if (p > n) broken = 1
        }
        { s = s $0 }
        END {
            n = length(s) / 2; p = 0
            while (p < n && !broken) {
                t = varint()
                if (broken) break
                skip(t % 8)
                if (!broken) count[int(t / 8)]++
            }
            for (f in count) print f, count[f]
        }'
}

nbad=0
bad() { # <stem> <leg> <message> [<file of details>]
    echo "proto_fixture: $1: $2: $3" >&2
    if [ -n "${4:-}" ]; then indent < "$4" >&2; fi
    nbad=$((nbad + 1))
}
: > "$T/report"
echo "protoc: $("$PROTOC_DIR/bin/protoc" --version)" >> "$T/report"
while [ "$#" -gt 0 ]; do
    STEM=$1 ROOT=$2 HEX=$3 TXTPB=$4 CANON=$5 CANONICAL_PRODUCER=$6
    shift 6
    # The files as named in a failure: the ones read, which for a `hex`
    # override is a build output, not <stem>.hex.
    HEXN=$(basename "$HEX") TXTPBN=$(basename "$TXTPB") CANONN=$(basename "$CANON")
    D="$T/fixture.$STEM"
    mkdir -p "$D"
    before=$nbad
    if ! why=$(unhex "$HEX" "$D/in.bin"); then
        bad "$STEM" "FIXTURE" "$HEXN $why"
        continue
    fi
    if ! why=$(unhex "$CANON" "$D/canonical.bin"); then
        bad "$STEM" "FIXTURE" "$CANONN $why"
        continue
    fi
    if ! grep -qxF "M $ROOT" "$T/schema.tsv"; then
        bad "$STEM" "FIXTURE" "the schema declares no message $ROOT"
        continue
    fi
    # Line 1 is the root line, which leg 4 alone judges.
    sed 1d "$TXTPB" > "$D/expected.txtpb"

    # LEG 0: what the bytes show of their producer. Equal to protoc's own
    # encoding, they compare protoc with protoc (unless the producer is
    # declared to write protoc's bytes); a singular field written twice is
    # one protoc's decode hides (the last one wins).
    if [ "$CANONICAL_PRODUCER" != 1 ] && cmp -s "$D/in.bin" "$D/canonical.bin"; then
        bad "$STEM" "LEG 0" "$HEXN is byte for byte $CANONN, protoc's encoding: both ends of legs 1 and 3 are protoc and no producer is checked (a producer that writes protoc's bytes is declared in \`canonical_producer\`)"
    fi
    toptags "$HEX" > "$D/tags"
    awk -v root="$ROOT" '
        FNR == NR { if ($1 == "F" && $2 == root && $5 != "LABEL_REPEATED") name[$4] = $3; next }
        ($1 in name) && $2 > 1 { print name[$1] " (field " $1 ") written " $2 " times" }
    ' "$T/schema.tsv" "$D/tags" > "$D/dup"
    if [ -s "$D/dup" ]; then
        bad "$STEM" "LEG 0" "$HEXN writes a singular field of $ROOT more than once (protoc's decode shows only the last):" "$D/dup"
    fi

    # LEG 1: protoc's decode of the producer's bytes is the committed text.
    decoded=0
    if ! protoc "--decode=$ROOT" < "$D/in.bin" > "$D/decoded.txtpb" 2> "$D/err1"; then
        bad "$STEM" "LEG 1" "protoc refused to decode $HEXN as $ROOT: the bytes are not a $ROOT message" "$D/err1"
    else
        decoded=1
        if ! diff -u -L "$TXTPBN" -L "protoc --decode" "$D/expected.txtpb" "$D/decoded.txtpb" > "$D/diff1"; then
            head -n 40 "$D/diff1" > "$D/diff1.head"
            bad "$STEM" "LEG 1" "protoc's decode of $HEXN as $ROOT differs from $TXTPBN after its first line (- the .txtpb, + protoc):" "$D/diff1.head"
        fi
    fi

    # LEG 2: no field the schema does not declare, at any depth. protoc prints
    # one as a bare field number (`99: 1`, or `99 {` for a group or a
    # length-delimited value that parses as a message) and exits 0, so leg 1
    # alone passes it once the .txtpb holds the number too.
    if [ "$decoded" = 1 ] && grep -nE '^[[:space:]]*[0-9]+(:| \{)' "$D/decoded.txtpb" > "$D/unknown"; then
        head -n 20 "$D/unknown" > "$D/unknown.head"
        bad "$STEM" "LEG 2" "$HEXN carries field numbers $ROOT does not declare (protoc prints them as bare numbers):" "$D/unknown.head"
    fi

    # LEG 3: protoc's own serialization of the text is the canonical fixture.
    if ! protoc "--encode=$ROOT" < "$TXTPB" > "$D/reencoded.bin" 2> "$D/err3"; then
        bad "$STEM" "LEG 3" "protoc refused to encode $TXTPBN as $ROOT:" "$D/err3"
    elif ! cmp -s "$D/reencoded.bin" "$D/canonical.bin"; then
        tohex "$D/reencoded.bin" > "$D/reencoded.hex"
        bad "$STEM" "LEG 3" "$CANONN is not protoc's encoding of $TXTPBN ($(wc -c < "$D/canonical.bin") bytes; protoc writes $(wc -c < "$D/reencoded.bin"), as hex):" "$D/reencoded.hex"
    fi

    # LEG 4: the fixture is the message it is checked as.
    named=$(txtpb_root "$TXTPB")
    if [ -z "$named" ]; then
        head -n 1 "$TXTPB" > "$D/line1"
        bad "$STEM" "LEG 4" "$TXTPBN does not begin with the line '# proto-message: $ROOT'; its first line is:" "$D/line1"
    elif [ "$named" != "$ROOT" ]; then
        bad "$STEM" "LEG 4" "$TXTPBN names $named on its '# proto-message:' line, but the fixture is checked as $ROOT"
    fi

    # LEG 5: every enum value on the wire has a name. protoc prints a value
    # an open (proto3) enum does not declare as a number on the field
    # (`kind: 99`), exits 0, and parses the number back, so legs 1-4 all pass
    # it. Each line of the decode is placed in its message by walking it from
    # the root with the schema table; a line that cannot be placed is a
    # failure, never skipped.
    if [ "$decoded" = 1 ]; then
        awk -v root="$ROOT" '
            FNR == NR {
                if ($1 == "F") {
                    typ[$2 SUBSEP $3] = $6; tn[$2 SUBSEP $3] = $7
                    # A group is printed under its type name.
                    if ($6 == "TYPE_GROUP") { g = $7; sub(/.*\./, "", g); typ[$2 SUBSEP g] = $6; tn[$2 SUBSEP g] = $7 }
                }
                next
            }
            FNR == 1 { sp = 1; st[1] = root }
            {
                line = $0
                sub(/^ +/, "", line)
                if (line == "}") { sp--; next }
                top = st[sp]
                if (line ~ /^[A-Za-z_][A-Za-z0-9_]* \{$/) {
                    f = substr(line, 1, length(line) - 2)
                    if (top == "?") st[++sp] = "?"
                    else if ((top SUBSEP f) in tn) st[++sp] = tn[top SUBSEP f]
                    else { print "U " FNR ": `" f "` in " top; st[++sp] = "?" }
                    next
                }
                # An unknown field (leg 2), an extension or an expanded Any:
                # nothing inside is placed.
                if (line ~ / \{$/) { st[++sp] = "?"; next }
                if (top == "?" || line !~ /^[A-Za-z_][A-Za-z0-9_]*: /) next
                f = line; sub(/:.*/, "", f)
                v = line; sub(/^[^:]*: /, "", v)
                if (!((top SUBSEP f) in typ)) print "U " FNR ": `" f "` in " top
                else if (typ[top SUBSEP f] == "TYPE_ENUM" && v ~ /^-?[0-9]/) print "E " FNR ": " $0 "    (" top "." f ", " tn[top SUBSEP f] ")"
            }' "$T/schema.tsv" "$D/decoded.txtpb" > "$D/walk"
        if grep '^U ' "$D/walk" | sed 's/^U //' | head -n 20 > "$D/unplaced" && [ -s "$D/unplaced" ]; then
            bad "$STEM" "LEG 5" "cannot place these lines of protoc's decode in $ROOT with the schema's descriptor set, so their enum values are unchecked:" "$D/unplaced"
        fi
        if grep '^E ' "$D/walk" | sed 's/^E //' | head -n 20 > "$D/enums" && [ -s "$D/enums" ]; then
            bad "$STEM" "LEG 5" "$HEXN carries enum values the schema does not name (protoc prints them as numbers):" "$D/enums"
        fi
    fi

    if [ "$nbad" = "$before" ]; then
        echo "PASS $STEM $ROOT: $(wc -c < "$D/in.bin") bytes, $(wc -c < "$D/canonical.bin") canonical, $(wc -l < "$D/decoded.txtpb") lines" >> "$T/report"
    fi
done
if [ "$nbad" != 0 ]; then
    echo "proto_fixture: FAILED: $nbad failure(s) (legs: 0 producer, 1 decode == .txtpb, 2 no unknown fields, 3 encode == .canonical.hex, 4 root, 5 enum values named)" >&2
    exit 1
fi
cp "$T/report" "$OUT"
