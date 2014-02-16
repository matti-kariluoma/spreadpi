#!/bin/bash

# TODO: if $DELIVERY_DIR has spaces will fail
su pi -c "tar xf $DELIVERY_DIR/files/pihome.tar.gz -C /home/pi/" || exit 1
# TODO: overzealous, maybe better than 'su pi -c' above?
#chown pi:pi -R /home/pi

if [ -e "$SSH_KEY" ]; then
	cp "$SSH_KEY" /home/pi/.ssh/authorized_keys || exit 1
fi

# enable boot to desktop
update-rc.d lightdm enable 2 || exit 1
sed /etc/lightdm/lightdm.conf -i -e "s/^#autologin-user=.*/autologin-user=pi/" || exit 1
# disable raspi-config at boot
# no || exit 1, ok to fail
rm -f /etc/profile.d/raspi-config.sh
sed -i /etc/inittab \
		-e "s/^#\(.*\)#\s*RPICFG_TO_ENABLE\s*/\1/" \
		-e "/#\s*RPICFG_TO_DISABLE/d"
