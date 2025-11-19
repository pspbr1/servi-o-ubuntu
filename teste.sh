#!/bin/bash

# Script de Teste para Servidor Ubuntu 24.04
# Testa todos os serviços configurados
# Autor: Teste Automatizado
# Data: 2025

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configurações
LAN_IP="192.168.0.1"
DOMAIN="empresa.local"
MYSQL_ROOT_PASSWORD="123"
EMAIL_USER_PASSWORD="123"

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

test_passed() {
    echo -e "${GREEN}✓ $1${NC}"
}

test_failed() {
    echo -e "${RED}✗ $1${NC}"
}

# Verificar se é root
if [[ $EUID -ne 0 ]]; then
   error "Este script precisa ser executado como root (sudo)"
   exit 1
fi

echo "=========================================="
echo "🧪 INICIANDO TESTES DO SERVIDOR"
echo "=========================================="
echo

# ============================================
# 1. TESTE DE CONECTIVIDADE DE REDE
# ============================================

log "1. Testando conectividade de rede..."

# Testar interface LAN
if ip addr show enp0s8 | grep -q "192.168.0.1"; then
    test_passed "Interface enp0s8 configurada com IP 192.168.0.1"
else
    test_failed "Interface enp0s8 não está configurada corretamente"
fi

# Testar interface WAN
if ip addr show enp0s3 | grep -q "inet"; then
    test_passed "Interface enp0s3 tem configuração IP (WAN)"
else
    test_failed "Interface enp0s3 sem configuração IP"
fi

# Testar ping para internet
if ping -c 2 -W 3 8.8.8.8 &> /dev/null; then
    test_passed "Conexão com internet funcionando"
else
    test_failed "Sem conexão com internet"
fi

# Testar IP forwarding
if sysctl net.ipv4.ip_forward | grep -q "1"; then
    test_passed "IP Forwarding habilitado"
else
    test_failed "IP Forwarding não está habilitado"
fi

echo

# ============================================
# 2. TESTE DOS SERVIÇOS DO SYSTEMD
# ============================================

log "2. Testando serviços systemd..."

services=(
    "apache2"
    "mysql"
    "postfix"
    "dovecot"
    "squid"
    "smbd"
    "nmbd"
    "isc-dhcp-server"
)

for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then
        test_passed "Serviço $service está ativo"
    else
        test_failed "Serviço $service está inativo"
    fi
done

echo

# ============================================
# 3. TESTE DO SERVIDOR WEB (APACHE)
# ============================================

log "3. Testando servidor web Apache..."

# Testar se porta 80 está ouvindo
if netstat -tuln | grep -q ":80 "; then
    test_passed "Apache ouvindo na porta 80"
else
    test_failed "Apache não está ouvindo na porta 80"
fi

# Testar acesso local à página web
if curl -s http://localhost/ | grep -q "Servidor"; then
    test_passed "Página web local acessível"
else
    test_failed "Não foi possível acessar página web local"
fi

# Testar acesso via IP da rede
if curl -s http://$LAN_IP/ | grep -q "Servidor"; then
    test_passed "Página web acessível via IP $LAN_IP"
else
    test_failed "Não foi possível acessar página web via IP $LAN_IP"
fi

echo

# ============================================
# 4. TESTE DO PHP E PHPMYADMIN
# ============================================

log "4. Testando PHP e phpMyAdmin..."

# Criar arquivo de teste PHP
cat > /var/www/html/test.php <<'EOF'
<?php
echo "PHP funcionando! Versão: " . PHP_VERSION . "\n";
echo "Extensions: " . implode(", ", get_loaded_extensions());
?>
EOF

# Testar PHP
if curl -s http://localhost/test.php | grep -q "PHP funcionando"; then
    test_passed "PHP está funcionando corretamente"
else
    test_failed "PHP não está funcionando"
fi

# Testar phpMyAdmin
if curl -s -I http://localhost/phpmyadmin/ | grep -q "200\|301"; then
    test_passed "phpMyAdmin acessível"
else
    test_failed "phpMyAdmin não está acessível"
fi

# Limpar arquivo de teste
rm -f /var/www/html/test.php

echo

