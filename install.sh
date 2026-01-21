#!/bin/bash

chmod +x scripts/*.sh

if [ ! $UID -eq 0 ]; then
	echo "Please run script as root: sudo ./install.sh"
	exit 0
fi

apt update 

set -e
for script in scripts/*.sh; do
	bash "$script"
done
