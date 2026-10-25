#!/usr/bin/env bash
# ==============================================================================
# OpenShorts Orchestration Script (run.sh)
# DevOps & Container Management for OpenShorts.app
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ------------------------------------------------------------------------------
# Colors and Logging Formats
# ------------------------------------------------------------------------------
BOLD=$'\033[1m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_step() {
    echo -e "${CYAN}${BOLD}==>${NC} ${BOLD}$*${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# ------------------------------------------------------------------------------
# Global Defaults
# ------------------------------------------------------------------------------
COMPOSE_FILES=("-f" "docker-compose.yml")
DETACH_MODE=false
BUILD_BEFORE_RUN=false
GPU_MODE="auto" # auto | on | off
CLOUD_MODE=false
OVERRIDE_FILE="docker-compose.override.yml"
OVERRIDE_BACKUP="docker-compose.override.yml.bak"

# ------------------------------------------------------------------------------
# Helper: Print Usage
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF
${BOLD}Penggunaan:${NC}
  ./run.sh [PERINTAH] [OPSI...]

${BOLD}Perintah (Commands):${NC}
  start | up        Menjalankan stack container OpenShorts (default)
  stop  | down      Menghentikan dan menghapus container OpenShorts
  restart           Merestart seluruh container OpenShorts
  build             Melakukan build/rebuild image Docker tanpa menjalankan
  logs              Melihat log container secara realtime (default: semua container)
  status | ps       Melihat status dan kesehatan container yang sedang berjalan
  shell [service]   Membuka shell interaktif ke dalam container (default: backend)
  health            Memeriksa ketersediaan endpoint aplikasi (healthcheck)
  clean             Membersihkan container yang berhenti, volume tak terpakai, dan cache
  help              Menampilkan bantuan ini

${BOLD}Opsi (Options):${NC}
  -d, --detach      Jalankan container di latar belakang (background / detached mode)
  -b, --build       Paksa build ulang image sebelum menjalankan container
  --gpu             Paksa aktifkan akselerasi NVIDIA GPU (NVENC & CUDA)
  --cpu             Paksa gunakan mode CPU-only
  --cloud           Aktifkan mode cloud (menyertakan PostgreSQL dari docker-compose.cloud.yml)
  -h, --help        Tampilkan pesan bantuan

${BOLD}Contoh Penggunaan:${NC}
  ./run.sh                     # Jalankan OpenShorts secara interaktif (foreground)
  ./run.sh start -d            # Jalankan di background
  ./run.sh start -d --gpu      # Jalankan dengan akselerasi NVIDIA GPU
  ./run.sh start -d --cloud    # Jalankan dengan database PostgreSQL (cloud mode)
  ./run.sh logs backend        # Pantau log service backend
  ./run.sh shell frontend      # Masuk ke terminal container frontend
  ./run.sh down                # Hentikan semua service
EOF
}

# ------------------------------------------------------------------------------
# 1. Prerequisite Checks: Docker & Docker Compose
# ------------------------------------------------------------------------------
check_docker() {
    log_step "Memeriksa dependensi Docker..."

    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker CLI tidak ditemukan di sistem! Silakan install Docker terlebih dahulu."
        exit 1
    fi

    # Determine compose command: 'docker compose' vs 'docker-compose'
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        log_error "Docker Compose (plugin v2 atau standalone v1) tidak ditemukan!"
        exit 1
    fi

    # Check if Docker daemon is running and current user has permissions
    if ! docker info >/dev/null 2>&1; then
        log_error "Tidak dapat berkomunikasi dengan Docker daemon!"
        log_warn "Pastikan Docker service telah aktif ('sudo systemctl start docker') dan user Anda terdaftar di grup docker:"
        log_warn "  sudo usermod -aG docker \$USER && newgrp docker"
        exit 1
    fi

    log_success "Docker daemon aktif ($(${DOCKER_COMPOSE_CMD} version --short 2>/dev/null || echo 'Compose ready'))."
}

# ------------------------------------------------------------------------------
# 2. Environment Configuration (.env) Check
# ------------------------------------------------------------------------------
check_env() {
    log_step "Memeriksa file konfigurasi environment (.env)..."

    if [[ ! -f ".env" ]]; then
        if [[ -f ".env.example" ]]; then
            log_warn "File .env tidak ditemukan. Menyalin template dari .env.example..."
            cp .env.example .env
            log_success "File .env berhasil dibuat dari .env.example."
            log_warn "CATATAN: Silakan sesuaikan variabel dan API key (Gemini, fal.ai, ElevenLabs, AWS S3) jika diperlukan."
        else
            log_warn "File .env maupun .env.example tidak ditemukan. Membuat .env kosong."
            touch .env
        fi
    else
        log_info "File .env ditemukan."
    fi
}

