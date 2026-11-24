"""Walkers over expression trees."""

from __future__ import annotations

import dataclasses
from collections.abc import Iterator

from komira._ops._expr import (
    EXPR_NODES,
    Arith,
    BoolOp,
    ColRef,
    Compare,
    Lit,
    MathFn2,
    Node,
    StringFnN,
    StructField,
    UdfCall,
    When,
)


def _need_expr(node) -> None:
    if not isinstance(node, EXPR_NODES):
        raise TypeError(f"not an expression node: {type(node).__name__}")


def children(node) -> tuple[Node, ...]:
    """The direct children of `node`, in field order (a `When`: each condition, its result, then the default)."""
    _need_expr(node)
    if isinstance(node, (ColRef, Lit)):
        return ()
    if isinstance(node, (Compare, Arith, BoolOp, MathFn2)):
        return (node.left, node.right)
    if isinstance(node, When):
        out = []
        for condition, result in node.cases:
            out.append(condition)
            out.append(result)
        out.append(node.default)
        return tuple(out)
    if isinstance(node, (StringFnN, UdfCall)):
        return node.args
    if isinstance(node, StructField):
        return (node.parent,)
    return (node.child,)


def walk(node) -> Iterator[Node]:
    """Every node of the tree, parents before children, children in order."""
    _need_expr(node)
    yield node
    for child in children(node):
        yield from walk(child)


def column_refs(node) -> tuple[ColRef, ...]:
    """Every `ColRef` in pre-order, repeats kept."""
    return tuple(n for n in walk(node) if isinstance(n, ColRef))


def referenced_columns(node) -> frozenset[str]:
    """The names of the columns the tree reads."""
    return frozenset(ref.name for ref in column_refs(node))


def _rebuild(node, new):
    if isinstance(node, (Compare, Arith, BoolOp, MathFn2)):
        return dataclasses.replace(node, left=new[0], right=new[1])
    if isinstance(node, When):
        pairs = tuple((new[i], new[i + 1]) for i in range(0, len(new) - 1, 2))
        return When(pairs, new[-1])
    if isinstance(node, (StringFnN, UdfCall)):
        return dataclasses.replace(node, args=new)
    if isinstance(node, StructField):
        return dataclasses.replace(node, parent=new[0])
    return dataclasses.replace(node, child=new[0])


def substitute(node, subs: dict[str, Node]) -> Node:
    """A tree with each side-less `ColRef` named in `subs` replaced by its entry.

    A node none of whose descendants changed is returned as the same object.
    """
    _need_expr(node)
    if isinstance(node, ColRef):
        if node.side is None and node.name in subs:
            return subs[node.name]
        return node
    old = children(node)
    new = tuple(substitute(child, subs) for child in old)
    if all(a is b for a, b in zip(old, new)):
        return node
    return _rebuild(node, new)


def leftmost_column(node) -> str | None:
    """The name of the first `ColRef` in pre-order, or None when there is none."""
    for n in walk(node):
        if isinstance(n, ColRef):
            return n.name
    return None
