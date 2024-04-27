-module(grammy_ffi).

-export([send/4, set_active/1]).

send(Socket, Host, Port, Packet) ->
  case gen_udp:send(Socket, Host, Port, Packet) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

set_active(Socket) ->
  case inet:setopts(Socket, [{active, once}]) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.
