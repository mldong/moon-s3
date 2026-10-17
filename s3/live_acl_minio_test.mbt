///|
// What a MinIO endpoint actually does with the ACL family, measured rather than
// assumed — the reading behind `S3PlatformConfig::supports_acl` being turned off
// for the MinIO legs.
//
// Assertions are pinned to today's measurements on two deployments (the shared
// :9000 and a self-started RELEASE.2025-09-07):
//   - `GET /key?acl` works and parses;
//   - `PUT /key?acl` answers `NotImplemented`, while the *same* request with a
//     broken signature answers `SignatureDoesNotMatch` — so the refusal is about
//     the operation, not about our request shape or signing;
//   - a release that implements the write will turn case 3 red, and that is the
//     moment to flip the flag rather than edit this file's expectations quietly.
//
// Env: S3_VHL_* (see the C 卡 §7-7 recipe). Missing env is a loud skip.

///|
fn error_code(error : @s3.S3Error) -> String {
  match error {
    @s3.S3Error::Service(details) => details.code
    other => render_error(other)
  }
}

///|
async fn live_acl_semantics(
  endpoint : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let client = @s3.Client::new(
    @s3.Config::new(
      endpoint,
      "us-east-1",
      @s3.Credentials::new(access_key, secret_key),
    ),
    @transport.AsyncHttpTransport::new(),
  )
  let bucket = "moonfs-acl-20261016"
  let key = "subject.txt"
  let _ = client.create_bucket({ bucket, }) catch {
    error => fail("create_bucket: " + render_error(error))
  }
  let body = @utf8.encode("acl semantics subject")
  let _ = client.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(body),
    content_type: None,
    metadata: Map([]),
  }) catch {
    error => fail("put_object: " + render_error(error))
  }

  // 1) Reading the policy document works.
  let before = client.get_object_acl({ bucket, key, }) catch {
    error => fail("get_object_acl: " + render_error(error))
  }
  let reading = "GET ?acl reading: grants=" +
    before.grants.length().to_string() +
    " public=" +
    before.has_all_users_read().to_string()
  println(reading)
  assert_true(before.grants.length() > 0)
  assert_true(!before.has_all_users_read())

  // 2) Writing a canned ACL is not implemented by this endpoint family.
  let write = try {
    let _ = client.put_object_acl({ bucket, key, acl: "public-read", })
    "accepted"
  } catch {
    error => error_code(error)
  }
  println("PUT ?acl reading=" + write)
  assert_eq(write, "NotImplemented")

  // 3) Control: the identical request with a broken secret is rejected as a
  //    signature problem, which is what makes (2) an endpoint fact.
  let wrong = @s3.Client::new(
    @s3.Config::new(
      endpoint,
      "us-east-1",
      @s3.Credentials::new(access_key, secret_key + "zz"),
    ),
    @transport.AsyncHttpTransport::new(),
  )
  let control = try {
    let _ = wrong.put_object_acl({ bucket, key, acl: "public-read", })
    "accepted"
  } catch {
    error => error_code(error)
  }
  let control_head = "same request, wrong secret reading=" + control
  println(control_head)
  assert_eq(control, "SignatureDoesNotMatch")

  let _ = client.delete_object({ bucket, key, }) catch {
    error => fail("delete object: " + render_error(error))
  }
  let _ = client.delete_bucket({ bucket, }) catch {
    error => fail("delete bucket: " + render_error(error))
  }
  let gone = client.bucket_exists({ bucket, }) catch {
    error => fail("bucket_exists: " + render_error(error))
  }
  assert_true(!gone.exists)
}

///|
async test "live MinIO: ACL reads work, canned ACL writes are not implemented" {
  match read_vhl_env() {
    None => {
      println("SKIP ACL semantics check, S3_VHL_* not supplied")
      println(
        "SKIP IS NOT A PASS: the endpoint's ACL behaviour was not measured by this run.",
      )
    }
    Some(environment) =>
      live_acl_semantics(environment.0, environment.1, environment.2)
  }
}
