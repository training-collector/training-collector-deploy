#!/bin/sh
# Writes the nginx config before start: port 80 always, port 443 once both certificates exist.
# Afterwards it checks the certificates every minute and reloads nginx when they change,
# so the first certificate and every renewal are picked up without a restart.
set -eu

render() {
    # The single quotes are deliberate: envsubst gets the variable names, not their values.
    # shellcheck disable=SC2016
    envsubst '${SITE_DOMAIN} ${ADMIN_DOMAIN}' < /etc/nginx/proxy/http.conf.template > /etc/nginx/conf.d/default.conf
    if [ -f /certs/site/fullchain.pem ] && [ -f /certs/admin/fullchain.pem ]; then
        # shellcheck disable=SC2016
        envsubst '${SITE_DOMAIN} ${ADMIN_DOMAIN}' < /etc/nginx/proxy/https.conf.template >> /etc/nginx/conf.d/default.conf
    fi
}

certificates() {
    stat -c '%Y' /certs/site/fullchain.pem /certs/admin/fullchain.pem 2>/dev/null | tr '\n' ' ' || true
}

rm -f /etc/nginx/conf.d/*.conf
render
(
    seen=$(certificates)
    while sleep 60; do
        now=$(certificates)
        if [ "$now" != "$seen" ]; then
            render
            if nginx -t -q; then nginx -s reload && echo "Certificates changed, nginx reloaded"; fi
            seen=$now
        fi
    done
) &
