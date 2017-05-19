#!/bin/sh

# Configuration variables
# (do not edit these, or your changes will be lost during updates:
# instead put your customisations in a separate simplvpn.local.sh script)

set -euo pipefail

VPN_DIR=`pwd`
CA_DIR="${VPN_DIR}/ca"
CA_SCRIPT="${CA_DIR}/simplca.sh"
CA_LOCALCONF="${CA_DIR}/simplca.local.sh"
CA_SERVER_NAME="openvpn-server"
VPN_DH_BITS=2048
VPN_SUBNET_ID=73 # 1 to 255, change in case of collision
VPN_CONFIGS="${VPN_DIR}/configs"
VPN_IPCONFIGS="${VPN_DIR}/ip"
VPN_KEYS="${VPN_DIR}/keys"
VPN_SERVER_CONFIG="${VPN_CONFIGS}/server.conf"
VPN_CLIENT_TEMPLATE="${VPN_CONFIGS}/client_template.conf"
VPN_TLSAUTH="${VPN_KEYS}/ta.key"
VPN_DH="${VPN_KEYS}/dh${VPN_DH_BITS}.pem"

[ -r ${VPN_DIR}/simplvpn.local.sh ] && source ${VPN_DIR}/simplvpn.local.sh

function confirm_prompt {
    [ $BATCH -eq 1 ] && return 0
    echo -n "${1:-Continue?} [y/N] " >&2
    read -r -n1 yn
    echo >&2
    case $yn in
        [yY]) return 0 ;;
        *) return 1 ;;
    esac
}

function show_usage {
    echo "Usage: $0 init [-y]" >&2
    echo "       $0 issue <alphanumeric_id> [-y] " >&2
    echo "       $0 revoke <alphanumeric_id> [-y] " >&2
    echo "       $0 list" >&2
    echo "       $0 cleanup [-y] " >&2
}

function die {
    echo "Error: $1" >&2
    exit 1
}

function ca_run_cmd {
    local prev=`pwd`
    cd "$CA_DIR"
    ./simplca.sh $@
    local res=$?
    cd "$prev"
    return $res
}

function gen_server_conf {
    cat <<EOF
proto tcp
port 9090

dev tun
topology subnet

ca $(ca_run_cmd get-cert ca)
cert $(ca_run_cmd get-cert "$CA_SERVER_NAME")
key $(ca_run_cmd get-key "$CA_SERVER_NAME")
dh ${VPN_DH}
tls-auth ${VPN_TLSAUTH} 0
crl-verify ${CA_DIR}/crl.pem

cipher AES-128-CBC

server 10.${VPN_SUBNET_ID}.0.0 255.255.255.0
client-config-dir ${VPN_IPCONFIGS}/

; Tunnel everything through us (e.g. DNS)
push "redirect-gateway def1"
push "dhcp-option DNS 8.8.8.8"

; Ping every 10s, disconnect after 2mins
keepalive 10 120

comp-lzo

user nobody
group nobody
persist-key
persist-tun

;status /var/log/openvpn/openvpn-status.log
;log-append /var/log/openvpn/openvpn.log
verb 2
mute 20
EOF
}

function gen_client_template {
    cat <<EOF
client
dev tun
proto tcp
remote <YOUR_SERVER_IP>
port <YOUR_SERVER_PORT>
resolv-retry infinite
nobind
persist-key
persist-tun
key-direction 1
verb 3
keepalive 10 120
comp-lzo
cipher AES-128-CBC
remote-cert-tls server
EOF
}

# Takes a client ID and outputs a configuration file for that client
function gen_client_conf {
    CA=$(ca_run_cmd get-cert ca)
    CERT=$(ca_run_cmd get-cert "$1")
    KEY=$(ca_run_cmd get-key "$1")
    cat "${VPN_CLIENT_TEMPLATE}"
    cat <<EOF
<ca>
$(cat "$CA")
</ca>
<cert>
$(cat "$CERT")
</cert>
<key>
$(cat "$KEY")
</key>
<tls-auth>
$(cat "$VPN_TLSAUTH")
</tls-auth>
EOF
}

function vpn_exists {
    [ -d ${CA_DIR} ] && return 0
    [ -d ${VPN_CONFIGS} ] && return 0
    [ -d ${VPN_IPCONFIGS} ] && return 0
    [ -d ${VPN_KEYS} ] && return 0
    return 1
}

function vpn_cleanup {
    if vpn_exists && ! confirm_prompt "About to overwrite CA and configuration files. Continue?"; then
        die "user abort, no modification"
    fi
    rm -rf "$CA_DIR" "$VPN_CONFIGS" "$VPN_IPCONFIGS" "$VPN_KEYS"
    echo "VPN configuration successfully reset to an empty state" >&2
}

