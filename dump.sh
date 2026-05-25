#!/usr/bin/env bash
# dump.sh — Puxa SQL dump de produção e injeta no container local.
# Uso: ./dump.sh <projeto>

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFEITURA_DIR="$(dirname "$INFRA_DIR")"
PROJECTS_YML="$INFRA_DIR/projects.yml"
DUMPS_DIR="$INFRA_DIR/dumps"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

PROJECT_ID="${1:-}"

if [[ -z "$PROJECT_ID" ]]; then
    echo -e "${RED}[dump]${RESET} Informe o projeto. Exemplo: ./dump.sh sema"
    exit 1
fi

parse_yaml_field() {
    local project="$1" field="$2"
    python3 -c "
import yaml
with open('$PROJECTS_YML') as f:
    data = yaml.safe_load(f)
proj = data.get('projects', {}).get('$project', {})
defaults = data.get('defaults', {})
val = proj.get('$field', defaults.get('$field', ''))
print(val)
" 2>/dev/null || echo ""
}

SSH_HOST=$(parse_yaml_field "$PROJECT_ID" "ssh_host")
SSH_PORT=$(parse_yaml_field "$PROJECT_ID" "ssh_port")
SSH_USER=$(parse_yaml_field "$PROJECT_ID" "ssh_user")
SSH_KEY=$(parse_yaml_field "$PROJECT_ID" "ssh_key")
DB_HOST=$(parse_yaml_field "$PROJECT_ID" "db_host")
DB_NAME=$(parse_yaml_field "$PROJECT_ID" "db_name")
DB_USER=$(parse_yaml_field "$PROJECT_ID" "db_user")
DOCKER_PORT=$(parse_yaml_field "$PROJECT_ID" "docker_port")
PROJECT_NAME=$(parse_yaml_field "$PROJECT_ID" "name")

if [[ -z "$DB_NAME" ]]; then
    echo -e "${YELLOW}[dump]${RESET} Projeto $PROJECT_ID não tem banco de dados configurado."
    exit 0
fi

mkdir -p "$DUMPS_DIR"

DUMP_FILE="$DUMPS_DIR/${PROJECT_ID}_$(date +%Y%m%d_%H%M%S).sql"

echo -e "${CYAN}[dump]${RESET} Buscando dump de: ${BOLD}${PROJECT_NAME}${RESET}"
echo -e "         Banco: $DB_NAME @ $DB_HOST"
echo -e "         Salvando em: $DUMP_FILE"
echo ""
echo -e "${YELLOW}ATENÇÃO:${RESET} Você precisará digitar a senha do banco."
echo -n "Senha do banco ($DB_USER): "
read -rs DB_PASS
echo ""

echo -e "${CYAN}[dump]${RESET} Conectando via SSH e fazendo dump..."
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    "$SSH_USER@$SSH_HOST" \
    "mysqldump -h $DB_HOST -u $DB_USER -p'$DB_PASS' $DB_NAME" \
    > "$DUMP_FILE"

local_size=$(du -sh "$DUMP_FILE" | cut -f1)
echo -e "${GREEN}[dump]${RESET} Dump salvo: $DUMP_FILE ($local_size)"

# Verificar se Docker está rodando para o projeto
DB_CONTAINER="${PROJECT_ID}-db-1"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$DB_CONTAINER"; then
    echo ""
    echo -n "Container '$DB_CONTAINER' encontrado. Injetar dump localmente? (s/N): "
    read -r inject
    if [[ "$inject" == "s" ]] || [[ "$inject" == "S" ]]; then
        echo -e "${CYAN}[dump]${RESET} Injetando no container local..."
        docker exec -i "$DB_CONTAINER" mysql -u root -proot "$DB_NAME" < "$DUMP_FILE"
        echo -e "${GREEN}[dump]${RESET} Dump injetado com sucesso em localhost!"
    fi
else
    echo -e "${YELLOW}[dump]${RESET} Container local não encontrado ($DB_CONTAINER)."
    echo -e "         Execute './local-env.sh start $PROJECT_ID' e depois injete manualmente:"
    echo -e "         docker exec -i $DB_CONTAINER mysql -u root -proot $DB_NAME < $DUMP_FILE"
fi
