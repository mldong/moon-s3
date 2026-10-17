///|
// Object ACL family: `PUT /key?acl` carrying a canned ACL in `x-amz-acl`, and
// `GET /key?acl` reading the resulting `AccessControlPolicy` back.
//
// The read exists because a 200 on the write alone says nothing: the earlier
// virtual-hosted round showed exactly that (that server answered 200 to requests whose
// bucket name in `Host` it had ignored). Whether a grant means "public" is left
// to the caller — this layer reports the document it was given.

///|
fn acl_subresource() -> Array[@sigv4.QueryPair] {
  [{ key: "acl", value: "", }]
}

///|
pub async fn Client::put_object_acl(
  self : Client,
  request : PutObjectAclRequest,
) -> PutObjectAclResponse raise S3Error {
  if request.bucket.is_empty() || request.key.is_empty() {
    raise InvalidRequest("put_object_acl needs a bucket and key")
  }
  if request.acl.is_empty() {
    raise InvalidRequest("put_object_acl needs a canned acl value")
  }
  let headers : Array[@transport.Header] = [
    { name: "x-amz-acl", value: request.acl, },
  ]
  let spec : RequestSpec = {
    http_method: Put,
    bucket: request.bucket,
    key: request.key,
    query: acl_subresource(),
    body: @transport.RequestBody::Empty,
    headers,
  }
  let response = self.execute(spec)
  response.body.close()
  PutObjectAclResponse::{ }
}

///|
/// Every `<Grant>` block of the document, in document order. A hand-rolled split
/// rather than `xml_all` because a grant holds nested elements (the grantee is
/// itself an element with an `xsi:type` attribute).
fn grant_blocks(xml : String) -> Array[String] {
  let open = "<Grant>"
  let close = "</Grant>"
  let out : Array[String] = []
  let mut cursor = 0
  while cursor < xml.length() {
    let rest = xml[cursor:xml.length()].to_owned()
    match rest.find(open) {
      None => cursor = xml.length()
      Some(start) =>
        match rest[start:].find(close) {
          None => cursor = xml.length()
          Some(offset) => {
            let from = cursor + start
            let to = from + offset + close.length()
            out.push(xml[from:to].to_owned())
            cursor = to
          }
        }
    }
  }
  out
}

///|
/// The document is parsed but not judged: whether a grant amounts to "public"
/// depends on which URI the store uses for the AllUsers group, so the verdict
/// lives in `has_all_users_read` where it can be tested against a captured
/// document instead of only against a live server.
fn parse_access_control_policy(xml : String) -> GetObjectAclResponse {
  let grants : Array[AclGrant] = []
  for block in grant_blocks(xml) {
    let grantee = match xml_first(block, "URI") {
      Some(uri) => Some(uri)
      None =>
        match xml_first(block, "EmailAddress") {
          Some(mail) => Some(mail)
          None => xml_first(block, "ID")
        }
    }
    grants.push(AclGrant::{
      grantee,
      permission: xml_first(block, "Permission"),
    })
  }
  GetObjectAclResponse::{ owner: xml_first(xml, "ID"), grants, }
}

///|
pub async fn Client::get_object_acl(
  self : Client,
  request : GetObjectAclRequest,
) -> GetObjectAclResponse raise S3Error {
  if request.bucket.is_empty() || request.key.is_empty() {
    raise InvalidRequest("get_object_acl needs a bucket and key")
  }
  let spec : RequestSpec = {
    http_method: Get,
    bucket: request.bucket,
    key: request.key,
    query: acl_subresource(),
    body: @transport.RequestBody::Empty,
    headers: [],
  }
  let response = self.execute(spec)
  let body = response.body
  let raw = read_all(body)
  body.close()
  parse_access_control_policy(@utf8.decode_lossy(raw))
}
