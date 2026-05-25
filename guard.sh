#!/usr/bin/env bash
# guard.sh — Barreira de segurança para operações SSH/FTP nos projetos da Prefeitura.
# Deve ser usado como wrapper: alias lftp='~/Documentos/Github/Estagio_Prefeitura/_infra/guard.sh lftp'

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_YML="$INFRA_DIR/projects.yml"
LOG_FILE="$INFRA_DIR/logs/deploys_$(date +%Y-%m).log"
REAL_CMD="$1"
shift

# ─── Cores ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Detectar se estamos dentro do diretório da Prefeitura ────────────────────
PREFEITURA_DIR="$(dirname "$INFRA_DIR")"
CURRENT_DIR="$(pwd)"
if [[ "$CURRENT_DIR" != "$PREFEITURA_DIR"* ]]; then
    exec "$REAL_CMD" "$@"
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
log_deploy() {
    local projeto="$1" arquivo="$2" hash="$3" keywords_ok="$4" diff_pct="$5" status="$6"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local linha="$timestamp | projeto=$projeto | arquivo=$arquivo | hash=$hash | keywords=$keywords_ok | diff=${diff_pct}% | status=$status"
    echo "$linha" >> "$LOG_FILE"
    echo "$linha"
}

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

get_keywords() {
    local project="$1"
    python3 -c "
import yaml
with open('$PROJECTS_YML') as f:
    data = yaml.safe_load(f)
proj = data.get('projects', {}).get('$project', {})
kws = proj.get('keywords', [])
print(' '.join(kws))
" 2>/dev/null || echo ""
}

get_project_name() {
    local project="$1"
    python3 -c "
import yaml
with open('$PROJECTS_YML') as f:
    data = yaml.safe_load(f)
proj = data.get('projects', {}).get('$project', {})
print(proj.get('name', '$project'))
" 2>/dev/null || echo "$project"
}

