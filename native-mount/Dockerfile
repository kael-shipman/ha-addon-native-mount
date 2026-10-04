FROM alpine:3.21

# bash: run.sh runtime
# jq: config parsing
# util-linux: nsenter
# mosquitto-clients: mosquitto_pub/mosquitto_sub for MQTT discovery
RUN apk add --no-cache bash curl jq util-linux mosquitto-clients ca-certificates

# Supplied by the Supervisor's builder; surfaced in the HA device info.
ARG BUILD_VERSION
ENV NATIVE_MOUNT_VERSION=${BUILD_VERSION}

COPY run.sh /
RUN chmod a+x /run.sh

CMD ["/run.sh"]
