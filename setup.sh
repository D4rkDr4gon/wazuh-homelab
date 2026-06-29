#!/bin/bash
# =============================================================================
# Wazuh Home Lab — Setup Script
# =============================================================================
# This script deploys a single-node Wazuh SIEM stack using Docker Compose.
# It checks prerequisites, generates certificates, and starts the stack.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
WAZUH_VERSION="4.14.5"
COMPOSE_FILE="docker-compose.yml"

# -----------------------------------------------------------------------------
# Prerequisites check
# -----------------------------------------------------------------------------
check_prerequisites() {
    echo ""
    echo "=============================================="
    echo "  Wazuh Home Lab v${WAZUH_VERSION} — Setup"
    echo "=============================================="
    echo ""

    log_info "Checking prerequisites..."

    # Docker
    if command -v docker &>/dev/null; then
        log_ok "Docker found: $(docker --version 2>/dev/null)"
        # Check if Docker is running
        if docker info &>/dev/null; then
            log_ok "Docker daemon is running"
        else
            log_error "Docker daemon is not running. Start it with: sudo systemctl start docker"
            exit 1
        fi
    else
        log_error "Docker is not installed. Install it first: https://docs.docker.com/engine/install/"
        exit 1
    fi

    # Docker Compose plugin
    if docker compose version &>/dev/null; then
        log_ok "Docker Compose plugin: $(docker compose version 2>/dev/null)"
    else
        log_error "Docker Compose plugin not found. Install: docker-compose-plugin"
        exit 1
    fi

    # vm.max_map_count
    CURRENT_MAP_COUNT=$(sysctl -n vm.max_map_count 2>/dev/null || echo "0")
    if [ "$CURRENT_MAP_COUNT" -ge 262144 ]; then
        log_ok "vm.max_map_count = $CURRENT_MAP_COUNT (≥ 262144)"
    else
        log_warn "vm.max_map_count = $CURRENT_MAP_COUNT (< 262144)"
        log_info "Setting vm.max_map_count to 262144..."
        echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sysctl.conf >/dev/null
        sudo sysctl -p >/dev/null
        log_ok "vm.max_map_count set to 262144"
    fi

    # Check available memory (rough estimate)
    TOTAL_MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    if [ "$TOTAL_MEM_GB" -ge 8 ]; then
        log_ok "System memory: ${TOTAL_MEM_GB} GB (sufficient)"
    elif [ "$TOTAL_MEM_GB" -ge 4 ]; then
        log_warn "System memory: ${TOTAL_MEM_GB} GB (minimum). Consider upgrading to 8 GB+"
    else
        log_error "System memory: ${TOTAL_MEM_GB} GB (insufficient). Minimum 4 GB required."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Generate certificates
# -----------------------------------------------------------------------------
generate_certificates() {
    echo ""
    log_info "Generating SSL certificates..."

    if [ -f "config/wazuh_indexer_ssl_certs/root-ca.pem" ]; then
        log_warn "Certificates already exist. Skipping generation."
        log_info "To regenerate, delete config/wazuh_indexer_ssl_certs/ and re-run."
        return
    fi

    if [ ! -f "scripts/wazuh-certs-tool.sh" ]; then
        log_info "Downloading certificate tool..."
        mkdir -p scripts
        curl -sL "https://raw.githubusercontent.com/wazuh/wazuh/v${WAZUH_VERSION}/extensions/certs-tools/wazuh-certs-tool.sh" \
            -o scripts/wazuh-certs-tool.sh
        chmod +x scripts/wazuh-certs-tool.sh
    fi

    mkdir -p config/wazuh_indexer_ssl_certs

    # Generate all certificates
    bash scripts/wazuh-certs-tool.sh -A

    # Move certificates to config directory
    mv -f *.pem config/wazuh_indexer_ssl_certs/ 2>/dev/null || true
    mv -f *.key config/wazuh_indexer_ssl_certs/ 2>/dev/null || true

    log_ok "Certificates generated successfully"
}

# -----------------------------------------------------------------------------
# Deploy stack
# -----------------------------------------------------------------------------
deploy_stack() {
    echo ""
    log_info "Deploying Wazuh stack..."

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "docker-compose.yml not found in current directory"
        exit 1
    fi

    # Pull images
    log_info "Pulling Docker images (this may take a while)..."
    docker compose pull

    # Start containers
    log_info "Starting containers..."
    docker compose up -d

    echo ""
    log_info "Waiting for services to start (this can take 2-3 minutes)..."
    log_info "Checking indexer health..."
    for i in $(seq 1 12); do
        if docker inspect wazuh-indexer --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
            log_ok "Indexer is healthy"
            break
        fi
        echo -n "."
        sleep 10
    done
    echo ""

    log_info "Checking dashboard health..."
    for i in $(seq 1 6); do
        if docker inspect wazuh-dashboard --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
            log_ok "Dashboard is healthy"
            break
        fi
        echo -n "."
        sleep 10
    done
    echo ""
}

# -----------------------------------------------------------------------------
# Post-installation summary
# -----------------------------------------------------------------------------
show_summary() {
    echo ""
    echo "=============================================="
    echo "  ✅ Wazuh Home Lab deployed successfully!"
    echo "=============================================="
    echo ""
    echo "  Dashboard:  https://localhost:8443"
    echo "  OpenSearch: https://localhost:9200"
    echo "  API:        https://localhost:55000"
    echo ""
    echo "  Default credentials:"
    echo "    User:     admin"
    echo "    Password: admin"
    echo ""
    echo "  🚨  CHANGE YOUR PASSWORDS AFTER FIRST LOGIN!"
    echo ""
    echo "  Containers:"
    docker ps --filter "name=wazuh" --format "  - {{.Names}} ({{.Image}}, {{.Status}})"
    echo ""
    echo "  Next steps:"
    echo "  1. Open https://localhost:8443 in your browser"
    echo "  2. Log in with admin:admin"
    echo "  3. Go to Security → Users and change the password"
    echo "  4. Deploy agents on your endpoints"
    echo ""
    echo "  For more info: https://documentation.wazuh.com"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    cd "$(dirname "$0")"

    check_prerequisites
    generate_certificates
    deploy_stack
    show_summary
}

main "$@"
