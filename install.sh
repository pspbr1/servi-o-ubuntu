#!/bin/bash
set -e

echo "=== ATUALIZANDO SISTEMA ==="
apt update && apt upgrade -y

echo "=== HABILITANDO IP FORWARDING ==="
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

echo "=== CONFIGURANDO NAT ==="
apt install -y iptables-persistent

iptables -t nat -A POSTROUTING -o enp0s3 -j MASQUERADE
iptables -A FORWARD -i enp0s8 -o enp0s3 -j ACCEPT
iptables -A FORWARD -i enp0s3 -o enp0s8 -m state --state RELATED,ESTABLISHED -j ACCEPT

netfilter-persistent save

echo "=== INSTALANDO SERVIDOR DHCP ==="
apt install -y isc-dhcp-server

echo INTERFACESv4=\"enp0s8\" > /etc/default/isc-dhcp-server

cat > /etc/dhcp/dhcpd.conf << 'EOF'
option domain-name "rede-local";
option domain-name-servers 192.168.0.1, 8.8.8.8;
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.0.0 netmask 255.255.255.0 {
  range 192.168.0.100 192.168.0.200;
  option routers 192.168.0.1;
  option broadcast-address 192.168.0.255;
}
EOF

systemctl restart isc-dhcp-server

echo "=== INSTALANDO APACHE2 E PHP ==="
apt install -y apache2 php libapache2-mod-php php-mysql
systemctl enable apache2
systemctl start apache2

echo "=== INSTALANDO MYSQL ==="
apt install -y mysql-server
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'root'; FLUSH PRIVILEGES;"

echo "=== INSTALANDO PHPMYADMIN ==="
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/app-password-confirm password root" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/admin-pass password root" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password root" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
apt install -y phpmyadmin

systemctl restart apache2

echo "=== INSTALANDO POSTFIX + DOVECOT ==="
debconf-set-selections <<< "postfix postfix/mailname string servidor.local"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
apt install -y postfix dovecot-core dovecot-imapd dovecot-pop3d

# CONFIG POSTFIX
postconf -e "home_mailbox = Maildir/"
postconf -e "inet_interfaces = all"
systemctl restart postfix

# CONFIG DOVECOT
sed -i 's/#mail_location =/mail_location = maildir:~\/Maildir/' /etc/dovecot/conf.d/10-mail.conf
systemctl restart dovecot

echo "=== INSTALANDO SQUID ==="
apt install -y squid

cat > /etc/squid/blocked-sites.acl << 'EOF'
.facebook.com
.youtube.com
.tiktok.com
EOF

sed -i 's/#acl blocksites/acl blocksites dstdomain "/etc/squid/blocked-sites.acl"/' /etc/squid/squid.conf
sed -i 's/#http_access deny blocksites/http_access deny blocksites/' /etc/squid/squid.conf

systemctl restart squid

echo "=== INSTALANDO SAMBA (SERVIDOR DE ARQUIVOS) ==="
apt install -y samba

cat >> /etc/samba/smb.conf << 'EOF'

[compartilhado]
   path = /srv/compartilhado
   read only = no
   browsable = yes
   guest ok = yes
EOF

mkdir -p /srv/compartilhado
chmod 777 /srv/compartilhado

systemctl restart smbd

echo "=== CONFIGURAÇÃO FINALIZADA COM SUCESSO ==="
echo "Servidor pronto!"
echo "Rede configurada: 192.168.0.1/24"
echo "Range DHCP: 192.168.0.100 - 192.168.0.200"