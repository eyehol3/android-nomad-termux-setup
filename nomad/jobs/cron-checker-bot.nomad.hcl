job "cron-checker-bot" {
  type        = "batch"
  datacenters = ["dc1"]

  periodic {
    crons            = ["*/10 * * * *"]
    prohibit_overlap = true
  }

  group "checker" {
    count = 1

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "cron-checker-bot" {
      driver = "raw_exec"

      artifact {
        source      = "http://10.63.153.74:8080/cron-checker-bot-arm64.tar.gz"
        destination = "local/app"
      }

      config {
        command = "/bin/sh"
        args = [
          "-c",
          "cd ${NOMAD_TASK_DIR}/app && exec /data/data/com.termux/files/usr/bin/python3 -u main.py",
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
