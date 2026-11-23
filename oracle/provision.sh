#!/bin/sh
# Creates the server in Oracle Cloud using Always Free resources only:
# one VM.Standard.A1.Flex instance (Ampere, arm64), a public subnet with SSH, HTTP and HTTPS
# open, and a budget alert that emails at the first cent of spending. Safe to run again:
# whatever already exists is reused.
#
# Before the first run:  oci session authenticate --profile-name training-collector --region <home region>
# Run:  ALERT_EMAIL=you@example.com oracle/provision.sh
set -eu

: "${ALERT_EMAIL:?Set ALERT_EMAIL: the budget alert goes there}"
OCPUS=${OCPUS:-2}            # Always Free: up to 4 OCPUs on A1 in total
MEMORY_GB=${MEMORY_GB:-12}   # Always Free: up to 24 GB on A1 in total
BOOT_GB=${BOOT_GB:-50}       # Always Free: up to 200 GB of block storage in total
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519.pub}
export OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-training-collector}"
export OCI_CLI_AUTH="${OCI_CLI_AUTH:-security_token}"
NAME=training-collector
here=$(cd "$(dirname "$0")" && pwd)
state="$here/.state"
mkdir -p "$state"

say() { printf '\n== %s\n' "$*"; }
q() { oci "$@" --raw-output; }

[ -f "$SSH_PUBLIC_KEY" ] || { echo "No SSH public key at $SSH_PUBLIC_KEY; set SSH_PUBLIC_KEY" >&2; exit 1; }
if [ "$OCPUS" -gt 4 ] || [ "$MEMORY_GB" -gt 24 ] || [ "$BOOT_GB" -lt 47 ] || [ "$BOOT_GB" -gt 200 ]; then
    echo "Requested size is outside the Always Free limits" >&2; exit 1
fi

tenancy=$(awk -v p="[$OCI_CLI_PROFILE]" '$0 == p { s = 1; next } /^\[/ { s = 0 } s && /^tenancy *=/ { sub(/^tenancy *= */, ""); print }' "$HOME/.oci/config")
[ -n "$tenancy" ] || { echo "No tenancy in profile $OCI_CLI_PROFILE of ~/.oci/config" >&2; exit 1; }

say "Free tier usage of A1 instances already in the tenancy"
used_ocpus=0; used_memory=0
for id in $(q search resource structured-search --query-text "query instance resources where lifeCycleState = 'RUNNING' || lifeCycleState = 'STOPPED'" --query 'data.items[*].identifier' | tr -d '[]",'); do
    shape=$(q compute instance get --instance-id "$id" --query 'data.shape')
    [ "$shape" = "VM.Standard.A1.Flex" ] || { echo "An instance of shape $shape exists; check that it is Always Free"; continue; }
    [ "$(q compute instance get --instance-id "$id" --query 'data."display-name"')" = "$NAME" ] && continue
    used_ocpus=$((used_ocpus + $(q compute instance get --instance-id "$id" --query 'data."shape-config".ocpus' | cut -d. -f1)))
    used_memory=$((used_memory + $(q compute instance get --instance-id "$id" --query 'data."shape-config"."memory-in-gbs"' | cut -d. -f1)))
done
echo "Other A1 instances use $used_ocpus OCPU and $used_memory GB"
if [ $((used_ocpus + OCPUS)) -gt 4 ] || [ $((used_memory + MEMORY_GB)) -gt 24 ]; then
    echo "This instance would exceed the Always Free A1 limits" >&2; exit 1
fi

say "Compartment"
compartment=$(q iam compartment list --compartment-id "$tenancy" --name "$NAME" --lifecycle-state ACTIVE --query 'data[0].id' 2>/dev/null || true)
if [ -z "$compartment" ] || [ "$compartment" = "None" ]; then
    compartment=$(q iam compartment create --compartment-id "$tenancy" --name "$NAME" \
        --description "Training Collector" --wait-for-state ACTIVE --query 'data.id')
    sleep 20 # A new compartment takes a moment to become usable everywhere.
fi
echo "$compartment"

say "Network"
vcn=$(q network vcn list --compartment-id "$compartment" --display-name "$NAME" --query 'data[0].id' 2>/dev/null || true)
if [ -z "$vcn" ] || [ "$vcn" = "None" ]; then
    vcn=$(q network vcn create --compartment-id "$compartment" --display-name "$NAME" --cidr-blocks '["10.0.0.0/16"]' \
        --dns-label tc --wait-for-state AVAILABLE --query 'data.id')
