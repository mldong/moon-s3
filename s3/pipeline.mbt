///|
/// Everything one S3 call needs before signing: where it points, what it
/// carries, and which headers the caller wants signed along with the request.
priv struct RequestSpec {
  http_method : @transport.Method
  bucket : String
  key : String
  query : Array[@sigv4.QueryPair]
  body : @transport.RequestBody
  headers : Array[@transport.Header]
}

///|
/// Build the request URL for `bucket`/`key`.
///
/// The path is percent-encoded here rather than left to the transport,
/// because SigV4 signs the encoded path: whatever this returns is both the
/// string that goes into the canonical request and the string on the wire.
fn build_object_url(
  config : Config,
  bucket : String,
  key : String,
) -> String raise S3Error {
  let raw = trim_trailing_slash(config.endpoint)
  // Trimming can strip a bare scheme down to "http:", which would otherwise be
  // re-prefixed into the nonsense origin "http://http:" and signed as if valid.
  let endpoint = if raw == "http:" || raw == "https:" {
    raise InvalidConfig("endpoint carries no host: " + config.endpoint)
  } else {
    raw
  }
  let origin = if endpoint.has_prefix("http://") ||
    endpoint.has_prefix("https://") {
    endpoint
  } else {
    "http://" + endpoint
  }
  let encoded_key = @sigv4.encode_object_key(key)
  match split_origin(origin) {
    None => raise InvalidConfig("endpoint is not a usable origin: " + origin)
    Some((scheme, authority)) => {
      let prefix = if bucket.is_empty() {
        ""
      } else if config.addressing_style is VirtualHosted {
        // Virtual-hosted addressing carries the bucket in the authority.
        ""
      } else {
        bucket + "/"
      }
      let host = if config.addressing_style is VirtualHosted {
        virtual_hosted_authority(authority, bucket)
      } else {
        authority
      }
      let head = scheme + "://" + host + "/"
      head + prefix + encoded_key
    }
  }
}

///|
/// Virtual-hosted addressing moves the bucket into the authority, so the
/// origin is rebuilt with `bucket.` prefixed to it.
fn virtual_hosted_authority(authority : String, bucket : String) -> String {
  if bucket.is_empty() {
    authority
  } else {
    bucket + "." + authority
  }
}

///|
fn split_origin(origin : String) -> (String, String)? {
  match origin.split_once("://") {
    None => None
    Some((scheme, rest)) => {
      let authority = match rest.find("/") {
        Some(i) => rest[0:i].to_owned()
        None => rest.to_owned()
      }
      if authority.is_empty() {
        None
      } else {
        Some((scheme.to_owned(), authority))
      }
    }
  }
}

///|

///|
fn trim_trailing_slash(text : String) -> String {
  let mut end = text.length()
  let chars = text.to_array()
  while end > 0 && chars[end - 1] == '/' {
    end = end - 1
  }
  text[0:end].to_owned()
}

///|
/// The wire form of the query: the pairs as the caller gave them, joined in
/// the order given. `@sigv4.sign` percent-encodes and sorts this text to build
/// the canonical query, so this must stay the raw form — putting the canonical
/// form here would get it encoded twice and the service would sign a different
/// string than the one it received (`sign.mbt`'s contract: path pre-encoded,
/// query raw).
fn join_query(pairs : Array[@sigv4.QueryPair]) -> String {
  let mut out = ""
  for i = 0; i < pairs.length(); i = i + 1 {
    if i > 0 {
      out = out + "&"
    }
    let pair = pairs[i]
    out = out + pair.key + "=" + pair.value
  }
  out
}

///|
/// Payload hash follows the signing rules: an in-memory body gets its real
/// digest, a stream is declared `UNSIGNED-PAYLOAD` (hashing it would mean
/// draining it here), and no body is the digest of the empty string.
fn payload_hash_of(body : @transport.RequestBody) -> String {
  match body {
    @transport.RequestBody::Empty => @sigv4.empty_payload_hash()
    @transport.RequestBody::Bytes(data) =>
      @hex.encode(@digest.sha256_of_bytes(data))
    @transport.RequestBody::Stream(_, _) => @sigv4.unsigned_payload
  }
}

