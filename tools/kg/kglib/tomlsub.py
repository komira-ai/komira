"""A strict TOML subset for docs/kg.toml, parsed without dependencies (Python 3.9 has no
`tomllib`). Supported: comments, `[table]` headers, `key = value` with bare or "quoted"
keys, and values that are "basic" or 'literal' strings, integers, booleans and arrays of
those (which may span lines and end with a comma). Anything else is refused with its
line number, never guessed at.
"""
from __future__ import annotations

import re

from . import KgError

_BARE = re.compile(r"[A-Za-z0-9_-]+")
_INT = re.compile(r"[+-]?[0-9]+")
_ESC = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}


class _P:
    def __init__(self, text, name):
        self.s, self.i, self.name = text, 0, name

    def err(self, msg):
        raise KgError("%s:%d: %s" % (self.name, self.s.count("\n", 0, self.i) + 1, msg))

    def ws(self, newlines=False):
        while self.i < len(self.s):
            c = self.s[self.i]
            if c in " \t" or (newlines and c in "\r\n"):
                self.i += 1
            elif c == "#":
                while self.i < len(self.s) and self.s[self.i] != "\n":
                    self.i += 1
            else:
                break

    def eol(self):
        self.ws()
        if self.i < len(self.s) and self.s[self.i] not in "\r\n":
            self.err("unexpected %r after the value" % self.s[self.i])

    def key(self):
        if self.s.startswith('"', self.i):
            return self.string()
        m = _BARE.match(self.s, self.i)
        if not m:
            self.err("expected a key")
        self.i = m.end()
        return m.group(0)

    def string(self):
        q = self.s[self.i]
        self.i += 1
        buf = []
        while True:
            if self.i >= len(self.s) or self.s[self.i] == "\n":
                self.err("unterminated string")
            c = self.s[self.i]
            if c == q:
                self.i += 1
                return "".join(buf)
            if c == "\\" and q == '"':
                e = self.s[self.i + 1:self.i + 2]
                if e not in _ESC:
                    self.err("unsupported escape \\%s" % e)
                buf.append(_ESC[e])
                self.i += 2
                continue
            buf.append(c)
            self.i += 1

    def value(self):
        c = self.s[self.i:self.i + 1]
        if c in ('"', "'"):
            if self.s.startswith(c * 3, self.i):
                self.err("multi-line strings are not in kg's TOML subset")
            return self.string()
        if c == "[":
            self.i += 1
            arr = []
            while True:
                self.ws(newlines=True)
                if self.s.startswith("]", self.i):
                    self.i += 1
                    return arr
                v = self.value()
                if isinstance(v, list):
                    self.err("nested arrays are not in kg's TOML subset")
                arr.append(v)
                self.ws(newlines=True)
                if self.s.startswith(",", self.i):
                    self.i += 1
                elif not self.s.startswith("]", self.i):
                    self.err("expected ',' or ']' in the array")
        for word, val in (("true", True), ("false", False)):
            if self.s.startswith(word, self.i):
                self.i += len(word)
                return val
        m = _INT.match(self.s, self.i)
        if m:
            self.i = m.end()
            return int(m.group(0))
        self.err("unsupported value (kg's TOML subset: strings, integers, booleans, arrays)")


def loads(text, name="docs/kg.toml"):
    p, root = _P(text, name), {}
    table = root
    while True:
        p.ws(newlines=True)
        if p.i >= len(p.s):
            return root
        if p.s[p.i] == "[":
            if p.s.startswith("[[", p.i):
                p.err("arrays of tables are not in kg's TOML subset")
            p.i += 1
            p.ws()
            k = p.key()
            p.ws()
            if not p.s.startswith("]", p.i):
                p.err("expected ']' (dotted table names are not in kg's TOML subset)")
            p.i += 1
            if k in root:
                p.err("table [%s] is defined twice" % k)
            table = root[k] = {}
            p.eol()
            continue
        k = p.key()
        p.ws()
        if p.s.startswith(".", p.i):
            p.err("dotted keys are not in kg's TOML subset")
        if not p.s.startswith("=", p.i):
            p.err("expected '=' after key %r" % k)
        p.i += 1
        p.ws()
        if k in table:
            p.err("key %r is defined twice" % k)
        table[k] = p.value()
        p.eol()
