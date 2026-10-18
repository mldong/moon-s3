///|
// Qiniu Kodo's S3-compatible surface. Measured, not restated from the vendor
// page.
//
// Env: S3_KODO_ENDPOINT / S3_KODO_REGION / S3_KODO_BUCKET / S3_KODO_AK /
// S3_KODO_SK, plus the optional S3_KODO_EXISTING_KEY (a key that really exists
// in that bucket; two read-only cells use it, and one of them is only meaningful
// with it — a 404 on a key that cannot exist separates nothing).
//
// What the surface answers, measured against a real account:
//
//   1. The surface works. Against a bucket whose name it answers to, the whole
//      object family round-trips: PUT with user metadata, HEAD, GET byte for byte,
//      `Range: bytes=0-3`, a listing that finds the key, and a sweep of the
//      case's own prefix down to zero residue. Both addressing styles work. And
//      the region carried inside the SigV4 scope is not what this surface looks
//      at: a region that is not even in Kodo's table (`cn-north-9`) answers
//      character for character the same as the real one. The endpoint carries the
//      region, and a wrong endpoint says so directly (`400 IncorrectRegion`).
//   2. The name this surface answers to is not always the name the console
//      shows. Qiniu states the rule on its 服务域名 page (`/kodo/4088`) and on the
//      console itself, not on the AWS-S3-compatibility page: 空间名称要求全局唯一；
//      **如不唯一，将使用自动生成的空间名称** — so a bucket named with a common word
//      answers to a generated short name over S3, while a rare one keeps its own.
//      Where to read the real value: `GET /` (Get Service) reports it, and the
//      console shows it as 空间概览 → 系统域名 → "S3 协议的外网访问".
//      Under the name from `GET /` the object family works exactly like point 1;
//      under the console name the same surface answers `403 AccessDenied` to a
//      listing and `404 NoSuchKey` to a key that genuinely exists (measured both
//      ways against the same bytes: the 18137-byte object the CDN serves is read
//      back whole through the generated name, byte for byte). Writing to the
//      console name answers `403`, and a different region's endpoint states the
//      reason plainly (`400 IncorrectRegion`), so this is not a wrong-region
//      artifact: the region used here is the one that bucket lives in.
//
// So the trap on this platform is the **bucket name**: point a client at a name
// this surface does not answer to and every operation on that bucket reads as a
// permission failure. Hence the precondition this file automates — ask the
// surface which bucket names it answers to first (`GET /`; `CreationDate` is what
// ties a generated name back to a console bucket), then judge only what answers.
// The classified case takes one of two branches, each with its own assertions, so
// it cannot degenerate into a block that only prints; the branch whose name is not
// answered to also reads a key that genuinely exists, because that is the only
// reading which tells a wrong name apart from a lost permission.
//
// Writes land only under `moonfs-live-<YYYYMMDD>/kodo-*` in the named bucket, and
// each case deletes what it made. Missing env, or an endpoint that never answers
// the 8s preflight, is a loud skip: the output says the run proved nothing.

///|
fn kodo_env(name : String) -> String? {
  env_or_none(name)
}

///|
fn read_kodo_env() -> (String, String, String, String, String)? {
  match
    (
      kodo_env("S3_KODO_ENDPOINT"),
      kodo_env("S3_KODO_REGION"),
      kodo_env("S3_KODO_BUCKET"),
      kodo_env("S3_KODO_AK"),
      kodo_env("S3_KODO_SK"),
    ) {
    (Some(e), Some(r), Some(b), Some(a), Some(s)) => Some((e, r, b, a, s))
    _ => None
  }
}

///|
fn report_kodo_skip() -> Unit {
  let names : Array[String] = [
    "S3_KODO_ENDPOINT", "S3_KODO_REGION", "S3_KODO_BUCKET", "S3_KODO_AK", "S3_KODO_SK",
  ]
  let missing : Array[String] = []
  for name in names {
    if kodo_env(name) is None {
      missing.push(name)
    }
  }
  println("SKIP live Kodo compatibility check, environment not supplied")
  println("missing: " + missing.join(", "))
  println(
    "SKIP IS NOT A PASS: Kodo was not exercised through the S3-compatible path by this run.",
  )
}

