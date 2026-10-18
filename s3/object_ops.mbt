///|
fn meta_headers(metadata : Map[String, String]) -> Array[@transport.Header] {
  let out : Array[@transport.Header] = []
  for (key, value) in metadata {
    let header : @transport.Header = { name: "x-amz-meta-" + key, value, }
    out.push(header)
  }
  out
}

///|
fn optional_header(
  out : Array[@transport.Header],
  name : String,
  value : String?,
) -> Unit {
  match value {
    Some(text) => {
      let header : @transport.Header = { name, value: text, }
      out.push(header)
    }
    None => ()
  }
}

///|
pub async fn Client::put_object(
  self : Client,
  request : PutObjectRequest,
) -> PutObjectResponse raise S3Error {
  let headers = meta_headers(request.metadata)
  optional_header(headers, "content-type", request.content_type)
  let spec : RequestSpec = {
    http_method: Put,
    bucket: request.bucket,
    key: request.key,
    query: [],
    body: request.body,
    headers,
  }
  let response = self.execute(spec)
  let etag = match header_value(response.headers, "etag") {
    Some(value) => value
    None => ""
  }
  PutObjectResponse::{ etag, }
}

///|
pub async fn Client::get_object(
  self : Client,
  request : GetObjectRequest,
) -> GetObjectResponse raise S3Error {
  let headers : Array[@transport.Header] = []
  optional_header(headers, "range", request.range)
  let spec : RequestSpec = {
    http_method: Get,
    bucket: request.bucket,
    key: request.key,
    query: [],
    body: @transport.RequestBody::Empty,
    headers,
  }
  let response = self.execute(spec)
  let body = response.body
  let length = match int64_header(response.headers, "content-length") {
    Some(value) => value
    None => 0L
  }
  GetObjectResponse::{
    content_length: length,
    content_type: header_value(response.headers, "content-type"),
    metadata: response_user_metadata(response.headers),
    content_range: header_value(response.headers, "content-range"),
    accept_ranges: header_value(response.headers, "accept-ranges"),
    etag: header_value(response.headers, "etag"),
    body,
  }
}

///|
/// User metadata comes back as `x-amz-meta-*`; the prefix is stripped because
/// that is how the caller named it in the first place.
pub fn response_user_metadata(
  headers : Array[@transport.Header],
) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for header in headers {
    let name = header.name.to_lower()
    if name.has_prefix("x-amz-meta-") {
      let key = name[11:name.length()].to_owned()
      out[key] = header.value
    }
  }
  out
}

