import gleam/bytes_builder.{type BytesBuilder}
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervisor
import gleam/result
import gleam/string
import logging

pub opaque type UdpServer {
  UdpServer(supervisor: Subject(supervisor.Message))
}

pub fn start(
  builder: Builder(user_state, user_message),
) -> Result(UdpServer, actor.StartError) {
  let ten_megabytes = 10 * 1024 * 1024

  let worker =
    supervisor.worker(fn(_arg) {
      actor.start_spec(
        actor.Spec(
          init: fn() {
            case
              udp_open(builder.port, [
                Binary,
                Active(Once),
                Sndbuf(ten_megabytes),
                Recbuf(ten_megabytes),
              ])
            {
              Error(reason) ->
                actor.Failed(
                  "Failed to open UDP socket: " <> string.inspect(reason),
                )
              Ok(socket) -> {
                let #(user_state, user_selector) = builder.on_init()
                let message_selector = udp_message_selector()
                let selector = case user_selector {
                  Some(user) -> {
                    user
                    |> process.map_selector(InternalUser)
                    |> process.merge_selector(message_selector)
                  }
                  None -> message_selector
                }
                actor.Ready(
                  State(socket: socket, user: user_state, clients: dict.new()),
                  selector,
                )
              }
            }
          },
          init_timeout: 500,
          loop: fn(message, state) {
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
                  actor.Continue(new_state, user_selector) -> {
                    state.socket
                    |> set_active
                    |> result.map(fn(_nil) {
                      let selector =
                        option.map(user_selector, fn(selector) {
                          selector
                          |> process.map_selector(InternalUser)
                          |> process.merge_selector(udp_message_selector())
                        })
                      actor.Continue(State(..state, user: new_state), selector)
                    })
                    |> result.map_error(fn(err) {
                      logging.log(
                        logging.Error,
                        "Failed to set UDP socket active: "
                          <> string.inspect(err),
                      )
                      actor.Stop(process.Abnormal(
                        "Failed to set UDP socket active",
                      ))
                    })
                    |> result.unwrap_both
                  }
                  actor.Stop(reason) -> {
                    actor.Stop(reason)
                  }
                }
              }
              InternalUser(user) -> {
                case builder.handler(User(user), conn, state.user) {
                  actor.Continue(new_state, None) -> {
                    actor.continue(State(..state, user: new_state))
                  }
                  actor.Continue(new_state, Some(new_user_selector)) -> {
                    actor.Continue(
                      State(..state, user: new_state),
                      Some(
                        new_user_selector
                        |> process.map_selector(InternalUser)
                        |> process.merge_selector(udp_message_selector()),
                      ),
                    )
                  }
                  actor.Stop(reason) -> actor.Stop(reason)
                }
              }
            }
          },
        ),
      )
    })

  supervisor.start(fn(children) { supervisor.add(children, worker) })
  |> result.map(UdpServer)
}

type InternalMessage(user_message) {
  InternalUser(user_message)
  UdpPacket(address: IpAddress, port: Int, data: BitArray)
  Unknown
}

fn udp_message_selector() -> Selector(InternalMessage(user_message)) {
  process.new_selector()
  |> process.selecting_record5(
    atom.create_from_string("udp"),
    fn(_socket, ip_address, port, message) {
      let ip =
        dynamic.tuple4(dynamic.int, dynamic.int, dynamic.int, dynamic.int)(
          ip_address,
        )
      let port = dynamic.int(port)
      let data = dynamic.bit_array(message)

      case ip, port, data {
        Ok(ip), Ok(port), Ok(data) -> {
          UdpPacket(ip, port, data)
        }
        _, _, _ -> Unknown
      }
    },
  )
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
    on_close: fn(user_state) -> Nil,
    port: Int,
    handler: Handler(user_state, user_message),
  )
}

pub fn new(
  init init: fn() -> #(user_state, Option(Selector(user_message))),
  handler handler: Handler(user_state, user_message),
) -> Builder(user_state, user_message) {
  Builder(
    on_init: init,
    on_close: fn(_state) { Nil },
    port: 4000,
    handler: handler,
  )
}

pub type Message(user_message) {
  User(message: user_message)
  Packet(ip_address: IpAddress, port: Int, data: BitArray)
}

pub type Handler(user_state, user_message) =
  fn(Message(user_message), Connection, user_state) ->
    actor.Next(user_message, user_state)

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
  data: BytesBuilder,
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
  packet: BytesBuilder,
) -> Result(Nil, Nil)

@external(erlang, "grammy_ffi", "set_active")
fn set_active(socket: Socket) -> Result(Nil, Nil)
