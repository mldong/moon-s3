///|
// Virtual-hosted traffic against Tencent COS's S3-compatible endpoint, named by
// S3_COS_ENDPOINT / S3_COS_REGION / S3_COS_BUCKET / S3_COS_AK / S3_COS_SK.
//
// Why this needs its own link instead of borrowing MinIO's reading: COS refuses
// path-style on every bucket created after 2024-01-01, so the very same client
// that passes elsewhere has to be re-measured here with the bucket folded into
// `Host`. The official compatibility guide spells out the shape (endpoint
// `cos.<region>.myqcloud.com`, bucket name carrying the APPID suffix, virtual
// hosted only), and this file is the measurement behind those three lines — not
// a restatement of them.
//
// Credentials are env-driven and never printed: only verb, path, status, ETag
// and sizes reach the log. Everything written lives under
// `moonfs-live-<YYYYMMDD>/cos-*`; each case deletes what it made and re-lists
// **its own** prefix expecting zero residue. A missing variable, or an endpoint
// that does not answer the 8s preflight, is a loud skip — the output itself says
// the run proved nothing.

///|

///|
/// Empty counts as absent: the local gate script exports the whole family of
/// variables even when a platform's credentials were never configured, and an
/// empty string would otherwise reach the client as a "supplied" endpoint and
/// produce a confusing "endpoint did not answer" instead of this case's own
/// "environment not supplied" skip with the missing names listed.
fn env_or_none(name : String) -> String? {
  match @env.get_env_var(name) {
    Some(value) => if value.is_empty() { None } else { Some(value) }
    None => None
  }
}

///|
fn read_cos_env() -> (String, String, String, String, String)? {
  let endpoint = env_or_none("S3_COS_ENDPOINT")
  let region = env_or_none("S3_COS_REGION")
  let bucket = env_or_none("S3_COS_BUCKET")
  let access_key = env_or_none("S3_COS_AK")
  let secret_key = env_or_none("S3_COS_SK")
  match (endpoint, region, bucket, access_key, secret_key) {
    (Some(e), Some(r), Some(b), Some(a), Some(s)) => Some((e, r, b, a, s))
    _ => None
  }
}

///|
fn report_cos_skip() -> Unit {
  let names : Array[String] = [
    "S3_COS_ENDPOINT", "S3_COS_REGION", "S3_COS_BUCKET", "S3_COS_AK", "S3_COS_SK",
  ]
  let missing : Array[String] = []
  for name in names {
    if @env.get_env_var(name) is None {
      missing.push(name)
    }
  }
  println("SKIP live COS compatibility check, environment not supplied")
  println("missing: " + missing.join(", "))
  println(
    "SKIP IS NOT A PASS: COS was not exercised through the S3-compatible path by this run.",
  )
}

///|
/// A client built the way the official guide says to build it: real region in
/// the scope, `addressing_style=VirtualHosted`, bucket carrying the APPID.
fn cos_client(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
  style : @s3.AddressingStyle,
  calls : Array[LiveCall],
) -> @s3.Client {
  let config = @s3.Config::new(
    endpoint,
    region,
    @s3.Credentials::new(access_key, secret_key),
    addressing_style=style,
  )
  let base : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let spy : &@transport.Transport = LiveTransport::{ inner: base, calls, }
  @s3.Client::new(config, spy)
}

///|
/// Reachability only: a link we could not open must not be read as a behaviour
/// change. Any HTTP answer at all keeps the assertions below in force.
async fn cos_preflight(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
  bucket : String,
) -> (Bool, String) {
  let calls : Array[LiveCall] = []
  let config = @s3.Config::new(
    endpoint,
    region,
    @s3.Credentials::new(access_key, secret_key),
    addressing_style=@s3.AddressingStyle::VirtualHosted,
  )
  let base : &@transport.Transport = @transport.AsyncHttpTransport::new(
    timeout=8000,
  )
  let spy : &@transport.Transport = LiveTransport::{ inner: base, calls, }
  let client = @s3.Client::new(config, spy)
  let answered = try {
    let response = client.get_object({
      bucket,
      key: "moonfs-probe/does-not-need-to-exist.txt",
      range: None,
    })
    response.body.close()
    "200"
  } catch {
    error => service_reading(error).1
  }
  (
    calls.length() > 0,
    "cos preflight: answered=" +
    answered +
    " recorded=" +
    calls.length().to_string(),
  )
}

