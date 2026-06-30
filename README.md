# Wazuh Home Lab 🛡️

> Single-node Wazuh SIEM/XDR stack deployed with Docker Compose for home lab and learning purposes.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Docker Host                             │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ wazuh.manager│  │ wazuh.indexer│  │ wazuh.dashboard  │   │
│  │   (SIEM)     │  │ (OpenSearch) │  │  (Dashboards)    │   │
│  │   4.14.5     │  │   4.14.5     │  │    4.14.5        │   │
│  │ 172.20.0.10  │  │ 172.20.0.20  │  │  172.20.0.30     │   │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘   │
│         │                 │                    │            │
│         └─────────────────┴────────────────────┘            │
│                         wazuh-net                           │
│                      (172.20.0.0/16)                        │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Wazuh Agent (Arch Linux)                │   │
│  │              Monitors the Docker host                │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

| Component | IP | Ports | Description |
|-----------|----|-------|-------------|
| **wazuh.manager** | 172.20.0.10 | 1514 (agents), 1515 (enrollment), 55000 (API) | SIEM engine — rules, alerts, agent management |
| **wazuh.indexer** | 172.20.0.20 | 9200 (OpenSearch API) | Storage & indexing — based on OpenSearch |
| **wazuh.dashboard** | 172.20.0.30 | 8443 (HTTPS) | Web UI — OpenSearch Dashboards + Wazuh plugin |

## Prerequisites

- **Docker Engine** (not Docker Desktop) with Compose plugin
- **At least 4 GB RAM** allocated to Docker (8 GB recommended)
- **`vm.max_map_count`** set to at least 262144:

```bash
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sysctl.conf
sudo sysctl -p
```

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/lcampassi/wazuh-homelab.git
cd wazuh-homelab
```

### 2. Generate SSL certificates

```bash
bash scripts/wazuh-certs-tool.sh -A
```

> Generates certificates for inter-component TLS communication in `config/wazuh_indexer_ssl_certs/`.

### 3. Deploy the stack

```bash
docker compose up -d
```

This starts three containers:
- `wazuh-manager`
- `wazuh-indexer`
- `wazuh-dashboard`

### 4. Access the dashboard

Open your browser at **https://localhost:8443**

Default credentials (change immediately after first login):
- **User:** `admin`
- **Password:** `admin`

> ⚠️ **Certificate warning**: The dashboard uses a self-signed certificate. If your browser blocks the connection, you can either:
> - Add the root CA to your system trust store:
>   ```bash
>   sudo cp config/wazuh_indexer_ssl_certs/root-ca.pem /etc/ca-certificates/trust-source/anchors/wazuh-root-ca.crt
>   sudo trust extract-compat
>   ```
> - Or access via the certificate's CN: add `127.0.0.1 wazuh.dashboard` to your `/etc/hosts` and browse to `https://wazuh.dashboard:8443`

### 5. Deploy an agent on the host

```bash
# Install the agent (Arch Linux)
paru -S wazuh-agent

# Register with the manager
sudo /var/ossec/bin/agent-auth -m 127.0.0.1 -P wazuh-agent-pass

# Start the agent
sudo systemctl enable --now wazuh-agent
```

