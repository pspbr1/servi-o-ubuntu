#!/usr/bin/env bash
# setup_all.sh - Configurador completo para Ubuntu 24.04 (virtualizado)
# Uso: sudo ./setup_all.sh
# Atenção: execute apenas em uma VM/instância de teste. Testado para fluxo genérico.
set -euo pipefail
IFS=$'\n\t'

LOG="/var/log/setup_all.log"
exec 3>&1 1>>"${LOG}" 2>&1

# ---------------------------
# Helpers
# ---------------------------
info() {
  echo "[INFO] $*" | tee /dev/fd/3
}
warn() {
  echo "[WARN] $*" | tee /dev/fd/3
}
error() {
  echo "[ERROR] $*" | tee /dev/fd/3
  exit 1
}
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "Execute como root (sudo)."
  fi
}
apt_install() {
  PACKS=("$@")
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKS[@]}" || error "Falha ao instalar: ${PACKS[*]}"
}
service_enable_start() {
  systemctl enable --now "$1" || error "Falha ao habilitar/iniciar $1"
}

# ---------------------------
# Parâmetros (editáveis)
# ---------------------------
INTERNAL_IFACE="enp0s8"   # interface da rede interna (servidor)
NAT_IFACE="enp0s3"        # interface NAT (recebe internet)
SERVER_IP="192.168.0.1"
NETMASK="255.255.255.0"
NETWORK_CIDR="192.168.0.0/24"
DNS_SERVER="1.1.1.1"

DHCP_RANGE_START="192.168.0.100"
DHCP_RANGE_END="192.168.0.200"
DHCP_LEASE_TIME="12h"

MAIL_USER="user1"
MAIL_PASS=""  # se vazio será gerado
MYSQL_ROOT_PASS="" # se vazio será gerado
PHPMYADMIN_PASS="" # se vazio será gerado

SQUID_BLOCKLIST="/etc/squid/blocked_sites.acl"
NFS_SHARE_DIR="/srv/share"

# ---------------------------
# Preparação e validações
# ---------------------------
check_root
info "Iniciando configuração — logs em ${LOG}"
date | tee -a "${LOG}"

# Gerar senhas se não fornecidas
random_pass() {
  < /dev/urandom tr -dc 'A-Za-z0-9!@#$%&*()_+-=' | head -c16 || echo "Passw0rd123!"
}
if [ -z "$MAIL_PASS" ]; then MAIL_PASS="$(random_pass)"; fi
if [ -z "$MYSQL_ROOT_PASS" ]; then MYSQL_ROOT_PASS="$(random_pass)"; fi
if [ -z "$PHPMYADMIN_PASS" ]; then PHPMYADMIN_PASS="$(random_pass)"; fi

info "Senhas geradas (anote):"
echo " - MAIL user:${MAIL_USER} pass:${MAIL_PASS}" | tee /dev/fd/3
echo " - MySQL root: ${MYSQL_ROOT_PASS}" | tee /dev/fd/3
echo " - phpMyAdmin app pass: ${PHPMYADMIN_PASS}" | tee /dev/fd/3

# Atualizar repositório
info "Atualizando apt..."
apt-get update -y || error "apt-get update falhou"
apt-get upgrade -y || error "apt-get upgrade falhou"

# ---------------------------
# 1) Netplan: configurar interfaces
# ---------------------------
info "Configurando netplan (interfaces: ${NAT_IFACE}=dhcp, ${INTERNAL_IFACE}=${SERVER_IP}/24)..."
NETPLAN_FILE="/etc/netplan/99-internal.yaml"
cat > "${NETPLAN_FILE}" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NAT_IFACE}:
      dhcp4: true
    ${INTERNAL_IFACE}:
      addresses: [${SERVER_IP}/24]
      dhcp4: no
      nameservers:
        addresses: [${DNS_SERVER}]
EOF

info "Aplicando netplan..."
netplan apply || error "Falha ao aplicar netplan. Verifique interfaces names (enp0s3/enp0s8)."

