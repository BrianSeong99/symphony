FROM elixir:1.19-alpine

RUN apk add --no-cache build-base curl git postgresql-client

WORKDIR /app/elixir

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY elixir/mix.exs elixir/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY elixir ./
COPY config /app/config
COPY docker/entrypoint.sh /app/docker/entrypoint.sh

RUN mix compile && chmod +x /app/docker/entrypoint.sh

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:4000/healthz >/dev/null || exit 1

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["mix", "run", "--no-halt"]
