#!/bin/sh

# Функция отключения системного DNS-сервера роутера
rci_post() {
    $WGET -qO - --post-data="$1" localhost:79/rci/ > /dev/null 2>&1
}

# Основная часть скрипта

# Проверка политики доступа
echo "Проверка наличия политики доступа..."
# Функция проверки наличия политики Hydra
policy_exists=$(curl -kfsS localhost:79/rci/show/ip/policy 2>/dev/null | jq -r '.[] | select(.description == "Hydra") | .description')
if [ "$policy_exists" != "Hydra" ]; then
    echo "Создайте политику доступа Hydra"
    exit 1
fi

echo "Установка необходимых пакетов..."
opkg update
opkg install adguardhome-go ipset iptables ip-full curl jq

# Инициализация WGET
WGET='/opt/bin/wget -q --no-check-certificate'

# Выполняем команду отключения DNS провайдера
curl -kfsS localhost:79/rci/opkg/dns-override | grep -q true || {
    echo 'Отключаем работу через DNS-провайдера роутера...'
    echo "Возможно, что сейчас произойдет выход из сессии..."
    echo "В этом случае необходимо заново войти в сессию по ssh и запустить скрипт"
    rci_post '[{"opkg": {"dns-override": true}},{"system": {"configuration": {"save": true}}}]' &>/dev/null
}

# Создание скрипта для ipset
echo "Создание скрипта для ipset..."
cat << EOF > /opt/etc/init.d/S52ipset
#!/bin/sh

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ "$1" = "start" ]; then
    ipset create bypass hash:ip
    ipset create bypass6 hash:ip family inet6
fi
EOF


# Создание скриптов для маркировки трафика
echo "Создание скриптов для маркировки трафика..."

# Скрипт для IPv4
cat << 'EOF' > /opt/etc/ndm/netfilter.d/010-bypass.sh
#!/bin/sh

interface=$(curl -kfsS localhost:79/rci/show/ip/policy 2>/dev/null | jq -r '
    .[] | 
    select(.description == "Hydra") |
    .route4.route[] | 
    select(.destination == "0.0.0.0/0") | 
    .interface
')

[ -z "\$interface" ] && exit

[ "\$type" == "ip6tables" ] && exit
[ "\$table" != "mangle" ] && exit
[ -z "\$(ipset --quiet list bypass)" ] && exit

if [ -z "\$(iptables-save | grep bypass)" ]; then
    mark_id=\$(curl -kfsS localhost:79/rci/show/ip/policy 2>/dev/null | jq -r '.[] | select(.description == "Hydra") | .mark')
    iptables -w -t mangle -A PREROUTING ! -i \$interface -m conntrack --ctstate NEW -m set --match-set bypass dst -j CONNMARK --set-mark 0x\$mark_id
    iptables -w -t mangle -A PREROUTING ! -i \$interface -m set --match-set bypass dst -j CONNMARK --restore-mark
fi
EOF

# Скрипт для IPv6
cat << 'EOF' > /opt/etc/ndm/netfilter.d/011-bypass6.sh
#!/bin/sh

interface=$(curl -kfsS localhost:79/rci/show/ip/policy 2>/dev/null | jq -r '
    .[] | 
    select(.description == "Hydra") |
    .route4.route[] | 
    select(.destination == "0.0.0.0/0") | 
    .interface
')

[ -z "\$interface" ] && exit

[ "\$type" != "ip6tables" ] && exit
[ "\$table" != "mangle" ] && exit
[ -z "\$(ipset --quiet list bypass6)" ] && exit

if [ -z "\$(ip6tables-save | grep bypass6)" ]; then
    mark_id=\$(curl -kfsS localhost:79/rci/show/ip/policy 2>/dev/null | jq -r '.[] | select(.description == "Hydra") | .mark')
    ip6tables -w -t mangle -A PREROUTING ! -i \$interface -m conntrack --ctstate NEW -m set --match-set bypass6 dst -j CONNMARK --set-mark 0x\$mark_id
    ip6tables -w -t mangle -A PREROUTING ! -i \$interface -m set --match-set bypass6 dst -j CONNMARK --restore-mark
fi
EOF

echo "Настройка AdGuard Home..."
# Добавляем ipset в AdGuard Home
echo "- включение ipset в ADGH"
sed -i '/^  ipset_file:/c\  ipset_file: /opt/etc/AdGuardHome/ipset.conf' /opt/etc/AdGuardHome/AdGuardHome.yaml

# Включение DNS серверов, защищенных шифрованием
echo "- включение DNS серверов, защищенных шифрованием"
sed -i '/^  upstream_dns:/,/^  upstream_dns_file: ""/{
    /^  upstream_dns:/!{
        /^  upstream_dns_file: ""/!d
    }
    /^  upstream_dns:/a \
    - tls://dns.google\n    - tls://one.one.one.one\n    - tls://p0.freedns.controld.com\n    - tls://dot.sb\n    - tls://dns.nextdns.io\n    - tls://dns.quad9.net
}' "/opt/etc/AdGuardHome/AdGuardHome.yaml"

# Добавление bootstrap DNS-серверов
echo "- добавление bootstrap DNS-серверов"
sed -i '/^  bootstrap_dns:/,/^  fallback_dns:/{
    /^  bootstrap_dns:/!{
        /^  fallback_dns:/!d
    }
    /^  bootstrap_dns:/a \
    - 9.9.9.9\n    - 94.140.14.14\n    - 208.67.222.222\n    - 1.1.1.1\n    - 8.8.8.8\n    - 149.112.112.10
}' "/opt/etc/AdGuardHome/AdGuardHome.yaml"

