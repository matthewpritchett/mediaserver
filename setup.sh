#!/bin/bash

function replace_text() {
  local filename=$1
  local old=$2
  local new=$3

  sed --in-place "s|$old|$new|g" "$filename"
}

function setup_ssh() {
  echo "Beginning SSH Setup"
  install -m 644 -o root -g root ./etc/ssh/sshd_config /etc/ssh
  systemctl reload sshd
  echo "Finished SSH Setup"
}

function setup_media_user() {
  if id -u "media" >/dev/null 2>&1; then
    echo "Skipping media user setup as it already exists"
  else
    echo "Beginning media User Setup"
    groupadd --gid 8675309 media
    adduser --gecos "" --no-create-home --disabled-password --disabled-login --uid 8675309 --gid 8675309 media
    usermod -aG media "$real_user"
    echo "Finished media User Setup"
  fi
}

function setup_samba() {
  echo "Beginning Samba Setup"
  DEBIAN_FRONTEND=noninteractive apt -yqq install samba cockpit-file-sharing
  install -m 644 -o root -g root ./etc/samba/smb.conf /etc/samba
  echo "SMB password is used for accessing the network shares."
  smbpasswd -a media
  service smbd restart
  echo "Finished Samba Setup"
}

function setup_avahi() {
  echo "Beginning Avahi Setup"
  DEBIAN_FRONTEND=noninteractive apt -yqq install avahi-daemon
  echo "Finished Avahi Setup"
}

function setup_networking() {
  echo "Beginning Networking Setup"
  #install network manager
  DEBIAN_FRONTEND=noninteractive apt -yqq install network-manager

  # disable networkd
  systemctl stop systemd-networkd
  systemctl disable systemd-networkd
  systemctl mask systemd-networkd

  # enable network manager
  systemctl unmask NetworkManager
  systemctl enable NetworkManager
  systemctl start NetworkManager

  # setup network config
  install -m 644 -o root -g root ./etc/netplan/00-installer-config.yaml /etc/netplan
  netplan generate
  netplan apply
  echo "Finished Networking Setup"
}

function  setup_cockpit() {
  echo "Beginning Cockpit Setup"
  curl -sSL https://repo.45drives.com/setup -o setup-repo.sh
  sudo bash setup-repo.sh
  DEBIAN_FRONTEND=noninteractive apt -yqq install cockpit cockpit-navigator
  systemctl unmask cockpit
  systemctl enable cockpit
  systemctl start cockpit
  echo "Finished Cockpit Setup"
}

function setup_virtual_machines() {
  echo "Beginning Virtual Machine Setup"
  DEBIAN_FRONTEND=noninteractive apt -yqq install cockpit-machines
  echo "Finished Virtual Machine Setup"
}

function setup_email() {
  echo "Beginning Email Setup"
  DEBIAN_FRONTEND=noninteractive apt -yqq install bsd-mailx msmtp msmtp-mta

  read -r -p "Enter the SMTP Username (your_email@gmail.com): " smtpUser
  read -r -p "Enter the SMTP Password: " -s smtpPassword
  echo ""
  read -r -p "Enter the SMTP Server (smtp.gmail.com): " smtpServer
  read -r -p "Enter the SMTP Port (587): " smtpPort
  read -r -p "Enter the email to send notifications to: " notifyEmail

  install -m 644 -o root -g root ./etc/msmtprc /etc
  replace_text "/etc/msmtprc" "SMTPSERVER" "$smtpServer"
  replace_text "/etc/msmtprc" "SMTPPORT" "$smtpPort"
  replace_text "/etc/msmtprc" "SMTPUSER" "$smtpUser"
  replace_text "/etc/msmtprc" "SMTPPASSWORD" "$smtpPassword"

  install -m 644 -o root -g root ./etc/aliases /etc
  replace_text "/etc/aliases" "NOTIFYEMAIL" "$notifyEmail"

  echo "Sending test email..."
  echo "mail works!" | mail root
  echo "sendmail works!" | sendmail root
  echo "Finished Email Setup"
}

function setup_fail2ban() {
  echo "Starting Fail2Ban Setup"
  DEBIAN_FRONTEND=noninteractive apt -yqq install fail2ban
  echo "Finished Fail2Ban Setup"
}

function setup_cloud-init() {
  echo "Starting Cloud-Init Setup"
  touch /etc/cloud/cloud-init.disabled
  echo "Finished Cloud-Init Setup"
}

