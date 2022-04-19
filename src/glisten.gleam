import gleam/erlang
import gleam/http/request.{Request}
import gleam/http/response.{Response}
import glisten/http.{make_handler}
import glisten/tcp

pub fn handler(req: Request(BitString)) -> Response(BitString) {
  response.new(200)
  |> response.set_body(req.body)
}

// this should be something like...
//
//   tcp socket
//     - ON RECEIVE
//       - send to `consumer_sender`
//     - TO SEND?
//       - maybe a SetSender message (or something) that initializes the sender in
//         the state of the consumer???
//   consumer
//     - ON RECEIVE
//       - gets the message in its mailbox
//     - TO SEND?
//       - receive some message?  idk
//
//   let handler = fn(consumer_sender) {
//     // i think this may need the socket to send, separately from `sender` below
//     // since that's defined after?
//     let loop_fn = fn(msg, socket) {
//
//     }
//     let producer_sender = tcp.make_acceptor(loop_fn)
//
//   }

pub fn main() {
  assert Ok(socket) = tcp.do_listen_tcp(8000, [])
  try _ = tcp.start_acceptor_pool(socket, make_handler(handler), 10)

  Ok(erlang.sleep_forever())
}
