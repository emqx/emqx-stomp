
-module(emqx_stomp_SUITE).

-include("emqx_stomp.hrl").

-compile(export_all).
-compile(nowarn_export_all).

-define(HEARTBEAT, <<$\n>>).

all() -> [t_connect, 
          t_heartbeat, 
          t_subscribe, 
          t_transaction, 
          t_receipt_in_error, 
          t_ack].

init_per_suite(Config) ->
    [run_setup_steps(App) || App <- [emqx, emqx_stomp]],
    Config.

end_per_suite(_Config) ->
    emqx:shutdown().

t_connect(_) ->
    %% Connect should be succeed
    with_connection(fun(Sock) ->
                        gen_tcp:send(Sock, serialize(<<"CONNECT">>, 
                                                     [{<<"accept-version">>, ?STOMP_VER},
                                                      {<<"host">>, <<"127.0.0.1:61613">>},
                                                      {<<"login">>, <<"guest">>},
                                                      {<<"passcode">>, <<"guest">>},
                                                      {<<"heart-beat">>, <<"1000,2000">>}])),                                                        
                        {ok, Data} = gen_tcp:recv(Sock, 0),
                        {ok, Frame = #stomp_frame{command = <<"CONNECTED">>, 
                                                  headers = _, 
                                                  body    = _}, _} = parse(Data),
                        <<"2000,1000">> = proplists:get_value(<<"heart-beat">>, Frame#stomp_frame.headers),

                        gen_tcp:send(Sock, serialize(<<"DISCONNECT">>, 
                                                     [{<<"receipt">>, <<"12345">>}])),
                        
                        {ok, Data1} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"RECEIPT">>, 
                                          headers = [{<<"receipt-id">>, <<"12345">>}], 
                                          body    = _}, _} = parse(Data1)
                    end),

    %% Connect will be failed, because of bad login or passcode
    with_connection(fun(Sock) ->
                        gen_tcp:send(Sock, serialize(<<"CONNECT">>, 
                                                     [{<<"accept-version">>, ?STOMP_VER},
                                                      {<<"host">>, <<"127.0.0.1:61613">>},
                                                      {<<"login">>, <<"admin">>},
                                                      {<<"passcode">>, <<"admin">>},
                                                      {<<"heart-beat">>, <<"1000,2000">>}])),                                                        
                        {ok, Data} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"ERROR">>, 
                                          headers = _, 
                                          body    = <<"Login or passcode error!">>}, _} = parse(Data)
                    end),

    %% Connect will be failed, because of bad version
    with_connection(fun(Sock) ->
                        gen_tcp:send(Sock, serialize(<<"CONNECT">>, 
                                                     [{<<"accept-version">>, <<"2.0,2.1">>},
                                                      {<<"host">>, <<"127.0.0.1:61613">>},
                                                      {<<"login">>, <<"guest">>},
                                                      {<<"passcode">>, <<"guest">>},
                                                      {<<"heart-beat">>, <<"1000,2000">>}])),                                                        
                        {ok, Data} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"ERROR">>, 
                                          headers = _, 
                                          body    = <<"Supported protocol versions < 1.2">>}, _} = parse(Data)
                    end).

t_heartbeat(_) ->
    %% Test heart beat
    with_connection(fun(Sock) ->
                        gen_tcp:send(Sock, serialize(<<"CONNECT">>, 
                                                    [{<<"accept-version">>, ?STOMP_VER},
                                                     {<<"host">>, <<"127.0.0.1:61613">>},
                                                     {<<"login">>, <<"guest">>},
                                                     {<<"passcode">>, <<"guest">>},
                                                     {<<"heart-beat">>, <<"500,800">>}])),                                                        
                        {ok, Data} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"CONNECTED">>, 
                                          headers = _, 
                                          body    = _}, _} = parse(Data),
                        
                        {ok, ?HEARTBEAT} = gen_tcp:recv(Sock, 0),
                        %% Server will close the connection because never receive the heart beat from client
                        {error, closed} = gen_tcp:recv(Sock, 0)
                    end).

