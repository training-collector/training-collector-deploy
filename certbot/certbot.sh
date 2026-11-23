#!/bin/sh
# Issues the two certificates and renews them when fewer than 30 days remain.
# nginx reads copies from /certs, so it never sees a half-written file.
set -u

publish() {
    name=$1
    mkdir -p "/certs/$name"
    cp -L "/etc/letsencrypt/live/$name/fullchain.pem" "/certs/$name/fullchain.pem.tmp"
    cp -L "/etc/letsencrypt/live/$name/privkey.pem" "/certs/$name/privkey.pem.tmp"
    chmod 600 "/certs/$name/privkey.pem.tmp"
    mv "/certs/$name/privkey.pem.tmp" "/certs/$name/privkey.pem"
    mv "/certs/$name/fullchain.pem.tmp" "/certs/$name/fullchain.pem"
}

issue() {
    name=$1
    domains=$2
    # --keep-until-expiring makes a repeated run renew only when the certificate is close to expiry.
    certbot certonly --webroot -w /var/www/certbot --cert-name "$name" -d "$domains" \
        --email "$ACME_EMAIL" --agree-tos --no-eff-email --non-interactive --keep-until-expiring \
        ${CERTBOT_STAGING:+--staging} && publish "$name"
}

# Let's Encrypt checks the domain through port 80, so nginx has to be up first.
until python3 -c "import socket; socket.create_connection(('proxy', 80), 2)" 2>/dev/null; do sleep 2; done
# Twice a day when all is well. After a failure, for example before DNS points here, every
# 15 minutes: that stays under the Let's Encrypt limit of 5 failed validations per name per hour.
while true; do
    pause=43200
    # The cabinet's certificate also covers www, which redirects to the bare domain.
    issue site "$SITE_DOMAIN,www.$SITE_DOMAIN" || { echo "Certificate for $SITE_DOMAIN failed, retrying in 15 minutes"; pause=900; }
    issue admin "$ADMIN_DOMAIN" || { echo "Certificate for $ADMIN_DOMAIN failed, retrying in 15 minutes"; pause=900; }
    sleep "$pause"
done
