///|
pub struct Credentials {
  access_key : String
  secret_key : String
  session_token : String?
}

///|
pub fn Credentials::new(
  access_key : String,
  secret_key : String,
  session_token~ : String? = None,
) -> Credentials {
  { access_key, secret_key, session_token, }
}

///|
pub(all) suberror SigningError {
  InvalidInput(String)
}
