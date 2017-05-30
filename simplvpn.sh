#!/bin/sh

# simplvpn.sh standalone script, Copyright (c) 2017 Matthieu Buffet
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Configuration variables
# (do not edit these, or your changes will be lost during updates:
# instead put your customisations in a separate simplvpn.local.sh script)
CA_DIR="ca"
SRV_DIR="srv"
CA_SCRIPT="${CA_DIR}/simplca.sh"
CA_LOCALCONF="${CA_DIR}/simplca.local.sh"
CA_CRL="crl.pem"
CA_SERVER_NAME="openvpn-server"
VPN_DH_BITS=2048
VPN_SUBNET_ID=73 # 1 to 255, change in case of collision
VPN_CLIENT_PROFILES="profiles"
VPN_CLIENT_CONFIGS="configs"
VPN_CLIENT_TEMPLATE="client_template.conf"

# Site-local customisations
[ -r simplvpn.local.sh ] && source simplvpn.local.sh

# Lists options and arguments on stderr
function vpn_show_usage {
    echo "Usage: $0 init" >&2
    echo "       $0 issue <alphanumeric_id>" >&2
    echo "       $0 revoke <alphanumeric_id>" >&2
    echo "       $0 get-status <alphanumeric_id>" >&2
    echo "       $0 get-ip <alphanumeric_id>" >&2
    echo "       $0 list" >&2
    echo "       $0 cleanup" >&2
}

# Prompts for y/N confirmation if shell is interactive, otherwise assumes yes
function vpn_confirm_prompt {
    [ -t 0 ] || return 0
    case "$-" in
        *i*) return 0 ;;
    esac
    echo -n "${1:-Continue?} [y/N] " >&2
    read -r -n1 yn
    echo >&2
    case $yn in
        [yY]) return 0 ;;
    esac
    return 1
}

# Displays the given error message on stderr
function vpn_warn {
    echo "Error: $@" >&2
}

# Runs simplca.sh with the given arguments
function vpn_run_ca_cmd {
    local prev=`pwd`
    cd "$CA_DIR"
    ./simplca.sh $@
    local res=$?
    cd "$prev"
    return $res
}

# Outputs an OpenVPN server configuration file on stdout, given global variables
function vpn_gen_server_conf {
    cat <<EOF
proto tcp
port 9090

dev tun
topology subnet

ca ca.pem
cert ${CA_SERVER_NAME}.pem
key ${CA_SERVER_NAME}.key
dh dh${VPN_DH_BITS}.pem
tls-auth ta.key 0
crl-verify crl.pem

cipher AES-128-CBC

server 10.${VPN_SUBNET_ID}.0.0 255.255.255.0
client-config-dir ${VPN_CLIENT_CONFIGS}/

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

verb 2
mute 20
EOF
}

