#!/usr/bin/env python3
"""Builds chessuite/repertoire_data.lua, the opening courses of the opening
trainer, from tabia's opening data (https://github.com/daxaur/tabia,
src/data/*.js, MIT, (c) 2026 dax). The data files are read as data: their
object literals are parsed here, nothing of them is run.

Usage, from the plugin folder:
    git clone --depth 1 https://github.com/daxaur/tabia /tmp/tabia
    python3 tools/build-repertoire.py /tmp/tabia > chessuite/repertoire_data.lua
"""
import os
import re
import sys

# --- a small reader for JavaScript object literals -------------------------

TOKEN = re.compile(r"""
    (?P<ws>\s+|//[^\n]*|/\*.*?\*/)
  | (?P<str>'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`)
  | (?P<num>-?\d+(?:\.\d+)?)
  | (?P<id>[A-Za-z_$][\w$]*)
  | (?P<p>[{}\[\]:,;=])
""", re.S | re.X)


def tokens(text):
    pos, out = 0, []
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise ValueError("unexpected %r at %d" % (text[pos:pos + 20], pos))
        pos = m.end()
        kind = m.lastgroup
        if kind != "ws":
            out.append((kind, m.group(kind)))
    return out


def unquote(s):
    body = s[1:-1]
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)


class Parser:
    def __init__(self, toks, consts):
        self.t, self.i, self.consts = toks, 0, consts

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def next(self):
        tok = self.peek()
        self.i += 1
        return tok

    def expect(self, value):
        kind, v = self.next()
        if v != value:
            raise ValueError("expected %s, got %s" % (value, v))

    def value(self):
        kind, v = self.next()
        if v == "{":
            obj = {}
            while self.peek()[1] != "}":
                k_kind, key = self.next()
                key = unquote(key) if k_kind == "str" else key
                self.expect(":")
                obj[key] = self.value()
                if self.peek()[1] == ",":
                    self.next()
            self.next()
            return obj
        if v == "[":
            arr = []
            while self.peek()[1] != "]":
                arr.append(self.value())
                if self.peek()[1] == ",":
                    self.next()
            self.next()
            return arr
        if kind == "str":
            return unquote(v)
        if kind == "num":
            return float(v) if "." in v else int(v)
        if v in ("true", "false"):
            return v == "true"
        if v == "null":
            return None
        if v in self.consts:
            return self.consts[v]
        raise ValueError("cannot read %s" % v)


def read_repertoire(path):
    toks = tokens(open(path, encoding="utf-8").read())
    consts, i = {}, 0
    rep = None
    while i < len(toks):
        if toks[i] == ("id", "const") and i + 3 < len(toks) and toks[i + 2] == ("p", "="):
            name = toks[i + 1][1]
            p = Parser(toks[i + 3:], consts)
            val = p.value()
            if name == "repertoire":
                rep = val
            else:
                consts[name] = val
            i += 3 + p.i
        else:
            i += 1
    return rep


def read_index(path):
    text = open(path, encoding="utf-8").read()
    order = re.search(r"openings\s*=\s*\[([^\]]*)\]", text).group(1)
    order = [x.strip() for x in order.split(",") if x.strip()]
    imports = dict(re.findall(r"import\s*\{\s*repertoire\s+as\s+(\w+)\s*\}\s*from\s*'\./(\w+)\.js", text))
    cats = dict(re.findall(r"(\w+):\s*'(\w+)'", re.search(r"CATEGORY\s*=\s*\{([^}]*)\}", text).group(1)))
    categories = re.findall(r"'(\w+)'", re.search(r"CATEGORIES\s*=\s*\[([^\]]*)\]", text).group(1))
    return [(name, imports[name]) for name in order], cats, categories


# --- Lua output -----------------------------------------------------------

def lua(v, indent=""):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(v, list):
        return "{ " + ", ".join(lua(x, indent) for x in v) + " }"
    inner = indent + " "
    parts = []
    for k, x in v.items():
        key = k if re.match(r"^[A-Za-z_]\w*$", k) else "[" + lua(k) + "]"
        parts.append("%s%s = %s," % (inner, key, lua(x, inner)))
    return "{\n" + "\n".join(parts) + "\n" + indent + "}"


def main(root):
    data_dir = os.path.join(root, "src", "data")
    order, cats, categories = read_index(os.path.join(data_dir, "index.js"))
    openings = []
    for name, module in order:
        rep = read_repertoire(os.path.join(data_dir, module + ".js"))
        rep["category"] = rep.get("category") or cats.get(rep["id"], "Other")
        openings.append(rep)
    nlines = sum(len(o["lines"]) for o in openings)
    print("-- Generated by tools/build-repertoire.py from tabia's opening data")
    print("-- (https://github.com/daxaur/tabia, MIT, (c) 2026 dax): %d openings, %d lines. Do not edit."
          % (len(openings), nlines))
    print("return " + lua({"categories": categories, "openings": openings}))


main(sys.argv[1])
