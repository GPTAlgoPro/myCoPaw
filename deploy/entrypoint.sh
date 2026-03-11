#!/bin/sh
# Substitute COPAW_PORT in supervisord template and start supervisord.
# Default port 10888; override at runtime with -e COPAW_PORT=3000.
set -e
export COPAW_PORT="${COPAW_PORT:-10888}"
envsubst '${COPAW_PORT}' \
  < /etc/supervisor/conf.d/supervisord.conf.template \
  > /etc/supervisor/conf.d/supervisord.conf
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
