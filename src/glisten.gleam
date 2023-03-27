import gleam/dynamic.{Dynamic}
import gleam/erlang/process
import gleam/result
import glisten/acceptor.{Pool, over_ssl}
import glisten/socket.{Closed, ListenSocket, SocketReason, Timeout}
import glisten/tcp
import glisten/ssl
import gleam/otp/actor
import glisten/socket/options.{AlpnPreferredProtocols, Certfile, Keyfile}

/// Reasons that `serve` might fail
pub type StartError {
  ListenerClosed
  ListenerTimeout
  AcceptorTimeout
  AcceptorFailed(process.ExitReason)
  AcceptorCrashed(Dynamic)
  SystemError(SocketReason)
}

/// Sets up a TCP listener with the given acceptor pool. The second argument
/// can be obtained from the `glisten/acceptor.{acceptor_pool}` function.
pub fn serve(
  port: Int,
  with_pool: fn(ListenSocket) -> Pool(data),
) -> Result(Nil, StartError) {
  use _ <- result.then(
    port
    |> tcp.listen([])
    |> result.map_error(fn(err) {
      case err {
        Closed -> ListenerClosed
        Timeout -> ListenerTimeout
        err -> SystemError(err)
      }
    })
    |> result.then(fn(socket) {
      socket
      |> with_pool
      |> acceptor.start_pool
      |> result.map_error(fn(err) {
        case err {
          actor.InitTimeout -> AcceptorTimeout
          actor.InitFailed(reason) -> AcceptorFailed(reason)
          actor.InitCrashed(reason) -> AcceptorCrashed(reason)
        }
      })
    }),
  )

  Ok(Nil)
}

external fn start_ssl() -> Result(Nil, Dynamic) =
  "ssl_ffi" "start_ssl"

/// Sets up a SSL listener with the given acceptor pool. The second argument
/// can be obtained from the `glisten/acceptor.{acceptor_pool}` function.
pub fn serve_ssl(
  port port: Int,
  certfile certfile: String,
  keyfile keyfile: String,
  with_pool with_pool: fn(ListenSocket) -> Pool(data),
) -> Result(Nil, StartError) {
  let assert Ok(_nil) = start_ssl()
  use _ <- result.then(
    port
    |> ssl.listen([
      Certfile(certfile),
      Keyfile(keyfile),
      AlpnPreferredProtocols(["h2", "http/1.1"]),
    ])
    |> result.map_error(fn(err) {
      case err {
        Closed -> ListenerClosed
        Timeout -> ListenerTimeout
        err -> SystemError(err)
      }
    })
    |> result.then(fn(socket) {
      socket
      |> over_ssl(with_pool)
      |> acceptor.start_pool
      |> result.map_error(fn(err) {
        case err {
          actor.InitTimeout -> AcceptorTimeout
          actor.InitFailed(reason) -> AcceptorFailed(reason)
          actor.InitCrashed(reason) -> AcceptorCrashed(reason)
        }
      })
    }),
  )

  Ok(Nil)
}
