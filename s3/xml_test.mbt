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
  // `&#47;` is a slash: outside the five predefined characters the reader leaves
  // it alone on purpose, so this asserts the *known* part only.
  let key = @s3.xml_first(document, "Key")
  match key {
    Some(value) => {
      assert_true(value.find(" & ") is Some(_))
      assert_true(value.find("&amp;") is None)
    }
    None => fail("the key did not parse")
  }
}
