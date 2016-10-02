PROJECT = emqttd_stomp
PROJECT_DESCRIPTION = Stomp Protocol Plugin for EMQ broker
PROJECT_VERSION = 2.0

DEPS = gen_conf
dep_gen_conf = git https://github.com/emqtt/gen_conf master

BUILD_DEPS = emqttd
dep_emqttd = git https://github.com/emqtt/emqttd emq20

ERLC_OPTS += +'{parse_transform, lager_transform}'

COVER = true

include erlang.mk

app:: rebar.config
