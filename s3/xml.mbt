///|
/// Minimal XML reads for the S3 response shapes this SDK consumes. S3 answers
/// with XML, and pulling in a full parser would cost more than the handful of
/// elements actually needed; anything outside these helpers' guarantees must
/// not be silently tolerated — a missing element reads as `None`.
pub fn xml_first(text : String, tag : String) -> String? {
  let open = "<" + tag + ">"
  let close = "</" + tag + ">"
  match text.find(open) {
    None => None
    Some(start) => {
      let value_start = start + open.length()
      let tail = text[value_start:text.length()].to_owned()
      match tail.find(close) {
        None => None
        Some(offset) => {
          let end = value_start + offset
          Some(xml_unescape(text[value_start:end].to_owned()))
        }
      }
    }
  }
}

///|
/// Every occurrence of `tag`, in document order.
pub fn xml_all(text : String, tag : String) -> Array[String] {
  let open = "<" + tag + ">"
  let close = "</" + tag + ">"
  let out : Array[String] = []
  let mut cursor = 0
  while cursor < text.length() {
    let rest = text[cursor:text.length()].to_owned()
    match rest.find(open) {
      None => cursor = text.length()
      Some(open_at) => {
        let value_start = cursor + open_at + open.length()
        let tail = text[value_start:text.length()].to_owned()
        match tail.find(close) {
          None => cursor = text.length()
          Some(close_at) => {
            let value = text[value_start:value_start + close_at].to_owned()
            out.push(xml_unescape(value))
            cursor = value_start + close_at + close.length()
          }
        }
      }
    }
  }
  out
}

///|
/// Splitting a **container** element out of a document, in document order. Unlike
/// `xml_all`, the segments are returned with escapes **not** decoded: a container
/// holds leaves, and each leaf gets its own decode when it is read.
///
/// This is the fix for a measured defect: `xml_all(doc, "Contents")` decoded the
/// whole inner text, then `xml_first(block, "Key")` decoded it a second time, so a
/// key that literally contains entity spellings came back rewritten
/// (`a&amp;lt;b` read as `a<b`). That key is then used for copy and delete, so the
/// second decode does not merely print wrong — it addresses the wrong object.
/// Idempotent shapes (`&#34;q&#34;` decodes fully on the first pass) hid this from
/// every existing assertion, which is why the case is pinned in a test.
pub fn xml_sections(text : String, tag : String) -> Array[String] {
  let open = "<" + tag + ">"
  let close = "</" + tag + ">"
  let out : Array[String] = []
  let mut cursor = 0
  while cursor < text.length() {
    let rest = text[cursor:text.length()].to_owned()
    match rest.find(open) {
      None => cursor = text.length()
      Some(open_at) => {
        let body_start = cursor + open_at + open.length()
        let tail = text[body_start:text.length()].to_owned()
        match tail.find(close) {
          None => cursor = text.length()
          Some(close_at) => {
            out.push(text[body_start:body_start + close_at].to_owned())
            cursor = body_start + close_at + close.length()
          }
        }
      }
    }
  }
  out
}

///|
/// Entity decoding belongs to moon-hutool (`@text.unescape_xml`); this SDK no
/// longer carries its own table. The two agree on every shape S3 and its
/// compatible endpoints actually return (a part ETag arrives as `&#34;…&#34;` in
/// `ListPartsResult` — measured — and a reader that only knows the named forms
/// would hand the completion document a tag the server cannot match, dying as
/// `InvalidPart`). hutool is the superset: it also decodes hexadecimal and
/// arbitrary decimal references, which is what the reference implementation does.
///
/// One case is deliberately **not** equivalent to the old local table: hutool
/// raises, and this hands back the whole string unchanged rather than decoding the
/// leading tokens. A lone surrogate (`&#xD800;`) is a shape MoonBit `String`
/// cannot hold, so refusing the whole string is more honest than a half-decoded
/// result. No per-token fallback is promised.
pub fn xml_unescape(text : String) -> String {
  @text.unescape_xml(text) catch {
    _ => text
  }
}

///|
pub fn xml_error_code(body : String) -> String {
  match xml_first(body, "Code") {
    Some(code) => code
    None => ""
  }
}

///|
pub fn xml_error_message(body : String) -> String {
  match xml_first(body, "Message") {
    Some(message) => message
    None => ""
  }
}
