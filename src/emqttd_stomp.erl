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
%%% Stomp Protocol
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(emqttd_stomp).

-export([start_listeners/0, stop_listeners/0]).

-define(SOCKOPTS, [binary,
                   {packet,    raw},
                   {reuseaddr, true},
                   {backlog,   128},
                   {nodelay,   true}]).

start_listeners() ->
    {ok, Listeners} = application:get_env(emqttd_stomp, listeners),
    lists:foreach(fun start_listener/1, Listeners).

start_listener({Name, Port, Opts}) ->
    {ok, Env} = application:get_env(emqttd_stomp, frame),
    MFArgs = {emqttd_stomp_client, start_link, [Env]},
    esockd:open(Name, Port, merge_sockopts(Opts), MFArgs).

merge_sockopts(Opts) ->
    SockOpts = emqttd_opts:merge(?SOCKOPTS, proplists:get_value(sockopts, Opts, [])),
    emqttd_opts:merge(Opts, [{sockopts, SockOpts}]).

stop_listeners() ->
    {ok, Listeners} = application:get_env(emqttd_stomp, listeners),
    lists:foreach(fun stop_listener/1, Listeners).

stop_listener({Name, Port, _Opts}) ->
    esockd:close({Name, Port}).


