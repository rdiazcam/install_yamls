#!/bin/bash
#
# Copyright 2023 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
set -ex

# expect that the common.sh is in the same dir as the calling script
SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. ${SCRIPTPATH}/common.sh --source-only

if [ -z "$NAMESPACE" ]; then
    echo "Please set NAMESPACE"; exit 1
fi

if [ -z "$DEPLOY_DIR" ]; then
    echo "Please set DEPLOY_DIR"; exit 1
fi

if [ -z "$EDPM_BMH_NAMESPACE" ]; then
    echo "Please set EDPM_BMH_NAMESPACE"; exit 1
fi

if [ ! -d ${DEPLOY_DIR} ]; then
    mkdir -p ${DEPLOY_DIR}
fi

pushd ${DEPLOY_DIR}

cat <<EOF >kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
namespace: ${NAMESPACE}
patches:
- target:
    kind: ${KIND}
  patch: |-
    - op: add
      path: /spec/baremetalSetTemplate/bmhNamespace
      value: ${EDPM_BMH_NAMESPACE}
    - op: add
      path: /spec/services/0
      value: repo-setup
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/timesync_ntp_servers
      value:
        - {hostname: ${EDPM_NTP_SERVER}}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/registry_url
      value: ${EDPM_REGISTRY_URL}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/image_tag
      value: ${EDPM_CONTAINER_TAG}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/image_prefix
      value: ${EDPM_CONTAINER_PREFIX}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_sshd_allowed_ranges
      value: ${EDPM_SSHD_ALLOWED_RANGES}
    - op: replace
      path: /spec/nodeTemplate/ansibleSSHPrivateKeySecret
      value: ${EDPM_ANSIBLE_SECRET}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleUser
      value: ${EDPM_ANSIBLE_USER:-"cloud-admin"}
    - op: replace
      path: /spec/baremetalSetTemplate/cloudUserName
      value: ${EDPM_ANSIBLE_USER:-"cloud-admin"}

EOF

if [ "$EDPM_GROWVOLS_ARGS" != "" ]; then
cat <<EOF >>kustomization.yaml
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/growvols_args
      value: '${EDPM_GROWVOLS_ARGS}'
EOF
fi
if [ "$EDPM_ROOT_PASSWORD" != "" ]; then
cat <<EOF >>kustomization.yaml
    - op: add
      path: /spec/baremetalSetTemplate/passwordSecret
      value:
        name: baremetalset-password-secret
        namespace: ${NAMESPACE}
EOF
fi
if [ "$EDPM_PROVISIONING_INTERFACE" != "" ]; then
cat <<EOF >>kustomization.yaml
    - op: add
      path: /spec/baremetalSetTemplate/provisioningInterface
      value: ${EDPM_PROVISIONING_INTERFACE}
EOF
fi
if [ "$EDPM_OS_CONTAINER_IMG" != "" ]; then
cat <<EOF >>kustomization.yaml
    - op: add
      path: /spec/baremetalSetTemplate/osContainerImageUrl
      value: ${EDPM_OS_CONTAINER_IMG}
EOF
fi
if [ "$EDPM_CTLPLANE_INTERFACE" != "" ]; then
cat <<EOF >>kustomization.yaml
    - op: replace
      path: /spec/baremetalSetTemplate/ctlplaneInterface
      value: ${EDPM_CTLPLANE_INTERFACE}
EOF
fi
if [ "$EDPM_TOTAL_NODES" -gt 1 ]; then
    for INDEX in $(seq 1 $((${EDPM_TOTAL_NODES} -1))) ; do
cat <<EOF >>kustomization.yaml
    - op: copy
      from: /spec/nodes/edpm-compute-0
      path: /spec/nodes/edpm-compute-${INDEX}
    - op: replace
      path: /spec/nodes/edpm-compute-${INDEX}/hostName
      value: edpm-compute-${INDEX}
EOF
    done
fi

if [ "${EDPM_SERVER_ROLE}" == "compute" ]; then
# Create a nova-custom service with a reference to nova-extra-config CM
cat <<EOF >>kustomization.yaml
- target:
    kind: OpenStackDataPlaneService
    name: nova
  patch: |-
    - op: replace
      path: /metadata/name
      value: nova-custom
    - op: add
      path: /spec/configMaps
      value:
        - nova-extra-config
EOF

# Create the nova-extra-config CM based on the provided config file
cat <<EOF >>kustomization.yaml
configMapGenerator:
- name: nova-extra-config
  files:
    - 25-nova-extra.conf=${EDPM_EXTRA_NOVA_CONFIG_FILE}
  options:
    disableNameSuffixHash: true
EOF

# Replace the nova service in the nodeset with the new nova-custom service
#
# NOTE(gibi): This is hard to do with kustomize as it only allows
# list item replacemnet by index and not by value, but we cannot
# be sure that the index is not changing in the future by
# adding more services or splitting existing services.
# The kustozmization would be something like:
#     - op: replace
#      path: /spec/services/11
#      value: nova-custom
#
# So we do a replace by value with yq (assuming golang implementation of yq)
yq -i '(.spec.services[] | select(. == "nova")) |= "nova-custom"' *openstackdataplanenodeset*.yaml
fi

kustomization_add_resources

popd
