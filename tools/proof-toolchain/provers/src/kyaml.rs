// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
//! A reader for the KYAML subset the kit's manifests use: flow mappings and
//! sequences, double-quoted strings, integers, true/false/null, bare keys,
//! `#` comments and trailing commas. Anything else is an error, never a guess.
//!
//! Transitional (estate DATA-FORMAT-ROUTING): KYAML queries belong to kyq.
//! Once a pinned kyq passes its positive and negative tests, this module is
//! replaced by a call to it and deleted.

use serde_json::{Map, Number, Value};

#[derive(Debug)]
pub struct Error {
    pub line: usize,
    pub col: usize,
    pub msg: String,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "line {}, column {}: {}", self.line, self.col, self.msg)
    }
}

struct P<'a> {
    s: &'a [u8],
    i: usize,
}

pub fn parse(src: &str) -> Result<Value, Error> {
    let mut p = P {
        s: src.as_bytes(),
        i: 0,
    };
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i != p.s.len() {
        return Err(p.err("trailing content after the document"));
    }
    Ok(v)
}

impl P<'_> {
    fn err(&self, msg: &str) -> Error {
        let before = &self.s[..self.i.min(self.s.len())];
        let line = before.iter().filter(|&&b| b == b'\n').count() + 1;
        let col = before.iter().rev().take_while(|&&b| b != b'\n').count() + 1;
        Error {
            line,
            col,
            msg: msg.to_string(),
        }
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn ws(&mut self) {
        while let Some(c) = self.peek() {
            match c {
                b' ' | b'\t' | b'\n' | b'\r' => self.i += 1,
                b'#' => {
                    while let Some(c) = self.peek() {
                        if c == b'\n' {
                            break;
                        }
                        self.i += 1;
                    }
                }
                _ => break,
            }
        }
    }

    fn expect(&mut self, c: u8) -> Result<(), Error> {
        if self.peek() == Some(c) {
            self.i += 1;
            Ok(())
        } else {
            Err(self.err(&format!("expected '{}'", c as char)))
        }
    }

    fn value(&mut self) -> Result<Value, Error> {
        match self.peek() {
            Some(b'{') => self.map(),
            Some(b'[') => self.seq(),
            Some(b'"') => Ok(Value::String(self.string()?)),
            Some(_) => self.scalar(),
            None => Err(self.err("unexpected end of input")),
        }
    }

    fn map(&mut self) -> Result<Value, Error> {
        self.expect(b'{')?;
        let mut m = Map::new();
        loop {
            self.ws();
            if self.peek() == Some(b'}') {
                self.i += 1;
                return Ok(Value::Object(m));
            }
            let key = if self.peek() == Some(b'"') {
                self.string()?
            } else {
                self.bare_key()?
            };
            self.ws();
            self.expect(b':')?;
            self.ws();
            let v = self.value()?;
            if m.contains_key(&key) {
                return Err(self.err(&format!("duplicate key '{key}'")));
            }
            m.insert(key, v);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b'}') => {}
                _ => return Err(self.err("expected ',' or '}' in a mapping")),
            }
        }
    }

    fn seq(&mut self) -> Result<Value, Error> {
        self.expect(b'[')?;
        let mut v = Vec::new();
        loop {
            self.ws();
            if self.peek() == Some(b']') {
                self.i += 1;
                return Ok(Value::Array(v));
            }
            v.push(self.value()?);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b']') => {}
                _ => return Err(self.err("expected ',' or ']' in a sequence")),
            }
        }
    }

    fn bare_key(&mut self) -> Result<String, Error> {
        let start = self.i;
        while let Some(c) = self.peek() {
            if c.is_ascii_alphanumeric() || c == b'-' || c == b'_' {
                self.i += 1;
            } else {
                break;
            }
        }
        if self.i == start {
            return Err(self.err("expected a key"));
        }
        Ok(String::from_utf8_lossy(&self.s[start..self.i]).into_owned())
    }

    fn scalar(&mut self) -> Result<Value, Error> {
        let start = self.i;
        while let Some(c) = self.peek() {
            if c.is_ascii_alphanumeric() || c == b'-' || c == b'+' || c == b'.' {
                self.i += 1;
            } else {
                break;
            }
        }
        let tok = std::str::from_utf8(&self.s[start..self.i]).unwrap_or("");
        match tok {
            "true" => return Ok(Value::Bool(true)),
            "false" => return Ok(Value::Bool(false)),
            "null" => return Ok(Value::Null),
            _ => {}
        }
        let digits = tok.strip_prefix('-').unwrap_or(tok);
        if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
            if let Ok(n) = tok.parse::<i64>() {
                if n.unsigned_abs() < (1u64 << 53) {
                    return Ok(Value::Number(Number::from(n)));
                }
            }
            self.i = start;
            return Err(self.err("integer outside the I-JSON range"));
        }
        self.i = start;
        Err(self.err("unquoted scalar: KYAML strings are double-quoted"))
    }

    fn string(&mut self) -> Result<String, Error> {
        self.expect(b'"')?;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let Some(c) = self.peek() else {
                return Err(self.err("unterminated string"));
            };
            self.i += 1;
            match c {
                b'"' => break,
                b'\n' => return Err(self.err("newline inside a string")),
                b'\\' => {
                    let Some(e) = self.peek() else {
                        return Err(self.err("unterminated escape"));
                    };
                    self.i += 1;
                    match e {
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'/' => out.push(b'/'),
                        b'n' => out.push(b'\n'),
                        b't' => out.push(b'\t'),
                        b'r' => out.push(b'\r'),
                        b'u' => {
                            let ch = self.unicode_escape()?;
                            let mut buf = [0u8; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        }
                        _ => return Err(self.err("unsupported escape")),
                    }
                }
                _ => out.push(c),
            }
        }
        String::from_utf8(out).map_err(|_| self.err("string is not UTF-8"))
    }

    fn hex4(&mut self) -> Result<u32, Error> {
        let h = self
            .s
            .get(self.i..self.i + 4)
            .ok_or_else(|| self.err("short \\u escape"))?;
        let v = u32::from_str_radix(std::str::from_utf8(h).unwrap_or("x"), 16)
            .map_err(|_| self.err("bad \\u escape"))?;
        self.i += 4;
        Ok(v)
    }

    fn unicode_escape(&mut self) -> Result<char, Error> {
        let hi = self.hex4()?;
        if (0xD800..0xDC00).contains(&hi) {
            if self.s.get(self.i..self.i + 2) != Some(b"\\u") {
                return Err(self.err("lone surrogate"));
            }
            self.i += 2;
            let lo = self.hex4()?;
            if !(0xDC00..0xE000).contains(&lo) {
                return Err(self.err("lone surrogate"));
            }
            let cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
            return char::from_u32(cp).ok_or_else(|| self.err("bad code point"));
        }
        char::from_u32(hi).ok_or_else(|| self.err("lone surrogate"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_the_subset() {
        let v =
            parse("# c\n{a: 1, b-c: \"x\\u00e9\", d: [true, null, -2,], \"e f\": {},}\n").unwrap();
        assert_eq!(v["a"], 1);
        assert_eq!(v["b-c"], "x\u{e9}");
        assert_eq!(v["d"][2], -2);
        assert!(v["e f"].is_object());
    }

    #[test]
    fn rejects_what_it_does_not_know() {
        for bad in [
            "{a: b}",                // unquoted string
            "{a: 1, a: 2}",          // duplicate key
            "{a: 1.5}",              // floats are not in the subset
            "{a: \"x\\q\"}",         // unknown escape
            "{a: \"\\ud800\"}",      // lone surrogate
            "{a: 1} x",              // trailing content
            "a: 1",                  // block style
            "{a: 9007199254740992}", // beyond I-JSON integers
        ] {
            assert!(parse(bad).is_err(), "accepted {bad}");
        }
    }

    #[test]
    fn reads_the_committed_manifests() {
        let root = env!("CARGO_MANIFEST_DIR");
        for f in [
            "../toolchain.kyaml",
            "../../environments/environments.kyaml",
        ] {
            let src = std::fs::read_to_string(format!("{root}/{f}")).unwrap();
            parse(&src).unwrap_or_else(|e| panic!("{f}: {e}"));
        }
    }
}
