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

-import(proplists, [get_value/2, get_value/3]).

%% API
-export([init/3, info/1]).

-export([received/2, send/2]).

-export([shutdown/2]).

-record(proto_state, {peername,
                      sendfun,
                      connected = false,
                      proto_ver,
                      proto_name,
                      heart_beats,
                      login,
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

received(#stomp_frame{command = <<"CONNECT">>, headers = Headers}, State = #proto_state{connected = false}) ->
    case negotiate_version(header(<<"accept-version">>, Headers)) of
        {ok, Version} ->
            case check_login(Login = header(<<"login">>, Headers), header(<<"passcode">>, Headers)) of
                true ->
                    Heartbeats = header(<<"heart-beat">>, Headers, <<"0,0">>),
                    emqttd_stomp_heartbeat:start(Heartbeats),
                    NewState = State#proto_state{connected = true, proto_ver = Version,
                                                 heart_beats = Heartbeats, login = Login},
                    send(connected_frame([{<<"version">>, Version},
                                          {<<"heart-beat">>, reverse_heartbeats(Heartbeats)}]), NewState);
                false ->
                    send(error_frame(<<"Login or passcode error!">>), State)
             end;
        {error, Msg} ->
            send(error_frame([{<<"version">>, <<"1.0,1.1,1.2">>},
                              {<<"content-type">>, <<"text/plain">>}], Msg), State)
    end;

received(#stomp_frame{command = <<"CONNECT">>}, State = #proto_state{connected = true}) ->
    {error, unexpected_connect, State};

received(#stomp_frame{command = <<"SEND">>, headers = Headers, body = Body}, State) ->
    Topic = header(<<"destination">>, Headers),
    Action = fun(State0) ->
                 emqttd_pubsub:publish(
                     emqttd_message:make(
                         stomp, Topic, iolist_to_binary(Body))),
                 State0
             end,
    case header(<<"transaction">>, Headers) of
        undefined     -> {ok, Action(State)};
        TransactionId -> add_action(TransactionId, Action, State)
    end;

received(#stomp_frame{command = <<"SUBSCRIBE">>, headers = Headers},
            State = #proto_state{subscriptions = Subscriptions}) ->
    Id    = header(<<"id">>, Headers),
    Topic = header(<<"destination">>, Headers),
    Ack   = header(<<"ack">>, Headers, <<"auto">>),
    case lists:keyfind(Id, 1, Subscriptions) of
        {Id, Topic, Ack} ->
            {ok, State};
        false ->
            emqttd_pubsub:subscribe(Topic, qos1),
            {ok, State#proto_state{subscriptions = [{Id, Topic, Ack}|Subscriptions]}}
    end;

received(#stomp_frame{command = <<"UNSUBSCRIBE">>, headers = Headers},
            State = #proto_state{subscriptions = Subscriptions}) ->
    Id = header(<<"id">>, Headers),
    case lists:keyfind(Id, 1, Subscriptions) of
        {Id, Topic, _Ack} ->
            emqttd_pubsub:unsubscribe(Topic),
            {ok, State#proto_state{subscriptions = lists:keydelete(Id, 1, Subscriptions)}};
        false ->
            {ok, State}
    end;

%% ACK
%% id:12345
%% transaction:tx1
%%
%% ^@
received(#stomp_frame{command = <<"ACK">>, headers = Headers}, State) ->
    Id = header(<<"id">>, Headers),
    Action = fun(State0) -> ack(Id, State0) end,
    case header(<<"transaction">>, Headers) of
        undefined     -> {ok, Action(State)};
        TransactionId -> add_action(TransactionId, Action, State)
    end;

%% NACK
%% id:12345
%% transaction:tx1
%%
%% ^@
received(#stomp_frame{command = <<"NACK">>, headers = Headers}, State) ->
    Id = header(<<"id">>, Headers),
    Action = fun(State0) -> nack(Id, State0) end,
    case header(<<"transaction">>, Headers) of
        undefined     -> {ok, Action(State)};
        TransactionId -> add_action(TransactionId, Action, State)
    end;

%% BEGIN
%% transaction:tx1
%%
%% ^@
received(#stomp_frame{command = <<"BEGIN">>, headers = Headers}, State) ->
    Id        = header(<<"transaction">>, Headers),
    %% self() ! TimeoutMsg
    TimeoutMsg = {transaction, {timeout, Id}},
    case emqttd_stomp_transaction:start(Id, TimeoutMsg) of
        {ok, _Transaction}       ->
            {ok, State};
        {error, already_started} ->
            send(error_frame(["Transaction ", Id, " already started"]), State)
    end;

%% COMMIT
%% transaction:tx1
%%
%% ^@
received(#stomp_frame{command = <<"COMMIT">>, headers = Headers}, State) ->
    Id = header(<<"transaction">>, Headers),
    case emqttd_stomp_transaction:commit(Id, State) of
        {ok, NewState} ->
            {ok, NewState};
        {error, not_found} ->
            send(error_frame(["Transaction ", Id, " not found"]), State)
    end;

%% ABORT
%% transaction:tx1
%%
%% ^@
received(#stomp_frame{command = <<"ABORT">>, headers = Headers}, State) ->
    Id = header(<<"transaction">>, Headers),
    case emqttd_stomp_transaction:abort(Id) of
        ok ->
            emqttd_stomp_transaction:abort(Id), {ok, State};
        {error, not_found} ->
            send(error_frame(["Transaction ", Id, " not found"]), State)
    end;

received(#stomp_frame{command = <<"DISCONNECT">>, headers = Headers}, State) ->
    send(receipt_frame(header(<<"receipt">>, Headers)), State),
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
    lager:info("SEND Frame: ~s", [emqttd_stomp_frame:format(Frame)]),
    Data = emqttd_stomp_frame:serialize(Frame),
    lager:debug("SENT to ~s: ~p", [emqttd_net:format(Peername), Data]),
    SendFun(Data),
    {ok, State}.

negotiate_version(undefined) ->
    {ok, <<"1.0">>};
negotiate_version(Accepts) ->
     negotiate_version(?STOMP_VER,
                        lists:reverse(
                          lists:sort(
                            binary:split(Accepts, <<",">>, [global])))).

negotiate_version(Ver, []) ->
    {error, <<"Supported protocol versions < ", Ver/binary>>};
negotiate_version(Ver, [AcceptVer|_]) when Ver >= AcceptVer ->
    {ok, AcceptVer};
negotiate_version(Ver, [_|T]) ->
    negotiate_version(Ver, T).

check_login(undefined, _) ->
    application:get_env(emqttd_stomp, allow_anonymous, false);
check_login(Login, Passcode) ->
    {ok, DefaultUser} = application:get_env(emqttd_stomp, default_user),
    case {get_value(login, DefaultUser), get_value(passcode, DefaultUser)} of
        {Login, Passcode} -> true;
        {_,     _       } -> false
    end.

add_action(Id, Action, State) ->
    case emqttd_stomp_transaction:add(Id, Action) of
        {ok, _}           ->
            {ok, State};
        {error, not_found} ->
            send(error_frame(["Transaction ", Id, " not found"]), State)
    end.

ack(Id, State) -> State.

nack(Id, State) -> State.

header(Name, Headers) ->
    get_value(Name, Headers).
header(Name, Headers, Val) ->
    get_value(Name, Headers, Val).

connected_frame(Headers) ->
    emqttd_stomp_frame:make(<<"CONNECTED">>, Headers).

receipt_frame(Receipt) ->
    emqttd_stomp_frame:make(<<"RECEIPT">>, [{<<"receipt-id">>, Receipt}]).

error_frame(Msg) ->
    error_frame([{<<"content-type">>, <<"text/plain">>}], Msg). 
error_frame(Headers, Msg) ->
    emqttd_stomp_frame:make(<<"ERROR">>, Headers, Msg).

reverse_heartbeats(Heartbeats) ->
    CxCy = re:split(Heartbeats, <<",">>, [{return, list}]),
    list_to_binary(string:join(lists:reverse(CxCy), ",")).

shutdown(_Reason, _State) ->
    ok.

next_msgid() ->
    MsgId = case get(msgid) of
                undefined -> 1;
                I         -> I
            end,
    put(msgid, MsgId+1), MsgId.