///|
async fn cos_guarded(
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
  body : async (Array[Int64], String, String, String, String, String) -> Unit,
) -> Unit {
  let preflight = cos_preflight(
    endpoint, region, access_key, secret_key, bucket,
  )
  if !preflight.0 {
    println(preflight.1)
    println("SKIP live COS compatibility check, endpoint did not answer")
    println(
      "SKIP IS NOT A PASS: COS was not exercised through the S3-compatible path by this run.",
    )
    return
  }
  println(preflight.1)
  // Three takes, and only for transport-level deaths. Measured reason: a first
  // small PUT to these public surfaces was seen hanging until the transport's
  // 30s bound (`S3Error.Transport` after +31765ms) while the other cases in the
  // same run answered in hundreds of milliseconds — somebody else's link, not
  // our request shape. A protocol-level red (wrong status, wrong ETag, wrong
  // window) is deterministic, so it is never retried into silence. The bound
  // itself stays at the transport's default and is not widened here: upstream
  // ruled that callers raise `timeout~` when *their* payload needs it
  // (https://github.com/mldong/moon-hutool/issues/6), which is not this case —
  // these requests carry a few dozen bytes.
  let attempts : Array[Int32] = [0]
  while attempts[0] < 3 {
    attempts[0] = attempts[0] + 1
    let take = attempts[0].to_string()
    let started = [now_ms()]
    let failure = try {
      body(started, endpoint, region, bucket, access_key, secret_key)
      ""
    } catch {
      error => {
        let ran = now_ms() - started[0]
        error.to_string() +
        " after +" +
        ran.to_string() +
        "ms at the step above"
      }
    }
    if failure == "" {
      return
    }
    println("cos attempt " + take + " failed: " + failure)
    if failure.find("Transport") is None {
      fail("COS case failed at the protocol layer, not retried: " + failure)
    }
  }
  fail(
    "COS case died at the transport layer three times in a row — this endpoint never answered the case",
  )
}

///|
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
/// Which step is in flight, and how long the case has been running: a
/// compatibility leg talks to somebody else's public endpoint, so "red" without
/// a position and an elapsed time is not actionable.
fn live_step(
  started : Array[Int64],
  calls : Array[LiveCall],
  label : String,
) -> Unit {
  let elapsed = now_ms() - started[0]
  let recorded = calls.length().to_string()
  println(
    "cos step +" +
    elapsed.to_string() +
    "ms: " +
    label +
    " (recorded=" +
    recorded +
    ")",
  )
}

///|
/// The URL we actually put the object at, straight out of the spy: the anonymous
/// fetch below must use that exact URL, not a hand-rebuilt one.
fn last_call_url(calls : Array[LiveCall]) -> String raise {
  if calls.length() == 0 {
    fail("no request was recorded")
  } else {
    calls[calls.length() - 1].url
  }
}