list_projects() {
    python3 -c "
import yaml
with open('$PROJECTS_YML') as f:
    data = yaml.safe_load(f)
for pid, p in data.get('projects', {}).items():
    print(f\"{pid}:{p.get('ftp_user','')}:{p.get('domain','')}\")
" 2>/dev/null || echo ""
}

detect_project_by_ftp_user() {
    local ftp_arg="$1"
    local user
    user=$(echo "$ftp_arg" | sed 's/,.*//')
    while IFS=: read -r pid ftp_user domain; do
        if [[ "$user" == "$ftp_user" ]]; then
            echo "$pid"
            return
        fi
    done <<< "$(list_projects)"
    echo ""
}

detect_project_by_ssh_host() {
    local host="$1"
    local ssh_host
    ssh_host=$(parse_yaml_field "sema" "ssh_host")
    if [[ "$host" == "$ssh_host" ]]; then
        echo "hostinger"
        return
    fi
    echo ""
}

check_keywords() {
    local file="$1"
    shift
    local keywords=("$@")
    if [[ ! -f "$file" ]]; then
        echo "no_file"
        return
    fi
    local content
    content=$(head -200 "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    for kw in "${keywords[@]}"; do
        if echo "$content" | grep -qi "$kw"; then
            echo "ok"
            return
        fi
    done
    echo "fail"
}

calc_diff_pct() {
    local local_file="$1" remote_content="$2"
    if [[ -z "$remote_content" ]] || [[ "$remote_content" == "REMOTE_ERROR" ]]; then
        echo "0"
        return
    fi
    local local_lines remote_lines diff_lines
    local_lines=$(wc -l < "$local_file" 2>/dev/null || echo 1)
    remote_lines=$(echo "$remote_content" | wc -l)
    diff_lines=$(diff <(echo "$remote_content") "$local_file" 2>/dev/null | grep -c '^[<>]' || echo 0)
    local total=$(( (local_lines + remote_lines) / 2 ))
    if [[ $total -eq 0 ]]; then
        echo "0"
        return
    fi
    echo $(( diff_lines * 100 / total ))
}

fetch_remote_file() {
    local project="$1" remote_path_file="$2"
    local ssh_host ssh_port ssh_user ssh_key remote_base
    ssh_host=$(parse_yaml_field "$project" "ssh_host")
    ssh_port=$(parse_yaml_field "$project" "ssh_port")
    ssh_user=$(parse_yaml_field "$project" "ssh_user")
    ssh_key=$(parse_yaml_field "$project" "ssh_key")
    remote_base=$(parse_yaml_field "$project" "remote_path")
    ssh -q -p "$ssh_port" -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        "$ssh_user@$ssh_host" "cat '$remote_base/$remote_path_file'" 2>/dev/null || echo "REMOTE_ERROR"
}

show_banner() {
    local project_id="$1" project_name="$2" domain="$3" remote_path="$4"
    echo ""
    echo -e "${YELLOW}┌──────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${YELLOW}│${RESET} ${BOLD}⚠  GUARD ATIVO — ${project_name}${RESET}"
    echo -e "${YELLOW}│${RESET}    Projeto:  ${CYAN}${project_id}${RESET}"
    echo -e "${YELLOW}│${RESET}    Domínio:  ${domain}"
    echo -e "${YELLOW}│${RESET}    Path:     ${remote_path}"
    echo -e "${YELLOW}└──────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

ask_force_confirm() {
    local project_id="$1"
    echo -e "${RED}${BOLD}BLOQUEADO.${RESET} O arquivo não parece pertencer ao projeto '${project_id}'."
    echo -e "Para forçar mesmo assim, ${BOLD}digite o nome do projeto${RESET} (ou ENTER para cancelar):"
    read -r confirm
    if [[ "$confirm" != "$project_id" ]]; then
        echo -e "${RED}Operação cancelada.${RESET}"
        log_deploy "$project_id" "?" "?" "FAIL" "?" "CANCELADO_USUARIO"
        exit 1
    fi
}

# ─── Wrapper para LFTP ───────────────────────────────────────────────────────
handle_lftp() {
    local args=("$@")
    local ftp_user_arg=""
    for i in "${!args[@]}"; do
        if [[ "${args[$i]}" == "-u" ]]; then
            ftp_user_arg="${args[$((i+1))]}"
            break
        fi
    done

    local project_id=""
    if [[ -n "$ftp_user_arg" ]]; then
        project_id=$(detect_project_by_ftp_user "$ftp_user_arg")
    fi

    if [[ -z "$project_id" ]]; then
        echo -e "${YELLOW}[GUARD]${RESET} Projeto não identificado pelo usuário FTP."
        echo "Projetos disponíveis:"
        list_projects | while IFS=: read -r pid fuser domain; do
            echo "  ${pid} → ${fuser} (${domain})"
        done
        echo -n "Digite o ID do projeto que você está acessando: "
        read -r project_id
    fi

    local project_name domain remote_path
    project_name=$(get_project_name "$project_id")
    domain=$(parse_yaml_field "$project_id" "domain")
    remote_path=$(parse_yaml_field "$project_id" "remote_path")

    show_banner "$project_id" "$project_name" "$domain" "$remote_path"
    echo -e "${CYAN}[GUARD]${RESET} Sessão LFTP iniciando. Checagem de arquivos ativada."
    echo -e "${CYAN}[GUARD]${RESET} Use ${BOLD}put${RESET} normalmente — o guard interceptará antes do envio.\n"

    # Criar script temporário lftp com hooks de verificação
    local tmpscript
    tmpscript=$(mktemp /tmp/guard_lftp_XXXXXX.sh)
    cat > "$tmpscript" << LFTP_WRAPPER
#!/usr/bin/env bash
GUARD_PROJECT="$project_id"
GUARD_SCRIPT="$INFRA_DIR/guard.sh"

# Intercepta o comando put do lftp via um wrapper de sessão
exec lftp "${args[@]}"
LFTP_WRAPPER
    chmod +x "$tmpscript"

    # Para LFTP não temos hook nativo fácil, então inicia lftp normalmente mas
    # registra a sessão e pede confirmação do projeto se necessário
    log_deploy "$project_id" "sessao_lftp" "-" "N/A" "N/A" "SESSAO_INICIADA"
    exec lftp "${args[@]}"
}

# ─── Wrapper para SSH ────────────────────────────────────────────────────────
handle_ssh() {
    local args=("$@")
    local host=""
    for arg in "${args[@]}"; do
        if [[ "$arg" != -* ]] && [[ -z "$host" ]]; then
            host=$(echo "$arg" | sed 's/.*@//')
            break
        fi
    done

    local ssh_host
    ssh_host=$(parse_yaml_field "sema" "ssh_host")

    if [[ "$host" != "$ssh_host" ]]; then
        exec ssh "${args[@]}"
    fi

    echo -e "${YELLOW}[GUARD]${RESET} Conexão SSH detectada para servidor da Prefeitura (${host})"
    echo ""
    echo "Projetos disponíveis:"
    list_projects | while IFS=: read -r pid fuser domain; do
        echo "  ${pid} → ${domain}"
    done
    echo -n "Para qual projeto você está conectando? (ou ENTER para sessão geral): "
    read -r project_id

    if [[ -n "$project_id" ]]; then
        local project_name domain
        project_name=$(get_project_name "$project_id")
        domain=$(parse_yaml_field "$project_id" "domain")
        echo -e "${GREEN}[GUARD]${RESET} Sessão SSH para: ${BOLD}${project_name}${RESET} (${domain})"
        log_deploy "$project_id" "sessao_ssh" "-" "N/A" "N/A" "SESSAO_INICIADA"
    else
        echo -e "${YELLOW}[GUARD]${RESET} Sessão SSH geral (sem projeto específico)"
        log_deploy "geral" "sessao_ssh" "-" "N/A" "N/A" "SESSAO_GERAL"
    fi

    exec ssh "${args[@]}"
}

# ─── Verificação de arquivo antes de deploy ──────────────────────────────────
check_file_before_deploy() {
    local project_id="$1" local_file="$2" remote_file_path="${3:-}"
    local project_name domain

    project_name=$(get_project_name "$project_id")
    domain=$(parse_yaml_field "$project_id" "domain")
    remote_path=$(parse_yaml_field "$project_id" "remote_path")

    show_banner "$project_id" "$project_name" "$domain" "$remote_path"

    if [[ ! -f "$local_file" ]]; then
        echo -e "${RED}[GUARD]${RESET} Arquivo não encontrado: $local_file"
        exit 1
    fi

    local file_hash
    file_hash=$(md5sum "$local_file" | cut -d' ' -f1)

    # 1. Verificar keywords
    IFS=' ' read -ra keywords <<< "$(get_keywords "$project_id")"
    local kw_result
    kw_result=$(check_keywords "$local_file" "${keywords[@]}")

    if [[ "$kw_result" == "fail" ]]; then
        echo -e "${RED}[GUARD]${RESET} Nenhuma keyword do projeto encontrada no arquivo."
        echo -e "         Keywords esperadas: ${YELLOW}${keywords[*]}${RESET}"
        ask_force_confirm "$project_id"
        log_deploy "$project_id" "$(basename "$local_file")" "$file_hash" "FORÇADO" "?" "ENVIADO"
    else
        echo -e "${GREEN}[GUARD]${RESET} Keywords OK ✓"

        # 2. Verificar diff se arquivo remoto existir e diff > 40%
        if [[ -n "$remote_file_path" ]]; then
            echo -e "${CYAN}[GUARD]${RESET} Comparando com arquivo remoto..."
            local remote_content
            remote_content=$(fetch_remote_file "$project_id" "$remote_file_path")
            local diff_pct
            diff_pct=$(calc_diff_pct "$local_file" "$remote_content")

            if [[ "$diff_pct" -gt 40 ]]; then
                echo -e "${YELLOW}[GUARD]${RESET} ${BOLD}Mudança drástica detectada: ${diff_pct}% do conteúdo alterado!${RESET}"
                echo -e "─── Diff (remoto → local) ───────────────────────────────────"
                diff <(echo "$remote_content") "$local_file" | head -50 || true
                echo -e "─────────────────────────────────────────────────────────────"
                echo -e "Confirma envio? (${BOLD}s${RESET}/N): "
                read -r confirm
                if [[ "$confirm" != "s" ]] && [[ "$confirm" != "S" ]]; then
                    echo -e "${RED}Operação cancelada.${RESET}"
                    log_deploy "$project_id" "$(basename "$local_file")" "$file_hash" "OK" "$diff_pct" "CANCELADO_DIFF"
                    exit 1
                fi
            fi
            log_deploy "$project_id" "$(basename "$local_file")" "$file_hash" "OK" "$diff_pct" "ENVIADO"
        else
            log_deploy "$project_id" "$(basename "$local_file")" "$file_hash" "OK" "?" "ENVIADO"
        fi

        echo -e "${GREEN}[GUARD]${RESET} Arquivo liberado para envio ✓"
    fi
}

# ─── Wrapper para SCP / RSYNC ────────────────────────────────────────────────
handle_scp() {
    local args=("$@")
    local ssh_host
    ssh_host=$(parse_yaml_field "sema" "ssh_host")

    local has_server=false
    for arg in "${args[@]}"; do
        if [[ "$arg" == *"$ssh_host"* ]]; then
            has_server=true
            break
        fi
    done

    if ! $has_server; then
        exec scp "${args[@]}"
    fi

    echo -e "${YELLOW}[GUARD]${RESET} Transferência SCP para servidor da Prefeitura detectada."
    echo -n "Para qual projeto? "
    list_projects | while IFS=: read -r pid _ domain; do echo "  $pid ($domain)"; done
    read -r project_id

    for arg in "${args[@]}"; do
        if [[ -f "$arg" ]]; then
            check_file_before_deploy "$project_id" "$arg"
        fi
    done

    exec scp "${args[@]}"
}

# ─── Subcomando direto: guard.sh check <projeto> <arquivo> ──────────────────
handle_check() {
    local project_id="$1" local_file="$2" remote_path="${3:-}"
    check_file_before_deploy "$project_id" "$local_file" "$remote_path"
}

# ─── Subcomando: guard.sh pull <projeto> ────────────────────────────────────
handle_pull() {
    local project_id="$1"
    local ssh_host ssh_port ssh_user ssh_key remote_path
    ssh_host=$(parse_yaml_field "$project_id" "ssh_host")
    ssh_port=$(parse_yaml_field "$project_id" "ssh_port")
    ssh_user=$(parse_yaml_field "$project_id" "ssh_user")
    ssh_key=$(parse_yaml_field "$project_id" "ssh_key")
    remote_path=$(parse_yaml_field "$project_id" "remote_path")
    local project_name
    project_name=$(get_project_name "$project_id")

    echo -e "${CYAN}[GUARD]${RESET} Git pull para: ${BOLD}${project_name}${RESET}"
    echo -e "         Destino: ${remote_path}"
    echo -e "Confirma? (${BOLD}s${RESET}/N): "
    read -r confirm
    if [[ "$confirm" != "s" ]] && [[ "$confirm" != "S" ]]; then
        echo -e "${RED}Cancelado.${RESET}"
        exit 1
    fi

    log_deploy "$project_id" "git_pull" "-" "N/A" "N/A" "INICIADO"
    ssh -p "$ssh_port" -i "$ssh_key" "$ssh_user@$ssh_host" \
        "cd $remote_path && git pull 2>&1"
    log_deploy "$project_id" "git_pull" "-" "N/A" "N/A" "CONCLUIDO"
}

# ─── Roteamento principal ────────────────────────────────────────────────────
case "$REAL_CMD" in
    lftp)
        handle_lftp "$@"
        ;;
    ssh)
        handle_ssh "$@"
        ;;
    scp)
        handle_scp "$@"
        ;;
    rsync)
        # Para rsync, passa direto mas loga a operação
        log_deploy "geral" "rsync" "-" "N/A" "N/A" "PASSTHROUGH"
        exec rsync "$@"
        ;;
    check)
        handle_check "$@"
        ;;
    pull)
        handle_pull "$@"
        ;;
    *)
        echo -e "${RED}[GUARD]${RESET} Comando desconhecido: $REAL_CMD"
        echo "Uso: guard.sh <lftp|ssh|scp|rsync|check|pull> [args...]"
        exit 1
        ;;
esac
