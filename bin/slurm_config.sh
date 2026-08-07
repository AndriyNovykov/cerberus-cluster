#!/bin/bash
#
# Regenerate Slurm Config
#
# Add --initial as argument if you need to restart slurm from scratch (Removes the current topology file)

scripts=`realpath $0`
folder=`dirname $scripts`
conf_folder=$folder/../conf/
playbooks_path=$folder/../playbooks/

if [[ ${@: -1} == "--INITIAL" || ${@: -1} == "--initial" || ${@: -1} == "-INITIAL" || ${@: -1} == "-initial" ]]
then
   sudo rm /etc/slurm/topology.conf
   sudo /usr/sbin/slurmctld -c
fi
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook $playbooks_path/slurm_config.yml
