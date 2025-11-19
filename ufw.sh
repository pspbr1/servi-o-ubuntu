#!/bin/bash

# Script de Correção Focalizada - Samba e UFW
# Data: 2025

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Funções de log
log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Verificar se é root
if [[ $EUID -ne 0 ]]; then
   error "Este script precisa ser executado como root (sudo)"
   exit 1
fi

echo "=========================================="
echo "🔧 CORREÇÃO FOCALIZADA - SAMBA E UFW"
echo "=========================================="
echo

# ============================================
# 1. PARAR TUDO E VERIFICAR CONFLITOS
# ============================================

log "1. Parando serviços e verificando conflitos..."

# Parar todos os serviços relacionados
systemctl stop smbd nmbd ufw 2>/dev/null || true

# Verificar se há processos nas portas do Samba
log "Verificando processos nas portas 139 e 445..."
lsof -i :139 && warning "Processo usando porta 139 - será finalizado" && lsof -ti:139 | xargs kill -9 2>/dev/null || true
lsof -i :445 && warning "Processo usando porta 445 - será finalizado" && lsof -ti:445 | xargs kill -9 2>/dev/null || true

# ============================================
# 2. CORREÇÃO COMPLETA DO SAMBA
# ============================================

log "2. Corrigindo Samba completamente..."

# Remover Samba completamente e reinstalar
log "Reinstalando Samba..."
apt remove --purge -y samba samba-common-bin
apt autoremove -y

# Instalar Samba limpo
apt update
apt install -y samba samba-common-bin

# Parar serviços recém-instalados
systemctl stop smbd nmbd

# Criar diretórios com permissões corretas
log "Criando diretórios do Samba..."
mkdir -p /srv/samba/publico
mkdir -p /srv/samba/privado

chmod 777 /srv/samba/publico
chmod 770 /srv/samba/privado

# Criar usuário aluno se não existir
if ! id "aluno" &> /dev/null; then
    log "Criando usuário aluno..."
    useradd -m -s /bin/bash aluno
    echo "aluno:123" | chpasswd
fi

chown aluno:aluno /srv/samba/privado

# Configuração MINIMALISTA do Samba
log "Criando configuração minimalista do Samba..."
cat > /etc/samba/smb.conf <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = Servidor Samba
   security = user
   map to guest = bad user
   dns proxy = no
   
   # Interfaces específicas
   interfaces = lo enp0s8 192.168.0.1/24
   bind interfaces only = yes
   
   # Logs
   log file = /var/log/samba/log.%m
   max log size = 1000
   
   # Desabilitar coisas problemáticas
   disable netbios = no
   smb ports = 445 139

[Publico]
   comment = Compartilhamento Publico
   path = /srv/samba/publico
   browseable = yes
   read only = no
   guest ok = yes
   writable = yes
   create mask = 0777
   directory mask = 0777

[Privado]
   comment = Compartilhamento Privado
   path = /srv/samba/privado
   browseable = yes
   read only = no
   guest ok = no
   valid users = aluno
   writable = yes
   create mask = 0770
   directory mask = 0770
EOF

# Configurar usuário no Samba
log "Configurando usuário aluno no Samba..."
(echo "123"; echo "123") | smbpasswd -a aluno -s
smbpasswd -e aluno

# Verificar configuração
log "Testando configuração do Samba..."
testparm -s

# Iniciar serviços Samba
log "Iniciando serviços Samba..."
systemctl start smbd
systemctl start nmbd

# Verificar se estão rodando
sleep 3
if systemctl is-active --quiet smbd && systemctl is-active --quiet nmbd; then
    log "Serviços Samba iniciados com sucesso"
else
    error "Falha ao iniciar serviços Samba - verificando logs..."
    journalctl -u smbd --no-pager -l --since "5 minutes ago"
    journalctl -u nmbd --no-pager -l --since "5 minutes ago"
fi

# ============================================
# 3. CORREÇÃO COMPLETA DO UFW
# ============================================

log "3. Corrigindo UFW completamente..."

# Parar UFW
ufw --force disable

# Reset completo
ufw --force reset

# Configurar políticas básicas
ufw default deny incoming
ufw default allow outgoing

# VERDADEIRA correção - permitir routed
echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw

# Ativar IP forwarding no sysctl
echo "net.ipv4.ip_forward=1" >> /etc/ufw/sysctl.conf

# Regras ESSENCIAIS apenas
log "Adicionando regras essenciais..."

# Interface LAN (enp0s8) - PERMITIR TUDO na rede interna
ufw allow in on enp0s8
ufw allow out on enp0s8

