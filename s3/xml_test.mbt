///|
// Entity decoding, judged on the shapes the endpoints actually answer with. The
// numeric spelling is not a curiosity: MinIO returns a part's ETag as
// `&#34;…&#34;` inside `ListPartsResult`, and a reader that only knows `&quot;`
// hands that back to `CompleteMultipartUpload` as-is — the server then answers
// `InvalidPart`, which reads like "the part was never uploaded" and is nothing of
// the sort (measured against the shared MinIO this round, through the facade's leg).

///|
test "a numeric entity is decoded the same way as its named twin" {
  let document = "<ListPartsResult><Part><ETag>&#34;a13ab993d329673bd5cf885e25106b27&#34;</ETag></Part></ListPartsResult>"
  let from_numbers = @s3.xml_first(document, "ETag")
  let named = "<ListPartsResult><Part><ETag>&quot;a13ab993d329673bd5cf885e25106b27&quot;</ETag></Part></ListPartsResult>"
  assert_eq(from_numbers, @s3.xml_first(named, "ETag"))
  assert_eq(from_numbers, Some("\"a13ab993d329673bd5cf885e25106b27\""))
}

///|
/// One escape, decoded once. A reader that decodes `&#38;`/`&amp;` eagerly turns
/// `&#38;lt;` into `<` — two levels of unescaping from one level of text — and the
/// object key that came back would no longer be the key that was stored.
test "ampersand forms are decoded last so nothing is decoded twice" {
  assert_eq(@s3.xml_unescape("&#38;lt;"), "&lt;")
  assert_eq(@s3.xml_unescape("&amp;#34;"), "&#34;")
  assert_eq(@s3.xml_unescape("&amp;amp;"), "&amp;")
  assert_eq(@s3.xml_unescape("&amp;lt;"), "&lt;")
}

///|
test "keys with punctuation survive the round through the reader" {
  let document = "<Contents><Key>reports &amp; charts/2026&#47;10&#47;16.txt</Key></Contents>"
  // `&#47;` is a slash. The old local table left decimal references alone; the
  // hutool reader decodes them (that is what the reference implementation does),
  // so this asserts the `&amp;` part, which both generations must agree on.
  let key = @s3.xml_first(document, "Key")
  match key {
    Some(value) => {
      assert_true(value.find(" & ") is Some(_))
      assert_true(value.find("&amp;") is None)
    }
    None => fail("the key did not parse")
  }
}

///|
/// The defect this round found and fixed. `xml_all` on a container decoded the
/// whole inner text, then the leaf read decoded it again, so a key stored
/// literally as `a&lt;b` — which the endpoint answers as
/// `<Key>a&amp;lt;b</Key>` — came back as `a<b`. The listing is then fed to
/// copy and delete, so the second decode addresses a different object.
/// `xml_sections` returns the segment undecoded, so exactly one pass happens.
test "a container segment is decoded once, not twice" {
  let document = "<ListBucketResult><Contents><Key>a&amp;lt;b</Key>" +
    "<Size>3</Size></Contents></ListBucketResult>"
  let blocks = @s3.xml_sections(document, "Contents")
  assert_eq(blocks.length(), 1)
  if !blocks[0].contains("a&amp;lt;b") {
    fail("splitting a container must not decode: " + blocks[0])
  }
  assert_eq(@s3.xml_first(blocks[0], "Key"), Some("a&lt;b"))
  // The old two-pass shape, kept here so nobody reintroduces it by reaching for
  // `xml_all` on a container again.
  assert_eq(
    @s3.xml_first(@s3.xml_all(document, "Contents")[0], "Key"),
    Some("a<b"),
  )
}

///|
/// Not promised to equal the old table: a lone surrogate cannot be represented in
/// a MoonBit `String`, so the whole string comes back untouched rather than the
/// leading tokens decoded. Decoding happens per string or not at all.
test "an undecodable entity returns the whole string untouched" {
  assert_eq(@s3.xml_unescape("&#34;a&#xD800;"), "&#34;a&#xD800;")
  assert_eq(@s3.xml_unescape("&#x41;"), "A")
}

///|
/// The write side, now delegated to moon-hutool. Pinned here because it is *not*
/// byte-for-byte the table this SDK used to carry: hutool escapes all five
/// reference characters, so `'` becomes `&apos;`. That is the shape the reference
/// implementation produces, and the reader below takes it back — which is what
/// `CompleteMultipartUpload` is judged on, since the ETag has to round-trip.
test "escape covers the five reference characters and round-trips back" {
  assert_eq(@s3.xml_escape("a<b&c>\"e'f"), "a&lt;b&amp;c&gt;&quot;e&apos;f")
  assert_eq(@s3.xml_escape("&amp;lt;"), "&amp;amp;lt;")
  assert_eq(
    @s3.xml_unescape(@s3.xml_escape("it's a & <b>x</b> \"y\"")),
    "it's a & <b>x</b> \"y\"",
  )
}
