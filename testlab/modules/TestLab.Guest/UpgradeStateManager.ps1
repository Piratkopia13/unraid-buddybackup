<#
.SYNOPSIS
    Configuration persistence and upgrade state capture/verification for BuddyBackup TestLab.
.DESCRIPTION
    Encapsulates test scenario planning, setup script generation, remote state sampling,
    and before/after state diffing across BuddyBackup upgrade cycles.
#>

$ErrorActionPreference = "Stop"

function Get-FunctionalTestConfig {
    param($Lab)

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $functionalCfg = Get-ObjectValue -Object $setupCfg -Name "functionalTests"

    $hostGatewayIp = [string](Get-ObjectValue -Object $functionalCfg -Name "hostGatewayIp")
    if ([string]::IsNullOrWhiteSpace($hostGatewayIp)) {
        $hostGatewayIp = "10.0.2.2"
    }

    $nodeAAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "nodeAAliasIp")
    if ([string]::IsNullOrWhiteSpace($nodeAAliasIp)) {
        $nodeAAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "senderAliasIp")
    }
    if ([string]::IsNullOrWhiteSpace($nodeAAliasIp)) {
        $nodeAAliasIp = "10.254.0.22"
    }

    $nodeBAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "nodeBAliasIp")
    if ([string]::IsNullOrWhiteSpace($nodeBAliasIp)) {
        $nodeBAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "receiverAliasIp")
    }
    if ([string]::IsNullOrWhiteSpace($nodeBAliasIp)) {
        $nodeBAliasIp = "10.254.0.23"
    }

    $allowUnencryptedRemoteBackups = "yes"
    $allowUnencryptedValue = Get-ObjectValue -Object $functionalCfg -Name "allowUnencryptedRemoteBackups"
    if ($null -ne $allowUnencryptedValue) {
        $allowUnencryptedRemoteBackups = if ([bool]$allowUnencryptedValue) { "yes" } else { "no" }
    }

    return [pscustomobject]@{
        hostGatewayIp                 = $hostGatewayIp
        nodeAAliasIp                  = $nodeAAliasIp
        nodeBAliasIp                  = $nodeBAliasIp
        allowUnencryptedRemoteBackups = $allowUnencryptedRemoteBackups
    }
}

function Get-UpgradeScenarioNodePlan {
    param(
        [string]$NodeName,
        $Connection,
        $ZfsValues,
        $FunctionalCfg
    )

    $canonicalNodeName = Get-TestLabCanonicalNodeName -NodeName $NodeName
    $uidPrefix = if ($canonicalNodeName -eq "nodeA") { "a" } else { "b" }
    $aliasIp = if ($canonicalNodeName -eq "nodeA") { $FunctionalCfg.nodeAAliasIp } else { $FunctionalCfg.nodeBAliasIp }
    $root = "$($ZfsValues.DatasetRoot)/upgrade/$canonicalNodeName"

    $port = 22
    if ($Connection) {
        $connPort = Get-ObjectValue -Object $Connection -Name "Port"
        if ($null -eq $connPort) { $connPort = Get-ObjectValue -Object $Connection -Name "port" }
        if ($null -ne $connPort) { $port = [int]$connPort }
    }

    return [pscustomobject]@{
        NodeName           = $canonicalNodeName
        SourceDataset      = "$root/source"
        SourceMountpoint   = "/mnt/buddybackup-upgrade/$canonicalNodeName-source"
        LocalBackupDataset = "$root/local-backup"
        ReceiveRootDataset = "$($ZfsValues.DatasetRoot)/upgrade/receive-$canonicalNodeName"
        RemoteBackupUid    = "${uidPrefix}upgrm01"
        LocalBackupUid     = "${uidPrefix}upglc01"
        SnapshotUid        = "${uidPrefix}upgsn01"
        AliasIp            = $aliasIp
        Port               = $port
    }
}

