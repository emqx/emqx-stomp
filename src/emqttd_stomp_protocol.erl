
-module(emqttd_stomp_protocol).

-export([received/2]).

-record(proto_state, {}).

received(Frame, State) ->
    ok.

send(Frame, State) ->
    ok.
