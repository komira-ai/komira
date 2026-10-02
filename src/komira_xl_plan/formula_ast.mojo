# =============================================================================
# formula_ast.mojo — the parsed formula AST (arena / index-based)
# =============================================================================
#
# Representation: an ARENA of nodes referenced by Int index — NOT recursive
# OwnedPointer children. Children are node indices into `FormulaAst.nodes`.
# This sidesteps Mojo's recursive-type constraints entirely, is gap6-trivial
# (POD-ish nodes, no heap-owning pointer fields), and makes the evaluator a
# simple index recursion. A CALL node's args are `List[Int]` (arg node indices);
# a BINOP holds `left`/`right` indices; a UNARY holds `left`.
# =============================================================================


# --- Node tags. ---
comptime NODE_NUMBER: UInt8 = 0   # numeric literal (num)
comptime NODE_STRING: UInt8 = 1   # quoted-string literal (text)
comptime NODE_BOOL: UInt8 = 2     # TRUE / FALSE (bool_val)
comptime NODE_ERROR: UInt8 = 3    # error literal #DIV/0! etc (error_code)
comptime NODE_NAME: UInt8 = 4     # bare identifier -> a binding lookup (text)
comptime NODE_CALL: UInt8 = 5     # function call: name=text, args=arg indices
comptime NODE_BINOP: UInt8 = 6    # binary op: op, left, right
comptime NODE_UNARY: UInt8 = 7    # unary op: op, left


# --- Binary/unary operator ids. ---
comptime OP_ADD: UInt8 = 0
comptime OP_SUB: UInt8 = 1
comptime OP_MUL: UInt8 = 2
comptime OP_DIV: UInt8 = 3
comptime OP_CONCAT: UInt8 = 4   # &
comptime OP_EQ: UInt8 = 5       # =
comptime OP_NE: UInt8 = 6       # <>
comptime OP_LT: UInt8 = 7       # <
comptime OP_LE: UInt8 = 8       # <=
comptime OP_GT: UInt8 = 9       # >
comptime OP_GE: UInt8 = 10      # >=
comptime OP_NEG: UInt8 = 11     # unary minus


@fieldwise_init
struct FormulaNode(Copyable, Movable):
    """One AST node. Only the fields relevant to `tag` are meaningful.

    Children are Int indices into the owning `FormulaAst.nodes` arena.
    """
    var tag: UInt8
    var num: Float64          # NODE_NUMBER
    var text: String          # NODE_STRING / NODE_NAME / NODE_CALL (fn name)
    var bool_val: Bool        # NODE_BOOL
    var error_code: UInt8     # NODE_ERROR
    var op: UInt8             # NODE_BINOP / NODE_UNARY
    var left: Int             # NODE_BINOP left / NODE_UNARY child
    var right: Int            # NODE_BINOP right
    var args: List[Int]       # NODE_CALL arg node indices


struct FormulaAst(Copyable, Movable):
    """An arena of AST nodes plus the root index. Built by the parser."""

    var nodes: List[FormulaNode]
    var root: Int

    def __init__(out self):
        self.nodes = List[FormulaNode]()
        self.root = -1

    def copy(self) -> Self:
        var out = Self()
        out.nodes = self.nodes.copy()
        out.root = self.root
        return out^

    def add(mut self, var node: FormulaNode) -> Int:
        """Append a node; return its arena index."""
        var idx = len(self.nodes)
        self.nodes.append(node^)
        return idx

    @always_inline
    def get(self, idx: Int) -> FormulaNode:
        return self.nodes[idx].copy()


# --- Node factories (keep the fieldwise-init positional order in ONE place). ---

@always_inline
def node_number(v: Float64) -> FormulaNode:
    return FormulaNode(NODE_NUMBER, v, String(""), False, 0, 0, -1, -1, List[Int]())


@always_inline
def node_string(v: String) -> FormulaNode:
    return FormulaNode(NODE_STRING, 0.0, v, False, 0, 0, -1, -1, List[Int]())


@always_inline
def node_bool(v: Bool) -> FormulaNode:
    return FormulaNode(NODE_BOOL, 0.0, String(""), v, 0, 0, -1, -1, List[Int]())


@always_inline
def node_error(code: UInt8) -> FormulaNode:
    return FormulaNode(NODE_ERROR, 0.0, String(""), False, code, 0, -1, -1, List[Int]())


@always_inline
def node_name(name: String) -> FormulaNode:
    return FormulaNode(NODE_NAME, 0.0, name, False, 0, 0, -1, -1, List[Int]())


@always_inline
def node_call(name: String, var args: List[Int]) -> FormulaNode:
    return FormulaNode(NODE_CALL, 0.0, name, False, 0, 0, -1, -1, args^)


@always_inline
def node_binop(op: UInt8, left: Int, right: Int) -> FormulaNode:
    return FormulaNode(NODE_BINOP, 0.0, String(""), False, 0, op, left, right, List[Int]())


@always_inline
def node_unary(op: UInt8, child: Int) -> FormulaNode:
    return FormulaNode(NODE_UNARY, 0.0, String(""), False, 0, op, child, -1, List[Int]())
