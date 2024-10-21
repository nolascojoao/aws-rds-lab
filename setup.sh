#!/bin/bash
# Update the instance packages
sudo dnf update -y

# Install the MariaDB client
sudo dnf install -y mariadb105-server.x86_64
sudo systemctl start mariadb
sudo systemctl enable mariadb


