# Disable built-in rules
MAKEFLAGS += --no-builtin-rules

IMAGE_BASED_DIR = .
SNO_DIR = ./bootstrap-in-place-poc
CONFIG_DIR = ./config-dir

########################

default: help

checkenv:
ifndef PULL_SECRET
	$(error PULL_SECRET must be defined)
endif

SEED_VM_NAME  ?= seed
SEED_VM_IP  ?= 192.168.126.10
SEED_VERSION ?= 4.13.5
SEED_MAC ?= 52:54:00:ee:42:e1

RECIPIENT_VM_NAME ?= recipient
RECIPIENT_VM_IP  ?= 192.168.126.99
RECIPIENT_VERSION ?= 4.14.1
RECIPIENT_MAC ?= 52:54:00:fa:ba:da

LIBVIRT_IMAGE_PATH := $(or ${LIBVIRT_IMAGE_PATH},/var/lib/libvirt/images)
BASE_IMAGE_PATH_SNO = $(LIBVIRT_IMAGE_PATH)/$(SEED_VM_NAME).qcow2
BACKUP_IMAGE_PATH_SNO = $(LIBVIRT_IMAGE_PATH)/$(SEED_VM_NAME)-backup.qcow2
IMAGE_PATH_SNO_IN_LIBVIRT = $(LIBVIRT_IMAGE_PATH)/SNO-baked-image.qcow2
SITE_CONFIG_PATH_IN_LIBVIRT = $(LIBVIRT_IMAGE_PATH)/site-config.iso
CLUSTER_RELOCATION_TEMPLATE = ./edge_configs/cluster-configuration/05_cluster-relocation.json
PULL_SECRET_TEMPLATE = ./edge_configs/cluster-configuration/03_pullsecret.json
NAMESPACE_TEMPLATE = ./edge_configs/cluster-configuration/00_namespace.json
EXTRA_MANIFESTS_PATH = ./edge_configs/extra-manifests
MACHINE_NETWORK ?= 192.168.126.0/24
CPU_CORE ?= 16
RAM_MB ?= 32768
LCA_IMAGE ?= quay.io/openshift-kni/lifecycle-agent-operator:latest
NET_CONFIG_TEMPLATE = $(IMAGE_BASED_DIR)/template-net.xml
NET_CONFIG = $(IMAGE_BASED_DIR)/net.xml
RELEASE_ARCH ?= x86_64


NET_NAME = test-net-2
VM_NAME = sno2
VOL_NAME = $(VM_NAME).qcow2

SSH_KEY_DIR = $(SNO_DIR)/ssh-key
SSH_KEY_PUB_PATH = $(SSH_KEY_DIR)/key.pub
SSH_KEY_PRIV_PATH = $(SSH_KEY_DIR)/key

SSH_FLAGS = -o IdentityFile=$(SSH_KEY_PRIV_PATH) \
 			-o UserKnownHostsFile=/dev/null \
 			-o StrictHostKeyChecking=no

HOST_IP = 192.168.128.10
SSH_HOST = core@$(HOST_IP)

CLUSTER ?= seed
SNO_KUBECONFIG ?= $(SNO_DIR)/workdir-$(CLUSTER)/auth/kubeconfig
oc = oc --kubeconfig $(SNO_KUBECONFIG)

# Relocation config
CLUSTER_NAME ?= new-name
BASE_DOMAIN ?= relocated.com
HOSTNAME ?= master1
MIRROR_URL ?= mirror-registry.local
MIRROR_PORT ?= 5000
NEW_REGISTRY_CERT = $(shell cat edge_configs/registry.crt)
NEW_SSH_KEY = $(shell cat ${SSH_KEY_PUB_PATH})
export NEW_REGISTRY_CERT
export NEW_SSH_KEY

$(SSH_KEY_DIR):
	@echo Creating SSH key dir
	mkdir $@

