///|
pub async fn Client::create_bucket(
  self : Client,
  request : CreateBucketRequest,
) -> CreateBucketResponse raise S3Error {
  if request.bucket.is_empty() {
    raise InvalidRequest("create_bucket needs a bucket name")
  }
  let spec : RequestSpec = {
    http_method: Put,
    bucket: request.bucket,
    key: "",
    query: [],
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let response = self.execute(spec)
  let body = response.body
  let raw = read_all(body)
  let xml = @utf8.decode_lossy(raw)
  body.close()
  CreateBucketResponse::{ location: xml_first(xml, "Location"), }
}

///|
/// A bucket probe answers with a status, not a document — so 404 means "no
/// such bucket" here rather than being an error worth propagating.
pub async fn Client::bucket_exists(
  self : Client,
  request : BucketExistsRequest,
) -> BucketExistsResponse raise S3Error {
  if request.bucket.is_empty() {
    raise InvalidRequest("bucket_exists needs a bucket name")
  }
  let spec : RequestSpec = {
    http_method: Head,
    bucket: request.bucket,
    key: "",
    query: [],
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let exists = try {
    let probe = self.execute(spec)
    probe.body.close()
    true
  } catch {
    Service(details) =>
      if details.status_code == 403 || details.status_code == 404 {
        false
      } else {
        raise Service(details)
      }
    error => raise error
  }
  BucketExistsResponse::{ exists, }
}

///|
pub async fn Client::list_buckets(
  self : Client,
  request : ListBucketsRequest,
) -> ListBucketsResponse raise S3Error {
  let query : Array[@sigv4.QueryPair] = []
  optional_pair(query, "prefix", request.prefix)
  optional_pair(query, "continuation-token", request.continuation_token)
  optional_pair(
    query,
    "max-buckets",
    match request.max_buckets {
      Some(value) => Some(value.to_string())
      None => None
    },
  )
  let spec : RequestSpec = {
    http_method: Get,
    bucket: "",
    key: "",
    query,
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let response = self.execute(spec)
  let body = response.body
  let raw = read_all(body)
  let xml = @utf8.decode_lossy(raw)
  body.close()
  let buckets : Array[BucketInfo] = []
  for block in xml_all(xml, "Bucket") {
    let info : BucketInfo = {
      name: read_required(block, "Name", ""),
      creation_date: xml_first(block, "CreationDate"),
    }
    buckets.push(info)
  }
  ListBucketsResponse::{
    buckets,
    continuation_token: xml_first(xml, "ContinuationToken"),
  }
}

///|
pub async fn Client::delete_bucket(
  self : Client,
  request : DeleteBucketRequest,
) -> DeleteBucketResponse raise S3Error {
  if request.bucket.is_empty() {
    raise InvalidRequest("delete_bucket needs a bucket name")
  }
  let spec : RequestSpec = {
    http_method: Delete,
    bucket: request.bucket,
    key: "",
    query: [],
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let _ = self.execute(spec)
  DeleteBucketResponse::{ }
}
