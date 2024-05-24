#!/bin/bash

# Check if the required number of arguments are provided
if [ $# -lt 6 ]; then
  echo "Usage: $0 <ssh_key_path> <ssh_user> <kubeadm_version> <kubeadm_version_apt> <K8s base version> <node_ip>"
  echo "example: ./upgrade_first_master.sh ~/.ssh/ed25519 root 1.28.9 -2.1 1.28 10.4.12.77"
  echo "The script is expecting the cluster config to be at ~/admin.conf"
  echo "Otherwise, it will fail to drain/cordon the nodes"
  exit 1
fi

# Extract the first 5 arguments
ssh_key_path=$1
ssh_user=$2
kubeadm_version=$3
kubeadm_version_apt=$4
k8s_base_version=$5
first_master_ip=$6


# Commands for the first master node
first_master_commands=$(cat <<EOF
# Backup etcd
ETCDCTL_API=3 etcdctl --endpoints https://localhost:2379 snapshot save /etc/kubernetes/snapshot.db --cacert="/etc/kubernetes/pki/etcd/ca.crt" --cert="/etc/kubernetes/pki/etcd/server.crt" --key="/etc/kubernetes/pki/etcd/server.key"

# Remove old repos if necessary
# sudo rm /etc/apt/sources.list.d/kubernetes.list

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.25/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.25/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update

apt-cache policy kubeadm

cp /etc/kubernetes/admin.conf ./.kube/config

# Mark node as unschedulable
kubectl cordon $(hostname | tr '[:upper:]' '[:lower:]')

# Drain the node
kubectl drain $(hostname | tr '[:upper:]' '[:lower:]') --ignore-daemonsets --delete-emptydir-data

# Upgrade kubeadm
apt-mark unhold kubeadm && \\
apt-get update && apt-get install -y kubeadm="1.25.16-1.1" && \\
apt-mark hold kubeadm

# Verify kubeadm version
kubeadm version

# Plan the upgrade
kubeadm upgrade plan --ignore-preflight-errors=CoreDNSUnsupportedPlugins

# Apply the upgrade
kubeadm upgrade apply v"1.25.16" --ignore-preflight-errors=CoreDNSUnsupportedPlugins --force

# Upgrade kubelet and kubectl
apt-mark unhold kubelet kubectl && \\
apt-get update && \\
apt-get install -y kubelet="1.25.16-1.1" kubectl="1.25.16-1.1" && \\
apt-mark hold kubelet kubectl

# Reload and restart kubelet
systemctl daemon-reload
systemctl restart kubelet

# Uncordon the node to make it schedulable again
kubectl uncordon $(hostname | tr '[:upper:]' '[:lower:]')
EOF
)

# Function to execute commands on the first master node via SSH
execute_commands_on_first_master() {
    local node_ip=$1
    local commands=$2

    ssh -i $ssh_key_path $ssh_user@$node_ip <<EOF
$commands
EOF
}

# Execute commands on the first master node
execute_commands_on_first_master $first_master_ip "$first_master_commands"
