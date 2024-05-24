#!/bin/bash

# Check if the required number of arguments are provided
if [ $# -lt 5 ]; then
  echo "Usage: $0 <ssh_key_path> <ssh_user> <kubeadm_version> <kubeadm_version_apt> <K8s base version> <node_ip1> [<node_ip2> ... <node_ipN>]"
  echo "example: $0 ~/.ssh/id_rsa ubuntu 1.28.2 -1.1 127.0.0.1"
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

# Function to execute commands on a remote worker node via SSH
execute_commands_on_worker_node() {
    local node_ip=$1

    # Copy the kubeconfig file to the worker node
    scp -i $ssh_key_path ~/admin.conf $ssh_user@$node_ip:/root/admin.conf

    ssh -i $ssh_key_path $ssh_user@$node_ip <<EOF
node_name=\$(hostname | tr '[:upper:]' '[:lower:]')

# Ensure kubectl can use the kubeconfig file
export KUBECONFIG=/root/admin.conf

# Cordon the node to prevent new pods from being scheduled
kubectl cordon \${node_name}

# Drain the node to evict the existing pods
kubectl drain \${node_name} --ignore-daemonsets --delete-emptydir-data

# Add the Kubernetes repository key and update the package list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${k8s_base_version}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${k8s_base_version}/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
apt update

# Upgrade kubeadm
apt-mark unhold kubeadm && \
apt-get update && apt-get install -y kubeadm="${kubeadm_version}${kubeadm_version_apt}" && \
apt-mark hold kubeadm

# Upgrade kubelet and kubectl
apt-mark unhold kubelet kubectl && \
apt-get update && apt-get install -y kubelet="${kubeadm_version}${kubeadm_version_apt}" kubectl="${kubeadm_version}${kubeadm_version_apt}" && \
apt-mark hold kubelet kubectl

# Apply the kubeadm upgrade
kubeadm upgrade node

# Reload and restart the kubelet service
systemctl daemon-reload
systemctl restart kubelet

# Uncordon the node to make it schedulable again
kubectl uncordon \${node_name}

# Remove the kubeconfig file from the worker node for security
rm -f /root/admin.conf
EOF
}

# Main script execution for all provided IP addresses
for node_ip in "$@"; do
    echo "Upgrading worker node: $node_ip"
    execute_commands_on_worker_node $node_ip
done
