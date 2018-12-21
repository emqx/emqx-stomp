PROJECT = emqx_stomp
PROJECT_DESCRIPTION = EMQ X Stomp Protocol Plugin
PROJECT_VERSION = 3.0
PROJECT_MOD = emqx_stomp

DEPS = clique
dep_clique = git https://github.com/emqx/clique v0.3.11

BUILD_DEPS = emqx cuttlefish
dep_emqx = git https://github.com/emqx/emqx emqx30
dep_cuttlefish = git https://github.com/emqx/cuttlefish v2.1.1

NO_AUTOPATCH = cuttlefish

ERLC_OPTS += +debug_info

CT_SUITES = emqx_stomp

CT_NODE_NAME = emqxct@127.0.0.1
CT_OPTS = -cover test/ct.cover.spec -erl_args -name $(CT_NODE_NAME)

COVER = true

include erlang.mk

app:: rebar.config

app.config::
	./deps/cuttlefish/cuttlefish -l info -e etc/ -c etc/emqx_stomp.conf -i priv/emqx_stomp.schema -d data