///|
fn header_value(headers : Array[@transport.Header], name : String) -> String? {
  let want = name.to_lower()
  for header in headers {
    if header.name.to_lower() == want {
      return Some(header.value)
    }
  }
  None
}

///|
/// Header text is decimal ASCII; anything else reads as absent rather than
/// being guessed at.
fn parse_int64_opt(text : StringView) -> Int64? {
  Some(@string.parse_int64(text, base=10)) catch {
    _ => None
  }
}

///|
fn int64_header(headers : Array[@transport.Header], name : String) -> Int64? {
  match header_value(headers, name) {
    Some(text) => parse_int64_opt(text.trim())
    None => None
  }
}

///|
/// Drain a response body into memory. Used for listings and for error bodies
/// only — a successful `get_object` keeps its body as a stream.
async fn read_all(body : &@transport.ResponseBody) -> Bytes raise S3Error {
  let merged : Array[Byte] = []
  let mut reading = true
  while reading {
    let chunk = body.read(65536) catch { error => raise Transport(error) }
    match chunk {
      Some(data) => merged.append(data.to_array())
      None => reading = false
    }
  }
  Bytes::from_array(merged)
}

///|
/// Decode a response body that this SDK reads in full (listings, copy
/// results, error documents). A body that is not UTF-8 is still the service's
/// answer, so it is reported as a service error carrying the status it
/// arrived with rather than as a transport failure.
fn response_text(data : Bytes, status : Int32) -> String raise S3Error {
  @utf8.decode(data.exact_view()) catch {
    _ =>
      raise Service(ServiceError::{
        status_code: status,
        code: "",
        message: "response body is not valid UTF-8",
        request_id: None,
        host_id: None,
        resource: None,
      })
  }
}

///|
/// One signed round trip. Bodies are only drained for non-2xx, because a
/// successful object read must stay a stream.
async fn Client::execute(
  self : Client,
  spec : RequestSpec,
) -> @transport.Response raise S3Error {
  let url = build_object_url(self.config, spec.bucket, spec.key)
  let query = join_query(spec.query)
  let full_url = if query.is_empty() { url } else { url + "?" + query }
  let unsigned : @transport.Request = {
    http_method: spec.http_method,
    url: full_url,
    headers: spec.headers,
    body: spec.body,
  }
  let hash = payload_hash_of(spec.body)
  let (_, timestamp) = now_stamps()
  let signed = @sigv4.sign(
    unsigned,
    self.config.credentials,
    self.config.region,
    timestamp,
    hash,
  ) catch {
    error => raise Signing(error)
  }
  let response = self.transport.send(signed) catch {
    error => raise Transport(error)
  }
  if response.status >= 200 && response.status < 300 {
    response
  } else {
    let body = response.body
    let raw = read_all(body)
    body.close()
    let text = response_text(raw, response.status)
    raise Service(ServiceError::{
      status_code: response.status,
      code: error_code_for(response.status, text),
      message: xml_error_message(text),
      request_id: header_value(response.headers, "x-amz-request-id"),
      host_id: header_value(response.headers, "x-amz-id-2"),
      resource: xml_first(text, "Resource"),
    })
  }
}

///|
/// A HEAD response carries no body at all (an HTTP rule, not an S3 one), so
/// there is no XML error document and the status is the only signal. Fall back
/// only in that case: a non-empty body whose `Code` cannot be read stays empty,
/// because guessing there would hide a parser failure behind a plausible label.
fn error_code_for(status : Int32, body : String) -> String {
  let code = xml_error_code(body)
  if !code.is_empty() {
    code
  } else if !body.is_empty() {
    ""
  } else if status == 404 {
    "NoSuchKey"
  } else if status == 403 {
    "AccessDenied"
  } else {
    "HTTP" + status.to_string()
  }
}
