///|
// What a MinIO endpoint actually does with the ACL family, measured rather than
// assumed — the reading behind `S3PlatformConfig::supports_acl` being turned off
// for the MinIO legs.
//
// Assertions are pinned to measurements on the RELEASE.2025-09-07 family (a shared
// local deployment and the throwaway instance CI downloads for itself — same
// generation, so the CI reading and the local one are the same measurement):
//   - `GET /key?acl` works and parses;
//   - `PUT /key?acl` answers `NotImplemented`, while the *same* request with a
//     broken signature answers `SignatureDoesNotMatch` — so the refusal is about
//     the operation, not about our request shape or signing;
//   - a release that implements the write will turn case 3 red, and that is the
//     moment to flip the flag rather than edit this file's expectations quietly.
//
// Env: S3_ACL_REFUSE_ENDPOINT / S3_ACL_REFUSE_AK / S3_ACL_REFUSE_SK. This is
// deliberately its own trio and not the `S3_VHL_*` one the virtual-hosted leg
// reads: the two legs ask opposite things of a single endpoint (this one must
// refuse `PUT ?acl`, that one must route buckets by `Host`, which the MinIO
// family no longer does), so sharing the names would turn CI red.
// Missing env is a loud skip.
//
// MOONFS_RUN_TAG scopes the bucket name to one run; without it the millisecond
// clock is used, so two runs on the same day never share a bucket — a shared
// bucket means one run's cleanup deletes the other run's in-flight subject.

///|
fn acl_refuse_env_of(name : String) -> String {
  @env.get_env_var(name).unwrap_or("")
}

///|
fn read_acl_refuse_env() -> (String, String, String)? {
  let names : Array[String] = [
    "S3_ACL_REFUSE_ENDPOINT", "S3_ACL_REFUSE_AK", "S3_ACL_REFUSE_SK",
  ]
  let missing : Array[String] = []
  for name in names {
    if acl_refuse_env_of(name).is_empty() {
      missing.push(name)
    }
  }
  if missing.length() > 0 {
    println("missing: " + missing.join(", "))
    None
  } else {
    Some(
      (
        acl_refuse_env_of("S3_ACL_REFUSE_ENDPOINT"),
        acl_refuse_env_of("S3_ACL_REFUSE_AK"),
        acl_refuse_env_of("S3_ACL_REFUSE_SK"),
      ),
    )
  }
}

///|
fn run_tag() -> String {
  let from_env = @env.get_env_var("MOONFS_RUN_TAG").unwrap_or("")
  if from_env.is_empty() {
    @env.now().to_string()
  } else {
    from_env
  }
}

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
  let bucket = "moonfs-acl-" + run_tag()
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
  match read_acl_refuse_env() {
    None => {
      println("SKIP ACL semantics check, S3_ACL_REFUSE_* not supplied")
      println(
        "SKIP IS NOT A PASS: the endpoint's ACL behaviour was not measured by this run.",
      )
    }
    Some(environment) =>
      live_acl_semantics(environment.0, environment.1, environment.2)
  }
}