fi
gateway=$(q network internet-gateway list --compartment-id "$compartment" --vcn-id "$vcn" --query 'data[0].id' 2>/dev/null || true)
if [ -z "$gateway" ] || [ "$gateway" = "None" ]; then
    gateway=$(q network internet-gateway create --compartment-id "$compartment" --vcn-id "$vcn" --is-enabled true \
        --display-name "$NAME" --wait-for-state AVAILABLE --query 'data.id')
fi
routes=$(q network vcn get --vcn-id "$vcn" --query 'data."default-route-table-id"')
oci network route-table update --rt-id "$routes" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$gateway\"}]" > /dev/null
rules=$(q network vcn get --vcn-id "$vcn" --query 'data."default-security-list-id"')
tcp() { printf '{"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":%s,"max":%s}}}' "$1" "$1"; }
oci network security-list update --security-list-id "$rules" --force \
    --ingress-security-rules "[$(tcp 22),$(tcp 80),$(tcp 443),{\"source\":\"0.0.0.0/0\",\"protocol\":\"1\",\"isStateless\":false,\"icmpOptions\":{\"type\":3,\"code\":4}}]" \
    --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' > /dev/null
subnet=$(q network subnet list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$NAME" --query 'data[0].id' 2>/dev/null || true)
if [ -z "$subnet" ] || [ "$subnet" = "None" ]; then
    subnet=$(q network subnet create --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$NAME" \
        --cidr-block 10.0.0.0/24 --dns-label public --route-table-id "$routes" --security-list-ids "[\"$rules\"]" \
        --wait-for-state AVAILABLE --query 'data.id')
fi
echo "subnet $subnet"

say "Deploy key for GitHub Actions"
[ -f "$state/deploy_key" ] || ssh-keygen -q -t ed25519 -N '' -C "github-actions-deploy" -f "$state/deploy_key"
sed "s|__DEPLOY_PUBLIC_KEY__|$(cat "$state/deploy_key.pub")|" "$here/cloud-init.yaml" > "$state/cloud-init.yaml"

say "Instance"
instance=$(q compute instance list --compartment-id "$compartment" --display-name "$NAME" --lifecycle-state RUNNING --query 'data[0].id' 2>/dev/null || true)
if [ -z "$instance" ] || [ "$instance" = "None" ]; then
    image=$(q compute image list --compartment-id "$compartment" --operating-system "Canonical Ubuntu" \
        --operating-system-version "24.04" --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC \
        --limit 1 --query 'data[0].id')
    # A1 capacity is often short; every availability domain is tried in turn.
    for zone in $(q iam availability-domain list --compartment-id "$tenancy" --query 'data[*].name' | tr -d '[]",'); do
        echo "Trying $zone"
        instance=$(q compute instance launch --availability-domain "$zone" --compartment-id "$compartment" \
            --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
            --image-id "$image" --subnet-id "$subnet" --assign-public-ip true --display-name "$NAME" \
            --hostname-label server --boot-volume-size-in-gbs "$BOOT_GB" \
            --ssh-authorized-keys-file "$SSH_PUBLIC_KEY" --user-data-file "$state/cloud-init.yaml" \
            --wait-for-state RUNNING --max-wait-seconds 900 --query 'data.id' 2>"$state/launch.log") && break
        grep -qi "capacity" "$state/launch.log" || { cat "$state/launch.log" >&2; exit 1; }
        instance=""
    done
    [ -n "$instance" ] || { echo "No A1 capacity in any availability domain now; run again later" >&2; exit 1; }
fi
ip=$(q compute instance list-vnics --instance-id "$instance" --query 'data[0]."public-ip"')
echo "$ip" > "$state/ip"
echo "Instance $instance at $ip"

say "Budget alert at the first cent"
budget=$(q budgets budget list --compartment-id "$tenancy" --query "data[?\"display-name\"=='$NAME'].id | [0]" 2>/dev/null || true)
if [ -z "$budget" ] || [ "$budget" = "None" ]; then
    budget=$(q budgets budget create --compartment-id "$tenancy" --display-name "$NAME" --amount 1 \
        --reset-period MONTHLY --target-type COMPARTMENT --targets "[\"$tenancy\"]" --query 'data.id')
    oci budgets alert-rule create --budget-id "$budget" --type ACTUAL --threshold 1 --threshold-type PERCENTAGE \
        --recipients "$ALERT_EMAIL" --display-name "$NAME" \
        --message "Training Collector: Oracle Cloud has started charging. Check the resources." > /dev/null
fi
echo "$budget"

say "Done"
echo "Server: ubuntu@$ip (first boot installs Docker; give it 5 minutes)"
echo "Deploy key for GitHub: $state/deploy_key"