///|
pub async fn Client::stat_object(
  self : Client,
  request : StatObjectRequest,
) -> StatObjectResponse raise S3Error {
  let spec : RequestSpec = {
    http_method: Head,
    bucket: request.bucket,
    key: request.key,
    query: [],
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let response = self.execute(spec)
  let length = match int64_header(response.headers, "content-length") {
    Some(value) => value
    None => 0L
  }
  StatObjectResponse::{
    content_length: length,
    content_type: header_value(response.headers, "content-type"),
    metadata: response_user_metadata(response.headers),
    etag: header_value(response.headers, "etag"),
    last_modified: header_value(response.headers, "last-modified"),
  }
}

///|
pub async fn Client::delete_object(
  self : Client,
  request : DeleteObjectRequest,
) -> DeleteObjectResponse raise S3Error {
  let spec : RequestSpec = {
    http_method: Delete,
    bucket: request.bucket,
    key: request.key,
    query: [],
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let response = self.execute(spec)
  let marker = match header_value(response.headers, "x-amz-delete-marker") {
    Some("true") => Some(true)
    _ => Some(false)
  }
  DeleteObjectResponse::{
    delete_marker: marker,
    version_id: header_value(response.headers, "x-amz-version-id"),
  }
}

///|
pub async fn Client::copy_object(
  self : Client,
  request : CopyObjectRequest,
) -> CopyObjectResponse raise S3Error {
  if request.bucket.is_empty() || request.key.is_empty() {
    raise InvalidRequest("copy_object needs a destination bucket and key")
  }
  if request.source_bucket.is_empty() || request.source_key.is_empty() {
    raise InvalidRequest("copy_object needs a source bucket and key")
  }
  let headers : Array[@transport.Header] = []
  let source_head = "/" + request.source_bucket + "/"
  let source_tail = @sigv4.encode_object_key(request.source_key)
  let source = source_head + source_tail
  let source_header : @transport.Header = {
    name: "x-amz-copy-source",
    value: source,
  }
  headers.push(source_header)
  let spec : RequestSpec = {
    http_method: Put,
    bucket: request.bucket,
    key: request.key,
    query: [],
    body: @transport.RequestBody::Empty,
    headers,
  }
  let response = self.execute(spec)
  let body = response.body
  let raw = read_all(body)
  body.close()
  let xml = response_text(raw, response.status)
  let etag = match xml_first(xml, "ETag") {
    Some(value) => value
    None => ""
  }
  CopyObjectResponse::{ etag, last_modified: xml_first(xml, "LastModified"), }
}

///|
pub async fn Client::list_objects(
  self : Client,
  request : ListObjectsRequest,
) -> ListObjectsResponse raise S3Error {
  if request.bucket.is_empty() {
    raise InvalidRequest("list_objects needs a bucket")
  }
  let query : Array[@sigv4.QueryPair] = []
  let version : @sigv4.QueryPair = { key: "list-type", value: "2", }
  query.push(version)
  optional_pair(query, "prefix", request.prefix)
  optional_pair(query, "delimiter", request.delimiter)
  optional_pair(query, "continuation-token", request.continuation_token)
  match request.max_keys {
    Some(value) => {
      let pair : @sigv4.QueryPair = {
        key: "max-keys",
        value: value.to_string(),
      }
      query.push(pair)
    }
    None => ()
  }
  let spec : RequestSpec = {
    http_method: Get,
    bucket: request.bucket,
    key: "",
    query,
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let response = self.execute(spec)
  let body = response.body
  let raw = read_all(body)
  body.close()
  let xml = response_text(raw, response.status)
  let objects : Array[ObjectInfo] = []
  for block in xml_sections(xml, "Contents") {
    let info : ObjectInfo = {
      key: match xml_first(block, "Key") {
        Some(value) => value
        None => ""
      },
      etag: xml_first(block, "ETag"),
      size: parse_int64_or_zero(xml_first(block, "Size")),
      last_modified: xml_first(block, "LastModified"),
    }
    objects.push(info)
  }
  let truncated = match xml_first(xml, "IsTruncated") {
    Some("true") => true
    _ => false
  }
  ListObjectsResponse::{
    objects,
    common_prefixes: common_prefixes_of(xml),
    is_truncated: truncated,
    next_continuation_token: xml_first(xml, "NextContinuationToken"),
  }
}

///|
/// `CommonPrefixes` wraps a `Prefix` element, and the response also echoes the
/// request's own `Prefix` at the top level — reading bare `Prefix` would mix
/// the two, so only the wrapped ones are taken.
fn common_prefixes_of(xml : String) -> Array[String] {
  let out : Array[String] = []
  for block in xml_sections(xml, "CommonPrefixes") {
    match xml_first(block, "Prefix") {
      Some(prefix) => out.push(prefix)
      None => ()
    }
  }
  out
}

///|
/// A missing or malformed `Size` reads as 0 rather than failing the listing;
/// the key and ETag are what the caller keys off.
fn parse_int64_or_zero(text : String?) -> Int64 {
  match text {
    Some(value) =>
      match parse_int64_opt(value.trim()) {
        Some(parsed) => parsed
        None => 0L
      }
    None => 0L
  }
}

///|
fn optional_pair(
  query : Array[@sigv4.QueryPair],
  key : String,
  value : String?,
) -> Unit {
  match value {
    Some(text) => {
      let pair : @sigv4.QueryPair = { key, value: text, }
      query.push(pair)
    }
    None => ()
  }
}

///|
/// A presigned URL: the signature travels in the query, so any client can use it
/// without holding credentials. `Get` hands out a download, `Put` hands out a
/// direct upload — the verb is what the signature covers, so the two are not
/// interchangeable. The expiry is validated here rather than left for the service
/// to reject.
pub fn Client::presigned_url(
  self : Client,
  bucket : String,
  key : String,
  verb : @transport.Method,
  expires_seconds : Int32,
) -> String raise S3Error {
  if bucket.is_empty() || key.is_empty() {
    raise InvalidRequest("presigned_url needs a bucket and key")
  }
  let unsigned : @transport.Request = {
    http_method: verb,
    url: build_object_url(self.config, bucket, key),
    headers: [],
    body: @transport.RequestBody::Empty,
  }
  let (_, timestamp) = now_stamps()
  let presigned = @sigv4.presign(
    unsigned,
    self.config.credentials,
    self.config.region,
    timestamp,
    expires_seconds,
  ) catch {
    @sigv4.SigningError::InvalidInput(detail) => raise InvalidConfig(detail)
  }
  presigned.url
}

///|
pub fn Client::presigned_get_url(
  self : Client,
  bucket : String,
  key : String,
  expires_seconds : Int32,
) -> String raise S3Error {
  self.presigned_url(bucket, key, @transport.Method::Get, expires_seconds)
}
