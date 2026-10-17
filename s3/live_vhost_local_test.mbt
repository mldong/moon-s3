///|
// Virtual-hosted addressing driven by **our client** against a one-shot S3
// endpoint, given by `S3_VHL_ENDPOINT`. Stage A could only assert the URL string,
// because the shared MinIO ignores the bucket name in `Host` entirely
// (A 卡 §7-20), and this box has no container runtime (C 卡 §7-7).
//
// Two vehicles have run this case, and they cover different halves:
//   - a MinIO started for this round with `MINIO_DOMAIN` (the brand-level read) —
//     it parses the bucket out of `Host` **and** verifies signatures;
//   - `moto_server` on 127.0.0.1 (no docker needed) — it parses the bucket too,
//     but answers 200 to a wrong secret, so it proves addressing only.
// What this case asserts either way: two self-named buckets stay apart, an
// absent bucket answers `NoSuchBucket`, and every recorded request carries the
// bucket in the authority rather than in the path.
//
// Env: S3_VHL_ENDPOINT / S3_VHL_AK / S3_VHL_SK (region fixed to us-east-1).
// Missing variables are a loud skip, not a pass. Buckets are self-named for this
// run and deleted at the end.

///|
fn read_vhl_env() -> (String, String, String)? {
  let endpoint = @env.get_env_var("S3_VHL_ENDPOINT")
  let access_key = @env.get_env_var("S3_VHL_AK")
  let secret_key = @env.get_env_var("S3_VHL_SK")
  match (endpoint, access_key, secret_key) {
    (Some(e), Some(a), Some(s)) => Some((e, a, s))
    _ => None
  }
}

///|
fn report_vhl_skip() -> Unit {
  let names : Array[String] = ["S3_VHL_ENDPOINT", "S3_VHL_AK", "S3_VHL_SK"]
  let missing : Array[String] = []
  for name in names {
    if @env.get_env_var(name) is None {
      missing.push(name)
    }
  }
  println("SKIP local virtual-hosted check, environment not supplied")
  println("missing: " + missing.join(", "))
  println(
    "SKIP IS NOT A PASS: virtual-hosted addressing was not run against a local endpoint by this run.",
  )
}

///|
async fn vhl_put(
  client : @s3.Client,
  bucket : String,
  key : String,
  text : String,
) -> Unit {
  let body = @utf8.encode(text)
  let _ = client.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(body),
    content_type: Some("text/plain"),
    metadata: Map([]),
  }) catch {
    error => fail("put " + bucket + "/" + key + ": " + render_error(error))
  }
}

///|
async fn vhl_keys(client : @s3.Client, bucket : String) -> Array[String] {
  let listing = client.list_objects({
    bucket,
    prefix: None,
    delimiter: None,
    continuation_token: None,
    max_keys: Some(100),
  }) catch {
    error => fail("list " + bucket + ": " + render_error(error))
  }
  let keys : Array[String] = []
  for object in listing.objects {
    keys.push(object.key)
  }
  keys
}

///|
async fn vhl_exists(client : @s3.Client, bucket : String) -> Bool {
  let probe = client.bucket_exists({ bucket, }) catch {
    error => fail("bucket_exists " + bucket + ": " + render_error(error))
  }
  probe.exists
}

///|
/// `*_test.mbt` is the black-box package, so the SDK's private body reader is
/// out of reach here — the public `ResponseBody.read` loop is what a consumer
/// would actually write. The fixture is ASCII, so decoding chunk by chunk cannot
/// split a multibyte character.
async fn vhl_read_text(body : &@transport.ResponseBody) -> String {
  let buf = StringBuilder()
  let mut done = false
  while !done {
    let chunk = body.read(65536) catch {
      error => fail("read body: " + vhl_transport_text(error))
    }
    match chunk {
      None => done = true
      Some(data) => buf.write_string(@utf8.decode_lossy(data))
    }
  }
  body.close()
  buf.to_string()
}

///|
/// `TransportError` has no `Show` instance in this toolchain, so the reading is
/// spelled out rather than printed through a method that does not exist.
fn vhl_transport_text(error : @transport.TransportError) -> String {
  match error {
    @transport.TransportError::Network(msg) => "Network: " + msg
    @transport.TransportError::Timeout => "Timeout"
    @transport.TransportError::InvalidRequest(msg) => "InvalidRequest: " + msg
    @transport.TransportError::InvalidResponse(msg) => "InvalidResponse: " + msg
  }
}

