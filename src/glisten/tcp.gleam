import gleam/dynamic.{Dynamic}
import gleam/erlang/atom.{Atom}
import gleam/erlang/charlist.{Charlist}
import gleam/iterator.{Iterator, Next}
import gleam/list
import gleam/map.{Map}
import gleam/option.{None, Option, Some}
import gleam/otp/actor
import gleam/otp/port.{Port}
import gleam/otp/process.{Abnormal, Pid, Receiver, Sender}
import gleam/otp/supervisor.{add, worker}
import gleam/pair
import gleam/result
import gleam

pub type TcpOption {
  Backlog(Int)
  Nodelay(Bool)
  Linger(#(Bool, Int))
  SendTimeout(Int)
  SendTimeoutClose(Bool)
  Reuseaddr(Bool)
  // Writing a wrapper for this would make my whole cool function below kind of
  // obsolete.  So I did this!  It's definitely better.
  Active(Dynamic)
  Binary
}

pub type SocketReason {
  Closed
  Timeout
}

pub opaque type ListenSocket {
  ListenSocket
}

pub opaque type Socket {
  Socket
}

external fn controlling_process(socket: Socket, pid: Pid) -> Result(Nil, Atom) =
  "glisten_ffi" "controlling_process"

pub external fn do_listen_tcp(
  port: Int,
  options: List(TcpOption),
) -> Result(ListenSocket, SocketReason) =
  "gen_tcp" "listen"

pub external fn accept_timeout(
  socket: ListenSocket,
  timeout: Int,
) -> Result(Socket, SocketReason) =
  "gen_tcp" "accept"

pub external fn accept(socket: ListenSocket) -> Result(Socket, SocketReason) =
  "gen_tcp" "accept"

external fn do_receive_timeout(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitString, SocketReason) =
  "gen_tcp" "recv"

pub external fn do_receive(
  socket: Socket,
  length: Int,
) -> Result(BitString, SocketReason) =
  "gen_tcp" "recv"

pub external fn send(
  socket: Socket,
  packet: Charlist,
) -> Result(Nil, SocketReason) =
  "glisten_ffi" "send"

pub external fn socket_info(socket: Socket) -> Map(a, b) =
  "socket" "info"

pub external fn close(socket: Socket) -> Atom =
  "gen_tcp" "close"

pub external fn do_shutdown(socket: Socket, write: Atom) -> Nil =
  "gen_tcp" "shutdown"

pub fn shutdown(socket: Socket) {
  assert Ok(write) = atom.from_string("write")
  do_shutdown(socket, write)
}

pub external fn set_opts(
  socket: Socket,
  opts: List(TcpOption),
) -> Result(Nil, Nil) =
  "glisten_ffi" "set_opts"

fn opts_to_map(options: List(TcpOption)) -> Map(atom.Atom, Dynamic) {
  let opt_decoder = dynamic.tuple2(dynamic.dynamic, dynamic.dynamic)

  options
  |> list.map(dynamic.from)
  |> list.filter_map(opt_decoder)
  |> list.map(pair.map_first(_, dynamic.unsafe_coerce))
  |> map.from_list
}

pub fn merge_with_default_options(options: List(TcpOption)) -> List(TcpOption) {
  let overrides = opts_to_map(options)

  [
    Backlog(1024),
    Nodelay(True),
    Linger(#(True, 30)),
    SendTimeout(30_000),
    SendTimeoutClose(True),
    Reuseaddr(gleam.True),
    Binary,
    Active(dynamic.from(False)),
  ]
  |> opts_to_map
  |> map.merge(overrides)
  |> map.to_list
  |> list.map(dynamic.from)
  |> list.map(dynamic.unsafe_coerce)
}

pub fn listen_tcp(
  port: Int,
  options: List(TcpOption),
) -> Result(ListenSocket, SocketReason) {
  options
  |> merge_with_default_options
  |> do_listen_tcp(port, _)
}

pub fn receive(socket: Socket) -> Result(BitString, SocketReason) {
  do_receive(socket, 0)
}

pub type Acceptor {
  AcceptConnection(ListenSocket)
}

pub type AcceptorError {
  AcceptError
  HandlerError
  ControlError
}

pub type HandlerMessage {
  ReceiveMessage(Charlist)
  SendMessage(Charlist)
  Tcp(socket: Port, data: Charlist)
  TcpClosed(Nil)
}

pub type Channel =
  #(Socket, Receiver(Acceptor))

pub type AcceptorState {
  AcceptorState(sender: Sender(Acceptor), socket: Option(Socket))
}


pub type LoopFn =
  fn(HandlerMessage, Socket) -> actor.Next(Socket)

pub type Handler =
  fn(Sender(HandlerMessage), Socket) -> Sender(HandlerMessage)

pub type TcpHandler {
  TcpHandler(channel: Option(Handler), loop_fn: LoopFn)
}

pub fn make_handler(channel: Handler, loop_fn: LoopFn) -> TcpHandler {
  TcpHandler(Some(channel), loop_fn)
}

pub fn make_receiver(loop_fn: LoopFn) -> TcpHandler {
  TcpHandler(None, loop_fn)
}

pub fn echo_loop(
  msg: HandlerMessage,
  state: AcceptorState,
) -> actor.Next(AcceptorState) {
  case msg, state {
    ReceiveMessage(data), AcceptorState(socket: Some(sock), ..) -> {
      let _ = send(sock, data)
      Nil
    }
    _, _ -> Nil
  }

  actor.Continue(state)
}

pub fn start_handler(
  socket: Socket,
  handler: TcpHandler,
) -> Result(Sender(HandlerMessage), actor.StartError) {
  try sender =
    actor.start_spec(actor.Spec(
      init: fn() {
        let socket_receiver =
          process.bare_message_receiver()
          |> process.map_receiver(fn(msg) {
            case dynamic.unsafe_coerce(msg) {
              Tcp(_sock, data) -> ReceiveMessage(data)
              message -> message
            }
          })
        actor.Ready(socket, Some(socket_receiver))
      },
      init_timeout: 1000,
      loop: fn(msg, sock) {
        case msg {
          SendMessage(data) -> {
            assert Ok(Nil) = send(socket, data)
            actor.Continue(sock)
          }
          _ -> {
            let resp = handler.loop_fn(msg, sock)
            case resp {
              actor.Continue(sock) as res -> {
                assert Ok(Nil) =
                  set_opts(
                    sock,
                    [Active(dynamic.from(atom.create_from_string("once")))],
                  )
                res
              }
              res -> res
            }
          }
        }
      },
    ))

  sender
  |> handler(socket)
  |> Ok
}

pub fn start_acceptor(
  socket: ListenSocket,
  handler: TcpHandler,
) -> Result(Sender(Acceptor), actor.StartError) {
  actor.start_spec(actor.Spec(
    init: fn() {
      let #(sender, actor_receiver) = process.new_channel()

      process.send(sender, AcceptConnection(socket))

      actor.Ready(AcceptorState(sender, None), Some(actor_receiver))
    },
    init_timeout: 30_000_000,
    loop: fn(msg, state) {
      let AcceptorState(sender, ..) = state
      case msg {
        AcceptConnection(listener) -> {
          let res = {
            try sock =
              accept(listener)
              |> result.replace_error(AcceptError)
            try start =
              start_handler(sock, handler)
              |> result.replace_error(HandlerError)
            sock
            |> controlling_process(process.pid(start))
            |> result.replace_error(ControlError)
          }
          case res {
            Error(reason) -> actor.Stop(Abnormal(dynamic.from(reason)))
            _val -> {
              actor.send(sender, AcceptConnection(listener))
              actor.Continue(state)
            }
          }
        }
      }
    },
  ))
}

pub fn receive_timeout(
  socket: Socket,
  timeout: Int,
) -> Result(BitString, SocketReason) {
  do_receive_timeout(socket, 0, timeout)
}

pub fn receiver_to_iterator(receiver: Receiver(a)) -> Iterator(a) {
  iterator.unfold(
    from: receiver,
    with: fn(recv) {
      recv
      |> process.receive_forever
      |> Next(accumulator: recv)
    },
  )
}

pub fn start_acceptor_pool(
  listener_socket: ListenSocket,
  handler: TcpHandler,
  pool_count: Int,
) -> Result(Nil, Nil) {
  let _ =
    supervisor.start_spec(supervisor.Spec(
      argument: Nil,
      max_frequency: 100,
      frequency_period: 1,
      init: fn(children) {
        iterator.range(from: 0, to: pool_count)
        |> iterator.fold(
          children,
          fn(children, _index) {
            add(
              children,
              worker(fn(_arg) {
                start_acceptor(listener_socket, handler)
              }),
            )
          },
        )
      },
    ))

  Ok(Nil)
}
