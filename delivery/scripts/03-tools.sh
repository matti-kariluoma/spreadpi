#!/bin/bash

# Install some basic tools and libraries
apt-get -y install console-common locales nginx ntp || exit 1
