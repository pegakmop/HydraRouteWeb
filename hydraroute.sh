#!/bin/sh

# Функция для получения списка интерфейсов
get_interfaces() {
    # Выводим список интерфейсов для выбора
    echo "Доступные интерфейсы:"
    i=1
    interfaces=$(ip a | sed -n 's/.*: \(.*\): <.*UP.*/\1/p')
    interface_list=""
    for iface in $interfaces; do
        # Проверяем, существует ли интерфейс, игнорируя ошибки 'ip: can't find device'
        if ip a show "$iface" &>/dev/null; then
            # Получаем IP-адрес интерфейса, используя ip a show
            ip_address=$(ip a show "$iface" | grep -oP 'inet \K[\d.]+')

            # Если IP-адрес найден, выводим интерфейс и его IP
            if [ -n "$ip_address" ]; then
                echo "$i. $iface: $ip_address"
                interface_list="$interface_list $iface"
                i=$((i+1))
            fi
        fi
    done

    # Запрашиваем у пользователя имя интерфейса с проверкой ввода
    while true; do
        read -p "Введите ИМЯ интерфейса, через которое будет перенаправляться трафик: " net_interface

        # Проверяем, существует ли введенное имя в списке
        if echo "$interface_list" | grep -qw "$net_interface"; then
            # Если интерфейс найден, завершаем цикл
            echo "Выбран интерфейс: $net_interface"
            break
        else
            # Если введен неверный интерфейс, выводим сообщение об ошибке
            echo "Неверный выбор, необходимо ввести ИМЯ интерфейса из списка."
        fi
    done
}


# Дисклаймер
echo ""
echo "Во избежание сбоев настоятельно рекомендуется удалить ранее используемый софт, реализующий маршрутизацию трафика."
echo "- идеальным решением будет очистить носитель и переустановить entware."
echo ""
echo "PS: Если нужного интерфейса нет в списке значит он не активен (нет соединения) или выключен."
echo ""

## Основная часть скрипта
# Вызов функции для получения интерфейса
get_interfaces

## Установка пакетов с отслеживанием результата, остановка в случае ошибки
echo "Обновление списка доступных пакетов..."
opkg update

# Список пакетов для установки
PACKAGES="adguardhome-go ipset iptables ip-full"

# Установка пакетов
for pkg in $PACKAGES; do
    echo "Установка $pkg..."
    ERROR_MSG=$(opkg install "$pkg" 2>&1)
    ERROR_CODE=$?

    if echo "$ERROR_MSG" | grep -qi "error\|failed"; then
        echo "Ошибка при установке пакета \"$pkg\":"
        echo "$ERROR_MSG"
        echo ""
        echo "Установка HydraRoute прервана."
        exit 1
    fi
done

echo "Необходимые пакеты установлены успешно, продолжаем..."


# Создание ipset
echo "Создаем ipset..."
cat << EOF > /opt/etc/init.d/S52ipset
#!/bin/sh

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ "\$1" = "start" ]; then
    ipset create bypass hash:ip
    ipset create bypass6 hash:ip family inet6
    ip rule add fwmark 1001 table 1001
    ip -6 rule add fwmark 1001 table 1001
fi
EOF

# Создание скриптов маршрутизации
echo "Создание скриптов маршрутизации..."
cat << EOF > /opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh
#!/bin/sh

[ "\$system_name" == "$net_interface" ] || exit 0
[ ! -z "\$(ipset --quiet list bypass)" ] || exit 0
[ "\${connected}-\${link}-\${up}" == "yes-up-up" ] || exit 0

if [ -z "\$(ip route list table 1001)" ]; then
    ip route add default dev \$system_name table 1001
fi
EOF

cat << EOF > /opt/etc/ndm/ifstatechanged.d/011-bypass6-table.sh
#!/bin/sh

[ "\$system_name" == "$net_interface" ] || exit 0
[ ! -z "\$(ipset --quiet list bypass6)" ] || exit 0
[ "\${connected}-\${link}-\${up}" == "yes-up-up" ] || exit 0

if [ -z "\$(ip -6 route list table 1001)" ]; then
    ip -6 route add default dev \$system_name table 1001
fi
EOF

# Создание скриптов маркировки трафика
echo "Создание скриптов маркировки трафика..."
cat << EOF > /opt/etc/ndm/netfilter.d/010-bypass.sh
#!/bin/sh

[ "\$type" == "ip6tables" ] && exit
[ "\$table" != "mangle" ] && exit
[ -z "\$(ip link list | grep $net_interface)" ] && exit
[ -z "\$(ipset --quiet list bypass)" ] && exit

if [ -z "\$(iptables-save | grep bypass)" ]; then
     iptables -w -t mangle -A PREROUTING ! -i $net_interface -m conntrack --ctstate NEW -m set --match-set bypass dst -j CONNMARK --set-mark 1001
     iptables -w -t mangle -A PREROUTING ! -i $net_interface -m set --match-set bypass dst -j CONNMARK --restore-mark
