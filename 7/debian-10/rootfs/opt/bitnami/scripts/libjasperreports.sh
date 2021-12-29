#!/bin/bash
#
# Bitnami JasperReports library

# shellcheck disable=SC1091

# Load generic libraries
. /opt/bitnami/scripts/libfs.sh
. /opt/bitnami/scripts/libos.sh
. /opt/bitnami/scripts/libnet.sh
. /opt/bitnami/scripts/libfile.sh
. /opt/bitnami/scripts/libvalidations.sh
. /opt/bitnami/scripts/libpersistence.sh
. /opt/bitnami/scripts/libservice.sh

# Load database library
if [[ -f /opt/bitnami/scripts/libmysqlclient.sh ]]; then
    . /opt/bitnami/scripts/libmysqlclient.sh
elif [[ -f /opt/bitnami/scripts/libmysql.sh ]]; then
    . /opt/bitnami/scripts/libmysql.sh
elif [[ -f /opt/bitnami/scripts/libmariadb.sh ]]; then
    . /opt/bitnami/scripts/libmariadb.sh
fi

########################
# Validate settings in JASPERREPORTS_* env vars
# Globals:
#   JASPERREPORTS_*
# Arguments:
#   None
# Returns:
#   0 if the validation succeeded, 1 otherwise
#########################
jasperreports_validate() {
    debug "Validating settings in JASPERREPORTS_* environment variables..."
    local error_code=0

    # Auxiliary functions
    print_validation_error() {
        error "$1"
        error_code=1
    }
    check_empty_value() {
        if is_empty_value "${!1}"; then
            print_validation_error "${1} must be set"
        fi
    }
    check_yes_no_value() {
        if ! is_yes_no_value "${!1}" && ! is_true_false_value "${!1}"; then
            print_validation_error "The allowed values for ${1} are: yes no"
        fi
    }
    check_multi_value() {
        if [[ " ${2} " != *" ${!1} "* ]]; then
            print_validation_error "The allowed values for ${1} are: ${2}"
        fi
    }
    check_resolved_hostname() {
        if ! is_hostname_resolved "$1"; then
            warn "Hostname ${1} could not be resolved, this could lead to connection issues"
        fi
    }
    check_valid_port() {
        local port_var="${1:?missing port variable}"
        local err
        if ! err="$(validate_port "${!port_var}")"; then
            print_validation_error "An invalid port was specified in the environment variable ${port_var}: ${err}."
        fi
    }

    check_empty_value "JASPERREPORTS_HOST"
    check_yes_no_value "JASPERREPORTS_SKIP_BOOTSTRAP"
    ! is_empty_value "$JASPERREPORTS_DATABASE_HOST" && check_resolved_hostname "$JASPERREPORTS_DATABASE_HOST"
    ! is_empty_value "$JASPERREPORTS_DATABASE_PORT_NUMBER" && check_valid_port "JASPERREPORTS_DATABASE_PORT_NUMBER"

    # Validate credentials
    if is_boolean_yes "${ALLOW_EMPTY_PASSWORD:-}"; then
        warn "You set the environment variable ALLOW_EMPTY_PASSWORD=${ALLOW_EMPTY_PASSWORD:-}. For safety reasons, do not use this flag in a production environment."
    else
        for empty_env_var in "JASPERREPORTS_DATABASE_PASSWORD" "JASPERREPORTS_PASSWORD"; do
            is_empty_value "${!empty_env_var}" && print_validation_error "The ${empty_env_var} environment variable is empty or not set. Set the environment variable ALLOW_EMPTY_PASSWORD=yes to allow a blank password. This is only recommended for development environments."
        done
    fi

    # Validate SMTP credentials
    if ! is_empty_value "$JASPERREPORTS_SMTP_HOST"; then
        for empty_env_var in "JASPERREPORTS_SMTP_USER" "JASPERREPORTS_SMTP_PASSWORD"; do
            is_empty_value "${!empty_env_var}" && warn "The ${empty_env_var} environment variable is empty or not set."
        done
        is_empty_value "$JASPERREPORTS_SMTP_PORT_NUMBER" && print_validation_error "The JASPERREPORTS_SMTP_PORT_NUMBER environment variable is empty or not set."
        ! is_empty_value "$JASPERREPORTS_SMTP_PORT_NUMBER" && check_valid_port "JASPERREPORTS_SMTP_PORT_NUMBER"
        ! is_empty_value "$JASPERREPORTS_SMTP_PROTOCOL" && check_multi_value "JASPERREPORTS_SMTP_PROTOCOL" "ssl tls"
    fi

    return "$error_code"
}