function New-UpgradePreservesConfigSetupScript {
    $script = @'
node_name="$1"
source_dataset="$2"
source_mountpoint="$3"
local_backup_dataset="$4"
receive_root_dataset="$5"
remote_uid="$6"
local_uid="$7"
snapshot_uid="$8"
remote_host="$9"
remote_destination_dataset="${10}"
allow_unencrypted="${11}"
peer_public_key="${12}"
host_gateway_ip="${13}"
peer_port="${14}"
peer_alias_ip="${15}"

set -euo pipefail

plugin_root="/boot/config/plugins/buddybackup"
plugin_cfg="$plugin_root/buddybackup.cfg"
backups_cfg="$plugin_root/backups.cfg"
snapshots_cfg="$plugin_root/snapshots.cfg"

set_ini_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    local escaped
    escaped=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')

    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${escaped}\"|" "$file"
    else
        printf '%s="%s"\n' "$key" "$value" >> "$file"
    fi
}

persist_peer_forward_rule() {
    local peer_alias_ip="$1"
    local host_gateway_ip="$2"
    local peer_port="$3"
    local go_file="/boot/config/go"
    local start_marker="# BuddyBackup testlab: persist peer forward ${peer_alias_ip} start"
    local end_marker="# BuddyBackup testlab: persist peer forward ${peer_alias_ip} end"
    local tmp_go

    if [ ! -f "$go_file" ]; then
        return 0
    fi

    tmp_go="${go_file}.buddybackup.tmp"
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$go_file" > "$tmp_go"

    local rule_block
    rule_block=$(cat <<EOF

$start_marker
if command -v iptables >/dev/null 2>&1; then
    iptables -t nat -C OUTPUT -d "${peer_alias_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}" >/dev/null 2>&1 || \
        iptables -t nat -A OUTPUT -d "${peer_alias_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}"
fi
$end_marker
EOF
)

    if grep -q '#BUDDYBACKUP_TESTLAB_POSTBOOT_REFRESH_BEGIN' "$tmp_go" 2>/dev/null; then
        awk -v rule="$rule_block" '
            $0 ~ /^#BUDDYBACKUP_TESTLAB_POSTBOOT_REFRESH_BEGIN/ {
                print rule
            }
            { print }
        ' "$tmp_go" > "${tmp_go}.2" && mv "${tmp_go}.2" "$tmp_go"
    else
        printf '%s\n' "$rule_block" >> "$tmp_go"
    fi

    mv "$tmp_go" "$go_file"
}

ensure_dataset_absent() {
    local dataset="$1"
    if zfs list -H -o name "$dataset" >/dev/null 2>&1; then
        zfs destroy -r "$dataset"
    fi
}

if command -v modprobe >/dev/null 2>&1; then
    modprobe zfs >/dev/null 2>&1 || true
fi

if command -v udevadm >/dev/null 2>&1; then
    udevadm settle >/dev/null 2>&1 || true
fi

mkdir -p "$plugin_root"
rm -f "$plugin_root/incoming.cfg"
rm -f "$plugin_root/buddybackup_known_hosts"
ensure_dataset_absent "$source_dataset"
ensure_dataset_absent "$local_backup_dataset"
ensure_dataset_absent "$receive_root_dataset"

mkdir -p "$(dirname "$source_mountpoint")"
zfs create -p -o mountpoint="$source_mountpoint" "$source_dataset"
zfs create -p -o mountpoint=none "$local_backup_dataset"
zfs create -p -o mountpoint=none "$receive_root_dataset"
printf 'node=%s\nstage=upgrade-preserves-config\n' "$node_name" > "$source_mountpoint/payload.txt"
sync || true

touch "$plugin_cfg"
set_ini_value "ReceiveBackups" "enable" "$plugin_cfg"
set_ini_value "ReceiveDestinationDataset" "$receive_root_dataset" "$plugin_cfg"
set_ini_value "DestinationPubSSHKey" "$peer_public_key" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionHourly" "4" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionDaily" "8" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionWeekly" "5" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionMonthly" "6" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionYearly" "2" "$plugin_cfg"
set_ini_value "BackupDaysAgoWarning" "5" "$plugin_cfg"
set_ini_value "BackupDaysAgoCritical" "11" "$plugin_cfg"
set_ini_value "BuddysBackupDaysAgoWarning" "9" "$plugin_cfg"
set_ini_value "BuddysBackupDaysAgoCritical" "19" "$plugin_cfg"
set_ini_value "UtcTimezone" "yes" "$plugin_cfg"
set_ini_value "AllowUnencryptedRemoteBackups" "$allow_unencrypted" "$plugin_cfg"

