///|
const EMPTY_PAYLOAD_HASH : String = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

///|
pub let unsigned_payload : String = "UNSIGNED-PAYLOAD"

///|
pub fn empty_payload_hash() -> String {
  EMPTY_PAYLOAD_HASH
}

///|
/// Percent-encode one URI component with the SigV4 rule set: everything
/// outside `A-Z a-z 0-9 - . _ ~` becomes `%XX` with uppercase digits, and a
/// space becomes `%20` (never `+`).
pub fn uri_encode_component(text : String) -> String {
  @percent.encode(text.view())
}

///|
/// Encode an object key: every `/`-separated segment is encoded and the
/// separators stay literal, which is what the signing rules ask for.
pub fn encode_object_key(key : String) -> String {
  let mut out = ""
  let mut first = true
  for segment in key.split("/") {
    if !first {
      out = out + "/"
    }
    first = false
    out = out + uri_encode_component(segment.to_owned())
  }
  out
}

///|
/// `YYYYMMDDTHHMMSSZ` → `YYYYMMDD`, the date half of the credential scope.
pub fn date_stamp_of(timestamp : String) -> String raise SigningError {
  if timestamp.length() < 8 {
    raise InvalidInput("timestamp must be YYYYMMDDTHHMMSSZ, got " + timestamp)
  }
  timestamp[0:8].to_owned()
}

///|
/// One `key=value` pair of a raw (not yet canonical) query string.
pub(all) struct QueryPair {
  key : String
  value : String
}

///|
/// Split a raw query string into pairs. A value-less parameter (`?acl`) reads
/// as an empty value, which is how the signing rules want it.
pub fn parse_query(query : String) -> Array[QueryPair] {
  let out : Array[QueryPair] = []
  if query.is_empty() {
    return out
  }
  for piece in query.split("&") {
    let text = piece.to_owned()
    match text.split_once("=") {
      Some((k, v)) => {
        let key = k.to_owned()
        let value = v.to_owned()
        out.push({ key, value, })
      }
      None => out.push({ key: text, value: "", })
    }
  }
  out
}

///|
/// ASCII-codepoint comparison folded to -1 / 0 / 1, so the ordering rule
/// lives in one place and no `Ordering` type name is needed.
fn compare_string(a : String, b : String) -> Int32 {
  let ac = a.to_array()
  let bc = b.to_array()
  let n = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  let mut i = 0
  while i < n {
    let x = ac[i].to_int()
    let y = bc[i].to_int()
    if x < y {
      return -1
    }
    if x > y {
      return 1
    }
    i = i + 1
  }
  ac.length() - bc.length()
}

///|
/// Canonical query string: encode each name and value, then sort by the
/// encoded form — sorting happens after encoding, not before.
pub fn canonical_query(pairs : Array[QueryPair]) -> String {
  let encoded : Array[QueryPair] = []
  for p in pairs {
    let key = uri_encode_component(p.key)
    let value = uri_encode_component(p.value)
    encoded.push({ key, value, })
  }
  let ordered = insertion_sort(encoded, (a, b) => compare_pair(a, b) < 0)
  let mut out = ""
  for i = 0; i < ordered.length(); i = i + 1 {
    if i > 0 {
      out = out + "&"
    }
    let item = ordered[i]
    out = out + item.key + "=" + item.value
  }
  out
}

///|
fn compare_pair(a : QueryPair, b : QueryPair) -> Int32 {
  let by_key = compare_string(a.key, b.key)
  if by_key == 0 {
    compare_string(a.value, b.value)
  } else {
    by_key
  }
}

///|
/// Insertion sort by an integer comparator: the arrays here (query pairs,
/// canonical headers) are single-digit long, so this beats depending on a
/// library sort whose ordering type name is not in scope.
fn[T] insertion_sort(items : Array[T], less : (T, T) -> Bool) -> Array[T] {
  let sorted : Array[T] = []
  for item in items {
    let mut placed = false
    let mut index = 0
    while index < sorted.length() && !placed {
      if less(item, sorted[index]) {
        placed = true
      } else {
        index = index + 1
      }
    }
    sorted.insert(index, item)
  }
  sorted
}