# ============================================
# 5. TESTE DO MYSQL
# ============================================

log "5. Testando MySQL Server..."

# Testar conexão local
if mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SELECT 1;" &> /dev/null; then
    test_passed "MySQL aceitando conexões locais"
else
    test_failed "MySQL recusando conexões locais"
fi

# Testar criação de banco de dados
TEST_DB="test_db_$(date +%s)"
if mysql -u root -p$MYSQL_ROOT_PASSWORD -e "CREATE DATABASE $TEST_DB; USE $TEST_DB; CREATE TABLE test(id INT); INSERT INTO test VALUES(1); SELECT * FROM test; DROP DATABASE $TEST_DB;" &> /dev/null; then
    test_passed "MySQL criando e manipulando bancos de dados"
else
    test_failed "Erro na manipulação de banco de dados MySQL"
fi

# Testar se porta está ouvindo
if netstat -tuln | grep -q ":3306 "; then
    test_passed "MySQL ouvindo na porta 3306"
else
    test_failed "MySQL não está ouvindo na porta 3306"
fi

echo

# ============================================
# 6. TESTE DE EMAIL (POSTFIX + DOVECOT)
# ============================================

log "6. Testando servidor de email..."

# Testar se portas SMTP estão ouvindo
if netstat -tuln | grep -q ":25 "; then
    test_passed "Postfix (SMTP) ouvindo na porta 25"
else
    test_failed "Postfix não está ouvindo na porta 25"
fi

# Testar se portas IMAP estão ouvindo
if netstat -tuln | grep -q ":143 "; then
    test_passed "Dovecot (IMAP) ouvindo na porta 143"
else
    test_failed "Dovecot não está ouvindo na porta 143"
fi

# Testar se portas POP3 estão ouvindo
if netstat -tuln | grep -q ":110 "; then
    test_passed "Dovecot (POP3) ouvindo na porta 110"
else
    test_failed "Dovecot não está ouvindo na porta 110"
fi

# Testar envio de email local
if echo "Teste de email" | mail -s "Teste SMTP" aluno@$DOMAIN &> /dev/null; then
    test_passed "Envio de email local funcionando"
else
    test_failed "Erro no envio de email local"
fi

# Verificar se email foi recebido
sleep 2
if su - aluno -c "test -f /home/aluno/Maildir/new/*" 2>/dev/null; then
    test_passed "Email recebido na caixa postal"
else
    test_failed "Email não chegou na caixa postal"
fi

echo

# ============================================
# 7. TESTE DO SQUID PROXY
# ============================================

log "7. Testando Squid Proxy..."

# Testar se porta do proxy está ouvindo
if netstat -tuln | grep -q ":3128 "; then
    test_passed "Squid ouvindo na porta 3128"
else
    test_failed "Squid não está ouvindo na porta 3128"
fi

# Testar acesso através do proxy
if curl -s --proxy http://$LAN_IP:3128 http://www.google.com &> /dev/null; then
    test_passed "Proxy permitindo acesso a sites externos"
else
    test_failed "Proxy bloqueando acesso a sites externos"
fi

# Testar bloqueio de sites
if curl -s --proxy http://$LAN_IP:3128 http://www.facebook.com | grep -i "blocked\|denied\|acesso" &> /dev/null; then
    test_passed "Proxy bloqueando sites restritos"
else
    test_failed "Proxy não está bloqueando sites restritos"
fi

echo

# ============================================
# 8. TESTE DO SAMBA
# ============================================

log "8. Testando servidor Samba..."

# Testar se portas SMB estão ouvindo
if netstat -tuln | grep -q ":139 "; then
    test_passed "Samba ouvindo na porta 139"
else
    test_failed "Samba não está ouvindo na porta 139"
fi

if netstat -tuln | grep -q ":445 "; then
    test_passed "Samba ouvindo na porta 445"
else
    test_failed "Samba não está ouvindo na porta 445"
fi

# Testar compartilhamento público
if smbclient -N -L //localhost/Publico &> /dev/null; then
    test_passed "Compartilhamento público acessível"
else
    test_failed "Compartilhamento público não acessível"
fi

