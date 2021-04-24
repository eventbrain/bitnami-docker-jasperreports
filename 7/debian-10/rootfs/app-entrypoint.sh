#!/bin/bash -e

. /opt/bitnami/base/functions
. /opt/bitnami/base/helpers

print_welcome_page

if [[ "$1" == "nami" && "$2" == "start" ]] || [[ "$1" == "/init.sh" ]]; then
    nami_initialize tomcat mysql-client jasperreports
    info "Starting gosu... "
    if [ -d "/bitnami/custom-config/" ]; then
        if ! [ -z "$(ls -A /bitnami/custom-config/)" ]; then 
            cp -r "/bitnami/custom-config/" "/opt/bitnami/jasperreports/"
        fi
    fi
fi

exec tini -- "$@"
