ARG BUILD_FROM
FROM $BUILD_FROM

# util-linux provides nsenter
RUN apk add --no-cache util-linux

COPY run.sh /
RUN chmod a+x /run.sh

CMD ["/run.sh"]
