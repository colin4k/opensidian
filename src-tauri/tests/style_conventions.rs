// SPDX-License-Identifier: GPL-3.0-or-later
//! Style convention that the desktop cannot notice and a touch screen cannot
//! forgive: on touch, a tap leaves `:hover` stuck on the element until the next
//! tap, so an unwrapped hover rule reads as a selection that will not clear.
//! Every `:hover` rule therefore lives inside `@media (hover: hover)`; a mouse
//! still matches the query, so desktop behaviour is unchanged.
//!
//! The check is source-level on purpose: no CSS engine here, and the rule is
//! about where a selector sits, not about a computed value. It fails on the
//! first unwrapped hover selector and names it.

use std::fs;

/// the prelude, with comments removed (a comment may sit between selectors)
fn without_comments(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'*') {
            match s[i + 2..].find("*/") {
                Some(off) => i += 2 + off + 2,
                None => break,
            }
            out.push(' '); // keep two selectors from fusing into one
            continue;
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

struct Frame {
    hover_media: bool,
}

/// Count the `:hover` rules and refuse the first one that is not inside a
/// `@media (hover: hover)`. Returns Err(selector) so a test can prove the
/// checker actually rejects something.
fn scan_hover_rules(src: &str) -> Result<usize, String> {
    let bytes = src.as_bytes();
    let mut stack: Vec<Frame> = Vec::new();
    let mut boundary = 0usize;
    let mut hover_rules = 0usize;
    let mut i = 0usize;

    while i < bytes.len() {
        match bytes[i] {
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i = match src[i + 2..].find("*/") {
                    Some(off) => i + 2 + off + 2,
                    None => bytes.len(),
                };
                continue;
            }
            b'"' | b'\'' => {
                let quote = bytes[i];
                i += 1;
                while i < bytes.len() {
                    if bytes[i] == b'\\' {
                        i += 2;
                        continue;
                    }
                    if bytes[i] == quote {
                        break;
                    }
                    i += 1;
                }
            }
            b'{' => {
                let prelude = without_comments(&src[boundary..i]);
                let prelude = prelude.trim();
                let at_rule = prelude.starts_with('@');
                let is_hover_media = at_rule && prelude.contains("(hover: hover)");
                let inside = is_hover_media || stack.iter().any(|f| f.hover_media);
                if !at_rule && prelude.contains(":hover") {
                    hover_rules += 1;
                    if !inside {
                        return Err(prelude.chars().take(120).collect());
                    }
                }
                stack.push(Frame { hover_media: inside });
                boundary = i + 1;
            }
            b'}' => {
                stack.pop();
                boundary = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    Ok(hover_rules)
}

#[test]
fn hover_rules_stay_behind_a_hover_media_query() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../ui/style.css");
    let src = fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let count = scan_hover_rules(&src)
        .unwrap_or_else(|sel| panic!("unwrapped :hover selector (wrap it in @media (hover: hover)): {sel}"));
    // A scanner that stopped matching would otherwise pass silently.
    assert!(count > 40, "the scanner found only {count} hover rules; did the conventions change?");
}

#[test]
fn the_checker_rejects_an_unwrapped_rule() {
    assert!(scan_hover_rules(".a { color: red }\n.b:hover { color: blue }").is_err());
    let wrapped = "@media (hover: hover) {\n.b:hover { color: blue }\n}";
    assert_eq!(scan_hover_rules(wrapped), Ok(1));
    // nested at-rules must not hide a rule either
    assert!(scan_hover_rules("@media (min-width: 1px) {\n.b:hover { color: blue }\n}").is_err());
}