########################
# Configure JasperReports database
# Globals:
#   JASPERREPORTS_*
# Arguments:
#   None
# Returns:
#   None
#########################
jasperreports_configure_db() {
    jasperreports_conf_set "dbPort" "$JASPERREPORTS_DATABASE_PORT_NUMBER"
    jasperreports_conf_set "dbHost" "$JASPERREPORTS_DATABASE_HOST"
    ! is_boolean_yes "$ALLOW_EMPTY_PASSWORD" && jasperreports_conf_set "dbPassword" "$JASPERREPORTS_DATABASE_PASSWORD"
    jasperreports_conf_set "dbUsername" "$JASPERREPORTS_DATABASE_USER"
    jasperreports_conf_set "js.dbName" "$JASPERREPORTS_DATABASE_NAME"
    # Extract MariaDB client version from the library jar. We do it at initialization time to avoid issues when updating
    local -r mariadb_client_jar="$(realpath "${JASPERREPORTS_CONF_DIR}/conf_source/db/mysql/jdbc"/mariadb-java-client-*)"
    local mariadb_client_version="${mariadb_client_jar##*-}"
    mariadb_client_version="${mariadb_client_version%.jar}"
    # Setting the admin database url (which will be the same as JASPERREPORTS_DATABASE_NAME), which is used by the installer
    # to perform several checks
    jasperreports_conf_set "admin.jdbcUrl" "jdbc:mysql://${JASPERREPORTS_DATABASE_HOST}:${JASPERREPORTS_DATABASE_PORT_NUMBER}/${JASPERREPORTS_DATABASE_NAME}" "${JASPERREPORTS_CONF_DIR}/conf_source/db/mysql/db.template.properties"
    jasperreports_conf_set "maven.jdbc.version" "${mariadb_client_version}"
}

########################
# Configure JasperReports SMTP
# Globals:
#   JASPERREPORTS_*
# Arguments:
#   None
# Returns:
#   None
#########################
jasperreports_configure_smtp() {
    info "Configuring SMTP"
    jasperreports_conf_set "quartz.mail.sender.host" "$JASPERREPORTS_SMTP_HOST"
    jasperreports_conf_set "quartz.mail.sender.port" "$JASPERREPORTS_SMTP_PORT_NUMBER"
    jasperreports_conf_set "quartz.mail.sender.protocol" "$JASPERREPORTS_SMTP_PROTOCOL"
    jasperreports_conf_set "quartz.mail.sender.username" "$JASPERREPORTS_SMTP_USER"
    jasperreports_conf_set "quartz.mail.sender.password" "$JASPERREPORTS_SMTP_PASSWORD"
    jasperreports_conf_set "quartz.mail.sender.from" "$JASPERREPORTS_SMTP_USER"
    # We only need to configure the URL when sending reports via email, so the user gets the proper URL for accessing the report
    # Source: https://community.jaspersoft.com/documentation/tibco-jasperreports-server-installation-guide/v720/configuring-report-scheduling
    jasperreports_conf_set "quartz.web.deployment.uri" "$JASPERREPORTS_HOST"
}

########################
# Configure JasperReports User
# Globals:
#   JASPERREPORTS_*
# Arguments:
#   None
# Returns:
#   None
#########################
jasperreports_configure_user() {
    info "Configuring users"
    # Change the default user username and mail using the database
    mysql_remote_execute "$JASPERREPORTS_DATABASE_HOST" "$JASPERREPORTS_DATABASE_PORT_NUMBER" "$JASPERREPORTS_DATABASE_NAME" "$JASPERREPORTS_DATABASE_USER" "$JASPERREPORTS_DATABASE_PASSWORD" <<<"UPDATE JIUser SET username='${JASPERREPORTS_USERNAME}' WHERE id=1"
    mysql_remote_execute "$JASPERREPORTS_DATABASE_HOST" "$JASPERREPORTS_DATABASE_PORT_NUMBER" "$JASPERREPORTS_DATABASE_NAME" "$JASPERREPORTS_DATABASE_USER" "$JASPERREPORTS_DATABASE_PASSWORD" <<<"UPDATE JIUser SET emailAddress='${JASPERREPORTS_EMAIL}' WHERE id=1"

    # Change the default user password using the export-import scripts
    # Based on https://community.jaspersoft.com/documentation/jasperreports-server-administration-guide/v550/import-and-export-through-command-line
    debug_execute "${JASPERREPORTS_CONF_DIR}/js-export.sh" --users "$JASPERREPORTS_USERNAME" --output-dir "${JASPERREPORTS_CONF_DIR}/JS"
    xmlstarlet ed -L -u '//password' -v "$JASPERREPORTS_PASSWORD" "${JASPERREPORTS_CONF_DIR}/JS/users/${JASPERREPORTS_USERNAME}.xml"
    debug_execute "${JASPERREPORTS_CONF_DIR}/js-import.sh" --input-dir "${JASPERREPORTS_CONF_DIR}/JS" --update

    # Delete created user folder
    rm -rf "${JASPERREPORTS_CONF_DIR}/JS"
}

