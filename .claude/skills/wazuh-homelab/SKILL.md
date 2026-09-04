---
name: wazuh-homelab
description: Skill de proyecto para ESTE homelab de Wazuh (docker-compose single-node en /files/VMs/DOCKER/wazuh) — topología exacta, comandos de operación (setup.sh, certs, agentes), integraciones activas (VirusTotal, TheHive) y su estado, y roadmap. Usar junto con `wazuh-manager` (conocimiento genérico) para cualquier tarea de gestión/consulta de este lab en particular.
---

# wazuh-homelab

Skill de proyecto — complementa a `wazuh-manager` (genérico) con los datos concretos de **este** lab. Cargar ambos cuando la tarea sea sobre este repo.

## Topología de este lab

| Contenedor | IP fija | Puertos publicados | Rol |
|------------|---------|---------------------|-----|
| `wazuh-manager` | 172.20.0.10 | 1514, 1515, 55000 | SIEM engine |
| `wazuh-indexer` | 172.20.0.20 | 9200 | OpenSearch — almacenamiento de alertas |
| `wazuh-dashboard` | 172.20.0.30 | 8443→5601 | UI web (HTTPS) |

Red: `wazuh-net`, bridge Docker, subnet `172.20.0.0/16`, gateway `172.20.0.1` (ese gateway es también la IP del host Docker vista desde dentro de los contenedores — relevante para `THEHIVE_URL`, ver abajo).

- Dashboard: `https://localhost:8443` (self-signed cert — importar `config/wazuh_indexer_ssl_certs/root-ca.pem` o usar el CN `wazuh.dashboard`)
- Un solo agente registrado hoy: el host Arch Linux (ver roadmap — falta variedad de endpoints)

## Operación del stack

```bash
cd /files/VMs/DOCKER/wazuh

./setup.sh                          # deploy completo: checks + certs + up -d + healthcheck
bash scripts/wazuh-certs-tool.sh -A # solo (re)generar certs si hace falta
docker compose up -d                # levantar sin pasar por setup.sh
docker compose down                 # bajar el stack
docker compose restart              # tras cambiar passwords o config
docker ps --filter "name=wazuh"     # estado de los 3 contenedores
```

Archivos de configuración clave:
- `config/wazuh_cluster/wazuh_manager.conf` → `ossec.conf` del manager (reglas, syscheck, integraciones)
- `config/wazuh_indexer/internal_users.yml` → usuarios/passwords hasheados de OpenSearch
- `config/wazuh_dashboard/wazuh.yml` → config del plugin Wazuh en el dashboard
- `docker-compose.yml` → env vars con passwords y API keys de integraciones (ver advertencia abajo)

## Integraciones activas

### VirusTotal — ✅ funcional
Nativa, vía syscheck, configurada en `config/wazuh_cluster/wazuh_manager.conf` (bloque `<integration><name>virustotal</name>`). La API key vive ahí mismo y en `docker-compose.yml`.

### TheHive — ⚠️ funcional con limitación conocida
- Alertas nivel ≥3 → forwarded a TheHive 5 como casos
- Archivos: `config/integrations/custom-thehive` (wrapper shell) + `custom-thehive.py` (script real)
- Env vars en `docker-compose.yml`: `THEHIVE_URL` (apunta a `172.20.0.1:9000`, o sea el host Docker — TheHive corre fuera de este compose) y `THEHIVE_API_KEY`
- Usuario de servicio en TheHive: `wazuh-final@thehive.local`, perfil `analyst`
- **Limitación:** el perfil `testing` de TheHive 5 no deja hacer mutaciones (crear alertas/casos) con perfiles Organisation aunque las queries de permisos den bien. Workaround: usar perfil `prod1-thehive`. Ver detalle en `MAN-001244` (referenciado en el README).

Debug rápido de integraciones en este lab:
```bash
docker exec wazuh-manager grep -i "integrat" /var/ossec/logs/ossec.log | tail -30
docker exec wazuh-manager cat /var/ossec/logs/integrations.log 2>/dev/null | tail -50
```

## ⚠️ Nota de seguridad

Los secretos rotables (`INDEXER_PASSWORD`, `DASHBOARD_PASSWORD`, `API_PASSWORD`) fueron rotados el 2026-09-04 y sacados de los archivos trackeados — ahora viven en `.env` (gitignored, ver `.env.example`), interpolados en `docker-compose.yml` con `${VAR}`. `VT_API_KEY` (en `wazuh_manager.conf`) y `THEHIVE_API_KEY` **no se pudieron rotar** (requieren sesión externa que el agente no tiene) — se sacaron de git con un placeholder pero la key real sigue activa en runtime. El historial de git del repo público (commit `141dee1` y anteriores) sigue exponiendo los valores viejos — pendiente de reescritura de historia, requiere confirmación explícita del usuario antes de hacerla. Detalle completo en `progress.md`.

Para integraciones nuevas (Cortex, MISP): usar `.env` + `${VAR}` desde el principio, nunca texto plano en archivos trackeados.

### Bind mounts: mismatch de filesystem agente↔host

Editar archivos bind-monteados (`internal_users.yml`, `wazuh_manager.conf`, `wazuh.yml` del dashboard, etc.) desde las herramientas de archivo del agente **no llega al contenedor real** — el agente y el host Docker de este lab tienen filesystems separados para esas rutas, aunque el path absoluto coincida. Para escribir contenido real en un archivo bind-monteado: `docker exec -i <container> sh -c 'cat > <path_en_el_container>'` pasando el contenido por **stdin** (nunca interpolado en la línea de comando — corrompe valores con `$`). Esto escribe sobre el archivo físico real y sobrevive a un `--force-recreate` del contenedor. Las env vars de `docker-compose.yml` no tienen este problema (viajan directo al daemon).

## Roadmap (ver `progress.md` en la raíz del repo)

Próximas integraciones en orden de naturalidad: Cortex (analizadores para TheHive) → MISP → Suricata/Zeek (NIDS) → más agentes/endpoints → Vulnerability Detection module → reglas Sigma → alerting externo → backups de volúmenes.

## Troubleshooting específico de este lab

Ver sección "Troubleshooting" del `README.md` (reset de password del indexer, agente que no registra, dashboard inaccesible) — son los mismos pasos genéricos de `wazuh-manager` pero con los nombres de contenedor exactos: `wazuh-manager`, `wazuh-indexer`, `wazuh-dashboard`.
