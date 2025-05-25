# FnOS Automated ACME Certificate Management (Docker)

Based on **[acme.sh](https://github.com/acmesh-official/acme.sh)** + Docker  
Designed for the FnOS system:
1. Automatically renew SSL certificates for FnOS, write `valid_to` and `issued_by` back to a PostgreSQL database, achieving **one script to manage everything**.
2. Automatically generate `.pfx` certificates for easy deployment and updates in applications like Jellufin.

---

## Features

| Feature            | Description |
| ------------------ | ----------- |
| **[Multiple CA Options](https://github.com/acmesh-official/acme.sh/wiki/Server)** | Built-in short names for common ACME CAs such as LetsEncrypt, ZeroSSL, BuyPass, SSL.com, Google Public CA, etc. |
| **[Multiple DNS APIs](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)** | Support for Tencent Cloud, Alibaba Cloud, Cloudflare, and any `acme.sh --dns` plugin. |
| **Containerized**  | Only one lightweight `acme.sh` container is required, zero dependencies on the host system. |
| **Auto Renewal**   | Executes based on `SCHEDULE_INTERVAL`; automatically renews certificates with ≤ 7 days remaining. |
| **Database Sync**  | Writes `valid_to` and `issued_by` back to the `trim_connect.cert` table. |
| **One‑click .pfx** | Generates `.pfx` for specified domains and copies to the target directory. |
| **Friendly Logs**  | Full logging in `./log/first_run.log` & `./log/cer_update.log`. |

---

## Project Structure

```
.
├── acme/                  # Contains acme.sh scripts and container configuration
│   ├── docker-compose.yml  # Docker Compose configuration
│   └── cer_update.sh       # Main certificate update script
├── LICENSE                # License file
├── README.md              # This file (Chinese version)
└── README_en.md           # This file (English version)
```

## Quick Start

1. **Deploy Docker Container**

   Use the `acme/docker-compose.yml` file in the project root to build the container. Update the `volumes:` parameter to map to your local `acme` directory. For example, if your `acme` folder is at `/vol1/1000/docker/acme`, map it as:

   ```yaml
   version: '3'
   services:
     acme.sh:
       image: neilpang/acme.sh
       container_name: acme.sh
       restart: always
       network_mode: host
       volumes:
         - /vol1/1000/docker/acme/acme.sh:/acme.sh
       command: daemon
   ```

2. **First Run to Create Configuration**

   ```bash
   # SSH into FnOS console and switch to root
   sudo -i
   cd /path/to/acme
   chmod 755 ./cer_update.sh
   ./cer_update.sh
   ```

   - Follow prompts to select the CA server, registration email, DNS provider, etc.
   - After generating `config.ini`, edit it and set `TEST_MODE=1` to enable test mode.

3. **Validate Configuration and Issue Test Certificates**

   ```bash
   ./cer_update.sh
   ```

   - Run again to generate test certificates under `./acme.sh/`. Download the generated `.cer` and `ca.cer` files and manually deploy them in FnOS if needed.

4. **Test Full Workflow**

   ```bash
   ./cer_update.sh
   ```

   - It’s recommended to use `letsencrypt_test` in test mode to avoid hitting rate limits.
   - Once everything works without errors, switch off test mode.

5. **Switch to Production Mode**

   - Edit `config.ini` and set `TEST_MODE=0` (disable test mode).
   - Run again:

     ```bash
     ./cer_update.sh
     ```

   - The script will now periodically check and renew certificates before expiration.

## Example Configuration (`config.ini`)

```ini
CA_SERVER=letsencrypt
REG_EMAIL=your-email@example.com

# API Configuration
PROVIDER=Tencent
DNS_PROVIDER=dns_tencent
PARAM_NAMES=Tencent_SecretId,Tencent_SecretKey
Tencent_SecretId=your_tencent_secret_id
Tencent_SecretKey=your_tencent_secret_key

# Runtime Parameters
ACME_PREFIX=/vol1/1000/docker/acme/
DOMAINS1_RAW=www.example1.com,www.example2.com
DOMAINS2_RAW=www.example3.com,www.example4.com
PASSWORD=123456789a
PFX_DIR=   # leave empty to skip copying, only generate under ./acme.sh/

# Execution Interval (format x年x月x天x时x分)
# Default: execute at 00:00 on the 1st of every month. Setting all zeros will remove the cron entry.
SCHEDULE_INTERVAL=0年1月1天0时0分

# Test Mode: 1=skip expiry check, 0=perform expiry check
TEST_MODE=0
```

## Logs

- First-run log: `./log/first_run.log`
- Execution log: `./log/cer_update.log`

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
