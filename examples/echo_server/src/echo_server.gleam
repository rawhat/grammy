import gleam/bytes_builder
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None}
import gleam/otp/actor
import gleam/string
import grammy

pub fn main() {
  let assert Ok(_supervisor) =
    grammy.new(init: fn() { #(Nil, None) }, handler: fn(msg, conn, state) {
      case msg {
        grammy.Packet(address, port, message) -> {
          io.println(
            grammy.ip_address_to_string(address)
            <> ":"
            <> int.to_string(port)
            <> " says "
            <> string.inspect(message),
          )
          let assert Ok(_nil) =
            grammy.send_to(
              conn,
              address,
              port,
              bytes_builder.from_bit_array(message),
            )
          actor.continue(state)
        }
        grammy.User(_user) -> {
          actor.continue(state)
        }
      }
    })
    |> grammy.start

  process.sleep_forever()
}
