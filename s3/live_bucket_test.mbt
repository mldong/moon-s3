///|
// Bucket family against the shared MinIO supplied via `S3_LIVE_*` (owner
// 2026-10-16: that server is a test environment, and a bucket this run names for itself
// may be created, written, listed and deleted).
//
// The only bucket this file touches is `moonfs-c2-<YYYYMMDD>`: nothing here reads
// or changes `uploads/`, `202608/`, `articles/` or any other existing bucket. The
// run begins by clearing a leftover of that exact name (a crashed earlier round)
// and ends by asserting the name is gone from the listing — so "created" and
// "deleted" are both readings, not assumptions.

///|
fn bucket_case_name() -> String {
  let (date, _) = @s3.utc_stamps(@env.now().reinterpret_as_int64())
  "moonfs-c2-" + date
}

///|
async fn bucket_listing(client : @s3.Client) -> Array[String] {
  let listed = client.list_buckets(@s3.ListBucketsRequest::{
    prefix: None,
    continuation_token: None,
    max_buckets: None,
  }) catch {
    error => fail("list_buckets: " + render_error(error))
  }
  let names : Array[String] = []
  for bucket in listed.buckets {
    names.push(bucket.name)
  }
  names
}

///|
fn has_name(names : Array[String], name : String) -> Bool {
  let mut found = false
  for item in names {
    if item == name {
      found = true
    }
  }
  found
}

///|
async fn empty_bucket(client : @s3.Client, bucket : String) -> Unit {
  let listing = client.list_objects({
    bucket,
    prefix: None,
    delimiter: None,
    continuation_token: None,
    max_keys: Some(1000),
  }) catch {
    // A bucket that is not there has nothing to empty; anything else is a real
    // failure and must not be swallowed.
    error => fail("sweep of " + bucket + ": " + render_error(error))
  }
  for object in listing.objects {
    let _ = client.delete_object({ bucket, key: object.key, }) catch {
      error => fail("delete " + object.key + ": " + render_error(error))
    }
  }
}

///|
async fn exists_now(client : @s3.Client, bucket : String) -> Bool {
  let probe = client.bucket_exists({ bucket, }) catch {
    error => fail("bucket_exists " + bucket + ": " + render_error(error))
  }
  probe.exists
}

///|
async fn live_bucket_family(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = make_live_client(endpoint, region, access_key, secret_key, calls)
  let bucket = bucket_case_name()
  println("bucket family case runs on " + bucket)

  // Precondition: clear a leftover of this exact self-named bucket, then prove it
  // is absent. Without this, a crashed earlier run would make "created" read as a
  // pass while nothing was created.
  if exists_now(client, bucket) {
    println(
      bucket + " already exists from an earlier run; emptying and deleting",
    )
    empty_bucket(client, bucket)
    let _ = client.delete_bucket({ bucket, }) catch {
      error => fail("pre-cleanup delete_bucket: " + render_error(error))
    }
  }
  let absent_before = exists_now(client, bucket)
  assert_true(!absent_before)

  let created = client.create_bucket({ bucket, }) catch {
    error => fail("create_bucket: " + render_error(error))
  }
  println(
    "create_bucket location reading: " + created.location.unwrap_or("(none)"),
  )
  let present = exists_now(client, bucket)
  assert_true(present)
  let names = bucket_listing(client)
  assert_true(has_name(names, bucket))

  let key = "at-root/hello.txt"
  let body = @utf8.encode("moon-file-storage bucket family probe")
  let _ = client.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(body),
    content_type: Some("text/plain"),
    metadata: Map([]),
  }) catch {
    error => fail("put_object: " + render_error(error))
  }
  let stat = client.stat_object({ bucket, key, }) catch {
    error => fail("stat_object: " + render_error(error))
  }
  assert_eq(stat.content_length, body.length().to_int64())

  // A non-empty bucket must refuse to be deleted: that is the difference between
  // "delete_bucket sent a request" and "delete_bucket means what it says".
  let refused = try {
    let _ = client.delete_bucket({ bucket, })
    "no-error"
  } catch {
    error => render_error(error)
  }
  show_calls(calls)
  if refused == "no-error" {
    fail("delete_bucket removed a bucket that still held an object")
  }
  let still_there = exists_now(client, bucket)
  assert_true(still_there)

  empty_bucket(client, bucket)
  let _ = client.delete_bucket({ bucket, }) catch {
    error => fail("delete_bucket: " + render_error(error))
  }
  let gone = exists_now(client, bucket)
  let after = bucket_listing(client)
  assert_true(!gone)
  assert_true(!has_name(after, bucket))
}

///|
async test "live MinIO: bucket family create / exists / list / delete" {
  match read_live_env() {
    None => report_skip()
    Some(environment) =>
      live_bucket_family(
        environment.0,
        environment.2,
        environment.3,
        environment.4,
      )
  }
}
