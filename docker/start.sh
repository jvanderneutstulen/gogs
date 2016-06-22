#!/bin/sh

create_socat_links() {
    # Bind linked docker container to localhost socket using socat
    USED_PORT="3000:22"
    while read NAME ADDR PORT; do
        if test -z "$NAME$ADDR$PORT"; then
            continue
        elif echo $USED_PORT | grep -E "(^|:)$PORT($|:)" > /dev/null; then
            echo "init:socat  | Can't bind linked container ${NAME} to localhost, port ${PORT} already in use" 1>&2
        else
            SERV_FOLDER=/app/gogs/docker/s6/SOCAT_${NAME}_${PORT}
            mkdir -p ${SERV_FOLDER}
            CMD="socat -ls TCP4-LISTEN:${PORT},fork,reuseaddr TCP4:${ADDR}:${PORT}"
            echo -e "#!/bin/sh\nexec $CMD" > ${SERV_FOLDER}/run
            chmod +x ${SERV_FOLDER}/run
            USED_PORT="${USED_PORT}:${PORT}"
            echo "init:socat  | Linked container ${NAME} will be binded to localhost on port ${PORT}" 1>&2
        fi
    done << EOT
    $(env | sed -En 's|(.*)_PORT_([0-9]+)_TCP=tcp://(.*):([0-9]+)|\1 \3 \4|p')
EOT
}

cleanup() {
    # Cleanup SOCAT services and s6 event folder
    # On start and on shutdown in case container has been killed
    rm -rf $(find /app/gogs/docker/s6/ -name 'event')
    rm -rf /app/gogs/docker/s6/SOCAT_*
}

create_volume_subfolder() {
    # Create VOLUME subfolder
    for f in /data/gogs/data /data/gogs/conf /data/gogs/log /data/git /data/ssh; do
        if ! test -d $f; then
            mkdir -p $f
        fi
    done
}

create_conf() {
    if [ ! -e /data/gogs/conf/app.ini ]; then
cat << EOF > /data/gogs/conf/app.ini
APP_NAME = ${GOGS_APP_NAME:-DockerGogs}
RUN_USER = ${GOGS_RUN_USER:-git}
RUN_MODE = ${GOGS_RUN_MODE:-prod}

[database]
DB_TYPE  = ${GOGS_DB_TYPE:-sqlite3}
HOST     = ${GOGS_DB_HOST:-127.0.0.1:5432}
NAME     = ${GOGS_DB_NAME:-gogs}
USER     = ${GOGS_DB_USER:-root}
PASSWD   = ${GOGS_DB_PASSWORD}
SSL_MODE = ${GOGS_DB_SSL_MODE:-disable}
PATH     = ${GOGS_DB_PATH:-data/gogs.db}

[repository]
ROOT = ${GOGS_ROOT:-/data/git/gogs-repositories}

[server]
DOMAIN       = ${GOGS_DOMAIN:-localhost}
HTTP_PORT    = ${GOGS_HTTP_PORT:-3000}
ROOT_URL     = ${GOGS_ROOT_URL:-http://localhost:3000/}
DISABLE_SSH  = ${GOGS_DISABLE_SSH:-false}
SSH_PORT     = ${GOGS_SSH_PORT:-22}
OFFLINE_MODE = ${GOGS_OFFLINE_MODE:-false}

[mailer]
ENABLED = ${GOGS_MAILER:-false}

[service]
REGISTER_EMAIL_CONFIRM = ${GOGS_REGISTER_EMAIL_CONFIRM:-false}
ENABLE_NOTIFY_MAIL     = ${GOGS_ENABLE_NOTIFY_MAIL:-false}
DISABLE_REGISTRATION   = ${GOGS_DISABLE_REGISTRATION:-true}
ENABLE_CAPTCHA         = ${GOGS_ENABLE_CAPTCHA:-false}
REQUIRE_SIGNIN_VIEW    = ${GOGS_REQUIRE_SIGNIN_VIEW:-true}

[picture]
DISABLE_GRAVATAR = ${GOGS_DISABLE_GRAVATAR:-true}

[session]
PROVIDER = file

[log]
MODE      = file
LEVEL     = Info
ROOT_PATH = /app/gogs/log
EOF
    fi
}

map_uidgid() {
  USERMAP_ORIG_UID=$(id -u git)
  USERMAP_ORIG_GID=$(id -g git)
  USERMAP_GID=${USERMAP_GID:-${USERMAP_UID:-$USERMAP_ORIG_GID}}
  USERMAP_UID=${USERMAP_UID:-$USERMAP_ORIG_UID}
  if [[ ${USERMAP_UID} != ${USERMAP_ORIG_UID} ]] || [[ ${USERMAP_GID} != ${USERMAP_ORIG_GID} ]]; then
    echo "Mapping UID and GID for git:git to $USERMAP_UID:$USERMAP_GID"
    #groupmod -g ${USERMAP_GID} git
    sed -i -e "s|:${USERMAP_ORIG_GID}:|:${USERMAP_GID}:|" /etc/group
    sed -i -e "s|:${USERMAP_ORIG_UID}:${USERMAP_ORIG_GID}:|:${USERMAP_UID}:${USERMAP_GID}:|" /etc/passwd
    find /data -path /data/git/\* -prune -o -print0 | xargs -0 chown -h git:
  fi
}

cleanup
create_volume_subfolder
create_conf
map_uidgid

LINK=$(echo "$SOCAT_LINK" | tr '[:upper:]' '[:lower:]')
if [ "$LINK" = "false" -o "$LINK" = "0" ]; then
    echo "init:socat  | Will not try to create socat links as requested" 1>&2
else
    create_socat_links
fi

CROND=$(echo "$RUN_CROND" | tr '[:upper:]' '[:lower:]')
if [ "$CROND" = "true" -o "$CROND" = "1" ]; then
    echo "init:crond  | Cron Daemon (crond) will be run as requested by s6" 1>&2
    rm -f /app/gogs/docker/s6/crond/down
else
    # Tell s6 not to run the crond service
    touch /app/gogs/docker/s6/crond/down
fi

# Exec CMD or S6 by default if nothing present
if [ $# -gt 0 ];then
    exec "$@"
else
    exec /bin/s6-svscan /app/gogs/docker/s6/
fi
