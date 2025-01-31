#!/bin/sh

# Функция анимации
loading_animation() {
  local pid=$1
  local message=$2
  local spin='-\|/'

  echo -n "$message... "

  while kill -0 $pid 2>/dev/null; do
    for i in $(seq 0 3); do
      echo -ne "\b${spin:$i:1}"
      usleep 100000  # 0.1 сек
    done
  done

  echo -e "\b✔ Готово!"
}


# Функция удаления пакетов
perform_opkg_uninstall() {
  /opt/etc/init.d/S99adguardhome kill >/dev/null 2>&1
  PACKAGES="adguardhome-go ipset iptables node-npm node"
  for pkg in $PACKAGES; do
    opkg remove "$pkg" >/dev/null 2>&1
  done
}

# Функция удаления файлов
perform_files_uninstall() {
  chmod -R 777 /opt/etc/AdGuardHome/ >/dev/null 2>&1
  chmod 777 /opt/etc/init.d/S52ipset >/dev/null 2>&1
  chmod 777 /opt/var/log/AdGuardHome.log >/dev/null 2>&1
  rm -f /opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh >/dev/null 2>&1
  rm -f /opt/etc/ndm/ifstatechanged.d/011-bypass6-table.sh >/dev/null 2>&1
  rm -f /opt/etc/ndm/netfilter.d/010-bypass.sh >/dev/null 2>&1
  rm -f /opt/etc/ndm/netfilter.d/011-bypass6.sh >/dev/null 2>&1
  rm -f /opt/etc/init.d/S52ipset >/dev/null 2>&1
  rm -rf /opt/etc/AdGuardHome/ >/dev/null 2>&1
  rm -f /opt/var/log/AdGuardHome.log >/dev/null 2>&1
}

# Функция удаления веб-панели
perform_hpanel_uninstall() {
  /opt/etc/init.d/S99hpanel kill >/dev/null 2>&1
  chmod -R 777 /opt/etc/HydraRoute/ >/dev/null 2>&1
  chmod 777 /opt/etc/init.d/S99hpanel >/dev/null 2>&1
  rm -rf /opt/etc/HydraRoute/ >/dev/null 2>&1
  rm -r /opt/etc/init.d/S99hpanel >/dev/null 2>&1
}

perform_opkg_uninstall >/dev/null 2>&1 &
loading_animation $! "Удаление opkg пакетов"

perform_files_uninstall >/dev/null 2>&1 &
loading_animation $! "Удаление файлов HydraRoute"

perform_hpanel_uninstall >/dev/null 2>&1 &
loading_animation $! "Удаление веб-панели"


## Включение системного DNS сервера
VERSION=$(ndmc -c show version | grep "title" | awk -F": " '{print $2}')
REQUIRED_VERSION="4.2.3"
DNS_OVERRIDE=$(curl -kfsS localhost:79/rci/opkg/dns-override)

if echo "$DNS_OVERRIDE" | grep -q "true"; then
    if [ "$(printf '%s\n' "$VERSION" "$REQUIRED_VERSION" | sort -V | tail -n1)" = "$VERSION" ]; then
        echo "Включение системного DNS..."
		/opt/bin/nohup sh ndmc -c 'opkg no dns-override'
		echo "Сохранение конфигурации..."
		/opt/bin/nohup sh ndmc -c 'system configuration save'
		sleep 3
    else
        opkg install coreutils-nohup >/dev/null 2>&1
        echo "Версия прошивки ниже $REQUIRED_VERSION, из-за чего SSH-сессия будет прервана, но скрипт корректно закончит работу и роутер будет перезагружен."
		/opt/bin/nohup sh -c "ndmc -c 'opkg no dns-override' && ndmc -c 'system configuration save' && sleep 3 && reboot" >/dev/null 2>&1
    fi
fi

echo "Удаление завершено (╥_╥)"
echo "Перезагрузка..."
reboot
