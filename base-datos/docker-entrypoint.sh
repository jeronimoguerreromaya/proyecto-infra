#!/bin/sh

# Ensure data directory exists and has correct permissions
mkdir -p /var/lib/mysql
chown -R mysql:mysql /var/lib/mysql

if [ ! -d /var/lib/mysql/mysql ]; then
    echo "Inicializando base de datos..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql
fi

exec su-exec mysql "$@"