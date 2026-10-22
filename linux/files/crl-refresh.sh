#!/bin/bash
# VDI-ImageMaint - refresh the CRL file SSSD checks certificates against
# (certificate_verification = no_ocsp, crl_file=...). Installed as
# /usr/local/sbin/vdi-imagemaint-crl-refresh, run by vdi-imagemaint-crl.timer on the
# golden image AND on every instant clone (clones are forked with the timer running).
#
# Rules measured in the sssd-smartcard project (SSSD 2.9/2.10, OpenSSL 3):
#   - EVERY CA in the bundle needs a current CRL, or no certificate verifies at all;
#   - several CRLs concatenated into one PEM file work, in any order;
#   - SSSD never downloads or refreshes the file itself.
# So the file is replaced only by a complete, current, correctly signed set. Any
# failure leaves the previous file in place and exits non-zero (systemctl status).
set -u
CONF=${VDI_CRL_CONF:-/etc/vdi-imagemaint/crl.conf}
CA_DB=/etc/sssd/pki/sssd_auth_ca_db.pem
CRL_FILE=/etc/sssd/pki/sssd_auth_crl.pem
CRL_URLS=""
# shellcheck source=/dev/null
[[ -r $CONF ]] && . "$CONF"

err() { echo "ERR: $*" >&2; exit 1; }
[[ -n $CRL_URLS ]] || err "no CRL_URLS in $CONF"
[[ -s $CA_DB ]] || err "CA bundle $CA_DB missing"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/set.pem"
: >"$tmp/issuers"
now=$(date +%s)
i=0
for url in $CRL_URLS; do
    i=$((i + 1))
    f="$tmp/$i"
    curl -fsS --max-time 30 -o "$f" "$url" || err "download failed: $url"
    # AD CS publishes DER; decide by content (OpenSSL 3 would also read DER without
    # -inform DER, so "it parses" says nothing about the format).
    if grep -q -- '-----BEGIN X509 CRL-----' "$f"; then
        form=PEM
    else
        form=DER
    fi
    openssl crl -inform "$form" -in "$f" -noout 2>/dev/null || err "not a CRL: $url"
    openssl crl -inform "$form" -in "$f" -out "$f.pem" 2>/dev/null || err "cannot convert: $url"
    openssl crl -in "$f.pem" -CAfile "$CA_DB" -noout 2>&1 | grep -q 'verify OK' ||
        err "not signed by a CA in $CA_DB: $url"
    next=$(openssl crl -in "$f.pem" -noout -nextupdate | cut -d= -f2-)
    if [[ -z $next ]] || (($(date -d "$next" +%s) <= now)); then
        err "expired ($next): $url"
    fi
    openssl crl -in "$f.pem" -noout -issuer -nameopt RFC2253,-esc_msb | sed 's/^issuer=//' >>"$tmp/issuers"
    cat "$f.pem" >>"$tmp/set.pem"
    echo "ok: $url (next update $next)"
done

# One CRL per CA in the bundle.
awk -v d="$tmp" '/-----BEGIN CERTIFICATE-----/ {n++} n {print > (d "/ca" n ".pem")}' "$CA_DB"
for ca in "$tmp"/ca*.pem; do
    subject=$(openssl x509 -in "$ca" -noout -subject -nameopt RFC2253,-esc_msb | sed 's/^subject=//')
    grep -Fxq "$subject" "$tmp/issuers" || err "no CRL for the CA \"$subject\" - every CA in the bundle needs one"
done

if ! install -m 0644 "$tmp/set.pem" "$CRL_FILE.new" || ! mv -f "$CRL_FILE.new" "$CRL_FILE"; then
    err "cannot write $CRL_FILE"
fi
echo "written: $CRL_FILE ($i CRLs)"
