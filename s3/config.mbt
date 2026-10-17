///|
pub using @sigv4 {type Credentials}

///|
pub(all) enum AddressingStyle {
  Path
  VirtualHosted
}

///|
pub struct Config {
  endpoint : String
  region : String
  credentials : Credentials
  addressing_style : AddressingStyle
}

///|
pub fn Config::new(
  endpoint : String,
  region : String,
  credentials : Credentials,
  addressing_style~ : AddressingStyle = Path,
) -> Config {
  { endpoint, region, credentials, addressing_style, }
}