cat > "$backups_cfg" <<EOF
[${remote_uid}]
enable="yes"
source_dataset="${source_dataset}"
recursive="yes"
backup_cron="17 3 * * *"
type="remote"
destination_host="${remote_host}"
destination_dataset="${remote_destination_dataset}"

[${local_uid}]
enable="yes"
source_dataset="${source_dataset}"
recursive="no"
backup_cron="43 5 * * 1"
type="local"
destination_host=""
destination_dataset="${local_backup_dataset}"
EOF

cat > "$snapshots_cfg" <<EOF
[${snapshot_uid}]
dataset="${source_dataset}"
hourly="6"
daily="4"
weekly="3"
monthly="2"
yearly="1"
autosnap="yes"
autoprune="yes"
recursive="yes"
process_children_only="no"
trigger="${remote_uid}"
EOF

if [[ "$peer_port" != "22" ]]; then
    if ! command -v iptables >/dev/null 2>&1; then
        echo "iptables is unavailable, cannot map ${peer_alias_ip}:22 to ${host_gateway_ip}:${peer_port}" >&2
        exit 1
    fi

    iptables -t nat -C OUTPUT -d "${peer_alias_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}" >/dev/null 2>&1 || \
        iptables -t nat -A OUTPUT -d "${peer_alias_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}"
    persist_peer_forward_rule "$peer_alias_ip" "$host_gateway_ip" "$peer_port"
fi

/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update

known_hosts_file="$plugin_root/buddybackup_known_hosts"
scanned_keys=""
attempt_keys=""
# ssh-keyscan can return partial results or time out entirely while the peer is
# busy. Merge several scans (deduped by key material) and require the common key
# types so the seeded state stays stable.
for attempt in 1 2 3 4 5; do
    attempt_keys=$(ssh-keyscan -T 3 "$remote_host" 2>/dev/null || true)
    if [ -n "$attempt_keys" ]; then
        if [ -n "$scanned_keys" ]; then
            scanned_keys=$(printf '%s\n%s\n' "$scanned_keys" "$attempt_keys" | sed '/^[[:space:]]*$/d' | awk '
                /^[[:space:]]*#/ { if (!comment[$0]++) print; next }
                NF >= 3 { key = $2 " " $3; if (!material[key]++) print; next }
                { print }
            ')
        else
            scanned_keys=$(printf '%s\n' "$attempt_keys" | sed '/^[[:space:]]*$/d')
        fi

        if printf '%s\n' "$scanned_keys" | grep -q 'ssh-ed25519' && \
           printf '%s\n' "$scanned_keys" | grep -q 'ecdsa-sha2-nistp256' && \
           printf '%s\n' "$scanned_keys" | grep -q 'ssh-rsa'; then
            break
        fi
    fi

    if [ "$attempt" -lt 5 ]; then
        sleep 1
    fi
done

if [ -z "$scanned_keys" ]; then
    echo "ssh-keyscan returned no host keys for ${remote_host}; refusing to seed an empty managed known_hosts" >&2
    exit 1
fi

{
    printf '# buddybackup start\n'
    printf '%s\n' "$scanned_keys"
    printf '# buddybackup end\n'
} > "$known_hosts_file"
chmod 600 "$known_hosts_file"

echo "seeded_node=${node_name}"
echo "seeded_remote_host=${remote_host}"
echo "seeded_receive_root=${receive_root_dataset}"
'@

    return $script
}

