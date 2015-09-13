%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2015 eMQTT.IO, All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% Stomp protocol handler.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(emqttd_stomp_proto).

-author("Feng Lee <feng@emqtt.io>").

-include("emqttd_stomp.hrl").

-include_lib("emqttd/include/emqttd.hrl").

%% API
-export([init/3, info/1]).

-export([received/2, send/2]).

-record(proto_state, {peername,
                      sendfun,
                      connected = false,
                      proto_ver,
                      proto_name,
                      username,
                      subscriptions = []}).

-type proto_state() :: #proto_state{}.

%%------------------------------------------------------------------------------
%% @doc Init protocol
%% @end
%%------------------------------------------------------------------------------

init(Peername, SendFun, _Env) ->
	#proto_state{peername   = Peername,
                 sendfun    = SendFun}.

info(#proto_state{proto_ver = Ver}) ->
    [{proto_ver, Ver}].

-spec received(stomp_frame(), proto_state()) -> {ok, proto_state()}
                                              | {error, any(), proto_state()}
                                              | {stop, any(), proto_state()}.
received(Frame = #stomp_frame{command = <<"STOMP">>}, State) ->
    received(Frame#stomp_frame{command = <<"CONNECT">>}, State);

received(#stomp_frame{command = <<"CONNECT">>}, State = #proto_state{connected = false}) ->
    send(emqttd_stomp_frame:make(<<"CONNECTED">>), State#proto_state{connected = true});

received(#stomp_frame{command = <<"CONNECT">>}, State = #proto_state{connected = true}) ->
    {error, unexpected_connect, State};

received(#stomp_frame{command = <<"SEND">>, headers = Headers, body = Body}, State) ->
    Topic = proplists:get_value(<<"destination">>, Headers),
    Msg = emqttd_message:make(stomp, Topic, iolist_to_binary(Body)),
    emqttd_pubsub:publish(Msg),
    {ok, State};

received(#stomp_frame{command = <<"SUBSCRIBE">>, headers = Headers},
            State = #proto_state{subscriptions = Subscriptions}) ->
    Id    = proplists:get_value(<<"id">>, Headers),
    Topic = proplists:get_value(<<"destination">>, Headers),
    Ack   = proplists:get_value(<<"ack">>, Headers),
    case lists:keyfind(Id, 1, Subscriptions) of
        {Id, Topic, Ack} ->
            {ok, State};
        false ->
            emqttd_pubsub:subscribe(Topic, qos1),
            {ok, State#proto_state{subscriptions = [{Id, Topic, Ack}|Subscriptions]}}
    end;

received(#stomp_frame{command = <<"UNSUBSCRIBE">>, headers = Headers},
            State = #proto_state{subscriptions = Subscriptions}) ->
    Id = proplists:get_value(<<"id">>, Headers),
    case lists:keyfind(Id, 1, Subscriptions) of
        {Id, Topic, _Ack} ->
            emqttd_pubsub:unsubscribe(Topic),
            State#proto_state{subscriptions = lists:keydelete(Id, 1, Subscriptions)};
        false ->
            {ok, State}
    end;

received(#stomp_frame{command = <<"ACK">>, headers = Headers}, State) ->
    %% id:12345
    %% transaction:tx1
    {ok, State};

received(#stomp_frame{command = <<"NACK">>, headers = Headers}, State) ->
    %% id:12345
    %% transaction:tx1
    {ok, State};

received(#stomp_frame{command = <<"BEGIN">>, headers = Headers}, State) ->
    %% transaction:tx1
    {ok, State};

received(#stomp_frame{command = <<"COMMIT">>, headers = Headers}, State) ->
    %% transaction:tx1
    {ok, State};

received(#stomp_frame{command = <<"ABORT">>, headers = Headers}, State) ->
    %% transaction:tx1
    {ok, State};

received(#stomp_frame{command = <<"DISCONNECT">>, headers = Headers}, State) ->
    Receipt = proplists:get_value(<<"receipt">>, Headers),
    Frame = emqttd_stomp:make(<<"RECEIPT">>, [{<<"receipt-id">>, Receipt}]),
    send(Frame, State),
    {stop, normal, State}.

send(Msg = #mqtt_message{topic = Topic, payload = Payload},
     State = #proto_state{subscriptions = Subscriptions}) ->
    case lists:keyfind(Topic, 2, Subscriptions) of
        {Id, Topic, _Ack} ->
            Headers = [{<<"subscription">>, Id},
                       {<<"message-id">>, next_msgid()},
                       {<<"destination">>, Topic},
                       {<<"content-type">>, <<"text/plain">>}], 
            Frame = #stomp_frame{command = <<"MESSAGE">>,
                                 headers = Headers,
                                 body = Payload},
            send(Frame, State);
        false ->
            lager:error("Stomp dropped: ~p", [Msg])
    end;

send(Frame, State = #proto_state{peername = Peername, sendfun = SendFun}) ->
    Data = emqttd_stomp_frame:serialise(Frame),
    lager:debug("SENT to ~s: ~p", [emqttd_net:format(Peername), Data]),
    SendFun(Data),
    {ok, State}.

next_msgid() ->
    MsgId =
    case get(msgid) of
        undefined -> 1;
        I         -> I
    end,
    put(msgid, MsgId+1),
    MsgId.

