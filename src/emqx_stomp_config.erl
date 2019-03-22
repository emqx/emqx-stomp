%% Copyright (c) 2013-2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_stomp_config).

-export([ register/0
        , unregister/0
        ]).

-define(APP, emqx_stomp).

register() ->
    clique_config:load_schema([code:priv_dir(?APP)], ?APP),
    register_formatter(),
    register_config().

unregister() ->
    unregister_formatter(),
    unregister_config(),
    clique_config:unload_schema(?APP).

%%--------------------------------------------------------------------
%% Get ENV Register formatter
%%--------------------------------------------------------------------

register_formatter() ->
    Ignore = ["stomp.allow_anonymous"],
    [clique:register_formatter(cuttlefish_variable:tokenize(Key),
     fun formatter_callback/2) || Key <- keys() -- Ignore].

formatter_callback([_, "listener", Key], {_Port, Params}) ->
    proplists:get_value(list_to_atom(Key), Params);
formatter_callback([_, "default_user", Key], Params) ->
    proplists:get_value(list_to_atom(Key), Params);
formatter_callback([_, "frame", Key], Params) ->
    proplists:get_value(list_to_atom(Key), Params).

%%--------------------------------------------------------------------
%% UnRegister formatter
%%--------------------------------------------------------------------

unregister_formatter() ->
    [clique:unregister_formatter(cuttlefish_variable:tokenize(Key)) || Key <- keys()].

%%--------------------------------------------------------------------
%% Set ENV Register Config
%%--------------------------------------------------------------------

register_config() ->
    Keys = keys(),
    [clique:register_config(Key , fun config_callback/2) || Key <- Keys],
    clique:register_config_whitelist(Keys, ?APP).

config_callback([_, Key], Value) ->
    application:set_env(?APP, list_to_atom(Key), Value),
    " successfully\n";
config_callback([_, "listener", Key0], Value) ->
    {ok, {Port, Env}} = application:get_env(?APP, listener),
    Key = list_to_atom(Key0),
    application:set_env(?APP, listener, {Port, lists:keyreplace(Key, 1, Env, {Key, Value})}),
    " successfully\n";
config_callback([_, "default_user", Key0], Value) ->
    {ok, Env} = application:get_env(?APP, default_user),
    Key = list_to_atom(Key0),
    application:set_env(?APP, default_user, lists:keyreplace(Key, 1, Env, {Key, Value})),
    " successfully\n";
config_callback([_, "frame", Key0], Value) ->
    {ok, Env} = application:get_env(?APP, frame),
    Key = list_to_atom(Key0),
    application:set_env(?APP, frame, lists:keyreplace(Key, 1, Env, {Key, Value})),
    " successfully\n".

%%--------------------------------------------------------------------
%% UnRegister config
%%--------------------------------------------------------------------

unregister_config() ->
    Keys = keys(),
    [clique:unregister_config(Key) || Key <- Keys],
    clique:unregister_config_whitelist(Keys, ?APP).

%%--------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------

keys() ->
    ["stomp.default_user.login",
     "stomp.default_user.passcode",
     "stomp.allow_anonymous",
     "stomp.frame.max_headers",
     "stomp.frame.max_header_length",
     "stomp.frame.max_body_length",
     "stomp.listener.acceptors",
     "stomp.listener.max_clients"].

