///|
test "signing signatures consume explicit time and prepared requests" {
  let _ : (@transport.Request, @sigv4.Credentials, String, String, String) -> @transport.Request raise @sigv4.SigningError = @sigv4.sign
  let _ : (@transport.Request, @sigv4.Credentials, String, String, Int32) -> @transport.Request raise @sigv4.SigningError = @sigv4.presign
  let request : @transport.Request = {
    http_method: @transport.Get,
    url: "https://bucket.example.test/raw%20key?a=2&a=1&empty=&value=%2B",
    headers: [{ name: "x-test", value: "unchanged", }],
    body: @transport.Empty,
  }
  assert_eq(
    request.url,
    "https://bucket.example.test/raw%20key?a=2&a=1&empty=&value=%2B",
  )
}
