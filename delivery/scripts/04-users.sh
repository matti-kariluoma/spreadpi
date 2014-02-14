#!/bin/bash

# TODO: if $DELIVERY_DIR has spaces will fail
su pi -c "tar xf $DELIVERY_DIR/files/home.pi.tar.gz -C /" || exit 1
# TODO: overzealous, maybe better than 'su pi -c' above?
#chown pi:pi -R /home/pi

if [ -e "$SSH_KEY" ]; then
	cp "$SSH_KEY" /home/pi/.ssh/authorized_keys || exit 1
fi
