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
    timeout 30 "$@" || echo "WARN: '$*' returned $?"
}

# SSH host keys were removed at Seal: every clone gets its own.
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    step ssh-keygen -A
    systemctl is-enabled --quiet ssh.service 2>/dev/null && step systemctl restart ssh.service
fi

# New machine keytab from the offline join -> refresh SSSD and NFS Kerberos clients.
step sss_cache -E
step systemctl restart sssd.service
if systemctl is-enabled --quiet autofs.service 2>/dev/null; then
    step systemctl restart rpc-gssd.service
    step systemctl restart autofs.service
fi

# Optional site hook (same rules: fast, non-interactive).
if [[ -x /etc/vdi-imagemaint/runonce.local ]]; then
    step /etc/vdi-imagemaint/runonce.local
fi

echo "=== done"
exit 0
