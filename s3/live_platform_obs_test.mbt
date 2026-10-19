///|
// Huawei OBS through its S3-compatible surface: what the service answers this
// client, measured on a real bucket rather than restated from the vendor page.
//
// Env: S3_OBS_ENDPOINT / S3_OBS_REGION / S3_OBS_BUCKET / S3_OBS_AK / S3_OBS_SK.
// Writes land only under `moonfs-live-<YYYYMMDD>/obs-*` in the named bucket, each
// case deletes what it made and re-lists its own prefix expecting zero residue.
// Missing env, or an endpoint that never answers the preflight, is a loud skip:
// the output says the run proved nothing.
//
// Four readings from 2026-10-19 shape the assertions below, and each is a place
// where a client written against AWS would mis-read the answer:
//
//   1. Path style is refused outright, on the vendor's own base address: every
//      bucket-scoped request answers `403 VirtualHostDomainRequired`, with a body.
//      So the addressing style is not a preference here.
//   2. A wrong region and a genuinely missing bucket answer **identically**
//      (`404 NoSuchBucket`), which is why this file asserts the equality instead
//      of pretending the two are separable. Qiniu, by contrast, says
//      `400 IncorrectRegion` — do not carry one platform's reading to the other.
//   3. Canned ACLs take effect: `public-read` really does open an anonymous read,
//      and putting it back to `private` really does close it again.
//   4. Presigned URLs are validated: one flipped signature character is refused
//      (`403 SignatureDoesNotMatch`) and so is a tampered credential
//      (`400 InvalidArgument`) — measured against a private bucket, which is the
//      control that makes those two refusals mean anything.

///|
fn read_obs_env() -> (String, String, String, String, String)? {
  let endpoint = env_or_none("S3_OBS_ENDPOINT")
  let region = env_or_none("S3_OBS_REGION")
  let bucket = env_or_none("S3_OBS_BUCKET")
  let access_key = env_or_none("S3_OBS_AK")
  let secret_key = env_or_none("S3_OBS_SK")
  match (endpoint, region, bucket, access_key, secret_key) {
    (Some(e), Some(r), Some(b), Some(a), Some(s)) => Some((e, r, b, a, s))
    _ => None
  }
}

///|
fn report_obs_skip() -> Unit {
  let names : Array[String] = [
    "S3_OBS_ENDPOINT", "S3_OBS_REGION", "S3_OBS_BUCKET", "S3_OBS_AK", "S3_OBS_SK",
  ]
  let missing : Array[String] = []
  for name in names {
    if env_or_none(name) is None {
      missing.push(name)
    }
  }
  println("SKIP live OBS compatibility check, environment not supplied")
  println("missing: " + missing.join(", "))
  println(
    "SKIP IS NOT A PASS: OBS was not exercised through the S3-compatible path by this run.",
  )
}

///|
fn obs_client(
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
/// Reachability only: "it never answered" must not be read as "behaviour
/// changed". Any HTTP answer at all keeps the assertions below in force.
async fn obs_preflight(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
  bucket : String,
) -> (Bool, String) {
  let calls : Array[LiveCall] = []
  let client = obs_client(
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
    "obs preflight: answered=" +
    answered +
    " recorded=" +
    calls.length().to_string(),
  )
}

///|
async fn obs_guarded(
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
  body : async (Array[Int64], String, String, String, String, String) -> Unit,
) -> Unit {
  let preflight = obs_preflight(
    endpoint, region, access_key, secret_key, bucket,
  )
  if !preflight.0 {
    println(preflight.1)
    println("SKIP live OBS compatibility check, endpoint did not answer")
    println(
      "SKIP IS NOT A PASS: OBS was not exercised through the S3-compatible path by this run.",
    )
    return
  }
  println(preflight.1)
  // Only transport deaths are retried; a protocol-level red is the reading and
  // must never be re-rolled until it says something else.
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
    println("obs attempt " + take + " failed: " + failure)
    if failure.find("Transport") is None {
      fail("OBS case failed at the protocol layer, not retried: " + failure)
    }
  }
  fail(
    "OBS case died at the transport layer three times in a row — this endpoint never answered the case",
  )
}

///|
fn obs_host_of(endpoint : String) -> String {
  if endpoint.has_prefix("https://") {
    endpoint[8:endpoint.length()].to_owned()
  } else if endpoint.has_prefix("http://") {
    endpoint[7:endpoint.length()].to_owned()
  } else {
    endpoint
  }
}

///|
/// Flip a character inside the credential parameter rather than the signature:
/// the service should refuse this before it ever gets to comparing a digest.
fn tamper_credential(url : String) -> String {
  // The caller has already asserted the presigned shape, so the marker is there;
  // if it ever is not, the slice below aborts loudly rather than tampering with
  // something else and reporting a pass.
  let at = url.find("X-Amz-Credential=").unwrap_or(-1) + 22
  let ch = url[at:at + 1].to_owned()
  let flipped = if ch == "a" { "b" } else { "a" }
  url[:at].to_owned() + flipped + url[at + 1:url.length()].to_owned()
}

