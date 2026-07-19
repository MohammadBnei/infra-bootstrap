output "k8s_node_ips" {
  value = { for k, v in var.k8s_nodes : k => v.ip }
}

output "garage_storage_ip" {
  value = var.garage_ip
}

output "garage_storage_ct_id" {
  value = var.garage_ct_id
}