$(SSH_KEY_PRIV_PATH): $(SSH_KEY_DIR)
	@echo "No private key $@ found, generating a private-public pair"
	# -N "" means no password
	ssh-keygen -f $@ -N ""
	chmod 400 $@

$(SSH_KEY_PUB_PATH): $(SSH_KEY_PRIV_PATH)

.PHONY: gather checkenv clean destroy-libvirt start-vm network ssh bake $(IMAGE_PATH_SNO_IN_LIBVIRT) $(NET_CONFIG) $(CONFIG_DIR) help vdu external-container-partition remove-container-partition ostree-backup ostree-restore create-config copy-config ostree-shared-containers

.SILENT: destroy-libvirt

### Install SNO from ISO
start-iso: bootstrap-in-place-poc
	make -C $(SNO_DIR) $@

.PHONY: seed-vm-create
seed-vm-create: VM_NAME=$(SEED_VM_NAME)
seed-vm-create: HOST_IP=$(SEED_VM_IP)
seed-vm-create: RELEASE_VERSION=$(SEED_VERSION)
seed-vm-create: MAC_ADDRESS=$(SEED_MAC)
seed-vm-create: start-iso-abi ## Install seed SNO cluster

.PHONY: recipient-vm-create
recipient-vm-create: VM_NAME=$(RECIPIENT_VM_NAME)
recipient-vm-create: HOST_IP=$(RECIPIENT_VM_IP)
recipient-vm-create: RELEASE_VERSION=$(RECIPIENT_VERSION)
recipient-vm-create: MAC_ADDRESS=$(RECIPIENT_MAC)
recipient-vm-create: start-iso-abi ## Install recipient SNO cluster

start-iso-abi: bootstrap-in-place-poc
	< agent-config-template.yaml \
		VM_NAME=$(VM_NAME) \
		HOST_IP=$(HOST_IP) \
		HOST_MAC=$(MAC_ADDRESS) \
		envsubst > $(SNO_DIR)/agent-config.yaml
	make -C $(SNO_DIR) $@ \
		VM_NAME=$(VM_NAME) \
		HOST_IP=$(HOST_IP) \
		MACHINE_NETWORK=$(MACHINE_NETWORK) \
		CLUSTER_NAME=$(VM_NAME) \
		HOST_MAC=$(MAC_ADDRESS) \
		INSTALLER_WORKDIR=workdir-$(VM_NAME)\
		RELEASE_VERSION=$(RELEASE_VERSION) \
		CPU_CORE=$(CPU_CORE) \
		RELEASE_ARCH=$(RELEASE_ARCH) \
		RAM_MB=$(RAM_MB)

bootstrap-in-place-poc:
	rm -rf $(SNO_DIR)
	git clone https://github.com/eranco74/bootstrap-in-place-poc

.PHONY: wait-for-seed
wait-for-seed: CLUSTER=seed
wait-for-seed: wait-for-install-complete ## Wait for seed cluster to complete installation

.PHONY: wait-for-recipient
wait-for-recipient: CLUSTER=recipient
wait-for-recipient: wait-for-install-complete ## Wait for recipient cluster to complete installation

.PHONY: wait-for-install-complete
wait-for-install-complete:
	echo "Waiting for installation to complete"
	@until [ "$$($(oc) get clusterversion -o jsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}')" == "True" ]; do \
			echo -n .; sleep 10; \
	done; \
	echo " DONE"

destroy-vm:
	@echo Destroying $(VM_NAME)
	-virsh destroy $(VM_NAME)
	@until virsh domstate $(VM_NAME) | grep -qx 'shut off' ; do echo -n . ; sleep 2; done; echo
	-rm "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME).qcow2" "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME)-backup.qcow2"
	sudo virsh undefine $(VM_NAME)

.PHONY: credentials/backup-secret.json
credentials/backup-secret.json:
	@test '$(BACKUP_SECRET)' || { echo "BACKUP_SECRET must be defined"; exit 1; }
	@mkdir -p credentials
	@echo '$(BACKUP_SECRET)' > credentials/backup-secret.json

