import gleam/bytes_builder
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam/otp/actor
import gleam/string
import grammy

pub type Message {
  Broadcast(data: BitArray)
}

pub fn main() {
  let return = process.new_subject()
  let selector =
    process.new_selector()
    |> process.selecting(return, fn(msg) { msg })

  let assert Ok(_supervisor) =
    grammy.new(
      init: fn() {
        let subj = process.new_subject()
        let selector =
          process.new_selector()
          |> process.selecting(subj, fn(msg) { msg })
        #(Nil, Some(selector))
      },
      handler: fn(msg, conn, state) {
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
          grammy.User(Broadcast(data)) -> {
            let assert Ok(_) =
              grammy.send_to(
                conn,
                #(127, 0, 0, 1),
                1234,
                bytes_builder.from_bit_array(data),
              )
            actor.continue(state)
          }
        }
      },
    )
    |> grammy.port(3000)
    |> grammy.start

  let sender = process.select_forever(selector)

  process.send(sender, Broadcast(<<"Hello, world!":utf8>>))

  process.sleep_forever()
}
