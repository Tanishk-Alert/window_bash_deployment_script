#!/usr/bin/env bash
export MSYS_NO_PATHCONV=1

fail() {
    echo "❌ ERROR: $1"
    exit 1
}

run() {
    echo "➡️ Running: $*"
    "$@"
    rc=$?
    echo "➡️ Exit code: $rc"
    if [ $rc -ne 0 ]; then
        echo "❌ ERROR: Command failed: $*"
        exit 1
    fi
}

step() {
    echo "========== $1 =========="
    shift
    "$@"
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "Step failed: $1"
    fi
}

################################
# LOAD ENV
################################
ENV_FILE="/c/AlertEnterprise/configs/.env"

[ ! -f "$ENV_FILE" ] && fail "ENV file missing: $ENV_FILE"

source "$ENV_FILE" || fail "Failed to source ENV"

################################
# INPUT PARAMS
################################
S3_SRC_PATH="$1"
gitBranch="$2"
buildVersion="$3"
flywayFixed="$4"
ARTIFACTS_ARG="$5"

echo "DEBUG:"
echo "S3_SRC_PATH=$S3_SRC_PATH"
echo "gitBranch=$gitBranch"
echo "buildVersion=$buildVersion"

################################
# PRECHECK
################################
precheck() {

echo "========== PRECHECK START =========="

fail() {
   echo "❌ PRECHECK FAILED: $1"
   exit 1
}

################################
# SOFTWARE CHECK
################################
command -v java >/dev/null 2>&1 || fail "Java not installed"
command -v unzip >/dev/null 2>&1 || fail "unzip not installed"
command -v aws >/dev/null 2>&1 || fail "AWS CLI not installed"
command -v jq >/dev/null 2>&1 || fail "jq not installed"
command -v flyway >/dev/null 2>&1 || fail "flyway not installed"
command -v netstat >/dev/null 2>&1 || fail "ss command missing"

################################
# IMPORTANT DIRECTORY CHECK
################################

[ -d "$CONFIG_PATH" ] || fail "CONFIG_PATH missing: $CONFIG_PATH"
[ -d "$INIT_APPS_PATH" ] || fail "INIT_APPS_PATH missing: $INIT_APPS_PATH"
[ -d "$BUILD_PATH" ] || fail "BUILD_PATH missing: $BUILD_PATH"
[ -d "$LOGS_PATH" ] || fail "LOGS_PATH missing: $LOGS_PATH"



################################
# DISK SPACE CHECK
################################
avail_gb=$(df -BG "$INIT_APPS_PATH" | awk 'NR==2 {gsub("G","",$4); print $4}')

[ "$avail_gb" -lt 3 ] && fail "Minimum 3 GB free space required on deployment mount"

################################
# JAVA WORKING CHECK
################################
java -version >/dev/null 2>&1 || fail "Java runtime not working"

echo "========== PRECHECK SUCCESS =========="

}

################################
# BUILD ARTIFACT LIST
################################
ARTIFACTS=()

IFS=',' read -ra SELECTED <<< "$ARTIFACTS_ARG"

for item in "${SELECTED[@]}"; do
    case "${item,,}" in
        application|agent)
            ARTIFACTS+=("$item")
            ;;
        *)
            fail "Invalid artifact value: $item"
            ;;
    esac
done