# ------------------------------------------------------------------------------
# 3. Directory and Volume Permissions Setup
# ------------------------------------------------------------------------------
prepare_storage() {
    log_step "Menyiapkan direktori volume lokal & hak akses..."

    # Menghindari issue permission Docker ketika container berjalan sebagai non-root (appuser)
    local dirs=("output" "uploads" ".cache" ".cache/huggingface" "dashboard/node_modules")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            log_info "Membuat direktori '${dir}'..."
            mkdir -p "${dir}"
        fi
    done

    # Pastikan direktori writable
    chmod -R 775 output uploads .cache 2>/dev/null || true
    log_success "Direktori penyimpanan volume siap."
}

# ------------------------------------------------------------------------------
# 4. GPU Detection & Override Configuration
# ------------------------------------------------------------------------------
configure_gpu() {
    log_step "Memeriksa konfigurasi GPU / CPU..."

    local has_nvidia=false
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            has_nvidia=true
        fi
    fi

    local enable_gpu=false

    if [[ "${GPU_MODE}" == "on" ]]; then
        if [[ "${has_nvidia}" == "false" ]]; then
            log_warn "Mode --gpu diaktifkan, namun 'nvidia-smi' tidak merespons atau tidak ditemukan."
            log_warn "Tetap melanjutkan dengan konfigurasi GPU Docker..."
        fi
        enable_gpu=true
    elif [[ "${GPU_MODE}" == "off" ]]; then
        log_info "Mode CPU dipaksa via flag (--cpu)."
        enable_gpu=false
    else
        # Auto mode
        if [[ "${has_nvidia}" == "true" ]]; then
            log_info "NVIDIA GPU terdeteksi di sistem host."
            # Cek apakah docker container runtime nvidia tersedia
            if docker info 2>/dev/null | grep -iq "nvidia"; then
                log_info "NVIDIA Container Toolkit terdeteksi. Mengaktifkan akselerasi GPU otomatis."
                enable_gpu=true
            else
                log_warn "NVIDIA GPU terdeteksi tetapi runtime NVIDIA Docker belum terkonfigurasi."
                log_warn "Menjalankan dalam mode CPU. Untuk mengaktifkan GPU, install nvidia-container-toolkit."
                enable_gpu=false
            fi
        else
            log_info "Tidak ada NVIDIA GPU terdeteksi. Menjalankan dalam mode CPU (default)."
            enable_gpu=false
        fi
    fi

    if [[ "${enable_gpu}" == "true" ]]; then
        log_info "Menyiapkan ${OVERRIDE_FILE} untuk akselerasi GPU (CUDA + NVENC)..."
        cat << 'EOF' > "${OVERRIDE_FILE}"
services:
  backend:
    build:
      context: .
      args:
        GPU: "1"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu, video]
EOF
        log_success "Konfigurasi GPU aktif (${OVERRIDE_FILE})."
    else
        # Jika file override sebelumnya ada dan berisi konfigurasi nvidia, nonaktifkan agar CPU build tidak gagal
        if [[ -f "${OVERRIDE_FILE}" ]]; then
            if grep -q "driver: nvidia" "${OVERRIDE_FILE}"; then
                log_info "Menonaktifkan ${OVERRIDE_FILE} GPU untuk mode CPU (disimpan sebagai ${OVERRIDE_BACKUP})..."
                mv "${OVERRIDE_FILE}" "${OVERRIDE_BACKUP}"
            fi
        fi
        log_info "Mode CPU siap."
    fi
}

# ------------------------------------------------------------------------------
# 5. Cloud Mode Handling
# ------------------------------------------------------------------------------
configure_cloud_mode() {
    if [[ "${CLOUD_MODE}" == "true" ]]; then
        log_step "Mengaktifkan Cloud Mode (PostgreSQL & Billing dependencies)..."
        if [[ ! -f "docker-compose.cloud.yml" ]]; then
            log_error "File 'docker-compose.cloud.yml' tidak ditemukan!"
            exit 1
        fi
        COMPOSE_FILES+=("-f" "docker-compose.cloud.yml")
        
        # Validasi POSTGRES_PASSWORD di .env jika cloud mode
        if ! grep -q "^POSTGRES_PASSWORD=" .env 2>/dev/null || grep -q "^POSTGRES_PASSWORD=$" .env 2>/dev/null; then
            log_warn "POSTGRES_PASSWORD belum disetel di .env. Membuat password acak untuk database cloud..."
            local generated_pass
            generated_pass=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
            echo "POSTGRES_PASSWORD=${generated_pass}" >> .env
            log_success "POSTGRES_PASSWORD telah ditambahkan ke .env."
        fi
    fi
}

