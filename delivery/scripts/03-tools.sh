#!/bin/bash

# Install some basic tools and libraries
apt-get -y install console-common htop less locales nginx ntp openssh-server vim || exit 1
