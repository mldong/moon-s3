///|
// Virtual-hosted addressing against an endpoint that really parses the bucket
// out of `Host`. This is the reading stage A could not get: the shared MinIO at
// that server ignores the bucket name in `Host` entirely, so every virtual-hosted request
// there answers 200 with the *account's* bucket list — a status code that proves
// nothing (阶段 A 卡 §7-20).
//
// The vehicle is instead Qiniu's S3-compatible endpoint, which the same round
// measured (see the C 卡 §7 write-back): it resolves `<bucket>.<endpoint>` per
// request. Nothing here is written — both cases expect an error document, and the
// judgment is the `<Resource>` the **service** filled in, i.e. which name it read
// out of our request. A 404 on its own would not distinguish "the endpoint
// resolved our bucket and the key is not there" from "the request never named a
// bucket at all".
//
// Env-driven: S3_VHOST_ENDPOINT / S3_VHOST_REGION / S3_VHOST_BUCKET /
// S3_VHOST_AK / S3_VHOST_SK. A missing variable is a loud skip, not a pass, and
// so is an endpoint that does not answer at all (see `vhost_preflight`).
// GET (not HEAD) on purpose: a HEAD response carries no body, so the error
// document this case reads would not exist.

///|
fn read_vhost_env() -> (String, String, String, String, String)? {
  let endpoint = @env.get_env_var("S3_VHOST_ENDPOINT")
  let region = @env.get_env_var("S3_VHOST_REGION")
  let bucket = @env.get_env_var("S3_VHOST_BUCKET")
  let access_key = @env.get_env_var("S3_VHOST_AK")
  let secret_key = @env.get_env_var("S3_VHOST_SK")
  match (endpoint, region, bucket, access_key, secret_key) {
    (Some(e), Some(r), Some(b), Some(a), Some(s)) => Some((e, r, b, a, s))
    _ => None
  }
}

///|
fn report_vhost_skip() -> Unit {
  let names : Array[String] = [
    "S3_VHOST_ENDPOINT", "S3_VHOST_REGION", "S3_VHOST_BUCKET", "S3_VHOST_AK", "S3_VHOST_SK",
  ]
  let missing : Array[String] = []
  for name in names {
    if @env.get_env_var(name) is None {
      missing.push(name)
    }
  }
  println("SKIP live virtual-hosted check, environment not supplied")
  println("missing: " + missing.join(", "))
  println(
    "SKIP IS NOT A PASS: virtual-hosted addressing was not verified against a real endpoint by this run.",
  )
}

///|
fn holds(text : String, needle : String) -> Bool {
  text.find(needle) is Some(_)
}

///|
/// The service's own words about a GET: code plus the `<Resource>` it resolved.
fn service_reading(error : @s3.S3Error) -> (String, String, String?) {
  match error {
    Service(details) =>
      (details.code, details.status_code.to_string(), details.resource)
    other => (render_error(other), "-1", None)
  }
}

///|
async fn vhost_get(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
  ask_bucket : String,
) -> (String, String, String?, String) {
  let vhosted = @s3.Config::new(
    endpoint,
    region,
    @s3.Credentials::new(access_key, secret_key),
    addressing_style=VirtualHosted,
  )
  let calls : Array[LiveCall] = []
  let inner : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let spy : &@transport.Transport = LiveTransport::{ inner, calls, }
  let client = @s3.Client::new(vhosted, spy)
  let key = "moon-file-storage-probe/does-not-need-to-exist.txt"
  let outcome : (String, String, String?) = try {
    // A success would mean the probe key exists on that endpoint; the reading is
    // then "the object family answered", which is not a bucket-resolution proof.
    let response = client.get_object({ bucket: ask_bucket, key, range: None, })
    response.body.close()
    ("Ok", "200", None)
  } catch {
    error => service_reading(error)
  }
  show_calls(calls)
  let sent = if calls.length() == 0 {
    fail("no request was recorded for " + ask_bucket)
  } else {
    calls[calls.length() - 1].url
  }
  (outcome.0, outcome.1, outcome.2, sent)
}

