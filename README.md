# CloudPanel Stager (`clp-stager`)

A lightweight, interactive Bash script for CloudPanel that clones a production website into a fully functional staging environment in seconds.

It automatically:

1. Provisions a new staging site using the same PHP version as production.

2. Clones the files using a fast `tar` pipeline to preserve integrity.

3. Detects your production database, exports it, and creates a new database for staging.

4. Imports the data into the staging database.

5. Auto-updates Laravel (`.env`) or WordPress (`wp-config.php`) with the new staging database credentials.

## 🚀 How to Install & Run on Your Server

You don't need to clone this entire repo to your server. You can create and run the script directly via SSH.

### Step 1: Connect to your server

SSH into your CloudPanel server as the `root` user:

```bash
ssh root@your-server-ip

```

### Step 2: Create the script file

Open the `nano` text editor to create the script file and automatically make it executable when you save and exit:

```bash
nano /root/make-staging.sh && chmod +x /root/make-staging.sh

```

### Step 3: Paste the Script

Copy the code below, paste it into the `nano` editor, save (CTRL+O, Enter), and exit (CTRL+X):

<details>
<summary><strong>Click to expand the Bash Script</strong></summary>

```bash
#!/usr/bin/env bash
# clp-stager: CloudPanel Staging Site & Database Generator

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

# 1. Fetch Active PHP Sites
mapfile -t SITES < <(sqlite3 "$DB_PATH" "SELECT domain_name FROM site WHERE type = 'php';")
if [[ ${#SITES[@]} -eq 0 ]]; then
    echo "[ERROR] No PHP sites found in CloudPanel."
    exit 1
fi

# 2. Interactive Menu
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
        
        # Capture input and prevent set -e from killing the script
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

# 3. Get Details & Prompt
SRC_INFO=$(sqlite3 "$DB_PATH" "SELECT s.user, p.php_version FROM site s JOIN php_settings p ON s.id = p.site_id WHERE s.domain_name = '$PROD_DOMAIN';")
IFS='|' read -r SRC_USER PHP_VERSION <<< "$SRC_INFO"

PROD_DB_INFO=$(sqlite3 "$DB_PATH" "SELECT d.name, du.user_name FROM database d JOIN site s ON d.site_id = s.id JOIN database_user du ON d.id = du.database_id WHERE s.domain_name = '$PROD_DOMAIN' LIMIT 1;")
IFS='|' read -r PROD_DB_NAME PROD_DB_USER <<< "$PROD_DB_INFO"

read -p "Enter staging domain (e.g., stg.example.com): " STG_DOMAIN
if [[ -z "$STG_DOMAIN" ]]; then echo "[ERROR] Domain required."; exit 1; fi

# Generate safe, short alphanumeric names guaranteed to pass CloudPanel validation
CLEAN_DOMAIN=$(echo "$STG_DOMAIN" | sed 's/[^a-zA-Z0-9]//g' | cut -c1-8)
STG_USER="stg${CLEAN_DOMAIN}"
STG_PASS=$(openssl rand -hex 16)

# 4. Provision Site & Database
echo -e "\n[+] Creating CloudPanel site ($STG_DOMAIN) on PHP $PHP_VERSION..."
clpctl site:add:php --domainName="$STG_DOMAIN" --phpVersion="$PHP_VERSION" --vhostTemplate="Generic" --siteUser="$STG_USER" --siteUserPassword="$STG_PASS"

if [[ -n "$PROD_DB_NAME" ]]; then
    STG_DB_NAME="${STG_USER}_db"
    STG_DB_USER="${STG_USER}_usr"
    STG_DB_PASS=$(openssl rand -hex 16)

    echo "[+] Exporting production database ($PROD_DB_NAME)..."
    clpctl db:export --databaseName="$PROD_DB_NAME" --file="/tmp/${PROD_DB_NAME}.sql.gz"

    echo "[+] Creating staging database ($STG_DB_NAME)..."
    clpctl db:add --domainName="$STG_DOMAIN" --databaseName="$STG_DB_NAME" --databaseUserName="$STG_DB_USER" --databaseUserPassword="$STG_DB_PASS"

    echo "[+] Importing data into staging database..."
    clpctl db:import --databaseName="$STG_DB_NAME" --file="/tmp/${PROD_DB_NAME}.sql.gz"
    rm -f "/tmp/${PROD_DB_NAME}.sql.gz"
fi

# 5. File Migration
SRC_DIR="/home/$SRC_USER/htdocs/$PROD_DOMAIN"
DEST_DIR="/home/$STG_USER/htdocs/$STG_DOMAIN"

echo "[+] Cloning files via tar..."
tar -cf "/tmp/stg_backup.tar" -C "$SRC_DIR" .
mv "/tmp/stg_backup.tar" "$DEST_DIR/"
cd "$DEST_DIR"
tar -xf "stg_backup.tar"
rm "stg_backup.tar"
chown -R "$STG_USER:$STG_USER" "$DEST_DIR"

# 6. Config Updates
if [[ -n "$PROD_DB_NAME" ]]; then
    echo "[+] Updating database credentials in config files..."
    if [[ -f "$DEST_DIR/wp-config.php" ]]; then
        sed -i "s/define( *'DB_NAME', *'[^']*' *);/define('DB_NAME', '$STG_DB_NAME');/g" "$DEST_DIR/wp-config.php"
        sed -i "s/define( *'DB_USER', *'[^']*' *);/define('DB_USER', '$STG_DB_USER');/g" "$DEST_DIR/wp-config.php"
        sed -i "s/define( *'DB_PASSWORD', *'[^']*' *);/define('DB_PASSWORD', '$STG_DB_PASS');/g" "$DEST_DIR/wp-config.php"
    elif [[ -f "$DEST_DIR/.env" ]]; then
        sed -i "s/DB_DATABASE=.*/DB_DATABASE=$STG_DB_NAME/g" "$DEST_DIR/.env"
        sed -i "s/DB_USERNAME=.*/DB_USERNAME=$STG_DB_USER/g" "$DEST_DIR/.env"
        sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$STG_DB_PASS/g" "$DEST_DIR/.env"
    fi
fi

echo -e "\n========================================================"
echo -e "✅ \e[32mStaging Deployment Complete!\e[0m"
echo "Staging Domain:  $STG_DOMAIN"
echo "Site/SSH User:   $STG_USER"
echo "Site Password:   $STG_PASS"
if [[ -n "$PROD_DB_NAME" ]]; then
echo "Database Name:   $STG_DB_NAME"
echo "Database User:   $STG_DB_USER"
echo "Database Pass:   $STG_DB_PASS"
fi
echo "========================================================"

```

</details>


### Step 4: Run the Script

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
