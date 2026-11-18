//! The text of a document you give meeting notes (an agenda, a spec, notes), as the Mac's MeetingDocuments: plain
//! text and Markdown, web pages and RTF (their tags left out), and Word (.docx: the text in its document.xml, read
//! from the file's zip). Read on this PC, at most 30,000 characters.

use std::io::Read;
use std::path::Path;

pub const LIMIT: usize = 30_000;

pub fn text(path: &Path) -> Result<String, String> {
    let extension = path.extension().and_then(|e| e.to_str()).unwrap_or_default().to_lowercase();
    let bytes = std::fs::read(path).map_err(|error| format!("can't read it: {error}"))?;
    let text = match extension.as_str() {
        "docx" => docx(&bytes).ok_or("it isn't a Word document Murmur can read")?,
        "html" | "htm" => tags_out(&String::from_utf8_lossy(&bytes)),
        "rtf" => rtf(&String::from_utf8_lossy(&bytes)),
        "pdf" | "doc" | "pptx" | "xlsx" => return Err(format!("Murmur on Windows doesn't read .{extension} files yet: \
                                                              save it as text or Word (.docx), or paste the text in About")),
        _ => String::from_utf8(bytes.clone()).unwrap_or_else(|_| bytes.iter().map(|b| *b as char).collect()),
    };
    let text = text.trim();
    if text.is_empty() {
        return Err("there's no text in it".into());
    }
    Ok(text.chars().take(LIMIT).collect())
}

/// A .docx's text: its paragraphs (w:p) a line each, from word/document.xml.
pub fn docx(bytes: &[u8]) -> Option<String> {
    let xml = zip_entry(bytes, "word/document.xml")?;
    let xml = String::from_utf8_lossy(&xml);
    let mut out = String::new();
    let mut rest = xml.as_ref();
    while let Some(start) = rest.find('<') {
        let Some(end) = rest[start..].find('>') else { break };
        let tag = &rest[start + 1..start + end];
        let after = &rest[start + end + 1..];
        if tag.starts_with("w:t") && !tag.starts_with("w:tab") && !tag.ends_with('/') {
            if let Some(close) = after.find("</w:t>") {
                out.push_str(&unescape(&after[..close]));
                rest = &after[close + 6..];
                continue;
            }
        } else if tag == "/w:p" || tag.starts_with("w:br") {
            out.push('\n');
        } else if tag.starts_with("w:tab") {
            out.push('\t');
        }
        rest = after;
    }
    Some(out)
}

/// One file from a zip, found through its central directory (stored or deflated).
fn zip_entry(bytes: &[u8], wanted: &str) -> Option<Vec<u8>> {
    let u16_at = |i: usize| -> Option<u16> { Some(u16::from_le_bytes(bytes.get(i..i + 2)?.try_into().ok()?)) };
    let u32_at = |i: usize| -> Option<u32> { Some(u32::from_le_bytes(bytes.get(i..i + 4)?.try_into().ok()?)) };
    // The end of central directory record, in the last 64 KB.
    let floor = bytes.len().saturating_sub(65_557);
    let end = (floor..bytes.len().saturating_sub(21)).rev().find(|&i| u32_at(i) == Some(0x0605_4b50))?;
    let count = u16_at(end + 10)? as usize;
    let mut at = u32_at(end + 16)? as usize;
    for _ in 0..count {
        if u32_at(at)? != 0x0201_4b50 {
            return None;
        }
        let method = u16_at(at + 10)?;
        let size = u32_at(at + 20)? as usize;
        let name_length = u16_at(at + 28)? as usize;
        let extra = u16_at(at + 30)? as usize;
        let comment = u16_at(at + 32)? as usize;
        let local = u32_at(at + 42)? as usize;
        let name = bytes.get(at + 46..at + 46 + name_length)?;
        if name == wanted.as_bytes() {
            let local_name = u16_at(local + 26)? as usize;
            let local_extra = u16_at(local + 28)? as usize;
            let start = local + 30 + local_name + local_extra;
            let data = bytes.get(start..start + size)?;
            return match method {
                0 => Some(data.to_vec()),
                8 => {
                    let mut out = Vec::new();
                    flate2::read::DeflateDecoder::new(data).read_to_end(&mut out).ok()?;
                    Some(out)
                }
                _ => None,
            };
        }
        at += 46 + name_length + extra + comment;
    }
    None
}

