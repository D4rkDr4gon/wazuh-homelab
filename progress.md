# Progress & Roadmap — Wazuh Home Lab

> Seguimiento de estado y plan de trabajo. Complementa al README (que documenta cómo usar lo que ya existe).

## Estado actual (2026-09-04)

### Seguridad — rotación de secretos (2026-09-04)

Se detectaron API keys/passwords en texto plano committeadas al repo público. Estado de la remediación:

| Secreto | Acción |
|---------|--------|
| `INDEXER_PASSWORD` (OpenSearch `admin`) | ✅ Rotado y verificado en vivo (`securityadmin.sh`) |
| `DASHBOARD_PASSWORD` (OpenSearch `kibanaserver`) | ✅ Rotado y verificado en vivo |
| `API_PASSWORD` (Wazuh API `wazuh-wui`) | ✅ Rotado vía API REST (`PUT /security/users/{id}`), `config/wazuh_dashboard/wazuh.yml` actualizado en runtime |
| `VT_API_KEY` (VirusTotal) | ⚠️ No rotable por el agente (requiere sesión web de VT) — sacada de git, placeholder en `wazuh_manager.conf`, key real sigue activa en runtime |
| `THEHIVE_API_KEY` | ⚠️ No rotable por el agente (TheHive detenido, sin sesión admin) — movida a `.env` (gitignored), valor original preservado |

Todos los secretos rotables ahora viven en `.env` (gitignored, ver `.env.example`); `docker-compose.yml` los interpola con `${VAR}`. **Pendiente:** el historial de git del repo público sigue exponiendo los valores viejos (commit `141dee1` y anteriores) — requiere reescritura de historia (BFG/git-filter-repo + force-push), no ejecutada porque es destructiva para cualquier clon existente y necesita confirmación explícita antes de hacerla.

### Hallazgo operacional: mismatch de filesystem

El entorno del agente y el host Docker real de este lab **no comparten el mismo filesystem** para las rutas bind-mounteadas, aunque el path absoluto sea idéntico (`/files/VMs/DOCKER/wazuh/...`). Editar un archivo desde las herramientas del agente NO se refleja en el bind mount real que usan los contenedores. Workaround usado: escribir el contenido directo dentro del contenedor vía `docker exec -i <container> sh -c 'cat > <path>'` (con stdin, nunca embebiendo el contenido en la línea de comando) — esto sí escribe sobre el archivo físico real detrás del mount y sobrevive a un recreate del contenedor. Las env vars de `docker-compose.yml`, en cambio, sí se aplican correctamente porque viajan directo al daemon (no vía bind mount).

## Estado actual (2026-09-03)

| Área | Estado | Notas |
|------|--------|-------|
| Stack base (manager/indexer/dashboard) | ✅ Funcional | Docker Compose, IPs estáticas en `wazuh-net` |
| `setup.sh` (deploy automatizado) | ✅ Funcional | Checks de prerequisitos + certs + deploy + healthcheck |
| Agente en host (Arch Linux) | ✅ Funcional | Único endpoint monitoreado hasta ahora |
| Integración VirusTotal | ✅ Funcional | Syscheck → lookup de hashes |
| Integración TheHive (SOAR) | ⚠️ Funcional con limitación | Perfil `testing` bloquea mutaciones de perfiles Organisation; usar `prod1-thehive` o bridge |

## Roadmap de integraciones

Ordenado por qué tan natural es el siguiente paso dado lo que ya hay.

### 1. Cortex (analizadores para TheHive) — *siguiente paso lógico*
Ya tenés TheHive recibiendo alertas como casos. Cortex es el motor de analizadores de TheHive: permite correr automáticamente VirusTotal, MISP, abuse.ch, Shodan, etc. sobre los observables de cada caso, sin intervención manual. Cierra el ciclo alerta → caso → enriquecimiento automático.

### 2. MISP (threat intelligence feed)
Alimentar Wazuh/TheHive con IOCs de feeds públicos (o propios). Con Cortex ya en el medio, MISP se integra naturalmente como analizador/fuente. Habilita correlación proactiva en vez de solo reactiva.