# Basic check network
ip -4 addr show "${INTERNAL_IFACE}" | grep -q "${SERVER_IP}" || warn "Atenção: IP interno ${SERVER_IP} não aparece em ${INTERNAL_IFACE}."

# ---------------------------
# 2) Instalar pacotes essenciais
# ---------------------------
info "Instalando pacotes essenciais..."
DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common apt-transport-https ca-certificates gnupg lsb-release curl || error "Falha ao instalar pacotes base"

info "Instalando serviços: postfix, dovecot, isc-dhcp-server, squid, apache2, mysql-server, phpmyadmin, nfs-kernel-server, mailutils (utilitários)"
# Preseed phpmyadmin to avoid interactive prompt
debconf-set-selections <<EOF
phpmyadmin phpmyadmin/dbconfig-install boolean true
phpmyadmin phpmyadmin/app-password-confirm password ${PHPMYADMIN_PASS}
phpmyadmin phpmyadmin/mysql/admin-pass password ${MYSQL_ROOT_PASS}
phpmyadmin phpmyadmin/mysql/app-pass password ${PHPMYADMIN_PASS}
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
EOF

# Preseed postfix basic configuration for 'Internet Site'
debconf-set-selections <<EOF
postfix postfix/main_mailer_type select Internet Site
postfix postfix/mailname string localdomain
EOF

# Install packages
apt_install postfix dovecot-imapd dovecot-pop3d dovecot-lmtpd isc-dhcp-server squid apache2 mysql-server phpmyadmin nfs-kernel-server mailutils

# ---------------------------
# 3) Configurar UFW + NAT (iptables via UFW)
# ---------------------------
info "Configurando UFW e NAT/forwarding..."
# Allow required ports on internal interface only where applicable
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Allow SSH globally (you might restrict to NAT IP later)
ufw allow ssh

# Services to allow: HTTP, HTTPS, SMTP, IMAP, POP3, DNS if needed, NFS? We'll allow internal net to necessary ports.
ufw allow in on ${INTERNAL_IFACE} to any port 53 proto udp comment 'Allow DNS from internal (if needed)'
ufw allow in on ${INTERNAL_IFACE} to any port 80 comment 'HTTP on internal'
ufw allow in on ${INTERNAL_IFACE} to any port 443 comment 'HTTPS on internal'
ufw allow in on ${INTERNAL_IFACE} to any port 25 comment 'SMTP postfix'
ufw allow in on ${INTERNAL_IFACE} to any port 143 comment 'IMAP (dovecot)'
ufw allow in on ${INTERNAL_IFACE} to any port 110 comment 'POP3 (dovecot)'
ufw allow in on ${INTERNAL_IFACE} to any port 3306 comment 'MySQL (if you want remote access - generally not recommended)'
# Allow squid (default port 3128) from internal
ufw allow in on ${INTERNAL_IFACE} to any port 3128 comment 'Squid proxy'
# Allow NFS (2049) from internal
ufw allow in on ${INTERNAL_IFACE} to any port 2049 comment 'NFS'

# Enable IPv4 forwarding in sysctl
sysctl_file="/etc/sysctl.d/99-forward.conf"
echo "net.ipv4.ip_forward=1" > "${sysctl_file}"
sysctl --system || warn "Falha ao recarregar sysctl, mas prosseguindo."

# Configure UFW to allow forwarding and masquerade (edit /etc/ufw/before.rules)
UFW_BEFORE="/etc/ufw/before.rules"
# Ensure we only add once
if ! grep -q "### NAT RULES START" "${UFW_BEFORE}"; then
  info "Adicionando regras de masquerade ao ${UFW_BEFORE}"
  # Insert at top before *filter rule — safer to append at beginning
  awk -v nat_iface="${NAT_IFACE}" -v int_iface="${INTERNAL_IFACE}" 'BEGIN{added=0}{
    print 
    if($0 ~ "COMMIT" && !added){
      # before commit, add nat table if not present (we place just before COMMIT of filter; safe enough)
    }
  }' "${UFW_BEFORE}" > "${UFW_BEFORE}.new" || true

  # We'll construct a snippet and prepend to the file to ensure nat applied
  cat > /tmp/ufw_nat_snippet <<EOF
