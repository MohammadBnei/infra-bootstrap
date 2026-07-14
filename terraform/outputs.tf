output "k8s_cp_01_ip" {
  value = "192.168.1.201"
}

output "k8s_worker_01_ip" {
  value = "192.168.1.202"
}

output "garage_storage_ip" {
  value = var.garage_ip
}

output "garage_storage_ct_id" {
  value = var.garage_ct_id
}