# dnsmasq workaround until https://github.com/openshift/assisted-service/pull/5658 is in assisted
dnsmasq-workaround: SEED_CLUSTER_NAME ?= $(SEED_VM_NAME).redhat.com
wait-for-seed-install-complete: CLUSTER=$(SEED_VM_NAME)
dnsmasq-workaround: ## Apply dnsmasq workaround to SEED_VM
	./generate-dnsmasq-machineconfig.sh --name $(SEED_CLUSTER_NAME) --ip $(SEED_VM_IP) | $(oc) apply -f -

.PHONY: seed-image-create
seed-image-create: credentials/backup-secret.json ## Create seed image using ibu-imager		make seed-image SEED_IMAGE=quay.io/whatever/ostmagic:seed
	scp $(SSH_FLAGS) credentials/backup-secret.json core@$(SEED_VM_NAME):/tmp
	ssh $(SSH_FLAGS) core@$(SEED_VM_NAME) sudo podman run --privileged --rm --pid=host --net=host \
		-v /var:/var \
		-v /var/run:/var/run \
		-v /etc:/etc \
		-v /run/systemd/journal/socket:/run/systemd/journal/socket \
		-v /tmp/backup-secret.json:/tmp/backup-secret.json \
		--entrypoint ibu-imager \
		$(LCA_IMAGE) \
			create --authfile /tmp/backup-secret.json --image $(SEED_IMAGE)

machineConfigs: machineConfigs/installation-configuration.yaml machineConfigs/dnsmasq.yaml

# Generate installation-configuration machine config that will create the service that reconfigure the node.
machineConfigs/installation-configuration.yaml: bake/installation-configuration.sh butane-installation-configuration.yaml
	podman run -i -v ./bake:/scripts/:rw,Z  --rm quay.io/coreos/butane:release --pretty --strict -d /scripts < butane-installation-configuration.yaml > $@ || (rm $@ && false)

machineConfigs/dnsmasq.yaml: bake/dnsmasq.conf bake/force-dns-script bake/unmanaged-resolv.conf butane-dnsmasq.yaml
	podman run -i -v ./bake:/scripts/:rw,Z  --rm quay.io/coreos/butane:release --pretty --strict -d /scripts < butane-dnsmasq.yaml > $@ || (rm $@ && false)

machineConfigs/internal-ip.yaml: bake/dispatcher-pre-up-internal-ip.sh bake/crio-nodenet.conf bake/kubelet-nodenet.conf
	podman run -i -v ./bake:/scripts/:rw,Z  --rm quay.io/coreos/butane:release --pretty --strict -d /scripts < butane-internal-ip.yaml > $@ || (rm $@ && false)

wait-for-shutdown:
	@until sudo virsh domstate $(SEED_VM_NAME) | grep shut; do \
		echo " $(SEED_VM_NAME) still running"; \
		sleep 10; \
	done

lifecycle-agent:
	rm -rf lifecycle-agent
	git clone https://github.com/openshift-kni/lifecycle-agent

.PHONY: lifecycle-agent-deploy
lifecycle-agent-deploy: CLUSTER=$(RECIPIENT_VM_NAME)
lifecycle-agent-deploy: lifecycle-agent
	KUBECONFIG=../$(SNO_KUBECONFIG) make -C lifecycle-agent install deploy
	@echo "Waiting for deployment lifecycle-agent-controller-manager to be available"; \
	until $(oc) wait deployment -n openshift-lifecycle-agent lifecycle-agent-controller-manager --for=condition=available=true; do \
		echo -n .;\
		sleep 5; \
	done; echo

