#!/bin/bash
# deploy-jobs.sh — Submit all Nomad job specs to the cluster.
# Run from your Mac after setup-cluster.sh has completed.
#
# This script registers/updates job specs with Nomad. It does NOT build or
# upload app code — use nomad-deploy.sh for that.
#
# For first-time setup, the recommended order is:
#   1. bash setup-cluster.sh          # cluster up
#   2. bash deploy-jobs.sh            # register all jobs (artifact-server + apps)
#   3. bash nomad-deploy.sh --all     # build artifacts, upload, restart apps
#
# For day-to-day code deploys, just: bash nomad-deploy.sh --app <name>
#
# Usage:
#   bash deploy-jobs.sh
#   NOMAD_ADDR=http://10.0.0.5:4646 bash deploy-jobs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOBS_DIR="$SCRIPT_DIR/jobs"
export NOMAD_ADDR="${NOMAD_ADDR:-http://phoneserver:4646}"

ALLOC_TIMEOUT="${ALLOC_TIMEOUT:-60}"  # seconds to wait for allocs to start
ALLOC_INTERVAL=5                       # seconds between polls

log()  { echo -e "\n\033[1;34m>>> $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠ $*\033[0m"; }

log "Deploying jobs to $NOMAD_ADDR"
echo ""

# Pre-flight: verify cluster is reachable
if ! nomad node status > /dev/null 2>&1; then
  echo "ERROR: Cannot reach Nomad at $NOMAD_ADDR"
  echo "Is the cluster running? Try: NOMAD_ADDR=http://<phone1-ip>:4646 bash deploy-jobs.sh"
  exit 1
fi

echo "Cluster nodes:"
nomad node status
echo ""

# Submit each job (--detach so it doesn't block on slow proot evaluations)
FAILED=0
SUBMITTED=()
for job_file in "$JOBS_DIR"/*.nomad.hcl; do
  name=$(basename "$job_file" .nomad.hcl)
  log "Deploying $name..."
  if nomad job run -detach "$job_file"; then
    ok "Submitted"
    SUBMITTED+=("$name")
  else
    warn "FAILED to submit"
    FAILED=$((FAILED + 1))
  fi
done

# ---------------------------------------------------------------------------
# Post-deploy: poll allocation status for submitted jobs
# ---------------------------------------------------------------------------
if [[ ${#SUBMITTED[@]} -gt 0 ]]; then
  log "Waiting up to ${ALLOC_TIMEOUT}s for allocations to start..."
  deadline=$((SECONDS + ALLOC_TIMEOUT))

  while (( SECONDS < deadline )); do
    all_settled=true
    for name in "${SUBMITTED[@]}"; do
      # Get latest alloc status — skip periodic parent jobs (they have no direct allocs)
      status=$(nomad job status -short "$name" 2>/dev/null \
        | awk '/Allocations/,0 { if ($0 ~ /running/) {print "running"; exit} if ($0 ~ /pending/) {print "pending"; exit} if ($0 ~ /failed/) {print "failed"; exit} }')
      if [[ "$status" == "pending" || -z "$status" ]]; then
        all_settled=false
      fi
    done
    $all_settled && break
    sleep "$ALLOC_INTERVAL"
  done

  echo ""
  log "Job status summary"
  printf "  %-25s %s\n" "JOB" "STATUS"
  printf "  %-25s %s\n" "---" "------"
  for name in "${SUBMITTED[@]}"; do
    status=$(nomad job status -short "$name" 2>/dev/null \
      | awk '/Allocations/,0 { if ($0 ~ /running/) {print "running"; exit} if ($0 ~ /pending/) {print "pending"; exit} if ($0 ~ /failed/) {print "failed"; exit} if ($0 ~ /complete/) {print "complete"; exit} if ($0 ~ /dead/) {print "dead"; exit} }')
    # Periodic or parameterized jobs may have no allocs
    [[ -z "$status" ]] && status="(periodic/no-alloc)"
    printf "  %-25s %s\n" "$name" "$status"
  done
fi

# Summary
echo ""
echo "========================================"
if [[ "$FAILED" -eq 0 ]]; then
  echo "All jobs submitted successfully."
else
  echo "$FAILED job(s) failed to submit."
fi
echo ""
echo "Dashboard: $NOMAD_ADDR"
