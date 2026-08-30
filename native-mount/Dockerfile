FROM alpine:3.21

# bash: run.sh runtime
# jq: config parsing
# util-linux: nsenter
RUN apk add --no-cache bash curl jq util-linux

COPY run.sh /
RUN chmod a+x /run.sh

CMD ["/run.sh"]