.PHONY: seed-image-restore
seed-image-restore: CLUSTER=$(RECIPIENT_VM_NAME)
seed-image-restore: lifecycle-agent-deploy lca-stage-idle lca-stage-prep lca-wait-for-prep lca-stage-upgrade lca-wait-for-upgrade ## Restore seed image				make lca-seed-restore SEED_IMAGE=quay.io/whatever/ostmagic:seed SEED_VERSION=4.13.5
	@echo "Seed image restoration process complete"
	@echo "Reboot SNO to finish the upgrade process"

.PHONY: lca-stage-idle
lca-stage-idle: CLUSTER=$(RECIPIENT_VM_NAME)
lca-stage-idle: credentials/backup-secret.json
	$(oc) create secret generic seed-pull-secret -n default --from-file=.dockerconfigjson=credentials/backup-secret.json \
		--type=kubernetes.io/dockerconfigjson --dry-run=client -oyaml \
		| $(oc) apply -f -
	SEED_VERSION=$(SEED_VERSION) SEED_IMAGE=$(SEED_IMAGE) envsubst < imagebasedupgrade.yaml | $(oc) apply -f -

.PHONY: lca-stage-prep
lca-stage-prep: CLUSTER=$(RECIPIENT_VM_NAME)
lca-stage-prep:
	$(oc) patch --type=json ibu -n default upgrade --type merge -p '{"spec": { "stage": "Prep"}}'

.PHONY: lca-wait-for-prep
lca-wait-for-prep: CLUSTER=$(RECIPIENT_VM_NAME)
lca-wait-for-prep:
	$(oc) wait --timeout=30m --for=condition=PrepCompleted=true ibu -n default upgrade

.PHONY: lca-stage-upgrade
lca-stage-upgrade: CLUSTER=$(RECIPIENT_VM_NAME)
lca-stage-upgrade:
	$(oc) patch --type=json ibu -n default upgrade --type merge -p '{"spec": { "stage": "Upgrade"}}'

.PHONY: lca-wait-for-upgrade
lca-wait-for-upgrade: CLUSTER=$(RECIPIENT_VM_NAME)
lca-wait-for-upgrade:
	$(oc) wait --timeout=30m --for=condition=UpgradeCompleted=true ibu -n default upgrade

### Create new image from template
create-image-template: $(IMAGE_PATH_SNO_IN_LIBVIRT)

$(IMAGE_PATH_SNO_IN_LIBVIRT): $(BASE_IMAGE_PATH_SNO)
	sudo mv $< $@
	sudo chown qemu:qemu $@

### Create a new SNO from the image template

# Render the libvirt net config file with the network name and host IP
$(NET_CONFIG): $(NET_CONFIG_TEMPLATE)
	sed -e 's/REPLACE_NET_NAME/$(NET_NAME)/' \
		-e 's/REPLACE_HOST_IP/$(HOST_IP)/' \
		-e 's|DOMAIN|$(CLUSTER_NAME).$(BASE_DOMAIN)|' \
		-e 's|REPLACE_HOSTNAME|$(HOSTNAME)|' \
	    $(NET_CONFIG_TEMPLATE) > $@
	@if [ "$(STATIC_NETWORK)" = "TRUE" ]; then \
		sed -i "/dhcp/,/\/dhcp/d" $@; \
	fi

network: destroy-libvirt $(NET_CONFIG)
	NET_XML=$(NET_CONFIG) \
	HOST_IP=$(HOST_IP) \
	CLUSTER_NAME=$(CLUSTER_NAME) \
	BASE_DOMAIN=$(BASE_DOMAIN) \
	$(SNO_DIR)/virt-create-net.sh

# Destroy previously created VMs/Networks and create a VM/Network with the pre-baked image
start-vm: checkenv $(IMAGE_PATH_SNO_IN_LIBVIRT) network $(SITE_CONFIG_PATH_IN_LIBVIRT) ## Copy sno-image.qcow2 and create new instance	make start-vm CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
	IMAGE=$(IMAGE_PATH_SNO_IN_LIBVIRT) \
	VM_NAME=$(VM_NAME) \
	NET_NAME=$(NET_NAME) \
	SITE_CONFIG=$(SITE_CONFIG_PATH_IN_LIBVIRT) \
	CPU_CORE=$(CPU_CORE) \
	RAM_MB=$(RAM_MB) \
	$(IMAGE_BASED_DIR)/virt-install-sno.sh


