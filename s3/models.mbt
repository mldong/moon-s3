///|
pub(all) struct PutObjectRequest {
  bucket : String
  key : String
  body : @transport.RequestBody
  content_type : String?
  metadata : Map[String, String]
}

///|
pub(all) struct PutObjectResponse {
  etag : String
}

///|
pub(all) struct GetObjectRequest {
  bucket : String
  key : String
  range : String?
}

///|
pub(all) struct GetObjectResponse {
  content_length : Int64
  content_type : String?
  metadata : Map[String, String]
  content_range : String?
  accept_ranges : String?
  etag : String?
  body : &@transport.ResponseBody
}

///|
pub(all) struct StatObjectRequest {
  bucket : String
  key : String
}

///|
pub(all) struct StatObjectResponse {
  content_length : Int64
  content_type : String?
  metadata : Map[String, String]
  etag : String?
  last_modified : String?
}

///|
pub(all) struct DeleteObjectRequest {
  bucket : String
  key : String
}

///|
pub(all) struct DeleteObjectResponse {
  delete_marker : Bool?
  version_id : String?
}

///|
pub(all) struct CopyObjectRequest {
  bucket : String
  key : String
  source_bucket : String
  source_key : String
}

///|
pub(all) struct CopyObjectResponse {
  etag : String
  last_modified : String?
}

///|
pub(all) struct ListObjectsRequest {
  bucket : String
  prefix : String?
  delimiter : String?
  continuation_token : String?
  max_keys : Int32?
}

///|
pub(all) struct ObjectInfo {
  key : String
  etag : String?
  size : Int64
  last_modified : String?
}

///|
pub(all) struct ListObjectsResponse {
  objects : Array[ObjectInfo]
  common_prefixes : Array[String]
  is_truncated : Bool
  next_continuation_token : String?
}

///|
pub(all) struct CreateBucketRequest {
  bucket : String
}

///|
pub(all) struct CreateBucketResponse {
  location : String?
}

///|
pub(all) struct BucketExistsRequest {
  bucket : String
}

///|
pub(all) struct BucketExistsResponse {
  exists : Bool
}

///|
pub(all) struct ListBucketsRequest {
  prefix : String?
  continuation_token : String?
  max_buckets : Int32?
}

///|
pub(all) struct BucketInfo {
  name : String
  creation_date : String?
}

///|
pub(all) struct ListBucketsResponse {
  buckets : Array[BucketInfo]
  continuation_token : String?
}

///|
pub(all) struct DeleteBucketRequest {
  bucket : String
}

///|
pub(all) struct DeleteBucketResponse {}

///|
pub(all) struct CreateMultipartUploadRequest {
  bucket : String
  key : String
  content_type : String?
  metadata : Map[String, String]
}

///|
pub(all) struct CreateMultipartUploadResponse {
  bucket : String
  key : String
  upload_id : String
}

///|
pub(all) struct UploadPartRequest {
  bucket : String
  key : String
  upload_id : String
  part_number : Int32
  body : @transport.RequestBody
}

///|
pub(all) struct UploadPartResponse {
  etag : String
}

///|
pub(all) struct CompletedPart {
  part_number : Int32
  etag : String
}

///|
pub(all) struct CompleteMultipartUploadRequest {
  bucket : String
  key : String
  upload_id : String
  parts : Array[CompletedPart]
}

///|
pub(all) struct CompleteMultipartUploadResponse {
  bucket : String
  key : String
  etag : String
}

///|
pub(all) struct AbortMultipartUploadRequest {
  bucket : String
  key : String
  upload_id : String
}

///|
pub(all) struct AbortMultipartUploadResponse {}

///|
pub(all) struct ListPartsRequest {
  bucket : String
  key : String
  upload_id : String
  part_number_marker : Int32?
  max_parts : Int32?
}

///|
pub(all) struct PartInfo {
  part_number : Int32
  etag : String
  size : Int64
  last_modified : String?
}

///|
pub(all) struct ListPartsResponse {
  parts : Array[PartInfo]
  is_truncated : Bool
  next_part_number_marker : Int32?
}

///|
pub(all) struct PutObjectAclRequest {
  bucket : String
  key : String
  /// canned ACL 的头值原文（`private` / `public-read` / `public-read-write`）——
  /// 协议层照发，语义归存储核心层的枚举，SDK 不自己发明第二套名字
  acl : String
}

///|
pub(all) struct PutObjectAclResponse {}

///|
/// One `<Grant>` from an `AccessControlPolicy` document. `grantee` is whatever
/// identified the grantee: the group URI (public grants) or the owner id /
/// email address. Left unparsed on purpose — whether a given grant means
/// "public read" is a policy question for the caller, not for the wire layer.
pub(all) struct AclGrant {
  grantee : String?
  permission : String?
}

///|
pub(all) struct GetObjectAclRequest {
  bucket : String
  key : String
}

///|
pub(all) struct GetObjectAclResponse {
  owner : String?
  grants : Array[AclGrant]
}

///|
/// True when some grant gives the AllUsers group read access — the canned
/// `public-read` shape. Compared by substring because the group URI is written
/// differently across stores (`http://` on MinIO, `https://` on AWS), and
/// neither spelling should make a private object look public or the other way round.
pub fn GetObjectAclResponse::has_all_users_read(
  self : GetObjectAclResponse,
) -> Bool {
  let mut found = false
  for grant in self.grants {
    match (grant.grantee, grant.permission) {
      (Some(grantee), Some("READ")) =>
        if grantee.find("global/AllUsers") is Some(_) {
          found = true
        }
      _ => ()
    }
  }
  found
}
