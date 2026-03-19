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
# clp-stager: CloudPanel Staging Site Generator (Multisite SAN SSL, Progress Tracking & Auto-Cleanup)

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
# AUTO-CLEANUP (ROLLBACK) ON ERROR
# ==========================================
STG_DOMAIN_CREATED=false
STG_DB_CREATED=false
STG_DOMAIN=""
STG_DB_NAME=""
PROD_DB_NAME=""

cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n\e[31m[!] ERROR ENCOUNTERED (Exit code $exit_code). INITIATING ROLLBACK...\e[0m"
        
        if [[ -n "$PROD_DB_NAME" && -f "/tmp/${PROD_DB_NAME}.sql.gz" ]]; then
            echo "    -> Removing dangling database export..."
            rm -f "/tmp/${PROD_DB_NAME}.sql.gz"
        fi
        
        if [[ -f "/tmp/stg_backup.tar" ]]; then
            echo "    -> Removing dangling file backup..."
            rm -f "/tmp/stg_backup.tar"
        fi
        
        if [ "$STG_DB_CREATED" = true ] && [[ -n "$STG_DB_NAME" ]]; then
            echo "    -> Deleting incomplete staging database ($STG_DB_NAME)..."
            clpctl db:delete --databaseName="$STG_DB_NAME" >/dev/null 2>&1 || true
        fi
        
        if [ "$STG_DOMAIN_CREATED" = true ] && [[ -n "$STG_DOMAIN" ]]; then
            echo "    -> Deleting incomplete staging site ($STG_DOMAIN)..."
            clpctl site:delete --domainName="$STG_DOMAIN" >/dev/null 2>&1 || true
        fi
        
        echo -e "\e[32m[✓] Cleanup complete. Your server is clean.\e[0m"
    fi
    exit $exit_code
}
# Trap catches ERR and EXIT. If it exits with non-zero, the rollback triggers.
trap cleanup_on_error EXIT

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
    while true; do
        index=0
        for o in "${options[@]}"; do
            if [ "$index" == "$cur" ]; then
                echo -e " > \e[7m$o\e[0m"
            else
                echo -e "   $o"
            fi
            index=$((index + 1))
        done
        
        read -s -n3 key || true
        
        if [[ $key == $esc[A ]]; then 
            cur=$((cur - 1))
            if [ $cur -lt 0 ]; then cur=$((count - 1)); fi
        elif [[ $key == $esc[B ]]; then 
            cur=$((cur + 1))
            if [ $cur -ge $count ]; then cur=0; fi
        elif [[ -z $key ]]; then 
            break
        fi
        echo -en "\e[${count}A"
    done
    eval $outvar="${options[$cur]}"
}

choose_site
echo -e "\nSelected Production Site: \e[32m$PROD_DOMAIN\e[0m\n"

# ==========================================
# 3. Get Details & Prompts (Safely)
# ==========================================
# Fetching properties separately ensures no variable shifting if a column is NULL
SRC_USER=$(sqlite3 "$DB_PATH" "SELECT user FROM site WHERE domain_name = '$PROD_DOMAIN';")
PHP_VERSION=$(sqlite3 "$DB_PATH" "SELECT php_version FROM php_settings WHERE site_id = (SELECT id FROM site WHERE domain_name = '$PROD_DOMAIN');")
VHOST_TEMPLATE=$(sqlite3 "$DB_PATH" "SELECT vhost_template FROM site WHERE domain_name = '$PROD_DOMAIN';" 2>/dev/null || true)

# Failsafes
if [[ -z "$PHP_VERSION" ]]; then
    echo -e "\e[31m[ERROR] Could not determine PHP Version for $PROD_DOMAIN. Aborting.\e[0m"
    exit 1
fi
if [[ -z "$VHOST_TEMPLATE" ]]; then
    VHOST_TEMPLATE="Generic"
fi

PROD_DB_NAME=$(sqlite3 "$DB_PATH" "SELECT name FROM database WHERE site_id = (SELECT id FROM site WHERE domain_name = '$PROD_DOMAIN') LIMIT 1;")

read -p "Enter staging domain (e.g., stg.example.com): " STG_DOMAIN
if [[ -z "$STG_DOMAIN" ]]; then echo "[ERROR] Domain required."; exit 1; fi

CLEAN_DOMAIN=$(echo "$STG_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g' | cut -c1-6)
RND_STR=$(openssl rand -hex 2)
STG_USER="stg${CLEAN_DOMAIN}${RND_STR}"
STG_PASS=$(openssl rand -hex 16)

# ==========================================
# 4. Provision Site
# ==========================================
echo -e "\n\e[36m[Step 1/8]\e[0m Creating CloudPanel site ($STG_DOMAIN) on PHP $PHP_VERSION..."
clpctl site:add:php --domainName="$STG_DOMAIN" --phpVersion="$PHP_VERSION" --vhostTemplate="$VHOST_TEMPLATE" --siteUser="$STG_USER" --siteUserPassword="$STG_PASS"
STG_DOMAIN_CREATED=true

# ==========================================
# 5. Database Export & Import
# ==========================================
if [[ -n "$PROD_DB_NAME" ]]; then
    STG_DB_NAME="db${CLEAN_DOMAIN}${RND_STR}"
    STG_DB_USER="u${CLEAN_DOMAIN}${RND_STR}"
    STG_DB_PASS=$(openssl rand -hex 16)

    echo -e "\e[36m[Step 2/8]\e[0m Exporting production database ($PROD_DB_NAME)..."
    clpctl db:export --databaseName="$PROD_DB_NAME" --file="/tmp/${PROD_DB_NAME}.sql.gz"

    echo -e "\e[36m[Step 3/8]\e[0m Creating staging database ($STG_DB_NAME)..."
    clpctl db:add --domainName="$STG_DOMAIN" --databaseName="$STG_DB_NAME" --databaseUserName="$STG_DB_USER" --databaseUserPassword="$STG_DB_PASS"
    STG_DB_CREATED=true

    echo -e "\e[36m[Step 4/8]\e[0m Importing data into staging database..."
    clpctl db:import --databaseName="$STG_DB_NAME" --file="/tmp/${PROD_DB_NAME}.sql.gz"
    rm -f "/tmp/${PROD_DB_NAME}.sql.gz"
else
    echo -e "\e[36m[Step 2-4/8]\e[0m No database found for $PROD_DOMAIN. Skipping DB setup..."
fi

# ==========================================
# 6. File Migration
# ==========================================
SRC_DIR="/home/$SRC_USER/htdocs/$PROD_DOMAIN"
DEST_DIR="/home/$STG_USER/htdocs/$STG_DOMAIN"

echo -e "\e[36m[Step 5/8]\e[0m Cloning files via tar..."
tar -cf "/tmp/stg_backup.tar" -C "$SRC_DIR" .
mv "/tmp/stg_backup.tar" "$DEST_DIR/"
cd "$DEST_DIR"
tar -xf "stg_backup.tar"
rm "stg_backup.tar"
chown -R "$STG_USER:$STG_USER" "$DEST_DIR"

# ==========================================
# 7. Config Updates & WP-CLI Search/Replace
# ==========================================
echo -e "\e[36m[Step 6/8]\e[0m Updating config files and databases..."
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

        # Multisite Detection
        if grep -q "DOMAIN_CURRENT_SITE" "$DEST_DIR/wp-config.php"; then
            echo "    -> WordPress Multisite detected! Updating network configuration..."
            sed -i "s/define( *'DOMAIN_CURRENT_SITE', *'[^']*' *);/define('DOMAIN_CURRENT_SITE', '$STG_DOMAIN');/g" "$DEST_DIR/wp-config.php"
            echo "    -> Running WP-CLI search-replace across all subsites..."
            sudo -u "$STG_USER" wp search-replace "$PROD_DOMAIN" "$STG_DOMAIN" --network --path="$DEST_DIR" || echo "    -> [WARNING] WP-CLI search-replace encountered an issue."
        fi

    elif [[ -f "$DEST_DIR/.env" ]]; then
        sed -i "s/DB_DATABASE=.*/DB_DATABASE=$STG_DB_NAME/g" "$DEST_DIR/.env"
        sed -i "s/DB_USERNAME=.*/DB_USERNAME=$STG_DB_USER/g" "$DEST_DIR/.env"
        sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$STG_DB_PASS/g" "$DEST_DIR/.env"
    fi
fi

# ==========================================
# 8. Clone Custom vHost Edits
# ==========================================
echo -e "\e[36m[Step 7/8]\e[0m Cloning custom Nginx configurations..."
PROD_VHOST="/etc/nginx/sites-enabled/$PROD_DOMAIN.conf"
STG_VHOST="/etc/nginx/sites-enabled/$STG_DOMAIN.conf"

if [[ ! -f "$PROD_VHOST" ]]; then
    PROD_VHOST="/etc/nginx/sites-available/$PROD_DOMAIN.conf"
    STG_VHOST="/etc/nginx/sites-available/$STG_DOMAIN.conf"
fi

if [[ -f "$PROD_VHOST" && -f "$STG_VHOST" ]]; then
    sed -e "s/$PROD_DOMAIN/$STG_DOMAIN/g" \
        -e "s/$SRC_USER/$STG_USER/g" \
        "$PROD_VHOST" > "$STG_VHOST"
        
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        echo "    -> Custom vHost settings copied successfully."
    else
        echo "    -> [WARNING] Copied vHost caused an Nginx error. Reverting to default template."
        clpctl site:add:php --domainName="$STG_DOMAIN" --phpVersion="$PHP_VERSION" --vhostTemplate="$VHOST_TEMPLATE" --siteUser="$STG_USER" --siteUserPassword="$STG_PASS" >/dev/null 2>&1 || true
        systemctl reload nginx
    fi
fi

# ==========================================
# 9. Multisite DNS Check & SSL Issuance
# ==========================================
echo -e "\n\e[36m[Step 8/8]\e[0m Preparing SSL Configuration..."

SAN_LIST=""
DISPLAY_DOMAINS="$STG_DOMAIN"

if sudo -u "$STG_USER" wp core is-installed --network --path="$DEST_DIR" 2>/dev/null; then
    echo "    -> Analyzing Multisite network for subdomains..."
    SUBS=$(sudo -u "$STG_USER" wp site list --field=domain --path="$DEST_DIR" 2>/dev/null | tr -d '\r' | grep -v "^$STG_DOMAIN$" || true)
    
    if [[ -n "$SUBS" ]]; then
        SAN_LIST=$(echo "$SUBS" | paste -sd "," -)
        DISPLAY_DOMAINS="$STG_DOMAIN, $(echo "$SUBS" | paste -sd ", " -)"
    fi
fi

echo -e "\n----------------------------------------------------------------------"
echo -e "⚠️  \e[33mDNS VERIFICATION REQUIRED FOR SSL\e[0m"
echo -e "To successfully issue Let's Encrypt certificates, the following"
echo -e "domain(s) MUST be pointed to this server's IP address:"
echo -e "\n   \e[36m$DISPLAY_DOMAINS\e[0m\n"
echo -e "If you use Cloudflare, ensure the proxy status is temporarily 'DNS Only'."
echo -e "----------------------------------------------------------------------"

# Disable the error trap temporarily during user input so Ctrl+C cancels nicely without throwing ugly rollback logic if they haven't finished the prompt
trap - EXIT 

read -p "Have you pointed the DNS records and want to issue the SSL? (y/n): " ISSUE_SSL

if [[ "$ISSUE_SSL" =~ ^[Yy]$ ]]; then
    echo -e "\n[+] Issuing Let's Encrypt SSL Certificate..."
    if [[ -n "$SAN_LIST" ]]; then
        clpctl lets-encrypt:install:certificate --domainName="$STG_DOMAIN" --subjectAlternativeName="$SAN_LIST" || echo "    -> [WARNING] SSL Issuance failed. Ensure DNS for ALL subdomains points to this server."
    else
        clpctl lets-encrypt:install:certificate --domainName="$STG_DOMAIN" || echo "    -> [WARNING] SSL Issuance failed. Check your DNS records."
    fi
else
    echo -e "\n[i] Skipping SSL certificate issuance. You can do this later via CloudPanel."
fi

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
