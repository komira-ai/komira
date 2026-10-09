//! A JSON reader for bench reports (RFC 8259): objects keep their keys in
//! the order written, and a key written twice is an error, as are NaN,
//! infinities, trailing input and a nesting deeper than 64.

#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    Str(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    /// The kind of the value, as an error message names it.
    pub fn kind(&self) -> &'static str {
        match self {
            Json::Null => "null",
            Json::Bool(_) => "a boolean",
            Json::Number(_) => "a number",
            Json::Str(_) => "a string",
            Json::Array(_) => "an array",
            Json::Object(_) => "an object",
        }
    }
}

const MAX_DEPTH: usize = 64;

/// Parses one JSON document; the error names the byte offset.
pub fn parse(input: &str) -> Result<Json, String> {
    let mut p = Parser { s: input.as_bytes(), i: 0 };
    p.ws();
    let v = p.value(0)?;
    p.ws();
    if p.i != p.s.len() {
        return Err(p.err("trailing input after the value"));
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn err(&self, what: &str) -> String {
        format!("byte {}: {}", self.i, what)
    }

    fn ws(&mut self) {
        while self.i < self.s.len() && matches!(self.s[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn lit(&mut self, word: &str, v: Json) -> Result<Json, String> {
        if self.s[self.i..].starts_with(word.as_bytes()) {
            self.i += word.len();
            Ok(v)
        } else {
            Err(self.err("not a JSON value"))
        }
    }

    fn value(&mut self, depth: usize) -> Result<Json, String> {
        if depth > MAX_DEPTH {
            return Err(self.err("nesting deeper than 64"));
        }
        match self.peek() {
            None => Err(self.err("unexpected end of input")),
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(Json::Str(self.string()?)),
            Some(b't') => self.lit("true", Json::Bool(true)),
            Some(b'f') => self.lit("false", Json::Bool(false)),
            Some(b'n') => self.lit("null", Json::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.err("not a JSON value")),
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, String> {
        self.i += 1;
        let mut out: Vec<(String, Json)> = Vec::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(Json::Object(out));
        }
        loop {
            self.ws();
            if self.peek() != Some(b'"') {
                return Err(self.err("expected a key"));
            }
            let key = self.string()?;
            if out.iter().any(|(k, _)| *k == key) {
                return Err(self.err(&format!("key '{}' written twice", key)));
            }
            self.ws();
            if self.peek() != Some(b':') {
                return Err(self.err("expected ':'"));
            }
            self.i += 1;
            self.ws();
            let v = self.value(depth + 1)?;
            out.push((key, v));
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b'}') => {
                    self.i += 1;
                    return Ok(Json::Object(out));
                }
                _ => return Err(self.err("expected ',' or '}'")),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, String> {
        self.i += 1;
        let mut out = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(Json::Array(out));
        }
        loop {
            self.ws();
            out.push(self.value(depth + 1)?);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b']') => {
                    self.i += 1;
                    return Ok(Json::Array(out));
                }
                _ => return Err(self.err("expected ',' or ']'")),
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let h = self.s.get(self.i..self.i + 4).ok_or_else(|| self.err("short \\u escape"))?;
        let t = std::str::from_utf8(h).map_err(|_| self.err("bad \\u escape"))?;
        let v = u32::from_str_radix(t, 16).map_err(|_| self.err("bad \\u escape"))?;
        self.i += 4;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, String> {
        self.i += 1;
        let mut out = String::new();
        loop {
            let start = self.i;
            while self.i < self.s.len() && !matches!(self.s[self.i], b'"' | b'\\' | 0..=0x1f) {
                self.i += 1;
            }
            // The input is a &str, and the run stops only at ASCII bytes.
            out.push_str(std::str::from_utf8(&self.s[start..self.i]).expect("utf-8 input"));
            match self.peek() {
                None => return Err(self.err("unterminated string")),
                Some(b'"') => {
                    self.i += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.i += 1;
                    let e = self.peek().ok_or_else(|| self.err("unterminated string"))?;
                    self.i += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let mut c = self.hex4()?;
                            if (0xd800..0xdc00).contains(&c) {
                                if !self.s[self.i..].starts_with(b"\\u") {
                                    return Err(self.err("unpaired surrogate"));
                                }
                                self.i += 2;
                                let lo = self.hex4()?;
                                if !(0xdc00..0xe000).contains(&lo) {
                                    return Err(self.err("unpaired surrogate"));
                                }
                                c = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
                            }
                            out.push(char::from_u32(c).ok_or_else(|| self.err("unpaired surrogate"))?);
                        }
                        _ => return Err(self.err("bad escape")),
                    }
                }
                Some(_) => return Err(self.err("control character in a string")),
            }
        }
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        let digits = |p: &mut Self| {
            let s = p.i;
            while p.peek().is_some_and(|c| c.is_ascii_digit()) {
                p.i += 1;
            }
            p.i - s
        };
        let int_start = self.i;
        if digits(self) == 0 {
            return Err(self.err("expected a digit"));
        }
        if self.s[int_start] == b'0' && self.i - int_start > 1 {
            return Err(self.err("leading zero"));
        }
        if self.peek() == Some(b'.') {
            self.i += 1;
            if digits(self) == 0 {
                return Err(self.err("expected a digit after '.'"));
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.i += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.i += 1;
            }
            if digits(self) == 0 {
                return Err(self.err("expected a digit in the exponent"));
            }
        }
        let text = std::str::from_utf8(&self.s[start..self.i]).expect("ascii");
        let v: f64 = text.parse().map_err(|_| self.err("bad number"))?;
        if !v.is_finite() {
            return Err(self.err("number out of range"));
        }
        Ok(Json::Number(v))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_and_order() {
        let v = parse(" {\"b\": [1, -2.5e1, true, false, null], \"a\": \"x\\n\\u00e9\\ud83d\\ude00\"} ").unwrap();
        let Json::Object(o) = v else { panic!("not an object") };
        assert_eq!(o[0].0, "b");
        assert_eq!(o[1].0, "a");
        assert_eq!(
            o[0].1,
            Json::Array(vec![Json::Number(1.0), Json::Number(-25.0), Json::Bool(true), Json::Bool(false), Json::Null])
        );
        assert_eq!(o[1].1, Json::Str("x\n\u{e9}\u{1f600}".to_string()));
        assert_eq!(parse("{}").unwrap(), Json::Object(vec![]));
        assert_eq!(parse("[ ]").unwrap(), Json::Array(vec![]));
        assert_eq!(parse("\"\\\"\\\\\\/\\b\\f\\r\\t\"").unwrap(), Json::Str("\"\\/\u{8}\u{c}\r\t".into()));
        assert_eq!(parse("0").unwrap(), Json::Number(0.0));
        assert_eq!(parse("1E+2").unwrap(), Json::Number(100.0));
    }

    #[test]
    fn refusals() {
        for (doc, why) in [
            ("{\"a\":1,\"a\":2}", "byte 10: key 'a' written twice"),
            ("NaN", "byte 0: not a JSON value"),
            ("Infinity", "byte 0: not a JSON value"),
            ("1e999", "byte 5: number out of range"),
            ("{} x", "byte 3: trailing input after the value"),
            ("01", "byte 2: leading zero"),
            ("1.", "byte 2: expected a digit after '.'"),
            ("1e", "byte 2: expected a digit in the exponent"),
            ("-", "byte 1: expected a digit"),
            ("[1 2]", "byte 3: expected ',' or ']'"),
            ("{\"a\" 1}", "byte 5: expected ':'"),
            ("{\"a\":1 \"b\"}", "byte 7: expected ',' or '}'"),
            ("{1:2}", "byte 1: expected a key"),
            ("\"a", "byte 2: unterminated string"),
            ("\"a\\", "byte 3: unterminated string"),
            ("\"\\x\"", "byte 3: bad escape"),
            ("\"\\u12\"", "byte 3: short \\u escape"),
            ("\"\\uzzzz\"", "byte 3: bad \\u escape"),
            ("\"\\ud800x\"", "byte 7: unpaired surrogate"),
            ("\"\\ud800\\u0041\"", "byte 13: unpaired surrogate"),
            ("\"\\udc00\"", "byte 7: unpaired surrogate"),
            ("\"\u{1}\"", "byte 1: control character in a string"),
            ("tru", "byte 0: not a JSON value"),
            ("", "byte 0: unexpected end of input"),
            ("@", "byte 0: not a JSON value"),
        ] {
            assert_eq!(parse(doc), Err(why.to_string()), "{doc}");
        }
        let deep = "[".repeat(66) + &"]".repeat(66);
        assert_eq!(parse(&deep), Err("byte 65: nesting deeper than 64".to_string()));
        let ok = "[".repeat(65) + &"]".repeat(65);
        assert!(parse(&ok).is_ok());
    }

    #[test]
    fn kinds() {
        let kinds: Vec<&str> = ["null", "true", "1", "\"s\"", "[]", "{}"].iter().map(|d| parse(d).unwrap().kind()).collect();
        assert_eq!(kinds, ["null", "a boolean", "a number", "a string", "an array", "an object"]);
    }
}