# Set the network name to static and call start-vm
start-vm-static-network: STATIC_NETWORK = "TRUE"
start-vm-static-network: start-vm

ssh: $(SSH_KEY_PRIV_PATH)
	ssh $(SSH_FLAGS) $(SSH_HOST)

$(CONFIG_DIR):
	rm -rf $@
	mkdir -p $@

# Set the network name to static and call start-vm
$(CONFIG_DIR)/cluster-configuration: PULL_SECRET_ENCODED=$(shell echo '$(PULL_SECRET)' | json_reformat | base64 -w 0)
$(CONFIG_DIR)/cluster-configuration: $(CONFIG_DIR) $(CLUSTER_RELOCATION_TEMPLATE) checkenv
	@mkdir $@
	@sed -e 's/REPLACE_DOMAIN/$(CLUSTER_NAME).$(BASE_DOMAIN)/' \
		-e 's/REPLACE_PULL_SECRET_ENCODED/"$(PULL_SECRET_ENCODED)"/' \
		-e 's/REPLACE_MIRROR_URL/$(MIRROR_URL)/' \
		-e 's/REPLACE_MIRROR_PORT/$(MIRROR_PORT)/' \
		-e 's|REPLACE_SSH_KEY|"$(NEW_SSH_KEY)"|' \
		-e 's|REPLACE_REGISTRY_CERT|"$(NEW_REGISTRY_CERT)"|' \
		$(CLUSTER_RELOCATION_TEMPLATE) > $@/$(notdir $(CLUSTER_RELOCATION_TEMPLATE))
	@sed -e 's/REPLACE_PULL_SECRET_ENCODED/"$(PULL_SECRET_ENCODED)"/' \
		$(PULL_SECRET_TEMPLATE) > $@/$(notdir $(PULL_SECRET_TEMPLATE))
	cp $(NAMESPACE_TEMPLATE) $@/$(notdir $(NAMESPACE_TEMPLATE))

$(CONFIG_DIR)/cluster-configuration/03_lb-api-cert-secret.json: $(CONFIG_DIR)/cluster-configuration
	KUBECONFIG=$(SNOB_KUBECONFIG) \
	$(IMAGE_BASED_DIR)/create-cert-for-api-lb.sh api.$(CLUSTER_NAME).$(BASE_DOMAIN) > $(CONFIG_DIR)/cluster-configuration/03_lb-api-cert-secret.json

create-config: $(CONFIG_DIR)/cluster-configuration edge_configs/static_network.cfg edge_configs/extra-manifests $(CONFIG_DIR)/cluster-configuration/03_lb-api-cert-secret.json
	@if [ "$(STATIC_NETWORK)" = "TRUE" ]; then \
		echo "Adding static network configuration to ISO"; \
		mkdir $(CONFIG_DIR)/network-configuration; \
		cp edge_configs/static_network.cfg $(CONFIG_DIR)/network-configuration/enp1s0.nmconnection; \
	fi
	cp -r $(EXTRA_MANIFESTS_PATH) $(CONFIG_DIR)

site-config.iso: create-config ## Create site-config.iso				make site-config.iso CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
	mkisofs -o site-config.iso -R -V "relocation-config" $(CONFIG_DIR)