########################
# Run JasperReports installation scripts
# Globals:
#   JASPERREPORTS_*
# Arguments:
#   None
# Returns:
#   None
#########################
jasperreports_run_install_scripts() {
    info "Executing installation scripts"

    # In order to allow empty passwords and permission issues with the ant scripts, we will use the manual database initialization steps detailed in
    # the official installation guide: https://community.jaspersoft.com/wiki/installation-steps-war-file-binary-distribution
    # Using source to avoid generating too much output
    mysql_remote_execute "$JASPERREPORTS_DATABASE_HOST" "$JASPERREPORTS_DATABASE_PORT_NUMBER" "$JASPERREPORTS_DATABASE_NAME" "$JASPERREPORTS_DATABASE_USER" "$JASPERREPORTS_DATABASE_PASSWORD" <<<"SOURCE ${JASPERREPORTS_CONF_DIR}/install_resources/sql/mysql/js-create.ddl"
    mysql_remote_execute "$JASPERREPORTS_DATABASE_HOST" "$JASPERREPORTS_DATABASE_PORT_NUMBER" "$JASPERREPORTS_DATABASE_NAME" "$JASPERREPORTS_DATABASE_USER" "$JASPERREPORTS_DATABASE_PASSWORD" <<<"SOURCE ${JASPERREPORTS_CONF_DIR}/install_resources/sql/mysql/quartz.ddl"

    # We need to move to the buildomatic folder to execute scripts
    cd "${JASPERREPORTS_CONF_DIR}" || exit

    # We set "y" to accept a warning on the keystore files
    if am_i_root; then
        echo "y" | debug_execute gosu "$JASPERREPORTS_DAEMON_USER" "${JASPERREPORTS_CONF_DIR}/js-ant" "import-minimal-ce"

    else
        echo "y" | debug_execute "${JASPERREPORTS_CONF_DIR}/js-ant" "import-minimal-ce"
    fi

    # We set "n" to avoid the installer to recreate the database
    if am_i_root; then
        # During the installation, it will copy one library file to the tomcat lib folder. We need to temporarily grant write permissions
        # for the installer to finish successfully. We restore the initial permissions after the operation
        chmod o+w "$BITNAMI_ROOT_DIR/tomcat/lib"
        echo "n" | debug_execute gosu "$JASPERREPORTS_DAEMON_USER" "${JASPERREPORTS_CONF_DIR}/js-install-ce.sh" "minimal"
        chmod o-w "$BITNAMI_ROOT_DIR/tomcat/lib"
    else
        echo "n" | debug_execute "${JASPERREPORTS_CONF_DIR}/js-install-ce.sh" "minimal"
    fi
}

########################
# Run JasperReports upgrade scripts
# Globals:
#   JASPERREPORTS_*
# Arguments:
#   None
# Returns:
#   None
#########################
jasperreports_run_upgrade_scripts() {
    info "Executing upgrade scripts"

    # We need to move to the buildomatic folder to execute scripts
    # Source: https://community.jaspersoft.com/documentation/tibco-jasperreports-server-community-project-upgrade-guide/v71/upgrading-64-71-0
    info "Running upgrade script"
    cd "${JASPERREPORTS_CONF_DIR}" || exit
    if am_i_root; then
        debug_execute gosu "$JASPERREPORTS_DAEMON_USER" "${JASPERREPORTS_CONF_DIR}/js-upgrade-samedb-ce.sh"

    else
        debug_execute "${JASPERREPORTS_CONF_DIR}/js-upgrade-samedb-ce.sh"
    fi
}

