///|
// White-box checks for the ACL document parser: the live leg proves the endpoint
// answers something, and these prove the reader turns a captured document into the
// verdict — including the case where the verdict must be "not public". Without a
// private fixture a parser that reported "public" for everything would still pass
// the live round. Each document is one line: this toolchain has no multi-line
// string literal, and joining lines with `+` parses as a new statement.

///|
test "a private policy document parses without reading as public" {
  let document = "<AccessControlPolicy><Owner><ID>foo</ID></Owner><AccessControlList><Grant><Grantee xsi:type=\"CanonicalUser\"><ID>foo</ID></Grantee><Permission>FULL_CONTROL</Permission></Grant></AccessControlList></AccessControlPolicy>"
  let parsed = parse_access_control_policy(document)
  assert_eq(parsed.owner, Some("foo"))
  assert_eq(parsed.grants.length(), 1)
  assert_eq(parsed.grants[0].permission, Some("FULL_CONTROL"))
  assert_true(!parsed.has_all_users_read())
}

///|
test "an all-users read grant is what public-read looks like on the wire" {
  let document = "<AccessControlPolicy><Owner><ID>foo</ID></Owner><AccessControlList><Grant><Grantee xsi:type=\"Group\"><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee><Permission>READ</Permission></Grant><Grant><Grantee xsi:type=\"CanonicalUser\"><ID>foo</ID></Grantee><Permission>FULL_CONTROL</Permission></Grant></AccessControlList></AccessControlPolicy>"
  let parsed = parse_access_control_policy(document)
  assert_eq(parsed.grants.length(), 2)
  assert_eq(parsed.grants[0].permission, Some("READ"))
  assert_true(parsed.has_all_users_read())
}

///|
test "a read grant for another grantee is not public access" {
  // Same permission word, different group: matching only on READ would let an
  // AuthenticatedUsers grant look public.
  let document = "<AccessControlPolicy><Grant><Grantee><URI>http://acs.amazonaws.com/groups/global/AuthenticatedUsers</URI></Grantee><Permission>READ</Permission></Grant></AccessControlPolicy>"
  assert_true(!parse_access_control_policy(document).has_all_users_read())
}

///|
test "a document without grant blocks yields no grants rather than a guess" {
  let document = "<Error><Code>AccessDenied</Code></Error>"
  let parsed = parse_access_control_policy(document)
  assert_eq(parsed.grants.length(), 0)
  assert_true(!parsed.has_all_users_read())
  assert_eq(parsed.owner, None)
}
