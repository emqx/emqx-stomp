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

-module(emqttd_stomp_protocol).

-author("Feng Lee <feng@emqtt.io>").

-include("emqttd_stomp.hrl").

%% API
-export([init/3, info/1]).

-export([received/2, send/2]).

-record(proto_state, {peername,
                      sendfun,
                      connected = false,
                      proto_ver,
                      proto_name,
                      username,
                      session}).

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
received(Frame, State) ->
    ok;
received(Frame, State) ->
    ok;
received(Frame, State) ->
    ok;
received(Frame, State) ->
    ok;
received(Frame, State) ->
    ok;
received(Frame, State) ->
    ok;
received(Frame, State) ->
    ok;
received(Frame, State) ->
    ok.

send(Frame, State = #proto_state{peername = Peername, sendfun = SendFun}) ->
    Data = emqttd_stomp_frame:serialise(Frame),
    lager:debug("SENT to ~s: ~p", [emqttd_net:format(Peername), Data]),
    SendFun(Data),
    {ok, State}.

