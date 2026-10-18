///|
// Virtual-hosted traffic against Aliyun OSS's S3-compatible surface, named by
// S3_OSS_ENDPOINT / S3_OSS_REGION / S3_OSS_BUCKET / S3_OSS_AK / S3_OSS_SK.
//
// OSS publishes two different base domains for this surface, and they do not
// behave the same way: the region endpoint (`oss-<region>.aliyuncs.com`, what
// the native SDKs use) and the S3-shaped endpoint (`s3.oss-<region>.aliyuncs.com`).
// Public documentation says path-style is available on the latter and refused on
// the former; that difference is exactly the kind of claim this repo refuses to
// copy from a doc page without measuring, so `oss_base_matrix` walks both bases
// in both addressing styles and prints what the service answers.
//
// Credentials are env-driven and never printed. Writes live under
// `moonfs-live-<YYYYMMDD>/oss-*`, each case deletes what it made, and the final
// step re-lists **its own** prefix expecting zero residue. A missing variable or
// an endpoint that does not answer the 8s preflight is a loud skip.

///|
fn read_oss_env() -> (String, String, String, String, String)? {
  let endpoint = env_or_none("S3_OSS_ENDPOINT")
  let region = env_or_none("S3_OSS_REGION")
  let bucket = env_or_none("S3_OSS_BUCKET")
  let access_key = env_or_none("S3_OSS_AK")
  let secret_key = env_or_none("S3_OSS_SK")
  match (endpoint, region, bucket, access_key, secret_key) {
    (Some(e), Some(r), Some(b), Some(a), Some(s)) => Some((e, r, b, a, s))
    _ => None
  }
}

///|
fn report_oss_skip() -> Unit {
  let names : Array[String] = [
    "S3_OSS_ENDPOINT", "S3_OSS_REGION", "S3_OSS_BUCKET", "S3_OSS_AK", "S3_OSS_SK",
  ]
  let missing : Array[String] = []
  for name in names {
    if @env.get_env_var(name) is None {
      missing.push(name)
    }
  }
  println("SKIP live OSS compatibility check, environment not supplied")
  println("missing: " + missing.join(", "))
  println(
    "SKIP IS NOT A PASS: OSS was not exercised through the S3-compatible path by this run.",
  )
}

///|
fn oss_client(
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
async fn oss_preflight(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
  bucket : String,
) -> (Bool, String) {
  let calls : Array[LiveCall] = []
  let client = oss_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
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
    "oss preflight: answered=" +
    answered +
    " recorded=" +
    calls.length().to_string(),
  )
}

///|
async fn oss_guarded(
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
  body : async (Array[Int64], String, String, String, String, String) -> Unit,
) -> Unit {
  let preflight = oss_preflight(
    endpoint, region, access_key, secret_key, bucket,
  )
  if !preflight.0 {
    println(preflight.1)
    println("SKIP live OSS compatibility check, endpoint did not answer")
    println(
      "SKIP IS NOT A PASS: OSS was not exercised through the S3-compatible path by this run.",
    )
    return
  }
  println(preflight.1)
  // Same rule and same measured reason as the COS link: retry only
  // transport-level deaths (a first small PUT was seen hanging until the
  // transport's 30s bound), never a protocol-level red. The bound is not
  // widened — see the note on that link about upstream's ruling on `timeout~`.
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
    println("oss attempt " + take + " failed: " + failure)
    if failure.find("Transport") is None {
      fail("OSS case failed at the protocol layer, not retried: " + failure)
    }
  }
  fail(
    "OSS case died at the transport layer three times in a row — this endpoint never answered the case",
  )
}

