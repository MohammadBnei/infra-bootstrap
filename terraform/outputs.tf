output "k8s_node_ips" {
  value = { for k, v in var.k8s_nodes : k => v.ip }
}

output "garage_storage_ip" {
  value = var.garage_ip
}

output "garage_storage_ct_id" {
  value = var.garage_ct_id
}

output "k9s_dashboard_ip" {
  value = var.k9s_dashboard_ip
}

output "k9s_dashboard_ct_id" {
  value = var.k9s_dashboard_ct_id
}