# Добавление пользовательского фильтра для обхода блокировки ECH Cloudflare
echo "- фильтр для обхода блокировки ECH Cloudflare"
sed -i '/^user_rules:/,/^dhcp:/{
    /^user_rules:/!{
        /^dhcp:/!d
    }
    /^user_rules:/a \
  - '\''||*^$dnstype=HTTPS,dnsrewrite=NOERROR'\''
}' "/opt/etc/AdGuardHome/AdGuardHome.yaml"

# Создание базового списка доменов для перенаправления
echo "- базовый список доменов для перенаправления"
cat << EOF > /opt/etc/AdGuardHome/ipset.conf
2ip.ru/bypass,bypass6
googlevideo.com,ggpht.com,ytimg.com,youtube.com,youtubei.googleapis.com,youtu.be,nhacmp3youtube.com,googleusercontent.com,gstatic.com/bypass,bypass6
openai.com,chatgpt.com/bypass,bypass6
bookstagram.com,carstagram.com,cdninstagram.com,chickstagram.com,ig.me,igcdn.com,igsonar.com,igtv.com,imstagram.com,imtagram.com,instaadder.com,instachecker.com,instafallow.com,instafollower.com,instagainer.com,instagda.com,instagify.com,instagmania.com,instagor.com,instagram-brand.com,instagram-engineering.com,instagram-help.com,instagram-press.com,instagram-press.net,instagram.com,instagramhashtags.net,instagramhilecim.com,instagramhilesi.org,instagramium.com,instagramizlenme.com,instagramkusu.com,instagramlogin.com,instagrampartners.com,instagramphoto.com,instagramq.com,instagramsepeti.com,instagramtips.com,instagramtr.com,instagy.com,instamgram.com,instanttelegram.com,instaplayer.net,instastyle.tv,instgram.com,oninstagram.com,online-instagram.com,onlineinstagram.com,web-instagram.net,wwwinstagram.com/bypass,bypass6
1337x.to,game4you.top,eztv.re,fitgirl-repacks.site,megashara.net,nnmclub.to,nnm-club.to,nnm-club.me,rarbg.to,rustorka.com,rutor.info,rutor.org,rutracker.cc,rutracker.org,rutracker.cc,tapochek.net,thelastgame.ru,thepiratebay.org,thepirate-bay.org,torrentgalaxy.to,torrent-games.best,torrentz2eu.org,limetorrents.info,pirateproxy-bay.com,torlock.com,torrentdownloads.me/bypass,bypass6
github.com/bypass,bypass6
EOF

# Установка прав на выполнение скриптов
echo "Установка прав на выполнение скриптов..."
chmod +x /opt/etc/init.d/S52ipset
chmod +x /opt/etc/ndm/netfilter.d/010-bypass.sh
chmod +x /opt/etc/ndm/netfilter.d/011-bypass6.sh

# Перезапуск AdGuard Home
echo "Перезапуск AdGuard Home..."
/opt/etc/init.d/S99adguardhome restart

# Информационные сообщения
echo "Скрипт выполнен."
echo "Завершите настройку AdGuardHome перейдя по адресу: http://192.168.1.1:3000/"
echo "Для проверки работы перейдите на 2ip.ru, должен отображаться IP-адрес вашего VPN."
echo "Чтобы добавить домены для перенаправления, отредактируйте файл: /opt/etc/AdGuardHome/ipset.conf."
echo "После добавления доменов необходимо перезапустить AdGuard Home командой: /opt/etc/init.d/S99adguardhome restart."

# Удаляем скрипт после выполнения
rm -- "$0"
