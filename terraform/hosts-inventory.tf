# Generates inventory/ukubi/hosts.yaml from var.k8s_nodes so the kubespray
# inventory never drifts from what Terraform actually provisioned — see
# templates/hosts.yaml.tpl for the rendered structure.
resource "local_file" "kubespray_inventory" {
  filename = "${path.module}/../inventory/ukubi/hosts.yaml"
  content = templatefile("${path.module}/templates/hosts.yaml.tpl", {
    nodes                = var.k8s_nodes
    ssh_private_key_file = var.k8s_vm_ssh_private_key_file
  })
}
