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
%%% @doc Stomp Transaction
%%%
%%% @author Feng Lee <feng@emqtt.io>
%%%-----------------------------------------------------------------------------
-module(emqttd_stomp_transaction).

-include("emqttd_stomp.hrl").

-export([start/2, add/2, commit/2, abort/1, timeout/1]).

-record(transaction, {id, actions, tref}).

-define(TIMEOUT, 60000).

start(Id, TimeoutMsg) ->
    case get({transaction, Id}) of
        undefined    -> 
            TRef = erlang:send_after(?TIMEOUT, self(), TimeoutMsg),
            Transaction = #transaction{id = Id, actions = [], tref = TRef},
            put({transaction, Id}, Transaction),
            {ok, Transaction};
        _Transaction ->
            {error, already_started}
    end.

add(Id, Action) ->
    Fun = fun(Transaction = #transaction{actions = Actions}) ->
            Transaction1 = Transaction#transaction{actions = [Action | Actions]},
            put({transaction, Id}, Transaction1),
            {ok, Transaction1}
          end,
    with_transaction(Id, Fun).

commit(Id, InitState) ->
    Fun = fun(Transaction = #transaction{actions = Actions}) ->
            done(Transaction),
            {ok, lists:foldr(fun(Action, State) -> Action(State) end,
                             InitState, Actions)}
          end,
    with_transaction(Id, Fun).

abort(Id) ->
    with_transaction(Id, fun done/1).

timeout(Id) ->
    erase({transaction, Id}).

done(#transaction{id = Id, tref = TRef}) ->
    erase({transaction, Id}),
    catch erlang:cancel_timer(TRef),
    ok.

with_transaction(Id, Fun) ->
    case get({transaction, Id}) of
        undefined   -> {error, not_found};
        Transaction -> Fun(Transaction)
    end.

