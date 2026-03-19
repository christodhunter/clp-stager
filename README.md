# CloudPanel Stager (`clp-stager`)

A lightweight, interactive Bash script for CloudPanel that clones a production website into a fully functional staging environment in seconds.

It automatically:

1. Provisions a new staging site using the same PHP version as production.

2. Clones the files using a fast `tar` pipeline to preserve integrity.

3. Detects your production database, exports it, and creates a new database for staging.

4. Imports the data into the staging database.

5. Auto-updates Laravel (`.env`) or WordPress (`wp-config.php`) with the new staging database credentials.

6. Asks to issue Let's Encrypt cetificates by listing all the required domains, make sure you've pointed the DNS records before proceeding.

## 🚀 How to Install & Run on Your Server

You don't need to clone this entire repo to your server. You can create and run the script directly via SSH.

### Step 1: Connect to your server

SSH into your CloudPanel server as the `root` user:

```bash
ssh root@your-server-ip

```

### Step 2: Create the script file

Open the `nano` text editor to create the file:

```bash
nano /root/make-staging.sh && chmod +x /root/make-staging.sh

```

Copy the code below, paste it into the `nano` editor, save (CTRL+S), and exit (CTRL+X):

<details>
<summary><strong>Click to expand the Bash Script</strong></summary>