> For other operating systems, check the [official Wazuh documentation](https://documentation.wazuh.com/current/installation-guide/wazuh-agent/index.html).

## Customization

### Network

The stack uses a dedicated Docker bridge network `wazuh-net` (172.20.0.0/16) with static IPs:

| Container | Static IP |
|-----------|-----------|
| wazuh.manager | 172.20.0.10 |
| wazuh.indexer | 172.20.0.20 |
| wazuh.dashboard | 172.20.0.30 |

### Dashboard port

The dashboard is published on port **8443** (instead of the default 443) to avoid conflicts with other services. The internal port is 5601:

```yaml
ports:
  - "8443:5601"
```

### Passwords

Sensitive passwords are set via environment variables in `docker-compose.yml`. The following credentials should be changed:

| Variable | Default | Description |
|----------|---------|-------------|
| `INDEXER_PASSWORD` | `SecretPassword` | OpenSearch admin user |
| `API_PASSWORD` | `MyS3cr37P450r.*-` | Wazuh API user (wazuh-wui) |
| `DASHBOARD_PASSWORD` | `kibanaserver` | Dashboard internal user |

To change them:
1. Update the passwords in `docker-compose.yml`
2. Update the hashed passwords in `config/wazuh_indexer/internal_users.yml`
3. Restart the stack: `docker compose restart`

## Integrations

### VirusTotal

The manager is configured with a native VirusTotal integration for file hash lookups via syscheck:

```xml
<integration>
  <name>virustotal</name>
  <api_key>VT_API_KEY</api_key>
  <group>syscheck</group>
  <alert_format>json</alert_format>
</integration>
```

**Status:** ✅ Functional — `wazuh-integratord` reports "Enabling integration for 'virustotal'". Alerts are triggered when syscheck detects files with hashes matching VirusTotal's database.

### TheHive (SOAR / Case Management)

A custom Python integration forwards Wazuh alerts (level ≥ 3) to TheHive 5:

```xml
<integration>
  <name>custom-thehive</name>
  <level>3</level>
  <alert_format>json</alert_format>
</integration>
```

The integration script reads `THEHIVE_URL` and `THEHIVE_API_KEY` from environment variables set in `docker-compose.yml`.

**Files:**
- `config/integrations/custom-thehive` — Shell wrapper (Wazuh calls this)
- `config/integrations/custom-thehive.py` — Python script (forwards alerts to TheHive API)

**Service user in TheHive:**
- Login: `wazuh-final@thehive.local`
- Profile: `analyst` (has `manageAlert/create`, `manageCase/create`, etc.)
- API key set via `THEHIVE_API_KEY` env var

> **⚠️ Known limitation:** TheHive 5's `testing` Docker profile has a permission issue where Organisation-type profiles (`analyst`, `org-admin`) show correct permissions in queries but cannot perform mutation operations (create alerts/cases) via the REST API. This is a profile initialization issue in the testing profile — using the `prod1-thehive` profile resolves it. See [[MAN-001244]] for details.

## Project Structure

```
wazuh/
├── docker-compose.yml              # Stack definition
├── .env                            # Environment variables
├── README.md                       # This file
├── config/
│   ├── wazuh_cluster/
│   │   └── wazuh_manager.conf      # Custom ossec.conf for the manager
│   ├── wazuh_indexer/
│   │   ├── wazuh.indexer.yml       # OpenSearch configuration
│   │   └── internal_users.yml      # OpenSearch users (hashed passwords)
│   ├── wazuh_dashboard/
│   │   ├── opensearch_dashboards.yml  # Dashboard configuration
│   │   └── wazuh.yml                  # Wazuh plugin configuration
│   ├── integrations/                # Custom integration scripts (TheHive, etc.)
│   └── wazuh_indexer_ssl_certs/    # SSL certificates (auto-generated)
├── scripts/
│   └── wazuh-certs-tool.sh         # Certificate generation script
├── volumes/                        # Docker volume mount points
├── certs/                          # Additional certificates (optional)
├── assets/                         # Screenshots, diagrams, etc.
└── docs/                           # Additional documentation
```

## Troubleshooting

### Dashboard is unreachable

```bash
# Check container status
docker ps --filter "name=wazuh"

# View dashboard logs
docker logs wazuh-dashboard

# Test direct access inside container
docker exec wazuh-dashboard curl -sk https://localhost:5601/
```

### Manager health shows "unhealthy"

The healthcheck checks all wazuh daemons. Optional daemons (like `wazuh-clusterd`, `wazuh-maild`) may not be running in a single-node setup, which is normal. Core SIEM functionality (analysisd, remoted, agentd) works correctly.

### Agent registration fails

```bash
# Check authd logs on manager
docker exec wazuh-manager tail -f /var/ossec/logs/ossec.log | grep authd

# Verify authd is running
docker exec wazuh-manager ps aux | grep authd

# Manually add agent
docker exec -i wazuh-manager /var/ossec/bin/manage_agents
# Use option (A) to add, then (E) to extract key
```

### Reset admin password

```bash
docker exec -it wazuh-indexer bash
cd /usr/share/wazuh-indexer/plugins/opensearch-security/tools
bash hash.sh
# Enter new password, copy the hash
# Edit internal_users.yml with the new hash
docker compose restart
```

## Upgrading

1. Backup volumes:
   ```bash
   docker compose down
   docker run --rm -v wazuh_wazuh-etc:/etc -v $(pwd)/backup:/backup alpine cp -r /etc /backup/
   ```
2. Update the version tag in `docker-compose.yml` and `.env`
3. Pull new images: `docker compose pull`
4. Restart: `docker compose up -d`

## License

This project is for educational purposes. Wazuh is licensed under GPL-2.0.