### 3. Suricata o Zeek (NIDS)
Wazuh es fuerte en host-based (HIDS) pero no ve tráfico de red. Sumar Suricata/Zeek en el mismo Docker host, con sus logs ingeridos por Wazuh vía `wodle` o Filebeat, agrega visibilidad de red (escaneos, C2, exfiltración) que hoy el lab no tiene.

### 4. Más agentes / endpoints reales
Hoy solo hay un agente (el host Arch). Sumar 1-2 endpoints más (una VM Windows, un contenedor Linux dedicado a "víctima") da telemetría variada para practicar detección — sin eso, gran parte de las reglas de Wazuh nunca se disparan con datos reales.

### 5. Wazuh Vulnerability Detection module
Módulo nativo de Wazuh (ya en 4.x) para detectar CVEs en paquetes instalados de los agentes. Bajo costo de activación, alto valor — no requiere infraestructura nueva, solo config.

### 6. Reglas/decoders custom + Sigma
Escribir reglas propias (`local_rules.xml`) para los escenarios que se practiquen, y evaluar convertir reglas Sigma públicas al formato Wazuh. Hay skill de referencia (`building-detection-rules-with-sigma`).

### 7. Alerting externo (Slack/Discord/Telegram)
Wrapper simple de integración (similar al de TheHive) para notificaciones en tiempo real de alertas críticas, sin tener que estar mirando el dashboard.

### 8. Backups automatizados
`setup.sh` cubre el deploy pero no hay estrategia de backup de volúmenes (indexer data, config). Con varias integraciones corriendo, perder el estado duele más — conviene resolverlo antes de sumar más piezas, no después.

## Agente/skills para gestionar el lab

Objetivo: poder decirle a Claude Code "revisá las alertas de las últimas 24h", "el agente X está caído, diagnosticá", "levantá el stack", "agregá una regla para detectar Y" — sin tener que recordar comandos de memoria cada vez.

**Piezas a construir:**

1. **Skill de proyecto (`.claude/skills/`) scopeada a este repo** — no un skill genérico, sino uno atado a *este* homelab: conoce las IPs estáticas, los puertos, dónde están los certs, cómo correr `setup.sh`, cómo leer `ossec.log`, cómo pegarle a la API REST del manager (puerto 55000) para listar agentes/alertas/reglas. Es la pieza central: convierte "gestionar el lab" en comandos repetibles en vez de que cada sesión redescubra la topología.

2. **Reusar `atenea` (agente blue-team) para consumo/triage** — ya existe como subagente en este entorno, cubre SIEM/logs/forense. En vez de crear un agente nuevo desde cero, tiene sentido que `atenea` use el skill de punto 1 como su "manual" de este lab específico cuando el usuario pida analizar alertas o investigar un hallazgo.

3. **Wrapper de la API de Wazuh** — funciones concretas que el skill debe exponer (vía curl/script, no hace falta MCP dedicado todavía):
   - Autenticación (Basic Auth → JWT) contra `https://wazuh.manager:55000`
   - Listar agentes y su estado (`GET /agents`)
   - Consultar alertas recientes (vía indexer/OpenSearch API, puerto 9200, con los índices `wazuh-alerts-*`)
   - Reiniciar servicios (`PUT /manager/restart`)
   - Gestión de reglas/decoders custom

4. **Skill de salud/diagnóstico** — encapsular lo que hoy está en la sección "Troubleshooting" del README (healthcheck del indexer/dashboard, logs de authd, reset de password) como pasos que el agente ejecuta solo en vez de que el usuario copie comandos del README.

**Orden sugerido:** primero el skill de proyecto (punto 1) con las operaciones básicas de health/consulta, después conectarlo a `atenea` para triage, y recién ahí sumar la API wrapper más completa (punto 3) a medida que se necesiten operaciones más finas.

## Próximos pasos inmediatos

- [ ] Decidir con qué ítem del roadmap de integraciones arrancar (recomendado: Cortex, por ser la continuación directa de TheHive)
- [ ] Armar el skill de proyecto para gestión del lab (punto 1 de la sección anterior)
- [ ] Sumar al menos un segundo agente/endpoint con datos reales para validar reglas