///|
/// The object family, in the style COS actually serves: bucket in `Host`.
async fn cos_object_family(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = cos_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("cos-family")
  let key = prefix + "family.txt"
  let copy_key = prefix + "copied.txt"
  let sample = "moon-s3 compatibility leg on COS 中文 +?&=%2F 0123456789abcdef\n"
  let payload = @utf8.encode(sample.view())
  let size = payload.length().to_int64()
  let put : @s3.PutObjectRequest = {
    bucket,
    key,
    body: @transport.RequestBody::Bytes(payload),
    content_type: Some("text/plain"),
    metadata: Map([("tool", "moon-s3-compat")]),
  }
  live_step(started, calls, "PUT")
  let put_response = client.put_object(put)
  let put_status = calls[calls.length() - 1].status.to_string()
  println("PUT status=" + put_status + " etag=" + put_response.etag)
  assert_true(!put_response.etag.is_empty())
  assert_true(
    calls[calls.length() - 1].url.has_prefix("https://" + bucket + "."),
  )
  live_step(started, calls, "HEAD")
  let stat = client.stat_object({ bucket, key, })
  println(
    "HEAD content_length=" +
    stat.content_length.to_string() +
    " etag=" +
    stat.etag.unwrap_or("-") +
    " tool=" +
    stat.metadata.get("tool").unwrap_or("-"),
  )
  assert_eq(stat.content_length, size)
  assert_eq(stat.etag, Some(put_response.etag))
  assert_eq(stat.metadata.get("tool"), Some("moon-s3-compat"))
  live_step(started, calls, "GET whole object")
  let got = client.get_object({ bucket, key, range: None, })
  let bytes = drain(got.body)
  let read_text = bytes.length().to_string()
  let declared = got.content_length.to_string()
  println("GET declared=" + declared + " read=" + read_text)
  assert_true(bytes.equal(payload))
  // The reading this platform is documented on is `bytes 0-3/<size>`; the size
  // here comes from this payload, so the judgment is the shape of the window the
  // endpoint reports. The service's own words are printed before any assertion:
  // an `S3Error.Service` reaching the failure line would carry no payload
  // (this version's `Error.to_string()` drops it), so the message has to be
  // logged while it is still typed.
  // The request header is `bytes=<from>-<to>`; spelling it `bytes 0-3` is not a
  // range at all, and COS says so with `416 InvalidRange` rather than pretending
  // to satisfy it — that refusal is this leg's own first reading, measured here.
  live_step(started, calls, "GET range bytes=0-3")
  let ranged = client.get_object({ bucket, key, range: Some("bytes=0-3"), }) catch {
    error =>
      // Printed while still typed, then failed: the service's own words never
      // reach a failure line (`Error.to_string()` drops `S3Error` payloads),
      // and re-raising from a cleanup arm is the shape this version warns about.
      fail("GET(range) refused: " + render_error(error))
  }
  let ranged_bytes = drain(ranged.body)
  let window = ranged.content_range.unwrap_or("-")
  let ranged_read = ranged_bytes.length().to_string()
  let ranged_declared = ranged.content_length.to_string()
  println(
    "GET(range) content_range=" +
    window +
    " declared=" +
    ranged_declared +
    " read=" +
    ranged_read,
  )
  assert_eq(ranged_bytes.length(), 4)
  assert_eq(ranged.content_length, 4L)
  assert_true(window.has_prefix("bytes 0-3/"))
  live_step(started, calls, "LIST")
  let listing = client.list_objects({
    bucket,
    prefix: Some(prefix),
    delimiter: None,
    continuation_token: None,
    max_keys: Some(100),
  })
  let listed = find_object(listing, key)
  println("LIST size=" + listed.size.to_string())
  assert_eq(listed.size, size)
  live_step(started, calls, "COPY")
  let copy = client.copy_object({
    bucket,
    key: copy_key,
    source_bucket: bucket,
    source_key: key,
  })
  println("COPY etag=" + copy.etag)
  live_step(started, calls, "GET the copy")
  let copied = client.get_object({ bucket, key: copy_key, range: None, })
  let copied_bytes = drain(copied.body)
  let copied_read = copied_bytes.length().to_string()
  println("GET(copy) read=" + copied_read)
  assert_true(copied_bytes.equal(payload))
  live_step(started, calls, "DELETE both")
  let _ = client.delete_object({ bucket, key, })
  let _ = client.delete_object({ bucket, key: copy_key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
/// The sweep is the only evidence that this leg left nothing behind, so a
/// transport-level failure in it must not become a pass. Three takes, then a
/// named red — a re-run of the case is the remedy, not a widened assertion.
async fn live_sweep_verified(
  client : @s3.Client,
  bucket : String,
  prefix : String,
) -> Unit {
  let attempts : Array[Int32] = [0]
  let mut residue = -1
  while residue < 0 && attempts[0] < 3 {
    let take = (attempts[0] + 1).to_string()
    attempts[0] = attempts[0] + 1
    residue = sweep(client, bucket, prefix) catch {
      error => {
        println("sweep attempt " + take + " failed: " + render_error(error))
        -1
      }
    }
  }
  if residue < 0 {
    fail(
      "residue under " +
      prefix +
      " is unverified: 3 sweep attempts all failed at the transport layer",
    )
  }
  assert_eq(residue, 0)
}

///|
/// Path style is the refusal this platform is known for. The judgment is the
/// status the **service** answers with, and the shape of the URL we sent — not a
/// message string: on a HEAD-less error body this SDK falls back to its own
/// label, and a fallback label is not evidence about the endpoint.
async fn cos_path_style_refused(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = cos_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::Path,
    calls,
  )
  live_step(started, calls, "GET with path-style addressing")
  let reading = try {
    let response = client.get_object({
      bucket,
      key: live_case_prefix("cos-path") + "never-written.txt",
      range: None,
    })
    response.body.close()
    "accepted with " + response.content_length.to_string() + " bytes"
  } catch {
    error => render_error(error)
  }
  show_calls(calls)
  println("path style GET -> " + reading)
  // Nothing reached the service: this case is about what the endpoint answers,
  // and a connection that never opened answers nothing. Loud skip, not a red —
  // same rule as the preflight above.
  if calls.length() == 0 {
    println("SKIP live COS path-style check, no request reached the service")
    println(
      "SKIP IS NOT A PASS: COS was not exercised through the S3-compatible path by this run.",
    )
    return
  }
  let sent = last_call_url(calls)
  assert_true(sent.has_prefix("https://cos."))
  assert_true(sent.find("/" + bucket + "/") is Some(_))
  assert_true(!sent.has_prefix("https://" + bucket + "."))
  let refused = service_status(reading)
  assert_eq(refused, "403")
}

///|
/// `render_error` gives `<status> <code> <message>` for a service error; pull
/// the status back out so the assertion names what was judged.
fn service_status(reading : String) -> String {
  match reading.split(" ").to_array() {
    [status, _, ..] => status.to_owned()
    _ => reading
  }
}

///|
/// A presigned URL has to work without credentials — that is the whole promise —
/// and tampering with the signature has to break it.
async fn cos_presigned_get(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = cos_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("cos-presign")
  let key = prefix + "share.txt"
  let payload = @utf8.encode(
    "presigned through the S3-compatible path\n".view(),
  )
  let _ = client.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(payload),
    content_type: Some("text/plain"),
    metadata: Map([]),
  })
  live_step(started, calls, "sign a GET for 900s")
  let url = client.presigned_get_url(bucket, key, 900)
  assert_true(url.find("X-Amz-Signature=") is Some(_))
  assert_true(url.has_prefix("https://" + bucket + "."))
  let bare : &@transport.Transport = @transport.AsyncHttpTransport::new()
  live_step(started, calls, "anonymous GET with the signed URL")
  let response = bare.send({
    http_method: Get,
    url,
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  println("presigned GET status=" + response.status.to_string())
  assert_eq(response.status, 200)
  assert_true(drain(response.body).equal(payload))
  live_step(started, calls, "anonymous GET with one flipped character")
  let tampered = bare.send({
    http_method: Get,
    url: tamper_signature(url),
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  println("tampered GET status=" + tampered.status.to_string())
  assert_eq(tampered.status, 403)
  let _ = drain(tampered.body)
  let _ = client.delete_object({ bucket, key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
/// Flip the last character of the signature query parameter.
fn tamper_signature(url : String) -> String {
  let mark = url.length() - 1
  let last = url[mark:url.length()].to_owned()
  let flipped = if last == "a" { "b" } else { "a" }
  url[0:mark].to_owned() + flipped
}

///|
/// The reading that separates COS from the other compatibility targets: a canned
/// ACL is accepted **and takes effect**, so an anonymous GET must succeed; after
/// flipping it back to private the same anonymous GET must be refused.
async fn cos_canned_acl_effective(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = cos_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("cos-acl")
  let key = prefix + "public.txt"
  let payload = @utf8.encode(
    "readable by anyone while the ACL says so\n".view(),
  )
  let _ = client.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(payload),
    content_type: Some("text/plain"),
    metadata: Map([]),
  })
  let object_url = last_call_url(calls)
  println("object URL = " + object_url)
  live_step(started, calls, "PUT ?acl public-read")
  let _ = client.put_object_acl({ bucket, key, acl: "public-read", })
  live_step(started, calls, "GET ?acl")
  let acl = client.get_object_acl({ bucket, key, })
  let grants = acl.grants.length().to_string()
  println("GET ?acl grants=" + grants)
  assert_true(acl.has_all_users_read())
  let bare : &@transport.Transport = @transport.AsyncHttpTransport::new()
  live_step(started, calls, "anonymous GET while public-read")
  let open = bare.send({
    http_method: Get,
    url: object_url,
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  println("anonymous GET (public-read) status=" + open.status.to_string())
  assert_eq(open.status, 200)
  let _ = drain(open.body)
  let _ = client.put_object_acl({ bucket, key, acl: "private", })
  live_step(started, calls, "anonymous GET after private")
  let closed = bare.send({
    http_method: Get,
    url: object_url,
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  println("anonymous GET (private) status=" + closed.status.to_string())
  assert_eq(closed.status, 403)
  let _ = drain(closed.body)
  let _ = client.delete_object({ bucket, key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
async test "live COS: object family round-trips in virtual-hosted style" {
  match read_cos_env() {
    None => report_cos_skip()
    Some(environment) =>
      cos_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        cos_object_family,
      )
  }
}

///|
async test "live COS: path-style requests are refused by the endpoint" {
  match read_cos_env() {
    None => report_cos_skip()
    Some(environment) =>
      cos_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        cos_path_style_refused,
      )
  }
}

///|
async test "live COS: presigned GET works without credentials and dies on one flipped character" {
  match read_cos_env() {
    None => report_cos_skip()
    Some(environment) =>
      cos_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        cos_presigned_get,
      )
  }
}

///|
async test "live COS: canned ACL public-read takes effect, private closes it again" {
  match read_cos_env() {
    None => report_cos_skip()
    Some(environment) =>
      cos_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        cos_canned_acl_effective,
      )
  }
}