///|
fn is_space(c : Char) -> Bool {
  let x = c.to_int()
  x == 32 || x == 9 || x == 10 || x == 13
}

///|
/// Header value normalisation: strip outer whitespace and collapse runs of
/// inner spaces to a single space.
pub fn normalize_header_value(value : String) -> String {
  let chars = value.to_array()
  let mut start = 0
  while start < chars.length() && is_space(chars[start]) {
    start = start + 1
  }
  let mut end = chars.length()
  while end > start && is_space(chars[end - 1]) {
    end = end - 1
  }
  let out : Array[Char] = []
  let mut pending_space = false
  for i in start..<end {
    let c = chars[i]
    if is_space(c) {
      pending_space = true
    } else {
      if pending_space && !out.is_empty() {
        out.push(' ')
      }
      pending_space = false
      out.push(c)
    }
  }
  String::from_array(out)
}

///|
/// `scheme://authority/path?query` in four pieces. The authority keeps its
/// port, since that is exactly what the `host` header must carry.
pub(all) struct UrlParts {
  scheme : String
  authority : String
  path : String
  query : String
}

///|
fn first_index_of_any(text : String, probes : Array[Char]) -> Int32 {
  let cs = text.to_array()
  let mut i = 0
  while i < cs.length() {
    let mut hit = false
    for probe in probes {
      if cs[i] == probe {
        hit = true
      }
    }
    if hit {
      return i
    }
    i = i + 1
  }
  cs.length()
}

///|
pub fn split_url(url : String) -> UrlParts raise SigningError {
  match url.split_once("://") {
    None => raise InvalidInput("url must carry a scheme, got " + url)
    Some((scheme_view, rest_view)) => {
      let scheme = scheme_view.to_owned().to_lower()
      let rest = rest_view.to_owned()
      let boundary = first_index_of_any(rest, ['/', '?'])
      let authority = rest[0:boundary].to_owned()
      if authority.is_empty() {
        raise InvalidInput("url has no host, got " + url)
      }
      let tail = rest[boundary:rest.length()].to_owned()
      let query_start = first_index_of_any(tail, ['?'])
      if query_start < tail.length() {
        let path = tail[0:query_start].to_owned()
        let query = tail[query_start + 1:tail.length()].to_owned()
        UrlParts::{ scheme, authority, path, query, }
      } else {
        UrlParts::{ scheme, authority, path: tail, query: "", }
      }
    }
  }
}

///|
/// Everything the signer needs beyond the request itself. The caller owns the
/// clock and the payload hash: signing never reads the body, so a stream is
/// never consumed by the act of signing.
pub(all) struct SigningInput {
  region : String
  service : String
  timestamp : String
  payload_hash : String
}

///|
priv struct HeaderLine {
  name : String
  value : String
}

///|
/// The headers this signer always owns.
fn is_reserved_header(name : String) -> Bool {
  match name {
    "host" => true
    "x-amz-date" => true
    "x-amz-content-sha256" => true
    "x-amz-security-token" => true
    "authorization" => true
    _ => false
  }
}

///|
/// The headers SigV4 requires in the canonical request for S3: `host`,
/// `x-amz-content-sha256`, `x-amz-date`, plus `x-amz-security-token` when the
/// credentials are temporary.
fn required_headers(
  parts : UrlParts,
  input : SigningInput,
  credentials : Credentials,
) -> Array[HeaderLine] {
  let host_line : HeaderLine = { name: "host", value: parts.authority, }
  let content_line : HeaderLine = {
    name: "x-amz-content-sha256",
    value: input.payload_hash,
  }
  let date_line : HeaderLine = { name: "x-amz-date", value: input.timestamp, }
  let lines : Array[HeaderLine] = [host_line, content_line, date_line]
  match credentials.session_token {
    Some(token) => {
      let token_line : HeaderLine = {
        name: "x-amz-security-token",
        value: token,
      }
      lines.push(token_line)
    }
    None => ()
  }
  lines
}

