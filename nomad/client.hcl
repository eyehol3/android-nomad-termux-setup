# Phone 2 (phoneserver2): Nomad client only
# Deploy to proot /etc/nomad.d/nomad.hcl via setup-cluster.sh
#
# IMPORTANT: replace PHONESERVER_IP with the actual IP of phone 1.
# The hostname "phoneserver" only exists in your Mac's /etc/hosts,
# not on the phones. setup-cluster.sh handles this automatically.

name      = "phoneserver2"
data_dir  = "/opt/nomad/data"
log_level = "INFO"
bind_addr = "0.0.0.0"

client {
  enabled           = true
  servers           = ["PHONESERVER_IP:4647"]
  network_interface = "wlan0"

  artifact {
    decompression_file_count_limit = 65536
  }
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}
