#!/bin/bash
#
# Cluster configuration script.
# Runs the full site.yml (or a given playbook) against /etc/ansible/hosts.
#
# Usage: configure.sh [playbook] [inventory]
#

if [ -n "$1" ]; then
  playbook=$1
else
  playbook="/opt/lucid-hpc/playbooks/site.yml"
fi

if [ -n "$2" ]; then
  inventory=$2
else
  inventory="/etc/ansible/hosts"
fi

if [ ! -f "$inventory" ]; then
  echo "Inventory $inventory not found. Copy samples/inventory.example to /etc/ansible/hosts and edit it." 1>&2
  exit 1
fi

username=`cat $inventory | grep compute_username= | tail -n 1| awk -F "=" '{print $2}'`
if [ "$username" == "" ]
then
username=$USER
fi

# Wait for every inventory host to be reachable over SSH before configuring
# (skip commented-out host lines)
grep -vE '^[[:space:]]*#' $inventory | grep -oE 'ansible_host=[^ ]+' | awk -F "=" '{print $2}' | sort -u > /tmp/hosts
/opt/lucid-hpc/bin/wait_for_hosts.sh /tmp/hosts $username

#
# Ansible will take care of key exchange and learning the host fingerprints, but for the first time we need
# to disable host key checking.
#
ANSIBLE_HOST_KEY_CHECKING=False ansible --private-key ~/.ssh/cluster.key all -m setup --tree /tmp/ansible > /dev/null 2>&1
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook --private-key ~/.ssh/cluster.key $playbook -i $inventory
