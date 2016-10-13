# simplvpn

This standalone script allows you to manage configuration files for an OpenVPN server and multiple clients using only one-liners, and no OpenSSL command.

Unlike its predecessors, it does not rely on easy-rsa, it is fairly straightforward to parse and understand (< 250 lines), and doesn't try to cover all your possible needs with dozens of commandline options. Instead, you are given a "sane" OpenSSL configuration file, which you are encouraged to read and understand, and which you can edit if it doesn't suit you.

## Usage

Clone this project using Git, or just wget the script, then *read it*.

    git clone https://github.com/mtth-bfft/simplvpn.git my_vpn_config
    cd my_vpn_config

### Without Docker:

Initialise a certification authority, a server configuration, and a client configuration template in the same directory:

    ./simplvpn.sh init

Modify server.conf and client_template.conf (you will especially need to setup the *remote* and *port* parts, but you might want to disable compression, change the cipher suite, etc.)

Issue certificates and create all-in-one profiles for each of your clients (each must have a unique ID containing only letters, digits, underscores and dashes):

    ./simplvpn.sh issue "my-client-name"
    ./simplvpn.sh issue "another-explicit-id"

If a client profile or private key gets leaked, or if you password-protect it and lose the password, you might want to prevent that profile from being used:

    ./simplvpn.sh revoke "my-client-name"

If you want to remove *all configuration files, certificates, private keys, and profiles* after your tests, simply run: (like all other commands, it will prompt you before modifying anything, except if you use the -y option)

    ./simplvpn.sh cleanup

### With Docker:

Build a local image and run commands as in the previous case, but prefixed with the following Docker options:

    docker build -t simplvpn .
    docker run -it --rm -v /your/config/dir/:/etc/openvpn/ simplvpn /etc/openvpn/simplvpn.sh init

Edit /your/config/dir/{server,client_template}.conf to suit your needs (at least the *remote* and *port* parts). Then issue certificates as needed and start your server:

    docker run -it --rm -v /your/config/dir/:/etc/openvpn/ simplvpn /etc/openvpn/simplvpn.sh issue "your-client"
    docker run -v /your/config/dir/:/etc/openvpn/ -p 9090:9090 --cap-add NET_ADMIN simplvpn openvpn-run.sh

Finally, you only have to send /your/config/dir/your-client.ovpn to your client.

## Recommendations:

1. Read OpenVPN's [documentation](https://openvpn.net/howto.html)
2. Read the contents of this script, and understand at least its basic steps;
3. As recommended in [simplca.sh](https://github.com/mtth-bfft/simplca), handle CA operations offline, or at least move
   client private keys and .ovpn profiles offline once they are generated.

## Contributing

I've tested this script and its generated configurations against OpenVPN Connect 1.1.{16,17} on Android 6.0.1, OpenVPN Connect 1.0.7 on iOS 9.3.5, NetworkManager 1.4.2 on Linux, and Tunnelblick 3.5.11 on Mac OS 10.6.8. Help by telling me if it works on other versions or platforms, otherwise open an issue with your logs.