function vpn_init {
    vpn_cleanup
    git clone https://github.com/mtth-bfft/simplca.git "${CA_DIR}"
    # Override the default CRL duration: only the server uses the CRL,
    # so we're guaranteed it will have the latest version. Reducing this
    # would only add maintenance overhead.
    echo "#!/bin/sh" > ${CA_LOCALCONF}
    echo "CRT_DURATION=3650 # days" >> ${CA_LOCALCONF}
    echo "CRL_DURATION=3650 # days" >> ${CA_LOCALCONF}
    ca_run_cmd init -y
    ca_run_cmd issue-server "$CA_SERVER_NAME" -y >/dev/null
    mkdir -p "$VPN_CONFIGS" "$VPN_KEYS" "$VPN_IPCONFIGS"
    openssl dhparam -out "$VPN_DH" "$VPN_DH_BITS"
    openvpn --genkey --secret "$VPN_TLSAUTH"
    sed -i -r -e 's/^#.*$//' -e '/^$/d' "$VPN_TLSAUTH"
    gen_server_conf > "$VPN_SERVER_CONFIG"
    gen_client_template > "$VPN_CLIENT_TEMPLATE"
    chmod -R 0600 "$VPN_KEYS"
    echo "VPN successfully configured" >&2
}

function vpn_get_client_ip {
    [ -f "${VPN_IPCONFIGS}/$1" ] || die "identifier not found"
    cat "${VPN_IPCONFIGS}/$1" | grep ifconfig-push | awk '{ print $2 }'
}

# Returns 0 if client ID found and valid, 1 if not found, 2 if it was revoked
function vpn_get_status {
    vpn_exists || die "please initialise your VPN configuration first"
    ca_run_cmd get-status "$1"
}

function vpn_list {
    vpn_exists || die "please initialise your VPN configuration first"
    echo -e "status\tIP      \tidentifier"
    for config in $(find "$VPN_CONFIGS" -type f -name "*.ovpn"); do
        clientid=$(basename "$config" | sed -r 's#\.ovpn$##')
        vpn_get_status "$clientid" &>/dev/null && status="valid" || status="revoked"
        echo -e "${status}\t$(vpn_get_client_ip "$clientid")\t${clientid}"
    done
}

function vpn_issue {
    vpn_exists || die "please initialise your VPN configuration first"
    CLIENTNB=$(ls -l ${VPN_CONFIGS}/*.ovpn 2>/dev/null | wc -l || true)
    IPADDR="10.${VPN_SUBNET_ID}.0.$(($CLIENTNB + 1))"
    [ -f "${VPN_CONFIGS}/${CLIENTID}.ovpn" ] && die "client ID in use, please choose another."
    if ! confirm_prompt "About to issue a client certificate for '${CLIENTID}'. Continue?"; then
        die "user abort, no modification"
    fi
    ca_run_cmd issue-client "$CLIENTID" -y >&2
    # Static IP address assignment (accountability)
    echo "ifconfig-push ${IPADDR} 255.255.255.0" > "${VPN_IPCONFIGS}/${CLIENTID}"
    gen_client_conf "$CLIENTID" | tee "${VPN_CONFIGS}/${CLIENTID}.ovpn"
    echo "Client configuration written to ${VPN_CONFIGS}/${CLIENTID}.ovpn (assigned IP ${IPADDR})" >&2
}

function vpn_revoke {
    vpn_exists || die "please initialise your VPN configuration first"
    vpn_get_status "$1" &>/dev/null || die "profile not found or already revoked"
    confirm_prompt "About to revoke profile certificate for '${1}'. Continue?" || exit 1
    ca_run_cmd revoke "$1" -y >&2
    echo "Client profile revoked successfully" >&2
}

function vpn_main {
    [ $# -gt 0 ] || { show_usage ; exit 1; }

    # Read command from first argument
    CMD=$1
    CLIENTID=''
    shift
    case $CMD in
        issue|revoke|get-ip|get-status)
            [ $# -gt 0 ] || die "command $CMD requires an identifier as argument"
            echo "$1" | grep -qE '^[a-zA-Z0-9_-]+$' || die "invalid identifier for command $CMD"
            CLIENTID="$1"
            shift ;;
    esac

    # Read optional arguments
    BATCH=0
    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help) show_usage; exit 0 ;;
            -y|--yes) BATCH=1 ;;
            *) die "unknown option '$1'" ;;
        esac
        shift
    done

    # Call the appropriate function
    case $CMD in
        init) vpn_init ;;
        list) vpn_list ;;
        issue) vpn_issue "$CLIENTID" ;;
        revoke) vpn_revoke "$CLIENTID" ;;
        get-ip) vpn_get_client_ip "$CLIENTID" ;;
        get-status) vpn_get_status "$CLIENTID" ;;
        list) vpn_list ;;
        cleanup) vpn_cleanup ;;
        *) show_usage ; exit 1 ;;
    esac
}

# Check that OpenVPN is installed (needed by vpn_init to generate a PSK)
which openvpn &>/dev/null || die "please install OpenVPN before proceeding"
case "$0" in
	*simplvpn.sh*) vpn_main $@ ;;
esac # otherwise, script is being sourced