fi
EOF

cat << EOF > /opt/etc/ndm/netfilter.d/011-bypass6.sh
#!/bin/sh

[ "\$type" != "ip6tables" ] && exit
[ "\$table" != "mangle" ] && exit
[ -z "\$(ip -6 link list | grep $net_interface)" ] && exit
[ -z "\$(ipset --quiet list bypass6)" ] && exit

if [ -z "\$(ip6tables-save | grep bypass6)" ]; then
     ip6tables -w -t mangle -A PREROUTING ! -i $net_interface -m conntrack --ctstate NEW -m set --match-set bypass6 dst -j CONNMARK --set-mark 1001
     ip6tables -w -t mangle -A PREROUTING ! -i $net_interface -m set --match-set bypass6 dst -j CONNMARK --restore-mark
fi
EOF


# Настройка AdGuard Home
echo "Настройка AdGuard Home..."
# Останавливаем AdGuard Home
/opt/etc/init.d/S99adguardhome stop

# Функция для получения IP роутера (br0)
IP_ADDRESS=$(ip addr show br0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

# Создаем дефолтный конфиг AdGuard Home
cat << EOF > /opt/etc/AdGuardHome/AdGuardHome.yaml
http:
  pprof:
    port: 6060
    enabled: false
  address: $IP_ADDRESS:3000
  session_ttl: 720h
users:
  - name: admin
    password: $2y$10$b6o19XQdb9ckUeP0.zs1Qe/7DwXAgHy4OJ7at.cz7mN2YMPSEmy6e
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - $IP_ADDRESS
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - tls://dns.google
    - tls://one.one.one.one
    - tls://p0.freedns.controld.com
    - tls://dot.sb
    - tls://dns.nextdns.io
    - tls://dns.quad9.net
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.9
    - 1.1.1.1
    - 8.8.8.8
    - 149.112.112.10
    - 94.140.14.14
    - 208.67.222.222
  fallback_dns: []
  upstream_mode: parallel
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: /opt/etc/AdGuardHome/ipset.conf
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: false
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 1h
  size_memory: 1000
  enabled: false
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 24h
  enabled: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_16.txt
    name: 'VNM: ABPVN List'
    id: 1724459839
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_41.txt
    name: 'POL: CERT Polska List of malicious domains'
    id: 1724459840
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_40.txt
    name: 'TUR: Turkish Ad Hosts'
    id: 1724459841
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_26.txt
    name: 'TUR: turk-adlist'
    id: 1724459842
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_14.txt
    name: 'POL: Polish filters for Pi-hole'
    id: 1724459843
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_17.txt
    name: 'SWE: Frellwit''s Swedish Hosts File'
    id: 1724459844
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_13.txt
    name: 'NOR: Dandelion Sprouts nordiske filtre'
    id: 1724459845
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_20.txt
    name: 'MKD: Macedonian Pi-hole Blocklist'
    id: 1724459846
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_36.txt
    name: 'LIT: EasyList Lithuania'
    id: 1724459847
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_15.txt
    name: 'KOR: YousList'
    id: 1724459848
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_25.txt
    name: 'KOR: List-KR DNS'
    id: 1724459849
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_43.txt
    name: 'ISR: EasyList Hebrew'
    id: 1724459850
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_19.txt
    name: 'IRN: PersianBlocker list'
    id: 1724459851
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_35.txt
    name: 'HUN: Hufilter'
    id: 1724459852
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_22.txt
    name: 'IDN: ABPindo'
    id: 1724459853
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_21.txt
    name: 'CHN: anti-AD'
    id: 1724459854
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_29.txt
    name: 'CHN: AdRules DNS List'
    id: 1724459855
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_51.txt
    name: HaGeZi's Pro++ Blocklist
    id: 1724459856
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_23.txt
    name: WindowsSpyBlocker - Hosts spy rules
    id: 1724459857
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt
    name: Phishing URL Blocklist (PhishTank and OpenPhish)
    id: 1724459858
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt
    name: The Big List of Hacked Malware Web Sites
    id: 1724459859
  - enabled: false
    url: https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_7_Japanese/filter.txt
    name: Japan
    id: 1731768906
  - enabled: false
    url: https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_224_Chinese/filter.txt
    name: China
    id: 1731768907
whitelist_filters: []
user_rules:
  - '||*^$dnstype=HTTPS,dnsrewrite=NOERROR'
  - '@@||yabs.yandex.ru^$important'
  - '@@||mc.yandex.ru^$important'
  - ""
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: Local
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 28
EOF


# Создание базового списка доменов для перенаправления
echo "Создание базового списка доменов для перенаправления..."
cat << EOF > /opt/etc/AdGuardHome/ipset.conf
2ip.ru/bypass,bypass6
googlevideo.com,ggpht.com,googleapis.com,googleusercontent.com,gstatic.com,google.com,nhacmp3youtube.com,youtu.be,youtube.com,ytimg.com/bypass,bypass6
cdninstagram.com,instagram.com,bookstagram.com,carstagram.com,chickstagram.com,ig.me,igcdn.com,igsonar.com,igtv.com,imstagram.com,imtagram.com,instaadder.com,instachecker.com,instafallow.com,instafollower.com,instagainer.com,instagda.com,instagify.com,instagmania.com,instagor.com,instagram.fkiv7-1.fna.fbcdn.net,instagram-brand.com,instagram-engineering.com,instagramhashtags.net,instagram-help.com,instagramhilecim.com,instagramhilesi.org,instagramium.com,instagramizlenme.com,instagramkusu.com,instagramlogin.com,instagrampartners.com,instagramphoto.com,instagram-press.com,instagram-press.net,instagramq.com,instagramsepeti.com,instagramtips.com,instagramtr.com,instagy.com,instamgram.com,instanttelegram.com,instaplayer.net,instastyle.tv,instgram.com,oninstagram.com,onlineinstagram.com,online-instagram.com,web-instagram.net,wwwinstagram.com/bypass,bypass6
1337x.to,262203.game4you.top,eztv.re,fitgirl-repacks.site,new.megashara.net,nnmclub.to,nnm-club.to,nnm-club.me,rarbg.to,rustorka.com,rutor.info,rutor.org,rutracker.cc,rutracker.org,tapochek.net,thelastgame.ru,thepiratebay.org,thepirate-bay.org,torrentgalaxy.to,torrent-games.best,torrentz2eu.org,limetorrents.info,pirateproxy-bay.com,torlock.com,torrentdownloads.me/bypass,bypass6
discordsays.com,discord.gg,discord.media,discordapp.com,dis.gd,disboard.org,discord.center,discord.co,discord.com,discord.dev,discord.gift,discord.gifts,discord.me,discord.new,discord.st,discord.store,discordInvites.net,discordactivities.com,discordapp.io,discordbee.com,discordbotlist.com,discordcdn.com,discordexpert.com,discordhome.com,discordhub.com,discordlist.me,discordlist.space,discordmerch.com,discordpartygames.com,discords.com,discordservers.com,discordstatus.com,discordtop.com,disforge.com,discordapp.net,findAdiscord.com,dyno.gg,mee6.xyz,top.gg/bypass,bypass6
EOF

# Установка прав на выполнение скриптов
echo "Установка прав на выполнение скриптов..."
chmod +x /opt/etc/init.d/S52ipset
chmod +x /opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh
chmod +x /opt/etc/ndm/ifstatechanged.d/011-bypass6-table.sh
chmod +x /opt/etc/ndm/netfilter.d/010-bypass.sh
chmod +x /opt/etc/ndm/netfilter.d/011-bypass6.sh


## Отключение системного DNS сервера
# Проверка системного DNS и версии прошивки
VERSION=$(ndmc -c show version | grep "title" | awk -F": " '{print $2}')
REQUIRED_VERSION="4.2.3"
DNS_OVERRIDE=$(curl -kfsS localhost:79/rci/opkg/dns-override)

if echo "$DNS_OVERRIDE" | grep -q "false"; then
    if [ "$(printf '%s\n' "$VERSION" "$REQUIRED_VERSION" | sort -V | tail -n1)" = "$VERSION" ]; then
        echo "Прошивка устройства соответствует требуемой."
    else
        opkg install coreutils-nohup
        echo "Прошивка устройства меньше $REQUIRED_VERSION версии, из-за чего SSH-сессия будет прервана, но скрипт корректно закончит работу и роутер будет перезагружен."
        echo ""
        echo "AdGuard Home будет доступен по адресу: http://$IP_ADDRESS:3000/"
        echo "Login: admin"
        echo "Password: keenetic"
        echo ""
        echo "Для продолжения нажмите ENTER"
        read -r
        nohup sh -c "ndmc -c 'opkg dns-override' && ndmc -c 'system configuration save' && reboot" > /dev/null 2>&1 &
    fi
fi

# Прошивка соответствует требованиям
echo "Отключаем системный DNS..."
ndmc -c 'opkg dns-override'
ndmc -c 'system configuration save'


# Информационные сообщения
echo ""
echo "Установка завершена."
echo ""
echo "AdGuard Home доступен по адресу: http://$IP_ADDRESS:3000/"
echo "Login: admin"
echo "Password: keenetic"
echo ""

# Удаляем скрипт после выполнения
rm -- "$0"

# Ждем Enter и ребутимся
echo "Нажмите Enter для перезагрузки (обязательно)."
read -r
reboot