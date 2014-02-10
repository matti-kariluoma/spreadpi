#!/bin/bash

if [ -e "$SSH_KEY" ]; then
	cp "$SSH_KEY" /home/pi/.ssh/authorized_keys || exit 1
fi
