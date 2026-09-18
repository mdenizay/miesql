//! Splits a script into statements on semicolons, while respecting the things that make a
//! naive `split(';')` wrong: quoted strings, quoted identifiers, line and block comments,
//! PostgreSQL dollar quoting, and MySQL `DELIMITER` changes.

use crate::models::DatabaseKind;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Statement {
    pub text: String,
    /// Character offsets into the original script, so the editor can highlight the
    /// statement under the cursor.
    pub start: usize,
    pub end: usize,
}

pub fn split(sql: &str, kind: DatabaseKind) -> Vec<Statement> {
    let chars: Vec<char> = sql.chars().collect();
    let mut statements = Vec::new();
    let mut i = 0;
    let mut statement_start = 0;
    let mut delimiter: Vec<char> = vec![';'];
    let uses_mysql = kind.uses_mysql_protocol();

    let flush = |statements: &mut Vec<Statement>, from: usize, to: usize| {
        let raw: String = chars[from..to].iter().collect();
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            statements.push(Statement {
                text: trimmed.to_string(),
                start: from,
                end: to,
            });
        }
    };

    while i < chars.len() {
        let c = chars[i];

        // -- line comment
        if c == '-' && i + 1 < chars.len() && chars[i + 1] == '-' {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }

        // # line comment (MySQL)
        if c == '#' && uses_mysql {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }

        // /* block comment */
        if c == '/' && i + 1 < chars.len() && chars[i + 1] == '*' {
            i += 2;
            while i < chars.len() {
                if chars[i] == '*' && i + 1 < chars.len() && chars[i + 1] == '/' {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Quoted string or identifier. Doubling the quote escapes it in every dialect we
        // support; MySQL additionally honours backslash escapes.
        if c == '\'' || c == '"' || (c == '`' && uses_mysql) {
            let quote = c;
            i += 1;
            while i < chars.len() {
                if chars[i] == '\\' && uses_mysql && quote != '`' {
                    i += 2;
                    continue;
                }
                if chars[i] == quote {
                    if i + 1 < chars.len() && chars[i + 1] == quote {
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // PostgreSQL dollar quoting: $$ ... $$ or $tag$ ... $tag$
        if c == '$' && kind == DatabaseKind::Postgres {
            if let Some(tag) = dollar_tag(&chars, i) {
                let body_start = i + tag.len();
                match find_subslice(&chars, &tag, body_start) {
                    Some(close) => i = close + tag.len(),
                    None => i = chars.len(),
                }
                continue;
            }
        }

        // MySQL DELIMITER directive, which changes the terminator for what follows.
        if uses_mysql && at_line_start(&chars, i) && matches_keyword(&chars, i, "DELIMITER") {
            let mut cursor = i + 9;
            while cursor < chars.len() && (chars[cursor] == ' ' || chars[cursor] == '\t') {
                cursor += 1;
            }
            let mut new_delimiter = Vec::new();
            while cursor < chars.len() && !chars[cursor].is_whitespace() {
                new_delimiter.push(chars[cursor]);
                cursor += 1;
            }
            if !new_delimiter.is_empty() {
                delimiter = new_delimiter;
            }
            // The directive is a client-side instruction, never sent to the server.
            flush(&mut statements, statement_start, i);
            statement_start = cursor;
            i = cursor;
            continue;
        }

        // Statement terminator
        if starts_with_at(&chars, i, &delimiter) {
            flush(&mut statements, statement_start, i);
            i += delimiter.len();
            statement_start = i;
            continue;
        }

        i += 1;
    }

    if statement_start < chars.len() {
        flush(&mut statements, statement_start, chars.len());
    }

    statements
}

/// The statement whose range contains `offset`, for "Run current statement". A caret just
/// past the final semicolon belongs to the statement before it.
pub fn statement_at(sql: &str, offset: usize, kind: DatabaseKind) -> Option<Statement> {
    let statements = split(sql, kind);
    if let Some(found) = statements.iter().find(|s| offset >= s.start && offset <= s.end) {
        return Some(found.clone());
    }
    statements.iter().rev().find(|s| s.end <= offset).cloned()
}

fn dollar_tag(chars: &[char], index: usize) -> Option<Vec<char>> {
    let mut tag = vec!['$'];
    let mut cursor = index + 1;
    while cursor < chars.len() {
        let c = chars[cursor];
        if c == '$' {
            tag.push('$');
            return Some(tag);
        }
        if !(c.is_alphanumeric() || c == '_') {
            return None;
        }
        tag.push(c);
        cursor += 1;
    }
    None
}

fn find_subslice(haystack: &[char], needle: &[char], from: usize) -> Option<usize> {
    if needle.is_empty() || from >= haystack.len() {
        return None;
    }
    (from..=haystack.len().saturating_sub(needle.len()))
        .find(|&i| haystack[i..i + needle.len()] == *needle)
}

fn starts_with_at(chars: &[char], index: usize, needle: &[char]) -> bool {
    index + needle.len() <= chars.len() && chars[index..index + needle.len()] == *needle
}

fn at_line_start(chars: &[char], index: usize) -> bool {
    let mut cursor = index;
    while cursor > 0 {
        cursor -= 1;
        let c = chars[cursor];
        if c == '\n' {
            return true;
        }
        if !c.is_whitespace() {
            return false;
        }
    }
    true
}

fn matches_keyword(chars: &[char], index: usize, keyword: &str) -> bool {
    let keyword_chars: Vec<char> = keyword.chars().collect();
    if index + keyword_chars.len() > chars.len() {
        return false;
    }
    chars[index..index + keyword_chars.len()]
        .iter()
        .zip(keyword_chars.iter())
        .all(|(a, b)| a.to_ascii_uppercase() == *b)
}
