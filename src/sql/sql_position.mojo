# =============================================================================
# sql/sql_position.mojo
#   Where in a SQL text the tokenizer or the parser stopped.
# =============================================================================
#
#   String(position_of("SELECT a\nFROM t", 9)) == "line 2, column 1"
#
# `SqlPosition` is a plain value and this module imports nothing, so a module
# that must not import the SQL front end (`sdk_exec.engine_plan`) can carry
# one. `sql.sql_parse_text.parse_sql_text` is what finds the place a text
# stopped parsing.


@fieldwise_init
struct SqlPosition(Copyable, Movable, Writable):
    """A place in a SQL text: `line` and `column`, both counted from 1. The
    column counts characters (UTF-8 code points), not bytes. Written as
    `line <L>, column <C>`."""

    var line: Int
    var column: Int

    def write_to[W: Writer](self, mut writer: W):
        writer.write("line ", self.line, ", column ", self.column)


def position_of(text: String, offset: Int) -> SqlPosition:
    """The position of the byte `offset` in `text`: the line is 1 plus the
    newlines before `offset`; the column is 1 plus the characters between the
    last newline before `offset` and `offset`. A byte that continues a
    multi-byte UTF-8 character (`0b10xxxxxx`) is not counted."""
    var src = text.as_bytes()
    var end = min(max(offset, 0), len(src))
    var line = 1
    var column = 1
    for i in range(end):
        var b = src[i]
        if b == UInt8(ord("\n")):
            line += 1
            column = 1
        elif (b & UInt8(0xC0)) != UInt8(0x80):
            column += 1
    return SqlPosition(line, column)
