#!/bin/bash
# VDI-ImageMaint - per-clone RunOnce script (viewagent-custom.conf: RunOnceScript).
# Runs as root on every instant clone after ClonePrep set the host name and did
# the SSSD offline domain join. Instant clones are forked, not booted, so boot-time
# units do not run per clone - everything clone-specific belongs here.
# Must finish within RunOnceScriptTimeout; never block, never prompt.
# SSSD, the domain join and the clock belong to Horizon (ClonePrep) and VMware Tools:
# this script never restarts SSSD or the time service (that broke clone logons, 0.8.0).

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

# Site hook first - it may create the keytab, e.g. the RunOnceScript an adopted
# image had before (domain rejoin).
# Same rules: non-interactive, finish within RunOnceScriptTimeout.
if [[ -x /etc/vdi-imagemaint/runonce.local ]]; then
    STEP_TIMEOUT=90 step /etc/vdi-imagemaint/runonce.local
fi

# New machine keytab from the offline join -> NFS Kerberos client (rpc-gssd) only.
echo "keytab: $(klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR>3 {print $1, $2}' | sort -u | head -n 3 | tr '\n' ' ')"
if systemctl is-active --quiet rpc-gssd.service 2>/dev/null; then
    step systemctl restart rpc-gssd.service
fi
if systemctl is-enabled --quiet autofs.service 2>/dev/null; then
    step systemctl restart autofs.service
fi

echo "=== done"
exit 0
