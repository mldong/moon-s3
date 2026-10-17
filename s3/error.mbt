///|
pub(all) struct ServiceError {
  status_code : Int32
  code : String
  message : String
  request_id : String?
  host_id : String?
  /// `<Resource>` as the service filled it in: which bucket or key **it** read
  /// out of the request. This is what makes a virtual-hosted addressing check a
  /// reading rather than a guess — a 404 by itself says nothing about which name
  /// the endpoint resolved.
  resource : String?
}

///|
pub(all) suberror S3Error {
  InvalidConfig(String)
  InvalidRequest(String)
  Signing(@sigv4.SigningError)
  Transport(@transport.TransportError)
  Service(ServiceError)
}
