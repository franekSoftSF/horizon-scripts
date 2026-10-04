#!/bin/bash
# VDI-ImageMaint - per-clone RunOnce script (viewagent-custom.conf: RunOnceScript).
# Runs as root on every instant clone after ClonePrep set the host name and did
# the SSSD offline domain join. Instant clones are forked, not booted, so boot-time
# units do not run per clone - everything clone-specific belongs here.
# Must finish within RunOnceScriptTimeout; never block, never prompt.

set -u
LOG=/var/log/vdi-imagemaint/runonce.log
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T') runonce on $(hostname -f 2>/dev/null || hostname)"

step() {
    echo "--- $*"
    timeout "${STEP_TIMEOUT:-30}" "$@" || echo "WARN: '$*' returned $?"
}

# SSH host keys were removed at Seal: every clone gets its own.
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    step ssh-keygen -A
    systemctl is-enabled --quiet ssh.service 2>/dev/null && step systemctl restart ssh.service
fi

# Clock first: after the fork Kerberos (SSSD, NFS) fails above 5 minutes of skew.
if systemctl is-enabled --quiet systemd-timesyncd.service 2>/dev/null; then
    step systemctl restart systemd-timesyncd.service
    for _ in $(seq 1 20); do
        [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && break
        sleep 1
    done
    echo "time: $(date -Is) synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
fi

# Site hook first - it may create the keytab, e.g. the RunOnceScript an adopted
# image had before (domain rejoin).
# Same rules: non-interactive, finish within RunOnceScriptTimeout.
if [[ -x /etc/vdi-imagemaint/runonce.local ]]; then
    STEP_TIMEOUT=90 step /etc/vdi-imagemaint/runonce.local
fi

# New machine keytab from the offline join -> restart SSSD and NFS Kerberos clients.
# The SSSD cache is kept (no sss_cache -E): it carries the cached credentials that
# keep logons working while a DC is not reachable yet.
step systemctl restart sssd.service
echo "keytab: $(klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR>3 {print $1, $2}' | sort -u | head -n 3 | tr '\n' ' ')"
if systemctl is-enabled --quiet autofs.service 2>/dev/null; then
    step systemctl restart rpc-gssd.service
    step systemctl restart autofs.service
fi

echo "=== done"
exit 0