///|
/// The vehicle for this case is somebody else's machine, so "it never answered"
/// must not be read as "our addressing changed". A connect-level failure records
/// no request and no service document, and is reported as a loud skip; any HTTP
/// answer at all — even 403 or 503 — keeps every assertion below in force.
/// The bound is short on purpose: the transport default is 30s and waiting that
/// long on a dead endpoint would only slow the gate down.
async fn vhost_preflight(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
  bucket : String,
) -> (Bool, String) {
  let vhosted = @s3.Config::new(
    endpoint,
    region,
    @s3.Credentials::new(access_key, secret_key),
    addressing_style=VirtualHosted,
  )
  let calls : Array[LiveCall] = []
  let inner : &@transport.Transport = @transport.AsyncHttpTransport::new(
    timeout=8000,
  )
  let spy : &@transport.Transport = LiveTransport::{ inner, calls, }
  let client = @s3.Client::new(vhosted, spy)
  let answered = try {
    let response = client.get_object({
      bucket,
      key: "moon-file-storage-probe/does-not-need-to-exist.txt",
      range: None,
    })
    response.body.close()
    "200"
  } catch {
    error => service_reading(error).1
  }
  let reached = calls.length() > 0
  let note = "vhost preflight: answered=" +
    answered +
    " recorded=" +
    calls.length().to_string()
  (reached, note)
}

///|
async fn live_virtual_hosted(
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let preflight = vhost_preflight(
    endpoint, region, access_key, secret_key, bucket,
  )
  if !preflight.0 {
    println(preflight.1)
    println("SKIP live virtual-hosted check, endpoint did not answer")
    println(
      "SKIP IS NOT A PASS: virtual-hosted addressing was not verified against a real endpoint by this run.",
    )
    return
  }
  // Case 1 — a bucket this endpoint really has. The service must name it in
  // `<Resource>`: that is the endpoint telling us it read the bucket from `Host`.
  let (known_code, known_status, known_resource, known_sent) = vhost_get(
    endpoint, region, access_key, secret_key, bucket,
  )
  let real_reading = "vhost real bucket: code=" +
    known_code +
    " status=" +
    known_status
  println(real_reading + " resource=" + known_resource.unwrap_or("(none)"))
  assert_eq(known_code, "NoSuchKey")
  assert_eq(known_resource, Some("/" + bucket))
  // 同一份读数的另一半：我们确实把桶名放进 Host、而不是塞在路径里。
  // 少了这条，"服务端解析对了"也可能只是路径风格蒙中的。
  let wanted_host = "https://" + bucket + "."
  assert_true(known_sent.has_prefix(wanted_host))
  assert_true(!holds(known_sent, "/" + bucket + "/"))

  // Case 2 — a bucket that does not exist, same endpoint and same client shape.
  // A different name must produce a different resolution, otherwise the answer
  // came from somewhere other than this request's `Host`.
  let absent = "moonfs-no-such-" + bucket
  let (absent_code, absent_status, absent_resource, absent_sent) = vhost_get(
    endpoint, region, access_key, secret_key, absent,
  )
  let absent_reading = "vhost absent bucket: code=" +
    absent_code +
    " status=" +
    absent_status
  println(absent_reading + " resource=" + absent_resource.unwrap_or("(none)"))
  assert_eq(absent_code, "NoSuchBucket")
  assert_eq(absent_resource, Some("/" + absent))
  assert_true(absent_sent.has_prefix("https://" + absent + "."))
  assert_true(!holds(absent_sent, "/" + absent + "/"))
}

///|
async test "live: virtual-hosted addressing is resolved by the endpoint itself" {
  match read_vhost_env() {
    None => report_vhost_skip()
    Some(environment) =>
      live_virtual_hosted(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
      )
  }
}