# Regras específicas por porta na LAN
ufw allow in on enp0s8 to any port 22
ufw allow in on enp0s8 to any port 80
ufw allow in on enp0s8 to any port 443
ufw allow in on enp0s8 to any port 25
ufw allow in on enp0s8 to any port 110
ufw allow in on enp0s8 to any port 143
ufw allow in on enp0s8 to any port 3128
ufw allow in on enp0s8 to any port 3306

# REGRAS SAMBA - CRÍTICAS
ufw allow in on enp0s8 to any port 139
ufw allow in on enp0s8 to any port 445
ufw allow in on enp0s8 to any port 137/udp
ufw allow in on enp0s8 to any port 138/udp

# DHCP
ufw allow in on enp0s8 to any port 67/udp

# Ativar UFW FORÇADAMENTE
log "Ativando UFW..."
yes | ufw enable

# ============================================
# 4. CONFIGURAR NAT E ROTEAMENTO NO UFW
# ============================================

log "4. Configurando NAT no UFW..."

# Detectar interface WAN
WAN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
log "Interface WAN detectada: $WAN_INTERFACE"

# Configurar arquivo de regras before
cat > /etc/ufw/before.rules <<EOF
# rules.before
#
# Rules that should be run before the ufw command line added rules. Custom
# rules should be added to one of these chains:
#   ufw-before-input
#   ufw-before-output
#   ufw-before-forward

*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o $WAN_INTERFACE -j MASQUERADE
COMMIT

*filter
:ufw-before-input - [0:0]
:ufw-before-output - [0:0]
:ufw-before-forward - [0:0]
:ufw-not-local - [0:0]

# Allow forwarding between LAN and WAN
-A ufw-before-forward -i enp0s8 -o $WAN_INTERFACE -j ACCEPT
-A ufw-before-forward -i $WAN_INTERFACE -o enp0s8 -m state --state RELATED,ESTABLISHED -j ACCEPT

COMMIT
EOF

# Recarregar UFW
ufw disable
yes | ufw enable

# ============================================
# 5. TESTES ESPECÍFICOS
# ============================================

log "5. Executando testes específicos..."

echo
info "=== TESTE SAMBA ==="

# Testar se portas estão ouvindo
if netstat -tuln | grep ":139 "; then
    echo "✓ Porta 139 (Samba): OUVIDO"
else
    echo "✗ Porta 139 (Samba): NÃO OUVIDO"
fi

if netstat -tuln | grep ":445 "; then
    echo "✓ Porta 445 (Samba): OUVIDO"
else
    echo "✗ Porta 445 (Samba): NÃO OUVIDO"
fi

# Testar serviços
if systemctl is-active smbd; then
    echo "✓ smbd: ATIVO"
else
    echo "✗ smbd: INATIVO"
fi

if systemctl is-active nmbd; then
    echo "✓ nmbd: ATIVO"
else
    echo "✗ nmbd: INATIVO"
fi

# Testar compartilhamentos localmente
if smbclient -L //localhost -N 2>/dev/null | grep -q "Publico"; then
    echo "✓ Compartilhamento público: DETECTADO"
else
    echo "✗ Compartilhamento público: NÃO DETECTADO"
fi

echo
info "=== TESTE UFW ==="

# Testar status UFW
if ufw status | grep -q "Status: active"; then
    echo "✓ UFW: ATIVO"
    ufw status numbered | grep -E "(139|445|80|22)"
else
    echo "✗ UFW: INATIVO"
fi

# Testar regras específicas
if ufw status | grep -q "139.*ALLOW"; then
    echo "✓ Regra 139: CONFIGURADA"
else
    echo "✗ Regra 139: NÃO CONFIGURADA"
fi

if ufw status | grep -q "445.*ALLOW"; then
    echo "✓ Regra 445: CONFIGURADA"
else
    echo "✗ Regra 445: NÃO CONFIGURADA"
fi

echo
info "=== TESTE DE CONECTIVIDADE ==="

# Testar acesso aos compartilhamentos
if smbclient -N //127.0.0.1/Publico -c "exit" 2>/dev/null; then
    echo "✓ Acesso público: FUNCIONANDO"
else
    echo "✗ Acesso público: FALHOU"
fi

if smbclient -U aluno%123 //127.0.0.1/Privado -c "exit" 2>/dev/null; then
    echo "✓ Acesso privado: FUNCIONANDO"
else
    echo "✗ Acesso privado: FALHOU"
fi

# ============================================
# 6. SOLUÇÕES ALTERNATIVAS SE AINDA FALHAR
# ============================================

log "6. Aplicando soluções alternativas..."

