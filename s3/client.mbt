///|
pub struct Client {
  priv config : Config
  priv transport : &@transport.Transport
}

///|
pub fn Client::new(
  config : Config,
  transport : &@transport.Transport,
) -> Client {
  { config, transport, }
}

///|
pub fn Client::config(self : Client) -> Config {
  self.config
}
