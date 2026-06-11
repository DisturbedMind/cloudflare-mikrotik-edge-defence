# Home Cinema RouterOS 7.23 edge/local offender updater
# Router: 192.168.1.1
# Feed source: Debian reverse proxy at 192.168.1.10:8088

:local offenderList "home_cinema_offenders"

:if ([:len [/ip firewall raw find comment="home-cinema raw drop offenders"]] = 0) do={
    /ip firewall raw add chain=prerouting src-address-list=$offenderList action=drop comment="home-cinema raw drop offenders"
    /ip firewall raw move [find comment="home-cinema raw drop offenders"] 0
}

:if ([:len [/ip firewall filter find comment="home-cinema input drop offenders"]] = 0) do={
    /ip firewall filter add chain=input src-address-list=$offenderList action=drop comment="home-cinema input drop offenders"
    /ip firewall filter move [find comment="home-cinema input drop offenders"] 0
}

:if ([:len [/ip firewall filter find comment="home-cinema forward drop offenders"]] = 0) do={
    /ip firewall filter add chain=forward src-address-list=$offenderList action=drop comment="home-cinema forward drop offenders"
    /ip firewall filter move [find comment="home-cinema forward drop offenders"] 0
}

:if ([:len [/system script find name="home-cinema-update-offenders"]] = 0) do={
    /system script add name="home-cinema-update-offenders" policy=read,write,policy,test source={
        :local feedUrl "http://192.168.1.10:8088/mikrotik/offenders.rsc"
        :local feedFile "home-cinema-offenders.rsc"
        :log info "home-cinema: fetching offender feed"
        :do {
            /tool fetch url=$feedUrl dst-path=$feedFile
            /import file-name=$feedFile
            :log info "home-cinema: offender feed import complete"
        } on-error={
            :log warning "home-cinema: offender feed update failed"
        }
    }
} else={
    /system script set [find name="home-cinema-update-offenders"] source={
        :local feedUrl "http://192.168.1.10:8088/mikrotik/offenders.rsc"
        :local feedFile "home-cinema-offenders.rsc"
        :log info "home-cinema: fetching offender feed"
        :do {
            /tool fetch url=$feedUrl dst-path=$feedFile
            /import file-name=$feedFile
            :log info "home-cinema: offender feed import complete"
        } on-error={
            :log warning "home-cinema: offender feed update failed"
        }
    }
}

:if ([:len [/system scheduler find name="home-cinema-update-offenders"]] = 0) do={
    /system scheduler add name="home-cinema-update-offenders" interval=30m start-time=startup on-event="/system script run home-cinema-update-offenders" comment="home-cinema offender updater"
} else={
    /system scheduler set [find name="home-cinema-update-offenders"] interval=30m on-event="/system script run home-cinema-update-offenders" comment="home-cinema offender updater"
}

/system script run home-cinema-update-offenders

