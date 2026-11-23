#!/bin/sh
# Creates .env once on the server. Values come from the environment of this command; every
# secret that is not given is generated here, so it never leaves the server.
# Required: SITE_DOMAIN ADMIN_DOMAIN ACME_EMAIL ADMIN_LOGIN ADMIN_PASSWORD AUTH_BOT_TOKEN BOT_TOKEN
set -eu

cd "$(dirname "$0")/.."
if [ -f .env ]; then echo ".env already exists; edit it by hand" >&2; exit 1; fi
for name in SITE_DOMAIN ADMIN_DOMAIN ACME_EMAIL ADMIN_LOGIN ADMIN_PASSWORD AUTH_BOT_TOKEN BOT_TOKEN; do
    eval "value=\${$name:-}"
    if [ -z "$value" ]; then echo "Set $name" >&2; exit 1; fi
done
secret() { openssl rand -hex 32; }
umask 077
cat > .env <<ENV
SITE_DOMAIN=$SITE_DOMAIN
ADMIN_DOMAIN=$ADMIN_DOMAIN
ACME_EMAIL=$ACME_EMAIL
DB_PASSWORD=${DB_PASSWORD:-$(secret)}
APP_SECRET=${APP_SECRET:-$(secret)}
AUTH_SERVICE_KEY=${AUTH_SERVICE_KEY:-$(secret)}
TRAINING_SERVICE_KEY=${TRAINING_SERVICE_KEY:-$(secret)}
ADMIN_LOGIN=$ADMIN_LOGIN
ADMIN_PASSWORD=$ADMIN_PASSWORD
AUTH_BOT_TOKEN=$AUTH_BOT_TOKEN
BOT_TOKEN=$BOT_TOKEN
BOT_DEFAULT_TIME_ZONE=${BOT_DEFAULT_TIME_ZONE:-UTC}
${CERTBOT_STAGING:+CERTBOT_STAGING=$CERTBOT_STAGING}
ENV
echo ".env written"
