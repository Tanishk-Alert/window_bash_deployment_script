#!/usr/bin/env bash
set -e
export MSYS_NO_PATHCONV=1

################################
# LOAD ENV
################################
ENV_FILE="/c/AlertEnterprise/configs/.env"

[ ! -f "$ENV_FILE" ] && echo "❌ ENV file missing: $ENV_FILE" && exit 1
source "$ENV_FILE"

export S3_SRC_PATH="$1"
export gitBranch="$2"
export buildVersion="$3"
export flywayFixed="$4"
export ARTIFACTS_ARG="$5"
export flywaySkip="$6"

echo "DEBUG:"
echo "S3_SRC_PATH=$S3_SRC_PATH"
echo "gitBranch=$gitBranch"
echo "buildVersion=$buildVersion"

################################
# BUILD ARTIFACT LIST
################################
ARTIFACTS=()
IFS=',' read -ra SELECTED <<< "$ARTIFACTS_ARG"

for item in "${SELECTED[@]}"; do
    case "${item,,}" in
        application|agent) ARTIFACTS+=("$item") ;;
        *) echo "❌ Invalid artifact: $item"; exit 1 ;;
    esac
done

[ "${#ARTIFACTS[@]}" -eq 0 ] && echo "❌ No artifacts selected" && exit 1

################################
# LOAD SECRETS
################################
# [ -z "$SECRETS" ] && echo "❌ SECRETS missing" && exit 1

# while read -r item; do
#     key=$(jq -r 'keys[0]' <<< "$item")
#     val=$(jq -r '.[keys[0]]' <<< "$item")
#     export "$key=$val"
# done < <(jq -c '.[]' <<< "$SECRETS")

