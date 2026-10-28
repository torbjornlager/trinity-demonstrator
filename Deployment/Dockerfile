# syntax=docker/dockerfile:1
# Build from the repository root. For a private native dependency, pass
# --secret id=github_token,src=/path/to/read-token (never a build argument).
FROM swipl:10.1.19
RUN apt-get update && apt-get install -y --no-install-recommends python3 git \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r webprolog \
    && useradd -r -g webprolog -d /app -s /usr/sbin/nologin webprolog
WORKDIR /app
COPY . /app/
RUN --mount=type=secret,id=github_token \
    python3 tools/fetch_swi.py --destination /opt/swi-prolog-node --token-file /run/secrets/github_token \
    && git config --system --add safe.directory /opt/swi-prolog-node \
    && python3 tools/fetch_browser.py --destination /opt/swi-wasm-node --token-file /run/secrets/github_token \
    && python3 tools/setup_swi.py --native-root /opt/swi-prolog-node --browser-root /opt/swi-wasm-node \
    && WP_CHECK=1 swipl -f none -q -s Deployment/start_node.pl \
    && mkdir -p /var/log/webprolog \
    && chown -R webprolog:webprolog /app/.trinity /var/log/webprolog
USER webprolog
ENV HOME=/tmp

CMD ["swipl", "-q", "-s", "/app/load.pl"]
