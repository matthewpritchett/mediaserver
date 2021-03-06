#!/bin/bash

function delete_config() {
  local filename=$1
  local key=$2

  sed --in-place "/^$key/d" "$filename"
  sed -i -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$filename"
  echo "" >> "$filename"
}

function upsert_config() {
  local filename=$1
  local key=$2
  local separator=$3
  local value=$4

  delete_config "$filename" "$key"
  echo "$key$separator$value" >> "$filename"
  echo "" >> "$filename"
}

function setup_ssh() {
  echo "Beginning SSH Setup"
  upsert_config "/etc/ssh/sshd_config" "PermitRootLogin" " " "no"
  upsert_config "/etc/ssh/sshd_config" "PasswordAuthentication" " " "no"
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
  DEBIAN_FRONTEND=noninteractive apt-get -yqq install samba
  install -m 644 -o root -g root ./etc/samba/smb.conf /etc/samba
  echo "SMB password is used for accessing the network shares."
  smbpasswd -a media
  service smbd restart
}

function setup_networking() {
  #install network manager
  DEBIAN_FRONTEND=noninteractive apt-get -yqq install network-manager

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
}

function  setup_cockpit() {
  echo "Beginning Cockpit Setup"
  curl -sSL https://repo.45drives.com/setup -o setup-repo.sh
  sudo bash setup-repo.sh
  DEBIAN_FRONTEND=noninteractive apt-get -yqq install cockpit cockpit-zfs-manager cockpit-navigator cockpit-file-sharing cockpit-machines
  systemctl unmask cockpit
  systemctl enable cockpit
  systemctl start cockpit
  echo "Finished Cockpit Setup"
}

function setup_email() {
  echo "Beginning Email Setup"
  DEBIAN_FRONTEND=noninteractive apt-get -yqq install bsd-mailx msmtp msmtp-mta

  read -r -p "Enter the SMTP Username (your_email@gamil.com): " smtpUser
  read -r -p "Enter the SMTP Password: " -s smtpPassword
  echo ""
  read -r -p "Enter the SMTP Server (smtp.gmail.com): " smtpServer
  read -r -p "Enter the SMTP Port (587): " smtpPort
  read -r -p "Enter the email to send notifications to: " notifyEmail

  rm ./etc/msmtprc
  {
    echo "defaults"
    echo "auth on"
    echo "tls on"
    echo "tls_trust_file /etc/ssl/certs/ca-certificates.crt"
    echo ""
    echo "account default"
    echo "host $smtpServer"
    echo "port $smtpPort"
    echo "user $smtpUser"
    echo "password $smtpPassword"
    echo "from $smtpUser"
    echo ""
    echo "aliases /etc/aliases"
    echo ""
  }  >> ./etc/msmtprc
  install -m 644 -o root -g root ./etc/msmtprc /etc
  rm ./etc/msmtprc

  rm ./etc/aliases
  {
    echo "root: $notifyEmail"
    echo "default: $notifyEmail"
    echo ""
  } >> ./etc/aliases
  install -m 644 -o root -g root ./etc/aliases /etc
  rm ./etc/aliases

  echo "Sending test email..."
  echo "mail works!" | mail root
  echo "sendmail works!" | sendmail root
  echo "Finished Email Setup"
}

function setup_fail2ban() {
  echo "Starting Fail2Ban Setup"
  DEBIAN_FRONTEND=noninteractive apt-get -yqq install fail2ban
  echo "Finished Fail2Ban Setup"
}

function setup_cloud-init() {
  echo "Starting Cloud-Init Setup"
  touch /etc/cloud/cloud-init.disabled
  echo "Finished Cloud-Init Setup"
}

function setup_zfs() {
  echo "Starting ZFS Setup"
  DEBIAN_FRONTEND=noninteractive apt-get -yqq install zfsutils-linux
  upsert_config "/etc/zfs/zed.d/zed.rc" "ZED_NOTIFY_VERBOSE" "=" "1"
  upsert_config "/etc/zfs/zed.d/zed.rc" "ZED_EMAIL_ADDR" "=" "root"
  zpool import vault
  install -m 644 -o root -g root ./etc/systemd/system/zpool-scrub@.service /etc/systemd/system
  install -m 644 -o root -g root ./etc/systemd/system/zpool-scrub@.timer /etc/systemd/system
  install -m 644 -o root -g root ./etc/systemd/system/docker-wait-zfs.service /etc/systemd/system
  systemctl daemon-reload
  systemctl enable --now zpool-scrub@vault.timer
  systemctl enable --now docker-wait-zfs.service
  echo "Finished ZFS Setup"
}

function setup_hdd_monitoring() {
  echo "Starting HDD Monitoring Setup"
  DEBIAN_FRONTEND=noninteractive apt-get -yqq install smartmontools
  upsert_config "/etc/smartd.conf" "DEVICESCAN" " " "-a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 4,38,45 -m root"
  echo "Finished HDD Monitoring Setup"
}

function setup_docker() {
  echo "Starting Docker Setup"
  DEBIAN_FRONTEND=noninteractive apt-get -yqq install docker.io docker-compose
  echo "Finished Docker Setup"
}

function setup_portainer() {
  docker-compose --file /vault/containers/portainer/compose.yaml up --detach
}

function setup_nut() {
  DEBIAN_FRONTEND=noninteractive apt-get -yqq  install nut

  local upspassword
  upspassword=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)

  upsert_config "/etc/nut/nut.conf" "MODE=" "standalone"

  rm ./etc/nut/upsd.users
  {
    echo "[upsmon]"
    echo "    password  = $upspassword"
    echo "    upsmon master"

  } >> ./etc/nut/upsd.users
  install -m 460 -o root -g nut ./etc/nut/upsd.users /etc/nut
  rm ./etc/nut/upsd.users

  install -m 460 -o root -g nut ./etc/nut/ups.conf /etc/nut

  upsert_config "/etc/nut/upsd.conf" "MAXAGE" " 25"

  upsert_config "/etc/nut/upsmon.conf" "MONITOR" " cyberp@localhost 1 upsmon $upspassword master"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYCMD" " /usr/sbin/upssched"
  upsert_config "/etc/nut/upsmon.conf" "DEADTIME" " 25"
  delete_config "/etc/nut/upsmon.conf" "POWERDOWNFLAG"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG ONLINE" "       SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG ONBATT" "       SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG LOWBATT" "      SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG FSD" "          SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG COMMOK" "       SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG COMMBAD" "      SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG SHUTDOWN" "     SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG REPLBATT" "     SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG NOCOMM" "       SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG NOPARENT" "     SYSLOG+EXEC"

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

echo "Media Server Setup"
echo "=================="

PS3="Select the operation: "
options=("Setup Media Server" "Setup Email" "Update Portainer" "Quit")
select opt in "${options[@]}"
do
  case $opt in
    "Setup Media Server")
      echo "Automated Setup"
      apt-get update
      setup_networking
      setup_cloud-init
      setup_fail2ban
      setup_email
      setup_ssh
      setup_media_user
      setup_samba
      setup_hdd_monitoring
      setup_zfs
      setup_docker
      setup_portainer
      setup_cockpit
      echo "Finished Automated Setup"
      read -n 1 -s -r -p "Press any key to reboot"
      reboot
      break
      ;;
    "Setup Email")
      setup_email
      break
      ;;
    "Update Portainer")
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