# Testar compartilhamento privado
if smbclient -U aluno%$EMAIL_USER_PASSWORD -L //localhost/Privado &> /dev/null; then
    test_passed "Compartilhamento privado acessível com credenciais"
else
    test_failed "Compartilhamento privado não acessível com credenciais"
fi

echo

# ============================================
# 9. TESTE DO SERVIDOR DHCP
# ============================================

log "9. Testando servidor DHCP..."

# Testar se porta DHCP está ouvindo
if netstat -tuln | grep -q ":67 "; then
    test_passed "DHCP ouvindo na porta 67"
else
    test_failed "DHCP não está ouvindo na porta 67"
fi

# Verificar processo DHCP
if pgrep -x dhcpd &> /dev/null; then
    test_passed "Processo DHCP está rodando"
else
    test_failed "Processo DHCP não está rodando"
fi

# Testar configuração DHCP
if dhcpd -t -cf /etc/dhcp/dhcpd.conf &> /dev/null; then
    test_passed "Configuração DHCP sintaticamente correta"
else
    test_failed "Erro na configuração DHCP"
fi

echo

# ============================================
# 10. TESTE DE NAT E ROTEAMENTO
# ============================================

log "10. Testando NAT e roteamento..."

# Verificar regras iptables
if iptables -t nat -L POSTROUTING | grep -q "MASQUERADE"; then
    test_passed "Regra MASQUERADE configurada"
else
    test_failed "Regra MASQUERADE não configurada"
fi

if iptables -L FORWARD | grep -q "ACCEPT.*enp0s8.*enp0s3"; then
    test_passed "Regra FORWARD configurada"
else
    test_failed "Regra FORWARD não configurada"
fi

echo

# ============================================
# 11. TESTE DE USUÁRIOS E PERMISSÕES
# ============================================

log "11. Testando usuários e permissões..."

# Verificar usuário aluno
if id "aluno" &> /dev/null; then
    test_passed "Usuário 'aluno' existe"
else
    test_failed "Usuário 'aluno' não existe"
fi

# Verificar diretório Maildir
if [ -d "/home/aluno/Maildir" ]; then
    test_passed "Diretório Maildir existe"
else
    test_failed "Diretório Maildir não existe"
fi

# Verificar compartilhamentos Samba
if [ -d "/srv/samba/publico" ] && [ -d "/srv/samba/privado" ]; then
    test_passed "Diretórios de compartilhamento existem"
else
    test_failed "Diretórios de compartilhamento não existem"
fi

echo

# ============================================
# 12. TESTE DE FIREWALL (UFW)
# ============================================

log "12. Testando firewall..."

# Verificar se UFW está ativo
if ufw status | grep -q "Status: active"; then
    test_passed "UFW está ativo"
else
    test_failed "UFW não está ativo"
fi

# Verificar regras básicas
if ufw status | grep -q "22/tcp.*ALLOW"; then
    test_passed "Regra SSH configurada"
else
    test_failed "Regra SSH não configurada"
fi

if ufw status | grep -q "80/tcp.*ALLOW"; then
    test_passed "Regra HTTP configurada"
else
    test_failed "Regra HTTP não configurada"
fi

echo

# ============================================
# RELATÓRIO FINAL
# ============================================

log "Gerando relatório final..."

# Criar relatório
REPORT_FILE="/root/teste_servidor_$(date +%Y%m%d_%H%M%S).txt"

cat > $REPORT_FILE <<EOF
RELATÓRIO DE TESTES DO SERVIDOR
Data: $(date)
Servidor: $(hostname)
IP: $LAN_IP
==========================================

SERVIÇOS TESTADOS:

1. REDE:
   - Interface LAN: $(ip addr show enp0s8 2>/dev/null | grep "inet" | wc -l)/1
   - Interface WAN: $(ip addr show enp0s3 2>/dev/null | grep "inet" | wc -l)/1
   - Internet: $(ping -c 1 -W 2 8.8.8.8 &>/dev/null && echo "OK" || echo "FALHA")
   - IP Forwarding: $(sysctl net.ipv4.ip_forward 2>/dev/null | grep -q "1" && echo "OK" || echo "FALHA")

