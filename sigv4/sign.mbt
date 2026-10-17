///|
/// Sign `request` and return the wire-ready copy.
///
/// Two contract points cause `SignatureDoesNotMatch` when missed: the URL must
/// already carry a percent-encoded path (see `encode_object_key`) while its
/// query stays raw (canonicalised here), and the payload hash is an input
/// rather than something read off the body — signing a stream must not drain
/// it.
pub fn sign(
  request : @transport.Request,
  credentials : Credentials,
  region : String,
  timestamp : String,
  payload_hash : String,
) -> @transport.Request raise SigningError {
  let input : SigningInput = { region, service: "s3", timestamp, payload_hash, }
  let lines = signable_headers(request, input, credentials)
  let canonical = canonical_request(request, input, credentials)
  let to_sign = string_to_sign(canonical, input)
  let key = derive_signing_key(credentials, input)
  let signature = calculate_signature(to_sign, key)
  let scope = credential_scope(input)
  let signed = signed_header_list(lines)
  let credential = credentials.access_key + "/" + scope
  let prefix = "AWS4-HMAC-SHA256 Credential=" + credential + ", SignedHeaders="
  let authorization = prefix + signed + ", Signature=" + signature
  let headers : Array[@transport.Header] = []
  for line in lines {
    if line.name != "host" {
      let header : @transport.Header = { name: line.name, value: line.value, }
      headers.push(header)
    }
  }
  let auth_header : @transport.Header = {
    name: "authorization",
    value: authorization,
  }
  headers.push(auth_header)
  @transport.Request::{
    http_method: request.http_method,
    url: request.url,
    headers,
    body: request.body,
  }
}

///|
/// Turn a request into a presigned URL: credentials, expiry and signature
/// travel as query parameters, and the payload is declared unsigned because
/// the client puts the body in later.
pub fn presign(
  request : @transport.Request,
  credentials : Credentials,
  region : String,
  timestamp : String,
  expires_seconds : Int32,
) -> @transport.Request raise SigningError {
  if expires_seconds <= 0 || expires_seconds > 604800 {
    let bound = "expires_seconds must be within 1..604800, got "
    raise InvalidInput(bound + expires_seconds.to_string())
  }
  let input : SigningInput = {
    region,
    service: "s3",
    timestamp,
    payload_hash: unsigned_payload,
  }
  let parts = split_url(request.url)
  let scope = credential_scope(input)
  let pairs = parse_query(parts.query)
  let algorithm : QueryPair = {
    key: "X-Amz-Algorithm",
    value: "AWS4-HMAC-SHA256",
  }
  pairs.push(algorithm)
  let credential : QueryPair = {
    key: "X-Amz-Credential",
    value: credentials.access_key + "/" + scope,
  }
  pairs.push(credential)
  let date : QueryPair = { key: "X-Amz-Date", value: timestamp, }
  pairs.push(date)
  let expires : QueryPair = {
    key: "X-Amz-Expires",
    value: expires_seconds.to_string(),
  }
  pairs.push(expires)
  let signed_headers : QueryPair = {
    key: "X-Amz-SignedHeaders",
    value: "host",
  }
  pairs.push(signed_headers)
  match credentials.session_token {
    Some(token) => {
      let session : QueryPair = { key: "X-Amz-Security-Token", value: token, }
      pairs.push(session)
    }
    None => ()
  }
  let query = canonical_query(pairs)
  let verb = verb_keyword(request.http_method)
  let host_line = "host:" + parts.authority + "\n"
  let head = verb + "\n" + parts.path + "\n" + query + "\n" + host_line
  let tail = "\n" + "host" + "\n" + unsigned_payload
  let canonical = head + tail
  let to_sign = string_to_sign(canonical, input)
  let key = derive_signing_key(credentials, input)
  let signature = calculate_signature(to_sign, key)
  let origin = parts.scheme + "://" + parts.authority
  let url = origin + parts.path + "?" + query + "&X-Amz-Signature=" + signature
  @transport.Request::{
    http_method: request.http_method,
    url,
    headers: [],
    body: @transport.RequestBody::Empty,
  }
}
