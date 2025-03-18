#!/bin/bash

# If you run docker_registry_proxy in host os in mac to cache images, this script config the ca and proxy in vm in virtualbox

mkdir -p /etc/systemd/system/docker.service.d
cat << EOD > /etc/systemd/system/docker.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://10.0.2.2:3128/"
Environment="HTTPS_PROXY=http://10.0.2.2:3128/"
EOD

### UBUNTU
# Get the CA certificate from the proxy and make it a trusted root.
curl http://10.0.2.2:3128/ca.crt > /usr/share/ca-certificates/docker_registry_proxy.crt
echo "docker_registry_proxy.crt" >> /etc/ca-certificates.conf
update-ca-certificates --fresh
###

# Reload systemd
systemctl daemon-reload

# Restart dockerd
systemctl restart docker.service