///|
async fn live_local_virtual_hosted(
  endpoint : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let inner : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let spy : &@transport.Transport = LiveTransport::{ inner, calls, }
  let config = @s3.Config::new(
    endpoint,
    "us-east-1",
    @s3.Credentials::new(access_key, secret_key),
    addressing_style=VirtualHosted,
  )
  let client = @s3.Client::new(config, spy)
  let (date, _) = @s3.utc_stamps(@env.now().reinterpret_as_int64())
  let bucket_a = "moonfs-vh-a-" + date
  let bucket_b = "moonfs-vh-b-" + date
  let absent = "moonfs-vh-gone-" + date

  for bucket in [bucket_a, bucket_b] {
    let _ = client.create_bucket({ bucket, }) catch {
      error => fail("create_bucket " + bucket + ": " + render_error(error))
    }
  }
  vhl_put(client, bucket_a, "only-in-a.txt", "payload only in A")
  vhl_put(
    client, bucket_b, "only-in-b.txt", "payload only in B, longer than A's",
  )

  // The judgment is per-bucket isolation: an endpoint that ignored `Host` would
  // answer with the account's bucket list or with both keys, which is what a Host-ignoring endpoint does.
  let keys_a = vhl_keys(client, bucket_a)
  let keys_b = vhl_keys(client, bucket_b)
  assert_eq(keys_a, ["only-in-a.txt"])
  assert_eq(keys_b, ["only-in-b.txt"])

  let read = client.get_object({
    bucket: bucket_a,
    key: "only-in-a.txt",
    range: None,
  }) catch {
    error => fail("get through vhost: " + render_error(error))
  }
  let text = vhl_read_text(read.body)
  assert_eq(text, "payload only in A")

  let present_a = vhl_exists(client, bucket_a)
  let present_gone = vhl_exists(client, absent)
  assert_true(present_a)
  assert_true(!present_gone)

  // 形状检查覆盖**每一条**请求，不是挑最后一条：上一版就是取末条时正好落在
  // "查不存在的桶"那一步上，把自家的断言写成了假红。
  show_calls(calls)
  let total = calls.length()
  let mut off_host = 0
  let mut bucket_in_path = 0
  let mut object_call_ok = false
  for call in calls {
    if call.url.find("http://" + bucket_a + ".") is None &&
      call.url.find("http://" + bucket_b + ".") is None &&
      call.url.find("http://" + absent + ".") is None {
      off_host = off_host + 1
    }
    if call.url.find("/" + bucket_a + "/") is Some(_) ||
      call.url.find("/" + bucket_b + "/") is Some(_) {
      bucket_in_path = bucket_in_path + 1
    }
    if call.url.find("only-in-a.txt") is Some(_) {
      let on_a = call.url.has_prefix("http://" + bucket_a + ".")
      object_call_ok = on_a && call.url.find("/only-in-a.txt") is Some(_)
    }
  }
  let head = "recorded " + total.to_string() + " requests"
  let counts = " off-host=" +
    off_host.to_string() +
    " bucket-in-path=" +
    bucket_in_path.to_string()
  println(head + " " + counts)
  assert_true(total >= 6)
  assert_eq(off_host, 0)
  assert_eq(bucket_in_path, 0)
  assert_true(object_call_ok)

  for bucket in [bucket_a, bucket_b] {
    for key in vhl_keys(client, bucket) {
      let _ = client.delete_object({ bucket, key, }) catch {
        error =>
          fail("delete " + bucket + "/" + key + ": " + render_error(error))
      }
    }
    let _ = client.delete_bucket({ bucket, }) catch {
      error => fail("delete_bucket " + bucket + ": " + render_error(error))
    }
    let left = vhl_exists(client, bucket)
    assert_true(!left)
  }
}

///|
async test "live local endpoint: our client's virtual-hosted requests resolve per bucket" {
  match read_vhl_env() {
    None => report_vhl_skip()
    Some(environment) =>
      live_local_virtual_hosted(environment.0, environment.1, environment.2)
  }
}
