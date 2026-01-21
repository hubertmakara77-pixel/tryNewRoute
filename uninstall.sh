#!/bin/bash

chmod +x scripts/*.sh

if [ ! $UID -eq 0 ]; then
	echo "Please run script as root: sudo ./uninstall.sh"
	exit 0
fi

set -e
for script in scripts/*.sh; do
	bash "$script" -D
done
