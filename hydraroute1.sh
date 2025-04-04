#!/bin/sh

# Служебные функции и переменные
LOG="/opt/var/log/HydraRoute.log"
echo "$(date "+%Y-%m-%d %H:%M:%S") Запуск установки" >> "$LOG"
REQUIRED_VERSION="4.2.3"
IP_ADDRESS=$(ip addr show br0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
VERSION=$(ndmc -c show version | grep "title" | awk -F": " '{print $2}')
AVAILABLE_SPACE=$(df /opt | awk 'NR==2 {print $4}')
## переменные для конфига AGH
PASSWORD=\$2y\$10\$fpdPsJjQMGNUkhXgalKGluJ1WFGBO6DKBJupOtBxIzckpJufHYpk.
rule1='||*^$dnstype=HTTPS,dnsrewrite=NOERROR'
rule2='||yabs.yandex.ru^$important'
rule3='||mc.yandex.ru^$important'
## анимация
animation() {
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

	wait $pid
	if [ $? -eq 0 ]; then
		echo -e "\b✔ Готово!"
	else
		echo -e "\b✖ Ошибка!"
	fi
}

# Получение списка и выбор интерфейса
get_interfaces() {
    ## выводим список интерфейсов для выбора
    echo "Доступные интерфейсы:"
    i=1
    interfaces=$(ip a | sed -n 's/.*: \(.*\): <.*UP.*/\1/p')
    interface_list=""
    for iface in $interfaces; do
        ## проверяем, существует ли интерфейс, игнорируя ошибки 'ip: can't find device'
        if ip a show "$iface" &>/dev/null; then
            ip_address=$(ip a show "$iface" | grep -oP 'inet \K[\d.]+')

            if [ -n "$ip_address" ]; then
                echo "$i. $iface: $ip_address"
                interface_list="$interface_list $iface"
                i=$((i+1))
            fi
        fi
    done

    ## запрашиваем у пользователя имя интерфейса с проверкой ввода
    while true; do
        read -p "Введите ИМЯ интерфейса, через которое будет перенаправляться трафик: " net_interface

        if echo "$interface_list" | grep -qw "$net_interface"; then
            echo "Выбран интерфейс: $net_interface"
			break
		else
			echo "Неверный выбор, необходимо ввести ИМЯ интерфейса из списка."
		fi
	done
}

# Установка пакетов
opkg_install() {
	opkg update
	opkg install adguardhome-go ipset iptables ip-full
}

# Формирование файлов
files_create() {
## ipset
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
	
## скрипты маршрутизации
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
	
## cкрипты маркировки трафика
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
}

# Настройки AGH
agh_setup() {
	/opt/etc/init.d/S99adguardhome stop
	## конфиг AdGuard Home
	cat << EOF > /opt/etc/AdGuardHome/AdGuardHome.yaml
http:
  pprof:
    port: 6060
    enabled: false
  address: $IP_ADDRESS:3000
  session_ttl: 720h
users:
  - name: admin
    password: $PASSWORD
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
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
  fallback_dns: []
  upstream_mode: load_balance
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
  use_private_ptr_resolvers: true
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
  interval: 24h
  size_memory: 1000
  enabled: false
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 24h
  enabled: false
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt
    name: AdGuard DNS Popup Hosts filter
    id: 1737211801
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt
    name: Phishing URL Blocklist (PhishTank and OpenPhish)
    id: 1737211802
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_42.txt
    name: ShadowWhisperer's Malware List
    id: 1737211803
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt
    name: The Big List of Hacked Malware Web Sites
    id: 1737211804
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_63.txt
    name: HaGeZi's Windows/Office Tracker Blocklist
    id: 1737211805
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_7.txt
    name: Perflyst and Dandelion Sprout's Smart-TV Blocklist
    id: 1737211806
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_12.txt
    name: Dandelion Sprout's Anti-Malware List
    id: 1737211807
whitelist_filters: []
user_rules:
  - '$rule1'
  - '$rule2'
  - '$rule3'
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
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safe_fs_patterns:
    - /opt/etc/AdGuardHome/userfilters/*
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
schema_version: 29
EOF
}

# Базовый список доменов
domain_add() {
	cat << EOF > /opt/etc/AdGuardHome/ipset.conf
2ip.ru/bypass,bypass6
googlevideo.com,ggpht.com,googleapis.com,googleusercontent.com,gstatic.com,nhacmp3youtube.com,youtu.be,youtube.com,ytimg.com/bypass,bypass6
cdninstagram.com,instagram.com,bookstagram.com,carstagram.com,chickstagram.com,ig.me,igcdn.com,igsonar.com,igtv.com,imstagram.com,imtagram.com,instaadder.com,instachecker.com,instafallow.com,instafollower.com,instagainer.com,instagda.com,instagify.com,instagmania.com,instagor.com,instagram.fkiv7-1.fna.fbcdn.net,instagram-brand.com,instagram-engineering.com,instagramhashtags.net,instagram-help.com,instagramhilecim.com,instagramhilesi.org,instagramium.com,instagramizlenme.com,instagramkusu.com,instagramlogin.com,instagrampartners.com,instagramphoto.com,instagram-press.com,instagram-press.net,instagramq.com,instagramsepeti.com,instagramtips.com,instagramtr.com,instagy.com,instamgram.com,instanttelegram.com,instaplayer.net,instastyle.tv,instgram.com,oninstagram.com,onlineinstagram.com,online-instagram.com,web-instagram.net,wwwinstagram.com/bypass,bypass6
1337x.to,262203.game4you.top,eztv.re,fitgirl-repacks.site,new.megashara.net,nnmclub.to,nnm-club.to,nnm-club.me,rarbg.to,rustorka.com,rutor.info,rutor.org,rutracker.cc,rutracker.org,tapochek.net,thelastgame.ru,thepiratebay.org,thepirate-bay.org,torrentgalaxy.to,torrent-games.best,torrentz2eu.org,limetorrents.info,pirateproxy-bay.com,torlock.com,torrentdownloads.me/bypass,bypass6
chatgpt.com,openai.com,oaistatic.com,files.oaiusercontent.com,gpt3-openai.com,openai.fund,openai.org/bypass,bypass6
EOF
}

# Установка прав на скрипты
chmod_set() {
	chmod +x /opt/etc/init.d/S52ipset
	chmod +x /opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh
	chmod +x /opt/etc/ndm/ifstatechanged.d/011-bypass6-table.sh
	chmod +x /opt/etc/ndm/netfilter.d/010-bypass.sh
	chmod +x /opt/etc/ndm/netfilter.d/011-bypass6.sh
}

# Отключение ipv6 на провайдере
disable_ipv6() {
	curl -kfsS "localhost:79/rci/show/interface/" | jq -r '
	  to_entries[] | 
	  select(.value.defaultgw == true or .value.via != null) | 
	  if .value.via then "\(.value.id) \(.value.via)" else "\(.value.id)" end
	' | while read -r iface via; do
	  ndmc -c "no interface $iface ipv6 address"
	  if [ -n "$via" ]; then
		ndmc -c "no interface $via ipv6 address"
	  fi
	done
	ndmc -c 'system configuration save'
}

# Проверка версии прошивки
firmware_check() {
	if [ "$(printf '%s\n' "$VERSION" "$REQUIRED_VERSION" | sort -V | tail -n1)" = "$VERSION" ]; then
		dns_off >>"$LOG" 2>&1 &
	else
		dns_off_sh
	fi
}

# Отклчюение системного DNS
dns_off() {
	ndmc -c 'opkg dns-override'
	ndmc -c 'system configuration save'
	sleep 3
}

# Отключение системного DNS через "nohup"
dns_off_sh() {
	opkg install coreutils-nohup >>"$LOG" 2>&1
	echo "Отключение системного DNS..."
	echo ""
	if [ "$PANEL" = "1" ]; then
		complete_info
	else
		complete_info_no_panel
	fi
	rm -- "$0"
	read -r
	/opt/bin/nohup sh -c "ndmc -c 'opkg dns-override' && ndmc -c 'system configuration save' && sleep 3 && reboot" >>"$LOG" 2>&1
}

# Сообщение установка ОK
complete_info() {
	echo "Установка HydraRoute завершена"
	echo " - панель управления доступна по адресу: http://$IP_ADDRESS:2000/"
	echo ""
	echo "Нажмите Enter для перезагрузки (обязательно)."
}

# Сообщение установка без панели
complete_info_no_panel() {
	echo "HydraRoute установлен, но для web-панели не достаточно места"
	echo " - редактирование ipset возможно только вручную (инструкция на GitHub)."
	echo ""
	echo "AdGuard Home доступен по адресу: http://$IP_ADDRESS:3000/"
	echo "Login: admin"
	echo "Password: keenetic"
	echo ""
	echo "Нажмите Enter для перезагрузки (обязательно)."
}

# === main ===
# Выход если места меньше 80Мб
if [ "$AVAILABLE_SPACE" -lt 81920 ]; then
	echo "Не достаточно места для установки"
	rm -- "$0"
	exit 1
fi

# Запрос интерфейса у пользователя
get_interfaces

# Установка пакетов
opkg_install >>"$LOG" 2>&1 &
animation $! "Установка необходимых пакетов"

# Формирование скриптов 
files_create >>"$LOG" 2>&1 &
animation $! "Формируем скрипты"

# Настройка AdGuard Home
agh_setup >>"$LOG" 2>&1 &
animation $! "Настройка AdGuard Home"

# Добавление доменов в ipset
domain_add >>"$LOG" 2>&1 &
animation $! "Добавление доменов в ipset"

# Установка прав на выполнение скриптов
chmod_set >>"$LOG" 2>&1 &
animation $! "Установка прав на выполнение скриптов"

# Отключение ipv6
disable_ipv6 >>"$LOG" 2>&1 &
animation $! "Отключение ipv6"

# Отключение системного DNS и сохранение
firmware_check
animation $! "Отключение системного DNS"

# Завершение
echo ""
if [ "$PANEL" = "1" ]; then
	complete_info
else
	complete_info_no_panel
fi
rm -- "$0"

# Ждем Enter и ребутимся
read -r
reboot
