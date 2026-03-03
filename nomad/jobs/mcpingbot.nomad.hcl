job "mcpingbot" {
  type        = "service"
  datacenters = ["dc1"]

  group "bot" {
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

    task "mcpingbot" {
      driver = "raw_exec"

      artifact {
        source      = "http://10.63.153.74:8080/mcpingbot-arm64.tar.gz"
        destination = "local/app"
      }

      config {
        command = "/bin/sh"
        args = [
          "-c",
          "cd ${NOMAD_TASK_DIR}/app && exec /data/data/com.termux/files/usr/bin/python3 -u bot.py",
        ]
      }

      env {
        PYTHONPATH      = "${NOMAD_TASK_DIR}/app/.pythonlibs"
        PYTHONUNBUFFERED = "1"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
