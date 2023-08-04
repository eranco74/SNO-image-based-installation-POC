#!/usr/bin/env bash
set -euoE pipefail ## -E option will cause functions to inherit trap

echo "Reconfiguring single node OpenShift"

mkdir -p /opt/openshift
cd /opt/openshift

function mount_config {
  echo "Mounting config iso"
  mkdir -p /mnt/config
  if [[ ! $(mountpoint --quiet /mnt/config) ]]; then
      mount "/dev/$1" /mnt/config
  fi
  ls /mnt/config
}

function umount_config {
  echo "Unmounting config iso"
  umount /dev/$1
  rm -rf /mnt/config
}

RELOCATION_CONFIG_PATH=/opt/openshift/cluster-relocation.yaml
echo "Waiting for ${RELOCATION_CONFIG_PATH}"
while [[ ! $(lsblk -f --json | jq -r '.blockdevices[] | select(.label == "relocation-config") | .name') && ! -f "${RELOCATION_CONFIG_PATH}" ]];
do
  echo "Waiting for site-config"
  sleep 5
done

DEVICE=$(lsblk -f --json | jq -r '.blockdevices[] | select(.label == "relocation-config") | .name')
if [[ -n ${DEVICE+x} && ! -f "${RELOCATION_CONFIG_PATH}" ]]; then
  mount_config "${DEVICE}"
  cp -r /mnt/config/* $(dirname ${RELOCATION_CONFIG_PATH})
fi

if [ ! -f "${RELOCATION_CONFIG_PATH}" ]; then
  echo "Failed to find configuration file at ${RELOCATION_CONFIG_PATH}"
  exit 1
fi

echo "${RELOCATION_CONFIG_PATH} has been created"
# Replace this with a function that loads values from yaml file
set +o allexport

if ls /opt/openshift/*.nmconnection 1> /dev/null 2>&1; then
    echo "Static network configuration exist"
    cp /opt/openshift/*.nmconnection /etc/NetworkManager/system-connections/ -f
    systemctl restart NetworkManager
    # TODO: we might need to delete the connection first
else
    echo "Static network configuration do not exist"
fi


# TODO check if we really need to stop kubelet
echo "Starting kubelet"
systemctl start kubelet

#TODO: we need to add kubeconfig to the node for the configuration stage, this kubeconfig might not suffice
export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig
function wait_for_api {
  echo "Waiting for api ..."
  until oc get clusterversion &> /dev/null
  do
    echo "Waiting for api ..."
    sleep 5
  done
  echo "api is available"
}

wait_for_api

wait_approve_csr() {
  local name=${1}

  echo "Waiting for ${name} CSR..."
  until oc get csr | grep -i "${name}" | grep -i "pending" &> /dev/null
  do
    echo "Waiting for ${name} CSR..."
    sleep 5
  done
  echo "CSR ${name} is ready for approval"

  echo "Approving all pending CSRs..."
  oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve
}

# if hostname has changed
if [[ "$(oc get nodes -ojsonpath='{.items[0].metadata.name}')" != "$(hostname)" ]]
then
  wait_approve_csr "kube-apiserver-client-kubelet"
  wait_approve_csr "kubelet-serving"

  echo "Deleting previous node..."
  oc delete node "$(oc get nodes -ojsonpath='{.items[?(@.metadata.name != "'"$(hostname)"'"].metadata.name}')"
fi

verify_csr_subject() {
  local csr=${1}
  local subject

  subject="$(oc get csr -ojsonpath='{.spec.request}' "${csr}" |base64 -d | openssl req -noout -subject -nameopt multiline)"

  if [ "$(echo "${subject}" |grep commonName |awk '{print $3}')" != "system:node:$(hostname)" ]
  then
    echo "CommonName is not 'system:node:master1'"
    return
  fi

  if [ "$(echo "${subject}" |grep organizationName |awk '{print $3}')" != "system:nodes" ]
  then
    echo "Organization is not 'system:nodes'"
    return
  fi
}

# If the kubelet API server client certificate has expired:
#   1. wait for the respective CSR to be created
#   2. verify it
#   3. approve it
#   4. wait for the certificate to be issued
KUBELET_CLIENT_CERTIFICATE=/var/lib/kubelet/pki/kubelet-client-current.pem
until openssl x509 -in ${KUBELET_CLIENT_CERTIFICATE} -checkend 30 &> /dev/null
do
  echo "${KUBELET_CLIENT_CERTIFICATE} has expired, waiting for new one to be issued..."

  csr=$(oc get csr -o go-template='{{range .items}}{{if and (not .status) (eq .spec.signerName "kubernetes.io/kube-apiserver-client-kubelet") (eq .spec.username "system:serviceaccount:openshift-machine-config-operator:node-bootstrapper")}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | head -1 || true)
  if [ -z "${csr}" ]
  then
    sleep 5
    continue
  fi

  echo "${csr} is pending. Verifying CSR before approving it..."
  err=$(verify_csr_subject "${csr}")
  if [ -n "${err}" ]
  then
    echo "${csr} could not be verified: ${err}"
    break
  fi

  echo "${csr} successfully verified. Approving it..."
  oc adm certificate approve "${csr}"
done
echo "${KUBELET_CLIENT_CERTIFICATE} is valid."

# Reconfigure DNS
node_ip=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type == "InternalIP")].address}')
domain=$(oc apply -f "${RELOCATION_CONFIG_PATH}" --dry-run=client -o jsonpath={'.items[?(@.kind=="ClusterRelocation")].spec.domain'})

if [ -z ${domain+x} ]; then
  echo "domain not defined"
else
  echo "Updating dnsmasq with new domain"
  cat << EOF > /etc/dnsmasq.d/customer-domain.conf
address=/apps.${domain}/${node_ip}
address=/api-int.${domain}/${node_ip}
address=/api.${domain}/${node_ip}
EOF
  systemctl restart dnsmasq
fi

echo "Applying cluster relocation CR"
oc apply -f "${RELOCATION_CONFIG_PATH}"
echo "Waiting for cluster relocation status"
oc wait --timeout=1h clusterrelocation cluster --for condition=Reconciled=true
echo "Cluster configuration updated"


verify_csr_addresses() {
  local csr=${1}
  local addresses=${2}
  local csr_san_content

  csr_san_content=$(oc get csr -ojsonpath='{.spec.request}' "${csr}" |base64 -d | openssl req -noout -text |grep DNS)
  for address in "${addresses[@]}"
  do
    if [[ "${csr_san_content}" != *"${address}"* ]]
    then
      echo "${address} not in CSR DNS or IP addresses"
      return
    fi
  done
}
# If the kubelet serving certificate has expired:
#   1. wait for the respective CSR to be created
#   2. verify it
#   3. approve it
#   4. wait for the certificate to be issued
KUBELET_SERVING_CERTIFICATE=/var/lib/kubelet/pki/kubelet-server-current.pem
until openssl x509 -in ${KUBELET_SERVING_CERTIFICATE} -checkend 30 &> /dev/null
do
  echo "${KUBELET_SERVING_CERTIFICATE} has expired, waiting for new one to be issued..."

  csr=$(oc get csr -o go-template='{{range .items}}{{if and (not .status) (eq .spec.signerName "kubernetes.io/kubelet-serving") (eq .spec.username "system:node:'"$(hostname)"'")}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | head -1 || true)
  if [ -z "${csr}" ]
  then
    sleep 5
    continue
  fi

  echo "${csr} is pending. Verifying CSR before approving it..."
  err=$(verify_csr_subject "${csr}")
  if [ -n "${err}" ]
  then
    echo "${csr} could not be verified: ${err}"
    break
  fi

  IFS=$' ' read -r -d '' -a addresses < <( oc get nodes "$(hostname)" -ojsonpath='{.status.addresses[*].address}'  && printf '\0' )
  err=$(verify_csr_addresses "${csr}" "${addresses}")
  if [ -n "${err}" ]
  then
    echo "${csr} addresses could not be verified: ${err}"
    break
  fi

  echo "${csr} successfully verified. Approving it..."
  oc adm certificate approve "${csr}"
done
echo "${KUBELET_SERVING_CERTIFICATE} is valid."

rm -rf /opt/openshift
systemctl enable kubelet
systemctl disable installation-configuration.service
if [[ -n ${DEVICE+x} ]]; then
  umount_config "${DEVICE}"
fi