t_subscribe(_) ->
    with_connection(fun(Sock) ->
                        gen_tcp:send(Sock, serialize(<<"CONNECT">>, 
                                                    [{<<"accept-version">>, ?STOMP_VER},
                                                     {<<"host">>, <<"127.0.0.1:61613">>},
                                                     {<<"login">>, <<"guest">>},
                                                     {<<"passcode">>, <<"guest">>},
                                                     {<<"heart-beat">>, <<"0,0">>}])),                                                        
                        {ok, Data} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"CONNECTED">>, 
                                          headers = _, 
                                          body    = _}, _} = parse(Data),
                        
                        %% Subscribe
                        gen_tcp:send(Sock, serialize(<<"SUBSCRIBE">>, 
                                                    [{<<"id">>, 0},
                                                     {<<"destination">>, <<"/queue/foo">>},
                                                     {<<"ack">>, <<"auto">>}])),

                        %% 'user-defined' header will be retain
                        gen_tcp:send(Sock, serialize(<<"SEND">>, 
                                                    [{<<"destination">>, <<"/queue/foo">>},
                                                     {<<"user-defined">>, <<"emq">>}],
                                                    <<"hello">>)),

                        {ok, Data1} = gen_tcp:recv(Sock, 0),
                        {ok, Frame = #stomp_frame{command = <<"MESSAGE">>, 
                                                  headers = _, 
                                                  body    = <<"hello">>}, _} = parse(Data1),
                        lists:foreach(fun({Key, Val}) ->
                                          Val = proplists:get_value(Key, Frame#stomp_frame.headers)
                                      end, [{<<"destination">>,  <<"/queue/foo">>}, 
                                            {<<"subscription">>, <<"0">>},
                                            {<<"user-defined">>, <<"emq">>}]),

                        %% Unsubscribe
                        gen_tcp:send(Sock, serialize(<<"UNSUBSCRIBE">>, 
                                                    [{<<"id">>, 0}, 
                                                     {<<"receipt">>, <<"12345">>}])),

                        {ok, Data2} = gen_tcp:recv(Sock, 0),

                        {ok, #stomp_frame{command = <<"RECEIPT">>, 
                                          headers = [{<<"receipt-id">>, <<"12345">>}], 
                                          body    = _}, _} = parse(Data2),

                        gen_tcp:send(Sock, serialize(<<"SEND">>, 
                                                    [{<<"destination">>, <<"/queue/foo">>}],
                                                    <<"You will not receive this msg">>)),

                        {error, timeout} = gen_tcp:recv(Sock, 0, 500)
                    end).

