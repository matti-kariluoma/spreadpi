#!/bin/bash

debconf-set-selections /debconf.set || exit 1
rm -f /debconf.set || exit 1

# Update packages
apt-get update || exit 1
