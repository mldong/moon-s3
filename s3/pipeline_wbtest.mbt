///|
// Shape tests for the pieces the live check depends on but cannot by itself
// attribute: the UTC stamp strings SigV4 signs with (calendar and clock come
// from `@date`; these pin our wire form), the URL and payload-hash rules the
// signature is computed over, and the minimal XML reader. All offline.

///|
fn empty_hash() -> String {
  // NIST vector: SHA-256 of the empty string.
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}

///|
fn error_kind_name(error : S3Error) -> String {
  match error {
    S3Error::InvalidConfig(_) => "InvalidConfig"
    S3Error::InvalidRequest(_) => "InvalidRequest"
    S3Error::Signing(_) => "Signing"
    S3Error::Transport(_) => "Transport"
    S3Error::Service(_) => "Service"
  }
}

///|
fn build_or_fail(
  config : Config,
  bucket : String,
  key : String,
  label : String,
) -> String raise {
  build_object_url(config, bucket, key) catch {
    error => fail(label + " raised " + error_kind_name(error))
  }
}

///|
fn path_config(endpoint : String) -> Config {
  Config::new(endpoint, "us-east-1", Credentials::new("ak", "sk"))
}

///|
test "utc stamps match known epoch vectors" {
  let (zero_date, zero_stamp) = utc_stamps(0L)
  assert_eq(zero_date, "19700101")
  assert_eq(zero_stamp, "19700101T000000Z")
  let (known_date, known_stamp) = utc_stamps(1700000000000L)
  assert_eq(known_date, "20231114")
  assert_eq(known_stamp, "20231114T221320Z")
  let (autumn_date, autumn_stamp) = utc_stamps(1792108800000L)
  assert_eq(autumn_date, "20261016")
  assert_eq(autumn_stamp, "20261016T000000Z")
  let (_, boundary_stamp) = utc_stamps(1609459199000L)
  assert_eq(boundary_stamp, "20201231T235959Z")
}

///|
test "utc stamps keep the leap-day and era boundaries" {
  let (_, leap_2024) = utc_stamps(1709209845000L)
  assert_eq(leap_2024, "20240229T123045Z")
  let (_, after_leap) = utc_stamps(1709251200000L)
  assert_eq(after_leap, "20240301T000000Z")
  let (_, leap_2000) = utc_stamps(951782400000L)
  assert_eq(leap_2000, "20000229T000000Z")
  // 2000-03-01 is where the 400-year era used by the algorithm starts.
  let (_, era_start) = utc_stamps(951868800000L)
  assert_eq(era_start, "20000301T000000Z")
  // 2100 is a century year that is *not* a leap year.
  let (_, century) = utc_stamps(4107542400000L)
  assert_eq(century, "21000301T000000Z")
}

///|

///|
/// The exact reading a live run reported: 1792094654969 ms is 2026-10-15
/// 20:04:14 UTC. Pinned because a host clock and a conversion bug look
/// identical from the outside.
test "utc stamps match the reading a live run reported" {
  let (date, stamp) = utc_stamps(1792094654969L)
  assert_eq(date, "20261015")
  assert_eq(stamp, "20261015T200414Z")
}

///|
test "utc stamps floor-divide a pre-epoch timestamp" {
  let (before_date, before_stamp) = utc_stamps(-1000L)
  assert_eq(before_date, "19691231")
  assert_eq(before_stamp, "19691231T235959Z")
}

///|
test "path style url carries the bucket and the encoded key" {
  let url = build_or_fail(
    path_config("http://minio.invalid:9000"),
    "mldong",
    "a/b c.txt",
    "path style",
  )
  assert_eq(url, "http://minio.invalid:9000/mldong/a/b%20c.txt")
}

///|
test "endpoint scheme and trailing slash are normalised" {
  let bare = build_or_fail(
    path_config("minio.invalid:9000/"),
    "mldong",
    "key",
    "bare endpoint",
  )
  assert_eq(bare, "http://minio.invalid:9000/mldong/key")
}