copy-config: create-config ## Copy site-config to HOST				make copy-config CLUSTER_NAME=new-name BASE_DOMAIN=foo.com HOST=snob-sno SNOB_KUBECONFIG=snob_kubeconfig
	@test "$(HOST)" || { echo "HOST must be defined"; exit 1; }
	echo "Copying site-config to $(HOST)"
	STATEROOT_B_NAME=$(shell ssh $(SSH_FLAGS) core@$(HOST) rpm-ostree status --json | jq -r '.deployments[] | select(.booted==false) | .osname'); \
		ssh $(SSH_FLAGS) core@$(HOST) sudo mount /sysroot -o remount,rw; \
		ssh $(SSH_FLAGS) core@$(HOST) sudo mkdir -p /sysroot/ostree/deploy/$${STATEROOT_B_NAME}/var/opt/openshift; \
		tar czC $(CONFIG_DIR) . | ssh $(SSH_FLAGS) core@$(HOST) sudo tar xvzC /sysroot/ostree/deploy/$${STATEROOT_B_NAME}/var/opt/openshift --no-same-owner

$(SITE_CONFIG_PATH_IN_LIBVIRT): site-config.iso
	sudo cp site-config.iso $(LIBVIRT_IMAGE_PATH)
	sudo chown qemu:qemu $(LIBVIRT_IMAGE_PATH)/site-config.iso
	sudo restorecon $(LIBVIRT_IMAGE_PATH)/site-config.iso

update_script:
	cat bake/installation-configuration.sh | ssh $(SSH_FLAGS) $(SSH_HOST) "sudo tee /usr/local/bin/installation-configuration.sh"
	ssh $(SSH_FLAGS) $(SSH_HOST) "sudo systemctl daemon-reload"
	ssh $(SSH_FLAGS) $(SSH_HOST) "sudo systemctl restart installation-configuration.service --no-block"

vdu: ## Apply VDU profile to seed VM
	KUBECONFIG=$(SNO_KUBECONFIG) \
	$(IMAGE_BASED_DIR)/vdu-profile.sh

ostree-shared-containers: NAME=$(SEED_VM_NAME)
ostree-shared-containers: ## Setup a shared /var/lib/containers directory
	$(oc) apply -f ostree-var-lib-containers-machineconfig.yaml
	@echo "Waiting for 98-var-lib-containers to be present in running rendered-master MachineConfig"; \
	until $(oc) get mcp master -ojson | jq -r .status.configuration.source[].name | grep -xq 98-var-lib-containers; do \
		echo -n .;\
		sleep 30; \
	done; echo
	$(oc) wait --timeout=20m --for=condition=updated=true mcp master

.PHONY: vm-backup
vm-backup:
	virsh shutdown $(VM_NAME)
	@until virsh domstate $(VM_NAME) | grep -qx 'shut off' ; do echo -n . ; sleep 5; done; echo
	cp "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME).qcow2" "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME)-$(VERSION)-backup.qcow2"
	virsh start $(VM_NAME)

.PHONY: vm-restore
vm-restore:
	-virsh destroy $(VM_NAME)
	@until virsh domstate $(VM_NAME) | grep -qx 'shut off' ; do echo -n . ; sleep 5; done; echo
	cp "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME)-$(VERSION)-backup.qcow2" "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME).qcow2"
	virsh start $(VM_NAME)

.PHONY: seed-vm-backup
seed-vm-backup: VM_NAME=$(SEED_VM_NAME)
seed-vm-backup: VERSION=$(SEED_VERSION)
seed-vm-backup: vm-backup ## Make a copy of seed VM disk image (qcow2 file)

.PHONY: seed-vm-restore
seed-vm-restore: VM_NAME=$(SEED_VM_NAME)
seed-vm-restore: VERSION=$(SEED_VERSION)
seed-vm-restore: vm-restore ## Restore a copy of seed VM disk image (qcow2 file)

.PHONY: recipient-vm-backup
recipient-vm-backup: VM_NAME=$(RECIPIENT_VM_NAME)
recipient-vm-backup: VERSION=$(RECIPIENT_VERSION)
recipient-vm-backup: vm-backup ## Make a copy of recipient VM disk image (qcow2 file)

