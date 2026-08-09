#!/bin/sh
# Run the GPU healthcheck prolog on any node with an NVIDIA driver loaded
if [ -e /dev/nvidia0 ]
then
    sudo python3 /opt/lucid-hpc/healthchecks/check_gpu_setup.py --slurm > /tmp/latest_healthcheck.log 2>&1
    DRAIN_MSG=`cat /tmp/latest_healthcheck.log | grep "Healthcheck::"`
    if [ "$DRAIN_MSG" != "" ]
    then
       if [ -n "$SLURM_JOB_ID" ]; then
         echo "${DRAIN_MSG}"
	       exit 1
       else
	       scontrol update nodename=`hostname` state=drain reason="${DRAIN_MSG}"
       fi
    fi
fi
