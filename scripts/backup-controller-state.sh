#!/bin/bash
#
# Back up the controller state that is NOT regenerable from this repo:
# service passwords, the LDAP database, Slurm accounting, the munge key,
# the cluster admin SSH key, and the hand-written inventory.
#
# Produces $BACKUP_DIR/controller-state-<host>-<timestamp>.tar.gz (mode 0600;
# it contains every secret in the cluster) and keeps the newest $RETENTION
# tarballs. Default destination is CephFS (/clusterhome) — survives a
# controller wipe, not a loss of the Ceph host. Run as root on the
# controller; installed as a daily root cron by playbooks/roles/backups.
#
# Alternative (better long-term): push to Ceph RGW S3 or the future central
# observability/backup infrastructure once either exists (issues.md).
#
# Restore notes:
#   passwords/            -> cp -a into /etc/opt/lucid-hpc/passwords/
#   ldap-config.ldif      -> (slapd stopped, /etc/ldap/slapd.d emptied)
#                            slapadd -F /etc/ldap/slapd.d -n 0 -l ldap-config.ldif
#   ldap-data.ldif        -> slapadd -F /etc/ldap/slapd.d -n 1 -l ldap-data.ldif
#                            then chown -R openldap:openldap /etc/ldap/slapd.d /var/lib/ldap
#   slurm_accounting.sql  -> mysql < slurm_accounting.sql (dump includes CREATE DATABASE)
#   munge.key             -> /etc/munge/munge.key (0400 munge:munge), restart munge
#                            everywhere; slurmdbd/slurmctld after
#   cluster.key{,.pub}    -> ~<admin>/.ssh/, mode 0600/0644
#   ansible-hosts         -> /etc/ansible/hosts
#   queues.conf           -> /opt/lucid-hpc/conf/queues.conf
#
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/clusterhome/.backups/controller}"
RETENTION="${RETENTION:-14}"
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-ubuntu}}"
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
TIMESTAMP=$(date '+%Y-%m-%d-%H%M%S')
TARBALL="controller-state-$(hostname -s)-${TIMESTAMP}.tar.gz"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (slapcat, /root/.my.cnf, munge key)" >&2; exit 1; }

# The default destination must be shared storage: backing the controller up
# to its own disk silently defeats the point. /clusterhome may be a systemd
# automount — stat something inside it first to trigger the attach, THEN ask
# findmnt (mountpoint -q lies before first access).
if [ "$BACKUP_DIR" = "/clusterhome/.backups/controller" ]; then
  stat /clusterhome/. >/dev/null 2>&1 || true
  FSTYPE=$(findmnt -n -o FSTYPE --target /clusterhome || true)
  case "$FSTYPE" in
    ceph|nfs|nfs4) ;;
    *) echo "ERROR: /clusterhome is '$FSTYPE', not shared storage — set BACKUP_DIR explicitly to override" >&2; exit 1 ;;
  esac
fi

STAGE=$(mktemp -d /tmp/controller-backup.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
chmod 0700 "$STAGE"

echo "== Dumping LDAP (cn=config + dc=local)"
slapcat -n 0 > "$STAGE/ldap-config.ldif"
slapcat -n 1 > "$STAGE/ldap-data.ldif"
grep -q '^dn:' "$STAGE/ldap-config.ldif" || { echo "ERROR: empty cn=config dump" >&2; exit 1; }
grep -q '^dn:' "$STAGE/ldap-data.ldif" || { echo "ERROR: empty LDAP data dump" >&2; exit 1; }

echo "== Dumping Slurm accounting database"
# Credentials come from /root/.my.cnf ([mysqldump] section, mysql role)
mysqldump --single-transaction --databases slurm_accounting > "$STAGE/slurm_accounting.sql"
grep -q 'CREATE TABLE' "$STAGE/slurm_accounting.sql" || { echo "ERROR: accounting dump has no tables" >&2; exit 1; }

echo "== Collecting passwords, keys, and config"
cp -a /etc/opt/lucid-hpc/passwords "$STAGE/passwords"
[ -n "$(ls -A "$STAGE/passwords")" ] || { echo "ERROR: passwords dir is empty" >&2; exit 1; }
cp /etc/munge/munge.key "$STAGE/munge.key"
cp "$ADMIN_HOME/.ssh/cluster.key" "$STAGE/cluster.key"
cp "$ADMIN_HOME/.ssh/cluster.key.pub" "$STAGE/cluster.key.pub"
cp /etc/ansible/hosts "$STAGE/ansible-hosts"
cp /opt/lucid-hpc/conf/queues.conf "$STAGE/queues.conf"

echo "== Writing $TARBALL"
install -d -m 0700 "$BACKUP_DIR"
tar czf "$STAGE/$TARBALL" -C "$STAGE" \
  ldap-config.ldif ldap-data.ldif slurm_accounting.sql passwords \
  munge.key cluster.key cluster.key.pub ansible-hosts queues.conf
chmod 0600 "$STAGE/$TARBALL"
mv "$STAGE/$TARBALL" "$BACKUP_DIR/$TARBALL"

echo "== Pruning (keeping newest $RETENTION)"
ls -1t "$BACKUP_DIR"/controller-state-*.tar.gz 2>/dev/null | tail -n +"$((RETENTION + 1))" | while read -r old; do
  rm -f "$old"
  echo "   pruned $old"
done

echo "== Done: $BACKUP_DIR/$TARBALL ($(du -h "$BACKUP_DIR/$TARBALL" | cut -f1))"
