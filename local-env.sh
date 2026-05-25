#!/usr/bin/env bash
# local-env.sh — Sobe ambiente Docker local para qualquer projeto da Prefeitura.
# Uso: ./local-env.sh <start|stop|status|dump> <projeto>

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFEITURA_DIR="$(dirname "$INFRA_DIR")"
PROJECTS_YML="$INFRA_DIR/projects.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

CMD="${1:-}"
PROJECT_ID="${2:-}"

parse_yaml_field() {
    local project="$1" field="$2"
    python3 -c "
import yaml, sys
with open('$PROJECTS_YML') as f:
    data = yaml.safe_load(f)
proj = data.get('projects', {}).get('$project', {})
defaults = data.get('defaults', {})
val = proj.get('$field', defaults.get('$field', ''))
print(val)
" 2>/dev/null || echo ""
}

list_all_projects() {
    python3 -c "
import yaml
with open('$PROJECTS_YML') as f:
    data = yaml.safe_load(f)
for pid, p in data.get('projects', {}).items():
    port = p.get('docker_port', '?')
    name = p.get('name', pid)
    print(f'{pid}:{port}:{name}')
" 2>/dev/null
}

# ─── Gera docker-compose.yml para projetos sem Docker ─────────────────────────
generate_docker_compose() {
    local project_id="$1" project_dir="$2"
    local docker_port db_name project_name
    docker_port=$(parse_yaml_field "$project_id" "docker_port")
    db_name=$(parse_yaml_field "$project_id" "db_name")
    project_name=$(parse_yaml_field "$project_id" "name")

    local pma_port=$((docker_port + 100))
    local db_port=$((docker_port + 200))

    cat > "$project_dir/docker-compose.yml" << EOF
# Auto-gerado por local-env.sh para: $project_name
services:
  web:
    image: php:8.3-apache
    ports:
      - "$docker_port:80"
    volumes:
      - .:/var/www/html
    environment:
      - DOCKER_ENV=1
    depends_on:
      - db

  db:
    image: mariadb:11
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: $db_name
      MYSQL_USER: app
      MYSQL_PASSWORD: app
    ports:
      - "$db_port:3306"
    volumes:
      - db_data:/var/lib/mysql

  pma:
    image: phpmyadmin/phpmyadmin
    ports:
      - "$pma_port:80"
    environment:
      PMA_HOST: db
      PMA_USER: root
      PMA_PASSWORD: root

volumes:
  db_data:
EOF
    echo -e "${GREEN}[local-env]${RESET} docker-compose.yml gerado em $project_dir"
}

# ─── START ────────────────────────────────────────────────────────────────────
cmd_start() {
    local project_id="$1"
    local project_dir="$PREFEITURA_DIR"

    # Mapear ID para diretório real
    case "$project_id" in
        sema)        project_dir="$PREFEITURA_DIR/sema-php" ;;
        estagio)     project_dir="$PREFEITURA_DIR/Estagio" ;;
        junta)       project_dir="$PREFEITURA_DIR/Junta medica" ;;
        demutran)    project_dir="$PREFEITURA_DIR/Demutran" ;;
        curtapdf)    project_dir="$PREFEITURA_DIR/curtapdf" ;;
        protocolo)   project_dir="$PREFEITURA_DIR/Protocolo_SEAD" ;;
        estagiario-pdf) project_dir="$PREFEITURA_DIR/Estagiario-PrefeituraPDF" ;;
        votacao)     project_dir="$PREFEITURA_DIR/votacao_centro" ;;
        logs)        project_dir="$PREFEITURA_DIR/Logs" ;;
        *)
            echo -e "${RED}[local-env]${RESET} Projeto desconhecido: $project_id"
            exit 1
            ;;
    esac

    local docker_port project_name
    docker_port=$(parse_yaml_field "$project_id" "docker_port")
    project_name=$(parse_yaml_field "$project_id" "name")

    echo -e "${CYAN}[local-env]${RESET} Iniciando: ${BOLD}${project_name}${RESET}"

    if [[ ! -f "$project_dir/docker-compose.yml" ]]; then
        echo -e "${YELLOW}[local-env]${RESET} Nenhum docker-compose.yml encontrado. Gerando..."
        generate_docker_compose "$project_id" "$project_dir"
    fi

    cd "$project_dir"

    # Para sema-php usa o script próprio se disponível
    if [[ "$project_id" == "sema" ]] && [[ -f "./run.sh" ]]; then
        ./run.sh start
    else
        docker compose up -d
    fi

    echo -e "${GREEN}[local-env]${RESET} ${project_name} rodando em http://localhost:${docker_port}"
    local pma_port=$((docker_port + 100))
    echo -e "${GREEN}[local-env]${RESET} phpMyAdmin em http://localhost:${pma_port}"
}

