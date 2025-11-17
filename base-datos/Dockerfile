FROM alpine:3.19

RUN apk update && \
    apk add --no-cache mariadb mariadb-client mariadb-common su-exec

RUN mkdir -p /run/mysqld && \
    chown -R mysql:mysql /run/mysqld

COPY my.cnf /etc/my.cnf

EXPOSE 3306

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["mysqld"]