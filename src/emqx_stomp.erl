%%%===================================================================
%%% Copyright (c) 2013-2018 EMQ Inc. All rights reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%===================================================================

-module(emqx_stomp).

-export([start_listener/0, stop_listener/0]).

-define(APP, ?MODULE).

-define(SOCKOPTS, [binary, {packet, raw}, {reuseaddr, true}, {nodelay, true}]).

start_listener() ->
    {ok, {Port, Opts}} = application:get_env(?APP, listener),
    {ok, Env} = application:get_env(?APP, frame),
    MFArgs = {emqx_stomp_connection, start_link, [Env]},
    esockd:open(stomp, Port, merge_sockopts(Opts), MFArgs).

merge_sockopts(Opts) ->
    SockOpts = emqx_misc:merge_opts(
                 ?SOCK_OPTS, proplists:get_value(sockopts, Opts, [])),
    emqx_misc:merge_opts(Opts, [{sockopts, SockOpts}]).

stop_listener() ->
    {ok, {Port, _Opts}} = application:get_env(?APP, listener),
    esockd:close({stomp, Port}).

