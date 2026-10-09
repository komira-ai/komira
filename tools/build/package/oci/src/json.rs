//! A JSON reader and writer, enough for an OCI image layout (index,
//! manifest, config).
//!
//! RFC 8259 values; a key given twice in one object is refused, so a
//! document cannot say two things about one field. Numbers are kept as text
//! and written back as read. The writer is compact, with every object's keys
//! in sorted order, so a value has one spelling.

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Num(String),
    Str(String),
    Arr(Vec<Value>),
    Obj(Vec<(String, Value)>),
}

impl Value {
    /// The member `key` of an object; None for a missing key or a non-object.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Obj(m) => m.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_arr(&self) -> Option<&[Value]> {
        match self {
            Value::Arr(a) => Some(a),
            _ => None,
        }
    }

    /// Sets the member `key` of an object, replacing one already there.
    pub fn set(&mut self, key: &str, v: Value) -> Result<(), String> {
        match self {
            Value::Obj(m) => {
                match m.iter_mut().find(|(k, _)| k == key) {
                    Some(slot) => slot.1 = v,
                    None => m.push((key.to_string(), v)),
                }
                Ok(())
            }
            _ => Err(format!("cannot set `{}`: not an object", key)),
        }
    }

    /// Removes the member `key` of an object, if there.
    pub fn remove(&mut self, key: &str) {
        if let Value::Obj(m) = self {
            m.retain(|(k, _)| k != key);
        }
    }

    /// Compact JSON, every object's keys in sorted order.
    pub fn to_json(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        match self {
            Value::Null => out.push_str("null"),
            Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Value::Num(n) => out.push_str(n),
            Value::Str(s) => quote(s, out),
            Value::Arr(a) => {
                out.push('[');
                for (i, v) in a.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    v.write(out);
                }
                out.push(']');
            }
            Value::Obj(m) => {
                let mut members: Vec<&(String, Value)> = m.iter().collect();
                members.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
                out.push('{');
                for (i, (k, v)) in members.into_iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    quote(k, out);
                    out.push(':');
                    v.write(out);
                }
                out.push('}');
            }
        }
    }
}

