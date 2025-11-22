#!/bin/bash
SERVIDOR_IP="192.168.0.1"
USER="pedro"

echo "===== REPARO COMPLETO DO CLIENTE ====="

echo ""
echo "== [1] Removendo PROXY do ambiente =="
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
echo "✔ Proxy removido"

echo ""
echo "== [2] Instalando pacotes necessários =="
sudo apt update
sudo apt install -y mailutils netcat-openbsd dnsutils openssh-client
echo "✔ Pacotes instalados"

echo ""
echo "== [3] Corrigindo DNS do cliente =="
if ! grep -q "nameserver 1.1.1.1" /etc/resolv.conf; then
    echo "❌ DNS incorreto — configurando..."
    echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf >/dev/null
else
    echo "✔ DNS OK"
fi

echo ""
echo "== [4] Verificando rota para o servidor =="
sudo ip route | grep -q "192.168.0.1"
if [ $? -ne 0 ]; then
    echo "❌ Rota não existe — adicionando..."
    sudo ip route add 192.168.0.0/24 dev enp0s8
else
    echo "✔ Rota OK"
fi

echo ""
echo "== [5] Corrigindo /etc/hosts =="
if ! grep -q "192.168.0.1 servidor" /etc/hosts; then
    echo "192.168.0.1 servidor" | sudo tee -a /etc/hosts >/dev/null
    echo "✔ /etc/hosts corrigido"
else
    echo "✔ /etc/hosts OK"
fi

echo ""
echo "== [6] Testando conectividade com o servidor =="
ping -c1 $SERVIDOR_IP &>/dev/null
if [ $? -ne 0 ]; then
    echo "❌ O cliente não consegue alcançar o servidor!"
    echo "Verifique o DHCP, cabo virtual ou rede interna."
else
    echo "✔ Conectividade OK"
fi

echo ""
echo "== [7] Testando portas necessárias =="
PORTAS=(25 587 143 993)
for P in "${PORTAS[@]}"; do
    echo -n "Porta $P... "
    timeout 3 bash -c "</dev/tcp/$SERVIDOR_IP/$P" &>/dev/null
    if [ $? -eq 0 ]; then echo "✔ ABERTA"; else echo "❌ FECHADA"; fi
done

echo ""
echo "== [8] Criando um email de teste via sendmail =="
TESTE="/tmp/email_cliente_$(date +%s).txt"
echo "Email de teste enviado do cliente em $(date)" > "$TESTE"

echo ""
echo "== [9] Enviando e-mail para o servidor =="
(
echo "HELO cliente"
echo "MAIL FROM:<cliente@rede.local>"
echo "RCPT TO:<pedro@$SERVIDOR_IP>"
echo "DATA"
cat "$TESTE"
echo "."
echo "QUIT"
) | nc $SERVIDOR_IP 25

echo "✔ Email de teste enviado (ou tentativa enviada)"

echo ""
echo "== [10] Enviando log para o servidor =="
scp "$TESTE" pedro@$SERVIDOR_IP:/tmp/ 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✔ Log enviado para o servidor"
else
    echo "❌ Não foi possível enviar o log via SCP"
    echo "Possíveis causas:"
    echo "- Servidor sem SSH ativo"
    echo "- Permissões erradas no usuário"
    echo "- Firewall bloqueando"
fi

echo ""
echo "===== REPARO DO CLIENTE FINALIZADO ====="
echo "Agora execute:  sudo tail -f /var/log/mail.log  no servidor para acompanhar a entrega."
