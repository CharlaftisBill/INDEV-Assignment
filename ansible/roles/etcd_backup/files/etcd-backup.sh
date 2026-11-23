#!/usr/bin/env bash
# Managed by Ansible (etcd_backup role). Snapshot etcd into BACKUP_DIR, verify it, prune by count, publish metrics.
set -euo pipefail

: "${BACKUP_DIR:?}" "${KEEP:?}" "${TEXTFILE_DIR:?}" "${METRICS_FILE:?}" "${MOUNT_FSTYPES:?}" "${ENDPOINT:?}" "${PKI_DIR:?}" "${SNAPSHOT_GLOB:?}"

# B-010: without the mount the snapshot would land on the VM disk and die with the VM.
fstype="$(findmnt -n -o FSTYPE -M "$BACKUP_DIR" || true)"
# REQUIRE_MOUNT=0 only for a VM used over SSH without the Lima mount (external-vm.conf).
if [[ "${REQUIRE_MOUNT:-1}" == 1 && ( -z "$fstype" || ",$MOUNT_FSTYPES," != *",$fstype,"* ) ]]; then
  echo "refusing to write: $BACKUP_DIR is not a mountpoint of type ${MOUNT_FSTYPES} (found '${fstype:-none}')" >&2
  exit 1
fi

umask 077
name="etcd-snapshot-$(date -u +%Y%m%dT%H%M%SZ).db"
tmp="$BACKUP_DIR/.$name.tmp"
trap 'rm -f -- "$tmp"' EXIT

# Leftovers from a killed run (an hour is far beyond the unit's timeout).
find "$BACKUP_DIR" -maxdepth 1 -name '.etcd-snapshot-*.tmp*' -mmin +60 -delete

etcdctl --endpoints "$ENDPOINT" --cacert "$PKI_DIR/ca.crt" --cert "$PKI_DIR/healthcheck-client.crt" --key "$PKI_DIR/healthcheck-client.key" \
  snapshot save "$tmp"
etcdutl snapshot status "$tmp" --write-out=json >/dev/null

# Same directory, so the rename is atomic: readers never see a partial snapshot under the final name.
mv -- "$tmp" "$BACKUP_DIR/$name"
size="$(stat -c %s -- "$BACKUP_DIR/$name")"

mapfile -t snaps < <(find "$BACKUP_DIR" -maxdepth 1 -name "$SNAPSHOT_GLOB" -printf '%f\n' | sort)
for ((i = 0; i < ${#snaps[@]} - KEEP; i++)); do rm -f -- "$BACKUP_DIR/${snaps[i]}"; done
kept=$((${#snaps[@]} > KEEP ? KEEP : ${#snaps[@]}))

# Written last: the timestamp only moves when the snapshot is saved, verified and in place.
mtmp="$TEXTFILE_DIR/.$METRICS_FILE.tmp"
cat >"$mtmp" <<METRICS
# HELP etcd_backup_last_success_timestamp_seconds Unix time of the last verified etcd snapshot written to the host.
# TYPE etcd_backup_last_success_timestamp_seconds gauge
etcd_backup_last_success_timestamp_seconds $(date +%s)
# HELP etcd_backup_last_snapshot_size_bytes Size of the last snapshot.
# TYPE etcd_backup_last_snapshot_size_bytes gauge
etcd_backup_last_snapshot_size_bytes $size
# HELP etcd_backup_snapshots_kept Snapshots in the backup directory after pruning.
# TYPE etcd_backup_snapshots_kept gauge
etcd_backup_snapshots_kept $kept
METRICS
chmod 0644 "$mtmp"
mv -- "$mtmp" "$TEXTFILE_DIR/$METRICS_FILE"
echo "saved $name ($size bytes), kept $kept"
