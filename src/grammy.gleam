import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging

pub opaque type Next(state, user_message) {
  Continue(state, Option(Selector(user_message)))
  NormalStop
  AbnormalStop(reason: String)
}

pub fn continue(state: state) -> Next(state, user_message) {
  Continue(state, None)
}

pub fn with_selector(
  next: Next(state, user_message),
  selector: Selector(user_message),
) -> Next(state, user_message) {
  case next {
    Continue(state, _) -> Continue(state, Some(selector))
    _ -> next
  }
}

pub fn stop() -> Next(state, user_message) {
  NormalStop
}

pub fn stop_abnormal(reason: String) -> Next(state, user_message) {
  AbnormalStop(reason)
}

pub fn start(
  builder: Builder(user_state, user_message),
) -> actor.StartResult(Subject(user_message)) {
  let ten_megabytes = 10 * 1024 * 1024

  actor.new_with_initialiser(500, fn(_subj) {
    let user_subj = process.new_subject()
    let res =
      udp_open(builder.port, [
        Binary,
        Active(Once),
        Sndbuf(ten_megabytes),
        Recbuf(ten_megabytes),
      ])
    case res {
      Error(reason) ->
        Error("Failed to open UDP socket: " <> string.inspect(reason))
      Ok(socket) -> {
        let #(user_state, user_selector) = builder.on_init()
        let default_selector =
          process.select(process.new_selector(), user_subj)
          |> process.map_selector(InternalUser)
        let message_selector = udp_message_selector()
        let selector = case user_selector {
          Some(user) -> {
            user
            |> process.map_selector(InternalUser)
            |> process.merge_selector(message_selector)
            |> process.merge_selector(default_selector)
          }
          None -> process.merge_selector(message_selector, default_selector)
        }
        State(socket: socket, user: user_state, clients: dict.new())
        |> actor.initialised
        |> actor.selecting(selector)
        |> actor.returning(user_subj)
        |> Ok
      }
    }
  })
  |> actor.on_message(fn(state, message) {
    let conn = Connection(socket: state.socket)
    case message {
      Unknown -> {
        logging.log(logging.Warning, "Discarding unknown message type")
        actor.continue(state)
      }
      UdpPacket(address, port, data) -> {
        let resp =
          builder.handler(Packet(address, port, data), conn, state.user)
        case resp {
          Continue(new_state, user_selector) -> {
            state.socket
            |> set_active
            |> result.map(fn(_nil) {
              let selector =
                option.map(user_selector, fn(selector) {
                  selector
                  |> process.map_selector(InternalUser)
                  |> process.merge_selector(udp_message_selector())
                })
              let next = actor.continue(State(..state, user: new_state))
              case selector {
                Some(selector) -> actor.with_selector(next, selector)
                _ -> next
              }
            })
            |> result.map_error(fn(err) {
              logging.log(
                logging.Error,
                "Failed to set UDP socket active: " <> string.inspect(err),
              )
              actor.stop_abnormal("Failed to set UDP socket active")
            })
            |> result.unwrap_both
          }
          NormalStop -> actor.stop()
          AbnormalStop(reason) -> actor.stop_abnormal(reason)
        }
      }
      InternalUser(user) -> {
        case builder.handler(User(user), conn, state.user) {
          Continue(new_state, None) -> {
            actor.continue(State(..state, user: new_state))
          }
          Continue(new_state, Some(new_user_selector)) -> {
            State(..state, user: new_state)
            |> actor.continue
            |> actor.with_selector(
              new_user_selector
              |> process.map_selector(InternalUser)
              |> process.merge_selector(udp_message_selector()),
            )
          }
          NormalStop -> actor.stop()
          AbnormalStop(reason) -> actor.stop_abnormal(reason)
        }
      }
    }
  })
  |> actor.start
}

type InternalMessage(user_message) {
  InternalUser(user_message)
  UdpPacket(address: IpAddress, port: Int, data: BitArray)
  Unknown
}

fn udp_message_selector() -> Selector(InternalMessage(user_message)) {
  process.new_selector()
  |> process.select_record(atom.create("udp"), 3, fn(dyn) {
    let decoder = {
      let ip = {
        use a <- decode.field(0, decode.int)
        use b <- decode.field(1, decode.int)
        use c <- decode.field(2, decode.int)
        use d <- decode.field(3, decode.int)
        decode.success(#(a, b, c, d))
      }
      use ip_address <- decode.field(1, ip)
      use port <- decode.field(2, decode.int)
      use data <- decode.field(3, decode.bit_array)
      decode.success(UdpPacket(ip_address, port, data))
    }
    let assert Ok(msg) = decode.run(dyn, decoder)
    msg
  })
}

@internal
pub opaque type State(user_state, user_message) {
  State(
    socket: Socket,
    user: user_state,
    clients: Dict(#(IpAddress, Int), Subject(Message(user_message))),
  )
}

pub type Builder(user_state, user_message) {
  Builder(
    on_init: fn() -> #(user_state, Option(Selector(user_message))),
    port: Int,
    handler: Handler(user_state, user_message),
  )
}

pub fn new(
  init init: fn() -> #(user_state, Option(Selector(user_message))),
  handler handler: Handler(user_state, user_message),
) -> Builder(user_state, user_message) {
  Builder(on_init: init, port: 4000, handler: handler)
}

pub fn port(
  builder: Builder(user_state, user_message),
  port: Int,
) -> Builder(user_state, user_message) {
  Builder(..builder, port: port)
}

pub type Message(user_message) {
  User(message: user_message)
  Packet(ip_address: IpAddress, port: Int, data: BitArray)
}

pub type Handler(user_state, user_message) =
  fn(Message(user_message), Connection, user_state) ->
    Next(user_state, user_message)

pub opaque type Connection {
  Connection(socket: Socket)
}

type ActiveType {
  Once
}

type SocketOption {
  Binary
  Active(ActiveType)
  Sndbuf(Int)
  Recbuf(Int)
}

pub type Socket

type IpAddress =
  #(Int, Int, Int, Int)

pub fn ip_address_to_string(ip: IpAddress) -> String {
  int.to_string(ip.0)
  <> "."
  <> int.to_string(ip.1)
  <> "."
  <> int.to_string(ip.2)
  <> "."
  <> int.to_string(ip.3)
}

pub fn send_to(
  connection: Connection,
  address: IpAddress,
  port: Int,
  data: BytesTree,
) -> Result(Nil, Nil) {
  udp_send(connection.socket, address, port, data)
}

@external(erlang, "gen_udp", "open")
fn udp_open(port: Int, opts: List(SocketOption)) -> Result(Socket, Nil)

@external(erlang, "grammy_ffi", "send")
pub fn udp_send(
  socket: Socket,
  host: IpAddress,
  port: Int,
  packet: BytesTree,
) -> Result(Nil, Nil)

@external(erlang, "grammy_ffi", "set_active")
fn set_active(socket: Socket) -> Result(Nil, Nil)