# ─── STOP ─────────────────────────────────────────────────────────────────────
cmd_stop() {
    local project_id="$1"
    local project_dir="$PREFEITURA_DIR"

    case "$project_id" in
        sema)        project_dir="$PREFEITURA_DIR/sema-php" ;;
        estagio)     project_dir="$PREFEITURA_DIR/Estagio" ;;
        junta)       project_dir="$PREFEITURA_DIR/Junta medica" ;;
        demutran)    project_dir="$PREFEITURA_DIR/Demutran" ;;
        curtapdf)    project_dir="$PREFEITURA_DIR/curtapdf" ;;
        protocolo)   project_dir="$PREFEITURA_DIR/Protocolo_SEAD" ;;
        estagiario-pdf) project_dir="$PREFEITURA_DIR/Estagiario-PrefeituraPDF" ;;
        votacao)     project_dir="$PREFEITURA_DIR/votacao_centro" ;;
        logs)        project_dir="$PREFEITURA_DIR/Logs" ;;
    esac

    echo -e "${CYAN}[local-env]${RESET} Parando $project_id..."
    cd "$project_dir"
    docker compose down
    echo -e "${GREEN}[local-env]${RESET} $project_id parado."
}

# ─── STATUS ───────────────────────────────────────────────────────────────────
cmd_status() {
    echo ""
    echo -e "${BOLD}Status dos Ambientes Locais:${RESET}"
    echo "─────────────────────────────────────────"
    while IFS=: read -r pid port name; do
        if curl -s --max-time 1 "http://localhost:$port" > /dev/null 2>&1; then
            echo -e "  ${GREEN}●${RESET} ${BOLD}${pid}${RESET} — $name (http://localhost:${port})"
        else
            echo -e "  ${RED}○${RESET} ${pid} — $name (porta $port)"
        fi
    done <<< "$(list_all_projects)"
    echo ""
}

# ─── DUMP (produção → local) ──────────────────────────────────────────────────
cmd_dump() {
    local project_id="$1"
    "$INFRA_DIR/dump.sh" "$project_id"
}

# ─── HELP ─────────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${BOLD}local-env.sh${RESET} — Gerenciador de ambientes locais"
    echo ""
    echo "Uso:"
    echo "  ./local-env.sh start  <projeto>   Inicia Docker do projeto"
    echo "  ./local-env.sh stop   <projeto>   Para Docker do projeto"
    echo "  ./local-env.sh status             Lista projetos rodando"
    echo "  ./local-env.sh dump   <projeto>   Puxa SQL de produção para local"
    echo ""
    echo "Projetos disponíveis:"
    while IFS=: read -r pid port name; do
        echo "  ${pid} → $name (porta $port)"
    done <<< "$(list_all_projects)"
    echo ""
}

# ─── Roteamento ───────────────────────────────────────────────────────────────
case "$CMD" in
    start)
        [[ -z "$PROJECT_ID" ]] && { show_help; exit 1; }
        cmd_start "$PROJECT_ID"
        ;;
    stop)
        [[ -z "$PROJECT_ID" ]] && { show_help; exit 1; }
        cmd_stop "$PROJECT_ID"
        ;;
    status)
        cmd_status
        ;;
    dump)
        [[ -z "$PROJECT_ID" ]] && { show_help; exit 1; }
        cmd_dump "$PROJECT_ID"
        ;;
    *)
        show_help
        ;;
esac