################################
# FUNCTIONS
################################
create_dirs() {
    mkdir -p "$APP_PATH" "$INIT_APPS_PATH" "$KEYSTORE_PATH" \
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

    # Helper function to check if a Windows service exists
    service_exists() {
        powershell.exe -Command \
        "Get-Service -Name '$1' -ErrorAction SilentlyContinue" \
        | grep -q "$1"
    }

    ################################
    # STOP APPLICATION SERVICES
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Application artifact detected"
        echo "🔄 Attempting to stop APPLICATION services"

        # ---- SVC_API ----
        echo "🔍 Checking if SVC_API exists"
        if service_exists "SVC_API"; then
            echo "🛑 Stopping SVC_API..."
            powershell.exe -Command "Stop-Service SVC_API -Force"
            echo "✅ SVC_API stopped successfully"
        else
            echo "ℹ️ SVC_API not found, skipping"
        fi

        # ---- SVC_JOB ----
        echo "🔍 Checking if SVC_JOB exists"
        if service_exists "SVC_JOB"; then
            echo "🛑 Stopping SVC_JOB..."
            powershell.exe -Command "Stop-Service SVC_JOB -Force"
            echo "✅ SVC_JOB stopped successfully"
        else
            echo "ℹ️ SVC_JOB not found, skipping"
        fi

        echo "✔ APPLICATION service shutdown stage completed"
    else
        echo "ℹ️ Application artifact not selected, skipping APPLICATION services"
    fi

    ################################
    # STOP AGENT SERVICE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Agent artifact detected"
        echo "🔄 Attempting to stop AGENT service"

        echo "🔍 Checking if SVC_AGENT exists"
        if service_exists "SVC_AGENT"; then
            echo "🛑 Stopping SVC_AGENT..."
            powershell.exe -Command "Stop-Service SVC_AGENT -Force"
            echo "✅ SVC_AGENT stopped successfully"
        else
            echo "ℹ️ SVC_AGENT not found, skipping"
        fi

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

    CURRENT_SESSION_ID=$(query session | awk '/>/{print $(NF-1)}')

    echo "🟢 Current Session ID: $CURRENT_SESSION_ID"
    echo "=========================================="
    echo "🔎 Checking other sessions..."
    echo "=========================================="

    query session | tail -n +2 | while read -r line; do

        # Remove leading >
        clean_line=$(echo "$line" | sed 's/^>//')

        # Extract from end (more reliable)
        STATE=$(echo "$clean_line" | awk '{print $NF}')
        ID=$(echo "$clean_line" | awk '{print $(NF-1)}')
        USERNAME=$(echo "$clean_line" | awk '{print $(NF-2)}')

        # Skip if no username
        if [[ -z "$USERNAME" || "$USERNAME" == "services" ]]; then
            continue
        fi

        # Skip current session
        if [[ "$ID" == "$CURRENT_SESSION_ID" ]]; then
            echo "⏭ Skipping current session ID: $ID"
            continue
        fi

        if [[ "$STATE" == "Active" || "$STATE" == "Disc" ]]; then
            echo "🚪 Logging off user: $USERNAME | ID: $ID | State: $STATE"
            logoff "$ID"
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

    echo "=================================================="
    echo "📦 Starting backup process"
    echo "=================================================="

    # Verify APP_PATH exists
    echo "🔎 Checking if APP_PATH exists: $APP_PATH"
    if [ ! -d "$APP_PATH" ]; then
        echo "❌ APP_PATH does not exist: $APP_PATH"
        return 1
    fi
    echo "✅ APP_PATH exists"

    ################################
    # Rotate bkp_2
    ################################
    if [ -d "$APP_PATH/bkp_2" ]; then
        echo "🗑️ Found existing bkp_2 → Removing"
        ls -ld "$APP_PATH/bkp_2"
        rm -rf "$APP_PATH/bkp_2"
        echo "✅ bkp_2 removed"
    else
        echo "ℹ️ No existing bkp_2 found"
    fi

    ################################
    # Move bkp_1 → bkp_2
    ################################
    if [ -d "$APP_PATH/bkp_1" ]; then
        echo "🔁 Found bkp_1 → Moving contents to bkp_2"
        ls -ld "$APP_PATH/bkp_1"

        mkdir -p "$APP_PATH/bkp_2"
        mv "$APP_PATH"/bkp_1/* "$APP_PATH"/bkp_2/

        echo "✅ bkp_1 moved to bkp_2"
    else
        echo "ℹ️ No existing bkp_1 found"
    fi

    ################################
    # Backup current apps → bkp_1
    ################################
    echo "🔎 Checking INIT_APPS_PATH: $INIT_APPS_PATH"

    if [ -d "$INIT_APPS_PATH" ] && [ "$(ls -A "$INIT_APPS_PATH")" ]; then
        echo "📁 Creating new bkp_1 directory"
        mkdir -p "$APP_PATH/bkp_1"

        echo "🔄 Moving current application files to bkp_1"
        cd "$INIT_APPS_PATH" || exit 1
        mv * "$APP_PATH/bkp_1/" 2>/dev/null || true

        echo "✅ Current apps successfully backed up to bkp_1"
    else
        echo "⚠️ No existing apps directory to backup"
    fi

    echo "=================================================="
    echo "✔ Backup process completed"
    echo "=================================================="
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

        if aws s3 cp "$src" "$WIN_BUILD_PATH\\"; then
            echo "✅ Successfully downloaded ${artifact}.zip"
        else
            echo "⚠️ ${artifact}.zip not found in S3 → Skipping"
        fi
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

    echo "=================================================="
    echo "📦 Starting artifact extraction process"
    echo "=================================================="

    echo "📁 Target extraction directory: $INIT_APPS_PATH"

    extract_artifact() {

        local artifact="$1"
        local zip_file="${BUILD_PATH}/${artifact}.zip"

        echo "--------------------------------------------------"
        echo "🔎 Processing artifact: ${artifact}.zip"
        echo "📂 Source ZIP: $zip_file"
        echo "--------------------------------------------------"

        if [[ -f "$zip_file" ]]; then
            echo "✅ ZIP file found"

            # Special handling for DB artifacts
            if [[ "${artifact,,}" == *db* ]]; then
                echo "🗄️ DB artifact detected"
                echo "➡️ Extracting into dedicated folder: ${INIT_APPS_PATH}/${artifact}"

                unzip -qq "$zip_file" -d "${INIT_APPS_PATH}/${artifact}"

                echo "✅ ${artifact}.zip extracted to its DB folder"
            else
                echo "➡️ Extracting into main apps directory"

                unzip -qq "$zip_file" -d "${INIT_APPS_PATH}"

                echo "✅ ${artifact}.zip extracted successfully"
            fi
        else
            echo "⚠️ ${artifact}.zip not found → Skipping extraction"
        fi
    }

    ################################
    # APPLICATION ARTIFACTS
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Application artifact selected"
        echo "🔄 Extracting APPLICATION artifacts (api, job, ui, DB)"

        for artifact in api job ui DB; do
            extract_artifact "$artifact"
        done

        echo "✔ APPLICATION extraction stage completed"
    else
        echo "ℹ️ Application artifact not selected → Skipping APPLICATION extraction"
    fi

    ################################
    # AGENT ARTIFACTS
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Agent artifact selected"
        echo "🔄 Extracting AGENT artifacts (agentserver, agentDB)"

        for artifact in agentserver agentDB; do
            extract_artifact "$artifact"
        done

        echo "✔ AGENT extraction stage completed"
    else
        echo "ℹ️ Agent artifact not selected → Skipping AGENT extraction"
    fi

    echo "=================================================="
    echo "🎉 Artifact extraction process completed"
    echo "=================================================="
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

        echo "📄 Copying override_env.conf"
        cp "${config_src}/override_env.conf" "${app_conf_dir}/"

        echo "📄 Copying log4j2.xml"
        cp "${config_src}/log4j2.xml" "${app_conf_dir}/"

        # Convert paths for Windows usage
        echo "🔄 Converting keystore paths to Windows format"

        WIN_KEYSTORE_FILE=$(cygpath -w "$KEYSTORE_FILE" | sed 's|\\|\\\\\\\\|g')
        WIN_KEYSTORE_KEY_PATH=$(cygpath -w "$KEYSTORE_KEY_PATH" | sed 's|\\|\\\\\\\\|g')



        ################################
        # KEYSTORE CONFIG UPDATE
        ################################
        if [ -f "${apps_path}/conf/keystore.conf" ]; then
            echo "🔐 keystore.conf detected for ${service^^}"
            echo "📄 Copying keystore.conf template"

            cp "${config_src}/keystore.conf" "${app_conf_dir}/"

            echo "✏️ Replacing {AEKEYSTOREFILE} placeholder"
            sed -i "s|{AEKEYSTOREFILE}|${WIN_KEYSTORE_FILE}|g" \
                "${app_conf_dir}/keystore.conf"

            echo "✏️ Replacing {AEKEYSTOREPASSWD} placeholder"
            sed -i "s|{AEKEYSTOREPASSWD}|${WIN_KEYSTORE_KEY_PATH}|g" \
                "${app_conf_dir}/keystore.conf"

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

    echo "=================================================="
    echo "📝 Starting environment.conf update process"
    echo "=================================================="

    update_env() {

        local service="$1"
        local env_file="$2"
        local ORIGINAL="${env_file}.original"

        echo "--------------------------------------------------"
        echo "➡️ Processing service: ${service^^}"
        echo "📄 Target file : $env_file"
        echo "📄 Original    : $ORIGINAL"
        echo "--------------------------------------------------"

        # Check if original file exists
        if [ ! -f "$ORIGINAL" ]; then
            echo "⚠️ Missing ${ORIGINAL} → Skipping ${service^^}"
            return
        fi

        echo "📋 Restoring environment.conf from original"
        cp "$ORIGINAL" "$env_file"

        echo "🧹 Removing Windows CRLF characters (if any)"
        sed -i 's/\r$//' "$env_file"

        echo "➕ Ensuring override_env include is present"
        printf "\n" >> "$env_file"

        if grep -q '^include "override_env"' "$env_file"; then
            echo "ℹ️ override_env already included"
        else
            echo 'include "override_env"' >> "$env_file"
            echo "✅ override_env include added"
        fi

        echo "✔ environment.conf updated for ${service^^}"
    }

    ################################
    # APPLICATION SERVICES
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" application "* ]]; then
        echo "➡️ Application artifact selected"
        echo "🔄 Updating environment.conf for API and JOB"

        update_env "api" \
            "$INIT_APPS_PATH/alert-api-server-1.0/conf/environment.conf"

        update_env "job" \
            "$INIT_APPS_PATH/alert-job-server-1.0/conf/environment.conf"

        echo "✔ APPLICATION environment update stage completed"
    else
        echo "ℹ️ Application artifact not selected → Skipping APPLICATION environment update"
    fi

    ################################
    # AGENT SERVICE
    ################################
    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        echo "➡️ Agent artifact selected"
        echo "🔄 Updating environment.conf for AGENT"

        update_env "agent" \
            "$INIT_APPS_PATH/alert-agent-1.0/conf/environment.conf"

        echo "✔ AGENT environment update stage completed"
    else
        echo "ℹ️ Agent artifact not selected → Skipping AGENT environment update"
    fi

    echo "=================================================="
    echo "🎉 environment.conf update process completed"
    echo "=================================================="
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

    # Validate required variables
    echo "🔎 Validating required keystore variables"

    if [[ -z "${keystorePass:-}" ]]; then
        echo "❌ keystorePass missing"
        return 1
    fi




    [ -z "$KEYSTORE_FILE" ] && { echo "❌ KEYSTORE_FILE missing"; exit 1; }

    echo "✅ Required keystore variables present"

    # Ensure keystore directory exists
    echo "📁 Ensuring keystore directory exists: $KEYSTORE_PATH"
    mkdir -p "$KEYSTORE_PATH"

    # Convert paths for Windows usage
    echo "🔄 Converting keystore paths to Windows format"

    WIN_KEYSTORE_FILE=$(cygpath -w "$KEYSTORE_FILE" | sed 's|\\|\\\\|g')
    WIN_KEYSTORE_KEY_PATH=$(cygpath -w "$KEYSTORE_KEY_PATH" | sed 's|\\|\\\\|g')

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
                echo "❌ Unknown service: $service"
                exit 1
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

        jq -c '.[]' <<< "$KEYSTORE_SECRETS" | while read -r item; do
            key=$(jq -r 'keys[0]' <<< "$item")
            val=$(jq -r '.[keys[0]]' <<< "$item")

            echo "➡️ Upserting key: $key"

            cd "$APPS_PATH/lib" || exit 1

            MSYS_NO_PATHCONV=1 java -cp "./*" \
                -Dlog4j.configurationFile=../conf/log4j2.xml \
                -Dcrypto.configurationFile=../conf/keystore.conf \
                com.alnt.cryptoutil.Main key_upsert "$key" "$val" || exit 1
        done

        echo "✅ Secrets inserted (Branch 12)"
    }

    ################################
    # INSERT SECRETS - BRANCH 11
    ################################
    insert_secrets_branch11() {

        echo "🔑 Inserting secrets using Branch 11 method"
        printf "%s" "$keystorePass" > "$WIN_KEYSTORE_KEY_PATH"

        jq -c '.[]' <<< "$KEYSTORE_SECRETS" | while read -r item; do
            key=$(jq -r 'keys[0]' <<< "$item")
            val=$(jq -r '.[keys[0]]' <<< "$item")

            echo "➡️ Adding key: $key"

            cd "$APPS_PATH/lib" || exit 1

            MSYS_NO_PATHCONV=1 java -jar keystore-0.0.1-SNAPSHOT.jar \
                "$WIN_KEYSTORE_FILE" \
                "$keystorePass" \
                "$val" "$key" || exit 1
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
        echo "❌ No keystore configuration found for selected service"
        exit 1
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
    WIN_STARTUP_DIR=$(cygpath -w "$STARTUP_DIR")
    WIN_STDOUT_LOG=$(cygpath -w "$STDOUT_LOG")
    WIN_STDERR_LOG=$(cygpath -w "$STDERR_LOG")

    echo "📂 Executable : $WIN_EXE_PATH"
    echo "📂 Work Dir   : $WIN_STARTUP_DIR"

    # Install service
    MSYS_NO_PATHCONV=1 "$NSSM" install "$SERVICE_NAME" "$WIN_EXE_PATH" $ARGUMENTS
    MSYS_NO_PATHCONV=1 "$NSSM" set "$SERVICE_NAME" AppDirectory "$WIN_STARTUP_DIR"
    MSYS_NO_PATHCONV=1 "$NSSM" set "$SERVICE_NAME" AppStdout "$WIN_STDOUT_LOG"
    MSYS_NO_PATHCONV=1 "$NSSM" set "$SERVICE_NAME" AppStderr "$WIN_STDERR_LOG"
    MSYS_NO_PATHCONV=1 "$NSSM" set "$SERVICE_NAME" Start SERVICE_AUTO_START

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
      '-cp "./lib/*" -Xms2g -Xmx6g -Dconfig.file=conf/application.conf -Dlogback.debug=true -Dorg.owasp.esapi.resources=conf -Dlog4j.configurationFile=conf/log4j2.xml play.core.server.ProdServerStart' \
      "$INIT_APPS_PATH/alert-api-server-1.0" \
      "$INIT_APPS_PATH/alert-api-server-1.0/logs/srvc.out" \
      "$INIT_APPS_PATH/alert-api-server-1.0/logs/srvc.err"

    echo "🧩 Creating JOB service"
    add_nssm_service_if_not_exists \
      "SVC_JOB" \
      "$JAVA_HOME/bin/java.exe" \
      '-cp "./lib/*" -Xms2g -Xmx6g -Dconfig.file=conf/jobserver.conf -Dhttp.port=9090 -Dlogback.debug=true -Dorg.owasp.esapi.resources=conf -Dlog4j.configurationFile=conf/log4j2.xml play.core.server.ProdServerStart' \
      "$INIT_APPS_PATH/alert-job-server-1.0" \
      "$INIT_APPS_PATH/alert-job-server-1.0/logs/srvc.out" \
      "$INIT_APPS_PATH/alert-job-server-1.0/logs/srvc.err"

    echo "🧩 Creating UI (NGINX) service"
    add_nssm_service_if_not_exists \
      "SVC_UI" \
      "$NGINX_PATH/nginx.exe" \
      "" \
      "$NGINX_PATH" \
      "$NGINX_PATH/logs/srvc.out" \
      "$NGINX_PATH/logs/srvc.err"

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
      '-cp "./lib/*" -Xms2g -Xmx6g -Dconfig.file=conf/application.conf -Dhttp.port=9095 -Dlogback.debug=true -Dorg.owasp.esapi.resources=conf -Dlog4j.configurationFile=conf/log4j2.xml play.core.server.ProdServerStart' \
      "$INIT_APPS_PATH/alert-agent-1.0" \
      "$INIT_APPS_PATH/alert-agent-1.0/logs/srvc.out" \
      "$INIT_APPS_PATH/alert-agent-1.0/logs/srvc.err"

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

    echo "=================================================="
    echo "▶️ Starting UI setup and cleanup process"
    echo "=================================================="

    echo "📁 Base path: $INIT_APPS_PATH"

    ################################
    # MOVE AlertUI (if exists)
    ################################
    if [ -d "${INIT_APPS_PATH}/production/AlertUI" ]; then
        echo "➡️ Detected: ${INIT_APPS_PATH}/production/AlertUI"
        echo "🔄 Moving AlertUI to $INIT_APPS_PATH"

        mv "${INIT_APPS_PATH}/production/AlertUI" "${INIT_APPS_PATH}/"

        echo "✅ AlertUI moved successfully"
    else
        echo "ℹ️ AlertUI not found inside production directory → Skipping move"
    fi

    ################################
    # REMOVE production DIRECTORY
    ################################
    if [ -d "${INIT_APPS_PATH}/production" ]; then
        echo "🗑️ Cleaning up production directory"
        echo "📂 Removing: ${INIT_APPS_PATH}/production"

        rm -rf "${INIT_APPS_PATH}/production"

        echo "✅ Production directory removed"
    else
        echo "ℹ️ No production directory found → Nothing to remove"
    fi

    echo "=================================================="
    echo "✔ UI setup and cleanup stage completed"
    echo "=================================================="
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
                    powershell.exe -Command "Start-Service $svc"
                    echo "✅ $svc started successfully"
                fi
            else
                echo "⚠️ $svc does not exist → Cannot start"
            fi
        done

        if [[ "${flywaySkip,,}" == "true" ]]; then
            echo "Flyway skip is TRUE → Disabling RUN_ON_STARTUP"

            sed -i 's/^RUN_ON_STARTUP=.*/RUN_ON_STARTUP=false/' \
            "$INIT_APPS_PATH/alert-api-server-1.0/conf/override_env.conf"
        fi

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
                powershell.exe -Command "Start-Service SVC_AGENT"
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
    exit 1
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

    echo "📁 Ensuring Flyway log directory exists"
    mkdir -p "$LOGS_PATH/flyway"

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
            exit 1
        fi
        echo "✅ DB_PATH validated for APPLICATION"
    else
        echo "ℹ️ Application artifact not selected → Skipping APPLICATION DB validation"
    fi

    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        if [ -z "$DB_PATH_AGENT" ]; then
            echo "❌ DB_PATH_AGENT is empty for AGENT"
            exit 1
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
        WIN_DB_PATH_DML="${WIN_DB_PATH}DML"

        echo "📂 Application DB Path     : $WIN_DB_PATH"
        echo "📂 Application DB DML Path : $WIN_DB_PATH_DML"
    fi

    if [[ " ${ARTIFACTS[*]} " == *" agent "* ]]; then
        WIN_DB_PATH_AGENT=$(cygpath -w "$DB_PATH_AGENT")
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
        touch "$logfile"

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
            return 1
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
    echo "Flyway Skip Flag = $flywayskip"

    if [[ "${flywayFixed,,}" == "true" && "${flywaySkip,,}" != "true" ]]; then
        flyway_run || exit 1
        exit 0
    fi

    CONF_FILE="$INIT_APPS_PATH/alert-api-server-1.0/conf/override_env.conf"

    if [[ "${flywayFixed,,}" == "true" && "${flywaySkip,,}" == "true" ]]; then
        echo "Flyway fixed + Flyway skip → Enabling RUN_ON_STARTUP"

        if grep -q "^RUN_ON_STARTUP=" "$CONF_FILE"; then
            sed -i 's/^RUN_ON_STARTUP=.*/RUN_ON_STARTUP=true/' "$CONF_FILE"
        else
            # echo "RUN_ON_STARTUP=true" >> "$CONF_FILE"
            echo "RUN_ON_STARTUP=true is not present"
        fi

        applicationStart || exit 1
        exit 0
    fi

    create_dirs || return 1
    stop_services || return 1
    logoff_other_sessions || return 1
    backup || return 1
    download_build || return 1
    extract_zip || return 1
    copy_env_configs || return 1
    update_environment_conf || return 1
    setup_keystore || return 1
    uiSetup || return 1
    applicationStart || return 1
    validate || return 1

    if [ "$flywayskip" = "true" ]; then
        echo "Skipping Flyway Migration"
    else
        echo "Running Flyway Migration"
        flyway_run || exit 1
    fi

}

main
EXIT_CODE=$?
echo "Final exit code: $EXIT_CODE"
exit $EXIT_CODE