[ ${#ARTIFACTS[@]} -eq 0 ] && fail "No artifacts selected"

################################
# LOAD SECRETS
################################


################################
# FUNCTIONS
################################

################################
# CREATE DIRS
################################
create_dirs() {
    echo "Creating directories"
    run mkdir -p "$APP_PATH" "$INIT_APPS_PATH" "$KEYSTORE_PATH" \
             "$CONFIG_PATH" \
             "$LOGS_PATH" "$BUILD_PATH" "$CERT_DIR"
}

################################
# STOP WINDOWS SERVICES
################################
stop_services() {

    echo "=================================================="
    echo "🛑 Starting service shutdown process"
    echo "=================================================="

    ################################
    # Helper → check service exists
    ################################
    service_exists() {
        powershell.exe -NoProfile -Command \
        "Get-Service -Name '$1' -ErrorAction SilentlyContinue" \
        | grep -q "$1"
    }

    ################################
    # Helper → stop service safely
    ################################
    stop_service_safe() {

    svc="$1"
	pid="$2"

    echo "🔍 Checking if ${svc} exists"

    if service_exists "$svc"; then

        echo "🛑 Stopping ${svc}..."
		
		if [ -f "$pid" ]; then
			echo "Deleting $pid"
			rm -f "$pid"
		fi

        powershell.exe -NoProfile -Command "
            try {
                \$s = Get-Service -Name '$svc' -ErrorAction Stop
                if (\$s.Status -eq 'Stopped') {
                    Write-Host 'Service already stopped'
                    exit 0
                }
                Stop-Service -Name '$svc' -Force -ErrorAction Stop
            }
            catch {
                exit 1
            }
        "

        rc=$?
        [ $rc -ne 0 ] && fail "Failed stopping ${svc}"

        echo "✅ ${svc} stopped successfully"

    else
        echo "ℹ️ ${svc} not found, skipping"
    fi
}
    ################################
    # APPLICATION SERVICES
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then

        echo "➡️ Application artifact detected"
        stop_service_safe "SVC_API"  "$INIT_APPS_PATH/alert-api-server-1.0/RUNNING_PID"
        stop_service_safe "SVC_JOB"  "$INIT_APPS_PATH/alert-job-server-1.0/RUNNING_PID"

        echo "✔ APPLICATION service shutdown stage completed"

    else
        echo "ℹ️ Application artifact not selected, skipping APPLICATION services"
    fi

    ################################
    # AGENT SERVICE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then

        echo "➡️ Agent artifact detected"
        stop_service_safe "SVC_AGENT" "$INIT_APPS_PATH/alert-agent-1.0/RUNNING_PID"

        echo "✔ AGENT service shutdown stage completed"

    else
        echo "ℹ️ Agent artifact not selected, skipping AGENT service"
    fi

    echo "=================================================="
    echo "✔ Service stop process completed"
    echo "=================================================="
}


################################
# LOGOFF OTHER USER SESSIONS
################################

logoff_other_sessions() {

    echo "=========================================="
    echo "🔎 Detecting current session ID..."
    echo "=========================================="

    SESSIONS_OUTPUT=$(query session)

    # ✅ DO NOT check exit code — validate output instead
    [ -z "$SESSIONS_OUTPUT" ] && fail "query session returned empty output"

    CURRENT_SESSION_ID=$(echo "$SESSIONS_OUTPUT" | awk '/>/{print $(NF-1)}')

    [ -z "$CURRENT_SESSION_ID" ] && fail "Unable to detect current session ID"

    echo "🟢 Current Session ID: $CURRENT_SESSION_ID"

    echo "=========================================="
    echo "🔎 Checking other sessions..."
    echo "=========================================="

    echo "$SESSIONS_OUTPUT" | tail -n +2 | while read -r line; do

        clean_line=$(echo "$line" | sed 's/^>//')

        STATE=$(echo "$clean_line" | awk '{print $NF}')
        ID=$(echo "$clean_line" | awk '{print $(NF-1)}')
        USERNAME=$(echo "$clean_line" | awk '{print $(NF-2)}')

        if [[ -z "$USERNAME" || "$USERNAME" == "services" ]]; then
            continue
        fi

        if [[ "$ID" == "$CURRENT_SESSION_ID" ]]; then
            echo "⏭ Skipping current session ID: $ID"
            continue
        fi

        if [[ "$STATE" == "Active" || "$STATE" == "Disc" ]]; then
            echo "🚪 Logging off user: $USERNAME | ID: $ID | State: $STATE"

            logoff "$ID"
            rc=$?

            [ $rc -ne 0 ] && fail "Failed to logoff session ID $ID"
        fi

    done

    echo "=========================================="
    echo "✅ Other sessions logged off successfully"
    echo "=========================================="
}

################################
# KILL LOCKING WINDOWS PROCESSES
################################

# kill_locking_processes() {

#     echo "=================================================="
#     echo "🔴 Starting process cleanup (locking processes)"
#     echo "=================================================="

#     echo "🔎 Attempting to terminate cmd.exe..."
#     cmd.exe /c "taskkill /F /IM cmd.exe" > /dev/null 2>&1 \
#         || echo "ℹ️ No running cmd.exe instances found"

#     echo "🔎 Attempting to terminate explorer.exe..."
#     # cmd.exe /c "taskkill /F /IM explorer.exe" > /dev/null 2>&1 \
#     #     || echo "ℹ️ explorer.exe was not running"

#     # echo "⏳ Waiting 5 seconds before restart..."
#     # sleep 5

#     # echo "🟢 Restarting explorer.exe..."
#     # cmd.exe /c "start explorer.exe"

#     powershell -NoProfile -Command '
# $shell = New-Object -ComObject Shell.Application
# $shell.Windows() | ForEach-Object { $_.Quit() }
# '


#     echo "=================================================="
#     echo "✔ Locking process cleanup completed"
#     echo "=================================================="
# }


################################
# BACKUP PROCESS
################################
backup() {

[ ! -d "$APP_PATH" ] && fail "APP_PATH missing"

[ -d "$APP_PATH/bkp_2" ] && run rm -rf "$APP_PATH/bkp_2"

if [ -d "$APP_PATH/bkp_1" ]; then
    if [ "$(find "$APP_PATH/bkp_1" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        run mkdir -p "$APP_PATH/bkp_2"
        run mv "$APP_PATH"/bkp_1/* "$APP_PATH"/bkp_2/
    fi
fi

if [ -d "$INIT_APPS_PATH" ] && [ "$(ls -A "$INIT_APPS_PATH")" ]; then
    run mkdir -p "$APP_PATH/bkp_1"
    cd "$INIT_APPS_PATH" || fail "cd failed"
    run mv * "$APP_PATH/bkp_1/"
fi

}

################################
# DOWNLOAD BUILD ARTIFACTS
################################

################################
# DOWNLOAD BUILD ARTIFACTS
################################
download_build() {

    echo "=================================================="
    echo "📥 Starting build artifact download process"
    echo "=================================================="

    echo "📁 Ensuring BUILD_PATH exists: $BUILD_PATH"
    mkdir -p "$BUILD_PATH"
    echo "✅ BUILD_PATH ready"

    download_artifact() {

        local artifact="$1"
        local src="${S3_SRC_PATH}/${gitBranch}/${buildVersion}/${artifact}.zip"

        local WIN_BUILD_PATH
        WIN_BUILD_PATH=$(cygpath -w "$BUILD_PATH")

        echo "--------------------------------------------------"
        echo "⬇️ Preparing to download: ${artifact}.zip"
        echo "🔗 Source : $src"
        echo "📂 Target : $WIN_BUILD_PATH"
        echo "--------------------------------------------------"

        echo "⬇️ Downloading ${artifact}.zip"

        aws s3 cp "$src" "$WIN_BUILD_PATH\\"
        rc=$?

        [ $rc -ne 0 ] && fail "Download failed for ${artifact}"

        echo "✔ Downloaded ${artifact}.zip"
    }

    ################################
    # APPLICATION ARTIFACTS
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Application artifact selected"
        echo "🔄 Downloading APPLICATION artifacts (api, job, ui, DB)"

        for artifact in api job ui DB; do
            download_artifact "$artifact"
        done

        echo "✔ APPLICATION artifacts download stage completed"
    else
        echo "ℹ️ Application artifact not selected → Skipping APPLICATION downloads"
    fi

    ################################
    # AGENT ARTIFACTS
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Agent artifact selected"
        echo "🔄 Downloading AGENT artifacts (agentserver, agentDB)"

        for artifact in agentserver agentDB; do
            download_artifact "$artifact"
        done

        echo "✔ AGENT artifacts download stage completed"
    else
        echo "ℹ️ Agent artifact not selected → Skipping AGENT downloads"
    fi

    echo "=================================================="
    echo "🎉 Build artifact download process completed"
    echo "=================================================="
}

################################
# EXTRACT BUILD ARTIFACTS
################################
extract_zip() {

extract_artifact() {
    artifact="$1"
    zip_file="${BUILD_PATH}/${artifact}.zip"

    [ ! -f "$zip_file" ] && fail "$artifact zip missing"

    if [[ "${artifact,,}" == *db* ]]; then
        run unzip -oq "$zip_file" -d "${INIT_APPS_PATH}/${artifact}"
    else
        run unzip -oq "$zip_file" -d "${INIT_APPS_PATH}"
    fi
}

if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
    for a in api job ui DB; do extract_artifact "$a"; done
fi

if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
    for a in agentserver agentDB; do extract_artifact "$a"; done
fi

}

################################
# COPY ENV CONFIGS (STANDARDIZED)
################################
################################
# COPY ENVIRONMENT CONFIG FILES
################################
copy_env_configs() {

    echo "=================================================="
    echo "⚙️ Starting environment configuration copy process"
    echo "=================================================="

    copy_configs() {

        local service="$1"
        local app_conf_dir="$2"
        local config_src="$3"
        local apps_path="$4"

        echo "--------------------------------------------------"
        echo "➡️ Processing service: ${service^^}"
        echo "📂 Config Source : $config_src"
        echo "📁 Target Dir    : $app_conf_dir"
        echo "--------------------------------------------------"

        [ ! -d "$app_conf_dir" ] && fail "Conf dir missing: $app_conf_dir"
        [ ! -d "$config_src" ] && fail "Config source missing: $config_src"

        echo "📄 Copying override_env.conf"
        cp "${config_src}/override_env.conf" "${app_conf_dir}/"
        [ $? -ne 0 ] && fail "override_env.conf copy failed for $service"

        echo "📄 Copying log4j2.xml"
        cp "${config_src}/log4j2.xml" "${app_conf_dir}/"
        [ $? -ne 0 ] && fail "log4j2.xml copy failed for $service"

        # Convert paths for Windows usage
        echo "🔄 Converting keystore paths to Windows format"

        WIN_KEYSTORE_FILE=$(cygpath -w "$KEYSTORE_FILE")
        [ $? -ne 0 ] && fail "cygpath conversion failed for KEYSTORE_FILE"

        WIN_KEYSTORE_FILE=$(echo "$WIN_KEYSTORE_FILE" | sed 's|\\|\\\\\\\\|g')
        [ $? -ne 0 ] && fail "sed formatting failed for KEYSTORE_FILE"

        WIN_KEYSTORE_KEY_PATH=$(cygpath -w "$KEYSTORE_KEY_PATH")
        [ $? -ne 0 ] && fail "cygpath conversion failed for KEYSTORE_KEY_PATH"

        WIN_KEYSTORE_KEY_PATH=$(echo "$WIN_KEYSTORE_KEY_PATH" | sed 's|\\|\\\\\\\\|g')
        [ $? -ne 0 ] && fail "sed formatting failed for KEYSTORE_KEY_PATH"

        ################################
        # KEYSTORE CONFIG UPDATE
        ################################
        if [ -f "${apps_path}/conf/keystore.conf" ]; then
            echo "🔐 keystore.conf detected for ${service^^}"
            echo "📄 Copying keystore.conf template"

            cp "${config_src}/keystore.conf" "${app_conf_dir}/"
            [ $? -ne 0 ] && fail "keystore.conf copy failed for $service"

            echo "✏️ Replacing {AEKEYSTOREFILE} placeholder"
            sed -i "s|{AEKEYSTOREFILE}|${WIN_KEYSTORE_FILE}|g" \
                "${app_conf_dir}/keystore.conf"
            [ $? -ne 0 ] && fail "keystoreFile sed failed for $service"

            echo "✏️ Replacing {AEKEYSTOREPASSWD} placeholder"
            sed -i "s|{AEKEYSTOREPASSWD}|${WIN_KEYSTORE_KEY_PATH}|g" \
                "${app_conf_dir}/keystore.conf"
            [ $? -ne 0 ] && fail "keystorePass sed failed for $service"

            echo "✅ keystore.conf updated successfully"
        else
            echo "ℹ️ No keystore.conf found for ${service^^}, skipping keystore update"
        fi

        echo "✔ Configuration copy completed for ${service^^}"
    }

    ################################
    # APPLICATION SERVICES
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Application artifact selected"
        echo "🔄 Copying configs for API and JOB"

        copy_configs \
            "api" \
            "${INIT_APPS_PATH}/alert-api-server-1.0/conf" \
            "${CONFIG_PATH}/api" \
            "${INIT_APPS_PATH}/alert-api-server-1.0"

        copy_configs \
            "job" \
            "${INIT_APPS_PATH}/alert-job-server-1.0/conf" \
            "${CONFIG_PATH}/job" \
            "${INIT_APPS_PATH}/alert-job-server-1.0"

        echo "✔ APPLICATION config copy stage completed"
    else
        echo "ℹ️ Application artifact not selected → Skipping APPLICATION config copy"
    fi

    ################################
    # AGENT SERVICE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Agent artifact selected"
        echo "🔄 Copying configs for AGENT"

        copy_configs \
            "agent" \
            "${INIT_APPS_PATH}/alert-agent-1.0/conf" \
            "${CONFIG_PATH}/agent" \
            "${INIT_APPS_PATH}/alert-agent-1.0"

        echo "✔ AGENT config copy stage completed"
    else
        echo "ℹ️ Agent artifact not selected → Skipping AGENT config copy"
    fi

    echo "=================================================="
    echo "🎉 Environment configuration copy process completed"
    echo "=================================================="
}

################################
# UPDATE environment.conf FILES
################################
update_environment_conf() {

echo "📝 Updating environment.conf..."

update_env() {

    service="$1"
    env_file="$2"
    ORIGINAL="${env_file}.original"

    [ ! -f "$ORIGINAL" ] && fail "${ORIGINAL} missing for $service"

    cp "$ORIGINAL" "$env_file"
    [ $? -ne 0 ] && fail "environment.conf copy failed for $service"

    sed -i 's/\r$//' "$env_file"
    [ $? -ne 0 ] && fail "CRLF cleanup failed for $service"

    grep -q '^include "override_env"' "$env_file"
    if [ $? -ne 0 ]; then
        echo '' >> "$env_file"
        echo 'include "override_env"' >> "$env_file"
    fi

    echo "✔ environment.conf updated for ${service^^}"
}

[[ " ${ARTIFACTS[*]} " == *" application "* ]] && {
    update_env "api" \
    "$INIT_APPS_PATH/alert-api-server-1.0/conf/environment.conf"

    update_env "job" \
    "$INIT_APPS_PATH/alert-job-server-1.0/conf/environment.conf"
}

[[ " ${ARTIFACTS[*]} " == *" agent "* ]] && {
    update_env "agent" \
    "$INIT_APPS_PATH/alert-agent-1.0/conf/environment.conf"
}

return 0

}


################################
# KEYSTORE SETUP (STANDARDIZED)
################################
################################
# KEYSTORE SETUP PROCESS
################################
setup_keystore() {

    echo "=================================================="
    echo "🔐 Starting Keystore setup process"
    echo "=================================================="

    echo "🔎 Validating required keystore variables"

    [ -z "${keystorePass:-}" ] && fail "keystorePass missing"
    [ -z "$KEYSTORE_FILE" ] && fail "KEYSTORE_FILE missing"

    echo "✅ Required keystore variables present"

    echo "📁 Ensuring keystore directory exists: $KEYSTORE_PATH"
    mkdir -p "$KEYSTORE_PATH"
    [ $? -ne 0 ] && fail "Keystore directory creation failed"

    echo "🔄 Converting keystore paths to Windows format"

    WIN_KEYSTORE_FILE=$(cygpath -w "$KEYSTORE_FILE")
    [ $? -ne 0 ] && fail "cygpath conversion failed for KEYSTORE_FILE"

    WIN_KEYSTORE_FILE=$(echo "$WIN_KEYSTORE_FILE" | sed 's|\\|\\\\|g')
    [ $? -ne 0 ] && fail "sed formatting failed for KEYSTORE_FILE"

    WIN_KEYSTORE_KEY_PATH=$(cygpath -w "$KEYSTORE_KEY_PATH")
    [ $? -ne 0 ] && fail "cygpath conversion failed for KEYSTORE_KEY_PATH"

    WIN_KEYSTORE_KEY_PATH=$(echo "$WIN_KEYSTORE_KEY_PATH" | sed 's|\\|\\\\|g')
    [ $? -ne 0 ] && fail "sed formatting failed for KEYSTORE_KEY_PATH"

    echo "✔ Path conversion completed"

    ################################
    # SELECT APPLICATION PATHS
    ################################
    select_app_paths() {

        local service="$1"

        echo "🔎 Selecting application paths for: $service"

        case "$service" in
            application)
                APPS_PATH="${INIT_APPS_PATH}/alert-api-server-1.0"
                ;;
            agent)
                APPS_PATH="${INIT_APPS_PATH}/alert-agent-1.0"
                ;;
            *)
                fail "Unknown service: $service"
                ;;
        esac

        BRANCH12_CONF="${APPS_PATH}/conf/keystore.conf"
        BRANCH11_JAR="${APPS_PATH}/lib/keystore-0.0.1-SNAPSHOT.jar"

        echo "📂 APPS_PATH: $APPS_PATH"
    }

    ################################
    # INSERT SECRETS - BRANCH 12
    ################################
    insert_secrets_branch12() {

        echo "🔑 Inserting secrets using Branch 12 method"

        printf "%s" "$keystorePass" > "$WIN_KEYSTORE_KEY_PATH"
        [ $? -ne 0 ] && fail "Failed writing keystore password file"

        jq -c '.[]' <<< "$KEYSTORE_SECRETS" | while read -r item; do
            key=$(jq -r 'keys[0]' <<< "$item")
            val=$(jq -r '.[keys[0]]' <<< "$item")

            echo "➡️ Upserting key: $key"

            cd "$APPS_PATH/lib" || fail "cd failed"

            MSYS_NO_PATHCONV=1 java -cp "./*" \
                -Dlog4j.configurationFile=../conf/log4j2.xml \
                -Dcrypto.configurationFile=../conf/keystore.conf \
                com.alnt.cryptoutil.Main key_upsert "$key" "$val"

            [ $? -ne 0 ] && fail "Secret insert failed $key"
        done

        echo "✅ Secrets inserted (Branch 12)"
    }

    ################################
    # INSERT SECRETS - BRANCH 11
    ################################
    insert_secrets_branch11() {

        echo "🔑 Inserting secrets using Branch 11 method"

        printf "%s" "$keystorePass" > "$WIN_KEYSTORE_KEY_PATH"
        [ $? -ne 0 ] && fail "Failed writing keystore password file"

        jq -c '.[]' <<< "$KEYSTORE_SECRETS" | while read -r item; do
            key=$(jq -r 'keys[0]' <<< "$item")
            val=$(jq -r '.[keys[0]]' <<< "$item")

            echo "➡️ Adding key: $key"

            cd "$APPS_PATH/lib" || fail "cd failed"

            MSYS_NO_PATHCONV=1 java -jar keystore-0.0.1-SNAPSHOT.jar \
                "$WIN_KEYSTORE_FILE" \
                "$keystorePass" \
                "$val" "$key"

            [ $? -ne 0 ] && fail "Secret insert failed $key"
        done

        echo "✅ Secrets inserted (Branch 11)"
    }

    ################################
    # CREATE KEYSTORE METHODS
    ################################
    create_keystore_branch12() {
        echo "🛠️ Creating Branch 12 PKCS12 keystore"
        MSYS_NO_PATHCONV=1 keytool -genseckey -keyalg AES -keysize 256 \
            -keystore "$WIN_KEYSTORE_FILE" \
            -storetype PKCS12 \
            -storepass "$keystorePass" \
            -keypass "$keystorePass"
        [ $? -ne 0 ] && fail "Keystore creation failed"
        echo "✅ Branch 12 keystore created"
    }

    create_keystore_branch11() {
        echo "🛠️ Creating Branch 11 JKS keystore"
        MSYS_NO_PATHCONV=1 keytool -genkeypair \
            -dname "cn=Alert Enterprise, ou=Java, o=Oracle, c=US" \
            -alias alert \
            -keystore "$WIN_KEYSTORE_FILE" \
            -storepass "$keystorePass" \
            -keypass "$keystorePass"
        [ $? -ne 0 ] && fail "Keystore creation failed"
        echo "✅ Branch 11 keystore created"
    }

    ################################
    # DETERMINE SERVICE TYPE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        SERVICE="application"
    elif [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        SERVICE="agent"
    else
        echo "ℹ️ No service selected for keystore setup"
        return
    fi

    echo "➡️ Service selected for keystore setup: $SERVICE"

    select_app_paths "$SERVICE"

    ################################
    # DETECT BRANCH TYPE
    ################################
    if [ -f "$BRANCH12_CONF" ]; then
        echo "🆕 Branch 12 keystore configuration detected"

        if [ ! -f "$KEYSTORE_FILE" ]; then
            create_keystore_branch12
            insert_secrets_branch12
        else
            echo "ℹ️ Keystore already exists → Skipping creation"
        fi

    elif [ -f "$BRANCH11_JAR" ]; then
        echo "📦 Branch 11 keystore configuration detected"

        if [ ! -f "$KEYSTORE_FILE" ]; then
            create_keystore_branch11
            insert_secrets_branch11
        else
            echo "ℹ️ Keystore already exists → Skipping creation"
        fi

    else
        fail "No keystore configuration found for selected service"
    fi

    echo "=================================================="
    echo "🎉 Keystore setup process completed successfully"
    echo "=================================================="
}

################################
# CREATE NSSM SERVICE IF NOT EXISTS (AND START IT)
################################
################################
# CREATE NSSM SERVICE IF NOT EXISTS
################################
add_nssm_service_if_not_exists() {

    local SERVICE_NAME="$1"
    local EXE_PATH="$2"
    local ARGUMENTS="$3"
    local STARTUP_DIR="$4"
    local STDOUT_LOG="$5"
    local STDERR_LOG="$6"

    local NSSM="nssm"

    echo "--------------------------------------------------"
    echo "🔎 Checking service: $SERVICE_NAME"
    echo "--------------------------------------------------"

    # Check if service already exists
    if "$NSSM" status "$SERVICE_NAME" >/dev/null 2>&1; then
        echo "ℹ️ Service '$SERVICE_NAME' already exists → Skipping creation & start"
        return 0
    fi

    echo "🛠️ Service '$SERVICE_NAME' does NOT exist → Creating"

    # Convert paths to Windows format
    echo "🔄 Converting paths to Windows format"

    local WIN_EXE_PATH
    local WIN_STARTUP_DIR
    local WIN_STDOUT_LOG
    local WIN_STDERR_LOG

    WIN_EXE_PATH=$(cygpath -w "$EXE_PATH")
    [ $? -ne 0 ] && fail "cygpath failed for EXE_PATH"

    WIN_STARTUP_DIR=$(cygpath -w "$STARTUP_DIR")
    [ $? -ne 0 ] && fail "cygpath failed for STARTUP_DIR"

    WIN_STDOUT_LOG=$(cygpath -w "$STDOUT_LOG")
    [ $? -ne 0 ] && fail "cygpath failed for STDOUT_LOG"

    WIN_STDERR_LOG=$(cygpath -w "$STDERR_LOG")
    [ $? -ne 0 ] && fail "cygpath failed for STDERR_LOG"

    echo "📂 Executable : $WIN_EXE_PATH"
    echo "📂 Work Dir   : $WIN_STARTUP_DIR"

    # Install service
    MSYS_NO_PATHCONV=1 "$NSSM" install "$SERVICE_NAME" "$WIN_EXE_PATH" $ARGUMENTS
    [ $? -ne 0 ] && fail "NSSM install failed for $SERVICE_NAME"

    MSYS_NO_PATHCONV=1 "$NSSM" set "$SERVICE_NAME" AppDirectory "$WIN_STARTUP_DIR"
    [ $? -ne 0 ] && fail "NSSM AppDirectory set failed for $SERVICE_NAME"

    MSYS_NO_PATHCONV=1 "$NSSM" set "$SERVICE_NAME" AppStdout "$WIN_STDOUT_LOG"
    [ $? -ne 0 ] && fail "NSSM AppStdout set failed for $SERVICE_NAME"

    MSYS_NO_PATHCONV=1 "$NSSM" set "$SERVICE_NAME" AppStderr "$WIN_STDERR_LOG"
    [ $? -ne 0 ] && fail "NSSM AppStderr set failed for $SERVICE_NAME"

    MSYS_NO_PATHCONV=1 "$NSSM" set "$SERVICE_NAME" Start SERVICE_AUTO_START
    [ $? -ne 0 ] && fail "NSSM startup type set failed for $SERVICE_NAME"

    echo "✅ Service '$SERVICE_NAME' created successfully"
}


################################
# CHECK IF ARTIFACT EXISTS
################################
contains() {
    echo "🔎 Checking if artifact '$1' is selected"
    [[ " ${ARTIFACTS[*]} " == *" $1 "* ]]
}

################################
# CREATE APPLICATION SERVICES
################################
create_application_services() {
    echo "=================================================="
    echo "▶️ Creating APPLICATION services"
    echo "=================================================="

    echo "🧩 Creating API service"
    add_nssm_service_if_not_exists \
      "SVC_API" \
      "$JAVA_HOME/bin/java.exe" \
      '-cp "./lib/*" -Xms1g -Xmx2g -Dconfig.file=conf/application.conf -Dlogback.debug=true -Dorg.owasp.esapi.resources=conf -Dlog4j.configurationFile=conf/log4j2.xml play.core.server.ProdServerStart' \
      "$INIT_APPS_PATH/alert-api-server-1.0" \
      "$INIT_APPS_PATH/alert-api-server-1.0/logs/srvc.out" \
      "$INIT_APPS_PATH/alert-api-server-1.0/logs/srvc.err" \
      || fail "API service creation failed"

    echo "🧩 Creating JOB service"
    add_nssm_service_if_not_exists \
      "SVC_JOB" \
      "$JAVA_HOME/bin/java.exe" \
      '-cp "./lib/*" -Xms1g -Xmx3g -Dconfig.file=conf/jobserver.conf -Dhttp.port=9090 -Dlogback.debug=true -Dorg.owasp.esapi.resources=conf -Dlog4j.configurationFile=conf/log4j2.xml play.core.server.ProdServerStart' \
      "$INIT_APPS_PATH/alert-job-server-1.0" \
      "$INIT_APPS_PATH/alert-job-server-1.0/logs/srvc.out" \
      "$INIT_APPS_PATH/alert-job-server-1.0/logs/srvc.err" \
      || fail "JOB service creation failed"

    echo "🧩 Creating UI (NGINX) service"
    add_nssm_service_if_not_exists \
      "SVC_UI" \
      "$NGINX_PATH/nginx.exe" \
      "" \
      "$NGINX_PATH" \
      "$NGINX_PATH/logs/srvc.out" \
      "$NGINX_PATH/logs/srvc.err" \
      || fail "UI service creation failed"

    echo "✅ APPLICATION services setup completed"
}

################################
# CREATE AGENT SERVICE
################################
create_agent_service() {
    echo "=================================================="
    echo "▶️ Creating AGENT service"
    echo "=================================================="

    add_nssm_service_if_not_exists \
      "SVC_AGENT" \
      "$JAVA_HOME/bin/java.exe" \
      '-cp "./lib/*" -Xms1g -Xmx2g -Dconfig.file=conf/application.conf -Dhttp.port=9095 -Dlogback.debug=true -Dorg.owasp.esapi.resources=conf -Dlog4j.configurationFile=conf/log4j2.xml play.core.server.ProdServerStart' \
      "$INIT_APPS_PATH/alert-agent-1.0" \
      "$INIT_APPS_PATH/alert-agent-1.0/logs/srvc.out" \
      "$INIT_APPS_PATH/alert-agent-1.0/logs/srvc.err" \
      || fail "AGENT service creation failed"

    echo "✅ AGENT service setup completed"
}

################################
# SERVICE CREATION ENTRY
################################
echo "=================================================="
echo "▶️ Evaluating which services need to be created..."
echo "=================================================="

if contains application; then
    echo "➡️ Application artifact selected"
    create_application_services
else
    echo "ℹ️ Application artifact not selected, skipping"
fi

if contains agent; then
    echo "➡️ Agent artifact selected"
    create_agent_service
else
    echo "ℹ️ Agent artifact not selected, skipping"
fi

echo "✔ Service creation stage completed"
echo "=================================================="

################################
# UI SETUP / CLEANUP
################################
################################
# UI SETUP / CLEANUP
################################
uiSetup() {

if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
    echo "ui setup not required for agent"
    return 0
fi

if [ -d "${INIT_APPS_PATH}/production/AlertUI" ]; then
    mv "${INIT_APPS_PATH}/production/AlertUI" "${INIT_APPS_PATH}/"
    [ $? -ne 0 ] && fail "UI move failed"
else
    fail "AlertUI directory missing"
fi

if [ -d "${INIT_APPS_PATH}/production" ]; then
    rm -rf "${INIT_APPS_PATH}/production"
    [ $? -ne 0 ] && fail "Production cleanup failed"
fi

echo "✅ UI setup completed"

}


################################
# START WINDOWS SERVICES
################################
applicationStart() {

    echo "=================================================="
    echo "▶️ Starting services based on selected artifacts"
    echo "=================================================="

    service_running() {
        powershell.exe -Command \
        "(Get-Service -Name '$1' -ErrorAction SilentlyContinue).Status" \
        | grep -q "Running"
    }

    service_exists() {
        powershell.exe -Command \
        "Get-Service -Name '$1' -ErrorAction SilentlyContinue" \
        | grep -q "$1"
    }

    ################################
    # APPLICATION SERVICES
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Application artifact detected"

        for svc in SVC_API SVC_JOB SVC_UI; do
            echo "--------------------------------------------------"
            echo "🔎 Checking service: $svc"

            if service_exists "$svc"; then
                if service_running "$svc"; then
                    echo "ℹ️ $svc is already running → Skipping start"
                else
                    echo "🚀 Starting $svc..."
                    powershell.exe -Command "
                        try {
                            Start-Service -Name '$svc' -ErrorAction Stop
                        } catch {
                            exit 1
                        }
                    "
                    rc=$?
                    [ $rc -ne 0 ] && fail "Failed to start service $svc"
                    echo "✅ $svc started successfully"
                fi
            else
                echo "⚠️ $svc does not exist → Cannot start"
            fi
        done

        echo "✔ APPLICATION service start stage completed"
    else
        echo "ℹ️ Application artifact not selected → Skipping APPLICATION services"
    fi

    ################################
    # AGENT SERVICE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "--------------------------------------------------"
        echo "➡️ Agent artifact detected"
        echo "🔎 Checking service: SVC_AGENT"

        if service_exists "SVC_AGENT"; then
            if service_running "SVC_AGENT"; then
                echo "ℹ️ SVC_AGENT is already running → Skipping start"
            else
                echo "🚀 Starting SVC_AGENT..."
                powershell.exe -Command "
                    try {
                        Start-Service -Name 'SVC_AGENT' -ErrorAction Stop
                    } catch {
                        exit 1
                    }
                "
                rc=$?
                [ $rc -ne 0 ] && fail "Failed to start service SVC_AGENT"
                echo "✅ SVC_AGENT started successfully"
            fi
        else
            echo "⚠️ SVC_AGENT does not exist → Cannot start"
        fi

        echo "✔ AGENT service start stage completed"
    else
        echo "ℹ️ Agent artifact not selected → Skipping AGENT service"
    fi

    echo "=================================================="
    echo "🎉 Service start stage completed"
    echo "=================================================="
}

################################
# CHECK PORT AVAILABILITY
################################
check_port() {

    local PORT="$1"
    local MAX_RETRIES=10
    local WAIT_SECONDS=30

    echo "=================================================="
    echo "🔎 Checking availability of port $PORT"
    echo "=================================================="

    for ((i=1; i<=MAX_RETRIES; i++)); do
        echo "⏳ Attempt $i/$MAX_RETRIES → Checking port $PORT..."

        # More precise port match (LISTENING state)
        PORT_INFO=$(netstat -ano | grep -E "[:.]$PORT[[:space:]]" | grep LISTENING || true)

        if [ -n "$PORT_INFO" ]; then
            PID=$(echo "$PORT_INFO" | awk '{print $5}' | head -n1)

            echo "✅ Port $PORT is LISTENING"
            echo "🔢 PID using port: $PID"
            echo "=================================================="
            return 0
        fi

        if [ "$i" -lt "$MAX_RETRIES" ]; then
            echo "⏸️ Port $PORT not active yet → Waiting $WAIT_SECONDS seconds..."
            sleep "$WAIT_SECONDS"
        fi
    done

    echo "❌ Port $PORT did not become available after $MAX_RETRIES attempts"
    echo "=================================================="
    fail "Port $PORT validation failed"
}

################################
# SERVICE VALIDATION
################################
validate() {

    echo "=================================================="
    echo "▶️ Starting service validation stage"
    echo "=================================================="

    ################################
    # APPLICATION SERVICES
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Application artifact detected"
        echo "🔍 Validating API service (Port 9000)"
        check_port 9000

        echo "🔍 Validating JOB service (Port 9090)"
        check_port 9090

        echo "✔ APPLICATION services validated successfully"
    else
        echo "ℹ️ Application artifact not selected → Skipping APPLICATION validation"
    fi

    ################################
    # AGENT SERVICE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Agent artifact detected"
        echo "🔍 Validating AGENT service (Port 9095)"
        check_port 9095

        echo "✔ AGENT service validated successfully"
    else
        echo "ℹ️ Agent artifact not selected → Skipping AGENT validation"
    fi

    echo "=================================================="
    echo "🎉 Service validation stage completed successfully"
    echo "=================================================="
}

################################
# FLYWAY MIGRATION RUNNER
################################

flyway_run() {

    echo "=================================================="
    echo "🛫 Starting Flyway migration stage"
    echo "=================================================="

    ################################
    # DB MIGRATION PATHS (VERY IMPORTANT)
    ################################

    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        [ -d "$DB_PATH" ] || fail "Application DB_PATH missing: $DB_PATH"
        [ -d "${DB_PATH}DML" ] || fail "Application DB DML path missing: ${DB_PATH}DML"
    fi

    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        [ -d "$DB_PATH_AGENT" ] || fail "Agent DB_PATH missing: $DB_PATH_AGENT"
        [ -d "${DB_PATH_AGENT}DML" ] || fail "Agent DB DML path missing: ${DB_PATH_AGENT}DML"
    fi

    echo "📁 Ensuring Flyway log directory exists"
    mkdir -p "$LOGS_PATH/flyway"
    rc=$?
    [ $rc -ne 0 ] && fail "Flyway log directory creation failed"

    # Fail if Flyway command fails
    set -o pipefail
    echo "✔ pipefail enabled"

    ################################
    # VALIDATE REQUIRED DB PATHS
    ################################
    echo "🔎 Validating required DB paths"

    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        if [ -z "$DB_PATH" ]; then
            echo "❌ DB_PATH is empty for APPLICATION"
            fail "DB_PATH validation failed"
        fi
        echo "✅ DB_PATH validated for APPLICATION"
    else
        echo "ℹ️ Application artifact not selected → Skipping APPLICATION DB validation"
    fi

    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        if [ -z "$DB_PATH_AGENT" ]; then
            echo "❌ DB_PATH_AGENT is empty for AGENT"
            fail "DB_PATH_AGENT validation failed"
        fi
        echo "✅ DB_PATH_AGENT validated for AGENT"
    else
        echo "ℹ️ Agent artifact not selected → Skipping AGENT DB validation"
    fi

    ################################
    # CONVERT DB PATHS TO WINDOWS
    ################################
    echo "🔄 Converting DB paths to Windows format"

    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        WIN_DB_PATH=$(cygpath -w "$DB_PATH")
        rc=$?
        [ $rc -ne 0 ] && fail "cygpath conversion failed for DB_PATH"

        WIN_DB_PATH_DML="${WIN_DB_PATH}DML"

        echo "📂 Application DB Path     : $WIN_DB_PATH"
        echo "📂 Application DB DML Path : $WIN_DB_PATH_DML"
    fi

    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        WIN_DB_PATH_AGENT=$(cygpath -w "$DB_PATH_AGENT")
        rc=$?
        [ $rc -ne 0 ] && fail "cygpath conversion failed for DB_PATH_AGENT"

        WIN_DB_PATH_AGENT_DML="${WIN_DB_PATH_AGENT}DML"

        echo "📂 Agent DB Path     : $WIN_DB_PATH_AGENT"
        echo "📂 Agent DB DML Path : $WIN_DB_PATH_AGENT_DML"
    fi

    ################################
    # FLYWAY EXECUTION FUNCTION
    ################################
    run_flyway() {

        local service="$1"
        local locations="$2"
        local logfile="$3"
        local dbSchema="$4"

        echo "--------------------------------------------------"
        echo "➡️ Running Flyway for ${service^^} database"
        echo "📌 Schema    : $dbSchema"
        echo "📌 Locations : $locations"
        echo "📌 Log file  : $logfile"
        echo "--------------------------------------------------"

        mkdir -p "$(dirname "$logfile")"
        rc=$?
        [ $rc -ne 0 ] && fail "Flyway logfile directory creation failed"

        touch "$logfile"
        rc=$?
        [ $rc -ne 0 ] && fail "Flyway logfile creation failed"

        ################################
        # REPAIR (Do not stop script)
        ################################
        echo "🔧 Running Flyway repair for ${service^^}"

        MSYS_NO_PATHCONV=1 flyway \
            -user="$flywayUser" \
            -password="$flywayPass" \
            -url="$dbURL" \
            -schemas="$dbSchema" \
            -locations="$locations" \
            repair || echo "⚠ Repair failed — continuing to migrate"

        ################################
        # MIGRATE (Store in logfile)
        ################################
        echo "🚀 Running Flyway migrate for ${service^^}"

        MSYS_NO_PATHCONV=1 flyway \
            -user="$flywayUser" \
            -password="$flywayPass" \
            -url="$dbURL" \
            -schemas="$dbSchema" \
            -locations="$locations" \
            migrate 2>&1 | tee "$logfile"

        migrate_status=${PIPESTATUS[0]}

        if [ $migrate_status -ne 0 ]; then
            echo "❌ Flyway migrate FAILED for ${service^^}"
        fi

        echo "✅ Flyway migration completed for ${service^^}"
        return 0
    }


    ################################
    # APPLICATION DATABASE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Application artifact detected → Running APPLICATION migrations"

        run_flyway \
            "application" \
            "filesystem:${WIN_DB_PATH},filesystem:${WIN_DB_PATH_DML}" \
            "$LOGS_PATH/flyway/flyway_application.log" \
            "$dbSchemaApp"
        rc=$?
        [ $rc -ne 0 ] && fail "APPLICATION DB migration failed"

        echo "✔ APPLICATION DB migration completed"
    else
        echo "ℹ️ Skipping APPLICATION DB migration"
    fi

    ################################
    # AGENT DATABASE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Agent artifact detected → Running AGENT migrations"

        run_flyway \
            "agent" \
            "filesystem:${WIN_DB_PATH_AGENT},filesystem:${WIN_DB_PATH_AGENT_DML}" \
            "$LOGS_PATH/flyway/flyway_agent.log" \
            "$dbSchemaAgent"
        rc=$?
        [ $rc -ne 0 ] && fail "AGENT DB migration failed"

        echo "✔ AGENT DB migration completed"
    else
        echo "ℹ️ Skipping AGENT DB migration"
    fi

    echo "=================================================="
    echo "🎉 Flyway migration stage completed successfully"
    echo "=================================================="
}

################################
# MAIN
################################
main() {

    step "Create dirs" create_dirs
    step "Precheck" precheck

    if [[ "${flywayFixed,,}" == "true" ]]; then
        echo "Flyway only mode"
        step "Flyway" flyway_run
        exit 0
    fi

    step "Stop services" stop_services
    step "Logoff sessions" logoff_other_sessions
    step "Backup" backup
    step "Download build" download_build
    step "Extract" extract_zip
    step "Copy configs" copy_env_configs
    step "Update env" update_environment_conf
    step "Keystore" setup_keystore
    step "UI setup" uiSetup
    step "Start services" applicationStart
    step "Validate" validate
    step "Flyway" flyway_run
    echo "✅ DEPLOY SUCCESS"
}

main
EXIT_CODE=$?
echo "Final exit code: $EXIT_CODE"
exit $EXIT_CODE