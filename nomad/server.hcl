# Phone 1 (phoneserver): Nomad server + client
# Deploy to proot /etc/nomad.d/nomad.hcl via setup-cluster.sh

name      = "phoneserver"
data_dir  = "/opt/nomad/data"
log_level = "INFO"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled           = true
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
