#!/bin/sh
set -eu

cd /app/elixir

if [ "${SYMPHONY_MIGRATE:-true}" = "true" ]; then
  mix ecto.create || true
  mix ecto.migrate
fi

exec "$@"
