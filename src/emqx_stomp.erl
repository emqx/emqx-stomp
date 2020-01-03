%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_stomp).

-behaviour(application).
-behaviour(supervisor).

-emqx_plugin(protocol).

-export([ start/2
        , stop/1
        ]).

-export([ start_listener/0
        , stop_listener/0
        ]).

-export([init/1]).

-define(APP, ?MODULE).
-define(TCP_OPTS, [binary, {packet, raw}, {reuseaddr, true}, {nodelay, true}]).

%%--------------------------------------------------------------------
%% Application callbacks
%%--------------------------------------------------------------------

start(_StartType, _StartArgs) ->
    {ok, Sup} = supervisor:start_link({local, emqx_stomp_sup}, ?MODULE, []),
    start_listener(),
    {ok, Sup}.

stop(_State) ->
    stop_listener().

%%--------------------------------------------------------------------
%% Supervisor callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_all, 10, 100}, []}}.

%%--------------------------------------------------------------------
%% Start/Stop listeners
%%--------------------------------------------------------------------

start_listener() ->
    {ok, {Port, Opts}} = application:get_env(?APP, listener),
    {ok, Env} = application:get_env(?APP, frame),
    MFArgs = {emqx_stomp_connection, start_link, [Env]},
    esockd:open(stomp, Port, merge_opts(Opts), MFArgs).

merge_opts(Opts) ->
    TcpOpts = emqx_misc:merge_opts(
                 ?TCP_OPTS, proplists:get_value(tcp_options, Opts, [])),
    emqx_misc:merge_opts(Opts, [{tcp_options, TcpOpts}]).

stop_listener() ->
    {ok, {Port, _Opts}} = application:get_env(?APP, listener),
    esockd:close({stomp, Port}).

