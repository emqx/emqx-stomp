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

-include("../../../include/emqttd_internal.hrl").

%% API Function Exports
-export([start_link/2, info/1]).

-behaviour(gen_server).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(stomp_client, {connection, connname, peername, peerhost, peerport,
                       await_recv, conn_state, rate_limit, parser_fun,
                       proto_state, proto_env, heartbeat}).

-define(INFO_KEYS, [peername, peerhost, peerport, await_recv, conn_state]).

-define(SOCK_STATS, [recv_oct, recv_cnt, send_oct, send_cnt]).

-define(LOG(Level, Format, Args, State),
            lager:Level("Stomp(~s): " ++ Format, [State#stomp_client.connname | Args])).

start_link(Connection, ProtoEnv) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [[Connection, ProtoEnv]])}.

info(CPid) ->
    gen_server:call(CPid, info, infinity).

init([Connection0, ProtoEnv]) ->
    process_flag(trap_exit, true),
    {ok, Connection} = Connection0:wait(),
    {PeerHost, PeerPort, PeerName} =
    case Connection:peername() of
        {ok, Peer = {Host, Port}} ->
            {Host, Port, Peer};
        {error, enotconn} ->
            Connection:fast_close(),
            exit(normal);
        {error, Reason} ->
            Connection:fast_close(),
            exit({shutdown, Reason})
    end,
    ConnName = esockd_net:format(PeerName),
    SendFun = fun(Data) ->
        try Connection:async_send(Data) of
            true -> ok
        catch
            error:Error -> exit({shutdown, Error})
        end
    end,
    ParserFun = emqttd_stomp_frame:parser(ProtoEnv),
    ProtoState = emqttd_stomp_proto:init(PeerName, SendFun, ProtoEnv),
    RateLimit = proplists:get_value(rate_limit, Connection:opts()),
    State = run_socket(#stomp_client{connection   = Connection,
                                     connname     = ConnName,
                                     peername     = PeerName,
                                     peerhost     = PeerHost,
                                     peerport     = PeerPort,
                                     await_recv   = false,
                                     conn_state   = running,
                                     rate_limit   = RateLimit,
                                     parser_fun   = ParserFun,
                                     proto_env    = ProtoEnv,
                                     proto_state  = ProtoState}),
    gen_server:enter_loop(?MODULE, [], State, 10000).

handle_call(info, _From, State = #stomp_client{connection  = Connection,
                                               proto_state = ProtoState}) ->

    ClientInfo = ?record_to_proplist(stomp_client, State, ?INFO_KEYS),
    ProtoInfo  = emqttd_stomp_proto:info(ProtoState),
    {ok, SockStats} = Connection:getstat(?SOCK_STATS),
    {noreply, lists:append([ClientInfo, [{proto_info, ProtoInfo},
                                         {sock_stats, SockStats}]]), State};

handle_call(Req, _From, State) ->
    ?LOG(critical, "Unexpected request: ~p", [Req], State),
    
    {reply, {error, unsupported_request}, State}.

handle_cast(Msg, State) ->
    ?LOG(critical, "Unexpected msg: ~p", [Msg], State),
    noreply(State).

handle_info(timeout, State) ->
    shutdown(idle_timeout, State);

handle_info({transaction, {timeout, Id}}, State) ->
    emqttd_stomp_transaction:timeout(Id),
    noreply(State);

