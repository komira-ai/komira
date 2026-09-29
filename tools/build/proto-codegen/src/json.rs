//! A small, dependency-free JSON parser that keeps each object's keys in
//! document order.

use std::collections::BTreeMap;

#[derive(Clone, Debug, Default)]
pub struct JsonObject {
    /// Keys in DOCUMENT order, first-occurrence wins.
    order: Vec<String>,
    map: BTreeMap<String, Json>,
}

impl JsonObject {
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert a key. A repeated key keeps its FIRST document position (and
    /// takes the LAST value, matching `BTreeMap::insert` and the "last one
    /// wins" convention every JSON reader uses for duplicate keys).
    pub fn insert(&mut self, key: String, value: Json) -> Option<Json> {
        let prev = self.map.insert(key.clone(), value);
        if prev.is_none() {
            self.order.push(key);
        }
        prev
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        self.map.get(key)
    }

    pub fn contains_key(&self, key: &str) -> bool {
        self.map.contains_key(key)
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    pub fn iter(&self) -> std::collections::btree_map::Iter<'_, String, Json> {
        self.map.iter()
    }

    /// Iterate in DOCUMENT order — what the AWS front-end needs for a
    /// structure's `members` (XML child-element order).
    pub fn iter_declared(&self) -> impl Iterator<Item = (&String, &Json)> {
        self.order
            .iter()
            .map(move |k| (k, self.map.get(k).expect("order and map agree by construction")))
    }

    pub fn keys(&self) -> std::collections::btree_map::Keys<'_, String, Json> {
        self.map.keys()
    }

    /// The keys in DOCUMENT order.
    pub fn keys_declared(&self) -> impl Iterator<Item = &String> {
        self.order.iter()
    }
}

impl PartialEq for JsonObject {
    fn eq(&self, other: &Self) -> bool {
        self.map == other.map
    }
}

impl<'a> IntoIterator for &'a JsonObject {
    type Item = (&'a String, &'a Json);
    type IntoIter = std::collections::btree_map::Iter<'a, String, Json>;

    fn into_iter(self) -> Self::IntoIter {
        self.map.iter()
    }
}

impl FromIterator<(String, Json)> for JsonObject {
    fn from_iter<T: IntoIterator<Item = (String, Json)>>(iter: T) -> Self {
        let mut o = JsonObject::new();
        for (k, v) in iter {
            o.insert(k, v);
        }
        o
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    Str(String),
    Array(Vec<Json>),
    Object(JsonObject),
}

impl Json {
    /// Borrow this value as an object, or `None` if it is another kind.
    pub fn as_object(&self) -> Option<&JsonObject> {
        match self {
            Json::Object(m) => Some(m),
            _ => None,
        }
    }

    /// Borrow this value as an array.
    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(v) => Some(v),
            _ => None,
        }
    }

    /// Borrow this value as a string.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    /// Borrow this value as a bool.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// Look up a key on an object value (`None` for a non-object or a
    /// missing key).
    pub fn get(&self, key: &str) -> Option<&Json> {
        self.as_object().and_then(|m| m.get(key))
    }
}