t_transaction(_) ->
    with_connection(fun(Sock) ->
                        gen_tcp:send(Sock, serialize(<<"CONNECT">>, 
                                                     [{<<"accept-version">>, ?STOMP_VER},
                                                      {<<"host">>, <<"127.0.0.1:61613">>},
                                                      {<<"login">>, <<"guest">>},
                                                      {<<"passcode">>, <<"guest">>},
                                                      {<<"heart-beat">>, <<"0,0">>}])),                                                        
                        {ok, Data} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"CONNECTED">>, 
                                                  headers = _, 
                                                  body    = _}, _} = parse(Data),

                        %% Subscribe
                        gen_tcp:send(Sock, serialize(<<"SUBSCRIBE">>, 
                                                    [{<<"id">>, 0},
                                                     {<<"destination">>, <<"/queue/foo">>},
                                                     {<<"ack">>, <<"auto">>}])),

                        %% Transaction: tx1
                        gen_tcp:send(Sock, serialize(<<"BEGIN">>, 
                                                    [{<<"transaction">>, <<"tx1">>}])),

                        gen_tcp:send(Sock, serialize(<<"SEND">>, 
                                                    [{<<"destination">>, <<"/queue/foo">>},
                                                     {<<"transaction">>, <<"tx1">>}],
                                                    <<"hello">>)),

                        %% You will not receive any messages
                        {error, timeout} = gen_tcp:recv(Sock, 0, 1000),

                        gen_tcp:send(Sock, serialize(<<"SEND">>, 
                                                    [{<<"destination">>, <<"/queue/foo">>},
                                                     {<<"transaction">>, <<"tx1">>}],
                                                    <<"hello again">>)),

                        gen_tcp:send(Sock, serialize(<<"COMMIT">>, 
                                                    [{<<"transaction">>, <<"tx1">>}])),

                        {ok, Data1} = gen_tcp:recv(Sock, 0),

                        {ok, #stomp_frame{command = <<"MESSAGE">>, 
                                          headers = _, 
                                          body    = <<"hello">>}, Rest} = parse(Data1),

                        {ok, Data2} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"MESSAGE">>, 
                                          headers = _, 
                                          body    = <<"hello again">>}, Rest} = parse(Data2),

                        %% Transaction: tx2
                        gen_tcp:send(Sock, serialize(<<"BEGIN">>, 
                                                    [{<<"transaction">>, <<"tx2">>}])),

                        gen_tcp:send(Sock, serialize(<<"SEND">>, 
                                                    [{<<"destination">>, <<"/queue/foo">>},
                                                     {<<"transaction">>, <<"tx2">>}],
                                                    <<"hello">>)),

                        gen_tcp:send(Sock, serialize(<<"ABORT">>, 
                                                    [{<<"transaction">>, <<"tx2">>}])),

                        %% You will not receive any messages
                        {error, timeout} = gen_tcp:recv(Sock, 0, 1000),

                        gen_tcp:send(Sock, serialize(<<"DISCONNECT">>, 
                                                     [{<<"receipt">>, <<"12345">>}])),
                        
                        {ok, Data3} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"RECEIPT">>, 
                                          headers = [{<<"receipt-id">>, <<"12345">>}], 
                                          body    = _}, _} = parse(Data3)
                    end).

t_receipt_in_error(_) ->
    with_connection(fun(Sock) ->
                        gen_tcp:send(Sock, serialize(<<"CONNECT">>, 
                                                     [{<<"accept-version">>, ?STOMP_VER},
                                                      {<<"host">>, <<"127.0.0.1:61613">>},
                                                      {<<"login">>, <<"guest">>},
                                                      {<<"passcode">>, <<"guest">>},
                                                      {<<"heart-beat">>, <<"0,0">>}])),                                                        
                        {ok, Data} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"CONNECTED">>, 
                                          headers = _, 
                                          body    = _}, _} = parse(Data),

                        gen_tcp:send(Sock, serialize(<<"ABORT">>, 
                                                    [{<<"transaction">>, <<"tx1">>},
                                                     {<<"receipt">>, <<"12345">>}])),

                        {ok, Data1} = gen_tcp:recv(Sock, 0),
                        {ok, Frame = #stomp_frame{command = <<"ERROR">>, 
                                          headers = _, 
                                          body    = <<"Transaction tx1 not found">>}, _} = parse(Data1),
                        
                         <<"12345">> = proplists:get_value(<<"receipt-id">>, Frame#stomp_frame.headers)
                    end).

