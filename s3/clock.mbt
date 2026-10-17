///|
/// SigV4 needs two UTC readings: `YYYYMMDD` for the credential scope and
/// `YYYYMMDDTHHMMSSZ` for `x-amz-date` / `X-Amz-Date`.
///
/// The clock, the epoch-to-calendar conversion and the floor-for-negative-epoch
/// rule all belong to `mldong/moon-hutool/date` (基础件归口，方案 §3.1-④). Only the
/// wire shape is assembled here: hutool's UTC rendering with its separators
/// dropped, which is what the protocol spells the same instant as.

///|
fn amz_date(epoch_millis : Int64) -> String {
  let wall = @date.DateTime::from_epoch_millis(epoch_millis, 0)
  let whole_second = wall.to_epoch_millis(0) - wall.milli.to_int64()
  // Offset 0 is what makes hutool terminate the text with `Z`, the same marker
  // the protocol carries. The sub-second remainder is removed first because the
  // fractional group is conditional, and a stamp must be fixed-width.
  let iso = @date.to_rfc3339(whole_second, 0)
  let flat = iso.replace_all(old="-", new="")
  flat.replace_all(old=":", new="")
}

///|
/// `(credential-scope date, timestamp)`. The date is read off the front of the
/// timestamp instead of converted a second time, so the two can never disagree.
pub fn utc_stamps(epoch_millis : Int64) -> (String, String) {
  let stamp = amz_date(epoch_millis)
  (stamp[0:8].to_owned(), stamp)
}

///|
pub fn now_stamps() -> (String, String) {
  utc_stamps(@date.now_millis())
}