# Outputs the common part of all OpenVPN client configurations on stdout.
function vpn_gen_client_template {
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

# Takes a client ID and outputs a configuration file for that client on stdout.
function vpn_gen_client_conf {
    cat "${VPN_CLIENT_TEMPLATE}"
    cat <<EOF
<ca>
$(cat "${CA_DIR}/certs/ca.pem")
</ca>
<cert>
$(cat "${CA_DIR}/certs/$1.pem")
</cert>
<key>
$(cat "${CA_DIR}/keys/$1.key")
</key>
<tls-auth>
$(cat "${SRV_DIR}/ta.key")
</tls-auth>
EOF
}

# Removes all state (configuration files, profiles, keys, certificates) from
# the current folder.
function vpn_cleanup {
    [ -d "$VPN_CLIENT_PROFILES" -o -d "$VPN_CLIENT_CONFIGS" -o -d "$SRV_DIR" ] || return 0 
    vpn_confirm_prompt "About to REMOVE ALL CERTIFICATES AND KEYS. Continue?" || return 1
    rm -rf "$SRV_DIR" "$VPN_CLIENT_PROFILES" "$VPN_CLIENT_CONFIGS" "$VPN_CLIENT_TEMPLATE"
    [ -x "$CA_SCRIPT" ] && vpn_run_ca_cmd cleanup 0<&-
    echo "VPN configuration successfully reset to an empty state" >&2
}

function vpn_init {
    vpn_cleanup
    if ! [ -d "$CA_DIR" ] && ! which git &>/dev/null; then
        vpn_warn "please install git or manually clone https://github.com/mtth-bfft/simplca"
        return 1
    fi
    [ -d "$CA_DIR" ] || git clone https://github.com/mtth-bfft/simplca.git "$CA_DIR"
    # Override the default CRL duration: only the server uses the CRL,
    # so we're guaranteed it will have the latest version. Reducing this
    # would only add maintenance overhead.
    echo "#!/bin/sh" > "$CA_LOCALCONF"
    echo "CRT_DURATION=3650 # days" >> "$CA_LOCALCONF"
    echo "CRL_DURATION=3650 # days" >> "$CA_LOCALCONF"
    echo "CA_CRL='../${SRV_DIR}/crl.pem'" >> "$CA_LOCALCONF"
    mkdir -p "$SRV_DIR" "$VPN_CLIENT_PROFILES" "$VPN_CLIENT_CONFIGS"
    vpn_run_ca_cmd init || return $?
    vpn_run_ca_cmd issue server "$CA_SERVER_NAME" >/dev/null 0<&- || return $?
    cp "${CA_DIR}/certs/ca.pem" "$SRV_DIR"
    cp "${CA_DIR}/certs/${CA_SERVER_NAME}.pem" "$SRV_DIR"
    cp "${CA_DIR}/keys/${CA_SERVER_NAME}.key" "$SRV_DIR"
    openssl dhparam -out "${SRV_DIR}/dh${VPN_DH_BITS}.pem" "$VPN_DH_BITS"
    openvpn --genkey --secret "${SRV_DIR}/ta.key"
    sed -i -r -e 's/^#.*$//' -e '/^$/d' "${SRV_DIR}/ta.key"
    vpn_gen_server_conf > "${SRV_DIR}/server.conf"
    vpn_gen_client_template > "$VPN_CLIENT_TEMPLATE"
    chmod -R 0600 "$CA_DIR" "$SRV_DIR" "$VPN_CLIENT_PROFILES" \
        "$VPN_CLIENT_CONFIGS" "$VPN_CLIENT_TEMPLATE"
    chmod o+x "$CA_SCRIPT"
    echo "VPN successfully configured" >&2
}

# Takes an alphanumeric client ID and outputs its associated IP on stdout.
# Returns 0 if and only if successful.
function vpn_get_client_ip {
    [ $# -eq 1 ] && [ -n "$1" ] || { vpn_warn "vpn_get_client_ip requires an ID"; return 1; }
    [ -f "${VPN_CLIENT_CONFIGS}/$1" ] || { vpn_warn "identifier not found"; return 2; }
    cat "${VPN_CLIENT_CONFIGS}/$1" | grep ifconfig-push | awk '{ print $2 }' || return $?
}

# Takes an alphanumeric client ID and outputs its status amongst
# ok/revoked/expired on stdout. Returns 0 if and only if certificate is valid.
function vpn_get_status {
    vpn_run_ca_cmd get-status "$1" || return $?
}

# Outputs a list of all clients on stdout. Always returns 0.
function vpn_list {
    echo -e "status \tIP            \tidentifier"
    IFS=$'\n'; for line in $(vpn_run_ca_cmd list | sed '1d'); do
        [ "$(echo "$line" | cut -f1)" != 'client' ] && continue;
        status=$(echo "$line" | cut -f2)
        clientid=$(echo "$line" | cut -f3)
        echo -e "${status}\t$(vpn_get_client_ip "$clientid")\t${clientid}"
    done
}

# Takes an alphanumeric client iD and issues a new certificate for it. Outputs
# the associated client profile on stdout. Returns 0 if and only if successful.
function vpn_issue {
    [ $# -eq 1 ] || { vpn_warn "vpn_issue requires an ID"; return 1; }
    local clientnb=$(ls -l ${VPN_CLIENT_PROFILES}/*.ovpn 2>/dev/null | wc -l || true)
    local ip="10.${VPN_SUBNET_ID}.0.$(($clientnb + 1))"
    if [ -f "${VPN_CLIENT_PROFILES}/$1.ovpn" ]; then
        vpn_warn "client ID in use, please choose another."
        return 1
    elif  ! vpn_confirm_prompt "About to issue a client certificate for '$1'. Continue?"; then
        vpn_warn "user abort, no modification"
        return 2
    fi
    vpn_run_ca_cmd issue client "$1" >&2 0<&- || return $?
    echo "ifconfig-push ${ip} 255.255.255.0" > "${VPN_CLIENT_CONFIGS}/$1"
    vpn_gen_client_conf "$1" | tee "${VPN_CLIENT_PROFILES}/$1.ovpn"
    echo "Client configuration written to ${VPN_CLIENT_PROFILES}/$1.ovpn (assigned IP ${ip})" >&2
}

# Takes an alphanumeric client ID and revokes its certificate.
# Returns 0 if and only if successful.
function vpn_revoke {
    [ $# -eq 1 ] && [ -n "$1" ] || { vpn_warn "vpn_revoke requires an ID"; return 1; }
    if ! vpn_get_status "$1" &>/dev/null; then
        vpn_warn "profile not found or already revoked"
        return 2
    fi
    vpn_confirm_prompt "About to revoke profile '${1}'. Continue?" || return 3
    vpn_run_ca_cmd revoke "$1" >&2 0<&- || return $?
    echo "Client profile revoked successfully" >&2
}

function vpn_main {
    [ $# -gt 0 ] || { vpn_show_usage ; exit 1; }
    case "$1" in
        issue|revoke|get-ip|get-status)
            [ $# -eq 2 ] || { vpn_show_usage; exit 2; };;
        *) [ $# -eq 1 ] || { vpn_show_usage; exit 2; };;
    esac
    case "$1" in
        init) vpn_init ;;
        issue) vpn_issue "$2" ;;
        revoke) vpn_revoke "$2" ;;
        get-status) vpn_get_status "$2" ;;
        get-ip) vpn_get_client_ip "$2" ;;
        list) vpn_list ;;
        cleanup) vpn_cleanup ;;
        *) vpn_warn "unknown command '$1'"; vpn_show_usage ; exit 1 ;;
    esac
}

if ! which openvpn &>/dev/null; then
    vpn_warn "please install OpenVPN before proceeding"
    exit 1
fi
case "$0" in
    *simplvpn.sh*) vpn_main $@ ;;
esac # otherwise, script is being sourced
