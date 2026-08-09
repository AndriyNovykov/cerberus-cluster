#!/bin/bash

# Variables (Replace these with actual values or pass them as arguments)
lab_name='' # john_smith
cluster_username='' # john_smith
full_name='' # John Smith
user_password=''
parent_account=''
ssh_key=''
quota_gb='500' # per-user /clusterhome quota (CephFS only)

# Function to exit script upon error
function error_exit {
    echo "$1" 1>&2
    exit 1
}

# Check if cluster command is available
cluster || error_exit "Cluster command is not available."

# Check if lab exists on the cluster
if cluster group list | grep -w "$lab_name"; then
    echo "Lab already exists. Moving on to researcher onboarding."
else
    # Lab Onboarding
    echo "Onboarding new lab: $lab_name"
    # Add the lab group
    cluster group create "$lab_name" || error_exit "Failed to create lab group: $lab_name"
    # Add slurm lab account
    sudo sacctmgr add account --immediate "$lab_name" Parent="$parent_account" Description="$lab_name Lab" Organization=Prof_"$lab_name" || error_exit "Failed to add Slurm lab account for: $lab_name"
fi

# Researcher Onboarding
echo "Onboarding new researcher: $cluster_username"

# Retrieve the lab group id
group_id=$(cluster group list | grep -wA1 "$lab_name" | grep gidNumber | awk '{print $2}')
# Create cluster user
cluster user add "$cluster_username" --gid "$group_id" --password "$user_password" --name "$full_name" || error_exit "Failed to add cluster user: $cluster_username"
# Create Slurm user
sudo sacctmgr create user --immediate "$cluster_username" DefaultAccount="$lab_name" || error_exit "Failed to create Slurm user for: $cluster_username"
# Add SSH key
echo "$ssh_key" | sudo tee -a /clusterhome/$cluster_username/.ssh/authorized_keys
# Set the home quota (CephFS homes only; needs setfattr from the 'attr'
# package and the 'p' MDS cap on the client key — ceph-pools authorizes rwp.
# NOTE: mounts opened before a cap change keep their old session caps; a
# remount/reboot picks up rwp on clusters authorized before 2026-08-09.)
if [ "$(findmnt -n -o FSTYPE /clusterhome 2>/dev/null)" = "ceph" ]; then
    if command -v setfattr >/dev/null; then
        sudo setfattr -n ceph.quota.max_bytes -v $((quota_gb*1024*1024*1024)) "/clusterhome/$cluster_username" \
            && echo "Set ${quota_gb}G quota on /clusterhome/$cluster_username" \
            || echo "WARNING: quota not set (does the mount session have the MDS 'p' cap?)" 1>&2
    else
        echo "WARNING: setfattr not found (apt install attr); quota not set" 1>&2
    fi
fi

echo "Onboarding process completed for $cluster_username."