# ### NAT RULES START (added by setup_all.sh)
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${NETWORK_CIDR} -o ${NAT_IFACE} -j MASQUERADE
COMMIT
# Allow forwarding (filter) - ensure forwarding policy by UFW will permit established
# ### NAT RULES END
EOF
  # Prepend snippet to before.rules
  cat /tmp/ufw_nat_snippet "${UFW_BEFORE}" > "${UFW_BEFORE}.patched"
  mv "${UFW_BEFORE}.patched" "${UFW_BEFORE}"
  rm -f /tmp/ufw_nat_snippet
else
  info "Regras de NAT já presentes em ${UFW_BEFORE}"
fi

# Allow forwarding in UFW configuration (DEFAULT_FORWARD_POLICY)
if ! grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw; then
  sed -i 's/^#DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
  # if not present, add
  if ! grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw; then
    echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
  fi
else
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
fi

info "Habilitando UFW..."
ufw --force enable || error "Falha ao habilitar UFW"

# ---------------------------
# 4) Configurar NAT (iptables persistente via UFW já feito)
# Também garantimos regra iptables em runtime (para sessão atual)
# ---------------------------
info "Aplicando regra de masquerade em runtime..."
iptables -t nat -C POSTROUTING -s "${NETWORK_CIDR}" -o "${NAT_IFACE}" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "${NETWORK_CIDR}" -o "${NAT_IFACE}" -j MASQUERADE

# ---------------------------
# 5) DHCP server (isc-dhcp-server)
# ---------------------------
info "Configurando isc-dhcp-server para ${INTERNAL_IFACE}..."
DHCP_CONF="/etc/dhcp/dhcpd.conf"
cat > "${DHCP_CONF}" <<EOF
option domain-name "localdomain";
option domain-name-servers ${DNS_SERVER}, 8.8.8.8;

default-lease-time 600;
max-lease-time 7200;

authoritative;

subnet 192.168.0.0 netmask 255.255.255.0 {
  range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
  option routers ${SERVER_IP};
  option broadcast-address 192.168.0.255;
  option domain-name-servers ${DNS_SERVER};
  option subnet-mask 255.255.255.0;
  default-lease-time ${DHCP_LEASE_TIME};
}
EOF

# Configure isc-dhcp-server to listen on internal iface
sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"${INTERNAL_IFACE}\"/" /etc/default/isc-dhcp-server || echo "INTERFACESv4=\"${INTERNAL_IFACE}\"" >> /etc/default/isc-dhcp-server

service_enable_start isc-dhcp-server

# ---------------------------
# 6) Squid - proxy com bloqueio
# ---------------------------
info "Configurando Squid..."
SQUID_CONF="/etc/squid/squid.conf"
# Backup
cp -n "${SQUID_CONF}" "${SQUID_CONF}.orig" || true

cat > "${SQUID_BLOCKLIST}" <<EOF
# Domínios a bloquear - adicione um por linha (sem protocolo)
facebook.com
youtube.com
twitter.com
EOF

cat > "${SQUID_CONF}" <<EOF
# Squid configurado por setup_all.sh
http_port 3128
acl localnet src ${NETWORK_CIDR}
acl Safe_ports port 80      # http
acl Safe_ports port 443     # https
acl CONNECT method CONNECT

# blocked sites
acl blocked_sites dstdomain "/etc/squid/blocked_sites.acl"

# http access rules
http_access deny blocked_sites
http_access allow localnet
http_access deny all

# logging & options
access_log /var/log/squid/access.log
cache_dir ufs /var/spool/squid 100 16 256
coredump_dir /var/spool/squid
EOF

