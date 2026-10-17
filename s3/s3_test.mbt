///|
priv struct ConstructorOnlyTransport {}

///|
impl @transport.Transport for ConstructorOnlyTransport with fn send(
  self,
  request,
) {
  let _ = (self, request)
  abort("constructor test must not send a request")
}

///|
test "credentials retain explicit and absent session tokens" {
  let permanent = @s3.Credentials::new("test-access", "test-secret")
  assert_eq(permanent.access_key, "test-access")
  assert_true(permanent.secret_key == "test-secret")
  assert_true(permanent.session_token is None)
  let temporary = @s3.Credentials::new(
    "temporary-access",
    "temporary-secret",
    session_token=Some("test-token"),
  )
  assert_eq(temporary.access_key, "temporary-access")
  assert_true(temporary.secret_key == "temporary-secret")
  assert_true(temporary.session_token == Some("test-token"))
}

///|
test "config and client construction preserve addressing and endpoint" {
  let credentials = @s3.Credentials::new("test-access", "test-secret")
  let config = @s3.Config::new(
    "https://storage.example.test/base/", "test-region-1", credentials,
  )
  let client = @s3.Client::new(config, ConstructorOnlyTransport::{ })
  assert_eq(client.config().endpoint, "https://storage.example.test/base/")
  assert_eq(client.config().region, "test-region-1")
  assert_eq(client.config().credentials.access_key, "test-access")
  assert_true(client.config().addressing_style is @s3.Path)
  let virtual_hosted = @s3.Config::new(
    "https://storage.example.test",
    "test-region-2",
    credentials,
    addressing_style=@s3.VirtualHosted,
  )
  assert_true(virtual_hosted.addressing_style is @s3.VirtualHosted)
  assert_eq(virtual_hosted.region, "test-region-2")
}

///|
test "object requests retain raw keys and 64 bit lengths" {
  let request : @s3.PutObjectRequest = {
    bucket: "raw-bucket",
    key: "folder/a b+%2F/中文",
    body: @transport.Empty,
    content_type: Some("application/octet-stream"),
    metadata: Map([("owner", "example")]),
  }
  assert_eq(request.bucket, "raw-bucket")
  assert_eq(request.key, "folder/a b+%2F/中文")
  assert_eq(request.metadata.get("owner"), Some("example"))
  assert_true(request.body is @transport.Empty)
  let copy : @s3.CopyObjectRequest = {
    bucket: "destination",
    key: "new/key",
    source_bucket: request.bucket,
    source_key: request.key,
  }
  assert_eq(copy.source_bucket, "raw-bucket")
  assert_eq(copy.source_key, "folder/a b+%2F/中文")
  let get : @s3.GetObjectRequest = {
    bucket: request.bucket,
    key: request.key,
    range: Some("bytes=4294967296-4294967300"),
  }
  assert_eq(get.range, Some("bytes=4294967296-4294967300"))
  let stat : @s3.StatObjectResponse = {
    content_length: 4294967297L,
    content_type: None,
    metadata: Map([]),
    etag: Some("\"object-etag\""),
    last_modified: None,
  }
  assert_eq(stat.content_length, 4294967297L)
}

///|
test "object listing models retain pagination and common prefixes" {
  let request : @s3.ListObjectsRequest = {
    bucket: "bucket",
    prefix: Some("a/"),
    delimiter: Some("/"),
    continuation_token: Some("opaque+/=token"),
    max_keys: Some(7),
  }
  assert_eq(request.continuation_token, Some("opaque+/=token"))
  assert_eq(request.prefix, Some("a/"))
  assert_eq(request.delimiter, Some("/"))
  assert_eq(request.max_keys, Some(7))
  let response : @s3.ListObjectsResponse = {
    objects: [
      {
        key: "a/large",
        etag: Some("\"object-etag\""),
        size: 4294967297L,
        last_modified: Some("2026-10-16T00:00:00Z"),
      },
    ],
    common_prefixes: ["a/sub/"],
    is_truncated: true,
    next_continuation_token: Some("next+/=token"),
  }
  assert_eq(response.objects[0].size, 4294967297L)
  assert_eq(response.objects[0].etag, Some("\"object-etag\""))
  assert_eq(response.common_prefixes, ["a/sub/"])
  assert_true(response.is_truncated)
  assert_eq(response.next_continuation_token, Some("next+/=token"))
}

///|
test "bucket listing uses continuation_token on both sides" {
  let request : @s3.ListBucketsRequest = {
    prefix: None,
    continuation_token: Some("bucket-page-1"),
    max_buckets: Some(2),
  }
  let response : @s3.ListBucketsResponse = {
    buckets: [{ name: "bucket", creation_date: None, }],
    continuation_token: Some("bucket-page-2"),
  }
  assert_eq(request.continuation_token, Some("bucket-page-1"))
  assert_eq(response.continuation_token, Some("bucket-page-2"))
  assert_eq(response.buckets[0].name, "bucket")
}

