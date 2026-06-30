#!/usr/bin/env python3
"""
Wazuh - TheHive Integration Script
Receives Wazuh alerts and creates alerts in TheHive 5 via its API.
"""

import sys
import json
import os
import urllib.request
import urllib.error
import logging
from datetime import datetime

# Configuration
THEHIVE_URL = os.getenv('THEHIVE_URL', 'http://thehive:9000')
THEHIVE_API_KEY = os.getenv('THEHIVE_API_KEY', '')
THEHIVE_API_PATH = '/thehive/api'

# Severity mapping: Wazuh level -> TheHive severity (1=low, 2=medium, 3=high, 4=critical)
def wazuh_to_thehive_severity(wazuh_level):
    if wazuh_level >= 15:
        return 4
    elif wazuh_level >= 10:
        return 3
    elif wazuh_level >= 7:
        return 2
    return 1

def create_thehive_alert(alert):
    """Create an alert in TheHive"""
    
    rule = alert.get('rule', {})
    agent = alert.get('agent', {})
    data = alert.get('data', {})
    
    wazuh_level = rule.get('level', 0)
    rule_id = rule.get('id', 'unknown')
    rule_description = rule.get('description', 'No description')
    
    # Build title
    title = f"[Wazuh] {rule_description}"
    if len(title) > 250:
        title = title[:247] + "..."
    
    # Build description
    description = (
        f"## Wazuh Alert\n\n"
        f"**Rule:** {rule_id} - {rule_description}\n"
        f"**Level:** {wazuh_level}\n"
        f"**Agent:** {agent.get('name', 'unknown')} ({agent.get('ip', 'unknown')})\n"
        f"**Date:** {alert.get('timestamp', 'unknown')}\n"
    )
    
    # Add full alert as JSON in description
    description += f"\n**Full Alert:**\n```json\n{json.dumps(alert, indent=2, default=str)[:3000]}\n```"
    
    # Build artifacts/observables
    artifacts = []
    
    # Add agent IP as observable
    agent_ip = agent.get('ip')
    if agent_ip:
        artifacts.append({
            "dataType": "ip",
            "data": agent_ip,
            "message": f"Agent IP: {agent.get('name', 'unknown')}"
        })
    
    # Add source IP if present
    src_ip = data.get('srcip') or alert.get('srcip') or alert.get('SrcIP')
    if src_ip:
        artifacts.append({
            "dataType": "ip",
            "data": src_ip,
            "message": "Source IP from alert"
        })
    
    # Add file path if present (FIM alerts)
    syscheck = data.get('syscheck', {}) or alert.get('syscheck', {})
    file_path = syscheck.get('path') or data.get('file') or data.get('File')
    if file_path:
        artifacts.append({
            "dataType": "file",
            "data": file_path,
            "message": "File from FIM alert"
        })
    
    # Get timestamp
    timestamp = alert.get('timestamp', datetime.utcnow().isoformat())
    
    # Build TheHive alert payload
    payload = {
        "title": title,
        "description": description,
        "severity": wazuh_to_thehive_severity(wazuh_level),
        "date": int(datetime.utcnow().timestamp() * 1000),
        "tags": ["wazuh", f"rule-{rule_id}", f"level-{wazuh_level}"],
        "type": "wazuh",
        "source": "wazuh",
        "sourceRef": f"wazuh-{rule_id}-{timestamp}",
        "artifacts": artifacts,
        "caseTemplate": None,
        "status": "New"
    }
    
    # Send to TheHive
    url = f"{THEHIVE_URL}{THEHIVE_API_PATH}/alert"
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {THEHIVE_API_KEY}'
    }
    
    req_data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=req_data, headers=headers, method='POST')
    
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            result = json.loads(response.read().decode('utf-8'))
            return True, result.get('_id', 'unknown')
    except urllib.error.HTTPError as e:
        error_body = e.read().decode('utf-8') if e.fp else str(e)
        return False, f"HTTP {e.code}: {error_body[:500]}"
    except Exception as e:
        return False, str(e)

def main():
    logging.basicConfig(level=logging.INFO, 
                       format='%(asctime)s %(levelname)s: %(message)s')
    
    if not THEHIVE_API_KEY:
        logging.error("THEHIVE_API_KEY environment variable not set")
        sys.exit(1)
    
    # Read alert file from argument
    if len(sys.argv) < 2:
        logging.error("No alert file specified")
        sys.exit(1)
    
    alert_file = sys.argv[1]
    
    try:
        with open(alert_file, 'r') as f:
            alert = json.load(f)
    except Exception as e:
        logging.error(f"Failed to read alert file: {e}")
        sys.exit(1)
    
    success, result = create_thehive_alert(alert)
    
    if success:
        logging.info(f"Alert sent to TheHive. ID: {result}")
    else:
        logging.error(f"Failed to send alert: {result}")
        sys.exit(1)

if __name__ == '__main__':
    main()