```bash
#!/usr/bin/env bash
# clp-stager: High-Performance Staging Generator for CloudPanel
# Features: Sequential Sync, Hardware-Aware ETA, Bulletproof Multisite, vHost Cloning, Auto-Cleanup

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
get_disk_speed() {
    local target_dir=$1
    local speed=150 # Default to standard SATA SSD (150 MB/s)
    
    # Find the block device where this directory lives
    local device=$(df "$target_dir" | tail -n 1 | awk '{print $1}')
    
    # Check if rotational (1 = HDD, 0 = SSD/NVMe)
    local is_hdd=0
    if command -v lsblk &> /dev/null; then
        is_hdd=$(lsblk -no ROTA "$device" 2>/dev/null | head -n 1 | tr -d ' ')
    fi
    
    if [[ "$is_hdd" == "1" ]]; then
        speed=50  # Slow HDD
    elif [[ "$is_hdd" == "0" ]]; then
        if [[ "$device" == *"nvme"* ]]; then
            speed=300 # Fast NVMe
        else
            speed=150 # Standard SSD
        fi
    fi
    echo "$speed"
}

get_size_estimate() {
    local dir=$1
    if [ -d "$dir" ]; then
        local speed=$(get_disk_speed "$dir")
        local size_mb=$(du -sm "$dir" | cut -f1)
        
        local eta=$(( size_mb / speed ))
        [[ $eta -lt 1 ]] && eta=1
        
        local drive_type="SSD"
        [[ "$speed" == 50 ]] && drive_type="HDD"
        [[ "$speed" == 300 ]] && drive_type="NVMe"
        
        echo "$size_mb MB (~$eta seconds on $drive_type)"
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
            local speed=$(get_disk_speed "/var/lib/mysql")
            # DB exports/imports are CPU/SQL bound, so we estimate they process at half the raw disk speed
            local dump_speed=$(( speed / 2 ))
            [[ $dump_speed -lt 10 ]] && dump_speed=10
            
            local eta=$(( size_mb / dump_speed ))
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
            clpctl db:delete --databaseName="$STG_DB_NAME" >/dev/null 2>&1 || true
        fi
        
        if [ "$STG_DOMAIN_CREATED" = true ] && [[ -n "$STG_DOMAIN" ]]; then
            clpctl site:delete --domainName="$STG_DOMAIN" >/dev/null 2>&1 || true
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
# 1. Fetch Active PHP Sites
# ==========================================
mapfile -t SITES < <(sqlite3 "$DB_PATH" "SELECT domain_name FROM site WHERE type = 'php';")
if [[ ${#SITES[@]} -eq 0 ]]; then
    echo "[ERROR] No PHP sites found in CloudPanel."
    exit 1
fi

# ==========================================
# 2. Interactive Menu
# ==========================================
choose_site() {
    local prompt="Use Up/Down arrows to select the production site, then press Enter:"
    local outvar="PROD_DOMAIN"
    local options=("${SITES[@]}")
    local cur=0
    local count=${#options[@]}
    local index=0
    local esc=$(echo -en "\e")

    echo "$prompt"
    echo -en "\e[?25l" 
    while true; do
        index=0
        for o in "${options[@]}"; do
            if [ "$index" == "$cur" ]; then
                echo -e " > \e[7m$o\e[0m\e[K" 
            else
                echo -e "   $o\e[K"
            fi
            index=$((index + 1))
        done
        
        read -s -n3 key || true
        if [[ $key == $esc[A ]]; then cur=$((cur - 1)); [ $cur -lt 0 ] && cur=$((count - 1));
        elif [[ $key == $esc[B ]]; then cur=$((cur + 1)); [ $cur -ge $count ] && cur=0;
        elif [[ -z $key ]]; then break; fi
        echo -en "\e[${count}A"
    done
    echo -en "\e[?25h" 
    eval $outvar="${options[$cur]}"
}

choose_site
echo -e "\nSelected Production Site: \e[32m$PROD_DOMAIN\e[0m\n"

# ==========================================
# 3. Get Details & Prompts
# ==========================================
SRC_USER=$(sqlite3 "$DB_PATH" "SELECT user FROM site WHERE domain_name = '$PROD_DOMAIN' LIMIT 1;" | tr -d '\r\n')
PHP_VERSION=$(sqlite3 "$DB_PATH" "SELECT php_version FROM php_settings WHERE site_id = (SELECT id FROM site WHERE domain_name = '$PROD_DOMAIN') LIMIT 1;" | tr -d '\r\n')
PROD_DB_NAME=$(sqlite3 "$DB_PATH" "SELECT name FROM database WHERE site_id = (SELECT id FROM site WHERE domain_name = '$PROD_DOMAIN') LIMIT 1;" | tr -d '\r\n')

if [[ -z "$PHP_VERSION" ]]; then
    echo -e "\e[31m[ERROR] Could not determine PHP Version for $PROD_DOMAIN. Aborting.\e[0m"
    exit 1
fi

# Explain the auto-append feature to the user
echo -e "\e[36m[i] Tip: Type just a prefix (e.g., 'stg') to auto-append '.$PROD_DOMAIN', or type a full domain.\e[0m"
read -p "Enter staging prefix or full domain: " STG_DOMAIN

if [[ -z "$STG_DOMAIN" ]]; then echo "[ERROR] Domain required."; exit 1; fi

# If the input doesn't contain a dot, assume it's a prefix and auto-append
if [[ "$STG_DOMAIN" != *"."* ]]; then
    STG_DOMAIN="${STG_DOMAIN}.${PROD_DOMAIN}"
    echo -e "  \e[90m↳ Auto-completed to: $STG_DOMAIN\e[0m"
fi

CLEAN_DOMAIN=$(echo "$STG_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g' | cut -c1-6)
RND_STR=$(openssl rand -hex 2)
STG_USER="stg${CLEAN_DOMAIN}${RND_STR}"
STG_PASS="Stg1!$(openssl rand -hex 6)"

echo ""

# ==========================================
# 4. Provision Site
# ==========================================
CMD="clpctl site:add:php --domainName=\"$STG_DOMAIN\" --phpVersion=\"$PHP_VERSION\" --vhostTemplate=\"Generic\" --siteUser=\"$STG_USER\" --siteUserPassword=\"$STG_PASS\""
execute_with_spinner "Creating CloudPanel site ($STG_DOMAIN) on PHP $PHP_VERSION..." "$CMD"
STG_DOMAIN_CREATED=true

# ==========================================
# 5. Database Migration
# ==========================================
if [[ -n "$PROD_DB_NAME" ]]; then
    STG_DB_NAME="db${CLEAN_DOMAIN}${RND_STR}"
    STG_DB_USER="u${CLEAN_DOMAIN}${RND_STR}"
    STG_DB_PASS=$(openssl rand -hex 16)
    STG_DB_CREATED=true

    DB_ESTIMATE=$(get_db_estimate "$PROD_DB_NAME")
    echo -e "\e[34m[i]\e[0m Database Volume: $DB_ESTIMATE"

    # Build DB Migration Command Sequence
    DB_CMD="clpctl db:export --databaseName=\"$PROD_DB_NAME\" --file=\"/tmp/${PROD_DB_NAME}.sql.gz\" && \
            clpctl db:add --domainName=\"$STG_DOMAIN\" --databaseName=\"$STG_DB_NAME\" --databaseUserName=\"$STG_DB_USER\" --databaseUserPassword=\"$STG_DB_PASS\" && \
            clpctl db:import --databaseName=\"$STG_DB_NAME\" --file=\"/tmp/${PROD_DB_NAME}.sql.gz\" && \
            rm -f \"/tmp/${PROD_DB_NAME}.sql.gz\""
            
    execute_with_spinner "Migrating Database ($PROD_DB_NAME -> $STG_DB_NAME)..." "$DB_CMD"
else
    echo -e "\e[34m[i]\e[0m No production database found. Skipping DB migration."
fi

# ==========================================
# 6. File Migration
# ==========================================
SRC_DIR="/home/$SRC_USER/htdocs/$PROD_DOMAIN"
DEST_DIR="/home/$STG_USER/htdocs/$STG_DOMAIN"

FILE_ESTIMATE=$(get_size_estimate "$SRC_DIR")
echo -e "\e[34m[i]\e[0m File Volume: $FILE_ESTIMATE"

FILE_CMD="tar -C \"$SRC_DIR\" -cf - . | tar -xf - -C \"$DEST_DIR\" && chown -R \"$STG_USER:$STG_USER\" \"$DEST_DIR\""

execute_with_spinner "Copying Site Files and Setting Permissions..." "$FILE_CMD"

# ==========================================
# 7. Config Updates & WP-CLI Search/Replace
# ==========================================
echo -e "\e[32m[✓]\e[0m Updating environment config files..."
if [[ -n "$PROD_DB_NAME" ]]; then
    if [[ -f "$DEST_DIR/wp-config.php" ]]; then
        sed -i "s/define( *'DB_NAME', *'[^']*' *);/define('DB_NAME', '$STG_DB_NAME');/g" "$DEST_DIR/wp-config.php"
        sed -i "s/define( *'DB_USER', *'[^']*' *);/define('DB_USER', '$STG_DB_USER');/g" "$DEST_DIR/wp-config.php"
        sed -i "s/define( *'DB_PASSWORD', *'[^']*' *);/define('DB_PASSWORD', '$STG_DB_PASS');/g" "$DEST_DIR/wp-config.php"
        
        if grep -q "WP_HOME" "$DEST_DIR/wp-config.php"; then
            sed -i "s|define( *'WP_HOME', *'[^']*' *);|define('WP_HOME', 'https://$STG_DOMAIN');|g" "$DEST_DIR/wp-config.php"
            sed -i "s|define( *'WP_SITEURL', *'[^']*' *);|define('WP_SITEURL', 'https://$STG_DOMAIN');|g" "$DEST_DIR/wp-config.php"
        else
            sed -i "/define( *'DB_PASSWORD'/a define('WP_HOME', 'https://$STG_DOMAIN');\ndefine('WP_SITEURL', 'https://$STG_DOMAIN');" "$DEST_DIR/wp-config.php"
        fi

        if grep -q "DOMAIN_CURRENT_SITE" "$DEST_DIR/wp-config.php"; then
            sed -i "s/define( *'DOMAIN_CURRENT_SITE', *'[^']*' *);/define('DOMAIN_CURRENT_SITE', '$STG_DOMAIN');/g" "$DEST_DIR/wp-config.php"
            execute_with_spinner "Multisite Detected: Running deep WP-CLI search-replace..." "sudo -u \"$STG_USER\" wp search-replace \"$PROD_DOMAIN\" \"$STG_DOMAIN\" --network --skip-plugins --skip-themes --path=\"$DEST_DIR\"" "true"
        fi
    elif [[ -f "$DEST_DIR/.env" ]]; then
        sed -i "s/DB_DATABASE=.*/DB_DATABASE=$STG_DB_NAME/g" "$DEST_DIR/.env"
        sed -i "s/DB_USERNAME=.*/DB_USERNAME=$STG_DB_USER/g" "$DEST_DIR/.env"
        sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$STG_DB_PASS/g" "$DEST_DIR/.env"
    fi
fi

# ==========================================
# 8. Clone Custom vHost Edits (Safe Fallback)
# ==========================================
PROD_VHOST="/etc/nginx/sites-enabled/$PROD_DOMAIN.conf"
STG_VHOST="/etc/nginx/sites-enabled/$STG_DOMAIN.conf"
[[ ! -f "$PROD_VHOST" ]] && PROD_VHOST="/etc/nginx/sites-available/$PROD_DOMAIN.conf" && STG_VHOST="/etc/nginx/sites-available/$STG_DOMAIN.conf"

if [[ -f "$PROD_VHOST" && -f "$STG_VHOST" ]]; then
    sed -e "s/$PROD_DOMAIN/$STG_DOMAIN/g" -e "s/$SRC_USER/$STG_USER/g" "$PROD_VHOST" > "$STG_VHOST"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        echo -e "\e[32m[✓]\e[0m Custom Nginx vHost settings copied successfully."
    else
        clpctl site:add:php --domainName="$STG_DOMAIN" --phpVersion="$PHP_VERSION" --vhostTemplate="Generic" --siteUser="$STG_USER" --siteUserPassword="$STG_PASS" >/dev/null 2>&1 || true
        systemctl reload nginx
        echo -e "\e[33m[!]\e[0m Copied vHost failed Nginx tests. Reverted to default template safely."
    fi
fi

# ==========================================
# 9. Multisite DNS Check & SSL Issuance
# ==========================================
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
if [[ -f "$DEST_DIR/wp-config.php" ]]; then
echo -e "\n=> WP Admin Login: Use the SAME username and password as your live site!"
fi
fi
echo "========================================================"
```

</details>


### Step 3: Run the Script

Whenever you want to spin up a staging site, simply run:

```bash
/root/make-staging.sh

```

Use your arrow keys to select the production site, type in your staging domain (e.g., `stg.example.com`), and the script will automatically clone the files and database!
*(Note: Ensure you have pointed your DNS A-Record for your staging domain to your server IP).*

## 🧹 Cleaning Up (Destroying the Staging Site)

Once you are done testing your changes and have pushed them to production, you can easily clean up the staging environment to free up server resources.

You can delete the site and database directly from the **CloudPanel GUI**, or if you prefer the command line, simply run the following two commands (replace `stg.example.com` and `database_name` with the values generated by the script):

```bash
# 1. Delete the database
clpctl db:delete --databaseName=your_staging_database_name

# 2. Delete the staging site and user files
clpctl site:delete --domainName=stg.example.com

```