///|
test "multipart models preserve upload ETags and long part sizes" {
  let upload : @s3.UploadPartRequest = {
    bucket: "bucket",
    key: "raw key",
    upload_id: "upload-id",
    part_number: 1,
    body: @transport.Bytes(b"part"),
  }
  match upload.body {
    @transport.Bytes(data) => assert_eq(data.length(), 4)
    _ => fail("expected byte body")
  }
  let uploaded : @s3.UploadPartResponse = { etag: "\"uploaded-part-etag\"", }
  let complete : @s3.CompleteMultipartUploadRequest = {
    bucket: upload.bucket,
    key: upload.key,
    upload_id: upload.upload_id,
    parts: [{ part_number: upload.part_number, etag: uploaded.etag, }],
  }
  assert_eq(complete.parts[0].part_number, 1)
  assert_eq(complete.parts[0].etag, "\"uploaded-part-etag\"")
  let completed : @s3.CompleteMultipartUploadResponse = {
    bucket: "bucket",
    key: "raw key",
    etag: "\"complete-etag-2\"",
  }
  assert_eq(completed.etag, "\"complete-etag-2\"")
  let request : @s3.ListPartsRequest = {
    bucket: upload.bucket,
    key: upload.key,
    upload_id: upload.upload_id,
    part_number_marker: Some(1),
    max_parts: Some(10),
  }
  let response : @s3.ListPartsResponse = {
    parts: [
      {
        part_number: 2,
        etag: "\"second-part-etag\"",
        size: 4294967297L,
        last_modified: None,
      },
    ],
    is_truncated: true,
    next_part_number_marker: Some(2),
  }
  assert_eq(request.part_number_marker, Some(1))
  assert_eq(request.max_parts, Some(10))
  assert_eq(response.parts[0].size, 4294967297L)
  assert_eq(response.parts[0].etag, "\"second-part-etag\"")
  assert_true(response.is_truncated)
  assert_eq(response.next_part_number_marker, Some(2))
}

///|
test "service error models retain status and optional request identifiers" {
  let details : @s3.ServiceError = {
    status_code: 404,
    code: "NoSuchKey",
    message: "Object was not found",
    request_id: Some("request-id"),
    host_id: None,
    resource: Some("/blog/articles/x.png"),
  }
  assert_eq(details.status_code, 404)
  assert_eq(details.code, "NoSuchKey")
  assert_eq(details.message, "Object was not found")
  assert_eq(details.request_id, Some("request-id"))
  assert_true(details.host_id is None)
  assert_eq(details.resource, Some("/blog/articles/x.png"))
  let service : @s3.S3Error = @s3.Service(details)
  let transport : @s3.S3Error = @s3.Transport(@transport.Timeout)
  let config : @s3.S3Error = @s3.InvalidConfig("invalid endpoint")
  let request : @s3.S3Error = @s3.InvalidRequest("invalid part number")
  assert_true(service is @s3.Service(_))
  assert_true(transport is @s3.Transport(@transport.Timeout))
  assert_true(config is @s3.InvalidConfig(_))
  assert_true(request is @s3.InvalidRequest(_))
}

///|
test "client async signatures compile without invoking I/O" {
  let _ : async (@s3.Client, @s3.PutObjectRequest) -> @s3.PutObjectResponse raise @s3.S3Error = @s3.Client::put_object
  let _ : async (@s3.Client, @s3.GetObjectRequest) -> @s3.GetObjectResponse raise @s3.S3Error = @s3.Client::get_object
  let _ : async (@s3.Client, @s3.StatObjectRequest) -> @s3.StatObjectResponse raise @s3.S3Error = @s3.Client::stat_object
  let _ : async (@s3.Client, @s3.DeleteObjectRequest) -> @s3.DeleteObjectResponse raise @s3.S3Error = @s3.Client::delete_object
  let _ : async (@s3.Client, @s3.CopyObjectRequest) -> @s3.CopyObjectResponse raise @s3.S3Error = @s3.Client::copy_object
  let _ : async (@s3.Client, @s3.ListObjectsRequest) -> @s3.ListObjectsResponse raise @s3.S3Error = @s3.Client::list_objects
  let _ : async (@s3.Client, @s3.CreateBucketRequest) -> @s3.CreateBucketResponse raise @s3.S3Error = @s3.Client::create_bucket
  let _ : async (@s3.Client, @s3.BucketExistsRequest) -> @s3.BucketExistsResponse raise @s3.S3Error = @s3.Client::bucket_exists
  let _ : async (@s3.Client, @s3.ListBucketsRequest) -> @s3.ListBucketsResponse raise @s3.S3Error = @s3.Client::list_buckets
  let _ : async (@s3.Client, @s3.DeleteBucketRequest) -> @s3.DeleteBucketResponse raise @s3.S3Error = @s3.Client::delete_bucket
  let _ : async (@s3.Client, @s3.CreateMultipartUploadRequest) -> @s3.CreateMultipartUploadResponse raise @s3.S3Error = @s3.Client::create_multipart_upload
  let _ : async (@s3.Client, @s3.UploadPartRequest) -> @s3.UploadPartResponse raise @s3.S3Error = @s3.Client::upload_part
  let _ : async (@s3.Client, @s3.CompleteMultipartUploadRequest) -> @s3.CompleteMultipartUploadResponse raise @s3.S3Error = @s3.Client::complete_multipart_upload
  let _ : async (@s3.Client, @s3.AbortMultipartUploadRequest) -> @s3.AbortMultipartUploadResponse raise @s3.S3Error = @s3.Client::abort_multipart_upload
  let _ : async (@s3.Client, @s3.ListPartsRequest) -> @s3.ListPartsResponse raise @s3.S3Error = @s3.Client::list_parts
}

///|
test "get response body remains closable through the transport port" {
  let _ : (@s3.GetObjectResponse) -> Unit = response => response.body.close()
  let _ : (@s3.GetObjectResponse) -> Int64 = response => response.content_length
  let _ : (@s3.GetObjectResponse) -> String? = response => {
    response.content_range
  }
  let _ : (@s3.GetObjectResponse) -> String? = response => {
    response.accept_ranges
  }
  let _ : (@s3.GetObjectResponse) -> String? = response => response.etag
}
