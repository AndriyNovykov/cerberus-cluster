#!/bin/bash
#
# Controller bootstrap script (on-prem, Ubuntu 24.04).
# Installs Ansible and prepares /etc/ansible on the controller node.
# Run once as the admin user (ubuntu) after the OS install, before configure.sh.
#

set -o pipefail

source /etc/os-release
if [ "$ID" != "ubuntu" ]; then
  echo "This script supports Ubuntu only (found: $ID)" 1>&2
  exit 1
fi

# checking here as well to be sure that the lock file is not being held
function fix_apt {
  apt_process=`ps aux | grep "apt update" | grep -v grep | wc -l`
  apt_process=$(( apt_process -1 ))
  while [ $apt_process -ge 1 ]
    do
      echo "wait until apt update is done"
      sleep 10s
      ps aux | grep "apt update" | grep -v grep
      apt_process=`ps aux | grep "apt update" | grep -v grep | wc -l`
      apt_process=$(( apt_process -1 ))
    done
}
fix_apt

# Unattended upgrades fight with Ansible apt runs and can restart services mid-deploy
sudo sed -i 's/"1"/"0"/g' /etc/apt/apt.conf.d/20auto-upgrades
sudo apt purge -y --auto-remove unattended-upgrades
sudo systemctl disable apt-daily-upgrade.timer
sudo systemctl mask apt-daily-upgrade.service
sudo systemctl disable apt-daily.timer
sudo systemctl mask apt-daily.service

# Never prompt for service restarts during playbook runs
if [ -f /etc/needrestart/needrestart.conf ]; then
  sudo sed -i 's/#$nrconf{restart} = '"'"'i'"'"';/$nrconf{restart} = '"'"'a'"'"';/g' /etc/needrestart/needrestart.conf
fi

fix_apt
sudo apt-get update
sudo apt-get -y install ansible python3 python3-netaddr python3-pip git
fix_apt

ansible-galaxy collection install ansible.netcommon --force > /dev/null
ansible-galaxy collection install community.general --force > /dev/null
ansible-galaxy collection install ansible.posix --force > /dev/null
ansible-galaxy collection install community.crypto --force > /dev/null

threads=$(nproc)
forks=$(($threads * 8))

if [ ! -d /etc/ansible ] ; then
  sudo mkdir /etc/ansible
  sudo chown ubuntu:ubuntu /etc/ansible
fi

ansible-config init --disabled -t all | sudo tee /etc/ansible/ansible.cfg > /dev/null
sudo sed -i "s/^\(#\|;\)forks.*/forks = ${forks}/" /etc/ansible/ansible.cfg
sudo sed -i "s/^\(#\|;\)fact_caching=.*/fact_caching=jsonfile/" /etc/ansible/ansible.cfg
sudo sed -i "0,/^\(#\|;\)fact_caching_connection.*/s//fact_caching_connection=\/tmp\/ansible/" /etc/ansible/ansible.cfg
sudo sed -i "s/^\(#\|;\)bin_ansible_callbacks.*/bin_ansible_callbacks=True/" /etc/ansible/ansible.cfg
# yaml callback was removed from community.general 12 / ansible-core 2.19;
# the built-in default callback renders yaml via result_format
sudo sed -i "s/^\(#\|;\)stdout_callback.*/stdout_callback=default/" /etc/ansible/ansible.cfg
sudo sed -i "s/^\(#\|;\)result_format.*/result_format=yaml/" /etc/ansible/ansible.cfg
sudo sed -i "s/^\(#\|;\)retries.*/retries=5/" /etc/ansible/ansible.cfg
sudo sed -i "s/^\(#\|;\)connect_timeout.*/connect_timeout=300/" /etc/ansible/ansible.cfg
sudo sed -i "s/^\(#\|;\)command_timeout.*/command_timeout=120/" /etc/ansible/ansible.cfg

if [ ! -f ~/.ssh/cluster.key ]; then
  echo
  echo "NOTE: ~/.ssh/cluster.key not found. Generate the cluster admin key with:"
  echo "  ssh-keygen -t ed25519 -N '' -f ~/.ssh/cluster.key"
  echo "and add cluster.key.pub to authorized_keys on every node (including this one)."
fi