########################
# Ensure JasperReports is initialized
# Globals:
#   JASPERREPORTS_*
# Arguments:
#   None
# Returns:
#   None
#########################
jasperreports_initialize() {
    # Check if JasperReports has already been initialized and persisted in a previous run
    local -r app_name="jasperreports"

    if ! [[ -e "$BITNAMI_ROOT_DIR/tomcat/webapps/jasperserver" ]]; then
        ln -s "$JASPERREPORTS_BASE_DIR" "$BITNAMI_ROOT_DIR/tomcat/webapps/jasperserver"
    fi

    if ! is_app_initialized "$app_name"; then
        # Ensure JasperReports persisted directories exist (i.e. when a volume has been mounted to /bitnami)
        info "Ensuring JasperReports directories exist"
        ensure_dir_exists "$JASPERREPORTS_VOLUME_DIR"
        # Use daemon:root ownership for compatibility when running as a non-root user
        am_i_root && configure_permissions_ownership "$JASPERREPORTS_VOLUME_DIR" -d "775" -f "664" -u "$JASPERREPORTS_DAEMON_USER" -g "root"
        info "Trying to connect to the database server"
        jasperreports_wait_for_mysql_connection "$JASPERREPORTS_DATABASE_HOST" "$JASPERREPORTS_DATABASE_PORT_NUMBER" "$JASPERREPORTS_DATABASE_NAME" "$JASPERREPORTS_DATABASE_USER" "$JASPERREPORTS_DATABASE_PASSWORD"

        # Configure JasperReports based on environment variables
        info "Configuring JasperReports with settings provided via environment variables"
        jasperreports_configure_db

        if ! is_empty_value "$JASPERREPORTS_SMTP_HOST"; then
            jasperreports_configure_smtp
        fi

        if ! is_boolean_yes "$JASPERREPORTS_SKIP_BOOTSTRAP"; then
            jasperreports_run_install_scripts
            jasperreports_configure_user

            if ! is_empty_value "$JASPERREPORTS_SMTP_HOST"; then
                # Fix that needs to be done after the installation on SMTP
                # Source: https://github.com/bitnami/bitnami-docker-jasperreports/issues/49
                # We need to use * in the XPath expressions because it is a namespaced XML but the namespace is not properly detected
                # in regular XPath experssions with namespace
                # Set mail.smtp.auth to true
                xmlstarlet ed -L -u '//*[name()="prop" and @key="mail.smtp.auth"]' -v "true" "${JASPERREPORTS_BASE_DIR}/WEB-INF/applicationContext-report-scheduling.xml"
                # Add a new prop node with mail.smtp.startls.enable=true
                xmlstarlet ed -L --subnode '//*[name()="property" and @name="javaMailProperties"]/*[name()="props"]' --type elem -n "prop" -v "true" "${JASPERREPORTS_BASE_DIR}/WEB-INF/applicationContext-report-scheduling.xml"
                xmlstarlet ed -L -i '//*[name()="prop" and not(@key)]' --type "attr" -n "key" -v "mail.smtp.starttls.enable" "${JASPERREPORTS_BASE_DIR}/WEB-INF/applicationContext-report-scheduling.xml"
            fi

        else
            info "An already initialized JasperReports database was provided, configuration will be skipped"
            jasperreports_run_upgrade_scripts
        fi

        info "Persisting JasperReports installation"
        persist_app "$app_name" "$JASPERREPORTS_DATA_TO_PERSIST"
    else
        info "Restoring persisted JasperReports installation"
        restore_persisted_app "$app_name" "$JASPERREPORTS_DATA_TO_PERSIST"
        info "Trying to connect to the database server"
        local db_host db_port db_name db_user db_pass
        db_host="$(jasperreports_conf_get "dbHost")"
        db_port="$(jasperreports_conf_get "dbPort")"
        db_name="$(jasperreports_conf_get "js.dbName")"
        db_user="$(jasperreports_conf_get "dbUsername")"
        # Adding true as the password may not be set
        db_pass="$(jasperreports_conf_get "dbPassword" || true)"
        jasperreports_wait_for_mysql_connection "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass"
        jasperreports_run_upgrade_scripts
    fi

    # Disable JNDI
    # Source: https://github.com/bitnami/bitnami-docker-jasperreports/pull/46
    echo "tbeller.usejndi=false" >>"${JASPERREPORTS_BASE_DIR}/WEB-INF/classes/resfactory.properties"

    # Add log file and fix permissions of the files created after the installation
    ensure_dir_exists "$JASPERREPORTS_LOGS_DIR"
    touch "$JASPERREPORTS_LOG_FILE"
    if am_i_root; then
        configure_permissions_ownership "$JASPERREPORTS_LOGS_DIR" -u "$JASPERREPORTS_DAEMON_USER" -g "$JASPERREPORTS_DAEMON_GROUP" -f "664"
        configure_permissions_ownership "$JASPERREPORTS_BASE_DIR/.jrsks" -u "$JASPERREPORTS_DAEMON_USER" -g "$JASPERREPORTS_DAEMON_GROUP" -f "664"
        configure_permissions_ownership "$JASPERREPORTS_BASE_DIR/.jrsksp" -u "$JASPERREPORTS_DAEMON_USER" -g "$JASPERREPORTS_DAEMON_GROUP" -f "664"
    fi

    # Make Tomcat redirect to /jasperserver
    replace_in_file "$BITNAMI_ROOT_DIR/tomcat/webapps/ROOT/index.jsp" '<%\s*$' '<%\nresponse.sendRedirect("/jasperserver");'

    # Avoid exit code of previous commands to affect the result of this function
    true
}

