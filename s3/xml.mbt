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
/// The five predefined XML entities, in **both** spellings S3 uses. `&amp;` is
/// decoded last so that `&amp;lt;` does not collapse into `<`.
///
/// The numeric spellings are not optional: MinIO writes the ETag of a part as
/// `&#34;…&#34;` in `ListPartsResult` (measured), so a reader that only knows the
/// named forms hands the completion document a tag the server cannot match, and
/// the upload dies as `InvalidPart`. Anything beyond these five (hexadecimal
/// references, arbitrary code points) is outside what these endpoints emit and is
/// left alone rather than half-implemented.
pub fn xml_unescape(text : String) -> String {
  // 两组"变成 &"的写法必须一起放在最后：先解 `&#38;` 的话，`&#38;lt;` 会被读成
  // `&lt;` 再被下一轮解成 `<`——一次转义被解了两次。
  let numeric = replace_all_pairs(text, [
    ("&#34;", "\""),
    ("&#39;", "'"),
    ("&#60;", "<"),
    ("&#62;", ">"),
  ])
  let lt = numeric.replace_all(old="&lt;", new="<")
  let gt = lt.replace_all(old="&gt;", new=">")
  let quot = gt.replace_all(old="&quot;", new="\"")
  let apos = quot.replace_all(old="&apos;", new="'")
  let amp = apos.replace_all(old="&amp;", new="&")
  amp.replace_all(old="&#38;", new="&")
}

///|
fn replace_all_pairs(text : String, pairs : Array[(String, String)]) -> String {
  let mut out = text
  for pair in pairs {
    out = out.replace_all(old=pair.0, new=pair.1)
  }
  out
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
