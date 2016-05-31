%%--------------------------------------------------------------------
%% Copyright (c) 2015-2016 Feng Lee <feng@emqtt.io>.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc Stomp Protocol
-module(emqttd_stomp).

-export([start_listeners/0, stop_listeners/0]).

-define(APP, ?MODULE).

-define(SOCKOPTS, [binary,
                   {packet,    raw},
                   {reuseaddr, true},
                   {backlog,   128},
                   {nodelay,   true}]).

start_listeners() ->
    {ok, Listeners} = application:get_env(?APP, listeners),
    lists:foreach(fun start_listener/1, Listeners).

start_listener({Name, ListenOn, Opts}) ->
    {ok, Env} = application:get_env(?APP, frame),
    MFArgs = {emqttd_stomp_client, start_link, [Env]},
    esockd:open(Name, ListenOn, merge_sockopts(Opts), MFArgs).

merge_sockopts(Opts) ->
    SockOpts = emqttd_opts:merge(?SOCKOPTS, proplists:get_value(sockopts, Opts, [])),
    emqttd_opts:merge(Opts, [{sockopts, SockOpts}]).

stop_listeners() ->
    {ok, Listeners} = application:get_env(?APP, listeners),
    lists:foreach(fun stop_listener/1, Listeners).

stop_listener({Name, ListenOn, _Opts}) ->
    esockd:close({Name, ListenOn}).