2. SERVIÇOS SYSTEMD:
$(for service in "${services[@]}"; do
    status=$(systemctl is-active "$service" 2>/dev/null)
    echo "   - $service: $status"
done)

3. APACHE:
   - Porta 80: $(netstat -tuln 2>/dev/null | grep -q ":80 " && echo "OK" || echo "FALHA")
   - Web Local: $(curl -s http://localhost/ &>/dev/null && echo "OK" || echo "FALHA")
   - Web Rede: $(curl -s http://$LAN_IP/ &>/dev/null && echo "OK" || echo "FALHA")

4. PHP:
   - PHP: $(curl -s http://localhost/test.php 2>/dev/null | grep -q "PHP" && echo "OK" || echo "FALHA")
   - phpMyAdmin: $(curl -s -I http://localhost/phpmyadmin/ 2>/dev/null | grep -q "200\|301" && echo "OK" || echo "FALHA")

5. MYSQL:
   - Conexão: $(mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SELECT 1;" 2>/dev/null && echo "OK" || echo "FALHA")
   - Porta 3306: $(netstat -tuln 2>/dev/null | grep -q ":3306 " && echo "OK" || echo "FALHA")

6. EMAIL:
   - SMTP (25): $(netstat -tuln 2>/dev/null | grep -q ":25 " && echo "OK" || echo "FALHA")
   - IMAP (143): $(netstat -tuln 2>/dev/null | grep -q ":143 " && echo "OK" || echo "FALHA")
   - POP3 (110): $(netstat -tuln 2>/dev/null | grep -q ":110 " && echo "OK" || echo "FALHA")

7. PROXY:
   - Squid (3128): $(netstat -tuln 2>/dev/null | grep -q ":3128 " && echo "OK" || echo "FALHA")
   - Acesso: $(curl -s --proxy http://$LAN_IP:3128 http://www.google.com 2>/dev/null && echo "OK" || echo "FALHA")

8. SAMBA:
   - Porta 139: $(netstat -tuln 2>/dev/null | grep -q ":139 " && echo "OK" || echo "FALHA")
   - Porta 445: $(netstat -tuln 2>/dev/null | grep -q ":445 " && echo "OK" || echo "FALHA")

9. DHCP:
   - Porta 67: $(netstat -tuln 2>/dev/null | grep -q ":67 " && echo "OK" || echo "FALHA")
   - Processo: $(pgrep -x dhcpd 2>/dev/null && echo "OK" || echo "FALHA")

10. NAT:
    - MASQUERADE: $(iptables -t nat -L POSTROUTING 2>/dev/null | grep -q "MASQUERADE" && echo "OK" || echo "FALHA")

11. FIREWALL:
    - UFW: $(ufw status 2>/dev/null | grep -q "Status: active" && echo "ATIVO" || echo "INATIVO")

==========================================
EOF

echo
echo "=========================================="
log "✅ TESTES CONCLUÍDOS!"
echo "=========================================="
echo
info "📊 RESUMO DOS TESTES:"
echo
info "Serviços Críticos:"
systemctl is-active apache2 >/dev/null && test_passed "Apache" || test_failed "Apache"
systemctl is-active mysql >/dev/null && test_passed "MySQL" || test_failed "MySQL"
systemctl is-active postfix >/dev/null && test_passed "Postfix" || test_failed "Postfix"
systemctl is-active isc-dhcp-server >/dev/null && test_passed "DHCP" || test_failed "DHCP"

echo
info "Serviços de Rede:"
ping -c 1 -W 2 8.8.8.8 >/dev/null && test_passed "Internet" || test_failed "Internet"
curl -s http://$LAN_IP/ >/dev/null && test_passed "Web Server" || test_failed "Web Server"
curl -s --proxy http://$LAN_IP:3128 http://www.google.com >/dev/null && test_passed "Proxy" || test_failed "Proxy"

echo
info "Relatório salvo em: $REPORT_FILE"
echo
warning "Próximos passos:"
echo "  1. Configure clientes na rede 192.168.0.0/24"
echo "  2. Teste DHCP nos clientes"
echo "  3. Configure proxy nos clientes: $LAN_IP:3128"
echo "  4. Teste acesso à internet pelos clientes"
echo

log "Script de teste finalizado!"