#!/usr/bin/env bash
# clp-stager: CloudPanel Staging Site Manager
# Features: Create, remove, refresh staging sites; Multisite, vHost cloning, auto-cleanup on create errors

set -e
DB_PATH="/home/clp/htdocs/app/data/db.sq3"

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This script must be run as root." 
   exit 1
fi

if ! command -v sqlite3 &> /dev/null; then
    echo "[ERROR] sqlite3 is not installed. Run: apt-get install -y sqlite3"
    exit 1
fi

# ==========================================
# PERFORMANCE & HARDWARE HELPERS
# ==========================================
get_size_estimate() {
    local dir=$1
    if [ -d "$dir" ]; then
        local size_mb=$(du -sm "$dir" | cut -f1)
        
        local eta=$(( size_mb / 150 ))
        [[ $eta -lt 1 ]] && eta=1
        
        echo "$size_mb MB (~$eta seconds)"
    else
        echo "0 MB"
    fi
}

get_db_estimate() {
    local db_name=$1
    if [[ -n "$db_name" ]]; then
        # Fetch and trim CloudPanel's master DB password dynamically
        local db_root_pass=$(clpctl db:show:master-credentials | grep 'Password' | awk -F'|' '{print $3}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # Query MySQL for combined table sizes in MB using the master credentials
        local size_mb=$(mysql -h 127.0.0.1 -u root -p"$db_root_pass" -Bse "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 0) FROM information_schema.tables WHERE table_schema = '$db_name';" 2>/dev/null)
        
        if [[ -n "$size_mb" && "$size_mb" != "NULL" && "$size_mb" -gt 0 ]]; then
            # DB exports/imports are CPU/SQL bound, assume roughly 15MB/s processing
            local eta=$(( size_mb / 15 ))
            [[ $eta -lt 1 ]] && eta=1
            
            echo "$size_mb MB (~$eta seconds)"
        else
            echo "Unknown Size"
        fi
    else
        echo "0 MB"
    fi
}

# ==========================================
# AUTO-CLEANUP (ROLLBACK) ON ERROR
# ==========================================
STG_DOMAIN_CREATED=false
STG_DB_CREATED=false
STG_DOMAIN=""
STG_DB_NAME=""
PROD_DB_NAME=""
CURRENT_PID=""

cleanup_on_error() {
    local exit_code=$?
    echo -en "\e[?25h" # Restore cursor safely
    
    if [ $exit_code -ne 0 ]; then
        echo -e "\n\e[31m[!] ERROR ENCOUNTERED. INITIATING ROLLBACK...\e[0m"
        
        if [[ -n "$CURRENT_PID" ]] && kill -0 $CURRENT_PID 2>/dev/null; then
            pkill -P $CURRENT_PID 2>/dev/null || true # Kill child processes (like tar)
            kill -9 $CURRENT_PID 2>/dev/null || true
        fi
        
        if [[ -n "$PROD_DB_NAME" && -f "/tmp/${PROD_DB_NAME}.sql.gz" ]]; then
            rm -f "/tmp/${PROD_DB_NAME}.sql.gz"
        fi
        
        if [ "$STG_DB_CREATED" = true ] && [[ -n "$STG_DB_NAME" ]]; then
            printf 'yes\n' | clpctl db:delete --databaseName="$STG_DB_NAME" >/dev/null 2>&1 || true
        fi
        
        if [ "$STG_DOMAIN_CREATED" = true ] && [[ -n "$STG_DOMAIN" ]]; then
            printf 'yes\n' | clpctl site:delete --domainName="$STG_DOMAIN" >/dev/null 2>&1 || true
        fi
        
        echo -e "\e[32m[✓] Cleanup complete. Your server is clean.\e[0m"
    fi
    exit $exit_code
}

trap cleanup_on_error EXIT INT TERM

# ==========================================
# SPINNER EXECUTOR FUNCTION (WITH LOG PARSING)
# ==========================================
execute_with_spinner() {
    local msg="$1"
    local cmd="$2"
    local allow_fail="$3"
    local log_file="/tmp/clp_stager_step.log"
    local start_t=$(date +%s)
    
    bash -c "$cmd" > "$log_file" 2>&1 &
    CURRENT_PID=$!
    
    local spinstr='|/-\'
    echo -en "\e[?25l"
    while kill -0 $CURRENT_PID 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r\e[36m[%c]\e[0m %s" "$spinstr" "$msg"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
    done
    
    set +e
    wait $CURRENT_PID
    local exit_code=$?
    set -e
    CURRENT_PID=""
    
    local end_t=$(date +%s)
    printf "\r\033[K" # Clear line
    
    if [ $exit_code -eq 0 ]; then
        if grep -qi "invalid command\|error\|exception" "$log_file"; then
            printf "\e[31m[x]\e[0m %s\n" "$msg"
            echo -e "\e[31m--- ERROR DETAILS ---\e[0m"
            cat "$log_file"
            echo -e "\e[31m---------------------\e[0m"
            exit 1
        fi
        printf "\e[32m[✓]\e[0m %s \e[90m(%ss)\e[0m\n" "$msg" "$((end_t - start_t))"
    else
        if [ "$allow_fail" == "true" ]; then
            printf "\e[33m[!]\e[0m %s (Finished with warnings)\n" "$msg"
        else
            printf "\e[31m[x]\e[0m %s\n" "$msg"
            echo -e "\e[31m--- ERROR DETAILS ---\e[0m"
            cat "$log_file"
            echo -e "\e[31m---------------------\e[0m"
            exit $exit_code
        fi
    fi
}

# ==========================================
# SITE TYPE & STAGING ENV HELPERS
# ==========================================
detect_site_type() {
    local dir="$1"
    if [[ -f "$dir/wp-config.php" ]]; then
        echo wordpress
    elif [[ -f "$dir/artisan" && -f "$dir/.env" ]]; then
        echo laravel
    elif [[ -f "$dir/.env" ]]; then
        echo laravel
    else
        echo unknown
    fi
}

env_key_exists() {
    local file="$1"
    local key="$2"
    grep -qE "^[[:space:]]*${key}=" "$file" 2>/dev/null
}

read_env_key() {
    local file="$1"
    local key="$2"
    local raw
    raw=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ "$raw" =~ ^\".*\"$ ]]; then
        raw="${raw:1:${#raw}-2}"
    elif [[ "$raw" =~ ^\'.*\'$ ]]; then
        raw="${raw:1:${#raw}-2}"
    fi
    raw="${raw%%#*}"
    raw="${raw%"${raw%%[![:space:]]}"}"
    printf '%s' "$raw"
}

patch_env_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local line="${key}=${value}"
    if [[ "$value" =~ [[:space:]#\"\'\\] ]]; then
        line="${key}=\"${value//\"/\\\"}\""
    fi
    if env_key_exists "$file" "$key"; then
        sed -i.bak -E "s|^[[:space:]]*${key}=.*|${line}|" "$file"
        rm -f "${file}.bak"
    else
        echo "$line" >> "$file"
    fi
}

dedupe_wp_config_define() {
    local file="$1"
    local const="$2"
    local lines ln
    lines=$(grep -nE "define[[:space:]]*\([[:space:]]*['\"]${const}['\"]" "$file" | cut -d: -f1 || true)
    [[ -z "$lines" ]] && return 0
    echo "$lines" | tail -n +2 | sort -rn | while read -r ln; do
        sed -i "${ln}d" "$file"
    done
}

patch_wp_config_define() {
    local file="$1"
    local const="$2"
    local value="$3"
    local insert_line
    if grep -qE "define[[:space:]]*\([[:space:]]*['\"]${const}['\"]" "$file"; then
        sed -i.bak -E "s/define[[:space:]]*\([[:space:]]*['\"]${const}['\"][[:space:]]*,[[:space:]]*['\"][^'\"]*['\"][[:space:]]*\)/define('${const}', '${value}')/g" "$file"
        rm -f "${file}.bak"
        dedupe_wp_config_define "$file" "$const"
    elif grep -qF "stop editing" "$file"; then
        insert_line=$(grep -nF "stop editing" "$file" | head -1 | cut -d: -f1)
        sed -i.bak "${insert_line}i define('${const}', '${value}');" "$file"
        rm -f "${file}.bak"
    else
        echo "define('${const}', '${value}');" >> "$file"
    fi
}

apply_wordpress_staging_env() {
    local wp_config="$1"
    [[ -f "$wp_config" ]] || return 0
    patch_wp_config_define "$wp_config" "WP_ENV" "local"
    patch_wp_config_define "$wp_config" "WP_ENVIRONMENT_TYPE" "local"
}

apply_laravel_staging_env() {
    local dest_dir="$1"
    local staging_url="$2"
    local db_name="$3"
    local db_user="$4"
    local db_pass="$5"
    local mode="${6:-create}"
    local env_file="$dest_dir/.env"
    local staging_host="${staging_url#https://}"
    staging_host="${staging_host#http://}"
    staging_host="${staging_host%%/*}"

    [[ -f "$env_file" ]] || return 1

    patch_env_key "$env_file" "DB_DATABASE" "$db_name"
    patch_env_key "$env_file" "DB_USERNAME" "$db_user"
    patch_env_key "$env_file" "DB_PASSWORD" "$db_pass"
    patch_env_key "$env_file" "APP_ENV" "local"
    patch_env_key "$env_file" "APP_DEBUG" "true"
    patch_env_key "$env_file" "APP_URL" "$staging_url"

    if [[ "$mode" == "create" ]]; then
        patch_env_key "$env_file" "MAIL_MAILER" "log"
        patch_env_key "$env_file" "QUEUE_CONNECTION" "sync"
    else
        env_key_exists "$env_file" "MAIL_MAILER" && patch_env_key "$env_file" "MAIL_MAILER" "log"
        env_key_exists "$env_file" "QUEUE_CONNECTION" && patch_env_key "$env_file" "QUEUE_CONNECTION" "sync"
    fi

    if env_key_exists "$env_file" "SESSION_DOMAIN"; then
        patch_env_key "$env_file" "SESSION_DOMAIN" ".$staging_host"
    fi
    if env_key_exists "$env_file" "SANCTUM_STATEFUL_DOMAINS"; then
        patch_env_key "$env_file" "SANCTUM_STATEFUL_DOMAINS" "$staging_host"
    fi
}

configure_wordpress_staging() {
    local dest_dir="$1"
    local stg_domain="$2"
    local stg_db_name="$3"
    local stg_db_user="$4"
    local stg_db_pass="$5"
    local prod_domain="$6"
    local stg_user="$7"
    local wp_config="$dest_dir/wp-config.php"

    [[ -f "$wp_config" ]] || return 0

    sed -i "s/define( *'DB_NAME', *'[^']*' *);/define('DB_NAME', '$stg_db_name');/g" "$wp_config"
    sed -i "s/define( *'DB_USER', *'[^']*' *);/define('DB_USER', '$stg_db_user');/g" "$wp_config"
    sed -i "s/define( *'DB_PASSWORD', *'[^']*' *);/define('DB_PASSWORD', '$stg_db_pass');/g" "$wp_config"

    if grep -q "WP_HOME" "$wp_config"; then
        sed -i "s|define( *'WP_HOME', *'[^']*' *);|define('WP_HOME', 'https://$stg_domain');|g" "$wp_config"
        sed -i "s|define( *'WP_SITEURL', *'[^']*' *);|define('WP_SITEURL', 'https://$stg_domain');|g" "$wp_config"
    else
        sed -i "/define( *'DB_PASSWORD'/a define('WP_HOME', 'https://$stg_domain');\ndefine('WP_SITEURL', 'https://$stg_domain');" "$wp_config"
    fi

    if grep -q "DOMAIN_CURRENT_SITE" "$wp_config"; then
        sed -i "s/define( *'DOMAIN_CURRENT_SITE', *'[^']*' *);/define('DOMAIN_CURRENT_SITE', '$stg_domain');/g" "$wp_config"
    fi

    apply_wordpress_staging_env "$wp_config"
    run_wordpress_db_search_replace "$dest_dir" "$prod_domain" "$stg_domain" "$stg_user"
}

run_wordpress_db_search_replace() {
    local dest_dir="$1"
    local prod_domain="$2"
    local stg_domain="$3"
    local stg_user="$4"
    local wp_config="$dest_dir/wp-config.php"

    [[ -f "$wp_config" ]] || return 0

    if grep -q "DOMAIN_CURRENT_SITE" "$wp_config"; then
        execute_with_spinner "Multisite: Running WP-CLI search-replace..." "sudo -u \"$stg_user\" wp search-replace \"$prod_domain\" \"$stg_domain\" --network --skip-plugins --skip-themes --path=\"$dest_dir\"" "true"
    else
        execute_with_spinner "Running WP-CLI search-replace (https)..." "sudo -u \"$stg_user\" wp search-replace \"https://$prod_domain\" \"https://$stg_domain\" --skip-plugins --skip-themes --path=\"$dest_dir\"" "true"
        execute_with_spinner "Running WP-CLI search-replace (http)..." "sudo -u \"$stg_user\" wp search-replace \"http://$prod_domain\" \"http://$stg_domain\" --skip-plugins --skip-themes --path=\"$dest_dir\"" "true"
    fi
}

run_laravel_post_deploy() {
    local dest_dir="$1"
    local site_user="$2"

    [[ -f "$dest_dir/artisan" ]] || return 0
    if ! command -v php &>/dev/null; then
        echo -e "\e[33m[!]\e[0m php not found. Skipping artisan optimize:clear."
        return 0
    fi

    execute_with_spinner "Clearing Laravel caches (optimize:clear)..." "cd \"$dest_dir\" && sudo -u \"$site_user\" php artisan optimize:clear" "true"
}

apply_staging_environment() {
    local dest_dir="$1"
    local stg_domain="$2"
    local stg_user="$3"
    local prod_domain="$4"
    local mode="$5"
    local stg_db_name="$6"
    local stg_db_user="$7"
    local stg_db_pass="$8"
    local staging_url="https://$stg_domain"
    local site_type
    local env_db_name env_db_user env_db_pass

    site_type=$(detect_site_type "$dest_dir")

    case "$site_type" in
        wordpress)
            if [[ "$mode" == "create" && -n "$stg_db_name" ]]; then
                configure_wordpress_staging "$dest_dir" "$stg_domain" "$stg_db_name" "$stg_db_user" "$stg_db_pass" "$prod_domain" "$stg_user"
            else
                apply_wordpress_staging_env "$dest_dir/wp-config.php"
                run_wordpress_db_search_replace "$dest_dir" "$prod_domain" "$stg_domain" "$stg_user"
            fi
            ;;
        laravel)
            if [[ -f "$dest_dir/.env" ]]; then
                if [[ "$mode" == "refresh" ]]; then
                    env_db_name=$(read_env_key "$dest_dir/.env" "DB_DATABASE")
                    env_db_user=$(read_env_key "$dest_dir/.env" "DB_USERNAME")
                    env_db_pass=$(read_env_key "$dest_dir/.env" "DB_PASSWORD")
                    [[ -n "$env_db_name" ]] && stg_db_name="$env_db_name"
                    [[ -n "$env_db_user" ]] && stg_db_user="$env_db_user"
                    [[ -n "$env_db_pass" ]] && stg_db_pass="$env_db_pass"
                fi
                if [[ -n "$stg_db_name" && -n "$stg_db_user" && -n "$stg_db_pass" ]]; then
                    apply_laravel_staging_env "$dest_dir" "$staging_url" "$stg_db_name" "$stg_db_user" "$stg_db_pass" "$mode"
                    run_laravel_post_deploy "$dest_dir" "$stg_user"
                else
                    echo -e "\e[33m[!]\e[0m Laravel .env found but database credentials could not be resolved. Skipping .env updates."
                fi
            fi
            ;;
        unknown)
            echo -e "\e[33m[!]\e[0m Unknown site type (no wp-config.php or .env). File copy only; no environment automation."
            ;;
    esac
}

# ==========================================
# 1. Fetch Active PHP Sites
# ==========================================
mapfile -t SITES < <(sqlite3 "$DB_PATH" "SELECT domain_name FROM site WHERE type = 'php';")
if [[ ${#SITES[@]} -eq 0 ]]; then
    echo "[ERROR] No PHP sites found in CloudPanel."
    exit 1
fi

ACTION_CREATE="__ACTION_CREATE__"
ACTION_REMOVE="__ACTION_REMOVE__"
ACTION_REFRESH="__ACTION_REFRESH__"

STAGING_SITES=()
LIVE_SITES=()

is_staging_site() {
    local dl="${1,,}"
    [[ "$dl" == *staging* || "$dl" == *studiorepublic* ]]
}

build_site_lists() {
    STAGING_SITES=()
    LIVE_SITES=()
    for d in "${SITES[@]}"; do
        if is_staging_site "$d"; then
            STAGING_SITES+=("$d")
        else
            LIVE_SITES+=("$d")
        fi
    done
}

option_label() {
    case "$1" in
        "$ACTION_CREATE") echo "Create a new staging site" ;;
        "$ACTION_REMOVE") echo "Remove a staging site" ;;
        "$ACTION_REFRESH") echo "Refresh a staging site from live" ;;
        *) echo "$1" ;;
    esac
}

candidate_add_unique() {
    local live="$1"
    local c
    for c in "${RESOLVE_CANDIDATES[@]}"; do
        [[ "$c" == "$live" ]] && return
    done
    RESOLVE_CANDIDATES+=("$live")
}

load_prod_metadata() {
    SRC_USER=$(sqlite3 "$DB_PATH" "SELECT user FROM site WHERE domain_name = '$PROD_DOMAIN' LIMIT 1;" | tr -d '\r\n')
    PHP_VERSION=$(sqlite3 "$DB_PATH" "SELECT php_version FROM php_settings WHERE site_id = (SELECT id FROM site WHERE domain_name = '$PROD_DOMAIN') LIMIT 1;" | tr -d '\r\n')
    PROD_DB_NAME=$(sqlite3 "$DB_PATH" "SELECT name FROM database WHERE site_id = (SELECT id FROM site WHERE domain_name = '$PROD_DOMAIN') LIMIT 1;" | tr -d '\r\n')

    if [[ -z "$PHP_VERSION" ]]; then
        echo -e "\e[31m[ERROR] Could not determine PHP Version for $PROD_DOMAIN. Aborting.\e[0m"
        exit 1
    fi

    SRC_DIR="/home/$SRC_USER/htdocs/$PROD_DOMAIN"
}

resolve_live_domain() {
    local stg="$1"
    local stg_lower="${stg,,}"
    local live rest first

    RESOLVE_CANDIDATES=()

    for live in "${LIVE_SITES[@]}"; do
        if [[ "$stg_lower" == "staging.${live,,}" ]]; then
            candidate_add_unique "$live"
        fi
    done

    first="${stg%%.*}"
    rest="${stg#*.}"
    if [[ ( "$first" == "staging" || "$first" == "stg" ) && -n "$rest" && "$rest" != "$stg" ]]; then
        for live in "${LIVE_SITES[@]}"; do
            if [[ "${live,,}" == "${rest,,}" ]]; then
                candidate_add_unique "$live"
            fi
        done
    fi

    if [[ ${#RESOLVE_CANDIDATES[@]} -eq 1 ]]; then
        PROD_DOMAIN="${RESOLVE_CANDIDATES[0]}"
        echo -e "\e[34m[i]\e[0m Live site detected: \e[32m$PROD_DOMAIN\e[0m\n"
        return 0
    fi

    if [[ ${#RESOLVE_CANDIDATES[@]} -gt 1 ]]; then
        choose_site "Could not auto-detect live site — select source (filter, arrows, Enter):" PROD_DOMAIN "${RESOLVE_CANDIDATES[@]}"
    else
        if [[ ${#LIVE_SITES[@]} -eq 0 ]]; then
            echo -e "\e[31m[ERROR] No live (non-staging) sites found to use as source.\e[0m"
            exit 1
        fi
        choose_site "Could not auto-detect live site — select source (filter, arrows, Enter):" PROD_DOMAIN "${LIVE_SITES[@]}"
    fi

    if [[ -z "$PROD_DOMAIN" ]]; then
        echo -e "\e[31m[ERROR] No live site selected. Aborting.\e[0m"
        exit 1
    fi
}

# ==========================================
# 2. Interactive Menu (With Type-to-Filter)
# ==========================================
choose_site() {
    local prompt="$1"
    local outvar="$2"
    shift 2
    local options=("$@")

    if [[ ${#options[@]} -eq 0 ]]; then
        echo -e "\e[31m[ERROR] No sites available to select.\e[0m"
        exit 1
    fi

    local filtered=("${options[@]}")
    local cur=0
    local filter=""
    local count=${#filtered[@]}
    local display_limit=10 # Max items to show at once to prevent terminal overflow

    echo -e "\e[36m$prompt\e[0m"
    echo -en "\e[?25l" # Hide cursor

    while true; do
        # 1. Print Filter Bar
        echo -e " \e[90mFilter:\e[0m \e[32m${filter}\e[0m\e[K"
        
        # 2. Setup display window size
        count=${#filtered[@]}
        local display_count=$count
        [[ $display_count -gt $display_limit ]] && display_count=$display_limit
        
        [[ $cur -ge $count && $count -gt 0 ]] && cur=$((count - 1))
        [[ $cur -lt 0 ]] && cur=0

        # 3. Print Options
        for ((i=0; i<display_count; i++)); do
            local opt_idx=$i
            # Scrolling logic if we move past the visible window
            if [[ $cur -ge $display_limit && $count -gt $display_limit ]]; then
                opt_idx=$((cur - display_limit + 1 + i))
            fi
            
            if [[ $opt_idx -ge $count ]]; then
                echo -e "\e[K" # Clear empty lines if list shrinks
                continue
            fi

            local o="${filtered[$opt_idx]}"
            local o_label
            o_label=$(option_label "$o")
            if [ "$opt_idx" == "$cur" ]; then
                echo -e " > \e[7m$o_label\e[0m\e[K"
            else
                echo -e "   $o_label\e[K"
            fi
        done

        # 4. Read User Input (1 char at a time)
        read -s -n1 key || true

        if [[ $key == $'\e' ]]; then
            # It's an escape sequence (arrow keys)
            read -s -n2 -t 0.1 seq || true
            if [[ $seq == "[A" ]]; then cur=$((cur - 1)); fi # Up
            if [[ $seq == "[B" ]]; then cur=$((cur + 1)); fi # Down
        elif [[ -z $key ]]; then
            # Enter pressed
            if [[ $count -gt 0 ]]; then
                eval $outvar="${filtered[$cur]}"
            else
                eval $outvar=""
            fi
            break
        elif [[ $key == $'\x7f' || $key == $'\x08' ]]; then
            # Backspace pressed
            if [[ -n $filter ]]; then
                filter="${filter%?}"
            fi
        else
            # Regular character typed (allow letters, numbers, dots, hyphens, underscores)
            if [[ "$key" =~ [a-zA-Z0-9_.-] ]]; then
                filter="${filter}${key}"
            fi
        fi

        # 5. Re-filter the array if the input wasn't an arrow key
        if [[ -n "$key" && "$key" != $'\e' ]]; then
            filtered=()
            for o in "${options[@]}"; do
                local o_label
                o_label=$(option_label "$o")
                if [[ "${o_label,,}" == *"${filter,,}"* ]]; then
                    filtered+=("$o")
                fi
            done
            cur=0 # Reset selection to top of filtered list
        fi

        # 6. Move cursor back up to seamlessly redraw the menu
        echo -en "\e[$((display_count + 1))A"
    done

    # Restore cursor and wipe the menu cleanly from the screen
    echo -en "\e[?25h" 
    for ((i=0; i<=display_limit; i++)); do echo -en "\e[K\n"; done
    echo -en "\e[$((display_limit + 1))A"
}

run_refresh_staging() {
    if [[ ${#STAGING_SITES[@]} -eq 0 ]]; then
        echo -e "\e[31m[ERROR] No staging sites found (domains containing staging or studiorepublic).\e[0m"
        exit 1
    fi

    choose_site "Select staging site to refresh (filter, arrows, Enter):" STG_DOMAIN "${STAGING_SITES[@]}"

    if [[ -z "$STG_DOMAIN" ]]; then
        echo -e "\e[31m[ERROR] No staging site selected. Aborting.\e[0m"
        exit 1
    fi

    STG_USER=$(sqlite3 "$DB_PATH" "SELECT user FROM site WHERE domain_name = '$STG_DOMAIN' LIMIT 1;" | tr -d '\r\n')
    STG_DB_NAME=$(sqlite3 "$DB_PATH" "SELECT name FROM database WHERE site_id = (SELECT id FROM site WHERE domain_name = '$STG_DOMAIN') LIMIT 1;" | tr -d '\r\n')
    DEST_DIR="/home/$STG_USER/htdocs/$STG_DOMAIN"

    if [[ -z "$STG_USER" ]]; then
        echo -e "\e[31m[ERROR] Could not resolve site user for $STG_DOMAIN. Aborting.\e[0m"
        exit 1
    fi

    echo -e "Selected staging site: \e[32m$STG_DOMAIN\e[0m\n"

    resolve_live_domain "$STG_DOMAIN"
    load_prod_metadata

    echo -e "\e[33mWARNING: This will OVERWRITE the staging site.\e[0m"
    echo ""
    echo "  Source (live):     $PROD_DOMAIN"
    echo "  Destination:       $STG_DOMAIN"
    echo ""
    echo "  - Staging database replaced with export from live"
    echo "  - Files copied from live (root wp-config.php and .env preserved, then re-applied for staging)"
    echo "  - WordPress: WP_ENV/WP_ENVIRONMENT_TYPE=local + WP-CLI URL replace ($PROD_DOMAIN -> $STG_DOMAIN)"
    echo "  - Laravel: APP_ENV=local, APP_DEBUG=true, APP_URL updated + artisan optimize:clear"
    echo ""
    read -p "Type 'yes' to continue: " CONFIRM_REFRESH

    if [[ "$CONFIRM_REFRESH" != "yes" ]]; then
        echo -e "\e[34m[i]\e[0m Aborted. No changes were made."
        trap - EXIT INT TERM
        exit 0
    fi

    echo ""

    if [[ -n "$PROD_DB_NAME" ]]; then
        if [[ -z "$STG_DB_NAME" ]]; then
            echo -e "\e[31m[ERROR] Live site has database '$PROD_DB_NAME' but staging has no linked database. Aborting.\e[0m"
            exit 1
        fi

        DB_ESTIMATE=$(get_db_estimate "$PROD_DB_NAME")
        echo -e "\e[34m[i]\e[0m Database Volume: $DB_ESTIMATE"

        DB_CMD="clpctl db:export --databaseName=\"$PROD_DB_NAME\" --file=\"/tmp/${PROD_DB_NAME}.sql.gz\" && \
                clpctl db:import --databaseName=\"$STG_DB_NAME\" --file=\"/tmp/${PROD_DB_NAME}.sql.gz\" && \
                rm -f \"/tmp/${PROD_DB_NAME}.sql.gz\""

        execute_with_spinner "Migrating Database ($PROD_DB_NAME -> $STG_DB_NAME)..." "$DB_CMD"
    else
        echo -e "\e[34m[i]\e[0m No live database found. Skipping DB migration."
    fi

    FILE_ESTIMATE=$(get_size_estimate "$SRC_DIR")
    echo -e "\e[34m[i]\e[0m File Volume: $FILE_ESTIMATE"

    FILE_CMD="tar --exclude='./wp-config.php' --exclude='./.env' -C \"$SRC_DIR\" -cf - . | tar -xf - -C \"$DEST_DIR\" && chown -R \"$STG_USER:$STG_USER\" \"$DEST_DIR\""

    execute_with_spinner "Copying Site Files and Setting Permissions..." "$FILE_CMD"

    echo -e "\e[32m[✓]\e[0m Updating preserved config for staging ($(detect_site_type "$DEST_DIR"))..."
    apply_staging_environment "$DEST_DIR" "$STG_DOMAIN" "$STG_USER" "$PROD_DOMAIN" "refresh" "$STG_DB_NAME" "" ""

    trap - EXIT INT TERM

    echo -e "\n========================================================"
    echo -e "✅ \e[32mRefresh Complete!\e[0m"
    echo "Live site:       $PROD_DOMAIN"
    echo "Staging site:    $STG_DOMAIN"
    echo "SSH/SFTP User:   $STG_USER (unchanged)"
    if [[ -n "$STG_DB_NAME" ]]; then
        echo "Database:        $STG_DB_NAME (credentials preserved in wp-config/.env)"
    fi
    echo "========================================================"
}

run_remove_staging() {
    if [[ ${#STAGING_SITES[@]} -eq 0 ]]; then
        echo -e "\e[31m[ERROR] No staging sites found (domains containing staging or studiorepublic).\e[0m"
        exit 1
    fi

    choose_site "Select staging site to remove (filter, arrows, Enter):" STG_DOMAIN "${STAGING_SITES[@]}"

    if [[ -z "$STG_DOMAIN" ]]; then
        echo -e "\e[31m[ERROR] No staging site selected. Aborting.\e[0m"
        exit 1
    fi

    STG_USER=$(sqlite3 "$DB_PATH" "SELECT user FROM site WHERE domain_name = '$STG_DOMAIN' LIMIT 1;" | tr -d '\r\n')
    STG_DB_NAME=$(sqlite3 "$DB_PATH" "SELECT name FROM database WHERE site_id = (SELECT id FROM site WHERE domain_name = '$STG_DOMAIN') LIMIT 1;" | tr -d '\r\n')

    echo -e "\e[33mWARNING: This will permanently delete the staging site.\e[0m"
    echo ""
    echo "  Domain:      $STG_DOMAIN"
    echo "  Site user:   ${STG_USER:-unknown}"
    if [[ -n "$STG_DB_NAME" ]]; then
        echo "  Database:    $STG_DB_NAME"
    else
        echo "  Database:    (none linked)"
    fi
    echo ""
    read -p "Type the staging domain to confirm deletion: " CONFIRM_REMOVE

    if [[ "$CONFIRM_REMOVE" != "$STG_DOMAIN" ]]; then
        echo -e "\e[34m[i]\e[0m Aborted. No changes were made."
        trap - EXIT INT TERM
        exit 0
    fi

    echo ""

    if [[ -n "$STG_DB_NAME" ]]; then
        execute_with_spinner "Deleting database ($STG_DB_NAME)..." "printf 'yes\n' | clpctl db:delete --databaseName=\"$STG_DB_NAME\""
    fi

    execute_with_spinner "Deleting site ($STG_DOMAIN)..." "printf 'yes\n' | clpctl site:delete --domainName=\"$STG_DOMAIN\""

    trap - EXIT INT TERM

    echo -e "\n========================================================"
    echo -e "✅ \e[32mStaging Site Removed\e[0m"
    echo "Deleted domain:  $STG_DOMAIN"
    echo "========================================================"
}

run_create_from_live() {
    if [[ ${#LIVE_SITES[@]} -eq 0 ]]; then
        echo -e "\e[31m[ERROR] No live sites found to copy from (all PHP sites appear to be staging).\e[0m"
        exit 1
    fi

    choose_site "Select LIVE site to copy from (filter, arrows, Enter):" PROD_DOMAIN "${LIVE_SITES[@]}"

    if [[ -z "$PROD_DOMAIN" ]]; then
        echo -e "\e[31m[ERROR] No live site selected. Aborting.\e[0m"
        exit 1
    fi

    echo -e "Selected LIVE site: \e[32m$PROD_DOMAIN\e[0m\n"

    load_prod_metadata

    echo -e "\e[36m[i] Tip: Type just a prefix (e.g., 'stg') to auto-append '.$PROD_DOMAIN', or type a full domain.\e[0m"
    read -p "Enter staging prefix or full domain: " STG_DOMAIN

    if [[ -z "$STG_DOMAIN" ]]; then echo "[ERROR] Domain required."; exit 1; fi

    if [[ "$STG_DOMAIN" != *"."* ]]; then
        STG_DOMAIN="${STG_DOMAIN}.${PROD_DOMAIN}"
        echo -e "  \e[90m↳ Auto-completed to: $STG_DOMAIN\e[0m"
    fi

    CLEAN_DOMAIN=$(echo "$STG_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g' | cut -c1-6)
    RND_STR=$(openssl rand -hex 2)
    STG_USER="stg${CLEAN_DOMAIN}${RND_STR}"
    STG_PASS="Stg1!$(openssl rand -hex 6)"

    echo ""

    CMD="clpctl site:add:php --domainName=\"$STG_DOMAIN\" --phpVersion=\"$PHP_VERSION\" --vhostTemplate=\"Generic\" --siteUser=\"$STG_USER\" --siteUserPassword=\"$STG_PASS\""
    execute_with_spinner "Creating CloudPanel site ($STG_DOMAIN) on PHP $PHP_VERSION..." "$CMD"
    STG_DOMAIN_CREATED=true

    if [[ -n "$PROD_DB_NAME" ]]; then
        STG_DB_NAME="db${CLEAN_DOMAIN}${RND_STR}"
        STG_DB_USER="u${CLEAN_DOMAIN}${RND_STR}"
        STG_DB_PASS=$(openssl rand -hex 16)
        STG_DB_CREATED=true

        DB_ESTIMATE=$(get_db_estimate "$PROD_DB_NAME")
        echo -e "\e[34m[i]\e[0m Database Volume: $DB_ESTIMATE"

        DB_CMD="clpctl db:export --databaseName=\"$PROD_DB_NAME\" --file=\"/tmp/${PROD_DB_NAME}.sql.gz\" && \
                clpctl db:add --domainName=\"$STG_DOMAIN\" --databaseName=\"$STG_DB_NAME\" --databaseUserName=\"$STG_DB_USER\" --databaseUserPassword=\"$STG_DB_PASS\" && \
                clpctl db:import --databaseName=\"$STG_DB_NAME\" --file=\"/tmp/${PROD_DB_NAME}.sql.gz\" && \
                rm -f \"/tmp/${PROD_DB_NAME}.sql.gz\""

        execute_with_spinner "Migrating Database ($PROD_DB_NAME -> $STG_DB_NAME)..." "$DB_CMD"
    else
        echo -e "\e[34m[i]\e[0m No production database found. Skipping DB migration."
    fi

    DEST_DIR="/home/$STG_USER/htdocs/$STG_DOMAIN"

    FILE_ESTIMATE=$(get_size_estimate "$SRC_DIR")
    echo -e "\e[34m[i]\e[0m File Volume: $FILE_ESTIMATE"

    FILE_CMD="tar -C \"$SRC_DIR\" -cf - . | tar -xf - -C \"$DEST_DIR\" && chown -R \"$STG_USER:$STG_USER\" \"$DEST_DIR\""

    execute_with_spinner "Copying Site Files and Setting Permissions..." "$FILE_CMD"

    if [[ -n "$PROD_DB_NAME" ]]; then
        echo -e "\e[32m[✓]\e[0m Updating environment config for staging ($(detect_site_type "$DEST_DIR"))..."
        apply_staging_environment "$DEST_DIR" "$STG_DOMAIN" "$STG_USER" "$PROD_DOMAIN" "create" "$STG_DB_NAME" "$STG_DB_USER" "$STG_DB_PASS"
    else
        site_type=$(detect_site_type "$DEST_DIR")
        if [[ "$site_type" != "unknown" ]]; then
            echo -e "\e[32m[✓]\e[0m Applying staging environment ($(detect_site_type "$DEST_DIR"))..."
            apply_staging_environment "$DEST_DIR" "$STG_DOMAIN" "$STG_USER" "$PROD_DOMAIN" "create" "" "" ""
        fi
    fi

    PROD_VARNISH="/home/$SRC_USER/.varnish-cache/settings.json"
    STG_VARNISH_DIR="/home/$STG_USER/.varnish-cache"

    if [[ -f "$PROD_VARNISH" ]]; then
        echo -e "\e[32m[✓]\e[0m Cloning Varnish Cache configuration..."
        mkdir -p "$STG_VARNISH_DIR"
        sed "s/$PROD_DOMAIN/$STG_DOMAIN/g" "$PROD_VARNISH" > "$STG_VARNISH_DIR/settings.json"
        chown -R "$STG_USER:$STG_USER" "$STG_VARNISH_DIR"
    fi

    PROD_VHOST="/etc/nginx/sites-enabled/$PROD_DOMAIN.conf"
    STG_VHOST="/etc/nginx/sites-enabled/$STG_DOMAIN.conf"
    [[ ! -f "$PROD_VHOST" ]] && PROD_VHOST="/etc/nginx/sites-available/$PROD_DOMAIN.conf" && STG_VHOST="/etc/nginx/sites-available/$STG_DOMAIN.conf"

    if [[ -f "$PROD_VHOST" && -f "$STG_VHOST" ]]; then
        STG_PORT=$(grep "fastcgi_pass" "$STG_VHOST" | awk '{print $2}' | tr -d ';')

        sed -e "s|/home/$SRC_USER/|/home/$STG_USER/|g" \
            -e "s|-$SRC_USER\.sock|-$STG_USER.sock|g" \
            -e "s/$PROD_DOMAIN/$STG_DOMAIN/g" \
            "$PROD_VHOST" > "$STG_VHOST"

        if [[ -n "$STG_PORT" ]]; then
            sed -i "s/fastcgi_pass.*/fastcgi_pass $STG_PORT;/g" "$STG_VHOST"
        fi

        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx
            echo -e "\e[32m[✓]\e[0m Custom Nginx vHost settings copied successfully."
        else
            clpctl site:add:php --domainName="$STG_DOMAIN" --phpVersion="$PHP_VERSION" --vhostTemplate="Generic" --siteUser="$STG_USER" --siteUserPassword="$STG_PASS" >/dev/null 2>&1 || true
            systemctl reload nginx
            echo -e "\e[33m[!]\e[0m Copied vHost failed Nginx tests. Reverted to default template safely."
        fi
    fi

    SAN_LIST=""
    DISPLAY_DOMAINS="$STG_DOMAIN"

    if grep -q "DOMAIN_CURRENT_SITE" "$DEST_DIR/wp-config.php" 2>/dev/null; then
        DB_PREFIX=$(grep -E "^\s*\\\$table_prefix\s*=" "$DEST_DIR/wp-config.php" | awk -F"['\"]" '{print $2}' | head -n1)
        [[ -z "$DB_PREFIX" ]] && DB_PREFIX="wp_"

        SUBS=$(sudo -u "$STG_USER" wp db query "SELECT domain FROM ${DB_PREFIX}blogs;" --skip-column-names --path="$DEST_DIR" 2>/dev/null | tr -d '\r' | grep -v "^$STG_DOMAIN$" || true)

        if [[ -n "$SUBS" ]]; then
            SAN_LIST=$(echo "$SUBS" | sed '/^[[:space:]]*$/d' | paste -sd "," -)
            DISPLAY_DOMAINS="$STG_DOMAIN, $(echo "$SUBS" | sed '/^[[:space:]]*$/d' | paste -sd ", " -)"
        fi
    fi

    echo -e "\n----------------------------------------------------------------------"
    echo -e "⚠️  \e[33mDNS VERIFICATION REQUIRED FOR SSL\e[0m"
    echo -e "To successfully issue Let's Encrypt certificates, the following"
    echo -e "domain(s) MUST be pointed to this server's IP address:"
    echo -e "\n   \e[36m$DISPLAY_DOMAINS\e[0m\n"
    echo -e "If you use Cloudflare, ensure the proxy status is temporarily 'DNS Only'."
    echo -e "----------------------------------------------------------------------"

    trap - EXIT INT TERM

    read -p "Have you pointed the DNS records and want to issue the SSL? (y/n): " ISSUE_SSL

    if [[ "$ISSUE_SSL" =~ ^[Yy]$ ]]; then
        trap cleanup_on_error EXIT INT TERM
        if [[ -n "$SAN_LIST" ]]; then
            execute_with_spinner "Issuing SAN SSL Certificate..." "clpctl lets-encrypt:install:certificate --domainName=\"$STG_DOMAIN\" --subjectAlternativeName=\"$SAN_LIST\"" "true"
        else
            execute_with_spinner "Issuing Standard SSL Certificate..." "clpctl lets-encrypt:install:certificate --domainName=\"$STG_DOMAIN\"" "true"
        fi
    else
        echo -e "\n[i] Skipping SSL certificate issuance. You can do this later via CloudPanel."
    fi

    trap - EXIT INT TERM

    echo -e "\n========================================================"
    echo -e "✅ \e[32mStaging Deployment Complete!\e[0m"
    echo "Staging Domain:  $STG_DOMAIN"
    echo "SSH/SFTP User:   $STG_USER"
    echo "SSH/SFTP Pass:   $STG_PASS"
    if [[ -n "$PROD_DB_NAME" ]]; then
        echo "Database Name:   $STG_DB_NAME"
        echo "Database User:   $STG_DB_USER"
        echo "Database Pass:   $STG_DB_PASS"
        site_type=$(detect_site_type "$DEST_DIR")
        if [[ "$site_type" == "wordpress" ]]; then
            echo -e "\n=> WP Admin Login: Use the SAME username and password as your live site!"
        elif [[ "$site_type" == "laravel" ]]; then
            echo -e "\n=> Laravel: APP_ENV=local, APP_DEBUG=true; APP_KEY copied from live."
        fi
    fi
    echo "========================================================"
}

# ==========================================
# Main entry
# ==========================================
build_site_lists

choose_site "CloudPanel Staging Manager — select an action (filter, arrows, Enter):" MAIN_ACTION \
    "$ACTION_CREATE" "$ACTION_REMOVE" "$ACTION_REFRESH"

if [[ -z "$MAIN_ACTION" ]]; then
    echo -e "\e[31m[ERROR] No action selected. Aborting.\e[0m"
    exit 1
fi

case "$MAIN_ACTION" in
    "$ACTION_CREATE")
        run_create_from_live
        ;;
    "$ACTION_REMOVE")
        run_remove_staging
        ;;
    "$ACTION_REFRESH")
        run_refresh_staging
        ;;
    *)
        echo -e "\e[31m[ERROR] Unknown action. Aborting.\e[0m"
        exit 1
        ;;
esac