# ------------------------------------------------------------------------------
# 6. Service Execution Handlers
# ------------------------------------------------------------------------------
cmd_up() {
    check_docker
    check_env
    prepare_storage
    configure_gpu
    configure_cloud_mode

    local compose_args=("${COMPOSE_FILES[@]}")

    if [[ "${BUILD_BEFORE_RUN}" == "true" ]]; then
        log_step "Melakukan build image container..."
        ${DOCKER_COMPOSE_CMD} "${compose_args[@]}" build
    fi

    log_step "Menjalankan container OpenShorts..."
    if [[ "${DETACH_MODE}" == "true" ]]; then
        ${DOCKER_COMPOSE_CMD} "${compose_args[@]}" up -d
        print_post_run_info
    else
        log_info "Menjalankan dalam mode interaktif (Ctrl+C untuk menghentikan)."
        print_post_run_info
        ${DOCKER_COMPOSE_CMD} "${compose_args[@]}" up
    fi
}

cmd_down() {
    check_docker
    log_step "Menghentikan container OpenShorts..."
    
    # Kumpulkan compose files jika cloud mode ada
    local files=("-f" "docker-compose.yml")
    if [[ -f "docker-compose.cloud.yml" ]]; then
        files+=("-f" "docker-compose.cloud.yml")
    fi
    if [[ -f "${OVERRIDE_FILE}" ]]; then
        files+=("-f" "${OVERRIDE_FILE}")
    fi

    ${DOCKER_COMPOSE_CMD} "${files[@]}" down --remove-orphans
    log_success "Semua container telah dihentikan."
}

cmd_restart() {
    log_step "Merestart container..."
    cmd_down
    cmd_up
}

cmd_build() {
    check_docker
    check_env
    prepare_storage
    configure_gpu
    configure_cloud_mode

    log_step "Melakukan build image Docker OpenShorts..."
    ${DOCKER_COMPOSE_CMD} "${COMPOSE_FILES[@]}" build "$@"
    log_success "Build selesai."
}

cmd_logs() {
    check_docker
    local service="${1:-}"
    shift 2>/dev/null || true
    
    local files=("-f" "docker-compose.yml")
    if [[ -f "${OVERRIDE_FILE}" ]]; then
        files+=("-f" "${OVERRIDE_FILE}")
    fi
    if [[ -f "docker-compose.cloud.yml" ]]; then
        files+=("-f" "docker-compose.cloud.yml")
    fi

    if [[ -n "${service}" ]]; then
        log_info "Menampilkan logs untuk service '${service}'..."
        ${DOCKER_COMPOSE_CMD} "${files[@]}" logs -f --tail=100 "${service}" "$@"
    else
        log_info "Menampilkan logs semua container (gunakan Ctrl+C untuk keluar)..."
        ${DOCKER_COMPOSE_CMD} "${files[@]}" logs -f --tail=100 "$@"
    fi
}

cmd_status() {
    check_docker
    log_step "Status container OpenShorts:"
    local files=("-f" "docker-compose.yml")
    if [[ -f "${OVERRIDE_FILE}" ]]; then
        files+=("-f" "${OVERRIDE_FILE}")
    fi
    ${DOCKER_COMPOSE_CMD} "${files[@]}" ps
}

cmd_shell() {
    check_docker
    local service="${1:-backend}"
    log_info "Membuka bash shell di container '${service}'..."
    ${DOCKER_COMPOSE_CMD} exec -it "${service}" /bin/bash || \
    ${DOCKER_COMPOSE_CMD} exec -it "${service}" /bin/sh
}

