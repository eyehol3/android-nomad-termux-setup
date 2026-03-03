job "artifact-server" {
  type        = "service"
  datacenters = ["dc1"]

  group "server" {
    count = 1

    constraint {
      attribute = "${node.unique.name}"
      value     = "phoneserver"
    }

    restart {
      attempts = 5
      interval = "5m"
      delay    = "10s"
      mode     = "delay"
    }

    reschedule {
      delay          = "30s"
      delay_function = "constant"
      max_delay      = "30s"
      unlimited      = true
    }

    task "http-server" {
      driver = "raw_exec"

      config {
        command = "/bin/sh"
        args = [
          "-c",
          "mkdir -p /data/data/com.termux/files/home/artifacts && exec /data/data/com.termux/files/usr/bin/python3 -m http.server 8080 --directory /data/data/com.termux/files/home/artifacts",
        ]
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
