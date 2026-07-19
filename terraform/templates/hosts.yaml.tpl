# Terraform-generated — DO NOT EDIT BY HAND.
# Regenerated from terraform/variables.tf's `k8s_nodes` on every
# `terraform apply` (see terraform/hosts-inventory.tf). Manual edits here
# are overwritten on next apply. To change topology, edit `k8s_nodes` in
# terraform/variables.tf.
all:
  hosts:
%{ for name, n in nodes ~}
    ${name}:
      ansible_host: ${n.ip}
      ansible_user: core
      ansible_ssh_private_key_file: ${ssh_private_key_file}
      ansible_become: true
      ansible_become_method: sudo
      ip: ${n.ip}
      access_ip: ${n.ip}
%{ endfor ~}
  children:
    kube_control_plane:
      hosts:
%{ for name, n in nodes ~}
%{ if n.control_plane ~}
        ${name}:
%{ endif ~}
%{ endfor ~}
    kube_node:
      hosts:
%{ for name, n in nodes ~}
%{ if n.worker ~}
        ${name}:
%{ endif ~}
%{ endfor ~}
    etcd:
      hosts:
%{ for name, n in nodes ~}
%{ if n.etcd ~}
        ${name}:
%{ endif ~}
%{ endfor ~}
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
