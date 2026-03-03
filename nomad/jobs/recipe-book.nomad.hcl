job "recipe-book" {
  type        = "service"
  datacenters = ["dc1"]

  group "app" {
    count = 1

    restart {
      attempts = 5
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    reschedule {
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "10m"
      unlimited      = true
    }

    task "recipe-book" {
      driver = "raw_exec"

      artifact {
        source      = "http://10.63.153.74:8080/recipe-book-arm64.tar.gz"
        destination = "local/app"
      }

      config {
        command = "/bin/sh"
        args = [
          "-c",
          "cd ${NOMAD_TASK_DIR}/app && exec /data/data/com.termux/files/usr/bin/npm start",
        ]
      }

      env {
        NODE_ENV = "production"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
