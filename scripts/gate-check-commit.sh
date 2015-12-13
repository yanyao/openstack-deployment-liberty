#!/usr/bin/env bash
# Copyright 2014, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## Shell Opts ----------------------------------------------------------------
set -e -u -x

## Variables -----------------------------------------------------------------
export ANSIBLE_PARAMETERS=${ANSIBLE_PARAMETERS:-"-v"}
export MAX_RETRIES=${MAX_RETRIES:-"2"}
# tempest and testr options, default is to run tempest in serial
export RUN_TEMPEST_OPTS=${RUN_TEMPEST_OPTS:-'--serial'}
export TESTR_OPTS=${TESTR_OPTS:-''}
# Disable the python output buffering so that jenkins gets the output properly
export PYTHONUNBUFFERED=1
# Extra options to pass to the AIO bootstrap process
export BOOTSTRAP_OPTS=${BOOTSTRAP_OPTS:-''}

## Functions -----------------------------------------------------------------
info_block "Checking for required libraries." 2> /dev/null || source $(dirname ${0})/scripts-library.sh

## Main ----------------------------------------------------------------------

# Log some data about the instance and the rest of the system
log_instance_info

# Determine the largest secondary disk device available for repartitioning
DATA_DISK_DEVICE=$(lsblk -brndo NAME,TYPE,RO,SIZE | \
                   awk '/d[b-z]+ disk 0/{ if ($4>m){m=$4; d=$1}}; END{print d}')

# Only set the secondary disk device option if there is one
if [ -n "${DATA_DISK_DEVICE}" ]; then
  export BOOTSTRAP_OPTS="${BOOTSTRAP_OPTS} bootstrap_host_data_disk_device=${DATA_DISK_DEVICE}"
fi

# Bootstrap Ansible
source $(dirname ${0})/bootstrap-ansible.sh

# Log some data about the instance and the rest of the system
log_instance_info

# Flush all the iptables rules set by openstack-infra
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Adjust settings based on the Cloud Provider info in OpenStack-CI
if [ -f /etc/nodepool/provider -a -s /etc/nodepool/provider ]; then
  source /etc/nodepool/provider

  if [[ ${NODEPOOL_PROVIDER} == "rax"* ]]; then

    # Set the Ubuntu Repository for the AIO to the RAX Mirror
    export BOOTSTRAP_OPTS="${BOOTSTRAP_OPTS} bootstrap_host_ubuntu_repo=http://mirror.rackspace.com/ubuntu"
    export BOOTSTRAP_OPTS="${BOOTSTRAP_OPTS} bootstrap_host_ubuntu_security_repo=http://mirror.rackspace.com/ubuntu"

  elif [[ ${NODEPOOL_PROVIDER} == "hpcloud"* ]]; then

    # Set the Ubuntu Repository for the AIO to the HP Cloud Mirror
    export BOOTSTRAP_OPTS="${BOOTSTRAP_OPTS} bootstrap_host_ubuntu_repo=http://${NODEPOOL_AZ}.clouds.archive.ubuntu.com/ubuntu"
    export BOOTSTRAP_OPTS="${BOOTSTRAP_OPTS} bootstrap_host_ubuntu_security_repo=http://${NODEPOOL_AZ}.clouds.archive.ubuntu.com/ubuntu"

  fi
fi

# Bootstrap an AIO
pushd $(dirname ${0})/../tests
  sed -i '/\[defaults\]/a nocolor = 1/' ansible.cfg
  ansible-playbook -i "localhost ansible-connection=local," \
                   -e "${BOOTSTRAP_OPTS}" \
                   ${ANSIBLE_PARAMETERS} \
                   bootstrap-aio.yml
popd

# Implement the log directory link for openstack-infra log publishing
mkdir -p /openstack/log
ln -sf /openstack/log $(dirname ${0})/../logs

pushd $(dirname ${0})/../playbooks
  # Disable Ansible color output
  sed -i 's/nocolor.*/nocolor = 1/' ansible.cfg

  # Create ansible logging directory and add in a log file entry into ansible.cfg
  mkdir -p /openstack/log/ansible-logging
  sed -i '/\[defaults\]/a log_path = /openstack/log/ansible-logging/ansible.log' ansible.cfg

  # Enable detailed task profiling
  sed -i '/\[defaults\]/a callback_plugins = plugins/callbacks' ansible.cfg
popd

# Log some data about the instance and the rest of the system
log_instance_info

# Execute the Playbooks
bash $(dirname ${0})/run-playbooks.sh

# Log some data about the instance and the rest of the system
log_instance_info

# Run the tempest tests
source $(dirname ${0})/run-tempest.sh

# Log some data about the instance and the rest of the system
log_instance_info

exit_success
