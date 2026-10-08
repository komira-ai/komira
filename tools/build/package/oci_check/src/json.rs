//! A JSON reader, enough for an OCI image layout (index, manifest, config).
//!
//! RFC 8259 values; a key given twice in one object is refused, so a
//! document cannot say two things about one field. Numbers are kept as text:
//! the checker compares none.

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
        let t = std::str::from_utf8(h).map_err(|_| self.err("a bad \\u escape"))?;
        let v = u32::from_str_radix(t, 16).map_err(|_| self.err("a bad \\u escape"))?;
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
}