chown proxy:proxy "${SQUID_BLOCKLIST}"
systemctl restart squid || error "Falha ao reiniciar squid"

# ---------------------------
# 7) Apache + MySQL + phpMyAdmin
# ---------------------------
info "Configurando MySQL root password e criando usuário de teste..."
# Secure installation minimal: set root password and remove anonymous, test db, remote root
# Use mysql shell to set password
mysql_install_secure() {
  mysql -uroot <<SQL || return 1
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
DELETE FROM mysql.user WHERE user='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
}
mysql_install_secure || warn "Aviso: falha ao aplicar mysql_secure_installation automatizado."

# Ensure Apache has phpmyadmin conf included (phpmyadmin package should have installed)
a2enmod php || true
systemctl restart apache2 || warn "Falha ao reiniciar apache2"

# ---------------------------
# 8) Postfix + Dovecot (email)
# ---------------------------
info "Configurando Postfix para entrega em Maildir e Dovecot para IMAP/POP3..."
# Postfix main.cf minimal changes
postconf -e "myhostname = ${HOSTNAME:-localhost}"
postconf -e "mydestination = localhost, ${HOSTNAME:-localhost}"
postconf -e "inet_interfaces = all"
postconf -e "mynetworks = 127.0.0.0/8, ${NETWORK_CIDR}"
postconf -e "home_mailbox = Maildir/"
postconf -e "smtpd_banner = \$myhostname ESMTP"
postconf -e "compatibility_level = 2"

# Dovecot main settings
DOVECOT_CONF="/etc/dovecot/dovecot.conf"
cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:~/Maildir
mail_privileged_group = mail
EOF

cat > /etc/dovecot/conf.d/10-master.conf <<'EOF'
service imap-login {
  inet_listener imap {
    port = 143
  }
}
service pop3-login {
  inet_listener pop3 {
    port = 110
  }
}
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
EOF

# Auth: use system users (PAM)
cat > /etc/dovecot/conf.d/10-auth.conf <<EOF
disable_plaintext_auth = no
auth_mechanisms = plain login
!include auth-system.conf.ext
EOF

# Ensure permissions and restart
service_enable_start postfix
service_enable_start dovecot

# Create mail test user
if ! id -u "${MAIL_USER}" >/dev/null 2>&1; then
  info "Criando usuário de email ${MAIL_USER}..."
  useradd -m -s /bin/bash "${MAIL_USER}" || error "Falha ao criar usuário ${MAIL_USER}"
  echo "${MAIL_USER}:${MAIL_PASS}" | chpasswd || warn "Falha ao definir senha de ${MAIL_USER}"
  # create Maildir
  su - "${MAIL_USER}" -c 'maildirmake Maildir || true' || true
else
  warn "Usuário ${MAIL_USER} já existe; não criado"
fi

# ---------------------------
# 9) NFS (serviço de arquivos)
# ---------------------------
info "Configurando NFS export em ${NFS_SHARE_DIR}..."
mkdir -p "${NFS_SHARE_DIR}"
chown nobody:nogroup "${NFS_SHARE_DIR}"
chmod 2775 "${NFS_SHARE_DIR}"

# Create a sample file to indicate share
echo "Pasta compartilhada NFS em $(date) - servidor ${SERVER_IP}" > "${NFS_SHARE_DIR}/README.txt"

# Add export
EXPORTS="/etc/exports"
if ! grep -q "^${NFS_SHARE_DIR} " "${EXPORTS}"; then
  echo "${NFS_SHARE_DIR} ${NETWORK_CIDR}(rw,sync,no_subtree_check,no_root_squash)" >> "${EXPORTS}"
fi
exportfs -ra || warn "exportfs -ra falhou (verifique /etc/exports)."
service_enable_start nfs-server

