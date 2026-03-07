# CloudPanel Stager (`clp-stager`)

A lightweight, interactive Bash script for CloudPanel that clones a production website into a fully functional staging environment in seconds. 

It automatically:
1. Provisions a new staging site using the same PHP version as production.
2. Clones the files using a fast `tar` pipe to preserve integrity.
3. Detects your production database, exports it, and creates a new database for staging.
4. Imports the data into the staging database.
5. Auto-updates Laravel (`.env`) or WordPress (`wp-config.php`) with the new staging database credentials.

## 🚀 How to Install & Run on Your Server

You don't need to clone this entire repo to your server. You can create and run the script directly via SSH.

### Step 1: Connect to your server
SSH into your CloudPanel server as the `root` user:
```bash
ssh root@your-server-ip
