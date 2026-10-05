# ---- build -------------------------------------------------------------------
FROM erlang:27 AS build
WORKDIR /app
COPY rebar.config rebar.lock* ./
RUN rebar3 get-deps && rebar3 compile --deps_only
COPY config config
COPY src src
COPY priv priv
RUN rebar3 release

# ---- runtime -----------------------------------------------------------------
# Same base as the builder (Debian bookworm): the embedded ERTS is compatible.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 libssl3 libncurses6 libstdc++6 \
      ca-certificates tini tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home --home-dir /home/ana --shell /usr/sbin/nologin ana
COPY --from=build /app/_build/default/rel/ana /opt/ana
COPY bin/ana-start /opt/ana/bin/ana-start
# Core code belongs to root and is read-only for the process (P10).
RUN chmod -R a-w /opt/ana && chmod 0555 /opt/ana/bin/ana-start \
 && mkdir -p /var/lib/ana/files && chown ana:ana /var/lib/ana/files && chmod 0700 /var/lib/ana/files
USER ana
ENV HOME=/home/ana ANA_PY_DIR=/tmp LANG=C.UTF-8
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health/live', timeout=2)"
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/ana/bin/ana-start"]