/// `s` as a JSON string: `"` and `\` escaped, control characters as their
/// short escape or a four-digit one, everything else as is (UTF-8).
fn quote(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\x08' => out.push_str("\\b"),
            '\x0c' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

const MAX_DEPTH: usize = 64;

pub fn parse(text: &[u8]) -> Result<Value, String> {
    let mut p = Parser { s: text, i: 0, depth: 0 };
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i != p.s.len() {
        return Err(p.err("bytes after the value"));
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
    depth: usize,
}

impl Parser<'_> {
    fn err(&self, what: &str) -> String {
        format!("JSON: {} at byte {}", what, self.i)
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }

    fn eat(&mut self, c: u8) -> Result<(), String> {
        if self.peek() == Some(c) {
            self.i += 1;
            Ok(())
        } else {
            Err(self.err(&format!("expected `{}`", c as char)))
        }
    }

    fn word(&mut self, w: &str, v: Value) -> Result<Value, String> {
        if self.s[self.i..].starts_with(w.as_bytes()) {
            self.i += w.len();
            Ok(v)
        } else {
            Err(self.err("not a JSON literal"))
        }
    }

    fn value(&mut self) -> Result<Value, String> {
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Ok(Value::Str(self.string()?)),
            Some(b't') => self.word("true", Value::Bool(true)),
            Some(b'f') => self.word("false", Value::Bool(false)),
            Some(b'n') => self.word("null", Value::Null),
            Some(c) if c == b'-' || c.is_ascii_digit() => self.number(),
            _ => Err(self.err("expected a value")),
        }
    }

    fn enter(&mut self, open: u8) -> Result<(), String> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self.err("nested too deep"));
        }
        self.eat(open)?;
        self.ws();
        Ok(())
    }

    /// After a member or element: true at the closing `close`, false after a `,`.
    fn next(&mut self, close: u8) -> Result<bool, String> {
        self.ws();
        match self.peek() {
            Some(b',') => {
                self.i += 1;
                self.ws();
                Ok(false)
            }
            Some(c) if c == close => {
                self.i += 1;
                self.depth -= 1;
                Ok(true)
            }
            _ => Err(self.err(&format!("expected `,` or `{}`", close as char))),
        }
    }

    fn object(&mut self) -> Result<Value, String> {
        self.enter(b'{')?;
        let mut m: Vec<(String, Value)> = Vec::new();
        if self.peek() == Some(b'}') {
            self.i += 1;
            self.depth -= 1;
            return Ok(Value::Obj(m));
        }
        loop {
            if self.peek() != Some(b'"') {
                return Err(self.err("expected a key"));
            }
            let k = self.string()?;
            if m.iter().any(|(q, _)| *q == k) {
                return Err(self.err(&format!("key `{}` given twice", k)));
            }
            self.ws();
            self.eat(b':')?;
            self.ws();
            let v = self.value()?;
            m.push((k, v));
            if self.next(b'}')? {
                return Ok(Value::Obj(m));
            }
        }
    }

    fn array(&mut self) -> Result<Value, String> {
        self.enter(b'[')?;
        let mut a = Vec::new();
        if self.peek() == Some(b']') {
            self.i += 1;
            self.depth -= 1;
            return Ok(Value::Arr(a));
        }
        loop {
            a.push(self.value()?);
            if self.next(b']')? {
                return Ok(Value::Arr(a));
            }
        }
    }

    fn digits(&mut self) -> usize {
        let at = self.i;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.i += 1;
        }
        self.i - at
    }

    fn number(&mut self) -> Result<Value, String> {
        let at = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        if self.peek() == Some(b'0') {
            self.i += 1;
        } else if self.digits() == 0 {
            return Err(self.err("a number without digits"));
        }
        if self.peek() == Some(b'.') {
            self.i += 1;
            if self.digits() == 0 {
                return Err(self.err("no digits after `.`"));
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.i += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.i += 1;
            }
            if self.digits() == 0 {
                return Err(self.err("no digits in the exponent"));
            }
        }
        Ok(Value::Num(String::from_utf8_lossy(&self.s[at..self.i]).into_owned()))
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let h = self.s.get(self.i..self.i + 4).ok_or_else(|| self.err("a short \\u escape"))?;
        // Four hex digits, nothing else: from_str_radix would take a sign.
        let mut v = 0;
        for &b in h {
            v = v * 16 + (b as char).to_digit(16).ok_or_else(|| self.err("a bad \\u escape"))?;
        }
        self.i += 4;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, String> {
        self.eat(b'"')?;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let c = self.peek().ok_or_else(|| self.err("an unterminated string"))?;
            self.i += 1;
            match c {
                b'"' => break,
                b'\\' => {
                    let e = self.peek().ok_or_else(|| self.err("an unterminated escape"))?;
                    self.i += 1;
                    let ch = match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                if !self.s[self.i..].starts_with(b"\\u") {
                                    return Err(self.err("a lone high surrogate"));
                                }
                                self.i += 2;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return Err(self.err("a bad low surrogate"));
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else {
                                hi
                            };
                            char::from_u32(cp).ok_or_else(|| self.err("a lone surrogate"))?
                        }
                        _ => return Err(self.err("an unknown escape")),
                    };
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                0..=0x1f => return Err(self.err("a control character in a string")),
                _ => out.push(c),
            }
        }
        String::from_utf8(out).map_err(|_| self.err("a string that is not UTF-8"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(x: &str) -> Value {
        Value::Str(x.to_string())
    }

    #[test]
    fn reads_an_oci_manifest_shape() {
        let v = parse(br#" {"config":{"digest":"sha256:ab","size":12},"layers":[{"digest":"d1"},{"digest":"d2"}],"n":-1.5e+3,"t":true,"z":null} "#).unwrap();
        assert_eq!(v.get("config").and_then(|c| c.get("digest")), Some(&s("sha256:ab")));
        let l: Vec<_> = v.get("layers").unwrap().as_arr().unwrap().iter().map(|d| d.get("digest").unwrap().as_str().unwrap()).collect();
        assert_eq!(l, ["d1", "d2"]);
        assert_eq!(v.get("n"), Some(&Value::Num("-1.5e+3".into())));
        assert_eq!(v.get("t"), Some(&Value::Bool(true)));
        assert_eq!(v.get("z"), Some(&Value::Null));
        assert_eq!(v.get("missing"), None);
    }

    #[test]
    fn decodes_escapes_and_surrogate_pairs() {
        assert_eq!(parse(br#""a\"\\\/\n\u00e9\ud83d\ude00""#).unwrap(), s("a\"\\/\n\u{e9}\u{1F600}"));
    }

    #[test]
    fn writes_compact_with_sorted_keys_and_reads_it_back() {
        let n = |x: &str| Value::Num(x.into());
        let mut v = Value::Obj(vec![
            ("z".into(), Value::Arr(vec![n("1"), n("-2.5e3"), Value::Bool(true), Value::Null])),
            ("a".into(), Value::Obj(vec![("y".into(), s("q\"\\\n\x01/")), ("b".into(), Value::Obj(vec![]))])),
            ("M".into(), s("x")),
        ]);
        let u0001: String = ['\\', 'u', '0', '0', '0', '1'].iter().collect();
        let want = format!("{{\"M\":\"x\",\"a\":{{\"b\":{{}},\"y\":\"q\\\"\\\\\\n{}/\"}},\"z\":[1,-2.5e3,true,null]}}", u0001);
        assert_eq!(v.to_json(), want);
        assert_eq!(parse(want.as_bytes()).unwrap().to_json(), want);
        v.set("M", s("y")).unwrap();
        v.set("new", n("2")).unwrap();
        v.remove("z");
        assert!(v.to_json().starts_with("{\"M\":\"y\",\"a\":"), "{}", v.to_json());
        assert!(v.to_json().ends_with("},\"new\":2}"), "{}", v.to_json());
        assert!(s("x").set("k", Value::Null).is_err());
        // One spelling: lower-case hex below 0x20, DEL as it is.
        assert_eq!(s("\x1f\x7f").to_json(), "\"\\u001f\x7f\"");
    }

    #[test]
    fn refuses_what_is_not_json() {
        for bad in [
            &br#"{"a":1,"a":2}"#[..],
            br#"{"a":1,}"#,
            br#"[1 2]"#,
            br#""\ud83d""#,
            br#""\x""#,
            b"\"a\nb\"",
            br#"01"#,
            br#"1."#,
            br#"{"a":1} x"#,
            br#"tru"#,
            br#""open"#,
            b"",
        ] {
            assert!(parse(bad).is_err(), "accepted {:?}", String::from_utf8_lossy(bad));
        }
        let deep = "[".repeat(65) + &"]".repeat(65);
        assert!(parse(deep.as_bytes()).is_err());
        let ok = "[".repeat(64) + &"]".repeat(64);
        assert!(parse(ok.as_bytes()).is_ok());
    }

    #[test]
    fn each_refusal_names_its_reason() {
        let deep = "[".repeat(65) + &"]".repeat(65);
        for (bad, why) in [
            (&br#"{"a":1} x"#[..], "bytes after the value"),
            (br#"{"a" 1}"#, "expected `:`"),
            (br#"tru"#, "not a JSON literal"),
            (br#"fals"#, "not a JSON literal"),
            (br#"nul"#, "not a JSON literal"),
            (br#"x"#, "expected a value"),
            (b"", "expected a value"),
            (br#"[1,]"#, "expected a value"),
            (br#"[1 2]"#, "expected `,` or `]`"),
            (br#"{"a":1 "b":2}"#, "expected `,` or `}`"),
            (br#"{1:2}"#, "expected a key"),
            (br#"{"a":1,"a":2}"#, "key `a` given twice"),
            (br#"-"#, "a number without digits"),
            (br#"-x"#, "a number without digits"),
            (br#"1."#, "no digits after `.`"),
            (br#"1e"#, "no digits in the exponent"),
            (br#"1e+"#, "no digits in the exponent"),
            (br#""\u12""#, "a short \\u escape"),
            (br#""\u12G4""#, "a bad \\u escape"),
            // Four bytes that are not UTF-8, and a sign before three hex digits.
            (b"\"\\u\xff\xff\xff\xff\"", "a bad \\u escape"),
            (br#""\u+041""#, "a bad \\u escape"),
            (br#""\u-041""#, "a bad \\u escape"),
            (br#""\ud83d\u+e00""#, "a bad \\u escape"),
            (br#""\ud83d""#, "a lone high surrogate"),
            (br#""\ud83dx""#, "a lone high surrogate"),
            (br#""\ud83d\u0041""#, "a bad low surrogate"),
            (br#""\ud800\ue000""#, "a bad low surrogate"),
            (br#""\ud800\udbff""#, "a bad low surrogate"),
            (br#""\udc00""#, "a lone surrogate"),
            (br#""\x""#, "an unknown escape"),
            (b"\"a\x1fb\"", "a control character in a string"),
            (b"\"\x00\"", "a control character in a string"),
            (b"\"\xff\"", "a string that is not UTF-8"),
            (br#""open"#, "an unterminated string"),
            (br#""a\"#, "an unterminated escape"),
            (deep.as_bytes(), "nested too deep"),
        ] {
            let e = parse(bad).unwrap_err();
            assert!(e.starts_with(&format!("JSON: {} at byte ", why)), "{:?}: {}", String::from_utf8_lossy(bad), e);
        }
        // Each boundary's first accepted value.
        assert_eq!(parse(b"\"\x20~\"").unwrap(), s(" ~"));
        assert_eq!(parse(br#""\ud800\udc00\udbff\udfff\ue000\ud7ff""#).unwrap(), s("\u{10000}\u{10FFFF}\u{E000}\u{D7FF}"));
        for n in ["0", "-0", "0.5", "1e5", "1E-5", "12.25e+3"] {
            assert_eq!(parse(n.as_bytes()).unwrap(), Value::Num(n.into()));
        }
        assert_eq!(parse(b" \t\r\n[ ] ").unwrap(), Value::Arr(vec![]));
        assert_eq!(parse(br#"{ "a" : [ 1 , { } ] }"#).unwrap().to_json(), r#"{"a":[1,{}]}"#);
    }

    #[test]
    fn depth_counts_nesting_not_containers() {
        // 65 siblings of each shape in one array are nested two deep; each
        // closing bracket, of an empty container too, gives its level back.
        for one in ["[1]", r#"{"a":1}"#, "{}", "[]"] {
            let doc = format!("[{}]", vec![one; 65].join(","));
            assert_eq!(parse(doc.as_bytes()).unwrap().as_arr().map(|a| a.len()), Some(65), "{}", one);
        }
        // The deepest level reached twice, one after the other.
        let d63 = "[".repeat(63) + &"]".repeat(63);
        assert!(parse(format!("[{},{}]", d63, d63).as_bytes()).is_ok());
        let d64 = "[".repeat(64) + &"]".repeat(64);
        assert!(parse(format!("[{}]", d64).as_bytes()).unwrap_err().contains("nested too deep"));
    }
}
