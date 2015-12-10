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
%%% @doc Stomp Heartbeat.
%%%
%%% @author Feng Lee <feng@emqtt.io>
%%%-----------------------------------------------------------------------------
-module(emqttd_stomp_heartbeat).

-include("emqttd_stomp.hrl").

-export([start_link/2, stop/1]).

%% callback
-export([init/1, loop/3]).

-define(MAX_REPEATS, 1).

-record(heartbeater, {name, cycle, tref, val, statfun, action, repeat = 0}).

start_link({0, _, _}, {0, _, _}) ->
    {ok, none};

start_link(Incoming, Outgoing) ->
    Params = [self(), Incoming, Outgoing],
    {ok, spawn_link(?MODULE, init, [Params])}.

stop(Pid) ->
    Pid ! stop.

init([Parent, Incoming, Outgoing]) ->
    loop(Parent, heartbeater(incomming, Incoming), heartbeater(outgoing,  Outgoing)).

heartbeater(_, {0, _, _}) ->
    undefined;

heartbeater(InOut, {Cycle, StatFun, ActionFun}) ->
    {ok, Val} = StatFun(),
    #heartbeater{name = InOut, cycle = Cycle,
                 tref = timer(InOut, Cycle),
                 val = Val, statfun = StatFun,
                 action = ActionFun}.

loop(Parent, Incomming, Outgoing) ->
    receive
        {heartbeat, incomming} ->
            #heartbeater{val = LastVal, statfun = StatFun,
                         action = Action, repeat = Repeat} = Incomming,
            case StatFun() of
                {ok, Val} ->
                    if Val =/= LastVal ->
                           hibernate([Parent, resume(Incomming, Val), Outgoing]);
                       Repeat < ?MAX_REPEATS ->
                           hibernate([Parent, resume(Incomming, Val, Repeat+1), Outgoing]);
                       true ->
                           Action()
                    end;
                {error, Error} -> %% einval
                    exit({shutdown, Error})
            end;
        {heartbeat, outgoing}  ->
            #heartbeater{val = LastVal, statfun = StatFun, action = Action} = Outgoing,
            case StatFun() of
                {ok, Val} ->
                    if Val =:= LastVal ->
                           Action(), {ok, NewVal} = StatFun(),
                           hibernate([Parent, Incomming, resume(Outgoing, NewVal)]);
                       true ->
                           hibernate([Parent, Incomming, resume(Outgoing, Val)])
                    end;
                {error, Error} -> %% einval
                    exit({shutdown, Error})
            end;
        stop ->
            ok;
        _Other ->
            loop(Parent, Incomming, Outgoing)
    end.

resume(Hb, NewVal) ->
    resume(Hb, NewVal, 0).
resume(Hb = #heartbeater{name = InOut, cycle = Cycle}, NewVal, Repeat) ->
    Hb#heartbeater{tref = timer(InOut, Cycle), val = NewVal, repeat = Repeat}.

timer(InOut, Cycle) ->
    erlang:send_after(Cycle, self(), {heartbeat, InOut}).

hibernate(Args) ->
    erlang:hibernate(?MODULE, loop, Args).