# ---------------------------
# 10) Final adjustments and service checks
# ---------------------------
info "Verificando status dos serviços principais..."
SERVICES=(isc-dhcp-server squid apache2 mysql postfix dovecot nfs-server)
for s in "${SERVICES[@]}"; do
  systemctl is-active --quiet "$s" && info "$s ativo" || warn "$s NÃO ATIVO (verifique logs)"
done

# Show UFW status
info "UFW status:"
ufw status verbose | tee /dev/fd/3

# Show netstat/listening ports relevant
info "Portas abertas (grep dos principais serviços):"
ss -tulwn | egrep ':80|:443|:25|:3128|:143|:110|:3306|:2049' | tee /dev/fd/3 || true

# ---------------------------
# 11) Output resumo e instruções para o cliente Zorin
# ---------------------------
cat > /dev/fd/3 <<EOF
==========================================
CONFIGURAÇÃO FINALIZADA
- Server internal IP: ${SERVER_IP}
- DNS: ${DNS_SERVER}
- DHCP range: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}
- Mail user: ${MAIL_USER} / ${MAIL_PASS}
- MySQL root: ${MYSQL_ROOT_PASS}
- phpMyAdmin app password: ${PHPMYADMIN_PASS}

Serviços instalados:
 - isc-dhcp-server (escutando em ${INTERNAL_IFACE})
 - squid (proxy porta 3128, ACLs em ${SQUID_BLOCKLIST})
 - apache2 + phpmyadmin (web: http://${SERVER_IP}/phpmyadmin)
 - mysql-server (bind em localhost por padrão)
 - postfix + dovecot (SMTP 25, IMAP 143, POP3 110)
 - nfs-server (share ${NFS_SHARE_DIR})

Notas importantes de segurança e uso:
 - MySQL está com root password definido, verifique / altere conforme necessário.
 - phpMyAdmin está instalado e integrado ao Apache: use com cuidado (mantenha firewall).
 - Dovecot aceita autenticação plaintext (disable_plaintext_auth = no) porque é uma rede interna. Para produção, use TLS (STARTTLS) e certificados.
 - Squid bloqueia domínios listados em ${SQUID_BLOCKLIST}. Edite esse arquivo para adicionar mais.
 - UFW foi habilitado e configurado. Se precisar abrir outras portas, use 'ufw allow in on ${INTERNAL_IFACE} to any port <porta>'.

Instrução rápida para o cliente Zorin (exemplo netplan):
------------------------------------------
# /etc/netplan/01-internal.yaml (exemplo para cliente)
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:    # ou o nome que sua VM Zorin mostra
      dhcp4: true
# OU para usar IP estático:
#    enp0s3:
#      addresses: [192.168.0.50/24]
#      gateway4: ${SERVER_IP}
#      nameservers:
#        addresses: [${DNS_SERVER}]
------------------------------------------

Como testar:
 - No cliente Zorin (DHCP), confirme que recebeu IP na faixa .100-.200 e gateway ${SERVER_IP}.
 - Teste internet (ping 8.8.8.8). Deve funcionar via NAT do host.
 - Teste proxy: aponte browser/CLI para proxy ${SERVER_IP}:3128 (ou use curl --proxy).
 - Teste IMAP: use 'telnet ${SERVER_IP} 143' ou cliente CLI como 'mutt' apontando para IMAP server ${SERVER_IP}.
 - Teste NFS: mount ${SERVER_IP}:/srv/share /mnt -v
 - Teste phpMyAdmin: acesse http://${SERVER_IP}/phpmyadmin no browser do cliente.

Logs importantes:
 - /var/log/setup_all.log (este script)
 - /var/log/syslog, /var/log/mail.log, /var/log/squid/access.log, /var/log/apache2/error.log

Se quiser: posso gerar um segundo script para o cliente (netplan + comandos úteis), ou adicionar TLS para dovecot/postfix e autenticação segura. 
==========================================
EOF

# End of script
info "Fim da execução do script. Verifique logs em ${LOG}."
exit 0
