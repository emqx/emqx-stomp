PROJECT = emqttd_stomp
PROJECT_DESCRIPTION = Stomp Protocol Plugin for emqttd broker
PROJECT_VERSION = 2.0

DEPS = gen_conf emqttd

dep_gen_conf = git https://github.com/emqtt/gen_conf
dep_emqttd   = git https://github.com/emqtt/emqttd

ERLC_OPTS += +'{parse_transform, lager_transform}'

COVER = true

include erlang.mk

app:: rebar.config