///|
test "listing an empty key keeps the bucket prefix slash" {
  let url = build_or_fail(
    path_config("http://minio.invalid:9000"),
    "mldong",
    "",
    "listing",
  )
  assert_eq(url, "http://minio.invalid:9000/mldong/")
}

///|
/// Virtual-hosted addressing is construction-verified only: the live run
/// addressed MinIO path-style, so this test proves shape, not acceptance.
test "virtual hosted url moves the bucket into the authority" {
  let credentials = Credentials::new("ak", "sk")
  let config = Config::new(
    "https://s3.example.com/",
    "us-east-1",
    credentials,
    addressing_style=VirtualHosted,
  )
  let url = build_or_fail(config, "mldong", "k/e.txt", "virtual hosted")
  assert_eq(url, "https://mldong.s3.example.com/k/e.txt")
}

///|
test "an endpoint with no host is rejected instead of guessed" {
  let reading = try {
    let _ = build_object_url(path_config("/"), "mldong", "key")
    "no-error"
  } catch {
    S3Error::InvalidConfig(_) => "InvalidConfig"
    error => "unexpected " + error_kind_name(error)
  }
  assert_eq(reading, "InvalidConfig")
}

///|
test "payload hash follows the body shape" {
  assert_eq(payload_hash_of(@transport.RequestBody::Empty), empty_hash())
  let abc = @utf8.encode("abc".view())
  let hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  assert_eq(payload_hash_of(@transport.RequestBody::Bytes(abc)), hex)
}

///|
test "xml reads elements, repeats and the five entities" {
  let doc = "<Error><Code>NoSuchKey</Code><Message>no such &amp; key</Message></Error>"
  assert_eq(xml_first(doc, "Code"), Some("NoSuchKey"))
  assert_eq(xml_first(doc, "Message"), Some("no such & key"))
  assert_eq(xml_first(doc, "RequestId"), None)
  let one = "<Contents><Key>a/1</Key><Size>3</Size></Contents>"
  let two = "<Contents><Key>a/2</Key><Size>4</Size></Contents>"
  let blocks = xml_all(one + two, "Contents")
  assert_eq(blocks.length(), 2)
  assert_eq(xml_first(blocks[1], "Key"), Some("a/2"))
  assert_eq(xml_unescape("&lt;a&gt;&quot;&apos;&amp;"), "<a>\"'&")
}

///|
/// Metadata keys are read back lower-cased: the header name is
/// case-insensitive on the wire, so this is the documented normalisation.
test "user metadata strips the amz prefix and lowercases the key" {
  let headers : Array[@transport.Header] = [
    { name: "X-Amz-Meta-Tool", value: "moon-file-storage", },
    { name: "x-amz-meta-stage", value: "A", },
    { name: "etag", value: "\"abc\"", },
  ]
  let metadata = response_user_metadata(headers)
  assert_eq(metadata.get("tool"), Some("moon-file-storage"))
  assert_eq(metadata.get("stage"), Some("A"))
  assert_eq(metadata.length(), 2)
}

///|
test "int64 header parsing refuses anything non-decimal" {
  let headers : Array[@transport.Header] = [
    { name: "Content-Length", value: " 42 ", },
    { name: "x-amz-weird", value: "0x2a", },
  ]
  assert_eq(int64_header(headers, "content-length"), Some(42L))
  assert_eq(int64_header(headers, "x-amz-weird"), None)
  assert_eq(int64_header(headers, "absent"), None)
}

///|
/// The signed query and the sent query must be one and the same string, and
/// that string is the canonical form: encoded, then sorted.
test "canonical query encodes and sorts" {
  let pairs : Array[@sigv4.QueryPair] = [
    { key: "prefix", value: "a b/c", },
    { key: "list-type", value: "2", },
  ]
  assert_eq(@sigv4.canonical_query(pairs), "list-type=2&prefix=a%20b%2Fc")
}