handle_info({heartbeat, start, {Cx, Cy}}, State = #stomp_client{connection = Connection}) ->
    Self = self(),
    Incomming = {Cx, statfun(recv_oct, State), fun() -> Self ! {heartbeat, timeout} end},
    Outgoing  = {Cy, statfun(send_oct, State), fun() -> Connection:send(<<$\n>>) end},
    {ok, HbProc} = emqttd_stomp_heartbeat:start_link(Incomming, Outgoing),
    noreply(State#stomp_client{heartbeat = HbProc});

handle_info({heartbeat, timeout}, State) ->
    stop({shutdown, heartbeat_timeout}, State);

handle_info({'EXIT', HbProc, Error}, State = #stomp_client{heartbeat = HbProc}) ->
    stop(Error, State);

handle_info(activate_sock, State) ->
    noreply(run_socket(State#stomp_client{conn_state = running}));

handle_info({inet_async, _Sock, _Ref, {ok, Bytes}}, State) ->

    ?LOG(debug, "RECV <- ~p", [Bytes], State),
    received(Bytes, rate_limit(size(Bytes), State#stomp_client{await_recv = false}));

handle_info({inet_async, _Sock, _Ref, {error, Reason}}, State) ->
    shutdown(Reason, State);

handle_info({inet_reply, _Ref, ok}, State) ->
    noreply(State);

handle_info({inet_reply, _Sock, {error, Reason}}, State) ->
    shutdown(Reason, State);

handle_info({dispatch, Msg}, State = #stomp_client{proto_state = ProtoState}) ->
    {ok, ProtoState1} = emqttd_stomp_proto:send(Msg, ProtoState),
    noreply(State#stomp_client{proto_state = ProtoState1});

handle_info(Info, State) ->
    ?LOG(critical, "Unexpected info: ~p", [Info], State),
    {noreply, State}.

terminate(Reason, State = #stomp_client{connection  = Connection,
                                        proto_state = ProtoState}) ->
    ?LOG(info, "terminated for ~p", [Reason], State),
    Connection:fast_close(),
    case {ProtoState, Reason} of
        {undefined, _} ->
            ok;
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

received(Bytes, State = #stomp_client{parser_fun  = ParserFun,
                                      proto_state = ProtoState}) ->
    case catch ParserFun(Bytes) of
        {more, NewParser} ->
            noreply(run_socket(State#stomp_client{parser_fun = NewParser}));
        {ok, Frame, Rest} ->
            ?LOG(info, "RECV Frame: ~s", [emqttd_stomp_frame:format(Frame)], State),
            case emqttd_stomp_proto:received(Frame, ProtoState) of
                {ok, ProtoState1}           ->
                    received(Rest, reset_parser(State#stomp_client{proto_state = ProtoState1}));
                {error, Error, ProtoState1} ->
                    shutdown(Error, State#stomp_client{proto_state = ProtoState1});
                {stop, Reason, ProtoState1} ->
                    stop(Reason, State#stomp_client{proto_state = ProtoState1})
            end;
        {error, Error} ->
            ?LOG(error, "Framing error - ~s", [Error], State),
            shutdown(frame_error, State);
        {'EXIT', Reason} ->
            ?LOG(error, "Parser failed for ~p", [Reason], State),
            ?LOG(error, "Error data: ~p", [Bytes], State),
            shutdown(parser_error, State)
    end.

reset_parser(State = #stomp_client{proto_env = ProtoEnv}) ->
    State#stomp_client{parser_fun = emqttd_stomp_frame:parser(ProtoEnv)}.

rate_limit(_Size, State = #stomp_client{rate_limit = undefined}) ->
    run_socket(State);
rate_limit(Size, State = #stomp_client{rate_limit = Limiter}) ->
    case esockd_ratelimit:check(Limiter, Size) of
        {0, Limiter1} ->
            run_socket(State#stomp_client{conn_state = running,
                                          rate_limit = Limiter1});
        {Pause, Limiter1} ->
            ?LOG(error, "Rate limiter pause for ~p", [Size, Pause], State),
            erlang:send_after(Pause, self(), activate_sock),
            State#stomp_client{conn_state = blocked, rate_limit = Limiter1}    
    end.

run_socket(State = #stomp_client{conn_state = blocked}) ->
    State;
run_socket(State = #stomp_client{await_recv = true}) ->
    State;
run_socket(State = #stomp_client{connection = Connection}) ->
    Connection:async_recv(0, infinity),
    State#stomp_client{await_recv = true}.

statfun(Stat, #stomp_client{connection = Connection}) ->
    fun() ->
        case Connection:getstat([Stat]) of
            {ok, [{Stat, Val}]} -> {ok, Val};
            {error, Error}      -> {error, Error}
        end
    end.

noreply(State) ->
    {noreply, State, hibernate}.

stop(Reason, State) ->
    {stop, Reason, State}.

shutdown(Reason, State) ->
    stop({shutdown, Reason}, State).