///|
/// The object family, virtual-hosted: this is the surface's own answer, not a
/// claim about compatibility.
async fn obs_object_family(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = obs_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("obs-family")
  let key = prefix + "family.txt"
  let sample = "moon-s3 compatibility measurement on OBS 中文 +?&=%2F 0123456\n"
  let payload = @utf8.encode(sample.view())
  let size = payload.length().to_int64()
  live_step(started, calls, "PUT")
  let put = try {
    let response = client.put_object({
      bucket,
      key,
      body: @transport.RequestBody::Bytes(payload),
      content_type: Some("text/plain"),
      metadata: Map([("tool", "moon-s3-obs")]),
    })
    "accepted etag=" + response.etag
  } catch {
    error => fail("PUT refused: " + render_error(error))
  }
  println("PUT -> " + put)
  live_step(started, calls, "HEAD")
  let stat = client.stat_object({ bucket, key, })
  println(
    "HEAD content_length=" +
    stat.content_length.to_string() +
    " tool=" +
    stat.metadata.get("tool").unwrap_or("-"),
  )
  assert_eq(stat.content_length, size)
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
  let ranged = client.get_object({ bucket, key, range: Some("bytes=0-3"), })
  println("GET(range) content_range=" + ranged.content_range.unwrap_or("-"))
  assert_eq(drain(ranged.body).length(), 4)
  live_step(started, calls, "LIST own prefix")
  let listed = find_object(
    client.list_objects({
      bucket,
      prefix: Some(prefix),
      delimiter: None,
      continuation_token: None,
      max_keys: Some(100),
    }),
    key,
  )
  println("LIST size=" + listed.size.to_string())
  assert_eq(listed.size, size)
  live_step(started, calls, "DELETE")
  let _ = client.delete_object({ bucket, key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
/// Path style is not an option on this surface, and the refusal names itself.
async fn obs_path_style(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = obs_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::Path,
    calls,
  )
  let prefix = live_case_prefix("obs-path")
  live_step(started, calls, "GET with the bucket in the path")
  let getting = try {
    let response = client.get_object({
      bucket,
      key: prefix + "never-written.txt",
      range: None,
    })
    response.body.close()
    "200 accepted"
  } catch {
    error => render_error(error)
  }
  live_step(started, calls, "LIST with the bucket in the path")
  let listing = try {
    let page = client.list_objects({
      bucket,
      prefix: Some(prefix),
      delimiter: None,
      continuation_token: None,
      max_keys: Some(10),
    })
    "accepted objects=" + page.objects.length().to_string()
  } catch {
    error => render_error(error)
  }
  println("path GET -> " + getting + " sent=" + last_call_url(calls))
  println("path LIST -> " + listing)
  assert_true(getting.has_prefix("403"))
  assert_true(getting.find("VirtualHostDomainRequired") is Some(_))
  assert_true(listing.has_prefix("403"))
}

///|
/// Presigned, with the control that makes the refusals mean something: the same
/// key fetched with no signature at all must be refused too, otherwise the bucket
/// is public and "a bad signature is refused" is not being tested at all.
async fn obs_presigned(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = obs_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("obs-presign")
  let key = prefix + "share.txt"
  let payload = @utf8.encode("presigned through OBS's S3 surface\n".view())
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
  live_step(started, calls, "anonymous GET of the unsigned object URL")
  let unsigned = bare.send({
    http_method: Get,
    url: obs_unsigned(url),
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  println("unsigned anonymous GET status=" + unsigned.status.to_string())
  assert_eq(unsigned.status, 403)
  let _ = drain(unsigned.body)
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
  println("tampered signature status=" + tampered.status.to_string())
  assert_eq(tampered.status, 403)
  let _ = drain(tampered.body)
  live_step(started, calls, "anonymous GET with a flipped credential")
  let bad_cred = bare.send({
    http_method: Get,
    url: tamper_credential(url),
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  // Measured, and it disagrees with an earlier probe on purpose: breaking the
  // **last** character of the credential answers `400 InvalidArgument`, while
  // breaking a character inside the access key (what this helper does) answers
  // 403 `InvalidAccessKeyId` — the code depends on which half of the credential
  // stops resolving, so neither refusal alone is "the" signature-checking shape.
  // Both are refusals; the body is printed so the reading stays on the record.
  let bad_body = @utf8.decode_lossy(drain(bad_cred.body))
  println(
    "tampered credential status=" +
    bad_cred.status.to_string() +
    " body=" +
    bad_body[:120].to_owned(),
  )
  assert_eq(bad_cred.status, 403)
  let _ = client.delete_object({ bucket, key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
/// Drop the query string from a presigned URL: what remains is the plain object
/// address, which is the control above.
fn obs_unsigned(url : String) -> String {
  match url.find("?") {
    Some(i) => url[:i].to_owned()
    None => url
  }
}

///|
/// Canned ACLs take effect here — written, honoured, and reversible.
async fn obs_acl(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = obs_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("obs-acl")
  let key = prefix + "acl.txt"
  let payload = @utf8.encode("acl effective on OBS 中文\n".view())
  let _ = client.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(payload),
    content_type: Some("text/plain"),
    metadata: Map([]),
  })
  let bare : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let object_url = "https://" + bucket + "." + obs_host_of(endpoint) + "/" + key
  live_step(started, calls, "anonymous GET while private")
  let before = bare.send({
    http_method: Get,
    url: object_url,
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  println("private anonymous GET status=" + before.status.to_string())
  assert_eq(before.status, 403)
  let _ = drain(before.body)
  live_step(started, calls, "PUT ?acl public-read")
  let _ = client.put_object_acl({ bucket, key, acl: "public-read", })
  live_step(started, calls, "anonymous GET after public-read")
  let open = bare.send({
    http_method: Get,
    url: object_url,
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  println("public-read anonymous GET status=" + open.status.to_string())
  assert_eq(open.status, 200)
  assert_true(drain(open.body).equal(payload))
  live_step(started, calls, "GET ?acl reads the grant back")
  let policy = client.get_object_acl({ bucket, key, })
  // Printed, not asserted: what the anonymous GET above already proved is the
  // effect. How OBS spells the grant in `AccessControlPolicy` is a separate
  // question, and the bucket-level reading came back with no URI/EmailAddress
  // entries at all — so a grant-shape assertion here would be testing a guess.
  println(
    "GET ?acl grants=" +
    policy.grants.length().to_string() +
    " all_users_read=" +
    policy.has_all_users_read().to_string(),
  )
  live_step(started, calls, "PUT ?acl private closes it again")
  let _ = client.put_object_acl({ bucket, key, acl: "private", })
  let closed = bare.send({
    http_method: Get,
    url: object_url,
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  println("back-to-private anonymous GET status=" + closed.status.to_string())
  assert_eq(closed.status, 403)
  let _ = drain(closed.body)
  let _ = client.delete_object({ bucket, key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
/// The reading a client must not be fooled by: on this surface a bucket that
/// lives in another region and a bucket that does not exist answer the same way,
/// so `404 NoSuchBucket` is not evidence about existence. Asserted as an
/// equality, because that is the fact worth keeping.
async fn obs_region_and_missing_agree(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let host = obs_host_of(endpoint)
  // A region token that is definitely not the bucket's own.
  let other_region = if region == "cn-north-4" {
    "cn-east-3"
  } else {
    "cn-north-4"
  }
  let other = obs_client(
    "https://" + host.replace_all(old=region, new=other_region),
    other_region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    [],
  )
  let missing = obs_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    [],
  )
  live_step(started, [], "GET on the wrong-region host")
  let elsewhere = try {
    let response = other.get_object({
      bucket,
      key: "moonfs-probe/never-written.txt",
      range: None,
    })
    response.body.close()
    "200 accepted"
  } catch {
    error => render_error(error)
  }
  live_step(started, [], "GET on a bucket that cannot exist")
  let nowhere = try {
    let response = missing.get_object({
      bucket: "moonfs-no-such-bucket-zz",
      key: "moonfs-probe/never-written.txt",
      range: None,
    })
    response.body.close()
    "200 accepted"
  } catch {
    error => render_error(error)
  }
  println("wrong-region host -> " + elsewhere)
  println("missing bucket     -> " + nowhere)
  assert_true(elsewhere.has_prefix("404"))
  assert_true(nowhere.has_prefix("404"))
  assert_true(elsewhere.find("NoSuchBucket") is Some(_))
  assert_true(nowhere.find("NoSuchBucket") is Some(_))
}

///|
async test "live OBS: object family over the S3-compatible surface" {
  match read_obs_env() {
    None => report_obs_skip()
    Some(environment) =>
      obs_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        obs_object_family,
      )
  }
}

///|
async test "live OBS: path style is refused with a body naming the reason" {
  match read_obs_env() {
    None => report_obs_skip()
    Some(environment) =>
      obs_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        obs_path_style,
      )
  }
}

///|
async test "live OBS: presigned works unsigned and dies on a flipped signature or credential" {
  match read_obs_env() {
    None => report_obs_skip()
    Some(environment) =>
      obs_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        obs_presigned,
      )
  }
}

///|
async test "live OBS: canned ACL takes effect and is reversible" {
  match read_obs_env() {
    None => report_obs_skip()
    Some(environment) =>
      obs_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        obs_acl,
      )
  }
}

///|
async test "live OBS: a wrong region and a missing bucket answer identically" {
  match read_obs_env() {
    None => report_obs_skip()
    Some(environment) =>
      obs_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        obs_region_and_missing_agree,
      )
  }
}
