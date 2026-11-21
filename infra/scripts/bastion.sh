# ===========================================================================
# vm-bastion: só repassa SSH (ProxyJump). Nenhum serviço além do sshd.
# ===========================================================================
if [ ! -f /var/lib/zad/bastion-instalado ]; then
  # Atualizações de segurança ficam com o unattended-upgrades padrão do Ubuntu.
  apt_get update
  touch /var/lib/zad/bastion-instalado
fi
log "bastion pronto"

# Marca para o deploy.sh saber que a inicialização terminou.
touch /var/lib/zad/startup-ok