########################
# Add or modify an entry in the JasperReports configuration file
# Globals:
#   JASPERREPORTS_*
# Arguments:
#   $1 - Variable name
#   $2 - Value to assign to the variable
#   $3 - Whether the value is a literal, or if instead it should be quoted (default: no)
# Returns:
#   None
#########################
jasperreports_conf_set() {
    local -r key="${1:?key missing}"
    local -r value="${2:-}"
    local -r file="${3:-"$JASPERREPORTS_CONF_FILE"}"
    debug "Setting ${key} to '${value}' in JasperReports configuration file ${file}"
    # Sanitize key (sed does not support fixed string substitutions)
    local sanitized_pattern
    sanitized_pattern="^[#]?\s*(//\s*)?$(sed 's/[]\[^$.*/]/\\&/g' <<<"$key")\s*=.*"
    local -r entry="${key}=${value}"
    # Check if the configuration exists in the file
    if grep -q -E "$sanitized_pattern" "$file"; then
        # It exists, so replace the line
        replace_in_file "$file" "$sanitized_pattern" "$entry"
    else
        # The JasperReports configuration file includes all supported keys, but because of its format,
        # we cannot append contents to the end. We can assume this should never happen.
        warn "Could not set the JasperReports '${key}' configuration. Check that the file has not been modified externally."
    fi
}

########################
# Get an entry from the JasperReports configuration file
# Globals:
#   JASPERREPORTS_*
# Arguments:
#   $1 - Variable name
# Returns:
#   None
#########################
jasperreports_conf_get() {
    local -r key="${1:?key missing}"
    debug "Getting ${key} from JasperReports configuration"
    # Sanitize key (sed does not support fixed string substitutions)
    local sanitized_pattern
    sanitized_pattern="^\s*(//\s*)?$(sed 's/[]\[^$.*/]/\\&/g' <<<"$key")\s*=(.*)"
    grep -E "$sanitized_pattern" "$JASPERREPORTS_CONF_FILE" | sed -E "s|${sanitized_pattern}|\2|" | tr -d "\"' "
}

########################
# Wait until the database is accessible with the currently-known credentials
# Globals:
#   *
# Arguments:
#   $1 - database host
#   $2 - database port
#   $3 - database name
#   $4 - database username
#   $5 - database user password (optional)
# Returns:
#   true if the database connection succeeded, false otherwise
#########################
jasperreports_wait_for_mysql_connection() {
    local -r db_host="${1:?missing database host}"
    local -r db_port="${2:?missing database port}"
    local -r db_name="${3:?missing database name}"
    local -r db_user="${4:?missing database user}"
    local -r db_pass="${5:-}"
    check_mysql_connection() {
        echo "SELECT 1" | mysql_remote_execute "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass"
    }
    if ! retry_while "check_mysql_connection"; then
        error "Could not connect to the database"
        return 1
    fi
}