function Get-UpgradeStateSummaryScript {
    $script = @'
set -euo pipefail

plugin_root="/boot/config/plugins/buddybackup"
plugin_cfg="$plugin_root/buddybackup.cfg"
incoming_cfg="$plugin_root/incoming.cfg"
backups_cfg="$plugin_root/backups.cfg"
snapshots_cfg="$plugin_root/snapshots.cfg"
managed_known_hosts="$plugin_root/buddybackup_known_hosts"
sender_key="$plugin_root/buddybackup_sender_key"
authorized_keys="/home/buddybackup/.ssh/authorized_keys"
sanoid_conf="$plugin_root/sanoid.conf"
sshd_config="/etc/ssh/sshd_config"
if [ -f /boot/config/ssh/sshd_config ]; then
    sshd_config="/boot/config/ssh/sshd_config"
fi

hash_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        sha256sum "$path" | awk '{print $1}'
    fi
}

known_hosts_key_material_hash_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        awk '
            /^[[:space:]]*$/ { next }
            /^[[:space:]]*#/ { next }
            NF >= 3 { print $2 " " $3 }
        ' "$path" | LC_ALL=C sort | sha256sum | awk '{print $1}'
    fi
}

authorized_keys_key_material_hash_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        awk '
            /^[[:space:]]*$/ { next }
            /^[[:space:]]*#/ { next }
            {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)/) {
                        print $i " " $(i+1)
                        break
                    }
                }
            }
        ' "$path" | LC_ALL=C sort | sha256sum | awk '{print $1}'
    fi
}

line_or_empty() {
    local key="$1"
    local path="$2"
    if [ -f "$path" ]; then
        awk -F= -v expected="$key" '$1==expected {print $0}' "$path" | tail -n 1
    fi
}

value_or_empty() {
    local key="$1"
    local path="$2"
    if [ -f "$path" ]; then
        awk -F= -v expected="$key" '
            $1==expected {
                value=$2
                gsub(/^[ \t]+|[ \t]+$/, "", value)
                gsub(/^"|"$/, "", value)
                print value
            }' "$path" | tail -n 1
    fi
}

values_or_empty() {
    local key="$1"
    local path="$2"
    if [ -f "$path" ]; then
        awk -F= -v expected="$key" '
            $1==expected {
                value=$2
                gsub(/^[ \t]+|[ \t]+$/, "", value)
                gsub(/^"|"$/, "", value)
                print value
            }' "$path" | LC_ALL=C sort -u | awk 'BEGIN { separator="" } { printf "%s%s", separator, $0; separator="," }'
    fi
}

emit_sections() {
    local path="$1"
    local label="$2"
    if [ -f "$path" ]; then
        awk '/^\[.*\]$/{gsub(/^\[|\]$/, "", $0); print}' "$path" | sort | while IFS= read -r value; do
            [ -n "$value" ] && echo "${label}=${value}"
        done
    fi
}

echo "plugin_cfg_sha256=$(hash_or_empty "$plugin_cfg")"
echo "backups_cfg_sha256=$(hash_or_empty "$backups_cfg")"
echo "snapshots_cfg_sha256=$(hash_or_empty "$snapshots_cfg")"
echo "sender_key_sha256=$(hash_or_empty "$sender_key")"
echo "known_hosts_sha256=$(hash_or_empty "$managed_known_hosts")"
echo "known_hosts_key_material_sha256=$(known_hosts_key_material_hash_or_empty "$managed_known_hosts")"
echo "authorized_keys_sha256=$(hash_or_empty "$authorized_keys")"
echo "authorized_keys_key_material_sha256=$(authorized_keys_key_material_hash_or_empty "$authorized_keys")"
echo "sanoid_conf_sha256=$(hash_or_empty "$sanoid_conf")"

for key in \
    ReceiveBackups \
    ReceiveDestinationDataset \
    ReceiveDestinationRententionHourly \
    ReceiveDestinationRententionDaily \
    ReceiveDestinationRententionWeekly \
    ReceiveDestinationRententionMonthly \
    ReceiveDestinationRententionYearly \
    BackupDaysAgoWarning \
    BackupDaysAgoCritical \
    BuddysBackupDaysAgoWarning \
    BuddysBackupDaysAgoCritical \
    UtcTimezone \
    AllowUnencryptedRemoteBackups; do
    line=$(line_or_empty "$key" "$plugin_cfg")
    if [ -n "$line" ]; then
        echo "plugin_cfg_line=$line"
    fi