///|
fn kodo_client(
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
async fn kodo_preflight(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
  bucket : String,
) -> (Bool, String) {
  let calls : Array[LiveCall] = []
  let client = kodo_client(
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
  let recorded = calls.length().to_string()
  (
    calls.length() > 0,
    "kodo preflight: answered=" + answered + " recorded=" + recorded,
  )
}

///|
async fn kodo_guarded(
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
  body : async (Array[Int64], String, String, String, String, String) -> Unit,
) -> Unit {
  let preflight = kodo_preflight(
    endpoint, region, access_key, secret_key, bucket,
  )
  if !preflight.0 {
    println(preflight.1)
    println("SKIP live Kodo compatibility check, endpoint did not answer")
    println(
      "SKIP IS NOT A PASS: Kodo was not exercised through the S3-compatible path by this run.",
    )
    return
  }
  println(preflight.1)
  // Transport-level deaths get retried — one cell was seen hanging until the
  // transport's 30s bound while its neighbours answered in hundreds of
  // milliseconds. Protocol-level reds are never retried. The bound is not
  // widened: upstream ruled that callers raise `timeout~` for their own payloads
  // (https://github.com/mldong/moon-hutool/issues/6).
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
    println("kodo attempt " + take + " failed: " + failure)
    if failure.find("Transport") is None {
      fail("Kodo case failed at the protocol layer, not retried: " + failure)
    }
  }
  fail(
    "Kodo case died at the transport layer three times in a row — this endpoint never answered the case",
  )
}

///|
/// Which buckets does this surface expose for this credential? Every judgement
/// below is classified by this answer — so a call that **dies** must not be
/// allowed to read as "nothing is exposed". Three takes, and only transport
/// deaths are retried; if none of them answer, this says so and stops.
async fn kodo_visible_buckets(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
) -> Array[String] {
  let attempts : Array[Int32] = [0]
  while attempts[0] < 3 {
    attempts[0] = attempts[0] + 1
    let take = attempts[0].to_string()
    let calls : Array[LiveCall] = []
    let client = kodo_client(
      endpoint,
      region,
      access_key,
      secret_key,
      @s3.AddressingStyle::Path,
      calls,
    )
    let names : Array[String] = []
    let failure = try {
      let page = client.list_buckets({
        prefix: None,
        continuation_token: None,
        max_buckets: Some(200),
      })
      for bucket in page.buckets {
        names.push(bucket.name)
      }
      ""
    } catch {
      error => render_error(error)
    }
    if failure == "" {
      println(
        "kodo list_buckets (take " +
        take +
        ") -> listed " +
        names.length().to_string() +
        " : " +
        names.join(","),
      )
      return names
    }
    println("kodo list_buckets (take " + take + ") -> " + failure)
    if failure.find("Transport") is None {
      fail(
        "the classification call ListBuckets failed at the protocol layer, not retried: " +
        failure,
      )
    }
  }
  fail(
    "ListBuckets never answered three times in a row: exposure is NOT measured, and no branch below is allowed to conclude anything from that",
  )
}

///|
/// A cell per (region-in-signature × addressing style), read-only: a key that
/// cannot exist and a listing of a prefix that cannot exist.
///
/// Two things are asserted. The URL shape, because that is the one thing this
/// client controls. And the invariant that came out of the measurements: the
/// service answers **the same way** whichever region is inside the SigV4 scope —
/// it is not validated. If that ever starts being validated, this cell goes red
/// and the fix is to stop sending a scope region the endpoint disagrees with,
/// not to widen the assertion.
async fn kodo_measure_matrix(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let styles : Array[(String, @s3.AddressingStyle)] = [
    ("path", @s3.AddressingStyle::Path),
    ("virtual-hosted", @s3.AddressingStyle::VirtualHosted),
  ]
  let prefix = live_case_prefix("kodo-matrix")
  for style in styles {
    let readings : Array[String] = []
    for signed_region in [region, "cn-north-9"] {
      let calls : Array[LiveCall] = []
      let client = kodo_client(
        endpoint,
        signed_region,
        access_key,
        secret_key,
        style.1,
        calls,
      )
      live_step(started, calls, "matrix " + signed_region + " / " + style.0)
      let getting = try {
        let response = client.get_object({
          bucket,
          key: prefix + "never-written.txt",
          range: None,
        })
        response.body.close()
        "GET accepted content_length=" + response.content_length.to_string()
      } catch {
        error => "GET " + render_error(error)
      }
      let listing = try {
        let page = client.list_objects({
          bucket,
          prefix: Some(prefix),
          delimiter: None,
          continuation_token: None,
          max_keys: Some(10),
        })
        "LIST ok objects=" + page.objects.length().to_string()
      } catch {
        error => "LIST " + render_error(error)
      }
      if calls.length() == 0 {
        fail("matrix cell " + style.0 + " sent no request at all")
      }
      let sent = last_call_url(calls)
      let answer = getting + " | " + listing
      println(
        "matrix scope=" +
        signed_region +
        " style=" +
        style.0 +
        " -> " +
        answer +
        " sent=" +
        sent,
      )
      readings.push(answer)
      if style.0 == "path" {
        assert_true(sent.find("/" + bucket + "/") is Some(_))
      } else {
        assert_true(sent.has_prefix("https://" + bucket + "."))
      }
    }
    // A single transient transport death would otherwise be read as "the two
    // cells answered differently", which is a false failure: name it separately
    // and let kodo_guarded's retry take it, so this equality only fires when the
    // service really answered two different ways.
    let flaky = readings[0].find("Transport") is Some(_) ||
      readings[1].find("Transport") is Some(_)
    if flaky {
      fail(
        "matrix cell died at S3Error.Transport — equality needs both answers from the service: " +
        readings[0] +
        " || " +
        readings[1],
      )
    }
    assert_eq(readings[0], readings[1])
  }
  // A key that really exists, when the runner names one: read-only, and the cell
  // that carried the whole difference between the two bucket kinds.
  match kodo_env("S3_KODO_EXISTING_KEY") {
    None =>
      println(
        "matrix realkey NOT MEASURED: S3_KODO_EXISTING_KEY is unset, so the read path is inferred only from a key that cannot exist",
      )
    Some(existing) =>
      for style in styles {
        let calls : Array[LiveCall] = []
        let client = kodo_client(
          endpoint,
          region,
          access_key,
          secret_key,
          style.1,
          calls,
        )
        live_step(started, calls, "realkey " + style.0)
        let reading = try {
          let response = client.get_object({
            bucket,
            key: existing,
            range: None,
          })
          let declared = response.content_length.to_string()
          response.body.close()
          "read back content_length=" + declared
        } catch {
          error => render_error(error)
        }
        println(
          "matrix realkey style=" +
          style.0 +
          " key=" +
          existing +
          " -> " +
          reading +
          " sent=" +
          last_call_url(calls),
        )
      }
  }
}

///|
/// The object family against a name the surface answers to. This is the half that
/// decides whether the surface works at all — refusals measured on one name don't.
async fn kodo_object_family(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = kodo_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("kodo-family")
  let key = prefix + "family.txt"
  let sample = "moon-s3 compatibility leg on Kodo 中文 +?&=%2F 0123456789abcdef\n"
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
  assert_true(
    calls[calls.length() - 1].url.has_prefix("https://" + bucket + "."),
  )
  live_step(started, calls, "HEAD")
  let stat = client.stat_object({ bucket, key, })
  let tool = stat.metadata.get("tool").unwrap_or("-")
  println(
    "HEAD content_length=" + stat.content_length.to_string() + " tool=" + tool,
  )
  assert_eq(stat.content_length, size)
  assert_eq(stat.metadata.get("tool"), Some("moon-s3-compat"))
  live_step(started, calls, "GET whole object")
  let got = client.get_object({ bucket, key, range: None, })
  let bytes = drain(got.body)
  let declared = got.content_length.to_string()
  let read = bytes.length().to_string()
  println("GET declared=" + declared + " read=" + read)
  assert_true(bytes.equal(payload))
  live_step(started, calls, "GET range bytes=0-3")
  let ranged = client.get_object({ bucket, key, range: Some("bytes=0-3"), })
  let window = ranged.content_range.unwrap_or("-")
  println("GET(range) content_range=" + window)
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
/// The promise of a presigned URL is that it works with no credentials at all —
/// and that one flipped character in the signature kills it. Measured here for
/// the same reason as everywhere else in this file: the vendor page says the
/// surface is S3-compatible, and only a run says whether this client's presigned
/// shape is answered.
async fn kodo_presigned_get(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = kodo_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  let prefix = live_case_prefix("kodo-presign")
  let key = prefix + "share.txt"
  let payload = @utf8.encode("presigned through Kodo's S3 surface\n".view())
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
  // A third cell, and the one that separates this surface from AWS: the same key
  // fetched with **no signature at all** is refused outright, even though the
  // bucket here is public-read. Documented on Qiniu's 服务域名 page (the S3 access
  // domains require an AWS Signature; anonymous access is not supported), so a
  // client that leans on "public bucket ⇒ plain GET works" gets a surprise that
  // has nothing to do with the bucket's own permission setting.
  live_step(started, calls, "GET the same key with no signature at all")
  let unsigned_url = match url.find("?") {
    Some(i) => url[:i].to_owned()
    None => url
  }
  let anon = bare.send({
    http_method: Get,
    url: unsigned_url,
    headers: [],
    body: @transport.RequestBody::Empty,
  })
  let anon_body = drain(anon.body)
  println(
    "unsigned anonymous GET status=" +
    anon.status.to_string() +
    " body=" +
    @utf8.decode_lossy(anon_body),
  )
  assert_eq(anon.status, 400)
  let _ = client.delete_object({ bucket, key, })
  live_sweep_verified(client, bucket, prefix)
}

///|
/// The other kind: a bucket the surface does not answer to by the name the
/// console uses. Both halves are measured facts (reproduced in both styles and
/// with either scope region), so both are asserted — and the second half is the
/// one that matters: the same key answers **200 under the name from the listing**
/// and **404 under this name**, which is what makes this a naming difference and
/// not a lost permission. If either answer changes shape, this case goes red
/// **here**, and what changes then is the branch in the test below, not the shape
/// of the request.
async fn kodo_invisible_bucket(
  started : Array[Int64],
  endpoint : String,
  region : String,
  bucket : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let calls : Array[LiveCall] = []
  let client = kodo_client(
    endpoint,
    region,
    access_key,
    secret_key,
    @s3.AddressingStyle::VirtualHosted,
    calls,
  )
  live_step(started, calls, "LIST on a bucket the surface does not name")
  let listing = try {
    let page = client.list_objects({
      bucket,
      prefix: Some(live_case_prefix("kodo-invisible")),
      delimiter: None,
      continuation_token: None,
      max_keys: Some(10),
    })
    "accepted objects=" + page.objects.length().to_string()
  } catch {
    error => render_error(error)
  }
  println("unnamed bucket LIST -> " + listing)
  assert_true(listing.has_prefix("403"))
  match kodo_env("S3_KODO_EXISTING_KEY") {
    None =>
      println(
        "unnamed bucket GET NOT MEASURED: S3_KODO_EXISTING_KEY is unset, so this cannot separate a naming difference from a lost permission",
      )
    Some(existing) => {
      live_step(started, calls, "GET a key that exists under the listed name")
      let reading = try {
        let response = client.get_object({ bucket, key: existing, range: None, })
        let declared = response.content_length.to_string()
        response.body.close()
        "read back content_length=" + declared
      } catch {
        error => render_error(error)
      }
      println("unnamed bucket GET " + existing + " -> " + reading)
      assert_true(reading.has_prefix("404"))
    }
  }
}

///|
async test "live Kodo: read-only cells, both styles, with the scope region varied" {
  match read_kodo_env() {
    None => report_kodo_skip()
    Some(environment) =>
      kodo_guarded(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
        kodo_measure_matrix,
      )
  }
}

///|
/// One entry point, two branches, both judged — and the branch is taken from what
/// the service itself reports, so the case cannot quietly stop exercising the
/// useful half.
async test "live Kodo: named buckets round-trip, console spellings it does not name are refused" {
  match read_kodo_env() {
    None => report_kodo_skip()
    Some(environment) => {
      let visible = kodo_visible_buckets(
        environment.0,
        environment.1,
        environment.3,
        environment.4,
      )
      let bucket = environment.2
      if visible.length() == 0 {
        fail("the S3 surface listed no buckets at all for this credential")
      }
      if visible.contains(bucket) {
        println(
          "kodo bucket " +
          bucket +
          " is named by the surface: running the object family",
        )
        kodo_guarded(
          environment.0,
          environment.1,
          environment.2,
          environment.3,
          environment.4,
          kodo_object_family,
        )
        kodo_guarded(
          environment.0,
          environment.1,
          environment.2,
          environment.3,
          environment.4,
          kodo_presigned_get,
        )
      } else {
        println(
          "kodo bucket " +
          bucket +
          " is NOT named by the S3 surface (it lists: " +
          visible.join(",") +
          "): asserting the measured refusal instead",
        )
        // Measured 2026-10-19, and the reason this branch exists for a bucket the
        // console clearly shows: this surface answers to one of this account's two
        // buckets under a six-character internal id instead of its console name —
        // same account, same region, same creation second, and the same object
        // reads back byte for byte (18137 bytes, sha256 equal to the CDN copy).
        // So "not in that list" means **use the listed name**, not "this bucket
        // cannot be reached over S3".
        println(
          "note: a name missing from that list is not proof of unreachability — the listed names may be internal ids for buckets the console spells differently. Compare CreationDate before concluding.",
        )
        kodo_guarded(
          environment.0,
          environment.1,
          environment.2,
          environment.3,
          environment.4,
          kodo_invisible_bucket,
        )
      }
    }
  }
}
