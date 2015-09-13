
-module(emqttd_stomp).

-define(SOCKOPTS, [binary,
                   {packet,    raw},
                   {reuseaddr, true},
                   {backlog,   128},
                   {nodelay,   true}]).