///|
/// The object family over the S3-shaped surface, virtual-hosted.
async fn oss_object_family(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = oss_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("oss-family")
  let key = prefix + "family.txt"
  let sample = "moon-s3 compatibility leg on OSS 中文 +?&=%2F 0123456789abcdefg\n"
  let payload = @utf8.encode(sample.view())
  let size = payload.length().to_int64()
  live_step(started, calls, "PUT")
  let put = client.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(payload),
    content_type: Some("text/plain"),
    metadata: Map([("tool", "moon-s3-compat")]),
  })
  let put_status = calls[calls.length() - 1].status.to_string()
  println("PUT status=" + put_status + " etag=" + put.etag)
  assert_true(!put.etag.is_empty())
  // OSS answers a bare 32-character hex ETag here, without the quoting AWS and
  // MinIO use — recorded as a reading, not normalised away.
  println(
    "ETag shape: quoted=" +
    (if put.etag.has_prefix("\"") { "yes" } else { "no" }),
  )
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
  assert_eq(stat.metadata.get("tool"), Some("moon-s3-compat"))
  live_step(started, calls, "GET whole object")
  let got = client.get_object({ bucket, key, range: None, })
  let bytes = drain(got.body)
  println(
    "GET declared=" +
    got.content_length.to_string() +
    " read=" +
    bytes.length().to_string(),
  )
  assert_true(bytes.equal(payload))
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
  println(
    "GET(range) content_range=" +
    window +
    " read=" +
    ranged_bytes.length().to_string(),
  )
  assert_eq(ranged_bytes.length(), 4)
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
  live_step(started, calls, "DELETE")
  let _ = client.delete_object({ bucket, key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
async fn oss_presigned_get(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = oss_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("oss-presign")
  let key = prefix + "share.txt"
  let payload = @utf8.encode(
    "presigned through the S3-compatible surface\n".view(),
  )
  live_step(started, calls, "PUT the object to share")
  let _ = client.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(payload),
    content_type: Some("text/plain"),
    metadata: Map([]),
  })
  let url = client.presigned_get_url(bucket, key, 900)
  assert_true(url.find("X-Amz-Signature=") is Some(_))
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
  live_step(started, calls, "DELETE")
  let _ = client.delete_object({ bucket, key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
/// The row that separates OSS from COS on this surface: writing a canned ACL.
/// The stage-G probe measured a refusal here, and this leg re-measures it rather
/// than inheriting it — the reading is printed whatever the outcome is.
async fn oss_acl_claim(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = oss_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("oss-acl")
  let key = prefix + "claim.txt"
  live_step(started, calls, "PUT an object to put ACL on")
  let _ = client.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(@utf8.encode("acl claim\n".view())),
    content_type: Some("text/plain"),
    metadata: Map([]),
  })
  let writing = try {
    let _ = client.put_object_acl({ bucket, key, acl: "public-read", })
    "accepted"
  } catch {
    error => render_error(error)
  }
  println("PUT ?acl public-read -> " + writing)
  let reading = try {
    let acl = client.get_object_acl({ bucket, key, })
    "grants=" +
    acl.grants.length().to_string() +
    " all_users_read=" +
    acl.has_all_users_read().to_string()
  } catch {
    error => render_error(error)
  }
  println("GET ?acl -> " + reading)
  assert_true(writing.has_prefix("403"))
  live_step(started, calls, "DELETE")
  let _ = client.delete_object({ bucket, key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
/// Two published base domains × two addressing styles. `S3_OSS_REGION` derives
/// the bases so the table cannot drift away from the region the credentials
/// belong to.
///
/// The refusal on the path-style side is the point of this case. Aliyun's
/// "access OSS with an AWS SDK" page presents path-style as available (and
/// recommends it for bucket names that are not DNS-safe); on this account and
/// this bucket **both** bases answer
/// `403 SecondLevelDomainForbidden / Please use virtual hosted style to access.`
/// — measured here, not copied from the page. Underscore-named buckets are out of
/// scope for this leg: this SDK signs the bucket into `Host` only when
/// `addressing_style` says so, so a DNS-invalid name simply has no working
/// addressing style here, and that is a claim about our bucket shape rather than
/// about the doc page.
async fn oss_base_matrix(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  // 供进来的那一路也走一遍：CI 与本机喂哪个基址本身就是这轮读数的一部分，
  // 而 `endpoint` 参数不该只是签名上的摆设。
  let published = [
    "https://oss-" + region + ".aliyuncs.com",
    "https://s3.oss-" + region + ".aliyuncs.com",
  ]
  let bases = if published[0] == endpoint || published[1] == endpoint {
    published
  } else {
    println("supplied endpoint is outside the two published bases: " + endpoint)
    published + [endpoint]
  }
  let styles : Array[(String, @s3.AddressingStyle)] = [
    ("path", @s3.AddressingStyle::Path),
    ("virtual-hosted", @s3.AddressingStyle::VirtualHosted),
  ]
  for base in bases {
    for style in styles {
      let calls : Array[LiveCall] = []
      let client = oss_client(
        base,
        region,
        access_key,
        secret_key,
        style.1,
        calls,
      )
      let key = live_case_prefix("oss-matrix") + "never-written.txt"
      let reading = try {
        let response = client.get_object({ bucket, key, range: None, })
        response.body.close()
        "accepted content_length=" + response.content_length.to_string()
      } catch {
        error => render_error(error)
      }
      live_step(started, calls, "matrix " + base + " / " + style.0)
      if calls.length() == 0 {
        println("SKIP live OSS base matrix, no request reached " + base)
        println(
          "SKIP IS NOT A PASS: OSS was not exercised through the S3-compatible path by this run.",
        )
        return
      }
      println(
        "matrix base=" +
        base +
        " style=" +
        style.0 +
        " -> " +
        reading +
        " sent=" +
        last_call_url(calls),
      )
      let status = service_status(reading)
      match style.1 {
        @s3.AddressingStyle::Path => assert_eq(status, "403")
        @s3.AddressingStyle::VirtualHosted => assert_eq(status, "404")
      }
    }
  }
}

///|
async test "live OSS: object family round-trips in virtual-hosted style" {
  match read_oss_env() {
    None => report_oss_skip()
    Some(environment) =>
      oss_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        oss_object_family,
      )
  }
}

///|
async test "live OSS: presigned GET works without credentials and dies on one flipped character" {
  match read_oss_env() {
    None => report_oss_skip()
    Some(environment) =>
      oss_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        oss_presigned_get,
      )
  }
}

///|
async test "live OSS: writing a canned ACL is refused by the bucket policy" {
  match read_oss_env() {
    None => report_oss_skip()
    Some(environment) =>
      oss_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        oss_acl_claim,
      )
  }
}

///|
async test "live OSS: both published base domains, each in both addressing styles" {
  match read_oss_env() {
    None => report_oss_skip()
    Some(environment) =>
      oss_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        oss_base_matrix,
      )
  }
}