t_ack(_) ->
    with_connection(fun(Sock) ->
                        gen_tcp:send(Sock, serialize(<<"CONNECT">>, 
                                                     [{<<"accept-version">>, ?STOMP_VER},
                                                      {<<"host">>, <<"127.0.0.1:61613">>},
                                                      {<<"login">>, <<"guest">>},
                                                      {<<"passcode">>, <<"guest">>},
                                                      {<<"heart-beat">>, <<"0,0">>}])),                                                        
                        {ok, Data} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"CONNECTED">>, 
                                          headers = _, 
                                          body    = _}, _} = parse(Data),

                        %% Subscribe
                        gen_tcp:send(Sock, serialize(<<"SUBSCRIBE">>, 
                                                    [{<<"id">>, 0},
                                                     {<<"destination">>, <<"/queue/foo">>},
                                                     {<<"ack">>, <<"client">>}])),

                        gen_tcp:send(Sock, serialize(<<"SEND">>, 
                                                    [{<<"destination">>, <<"/queue/foo">>}],
                                                    <<"ack test">>)),

                        {ok, Data1} = gen_tcp:recv(Sock, 0),
                        {ok, Frame = #stomp_frame{command = <<"MESSAGE">>, 
                                                  headers = _, 
                                                  body    = <<"ack test">>}, _} = parse(Data1),

                        AckId = proplists:get_value(<<"ack">>, Frame#stomp_frame.headers),

                        gen_tcp:send(Sock, serialize(<<"ACK">>, 
                                                    [{<<"id">>, AckId},
                                                     {<<"receipt">>, <<"12345">>}])),

                        {ok, Data2} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"RECEIPT">>, 
                                                  headers = [{<<"receipt-id">>, <<"12345">>}], 
                                                  body    = _}, _} = parse(Data2),

                        gen_tcp:send(Sock, serialize(<<"SEND">>, 
                                                    [{<<"destination">>, <<"/queue/foo">>}],
                                                    <<"nack test">>)),

                        {ok, Data3} = gen_tcp:recv(Sock, 0),
                        {ok, Frame1 = #stomp_frame{command = <<"MESSAGE">>, 
                                                  headers = _, 
                                                  body    = <<"nack test">>}, _} = parse(Data3),

                        AckId1 = proplists:get_value(<<"ack">>, Frame1#stomp_frame.headers),

                        gen_tcp:send(Sock, serialize(<<"NACK">>, 
                                                    [{<<"id">>, AckId1},
                                                     {<<"receipt">>, <<"12345">>}])),

                        {ok, Data4} = gen_tcp:recv(Sock, 0),
                        {ok, #stomp_frame{command = <<"RECEIPT">>, 
                                                  headers = [{<<"receipt-id">>, <<"12345">>}], 
                                                  body    = _}, _} = parse(Data4)
                    end).

with_connection(DoFun) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, 
                                 61613, 
                                 [binary, {packet, raw}, {active, false}], 
                                 3000),
    try 
        DoFun(Sock)
    after
        gen_tcp:close(Sock)
    end.

serialize(Command, Headers) ->
    emqx_stomp_frame:serialize(emqx_stomp_frame:make(Command, Headers)).

serialize(Command, Headers, Body) ->
    emqx_stomp_frame:serialize(emqx_stomp_frame:make(Command, Headers, Body)).

parse(Data) ->
    ProtoEnv = [{max_headers, 10}, 
                {max_header_length, 1024}, 
                {max_body_length, 8192}],
    ParseFun = emqx_stomp_frame:parser(ProtoEnv),
    ParseFun(Data).

run_setup_steps(App) ->
    NewConfig = generate_config(App),
    lists:foreach(fun set_app_env/1, NewConfig),
    application:ensure_all_started(App).

generate_config(emqx) ->
    Schema = cuttlefish_schema:files([local_path(["deps", "emqx", "priv", "emqx.schema"])]),
    Conf = conf_parse:file([local_path(["deps", "emqx", "etc", "emqx.conf"])]),
    cuttlefish_generator:map(Schema, Conf);

generate_config(emqx_stomp) ->
    Schema = cuttlefish_schema:files([local_path(["priv", "emqx_stomp.schema"])]),
    Conf = conf_parse:file([local_path(["etc", "emqx_stomp.conf"])]),
    cuttlefish_generator:map(Schema, Conf).

get_base_dir(Module) ->
    {file, Here} = code:is_loaded(Module),
    filename:dirname(filename:dirname(Here)).

get_base_dir() ->
    get_base_dir(?MODULE).

local_path(Components, Module) ->
    filename:join([get_base_dir(Module) | Components]).

local_path(Components) ->
    local_path(Components, ?MODULE).

set_app_env({App, Lists}) ->
    lists:foreach(fun({acl_file, _Var}) -> 
                          application:set_env(App, acl_file, local_path(["emqx", "etc", "acl.conf"]));
                     ({plugins_loaded_file, _Var}) ->
                          application:set_env(App, plugins_loaded_file, 
                                              local_path(["emqx", "test", "emqx_SUITE_data", "loaded_plugins"]));
                     ({Par, Var}) ->
                          application:set_env(App, Par, Var)
                  end, Lists).
