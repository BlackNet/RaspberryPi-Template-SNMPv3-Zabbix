# RaspberryPi-Template-SNMPv3-Zabbix
host script + Zzabbix template for Raspberry Pi 4/5


# install on PI
sudo apt install snmpd
wget https://github.com/BlackNet/RaspberryPi-Template-SNMPv3-Zabbix/raw/refs/heads/main/pi-snmpv3-setup.sh
sudo ./pi-snmpv3-setup.sh
fill in passwords

Zabbix side:
import template, assign to host.