done

for key in \
    BackupDaysAgoWarning \
    BackupDaysAgoCritical \
    BuddysBackupDaysAgoWarning \
    BuddysBackupDaysAgoCritical \
    UtcTimezone \
    AllowUnencryptedRemoteBackups; do
    line=$(line_or_empty "$key" "$plugin_cfg")
    if [ -n "$line" ]; then
        echo "general_plugin_cfg_line=$line"
    fi
done

incoming_cfg_present=no
if [ -f "$incoming_cfg" ]; then
    incoming_cfg_present=yes
fi
echo "incoming_cfg_present=$incoming_cfg_present"

# Receiver state moved from flat keys in buddybackup.cfg to incoming.cfg.
# Report the effective values so upgrades across that migration stay comparable.
receive_enable=""
receive_destinations=""
receive_ssh_key_count=0
if [ "$incoming_cfg_present" = "yes" ]; then
    receive_enable=$(value_or_empty enable "$incoming_cfg")
    receive_destinations=$(values_or_empty destination_dataset "$incoming_cfg")
    receive_ssh_key_count=$(awk -F= '
        $1=="ssh_key" {
            value=$2
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            gsub(/^"|"$/, "", value)
            if (value != "") count++
        }
        END { print count + 0 }
    ' "$incoming_cfg")
fi

if [ -z "$receive_enable" ]; then
    legacy_enable=$(value_or_empty ReceiveBackups "$plugin_cfg")
    if [ "$legacy_enable" = "enable" ]; then
        receive_enable="yes"
    elif [ -n "$legacy_enable" ]; then
        receive_enable="no"
    fi
fi
if [ -z "$receive_destinations" ]; then
    receive_destinations=$(values_or_empty ReceiveDestinationDataset "$plugin_cfg")
fi
if [ "$receive_ssh_key_count" -eq 0 ]; then
    receive_ssh_key_count=$(awk -F= '
        $1=="DestinationPubSSHKey" {
            value=$2
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            gsub(/^"|"$/, "", value)
            if (value != "") count++
        }
        END { print count + 0 }
    ' "$plugin_cfg")
fi

echo "receive_enable=$receive_enable"
echo "receive_destinations=$receive_destinations"
echo "receive_ssh_key_count=$receive_ssh_key_count"

emit_sections "$backups_cfg" "backup_section"
emit_sections "$snapshots_cfg" "snapshot_section"

shopt -s nullglob
backup_crons=("$plugin_root"/backup-*.cron)
shopt -u nullglob

for cron in "${backup_crons[@]}"; do
    basename "$cron"
done | sort | while IFS= read -r value; do
    [ -n "$value" ] && echo "backup_cron=$value"
done

known_hosts_lines=0
known_hosts_key_types=""
if [ -f "$managed_known_hosts" ]; then
    known_hosts_lines=$(grep -cve '^[[:space:]]*$' "$managed_known_hosts" || true)
    known_hosts_key_types=$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        NF >= 3 { print $2 }
    ' "$managed_known_hosts" | LC_ALL=C sort -u | awk 'BEGIN { separator="" } { printf "%s%s", separator, $0; separator="," }')
fi
echo "known_hosts_line_count=$known_hosts_lines"
echo "known_hosts_key_types=$known_hosts_key_types"

buddybackup_user_present=no
if id buddybackup >/dev/null 2>&1; then
    buddybackup_user_present=yes
fi
echo "buddybackup_user_present=$buddybackup_user_present"

allow_users_contains_buddybackup=no
if [ -f "$sshd_config" ] && grep -Eq '^AllowUsers .*buddybackup([[:space:]]|$)' "$sshd_config"; then
    allow_users_contains_buddybackup=yes
fi
echo "allow_users_contains_buddybackup=$allow_users_contains_buddybackup"

match_user_buddybackup=no
if [ -f "$sshd_config" ] && grep -Fq 'Match User buddybackup' "$sshd_config"; then
    match_user_buddybackup=yes
fi
echo "match_user_buddybackup=$match_user_buddybackup"

receive_dataset=""
if [ -f "$plugin_cfg" ]; then
    receive_dataset=$(awk -F= '$1=="ReceiveDestinationDataset" {value=$2; gsub(/^"|"$/, "", value); print value}' "$plugin_cfg" | tail -n 1)
fi
if [ -z "$receive_dataset" ] && [ -f "$plugin_root/incoming.cfg" ]; then
    receive_dataset=$(awk -F= '$1=="destination_dataset" {value=$2; gsub(/^"|"$/, "", value); print value}' "$plugin_root/incoming.cfg" | tail -n 1)
fi

sanoid_conf_contains_receive_dataset=no
if [ -n "$receive_dataset" ] && [ -f "$sanoid_conf" ] && grep -Fq "[$receive_dataset]" "$sanoid_conf"; then
    sanoid_conf_contains_receive_dataset=yes
fi
echo "sanoid_conf_contains_receive_dataset=$sanoid_conf_contains_receive_dataset"
'@

    return $script
}

function ConvertFrom-UpgradeStateOutput {
    param([string]$Output)

    $snapshot = [ordered]@{
        pluginCfgSha256                  = ""
        backupsCfgSha256                 = ""
        snapshotsCfgSha256               = ""
        senderKeySha256                  = ""
        knownHostsSha256                 = ""
        knownHostsKeyMaterialSha256      = ""
        knownHostsLineCount              = 0
        knownHostsKeyTypes               = @()
        authorizedKeysSha256             = ""
        authorizedKeysKeyMaterialSha256  = ""
        sanoidConfSha256                 = ""
        sanoidConfContainsReceiveDataset = "no"
        incomingCfgPresent               = "no"
        receiveEnable                    = ""
        receiveDestinations              = @()
        receiveSshKeyCount               = 0
        buddybackupUserPresent           = "no"
        allowUsersContainsBuddybackup    = "no"
        matchUserBuddybackup             = "no"
        pluginCfgLines                   = @()
        generalPluginCfgLines            = @()
        backupSections                   = @()
        snapshotSections                 = @()
        backupCrons                      = @()
    }

    $lines = @($Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($line in $lines) {
        $parts = $line -split '=', 2
        $name = [string]$parts[0]
        $value = if ($parts.Count -gt 1) { [string]$parts[1] } else { "" }

        switch ($name) {
            "plugin_cfg_sha256" { $snapshot.pluginCfgSha256 = $value }
            "backups_cfg_sha256" { $snapshot.backupsCfgSha256 = $value }
            "snapshots_cfg_sha256" { $snapshot.snapshotsCfgSha256 = $value }
            "sender_key_sha256" { $snapshot.senderKeySha256 = $value }
            "known_hosts_sha256" { $snapshot.knownHostsSha256 = $value }
            "known_hosts_key_material_sha256" { $snapshot.knownHostsKeyMaterialSha256 = $value }
            "known_hosts_line_count" { $snapshot.knownHostsLineCount = if ([string]::IsNullOrWhiteSpace($value)) { 0 } else { [int]$value } }
            "known_hosts_key_types" { $snapshot.knownHostsKeyTypes += @($value -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
            "authorized_keys_sha256" { $snapshot.authorizedKeysSha256 = $value }
            "authorized_keys_key_material_sha256" { $snapshot.authorizedKeysKeyMaterialSha256 = $value }
            "sanoid_conf_sha256" { $snapshot.sanoidConfSha256 = $value }
            "sanoid_conf_contains_receive_dataset" { $snapshot.sanoidConfContainsReceiveDataset = $value }
            "incoming_cfg_present" { $snapshot.incomingCfgPresent = $value }
            "receive_enable" { $snapshot.receiveEnable = $value }
            "receive_destinations" { $snapshot.receiveDestinations += @($value -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
            "receive_ssh_key_count" { $snapshot.receiveSshKeyCount = if ([string]::IsNullOrWhiteSpace($value)) { 0 } else { [int]$value } }
            "buddybackup_user_present" { $snapshot.buddybackupUserPresent = $value }
            "allow_users_contains_buddybackup" { $snapshot.allowUsersContainsBuddybackup = $value }
            "match_user_buddybackup" { $snapshot.matchUserBuddybackup = $value }
            "plugin_cfg_line" { $snapshot.pluginCfgLines += $value }
            "general_plugin_cfg_line" { $snapshot.generalPluginCfgLines += $value }
            "backup_section" { $snapshot.backupSections += $value }
            "snapshot_section" { $snapshot.snapshotSections += $value }
            "backup_cron" { $snapshot.backupCrons += $value }
        }
    }

    $snapshot.pluginCfgLines = @($snapshot.pluginCfgLines | Sort-Object -Unique)
    $snapshot.generalPluginCfgLines = @($snapshot.generalPluginCfgLines | Sort-Object -Unique)
    $snapshot.backupSections = @($snapshot.backupSections | Sort-Object -Unique)
    $snapshot.snapshotSections = @($snapshot.snapshotSections | Sort-Object -Unique)
    $snapshot.backupCrons = @($snapshot.backupCrons | Sort-Object -Unique)
    $snapshot.knownHostsKeyTypes = @($snapshot.knownHostsKeyTypes | Sort-Object -Unique)
    $snapshot.receiveDestinations = @($snapshot.receiveDestinations | Sort-Object -Unique)

    return [pscustomobject]$snapshot
}

function Get-UpgradeStateSnapshot {
    param(
        [string]$NodeName,
        $NodeConnection,
        [switch]$DoExecute
    )

    $script = Get-UpgradeStateSummaryScript
    $command = Convert-ToRemoteBashScriptCommand -Script $script -Arguments @()
    $maxSnapshotAttempts = 6
    $attempts = @()
    $result = $null

    for ($snapshotAttempt = 1; $snapshotAttempt -le $maxSnapshotAttempts; $snapshotAttempt++) {
        $result = Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $command -LoggedCommand "capture BuddyBackup upgrade state summary" -Label "${NodeName}-upgrade-state-snapshot" -DoExecute:$DoExecute
        $attempts += $result
        if ($result.Success) {
            break
        }

        if ($DoExecute -and $snapshotAttempt -lt $maxSnapshotAttempts) {
            Start-Sleep -Seconds 5
        }
    }

    if ($result) {
        $result = New-RetrySummaryResult -Result $result -Attempts $attempts
    }

    return [pscustomobject]@{
        Result   = $result
        Snapshot = if ($result.Success -and $DoExecute) { ConvertFrom-UpgradeStateOutput -Output $result.Output } elseif (-not $DoExecute) { [pscustomobject]@{ dryRun = $true } } else { $null }
    }
}

function Test-UpgradeStateSnapshot {
    param(
        [string]$NodeName,
        $Snapshot,
        $Plan,
        [string]$AllowUnencryptedRemoteBackups
    )

    $errors = @()
    if ([string]::IsNullOrWhiteSpace([string]$Snapshot.pluginCfgSha256)) {
        $errors += "plugin cfg hash is missing"
    }
    if ([string]::IsNullOrWhiteSpace([string]$Snapshot.backupsCfgSha256)) {
        $errors += "backups cfg hash is missing"
    }
    if ([string]::IsNullOrWhiteSpace([string]$Snapshot.snapshotsCfgSha256)) {
        $errors += "snapshots cfg hash is missing"
    }
    if ([string]::IsNullOrWhiteSpace([string]$Snapshot.senderKeySha256)) {
        $errors += "sender key hash is missing"
    }
    if ($Snapshot.buddybackupUserPresent -ne "yes") {
        $errors += "buddybackup user is missing"
    }
    if ($Snapshot.allowUsersContainsBuddybackup -ne "yes") {
        $errors += "sshd_config AllowUsers does not include buddybackup"
    }
    if ($Snapshot.matchUserBuddybackup -ne "yes") {
        $errors += "sshd_config Match User buddybackup block is missing"
    }
    if ($Snapshot.sanoidConfContainsReceiveDataset -ne "yes") {
        $errors += "sanoid.conf does not contain the receive dataset"
    }

    $expectedPluginLines = @(
        'UtcTimezone="yes"',
        ('AllowUnencryptedRemoteBackups="{0}"' -f $AllowUnencryptedRemoteBackups)
    )
    foreach ($expectedLine in $expectedPluginLines) {
        if ($Snapshot.pluginCfgLines -notcontains $expectedLine) {
            $errors += "missing plugin cfg line $expectedLine"
        }
    }

    if ($Snapshot.receiveEnable -ne "yes") {
        $errors += "receiver mode is not enabled (receive_enable=$($Snapshot.receiveEnable))"
    }
    if (@($Snapshot.receiveDestinations) -notcontains $Plan.ReceiveRootDataset) {
        $errors += "receiver destination dataset $($Plan.ReceiveRootDataset) is missing"
    }
    if ([int]$Snapshot.receiveSshKeyCount -lt 1) {
        $errors += "receiver buddy SSH key is missing"
    }
    if (@($Snapshot.knownHostsKeyTypes).Count -eq 0) {
        $errors += "managed known_hosts contains no host keys"
    }

    foreach ($expectedSection in @($Plan.RemoteBackupUid, $Plan.LocalBackupUid)) {
        if ($Snapshot.backupSections -notcontains $expectedSection) {
            $errors += "missing backup section $expectedSection"
        }
    }
    if ($Snapshot.snapshotSections -notcontains $Plan.SnapshotUid) {
        $errors += "missing snapshot section $($Plan.SnapshotUid)"
    }

    foreach ($expectedCron in @("backup-$($Plan.RemoteBackupUid).cron", "backup-$($Plan.LocalBackupUid).cron")) {
        if ($Snapshot.backupCrons -notcontains $expectedCron) {
            $errors += "missing cron file $expectedCron"
        }
    }

    return [pscustomobject]@{
        Success = ($errors.Count -eq 0)
        Error   = if ($errors.Count -eq 0) { $null } else { $errors -join '; ' }
    }
}

function Compare-UpgradeStateSnapshots {
    param(
        [string]$NodeName,
        $Before,
        $After
    )

    $differences = @()
    $properties = @(
        'backupsCfgSha256',
        'snapshotsCfgSha256',
        'senderKeySha256',
        'knownHostsKeyTypes',
        'authorizedKeysKeyMaterialSha256',
        'sanoidConfContainsReceiveDataset',
        'receiveEnable',
        'receiveDestinations',
        'receiveSshKeyCount',
        'buddybackupUserPresent',
        'allowUsersContainsBuddybackup',
        'matchUserBuddybackup',
        'generalPluginCfgLines',
        'backupSections',
        'snapshotSections',
        'backupCrons'
    )

    foreach ($propertyName in $properties) {
        $beforeValue = $Before.$propertyName
        $afterValue = $After.$propertyName

        if ($propertyName -eq 'knownHostsKeyTypes') {
            $missingTypes = @(@($beforeValue) | Where-Object { $_ -and (@($afterValue) -notcontains $_) })
            if ($missingTypes.Count -gt 0) {
                $differences += "knownHostsKeyTypes: missing in after state: $($missingTypes -join ', ')"
            }
            continue
        }

        if ($beforeValue -is [System.Array] -or $afterValue -is [System.Array]) {
            $beforeText = (@($beforeValue) | Sort-Object) -join ', '
            $afterText = (@($afterValue) | Sort-Object) -join ', '
            if ($beforeText -ne $afterText) {
                $differences += "${propertyName}: before=[$beforeText] after=[$afterText]"
            }
            continue
        }

        $beforeText = [string]$beforeValue
        $afterText = [string]$afterValue
        if ($beforeText -ne $afterText) {
            $differences += "${propertyName}: before=[$beforeText] after=[$afterText]"
        }
    }

    return [pscustomobject]@{
        Success = ($differences.Count -eq 0)
        Error   = if ($differences.Count -eq 0) { $null } else { $differences -join '; ' }
    }
}