function setup_zfs() {
  echo "Starting ZFS Setup"
  DEBIAN_FRONTEND=noninteractive apt -yqq install zfsutils-linux cockpit-zfs-manager
  install -m 644 -o root -g root ./etc/zfs/zed.d/zed.rc /etc/zfs/zed.d
  install -m 644 -o root -g root ./etc/systemd/system/zpool-scrub@.service /etc/systemd/system
  install -m 644 -o root -g root ./etc/systemd/system/zpool-scrub@.timer /etc/systemd/system
  systemctl daemon-reload
  systemctl enable --now zpool-scrub@vault.timer
  zpool import -d /dev/disk/by-id -a
  echo "Finished ZFS Setup"
}

function setup_hdd_monitoring() {
  echo "Starting HDD Monitoring Setup"
  DEBIAN_FRONTEND=noninteractive apt -yqq install smartmontools
  install -m 644 -o root -g root ./etc/smartd.conf /etc
  echo "Finished HDD Monitoring Setup"
}

function setup_docker() {
  echo "Starting Docker Setup"
  DEBIAN_FRONTEND=noninteractive apt -yqq install docker.io docker-compose
  install -m 644 -o root -g root ./etc/docker/daemon.json /etc/docker
  install -m 644 -o root -g root ./etc/systemd/system/docker-wait-zfs.service /etc/systemd/system
  install -m 644 -o root -g root ./etc/systemd/system/docker-compose@.service /etc/systemd/system
  install -m 644 -o root -g root ./etc/systemd/system/docker-compose-auto-update@.service /etc/systemd/system
  install -m 644 -o root -g root ./etc/systemd/system/docker-compose-auto-update@.timer /etc/systemd/system
  install -m 644 -o root -g root ./etc/systemd/system/docker-prune.service /etc/systemd/system
  install -m 644 -o root -g root ./etc/systemd/system/docker-prune.timer /etc/systemd/system
  systemctl enable --now docker-wait-zfs.service
  systemctl enable --now docker-prune.timer
  systemctl daemon-reload
  echo "Finished Docker Setup"
}

function setup_docker_apps() {
  find . -type d -maxdepth 1 -mindepth 1 -print0 | while IFS= read -r -d '' directory
  do
    systemctl enable --now docker-compose@"$directory".service
    systemctl enable --now docker-compose-auto-update@"$directory".timer
  done
}

function setup_nut() {
  DEBIAN_FRONTEND=noninteractive apt -yqq  install nut

  local upspassword
  upspassword=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)

  install -m 460 -o root -g nut ./etc/nut/nut.conf /etc/nut

  install -m 460 -o root -g nut ./etc/nut/upsd.users /etc/nut
  replace_text "/etc/nut/upsd.users" "UPSPASSWORD" "$upspassword"

  install -m 460 -o root -g nut ./etc/nut/ups.conf /etc/nut

  install -m 460 -o root -g nut ./etc/nut/upsmon.conf /etc/nut
  replace_text "/etc/nut/upsmon.conf" "UPSPASSWORD" "$upspassword"

  install -m 755 -o root -g root ./usr/bin/upssched-cmd /usr/bin
  install -m 460 -o root -g nut ./etc/nut/upssched.conf /etc/nut

  service nut-server start
  service nut-monitor start
}

if ! [ "$(id -u)" = 0 ]; then
   echo "The script need to be run as root." >&2
   exit 1
fi

if [ "$SUDO_USER" ]; then
    real_user=$SUDO_USER
else
    real_user=$(whoami)
fi

echo "Server Scripts"
echo "=================="

PS3="Select the operation: "
options=("Media Server Setup" "Email Setup" "Portainer Setup" "Quit")
select opt in "${options[@]}"
do
  case $opt in
    "Media Server Setup")
      echo "Beginning Media Server Setup"
      apt update -y
      setup_cloud-init
      setup_networking
      setup_avahi
      setup_fail2ban
      setup_ssh
      setup_email
      setup_media_user
      setup_hdd_monitoring
      setup_cockpit
      setup_samba
      setup_nut
      setup_virtual_machines
      setup_zfs
      setup_docker
      setup_docker_apps
      echo "Finished Media Server Setup"
      read -n 1 -s -r -p "Press any key to reboot"
      reboot
      break
      ;;
    "Email Setup")
      setup_email
      break
      ;;
    "Portainer Setup")
      setup_portainer
      break
      ;;
    "Quit")
      break
      ;;
    *)
      echo "Invalid option $REPLY"
      ;;
  esac
done

