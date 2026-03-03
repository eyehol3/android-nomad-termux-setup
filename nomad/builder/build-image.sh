#!/usr/bin/env bash
# Build the termux-builder Docker image.
# Resolves DNS at build time (since dnsmasq is broken inside the Termux container).
set -euo pipefail
cd "$(dirname "$0")"

IMAGE_NAME="${1:-termux-builder}"

echo "==> Resolving DNS for Termux package/pip repos..."

resolve() {
  # Try dig first, fall back to nslookup
  local ip
  ip=$(dig +short "$1" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
  if [[ -z "$ip" ]]; then
    ip=$(nslookup "$1" 2>/dev/null | awk '/^Address:/{a=$2} END{print a}')
  fi
  echo "$ip"
}

TERMUX_IP=$(resolve packages-cf.termux.dev)
PYPI_IP=$(resolve pypi.org)
FILES_PY_IP=$(resolve files.pythonhosted.org)
NODEJS_IP=$(resolve nodejs.org)
REGISTRY_NPM_IP=$(resolve registry.npmjs.org)
GITHUB_IP=$(resolve github.com)
CRATES_IP=$(resolve crates.io)
STATIC_CRATES_IP=$(resolve static.crates.io)
INDEX_CRATES_IP=$(resolve index.crates.io)

echo "   packages-cf.termux.dev  -> $TERMUX_IP"
echo "   pypi.org                -> $PYPI_IP"
echo "   files.pythonhosted.org  -> $FILES_PY_IP"
echo "   nodejs.org              -> $NODEJS_IP"
echo "   registry.npmjs.org      -> $REGISTRY_NPM_IP"
echo "   github.com              -> $GITHUB_IP"
echo "   crates.io               -> $CRATES_IP"
echo "   static.crates.io        -> $STATIC_CRATES_IP"
echo "   index.crates.io         -> $INDEX_CRATES_IP"

# Generate system-hosts file for COPY into the image
cat > system-hosts <<EOF
127.0.0.1 localhost
${TERMUX_IP} packages-cf.termux.dev
${PYPI_IP} pypi.org
${FILES_PY_IP} files.pythonhosted.org
${NODEJS_IP} nodejs.org
${REGISTRY_NPM_IP} registry.npmjs.org
${GITHUB_IP} github.com
${CRATES_IP} crates.io
${STATIC_CRATES_IP} static.crates.io
${INDEX_CRATES_IP} index.crates.io
EOF

echo ""
echo "==> Building Docker image '${IMAGE_NAME}'..."

# --add-host flags provide DNS during the build itself (for apt/pip/npm)
docker build \
  --add-host="packages-cf.termux.dev:${TERMUX_IP}" \
  --add-host="packages.termux.dev:${TERMUX_IP}" \
  --add-host="pypi.org:${PYPI_IP}" \
  --add-host="files.pythonhosted.org:${FILES_PY_IP}" \
  --add-host="nodejs.org:${NODEJS_IP}" \
  --add-host="registry.npmjs.org:${REGISTRY_NPM_IP}" \
  --add-host="github.com:${GITHUB_IP}" \
  --add-host="crates.io:${CRATES_IP}" \
  --add-host="static.crates.io:${STATIC_CRATES_IP}" \
  --add-host="index.crates.io:${INDEX_CRATES_IP}" \
  -t "${IMAGE_NAME}" \
  .

echo ""
echo "==> Done! Image '${IMAGE_NAME}' is ready."
echo "    Test with: docker run --rm ${IMAGE_NAME} python3 -c 'print(\"hello from termux\")'"