cmd_health() {
    log_step "Memeriksa status endpoint aplikasi..."
    
    echo -n "• Backend API (http://localhost:8000/health/ready): "
    if curl -sf "http://localhost:8000/health/ready" >/dev/null 2>&1; then
        echo -e "${GREEN}HEALTHY (Ready)${NC}"
    else
        echo -e "${RED}UNAVAILABLE${NC}"
    fi

    echo -n "• Frontend Dashboard (http://localhost:5175): "
    if curl -sf "http://localhost:5175" >/dev/null 2>&1; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}UNAVAILABLE${NC}"
    fi

    echo -n "• Remotion Renderer (http://localhost:3100): "
    if curl -sf "http://localhost:3100" >/dev/null 2>&1; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${YELLOW}WAITING / UNAVAILABLE${NC}"
    fi
}

cmd_clean() {
    check_docker
    log_warn "Membersihkan container, volume lokal dangling, dan file temporary..."
    read -p "Apakah Anda yakin ingin melanjutkan pembersihan? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local files=("-f" "docker-compose.yml")
        if [[ -f "${OVERRIDE_FILE}" ]]; then
            files+=("-f" "${OVERRIDE_FILE}")
        fi
        ${DOCKER_COMPOSE_CMD} "${files[@]}" down -v --remove-orphans
        docker system prune -f
        log_success "Pembersihan selesai."
    else
        log_info "Pembersihan dibatalkan."
    fi
}

print_post_run_info() {
    echo ""
    echo -e "${GREEN}${BOLD}================================================================${NC}"
    echo -e "${GREEN}${BOLD}           OpenShorts Container Berhasil Dijalankan!            ${NC}"
    echo -e "${GREEN}${BOLD}================================================================${NC}"
    echo -e " Akses layanan aplikasi melalui browser Anda:"
    echo -e "   • ${BOLD}Web Dashboard:${NC}      ${CYAN}http://localhost:5175${NC}"
    echo -e "   • ${BOLD}Backend REST API:${NC}   ${CYAN}http://localhost:8000/docs${NC} (Swagger UI)"
    echo -e "   • ${BOLD}MCP Server Endpoint:${NC}${CYAN}http://localhost:8000/mcp${NC}"
    echo -e "   • ${BOLD}Remotion Renderer:${NC}  ${CYAN}http://localhost:3100${NC}"
    echo -e ""
    echo -e " Perintah penting:"
    echo -e "   • Cek logs:             ${YELLOW}./run.sh logs${NC}"
    echo -e "   • Cek logs backend:     ${YELLOW}./run.sh logs backend${NC}"
    echo -e "   • Cek status:           ${YELLOW}./run.sh status${NC}"
    echo -e "   • Hentikan container:   ${YELLOW}./run.sh stop${NC}"
    echo -e "${GREEN}${BOLD}================================================================${NC}"
    echo ""
}

# ------------------------------------------------------------------------------
# 7. Argument Parsing & CLI Router
# ------------------------------------------------------------------------------
COMMAND="up"

while [[ $# -gt 0 ]]; do
    case "$1" in
        start|up)
            COMMAND="up"
            shift
            ;;
        stop|down)
            COMMAND="down"
            shift
            ;;
        restart)
            COMMAND="restart"
            shift
            ;;
        build)
            COMMAND="build"
            shift
            ;;
        logs)
            COMMAND="logs"
            shift
            break # Sisa argument dioper ke logs
            ;;
        status|ps)
            COMMAND="status"
            shift
            ;;
        shell|sh)
            COMMAND="shell"
            shift
            break # Sisa argument dioper ke shell
            ;;
        health)
            COMMAND="health"
            shift
            ;;
        clean)
            COMMAND="clean"
            shift
            ;;
        help|-h|--help)
            show_help
            exit 0
            ;;
        -d|--detach)
            DETACH_MODE=true
            shift
            ;;
        -b|--build)
            BUILD_BEFORE_RUN=true
            shift
            ;;
        --gpu)
            GPU_MODE="on"
            shift
            ;;
        --cpu)
            GPU_MODE="off"
            shift
            ;;
        --cloud)
            CLOUD_MODE=true
            shift
            ;;
        *)
            log_error "Opsi atau perintah tidak dikenal: $1"
            show_help
            exit 1
            ;;
    esac
done

# Route commands
case "${COMMAND}" in
    up)
        cmd_up
        ;;
    down)
        cmd_down
        ;;
    restart)
        cmd_restart
        ;;
    build)
        cmd_build "$@"
        ;;
    logs)
        cmd_logs "$@"
        ;;
    status)
        cmd_status
        ;;
    shell)
        cmd_shell "$@"
        ;;
    health)
        cmd_health
        ;;
    clean)
        cmd_clean
        ;;
esac
