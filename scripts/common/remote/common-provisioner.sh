#!/bin/bash

set -euxo posix

PARAM_COUNT=3

if [ $# -ne $PARAM_COUNT ]; then
	echo "common-provisioner.sh requires $PARAM_COUNT parameters"
	exit 1
fi

apt -y update
apt -y install jq

INSTANCE_METADATA=$(curl --silent http://169.254.169.254/v1.json)
PRIVATE_IP=$(echo $INSTANCE_METADATA | jq -r .interfaces[1].ipv4.address)
PUBLIC_MAC=$(curl --silent 169.254.169.254/v1.json | jq -r '.interfaces[] | select(.["network-type"]=="public") | .mac')
PRIVATE_MAC=$(curl --silent 169.254.169.254/v1.json | jq -r '.interfaces[] | select(.["network-type"]=="private") | .mac')

# Parameters
DOCKER_RELEASE="$1"
CONTAINERD_RELEASE="$2"
K8_RELEASE=$(echo $3 | sed 's/v//' | sed 's/$/-00/')

pre_dependencies(){
	apt -y install gnupg2 iptables arptables ebtables

	cat <<-EOF > /etc/sysctl.d/k8s.conf
		net.bridge.bridge-nf-call-ip6tables = 1
		net.bridge.bridge-nf-call-iptables = 1
		EOF

	sysctl --system

	update-alternatives --set iptables /usr/sbin/iptables-legacy
	update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
	update-alternatives --set arptables /usr/sbin/arptables-legacy
	update-alternatives --set ebtables /usr/sbin/ebtables-legacy
}

network_config(){
	cat <<-EOF > /etc/systemd/network/public.network
		[Match]
		MACAddress=$PUBLIC_MAC

		[Network]
		DHCP=yes
		EOF

	cat <<-EOF > /etc/systemd/network/private.network
		[Match]
		MACAddress=$PRIVATE_MAC

		[Network]
		Address=$PRIVATE_IP
		EOF

	systemctl enable systemd-networkd systemd-resolved
	systemctl restart systemd-networkd systemd-resolved
}

install_k8(){
	curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -

	cat <<-EOF > /etc/apt/sources.list.d/kubernetes.list
		deb https://apt.kubernetes.io/ kubernetes-xenial main
		EOF

	apt -y update
	apt -y install kubelet=$K8_RELEASE kubeadm=$K8_RELEASE kubectl=$K8_RELEASE
	apt-mark hold kubelet kubeadm kubectl

	cat <<-EOF > /etc/default/kubelet
		KUBELET_EXTRA_ARGS="--cloud-provider=external"
		KUBELET_CONFIG_ARGS="--allowed-unsafe-sysctls='kernel.msg*,net.core.*,net.ipv4.*,net.netfilter.nf_conntrack_max,fs.file-max'"
		EOF
}

install_docker(){
	apt -y update
	apt -y install apt-transport-https ca-certificates curl gnupg2 software-properties-common

	curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -

	cat <<-EOF > /etc/apt/sources.list.d/docker.list
		deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable
		EOF

	apt -y update
	apt -y install containerd.io=$CONTAINERD_RELEASE docker-ce=$DOCKER_RELEASE docker-ce-cli=$DOCKER_RELEASE

	cat <<-EOF > /etc/docker/daemon.json
		{
		  "exec-opts": ["native.cgroupdriver=systemd"],
		  "log-driver": "json-file",
		  "log-opts": {
		    "max-size": "100m"
		  },
		  "storage-driver": "overlay2"
		}
		EOF

	mkdir -p /etc/systemd/system/docker.service.d

	systemctl daemon-reload
	systemctl enable docker
	systemctl restart docker
}

clean(){
	rm -f /tmp/common-provisioner.sh
}

tweak_sysctl(){
	sysctl -w fs.file-max=2097152
	sysctl -w vm.swappiness=10
	sysctl -w vm.dirty_ratio=60
	sysctl -w vm.dirty_background_ratio=2
	sysctl -w net.ipv4.tcp_synack_retries=2
	sysctl -w net.ipv4.tcp_rfc1337=1
	sysctl -w net.ipv4.tcp_fin_timeout=15
	sysctl -w net.ipv4.tcp_keepalive_time=300
	sysctl -w net.ipv4.tcp_keepalive_probes=5
	sysctl -w net.ipv4.tcp_keepalive_intvl=15
	sysctl -w net.core.rmem_max=12582912
	sysctl -w net.core.wmem_default=31457280
	sysctl -w net.core.wmem_max=12582912
	sysctl -w net.core.somaxconn=65535
	sysctl -w net.core.netdev_max_backlog=65535
	sysctl -w net.core.optmem_max=25165824
	sysctl -w net.ipv4.udp_rmem_min=16384
	sysctl -w net.ipv4.udp_wmem_min=16384
	sysctl -w net.ipv4.tcp_max_tw_buckets=1440000
	sysctl -w net.ipv4.tcp_tw_reuse=1
	sysctl -w net.ipv4.ip_forward=1
	sysctl -w net.netfilter.nf_conntrack_max=2097152
	echo "* soft nofile 400000" >> /etc/security/limits.conf
	echo "* hard nofile 400000" >> /etc/security/limits.conf
	echo "root soft nofile 400000" >> /etc/security/limits.conf
	echo "root hard nofile 400000" >> /etc/security/limits.conf
	ulimit -n 400000
}

main(){
	pre_dependencies

	network_config
	tweak_sysctl
	install_k8
	install_docker
	clean
}

main
