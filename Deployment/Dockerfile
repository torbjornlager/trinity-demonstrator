FROM swipl:stable

RUN groupadd -r webprolog \
    && useradd -r -g webprolog -d /app -s /usr/sbin/nologin webprolog

WORKDIR /app

RUN mkdir -p /var/log/webprolog \
    && chown webprolog:webprolog /var/log/webprolog

COPY --chown=webprolog:webprolog . /app/

USER webprolog

ENV HOME=/tmp

CMD ["swipl", "-q", "-s", "/app/load.pl"]
