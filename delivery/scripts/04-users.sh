#!/bin/bash

# Create root user
echo "root:raspberry" | chpasswd || exit 1
cp "$DELIVERY_DIR/files/bashrc" /root/.bashrc || exit 1


# Create spreads user
useradd -s /bin/bash -m spreads || exit 1
echo "spreads:spreads" |chpasswd || exit 1
cp "$DELIVERY_DIR/files/bashrc" /home/spreads/.bashrc || exit 1
mkdir -p /home/spreads/.ssh || exit 1

if [ -e "$SSH_KEY" ]; then
	cp "$SSH_KEY" /home/spreads/.ssh/authorized_keys || exit 1
fi
