---
name: wazuh-manager
description: Use when the user asks about deploying, operando o integrando Wazuh SIEM/XDR — arquitectura (manager/indexer/dashboard), despliegue con Docker/Compose, gestión de agentes, API REST, reglas/decoders custom, y SOAR/threat-intel (VirusTotal, TheHive, Cortex, MISP, Slack/Shuffle). Genérico, no atado a un lab en particular.
---

# wazuh-manager

## Descripción general

Wazuh es una plataforma SIEM/XDR open source con tres componentes:

| Componente | Rol | Puertos típicos |
|------------|-----|------------------|
| **wazuh-manager** | Recibe eventos de agentes, aplica reglas/decoders, dispara integraciones y active response | 1514 (agentes), 1515 (enrollment), 55000 (API REST), 1516 (cluster) |
| **wazuh-indexer** | Almacena e indexa alertas — es OpenSearch por debajo | 9200 (API) |
| **wazuh-dashboard** | UI web — OpenSearch Dashboards + plugin Wazuh | 443/5601 (interno) |
| **wazuh-agent** | Corre en el endpoint monitoreado, envía eventos al manager por el puerto 1514 | — |

Filosofía: el agente recolecta (logs, FIM, rootcheck, syscollector) → el manager decodifica y aplica reglas → los hits de nivel suficiente se indexan y opcionalmente disparan integraciones (VirusTotal, TheHive, Slack, etc.).

## Despliegue con Docker Compose

Patrón estándar de single-node (3 contenedores en una red bridge dedicada, IPs estáticas):

```bash
# 1. Certificados TLS inter-componente (obligatorio, se regeneran si faltan)
curl -sL "https://raw.githubusercontent.com/wazuh/wazuh/v<VERSION>/extensions/certs-tools/wazuh-certs-tool.sh" -o wazuh-certs-tool.sh
chmod +x wazuh-certs-tool.sh
bash wazuh-certs-tool.sh -A   # genera root-ca, y certs de manager/indexer/dashboard/filebeat

# 2. Prerequisito del kernel para OpenSearch
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sysctl.conf
sudo sysctl -p

# 3. Levantar el stack
docker compose up -d

# 4. Verificar salud
docker inspect <indexer> --format '{{.State.Health.Status}}'
docker inspect <dashboard> --format '{{.State.Health.Status}}'
```

**Notas de arquitectura:**
- El indexer necesita RAM dedicada (`OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g` como mínimo) y `memlock` sin límite (`ulimits`)
- El healthcheck del manager corre `wazuh-control status` — si daemons opcionales (`wazuh-clusterd`, `wazuh-maild`) no están activos en single-node, es normal, no significa que el stack esté roto
- El dashboard depende del indexer (`depends_on: condition: service_healthy`) — si el indexer no arranca, el dashboard tampoco lo hará

## Gestión de agentes

### Registro

```bash
# En el endpoint (agente ya instalado)
sudo /var/ossec/bin/agent-auth -m <IP_MANAGER> [-P <password_si_use_password=yes>]
sudo systemctl enable --now wazuh-agent

# Desde el manager (registro manual/offline)
docker exec -i wazuh-manager /var/ossec/bin/manage_agents
# (A) Add agent → (E) Extract key → copiar al agente con manage_agents -i <key>
```

### Consulta y administración

```bash
# Listar agentes y su estado (vía API REST — ver sección siguiente)
curl -k -X GET "https://<manager>:55000/agents?status=active" -H "Authorization: Bearer $TOKEN"

# Ver logs de authd (diagnóstico de registro)
docker exec wazuh-manager tail -f /var/ossec/logs/ossec.log | grep authd

# Reiniciar agente remoto vía API
curl -k -X PUT "https://<manager>:55000/agents/<id>/restart" -H "Authorization: Bearer $TOKEN"
```

## API REST del manager (puerto 55000)

Autenticación Basic → JWT, luego Bearer en cada request:

```bash
TOKEN=$(curl -sk -u wazuh-wui:$API_PASSWORD -X POST "https://<manager>:55000/security/user/authenticate" | jq -r .data.token)

# Endpoints más usados
curl -sk -H "Authorization: Bearer $TOKEN" "https://<manager>:55000/manager/status"        # estado de daemons
curl -sk -H "Authorization: Bearer $TOKEN" "https://<manager>:55000/agents"                # listar agentes
curl -sk -H "Authorization: Bearer $TOKEN" "https://<manager>:55000/rules"                 # reglas cargadas
curl -sk -H "Authorization: Bearer $TOKEN" "https://<manager>:55000/decoders"              # decoders cargados
curl -sk -H "Authorization: Bearer $TOKEN" -X PUT "https://<manager>:55000/manager/restart" # reiniciar manager
```

## Consulta de alertas (indexer / OpenSearch, puerto 9200)

Las alertas no viven en el manager sino en el indexer, en índices `wazuh-alerts-*`:

