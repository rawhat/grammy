import startest
import startest/expect

pub fn main() {
  startest.run(startest.default_config())
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  1
  |> expect.to_equal(1)
}
