///|
/// Five-step manual multipart upload. `part_number` is validated before any
/// request goes out, because S3 numbers parts from 1 and a 0 would otherwise
/// reach the wire as a signed request that can only fail.
pub async fn Client::create_multipart_upload(
  self : Client,
  request : CreateMultipartUploadRequest,
) -> CreateMultipartUploadResponse raise S3Error {
  if request.bucket.is_empty() || request.key.is_empty() {
    raise InvalidRequest("create_multipart_upload needs a bucket and key")
  }
  let headers : Array[@transport.Header] = meta_headers(request.metadata)
  optional_header(headers, "content-type", request.content_type)
  let query : Array[@sigv4.QueryPair] = [{ key: "uploads", value: "", }]
  let spec : RequestSpec = {
    http_method: Post,
    bucket: request.bucket,
    key: request.key,
    query,
    body: @transport.RequestBody::Empty,
    headers,
  }
  let response = self.execute(spec)
  let body = response.body
  let raw = read_all(body)
  let xml = @utf8.decode_lossy(raw)
  body.close()
  CreateMultipartUploadResponse::{
    bucket: read_required(xml, "Bucket", request.bucket),
    key: read_required(xml, "Key", request.key),
    upload_id: read_required(xml, "UploadId", ""),
  }
}

///|
fn read_required(xml : String, tag : String, fallback : String) -> String {
  match xml_first(xml, tag) {
    Some(value) => value
    None => fallback
  }
}

///|
pub async fn Client::upload_part(
  self : Client,
  request : UploadPartRequest,
) -> UploadPartResponse raise S3Error {
  if request.part_number < 1 || request.part_number > 10000 {
    raise InvalidRequest(
      "part_number must be within 1..10000, got " +
      request.part_number.to_string(),
    )
  }
  if request.upload_id.is_empty() {
    raise InvalidRequest("upload_part needs an upload_id")
  }
  let query : Array[@sigv4.QueryPair] = []
  let number_pair : @sigv4.QueryPair = {
    key: "partNumber",
    value: request.part_number.to_string(),
  }
  query.push(number_pair)
  let id_pair : @sigv4.QueryPair = {
    key: "uploadId",
    value: request.upload_id,
  }
  query.push(id_pair)
  let spec : RequestSpec = {
    http_method: Put,
    bucket: request.bucket,
    key: request.key,
    query,
    body: request.body,
    headers: [],
  }
  let response = self.execute(spec)
  UploadPartResponse::{ etag: etag_from(response.headers), }
}

///|
fn etag_from(headers : Array[@transport.Header]) -> String {
  match header_value(headers, "etag") {
    Some(value) => value
    None => ""
  }
}

///|
/// The completion document lists every part in ascending order with the ETag
/// the upload returned; S3 rejects a mismatch rather than merging what it got.
pub async fn Client::complete_multipart_upload(
  self : Client,
  request : CompleteMultipartUploadRequest,
) -> CompleteMultipartUploadResponse raise S3Error {
  if request.upload_id.is_empty() {
    raise InvalidRequest("complete_multipart_upload needs an upload_id")
  }
  if request.parts.is_empty() {
    raise InvalidRequest("complete_multipart_upload needs at least one part")
  }
  let mut previous = 0
  for part in request.parts {
    if part.part_number < 1 || part.part_number > 10000 {
      raise InvalidRequest(
        "part_number must be within 1..10000, got " +
        part.part_number.to_string(),
      )
    }
    if part.part_number <= previous {
      raise InvalidRequest(
        "parts must be listed in ascending part_number order",
      )
    }
    if part.etag.is_empty() {
      raise InvalidRequest(
        "each part must carry the ETag returned by upload_part",
      )
    }
    previous = part.part_number
  }
  let document = complete_document(request.parts)
  let query : Array[@sigv4.QueryPair] = [
    { key: "uploadId", value: request.upload_id, },
  ]
  let spec : RequestSpec = {
    http_method: Post,
    bucket: request.bucket,
    key: request.key,
    query,
    body: @transport.RequestBody::Bytes(@utf8.encode(document.view())),
    headers: [],
  }
  let response = self.execute(spec)
  let body = response.body
  let raw = read_all(body)
  let xml = @utf8.decode_lossy(raw)
  body.close()
  CompleteMultipartUploadResponse::{
    bucket: read_required(xml, "Bucket", request.bucket),
    key: read_required(xml, "Key", request.key),
    etag: read_required(xml, "ETag", ""),
  }
}

