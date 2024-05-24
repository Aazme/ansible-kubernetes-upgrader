#!/bin/bash
#https://www.cyberithub.com/solved-error-while-dialing-dial-unix-var-run-dockershim-sock/

# Check if the required number of arguments are provided
if [ $# -lt 5 ]; then
  echo "Usage: $0 <ssh_key_path> <ssh_user> <kubeadm_version> <kubeadm_version_apt> <K8s base version> <node_ip1> [<node_ip2> ... <node_ipN>]"
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

shift 5

# Commands for the other master nodes
other_master_commands=$(cat <<EOF
# Backup etcd
ETCDCTL_API=3 etcdctl --endpoints https://localhost:2379 snapshot save /etc/kubernetes/snapshot.db --cacert="/etc/kubernetes/pki/etcd/ca.crt" --cert="/etc/kubernetes/pki/etcd/server.crt" --key="/etc/kubernetes/pki/etcd/server.key"

# Remove old repos if necessary
sudo rm /etc/apt/sources.list.d/kubernetes.list

curl -fsSL https://pkgs.k8s.io/core:/stable:/v${k8s_base_version}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${k8s_base_version}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update

apt-cache policy kubeadm

cp /etc/kubernetes/admin.conf ./.kube/config

# Mark node as unschedulable
kubectl cordon \$(hostname | tr '[:upper:]' '[:lower:]')

# Drain the node
kubectl drain \$(hostname | tr '[:upper:]' '[:lower:]') --ignore-daemonsets --delete-emptydir-data

# Upgrade kubeadm
apt-mark unhold kubeadm && \\
apt-get update && apt-get install -y kubeadm="${kubeadm_version}${kubeadm_version_apt}" && \\
apt-mark hold kubeadm

# Verify kubeadm version
kubeadm version

# Upgrade the node
kubeadm upgrade node

# Upgrade kubelet and kubectl
apt-mark unhold kubelet kubectl && \\
apt-get update && \\
apt-get install -y kubelet="1.25.16-1.1" kubectl="1.25.16-1.1" && \\
apt-mark hold kubelet kubectl

# Reload and restart kubelet
systemctl daemon-reload
systemctl restart kubelet

# Uncordon the node to make it schedulable again
kubectl uncordon \$(hostname | tr '[:upper:]' '[:lower:]')
EOF
)

# Function to execute commands on a remote node via SSH
execute_commands_on_node() {
    local node_ip=$1
    local commands=$2

    ssh -i $ssh_key_path $ssh_user@$node_ip <<EOF
$commands
EOF
}

# Main script execution for all provided IP addresses
for node_ip in "$@"; do
    echo "Upgrading master node: $node_ip"
    execute_commands_on_node $node_ip "$other_master_commands"
done
