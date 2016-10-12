PROJECT = emq_stomp
PROJECT_DESCRIPTION = Stomp Protocol Plugin for EMQ 3.0 broker
PROJECT_VERSION = 3.0

BUILD_DEPS = emqttd cuttlefish
dep_emqttd     = git https://github.com/emqtt/emqttd master
dep_cuttlefish = git https://github.com/basho/cuttlefish master

ERLC_OPTS += +'{parse_transform, lager_transform}'

COVER = true

include erlang.mk

app:: rebar.config

app.config::
	cuttlefish -l info -e etc/ -c etc/emq_stomp.conf -i priv/emq_stomp.schema -d data
