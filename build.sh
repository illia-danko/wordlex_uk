#!/usr/bin/env bash
#
# Build release
# See https://hexdocs.pm/phoenix/releases.html

set -eou pipefail

working_dir="/var/server/slivce"
# See systemd homepage.service entry.
env_conf="/var/server/slivce/env.conf"

pushd "$working_dir"

export MIX_ENV="prod"
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8

compile() {
    mix local.hex --force
    mix local.rebar --force

    mix deps.get --only "$MIX_ENV"
    mix compile
    mix assets.deploy
    mix release
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

    # Postfix.
    echo "MIX_ENV=$MIX_ENV" > "$env_conf"
    echo "SECRET_KEY_BASE=$(mix phx.gen.secret)" >> "$env_conf"
    echo "PHX_SERVER=1" >> "$env_conf" # to start to listen to a PORT
}

case "$1" in
    compile) compile;;
esac