///|
fn complete_document(parts : Array[CompletedPart]) -> String {
  let mut out = "<CompleteMultipartUpload>"
  for part in parts {
    let number = part.part_number.to_string()
    let quoted = xml_escape(part.etag)
    out = out +
      "<Part><PartNumber>" +
      number +
      "</PartNumber><ETag>" +
      quoted +
      "</ETag></Part>"
  }
  out + "</CompleteMultipartUpload>"
}

///|
/// The mirror of `xml_unescape`: an ETag arrives quoted, and the quotes must go
/// out the same way they came if the document is to parse on the server.
pub fn xml_escape(text : String) -> String {
  let amp = text.replace_all(old="&", new="&amp;")
  let lt = amp.replace_all(old="<", new="&lt;")
  let gt = lt.replace_all(old=">", new="&gt;")
  gt.replace_all(old="\"", new="&quot;")
}

///|
pub async fn Client::abort_multipart_upload(
  self : Client,
  request : AbortMultipartUploadRequest,
) -> AbortMultipartUploadResponse raise S3Error {
  if request.upload_id.is_empty() {
    raise InvalidRequest("abort_multipart_upload needs an upload_id")
  }
  let query : Array[@sigv4.QueryPair] = [
    { key: "uploadId", value: request.upload_id, },
  ]
  let spec : RequestSpec = {
    http_method: Delete,
    bucket: request.bucket,
    key: request.key,
    query,
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let _ = self.execute(spec)
  AbortMultipartUploadResponse::{ }
}

///|
pub async fn Client::list_parts(
  self : Client,
  request : ListPartsRequest,
) -> ListPartsResponse raise S3Error {
  if request.upload_id.is_empty() {
    raise InvalidRequest("list_parts needs an upload_id")
  }
  let query : Array[@sigv4.QueryPair] = [
    { key: "uploadId", value: request.upload_id, },
  ]
  optional_pair(
    query,
    "max-parts",
    match request.max_parts {
      Some(value) => Some(value.to_string())
      None => None
    },
  )
  optional_pair(
    query,
    "part-number-marker",
    match request.part_number_marker {
      Some(value) => Some(value.to_string())
      None => None
    },
  )
  let spec : RequestSpec = {
    http_method: Get,
    bucket: request.bucket,
    key: request.key,
    query,
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let response = self.execute(spec)
  let body = response.body
  let raw = read_all(body)
  let xml = @utf8.decode_lossy(raw)
  body.close()
  let parts : Array[PartInfo] = []
  for block in xml_sections(xml, "Part") {
    let size = parse_int64_or_zero(xml_first(block, "Size"))
    let number = parse_int_or_zero(xml_first(block, "PartNumber"))
    let info : PartInfo = {
      part_number: number,
      etag: read_required(block, "ETag", ""),
      size,
      last_modified: xml_first(block, "LastModified"),
    }
    parts.push(info)
  }
  ListPartsResponse::{
    parts,
    is_truncated: match xml_first(xml, "IsTruncated") {
      Some("true") => true
      _ => false
    },
    next_part_number_marker: next_marker_of(xml),
  }
}

///|
fn parse_int_or_zero(text : String?) -> Int32 {
  match text {
    Some(value) => parse_int_or_none(value).unwrap_or(0)
    None => 0
  }
}

///|
fn parse_int_or_none(text : String) -> Int32? {
  match parse_int64_opt(text.trim()) {
    Some(value) => Some(value.to_int())
    None => None
  }
}

///|
fn next_marker_of(xml : String) -> Int32? {
  match xml_first(xml, "NextPartNumberMarker") {
    Some(value) => parse_int_or_none(value)
    None => None
  }
}
