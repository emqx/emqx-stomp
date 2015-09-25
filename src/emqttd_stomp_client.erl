%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2015 eMQTT.IO, All Rights Reserved.
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
%%% Stomp client connection
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(emqttd_stomp_client).

-author("Feng Lee <feng@emqtt.io>").

-include("emqttd_stomp.hrl").

%% API Function Exports
-export([start_link/2, info/1]).

-behaviour(gen_server).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(state, {transport,
                socket,
                peername,
                conn_name,
                await_recv,
                conn_state,
                conserve,
                parser,
                proto_state,
                proto_env,
                heartbeat}).

start_link(SockArgs, ProtoEnv) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [[SockArgs, ProtoEnv]])}.

info(CPid) ->
    gen_server:call(CPid, info, infinity).

init([SockArgs = {Transport, Sock, _SockFun}, ProtoEnv]) ->
    process_flag(trap_exit, true),
    % Transform if ssl.
    {ok, NewSock} = esockd_connection:accept(SockArgs),
    {ok, Peername} = emqttd_net:peername(Sock),
    {ok, ConnStr} = emqttd_net:connection_string(Sock, inbound),
    lager:info("Connect from ~s", [ConnStr]),
    SendFun = fun(Data) -> Transport:send(NewSock, Data) end,
    ProtoState = emqttd_stomp_proto:init(Peername, SendFun, ProtoEnv),
    State = control_throttle(#state{transport    = Transport,
                                    socket       = NewSock,
                                    peername     = Peername,
                                    conn_name    = ConnStr,
                                    await_recv   = false,
                                    conn_state   = running,
                                    conserve     = false,
                                    proto_env    = ProtoEnv,
                                    parser       = emqttd_stomp_frame:parser(ProtoEnv),
                                    proto_state  = ProtoState}),
    gen_server:enter_loop(?MODULE, [], State, 10000).

handle_call(info, _From, State = #state{conn_name = ConnName,
                                        proto_state = ProtoState}) ->
    Info = [{conn_name, ConnName} | emqttd_stomp_proto:info(ProtoState)],
    {reply, Info, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(Msg, State = #state{peername = Peername}) ->
    lager:critical("Stomp(~s): unexpected msg - ~p",[emqttd_net:format(Peername), Msg]),
    noreply(State).

handle_info(timeout, State) ->
    stop({shutdown, timeout}, State);

handle_info({transaction, {timeout, Id}}, State) ->
    emqttd_stomp_transaction:timeout(Id),
    noreply(State);

handle_info({heartbeat, start, {Cx, Cy}}, State = #state{transport = Transport, socket = Socket}) ->
    Self = self(),
    Incomming = {Cx, statfun(recv_oct, State), fun() -> Self ! {heartbeat, timeout} end},
    Outgoing  = {Cy, statfun(send_oct, State), fun() -> Transport:send(Socket, <<$\n>>) end},
    {ok, HbProc} = emqttd_stomp_heartbeat:start_link(Incomming, Outgoing),
    noreply(State#state{heartbeat = HbProc});

handle_info({heartbeat, timeout}, State) ->
    stop({shutdown, heartbeat_timeout}, State);

handle_info({'EXIT', HbProc, Error}, State = #state{heartbeat = HbProc}) ->
    stop(Error, State);

handle_info({inet_reply, _Ref, ok}, State) ->
    noreply(State);

handle_info({inet_async, Sock, _Ref, {ok, Bytes}}, State = #state{peername = Peername, socket = Sock}) ->
    lager:debug("RECV from ~s: ~p", [emqttd_net:format(Peername), Bytes]),
    received(Bytes, control_throttle(State #state{await_recv = false}));

handle_info({inet_async, _Sock, _Ref, {error, Reason}}, State) ->
    network_error(Reason, State);

handle_info({inet_reply, _Sock, {error, Reason}}, State = #state{peername = Peername}) ->
    lager:critical("Client ~s: unexpected inet_reply '~p'", [emqttd_net:format(Peername), Reason]),
    {noreply, State};

handle_info({dispatch, Msg}, State = #state{proto_state = ProtoState}) ->
    {ok, ProtoState1} = emqttd_stomp_proto:send(Msg, ProtoState),
    {noreply, State#state{proto_state = ProtoState1}};

handle_info(Info, State = #state{peername = Peername}) ->
    lager:critical("Stomp(~s): unexpected info ~p",[emqttd_net:format(Peername), Info]),
    {noreply, State}.

terminate(Reason, #state{peername = Peername, proto_state = ProtoState}) ->
    lager:info("Stomp(~s) terminated, reason: ~p", [emqttd_net:format(Peername), Reason]),
    case {ProtoState, Reason} of
        {undefined, _} -> ok;
        {_, {shutdown, Error}} -> 
            emqttd_stomp_proto:shutdown(Error, ProtoState);
        {_,  Reason} ->
            emqttd_stomp_proto:shutdown(Reason, ProtoState)
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% receive and parse tcp data 
%%------------------------------------------------------------------------------

received(<<>>, State) ->
    noreply(State);

received(Bytes, State = #state{conn_name   = ConnStr,
                               parser      = Parser,
                               proto_state = ProtoState}) ->
    case Parser(Bytes) of
        {more, NewParser} ->
            noreply(control_throttle(State#state{parser = NewParser}));
        {ok, Frame, Rest} ->
            lager:info("RECV Frame: ~s", [emqttd_stomp_frame:format(Frame)]),
            case emqttd_stomp_proto:received(Frame, ProtoState) of
                {ok, ProtoState1}           ->
                    received(Rest, reset_parser(State#state{proto_state = ProtoState1}));
                {error, Error, ProtoState1} ->
                    stop({shutdown, Error}, State#state{proto_state = ProtoState1});
                {stop, Reason, ProtoState1} ->
                    stop(Reason, State#state{proto_state = ProtoState1})
            end;
        {error, Error} ->
            lager:error("Stomp(~s): framing error: ~s", [ConnStr, Error]),
            stop({shutdown, frame_error}, State)
    end.

reset_parser(State = #state{proto_env = ProtoEnv}) ->
    State#state{parser = emqttd_stomp_frame:parser(ProtoEnv)}.

noreply(State) ->
    {noreply, State, hibernate}.

stop(Reason, State) ->
    {stop, Reason, State}.

network_error(Reason, State = #state{peername = Peername}) ->
    lager:warning("Stomp(~s): Network error '~p'", [emqttd_net:format(Peername), Reason]),
    stop({shutdown, Reason}, State).

control_throttle(State = #state{conn_state = Flow,
                                conserve   = Conserve}) ->
    case {Flow, Conserve} of
        {running,   true} -> State #state{conn_state = blocked};
        {blocked,  false} -> run_socket(State #state{conn_state = running});
        {_,            _} -> run_socket(State)
    end.

run_socket(State = #state{conn_state = blocked}) ->
    State;
run_socket(State = #state{await_recv = true}) ->
    State;
run_socket(State = #state{transport = Transport, socket = Sock}) ->
    Transport:async_recv(Sock, 0, infinity),
    State#state{await_recv = true}.

statfun(Stat, #state{transport = Transport, socket = Socket}) ->
    fun() ->
        case Transport:getstat(Socket, [Stat]) of
            {ok, [{Stat, Val}]} -> {ok, Val};
            {error, Error}      -> {error, Error}
        end
    end.