```bash
# Alertas de las últimas 24h, nivel >= 7, ordenadas por timestamp
curl -sk -u admin:$INDEXER_PASSWORD "https://<indexer>:9200/wazuh-alerts-*/_search" \
  -H 'Content-Type: application/json' -d '{
    "query": { "bool": { "filter": [
      { "range": { "rule.level": { "gte": 7 } } },
      { "range": { "@timestamp": { "gte": "now-24h" } } }
    ]}},
    "sort": [{ "@timestamp": "desc" }],
    "size": 50
  }'
```

## Reglas y decoders custom

```bash
# Ubicación (dentro del contenedor / bajo /var/ossec)
/var/ossec/etc/rules/local_rules.xml       # reglas custom
/var/ossec/etc/decoders/local_decoder.xml  # decoders custom

# Testear una regla antes de desplegar
/var/ossec/bin/wazuh-logtest
```

Patrón mínimo de regla custom:

```xml
<group name="local,custom_group,">
  <rule id="100100" level="10">
    <if_sid>5716</if_sid>
    <match>authentication failed</match>
    <description>Fallo de autenticación repetido — posible brute force</description>
  </rule>
</group>
```

## Integraciones — patrón general

Todas se declaran en `ossec_config` con un bloque `<integration>`:

```xml
<integration>
  <name>NOMBRE</name>          <!-- nativa (virustotal, slack, pagerduty) o custom-* -->
  <api_key>...</api_key>       <!-- si aplica -->
  <level>3</level>             <!-- nivel mínimo de alerta que dispara la integración -->
  <group>syscheck</group>      <!-- opcional: solo alertas de este grupo -->
  <alert_format>json</alert_format>
</integration>
```

Dos tipos:
- **Nativas** (`virustotal`, `slack`, `pagerduty`, `shuffle`, `maltiverse`, etc.): el manager ya trae el script, solo se configura
- **Custom** (`custom-*`): dos archivos en `integrations/`
  - `custom-<nombre>` — wrapper shell que invoca al script real con el python embebido de Wazuh
  - `custom-<nombre>.py` — el script que recibe el JSON de la alerta por stdin/args y llama a la API externa

### Catálogo de referencia (SOAR / threat intel)

| Integración | Qué aporta | Patrón |
|-------------|------------|--------|
| **VirusTotal** | Lookup de hashes detectados por syscheck contra la base de VT | Nativa |
| **TheHive** | Convierte alertas en casos para case management/SOAR | Custom script → API REST de TheHive |
| **Cortex** | Motor de analizadores para TheHive (VT, MISP, abuse.ch, Shodan, etc. corridos automáticamente sobre observables) | Se integra vía TheHive, no directo con Wazuh |
| **MISP** | Feed de IOCs para correlación proactiva (listas `etc/lists/malicious-ioc/*`) o vía Cortex | Actualización periódica de listas, o analizador en Cortex |
| **Slack/Discord** | Notificación en tiempo real de alertas críticas | Nativa (Slack) o custom (Discord/Telegram) |
| **Shuffle** | SOAR de automatización con playbooks visuales | Nativa |

Debuggear si una integración no dispara:

```bash
docker exec wazuh-manager grep -i "integrat" /var/ossec/logs/ossec.log | tail -30
# Debe verse: "Enabling integration for 'X'" al arrancar
# Si no dispara con alertas reales: revisar el <level> del bloque integration vs. el nivel real de la alerta
```

## Troubleshooting común

| Síntoma | Causa probable | Fix |
|---------|-----------------|-----|
| Indexer no arranca / crashea | `vm.max_map_count` insuficiente | `sysctl -w vm.max_map_count=262144` |
| Manager "unhealthy" pero funciona | Daemons opcionales no corren en single-node (`wazuh-clusterd`, `wazuh-maild`) | Normal — verificar `analysisd`/`remoted`/`agentd` con `ps aux` |
| Agente no se registra | `authd` no escucha, o puerto 1515 bloqueado | `docker exec <manager> ps aux \| grep authd`; revisar firewall/red |
| Integración no dispara | `<level>` mal configurado, o script custom sin permisos de ejecución | Revisar logs de `wazuh-integratord`; `chmod +x` en el wrapper |
| Password del indexer perdido | — | `bash hash.sh` en `opensearch-security/tools`, actualizar `internal_users.yml`, `docker compose restart` |
| Dashboard inaccesible | Certificado self-signed rechazado por el browser | Importar `root-ca.pem` al trust store, o acceder por el CN del cert |

## Cheatsheet rápido

```bash
docker ps --filter "name=wazuh"                          # estado de contenedores
docker logs wazuh-manager --tail 100                      # logs del manager
docker exec wazuh-manager tail -f /var/ossec/logs/ossec.log   # log principal en vivo
docker exec wazuh-manager /var/ossec/bin/wazuh-control status # estado de daemons
docker exec -i wazuh-manager /var/ossec/bin/manage_agents     # gestión interactiva de agentes
```