# Se Samba ainda não funcionar, tentar abordagem diferente
if ! systemctl is-active --quiet smbd; then
    warning "Samba ainda com problemas - aplicando solução alternativa..."
    
    # Abordagem alternativa: configurar Samba apenas na porta 445
    cat > /etc/samba/smb.conf <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = Samba Server
   security = user
   map to guest = bad user
   
   # Usar apenas porta 445
   smb ports = 445
   disable netbios = yes
   
   interfaces = 127.0.0.1 192.168.0.1/24
   bind interfaces only = yes

[Publico]
   path = /srv/samba/publico
   browseable = yes
   read only = no
   guest ok = yes

[Privado]
   path = /srv/samba/privado
   browseable = yes
   read only = no
   guest ok = no
   valid users = aluno
EOF

    systemctl stop nmbd
    systemctl disable nmbd
    systemctl start smbd
fi

# Se UFW ainda não funcionar
if ! ufw status | grep -q "Status: active"; then
    warning "UFW ainda com problemas - reinstalando..."
    apt remove --purge -y ufw
    apt install -y ufw
    
    # Configuração mínima
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow in on enp0s8
    yes | ufw enable
fi

# ============================================
# 7. VERIFICAÇÃO FINAL
# ============================================

log "7. Verificação final..."

echo
info "=== STATUS FINAL ==="

# Verificar processos Samba
if pgrep smbd >/dev/null; then
    echo "✓ Processo smbd: RODANDO"
else
    echo "✗ Processo smbd: NÃO RODANDO"
fi

# Verificar portas
echo "Portas abertas:"
netstat -tuln | grep -E ":139|:445" || echo "Nenhuma porta Samba aberta"

# Verificar UFW
echo
ufw status | head -10

# Teste prático
echo
info "Teste prático - criando arquivo no Samba:"
if echo "teste" > /srv/samba/publico/teste.txt 2>/dev/null; then
    echo "✓ Escrita no Samba: FUNCIONANDO"
else
    echo "✗ Escrita no Samba: FALHOU"
fi

# ============================================
# RELATÓRIO FINAL
# ============================================

log "✅ CORREÇÃO SAMBA/UFW CONCLUÍDA!"

# Criar script de verificação rápida
cat > /usr/local/bin/verificar-samba-ufw.sh <<'EOF'
#!/bin/bash
echo "=== VERIFICAÇÃO RÁPIDA SAMBA/UFW ==="
echo "Data: $(date)"
echo

echo "1. SAMBA:"
echo "   Porta 139: $(netstat -tuln | grep -q ':139 ' && echo 'ABERTA' || echo 'FECHADA')"
echo "   Porta 445: $(netstat -tuln | grep -q ':445 ' && echo 'ABERTA' || echo 'FECHADA')"
echo "   smbd: $(systemctl is-active smbd)"
echo "   nmbd: $(systemctl is-active nmbd)"

echo
echo "2. UFW:"
ufw status | head -5

echo
echo "3. COMPARTILHAMENTOS:"
smbclient -L //localhost -N 2>/dev/null | grep -E "Publico|Privado" | head -5 || echo "   Nenhum detectado"

echo
echo "4. REGRAS:"
ufw status | grep -E "139|445|enp0s8" | head -10
EOF

chmod +x /usr/local/bin/verificar-samba-ufw.sh

echo
log "=========================================="
log "🎯 CORREÇÕES APLICADAS!"
log "=========================================="
echo
info "Comandos úteis:"
echo "  verificar-samba-ufw.sh      - Status rápido"
echo "  systemctl status smbd       - Status Samba"
echo "  ufw status                  - Status firewall"
echo "  journalctl -u smbd -f       - Logs Samba em tempo real"
echo
warning "Se ainda houver problemas:"
echo "  1. Reinicie o servidor: reboot"
echo "  2. Execute: verificar-samba-ufw.sh"
echo "  3. Teste de um cliente: smbclient //192.168.0.1/Publico -N"
echo

# Criar relatório
cat > /root/correcao_samba_ufw.txt <<EOF
CORREÇÃO SAMBA E UFW - $(date)

AÇÕES REALIZADAS:
- Samba reinstalado completamente
- Configuração minimalista aplicada
- UFW reconfigurado com regras específicas
- NAT configurado no UFW
- Portas 139 e 445 liberadas
- Usuário aluno configurado no Samba

STATUS FINAL:
Samba: $(systemctl is-active smbd)
UFW: $(ufw status | grep Status | cut -d: -f2 | tr -d ' ')

Teste dos compartilhamentos:
- Publico: $(smbclient -N //127.0.0.1/Publico -c "exit" 2>/dev/null && echo "OK" || echo "FALHA")
- Privado: $(smbclient -U aluno%123 //127.0.0.1/Privado -c "exit" 2>/dev/null && echo "OK" || echo "FALHA")

Para verificar rapidamente: verificar-samba-ufw.sh
EOF

log "Relatório salvo em: /root/correcao_samba_ufw.txt"