///|
/// Caller headers that take part in the signature: everything except the ones
/// the signer owns, so the canonical form and the wire form cannot disagree.
fn signable_headers(
  request : @transport.Request,
  input : SigningInput,
  credentials : Credentials,
) -> Array[HeaderLine] raise SigningError {
  let parts = split_url(request.url)
  let lines = required_headers(parts, input, credentials)
  for header in request.headers {
    let name = header.name.to_lower()
    if !is_reserved_header(name) {
      let line : HeaderLine = { name, value: header.value, }
      lines.push(line)
    }
  }
  insertion_sort(lines, (a, b) => compare_string(a.name, b.name) < 0)
}

///|
fn header_block(lines : Array[HeaderLine]) -> String {
  let mut out = ""
  for line in lines {
    let value = normalize_header_value(line.value)
    out = out + line.name + ":" + value + "\n"
  }
  out
}

///|
fn signed_header_list(lines : Array[HeaderLine]) -> String {
  let mut out = ""
  for i = 0; i < lines.length(); i = i + 1 {
    if i > 0 {
      out = out + ";"
    }
    out = out + lines[i].name
  }
  out
}

///|
pub fn canonical_request(
  request : @transport.Request,
  input : SigningInput,
  credentials : Credentials,
) -> String raise SigningError {
  let parts = split_url(request.url)
  let lines = signable_headers(request, input, credentials)
  let query = canonical_query(parse_query(parts.query))
  let headers = header_block(lines)
  let signed = signed_header_list(lines)
  let verb = verb_keyword(request.http_method)
  let first = verb + "\n" + parts.path + "\n" + query + "\n"
  let second = headers + "\n" + signed + "\n" + input.payload_hash
  first + second
}

///|
fn verb_keyword(http_method : @transport.Method) -> String {
  match http_method {
    Get => "GET"
    Head => "HEAD"
    Put => "PUT"
    Post => "POST"
    Delete => "DELETE"
    Patch => "PATCH"
    Options => "OPTIONS"
  }
}

///|
pub fn credential_scope(input : SigningInput) -> String raise SigningError {
  let date = date_stamp_of(input.timestamp)
  date + "/" + input.region + "/" + input.service + "/aws4_request"
}

///|
pub fn string_to_sign(
  canonical : String,
  input : SigningInput,
) -> String raise SigningError {
  let scope = credential_scope(input)
  let digest = @digest.sha256_hex(canonical)
  "AWS4-HMAC-SHA256\n" + input.timestamp + "\n" + scope + "\n" + digest
}

///|
fn to_bytes(text : String) -> Bytes {
  @utf8.encode(text.view())
}

///|
pub fn derive_signing_key(
  credentials : Credentials,
  input : SigningInput,
) -> Bytes raise SigningError {
  let date = date_stamp_of(input.timestamp)
  let seed = "AWS4" + credentials.secret_key
  let date_key = @digest.hmac_sha256_of_bytes(to_bytes(seed), to_bytes(date))
  let region_key = @digest.hmac_sha256_of_bytes(
    date_key,
    to_bytes(input.region),
  )
  let service_key = @digest.hmac_sha256_of_bytes(
    region_key,
    to_bytes(input.service),
  )
  @digest.hmac_sha256_of_bytes(service_key, to_bytes("aws4_request"))
}

///|
/// Lowercase hex signature over the string to sign — the value that goes into
/// `Signature=`.
pub fn calculate_signature(to_sign : String, signing_key : Bytes) -> String {
  let raw = @digest.hmac_sha256_of_bytes(signing_key, to_bytes(to_sign))
  @hex.encode(raw)
}
