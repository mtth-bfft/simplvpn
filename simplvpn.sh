#!/bin/bash

# Configuration variables
# (do not edit these, or your changes will be lost during updates:
# instead put your customisations in a separate simplvpn.local.sh script)

pushd `dirname $0` > /dev/null
VPN_DIR=`pwd`
popd > /dev/null
CA_DIR="${VPN_DIR}/ca"
CA_SCRIPT="${CA_DIR}/simplca.sh"
CA_LOCALCONF="${CA_DIR}/simplca.local.sh"
VPN_DH_BITS=2048
VPN_SUBNET_ID=73 # 1 to 255, change in case of collision
VPN_CLIENTS="${VPN_DIR}/clients"
VPN_CONFIG="${VPN_DIR}/server.conf"
VPN_CLIENT_TEMPLATE="${VPN_DIR}/client_template.conf"
VPN_TLSAUTH="${VPN_DIR}/ta.key"
VPN_DH="${VPN_DIR}/dh${VPN_DH_BITS}.pem"

[ -r ${VPN_DIR}/simplvpn.local.sh ] && source ${VPN_DIR}/simplvpn.local.sh

# Bash "safe" mode
set -euo pipefail

function confirm_prompt {
    [ $BATCH -eq 1 ] && return 0
    read -r -n1 -p "${1:-Continue?} [y/N] " yn
    echo
    case $yn in
        [yY]) return 0 ;;
        *) return 1 ;;
    esac
}

function show_usage {
    echo "Usage: $0 init [-y]" >&2
    echo "       $0 issue <alphanumeric_id> [-y] " >&2
    echo "       $0 revoke <alphanumeric_id> [-y] " >&2
    echo "       $0 cleanup [-y] " >&2
}

function die {
    echo "Error: $1" >&2
    exit 1
}

function gen_server_conf {
    cat <<EOF
proto tcp
port 9090

dev tun
topology subnet

ca ${CA_DIR}/ca.pem
cert ${CA_DIR}/server1.pem
key ${CA_DIR}/server1.key
dh ${VPN_DH}
tls-auth ${VPN_TLSAUTH} 0
crl-verify ${CA_DIR}/crl.pem

cipher AES-128-CBC

server 10.${VPN_SUBNET_ID}.0.0 255.255.255.0
client-config-dir ${VPN_CLIENTS}/

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
verb 3
mute 20
EOF
}

function gen_client_template {
    cat <<EOF
client
dev tun
proto tcp
remote <YOUR_REMOTE>
port <YOUR_PORT>
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

function gen_client_conf {
    cat "${VPN_CLIENT_TEMPLATE}"
    cat <<EOF
<ca>
$(cat ${CA_DIR}/ca.pem)
</ca>
<cert>
$(cat ${CA_DIR}/${CLIENTID}.pem)
</cert>
<key>
$(cat ${CA_DIR}/${CLIENTID}.key)
</key>
<tls-auth>
$(cat ${VPN_TLSAUTH})
</tls-auth>
EOF
}

function vpn_exists {
    [ -d ${CA_DIR} ] && return 0
    [ -d ${VPN_CLIENTS} ] && return 0
    [ -f ${VPN_CONFIG} ] && return 0
    [ -f ${VPN_CLIENT_TEMPLATE} ] && return 0
    [ -f ${VPN_DH} ] && return 0
    [ -f ${VPN_TLSAUTH} ] && return 0
    return 1
}

function vpn_cleanup {
    if vpn_exists && ! confirm_prompt "About to overwrite CA and configs. Continue?"; then
        die "abort by user, no modification."
    fi
    rm -rf ${CA_DIR} ${VPN_CLIENTS} ${VPN_CONFIG} ${VPN_CLIENT_TEMPLATE}
    rm -rf ${VPN_DH} ${VPN_TLSAUTH} ${VPN_DIR}/*.ovpn
}

function vpn_init {
    vpn_cleanup
    git clone https://github.com/mtth-bfft/simplca.git "${CA_DIR}"
    # Override the default CRL duration: only the server uses the CRL,
    # so we're guaranteed it will have the latest version. Reducing this
    # would only add maintenance overhead.
    echo "#!/bin/bash" > ${CA_LOCALCONF}
    echo "CRT_DURATION=3650 # days" >> ${CA_LOCALCONF}
    echo "CRL_DURATION=3650 # days" >> ${CA_LOCALCONF}
    ${CA_SCRIPT} init -y
    ${CA_SCRIPT} issue-server "server1" -y
    openssl dhparam -out "${VPN_DH}" "${VPN_DH_BITS}"
    chmod 0600 "${VPN_DH}"
    openvpn --genkey --secret "${VPN_TLSAUTH}"
    chmod 0600 "${VPN_TLSAUTH}"
    gen_server_conf > ${VPN_CONFIG}
    gen_client_template > ${VPN_CLIENT_TEMPLATE}
    mkdir -p ${VPN_CLIENTS}
}

function vpn_issue {
    CLIENTNB=$(ls -l ${CA_DIR}/*.pem | wc -l)
    [ -f ${VPN_CLIENTS}/${CLIENTID} ] && die "client name in use, please choose another."
    if ! confirm_prompt "About to issue a certificate for '${CLIENTID}'. Continue?"; then
        die "user abort, no modification"
    fi
    ${CA_SCRIPT} issue-client "${CLIENTID}" -y
    echo "ifconfig-push 10.${VPN_SUBNET_ID}.0.${CLIENTNB} 255.255.255.0" > ${VPN_CLIENTS}/${CLIENTID}
    gen_client_conf > ${VPN_DIR}/${CLIENTID}.ovpn
}

function vpn_revoke {
    die "not implemented yet. Sorry"
}

# Check that OpenVPN is installed
which openvpn >/dev/null 2>&1 || die "please install OpenVPN before proceeding"

# Read command from first argument
[ $# -gt 0 ] || die "command keyword needed"
CMD=$1
shift
CLIENTID=''
case $CMD in
    issue|revoke)
        [ $# -gt 0 ] || die "command $CMD requires an identifier as argument"
	[[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] || die "invalid identifier for command $CMD"
        CLIENTID=$1
	shift ;;
    init|cleanup) ;;
    *)
        die "unknown command $CMD"
esac

# Read optional arguments
BATCH=0
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) show_usage; exit 0 ;;
        -y|--yes) BATCH=1 ;;
        *) die "Invalid command line option: $1" ;;
    esac
    shift
done

# Call the appropriate function
case $CMD in
    init) vpn_init ;;
    issue) vpn_issue ;;
    revoke) vpn_revoke ;;
    cleanup) vpn_cleanup ;;
esac