.PHONY: recipient-vm-restore
recipient-vm-restore: VM_NAME=$(RECIPIENT_VM_NAME)
recipient-vm-restore: VERSION=$(RECIPIENT_VERSION)
recipient-vm-restore: vm-restore ## Restore a copy of recipient VM disk image (qcow2 file)

.PHONY: relocation-operator
relocation-operator: ## (DEPRECATED) Install relocation-operator to seed VM
	$(oc) apply -f ./relocation-operator.yaml
	sleep 5
	@echo "Waiting for cluster-relocation-operator to be installed"
	$(oc) wait subscription --timeout=20m --for=jsonpath='{.status.state}'=AtLatestKnown -n openshift-operators cluster-relocation-operator

bake: machineConfigs relocation-operator ## (DEPRECATED) Make mandatory changes to seed VM to have a working seed image
	$(oc) apply -f ./machineConfigs/installation-configuration.yaml
	$(oc) apply -f ./machineConfigs/dnsmasq.yaml
	echo "Wait for mcp to update, the node will reboot in the process"
	@for mc in 50-master-dnsmasq-configuration 99-master-installation-configuration; do \
		echo "Waiting for $$mc to be present in running rendered-master MachineConfig"; \
		until $(oc) get mcp master -ojson | jq -r .status.configuration.source[].name | grep -xq $$mc; do \
			echo -n .;\
			sleep 30; \
		done; echo; \
	done
	$(oc) wait --timeout=20m --for=condition=updated=true mcp master
	# TODO: add this once we have the bootstrap script
	make -C $(SNO_DIR) ssh CMD="sudo systemctl disable kubelet"
	# Uncomment below line to generate an image that you can modify the script of and manually run
	# instead of having it run automatically on boot. Useful for development.
	# make -C $(SNO_DIR) ssh CMD="sudo systemctl disable installation-configuration"

ostree-backup: credentials/backup-secret.json ## (DEPRECATED) Create seed image using scripts	make ostree-backup SEED_IMAGE=quay.io/whatever/ostmagic:seed
	scp $(SSH_FLAGS) ostree-backup.sh credentials/backup-secret.json core@$(SEED_VM_NAME):/tmp
	ssh $(SSH_FLAGS) core@$(SEED_VM_NAME) sudo /tmp/ostree-backup.sh $(SEED_IMAGE)

ostree-restore: credentials/backup-secret.json ## (DEPRECATED) Restore SNO from ostree OCI		make ostree-restore SEED_IMAGE=quay.io/whatever/ostmagic:seed HOST=snob-sno
	@test "$(HOST)" || { echo "HOST must be defined"; exit 1; }
	scp $(SSH_FLAGS) ostree-restore.sh credentials/*-secret.json core@$(HOST):/tmp
	ssh $(SSH_FLAGS) core@$(HOST) sudo /tmp/ostree-restore.sh $(SEED_IMAGE)

external-container-partition: ## (DEPRECATED) Configure seed VM to use external /var/lib/containers
	VM_NAME=$(SEED_VM_NAME) \
	BASE_IMAGE_PATH_SNO=$(BASE_IMAGE_PATH_SNO) \
	KUBECONFIG=$(SNO_KUBECONFIG) \
	$(IMAGE_BASED_DIR)/external-varlibcontainers-create.sh

remove-container-partition: ## (DEPRECATED) Remove extra /var/lib/containers partition from baked image
	BASE_IMAGE_PATH_SNO=$(BASE_IMAGE_PATH_SNO) \
	$(IMAGE_BASED_DIR)/external-varlibcontainers-remove-partition.sh

### Cleanup

destroy-libvirt:
	echo "Destroying previous libvirt resources"
	NET_NAME=$(NET_NAME) \
        VM_NAME=$(VM_NAME) \
        VOL_NAME=$(VOL_NAME) \
	$(SNO_DIR)/virt-delete-sno.sh || true

help:   ## Shows this message.
		@grep -E '^[a-zA-Z_\.\-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
