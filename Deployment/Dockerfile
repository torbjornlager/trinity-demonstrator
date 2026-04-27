FROM swipl:stable

RUN groupadd -r webprolog \
    && useradd -r -g webprolog -d /app -s /usr/sbin/nologin webprolog

WORKDIR /app

COPY --chown=webprolog:webprolog . /app/

USER webprolog

ENV HOME=/tmp

CMD ["swipl", "-q", "-s", "/app/load.pl"]
