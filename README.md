# _infra — Central de Segurança dos Projetos Prefeitura

## Por que existe

Em uma sessão de trabalho num projeto pessoal, um arquivo `index.php` errado foi enviado via FTP para o servidor da Prefeitura, caindo no site dos estagiários. O site ficou com conteúdo errado por 3 dias sem ninguém perceber.

Este diretório previne isso com:
1. **guard.sh** — wrapper de segurança que intercepta `lftp/ssh/scp`
2. **local-env.sh** — ambiente Docker local para qualquer projeto
3. **dump.sh** — puxa SQL de produção para testes locais
4. **monitor.php** (em `Logs/`) — verifica uptime e envia email de alerta

---

## Setup (uma vez só)

### 1. Instalar dependência Python (para ler projects.yml)
```bash
pip install pyyaml
```

### 2. Ativar wrappers no Fish shell
Adicione ao `~/.config/fish/config.fish`:
```fish
# Guard de segurança — só ativo dentro do diretório da Prefeitura
function lftp
    set INFRA "$HOME/Documentos/Github/Estagio_Prefeitura/_infra/guard.sh"
    if string match -q "$HOME/Documentos/Github/Estagio_Prefeitura*" (pwd)
        bash $INFRA lftp $argv
    else
        command lftp $argv
    end
end

function ssh
    set INFRA "$HOME/Documentos/Github/Estagio_Prefeitura/_infra/guard.sh"
    if string match -q "$HOME/Documentos/Github/Estagio_Prefeitura*" (pwd)
        bash $INFRA ssh $argv
    else
        command ssh $argv
    end
end
```

### 3. Tornar scripts executáveis
```bash
chmod +x _infra/guard.sh _infra/local-env.sh _infra/dump.sh
```

### 4. Instalar PHPMailer no Logs (no servidor via SSH)
```bash
ssh -p 65002 u492577848@46.202.145.215 \
  "cd ~/domains/logs.protocolosead.com/public_html && composer install --no-dev"
```

### 5. Configurar cron no Hostinger
No painel Hostinger → Cron Jobs:
```
*/5 * * * * php ~/domains/logs.protocolosead.com/public_html/monitor.php
```
Defina a variável de ambiente `SMTP_PASS` com a senha do email `noreply@protocolosead.com`.

---

## Uso diário

### Verificar um arquivo antes de enviar manualmente
```bash
./_infra/guard.sh check estagio ./build/index.php
```

### Fazer git pull num projeto via SSH
```bash
./_infra/guard.sh pull sema
```

### Subir ambiente local
```bash
./_infra/local-env.sh start sema
./_infra/local-env.sh start estagio
./_infra/local-env.sh status
```

### Puxar SQL de produção para local
```bash
./_infra/dump.sh sema
```

### Testar envio de email do monitor
```bash
ssh -p 65002 u492577848@46.202.145.215 \
  "php ~/domains/logs.protocolosead.com/public_html/monitor.php --test-email"
```

---

## Como o guard detecta projetos

O guard identifica o projeto pelo **usuário FTP** passado para o `lftp` (campo `-u`). Por exemplo:
- `-u "estagio,senha"` → projeto `estagio`
- `-u "u492577848.semapmpfestagio,senha"` → projeto `sema`

Se não conseguir identificar, pergunta interativamente.

---

## Regras de bloqueio

1. **Sem keyword do projeto no arquivo** → BLOQUEADO. Para forçar, precisa digitar o ID do projeto.
2. **Diff > 40% com arquivo remoto** → Mostra diff colorido e pede confirmação (s/N).
3. **SSH para o servidor** → Pergunta qual projeto antes de abrir sessão.

---

## Logs gerados

| Arquivo | Conteúdo |
|---------|---------|
| `_infra/logs/deploys_YYYY-MM.log` | Histórico de todos os deploys/uploads |
| `Logs/logs/uptime_YYYY-MM.log` | Verificações de uptime dos domínios |
| `Logs/logs/alerts_YYYY-MM.log` | Alertas de email enviados |
| `Logs/logs/status.json` | Status atual dos domínios (atualizado a cada 5 min) |

O painel em `Logs/painel.php` mostra tudo isso em tempo real.
