///|
/// Live coverage for the five-step manual multipart upload, presigned GET and
/// the argument guards that must refuse before anything reaches the wire.
/// Skipped (loudly) when the environment is absent — a skip is not a pass.

///|
fn block_of(size_kib : Int32, byte : Byte) -> Bytes {
  let chunk : Array[Byte] = []
  for i = 0; i < 1024; i = i + 1 {
    chunk.push(byte)
  }
  let out : Array[Byte] = []
  for i = 0; i < size_kib; i = i + 1 {
    out.append(chunk)
  }
  Bytes::from_array(out.exact_view())
}

///|
async fn live_multipart_round_trip(
  endpoint : String,
  bucket : String,
  region : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = make_live_client(endpoint, region, access_key, secret_key, calls)
  let prefix = live_case_prefix("multipart")
  let key = prefix + "big.bin"
  let init_request : @s3.CreateMultipartUploadRequest = {
    bucket,
    key,
    content_type: None,
    metadata: Map([]),
  }
  let upload = client.create_multipart_upload(init_request)
  println(
    "multipart upload_id present=" + (upload.upload_id.length() > 0).to_string(),
  )
  assert_true(upload.upload_id.length() > 0)
  // Every part but the last must be at least 5 MiB, so the first block is
  // exactly that and the second is the short tail.
  let first = block_of(5120, (65).to_byte())
  let second = block_of(1024, (66).to_byte())
  let part_one : @s3.UploadPartRequest = {
    bucket,
    key,
    upload_id: upload.upload_id,
    part_number: 1,
    body: @transport.RequestBody::Bytes(first),
  }
  let etag_one = client.upload_part(part_one).etag
  println("multipart part 1 etag length=" + etag_one.length().to_string())
  assert_true(!etag_one.is_empty())
  let part_two : @s3.UploadPartRequest = {
    bucket,
    key,
    upload_id: upload.upload_id,
    part_number: 2,
    body: @transport.RequestBody::Bytes(second),
  }
  let etag_two = client.upload_part(part_two).etag
  let list_request : @s3.ListPartsRequest = {
    bucket,
    key,
    upload_id: upload.upload_id,
    part_number_marker: None,
    max_parts: None,
  }
  let listed = client.list_parts(list_request)
  println("multipart listed parts=" + listed.parts.length().to_string())
  assert_eq(listed.parts.length(), 2)
  assert_eq(listed.parts[0].size, 5120L * 1024L)
  assert_eq(listed.parts[1].size, 1024L * 1024L)
  let complete_request : @s3.CompleteMultipartUploadRequest = {
    bucket,
    key,
    upload_id: upload.upload_id,
    parts: [
      { part_number: 1, etag: etag_one, },
      { part_number: 2, etag: etag_two, },
    ],
  }
  let completed = client.complete_multipart_upload(complete_request)
  println(
    "multipart complete etag length=" + completed.etag.length().to_string(),
  )
  assert_true(!completed.etag.is_empty())
  let stat_request : @s3.StatObjectRequest = { bucket, key, }
  let merged = client.stat_object(stat_request)
  let merged_size = merged.content_length.to_string()
  println("multipart merged size=" + merged_size)
  assert_eq(merged.content_length, 6144L * 1024L)
  let get_request : @s3.GetObjectRequest = { bucket, key, range: None, }
  let fetched = client.get_object(get_request)
  let bytes = drain(fetched.body)
  assert_eq(bytes.length(), 6144 * 1024)
  assert_true(bytes[0] == (65).to_byte())
  assert_true(bytes[6144 * 1024 - 1] == (66).to_byte())
  let delete_request : @s3.DeleteObjectRequest = { bucket, key, }
  let _ = client.delete_object(delete_request)
  let residue = sweep_reported(client, bucket, prefix, calls)
  assert_eq(residue, 0)
}

///|
async test "live MinIO: manual multipart five steps" {
  match read_live_env() {
    None => report_skip()
    Some((endpoint, bucket, region, access_key, secret_key)) =>
      live_multipart_round_trip(
        endpoint, bucket, region, access_key, secret_key,
      )
  }
}

///|
async fn live_presigned_get(
  endpoint : String,
  bucket : String,
  region : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = make_live_client(endpoint, region, access_key, secret_key, calls)
  let prefix = live_case_prefix("presign")
  let key = prefix + "share.txt"
  let payload = @utf8.encode("presigned body\n".view())
  let put_request : @s3.PutObjectRequest = {
    bucket,
    key,
    body: @transport.RequestBody::Bytes(payload),
    content_type: None,
    metadata: Map([]),
  }
  let _ = client.put_object(put_request)
  let url = client.presigned_get_url(bucket, key, 900)
  assert_true(url.find("X-Amz-Signature=") is Some(_))
  let bare : &@transport.Transport = @transport.AsyncHttpTransport::new()
  // No Authorization header: everything the fetch needs is in the query.
  let request : @transport.Request = {
    http_method: Get,
    url,
    headers: [],
    body: @transport.RequestBody::Empty,
  }
  let response = bare.send(request)
  println("presigned GET status=" + response.status.to_string())
  assert_eq(response.status, 200)
  let bytes = drain(response.body)
  assert_true(bytes.equal(payload))
  // Flip the last character of the signature: the same URL must now be refused.
  let mark = url.length() - 1
  let stem = url[0:mark].to_owned()
  let last = url[mark:url.length()].to_owned()
  let flipped = if last == "a" { "b" } else { "a" }
  let broken = stem + flipped
  let tampered : @transport.Request = {
    http_method: Get,
    url: broken,
    headers: [],
    body: @transport.RequestBody::Empty,
  }
  let refused = bare.send(tampered)
  println("tampered presigned GET status=" + refused.status.to_string())
  assert_true(refused.status == 403)
  refused.body.close()
  let delete_request : @s3.DeleteObjectRequest = { bucket, key, }
  let _ = client.delete_object(delete_request)
  let residue = sweep_reported(client, bucket, prefix, calls)
  assert_eq(residue, 0)
}

///|
async test "live MinIO: presigned URL fetches without credentials" {
  match read_live_env() {
    None => report_skip()
    Some((endpoint, bucket, region, access_key, secret_key)) =>
      live_presigned_get(endpoint, bucket, region, access_key, secret_key)
  }
}

///|
/// Guards must refuse before signing: an out-of-range part number that still
/// reached the wire would leave a stray upload on the shared server.
async test "live MinIO: part number guards send no request" {
  let (endpoint, bucket, region, access_key, secret_key) = match
    read_live_env() {
    None => {
      report_skip()
      return
    }
    Some(values) => values
  }
  let calls : Array[LiveCall] = []
  let client = make_live_client(endpoint, region, access_key, secret_key, calls)
  for number in [0, 10001] {
    let request : @s3.UploadPartRequest = {
      bucket,
      key: "unused",
      upload_id: "unused",
      part_number: number,
      body: @transport.RequestBody::Empty,
    }
    let reading = try {
      let _ = client.upload_part(request)
      "no-error"
    } catch {
      @s3.InvalidRequest(detail) => "InvalidRequest " + detail
      _ => "other"
    }
    println("part_number " + number.to_string() + " -> " + reading)
    assert_true(reading.has_prefix("InvalidRequest"))
  }
  assert_eq(calls.length(), 0)
}
