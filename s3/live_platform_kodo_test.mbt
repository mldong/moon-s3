///|
// Qiniu Kodo's S3-compatible surface. Measured, not restated from the vendor
// page.
//
// Env: S3_KODO_ENDPOINT / S3_KODO_REGION / S3_KODO_BUCKET / S3_KODO_AK /
// S3_KODO_SK, plus the optional S3_KODO_EXISTING_KEY (a key that really exists
// in that bucket; one read-only cell uses it).
//
// What two rounds against a real account established, in this order:
//
//   1. The surface works. Against a bucket it actually exposes, the whole object
//      family round-trips: PUT with user metadata, HEAD, GET byte for byte,
//      `Range: bytes=0-3`, a listing that finds the key, and a sweep of the
//      case's own prefix down to zero residue. Both addressing styles work. And
//      the region carried inside the SigV4 scope is not what this surface looks
//      at: a region that is not even in Kodo's table (`cn-north-9`) answers
//      character for character the same as the real one. The endpoint carries the
//      region, and a wrong endpoint says so directly (`400 IncorrectRegion`).
//   2. Whether a bucket is exposed is a separate question and it decides
//      everything. The account's production Kodo bucket — fine over the native
//      API, upload tokens and CDN playback both working — is **not** in this
//      surface's view: service-level `GET /` lists other buckets and not it,
//      listing its objects answers `403 AccessDenied`, writing answers
//      `403 AccessDenied`, and a key that genuinely exists answers `NoSuchKey` in
//      both styles. A different region's endpoint states the reason plainly
//      (`400 IncorrectRegion`), so that is not a wrong-region artifact: the
//      region used here is the one that bucket lives in.
//
// An earlier note here claimed Kodo's S3 surface was dead. It was measured only
// against an unexposed bucket, which is why it saw nothing but refusals — and it
// never wrote an object, so it never reached the half that works.
//
// Hence the precondition this file automates: ask the surface which buckets it
// exposes before judging anything else. The classified case below takes one of
// two branches, each with its own assertions, so it cannot degenerate into a
// block that only prints.
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
/// below is classified by this answer.
async fn kodo_visible_buckets(
  endpoint : String,
  region : String,
  access_key : String,
  secret_key : String,
) -> Array[String] {
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
  let reading = try {
    let page = client.list_buckets({
      prefix: None,
      continuation_token: None,
      max_buckets: Some(200),
    })
    for bucket in page.buckets {
      names.push(bucket.name)
    }
    "listed " + names.length().to_string()
  } catch {
    error => render_error(error)
  }
  println("kodo list_buckets -> " + reading + " : " + names.join(","))
  names
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
        "matrix cell died at the transport layer — equality needs both answers from the service",
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
/// The object family against a bucket the surface exposes — the half the earlier
/// round never reached, and the reason its verdict was wrong.
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
/// The other kind: a bucket the surface does not expose. The refusal is a
/// measured fact (reproduced in both styles and with either scope region), so it
/// is asserted. The day such a bucket gets exposed, this case goes red **here** —
/// that red is the message, and what changes then is the branch below, not the
/// shape of the request.
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
  live_step(started, calls, "LIST on a bucket outside the S3 view")
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
  println("unexposed bucket LIST -> " + listing)
  assert_true(listing.has_prefix("403"))
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
async test "live Kodo: exposed buckets round-trip, unexposed ones are refused" {
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
          "kodo bucket " + bucket + " is exposed: running the object family",
        )
        kodo_guarded(
          environment.0,
          environment.1,
          environment.2,
          environment.3,
          environment.4,
          kodo_object_family,
        )
      } else {
        println(
          "kodo bucket " +
          bucket +
          " is NOT exposed by the S3 surface (it lists: " +
          visible.join(",") +
          "): asserting the measured refusal instead",
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