/// Parse a JSON document. Returns a descriptive error string on malformed
/// input (the OpenAPI front-end surfaces it through the plugin protocol).
pub fn parse(input: &str) -> Result<Json, String> {
    let mut p = Parser {
        chars: input.chars().collect(),
        pos: 0,
    };
    p.skip_ws();
    let value = p.parse_value()?;
    p.skip_ws();
    if p.pos != p.chars.len() {
        return Err(format!("trailing input at position {}", p.pos));
    }
    Ok(value)
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek();
        if c.is_some() {
            self.pos += 1;
        }
        c
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t' | '\n' | '\r')) {
            self.pos += 1;
        }
    }

    fn parse_value(&mut self) -> Result<Json, String> {
        self.skip_ws();
        match self.peek() {
            Some('{') => self.parse_object(),
            Some('[') => self.parse_array(),
            Some('"') => Ok(Json::Str(self.parse_string()?)),
            Some('t') | Some('f') => self.parse_bool(),
            Some('n') => self.parse_null(),
            Some(c) if c == '-' || c.is_ascii_digit() => self.parse_number(),
            Some(c) => Err(format!("unexpected character {c:?} at {}", self.pos)),
            None => Err("unexpected end of input".to_string()),
        }
    }

    fn parse_object(&mut self) -> Result<Json, String> {
        self.expect('{')?;
        let mut map = JsonObject::new();
        self.skip_ws();
        if self.peek() == Some('}') {
            self.pos += 1;
            return Ok(Json::Object(map));
        }
        loop {
            self.skip_ws();
            let key = self.parse_string()?;
            self.skip_ws();
            self.expect(':')?;
            let value = self.parse_value()?;
            map.insert(key, value);
            self.skip_ws();
            match self.bump() {
                Some(',') => continue,
                Some('}') => break,
                other => {
                    return Err(format!(
                        "expected ',' or '}}' in object, got {other:?}"
                    ))
                }
            }
        }
        Ok(Json::Object(map))
    }

    fn parse_array(&mut self) -> Result<Json, String> {
        self.expect('[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(']') {
            self.pos += 1;
            return Ok(Json::Array(items));
        }
        loop {
            items.push(self.parse_value()?);
            self.skip_ws();
            match self.bump() {
                Some(',') => continue,
                Some(']') => break,
                other => {
                    return Err(format!(
                        "expected ',' or ']' in array, got {other:?}"
                    ))
                }
            }
        }
        Ok(Json::Array(items))
    }

    fn parse_string(&mut self) -> Result<String, String> {
        self.expect('"')?;
        let mut out = String::new();
        loop {
            match self.bump() {
                Some('"') => return Ok(out),
                Some('\\') => match self.bump() {
                    Some('"') => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some('/') => out.push('/'),
                    Some('b') => out.push('\u{0008}'),
                    Some('f') => out.push('\u{000C}'),
                    Some('n') => out.push('\n'),
                    Some('r') => out.push('\r'),
                    Some('t') => out.push('\t'),
                    Some('u') => {
                        let cp = self.parse_hex4()?;
                        if (0xD800..=0xDBFF).contains(&cp) {
                            if self.bump() != Some('\\') || self.bump() != Some('u') {
                                return Err("lone high surrogate".to_string());
                            }
                            let low = self.parse_hex4()?;
                            let c = 0x10000
                                + ((cp - 0xD800) << 10)
                                + (low - 0xDC00);
                            out.push(
                                char::from_u32(c)
                                    .ok_or("invalid surrogate pair")?,
                            );
                        } else {
                            out.push(
                                char::from_u32(cp)
                                    .ok_or("invalid \\u escape")?,
                            );
                        }
                    }
                    other => {
                        return Err(format!("invalid escape \\{other:?}"))
                    }
                },
                Some(c) => out.push(c),
                None => return Err("unterminated string".to_string()),
            }
        }
    }

    fn parse_hex4(&mut self) -> Result<u32, String> {
        let mut v = 0u32;
        for _ in 0..4 {
            let c = self.bump().ok_or("truncated \\u escape")?;
            let d = c.to_digit(16).ok_or("non-hex digit in \\u escape")?;
            v = v * 16 + d;
        }
        Ok(v)
    }

    fn parse_number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        if self.peek() == Some('-') {
            self.pos += 1;
        }
        while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
            self.pos += 1;
        }
        if self.peek() == Some('.') {
            self.pos += 1;
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some('e' | 'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some('+' | '-')) {
                self.pos += 1;
            }
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        let text: String = self.chars[start..self.pos].iter().collect();
        text.parse::<f64>()
            .map(Json::Number)
            .map_err(|_| format!("invalid number {text:?}"))
    }

    fn parse_bool(&mut self) -> Result<Json, String> {
        if self.consume_keyword("true") {
            Ok(Json::Bool(true))
        } else if self.consume_keyword("false") {
            Ok(Json::Bool(false))
        } else {
            Err(format!("invalid literal at {}", self.pos))
        }
    }

    fn parse_null(&mut self) -> Result<Json, String> {
        if self.consume_keyword("null") {
            Ok(Json::Null)
        } else {
            Err(format!("invalid literal at {}", self.pos))
        }
    }

    fn consume_keyword(&mut self, kw: &str) -> bool {
        let kw_chars: Vec<char> = kw.chars().collect();
        if self.chars[self.pos..].starts_with(&kw_chars) {
            self.pos += kw_chars.len();
            true
        } else {
            false
        }
    }

    fn expect(&mut self, c: char) -> Result<(), String> {
        match self.bump() {
            Some(got) if got == c => Ok(()),
            other => Err(format!("expected {c:?}, got {other:?}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_nested_object() {
        let v = parse(r#"{"a": {"b": [1, 2, true]}, "c": "x"}"#).unwrap();
        assert_eq!(v.get("c").and_then(Json::as_str), Some("x"));
        let b = v.get("a").unwrap().get("b").unwrap();
        assert_eq!(b.as_array().unwrap().len(), 3);
    }

    #[test]
    fn parses_escapes() {
        let v = parse(r#""line\nbreakA""#).unwrap();
        assert_eq!(v.as_str(), Some("line\nbreakA"));
    }

    #[test]
    fn rejects_trailing_input() {
        assert!(parse("{} junk").is_err());
    }
}
