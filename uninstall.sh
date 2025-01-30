#!/bin/sh

# удаление пакетов
remove_packages() {
    PACKAGES="adguardhome-go ipset iptables"
    
    for pkg in $PACKAGES; do
        echo "Удаление пакета $pkg..."
        opkg remove "$pkg" || echo "Не удалось удалить пакет $pkg"
    done
}

echo "Удаление пакетов установленных HydraRoute..."
remove_packages

# удаление файлов
echo "Удаление файлов созданных HydraRoute..."
rm -f /opt/etc/init.d/S52ipset
rm -f /opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh
rm -f /opt/etc/ndm/ifstatechanged.d/011-bypass6-table.sh
rm -f /opt/etc/ndm/netfilter.d/010-bypass.sh
rm -f /opt/etc/ndm/netfilter.d/011-bypass6.sh
rm -f /opt/var/log/AdGuardHome.log
rm -rf /opt/etc/AdGuardHome/

echo "Удаление web панели..."
/opt/etc/init.d/S99hpanel kill >/dev/null 2>&1
chmod -R 777 /opt/etc/HydraRoute/ >/dev/null 2>&1
chmod 777 /opt/etc/init.d/S99hpanel >/dev/null 2>&1
rm -rf /opt/etc/HydraRoute/ >/dev/null 2>&1
rm -r /opt/etc/init.d/S99hpanel >/dev/null 2>&1

## Включение системного DNS сервера
VERSION=$(ndmc -c show version | grep "title" | awk -F": " '{print $2}')
REQUIRED_VERSION="4.2.3"
DNS_OVERRIDE=$(curl -kfsS localhost:79/rci/opkg/dns-override)

if echo "$DNS_OVERRIDE" | grep -q "true"; then
    if [ "$(printf '%s\n' "$VERSION" "$REQUIRED_VERSION" | sort -V | tail -n1)" = "$VERSION" ]; then
        echo "Прошивка выше $REQUIRED_VERSION..."
    else
        opkg install coreutils-nohup
        echo "Версия прошивки ниже $REQUIRED_VERSION, из-за чего SSH-сессия будет прервана, но скрипт корректно закончит работу и роутер будет перезагружен."
        nohup sh -c "ndmc -c 'opkg no dns-override' && ndmc -c 'system configuration save' && sleep 5 && reboot" > /dev/null 2>&1 &
    fi
fi

# Прошивка выше 4.2.3
echo "Включаем системный DNS..."
ndmc -c 'opkg no dns-override'
ndmc -c 'system configuration save'
echo "Удаление завершено (╥_╥)"
sleep 5
echo "Перезагрузка..."
reboot