fn unescape(text: &str) -> String {
    text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

/// A web page's text: tags, scripts and styles out.
fn tags_out(html: &str) -> String {
    let mut out = String::new();
    let lower = html.to_lowercase();
    let mut i = 0;
    while i < html.len() {
        if lower[i..].starts_with("<script") || lower[i..].starts_with("<style") {
            let close = if lower[i..].starts_with("<script") { "</script>" } else { "</style>" };
            i = lower[i..].find(close).map_or(html.len(), |j| i + j + close.len());
            continue;
        }
        if html[i..].starts_with('<') {
            let end = html[i..].find('>').map_or(html.len(), |j| i + j + 1);
            let tag = &lower[i..end];
            if tag.starts_with("<p") || tag.starts_with("<br") || tag.starts_with("<li") || tag.starts_with("<h") || tag.starts_with("<div") {
                out.push('\n');
            }
            i = end;
            continue;
        }
        let next = html[i..].find('<').map_or(html.len(), |j| i + j);
        out.push_str(&unescape(&html[i..next]));
        i = next;
    }
    out.lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join("\n")
}

/// RTF's text, roughly: control words and groups out.
fn rtf(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                let mut word = String::new();
                while let Some(&next) = chars.peek() {
                    if next.is_ascii_alphabetic() {
                        word.push(next);
                        chars.next();
                    } else {
                        break;
                    }
                }
                while chars.peek().is_some_and(|c| c.is_ascii_digit() || *c == '-') {
                    chars.next();
                }
                if chars.peek() == Some(&' ') {
                    chars.next();
                }
                if word == "par" || word == "line" {
                    out.push('\n');
                } else if word.is_empty() {
                    if let Some(escaped) = chars.next() {
                        if "\\{}".contains(escaped) {
                            out.push(escaped);
                        }
                    }
                }
            }
            '{' | '}' => {}
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_and_rtf_text() {
        assert_eq!(tags_out("<html><style>p{}</style><p>Agenda</p><p>Q3 &amp; Q4</p><script>x()</script></html>"), "Agenda\nQ3 & Q4");
        assert_eq!(rtf(r"{\rtf1\ansi Hello\par World}").trim(), "Hello\nWorld");
    }

    #[test]
    fn a_stored_zip_entry() {
        // A zip with one stored file, "word/document.xml".
        let xml = br#"<w:document><w:p><w:r><w:t>Launch plan</w:t></w:r></w:p><w:p><w:r><w:t xml:space="preserve">Ship &amp; tell</w:t></w:r></w:p></w:document>"#;
        let name = b"word/document.xml";
        let mut zip = Vec::new();
        zip.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        zip.extend_from_slice(&[20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        zip.extend_from_slice(&(xml.len() as u32).to_le_bytes());
        zip.extend_from_slice(&(xml.len() as u32).to_le_bytes());
        zip.extend_from_slice(&(name.len() as u16).to_le_bytes());
        zip.extend_from_slice(&0u16.to_le_bytes());
        zip.extend_from_slice(name);
        zip.extend_from_slice(xml);
        let central = zip.len();
        zip.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        zip.extend_from_slice(&[20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        zip.extend_from_slice(&(xml.len() as u32).to_le_bytes());
        zip.extend_from_slice(&(xml.len() as u32).to_le_bytes());
        zip.extend_from_slice(&(name.len() as u16).to_le_bytes());
        zip.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        zip.extend_from_slice(&0u32.to_le_bytes());
        zip.extend_from_slice(name);
        let size = zip.len() - central;
        zip.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        zip.extend_from_slice(&[0, 0, 0, 0, 1, 0, 1, 0]);
        zip.extend_from_slice(&(size as u32).to_le_bytes());
        zip.extend_from_slice(&(central as u32).to_le_bytes());
        zip.extend_from_slice(&0u16.to_le_bytes());
        assert_eq!(docx(&zip).unwrap().trim(), "Launch plan\nShip & tell");
    }
}
