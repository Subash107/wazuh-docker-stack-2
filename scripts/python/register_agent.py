#!/usr/bin/env python3
"""
Register a Windows agent with Wazuh manager via REST API
"""
import json
import os
import requests
import urllib3
from urllib3.exceptions import InsecureRequestWarning

# Disable SSL warnings for self-signed certificates
urllib3.disable_warnings(InsecureRequestWarning)

# Configuration
WAZUH_API_URL = os.getenv("WAZUH_API_URL", "https://192.168.1.7:55000")
WAZUH_USER = os.getenv("WAZUH_USER", "wazuh-wui")
WAZUH_PASS = os.getenv("WAZUH_PASS", "")
AGENT_NAME = os.getenv("AGENT_NAME", "Windows-Monitoring")
AGENT_IP = os.getenv("AGENT_IP", "192.168.1.7")

def register_agent():
    """Register the Windows agent with Wazuh manager"""

    if not WAZUH_PASS:
        print("[-] Set WAZUH_PASS before running this script.")
        return False
    
    # Disable SSL verification for demo purposes
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)
    
    try:
        # Step 1: Authenticate
        print("[*] Authenticating to Wazuh API...")
        auth_url = f"{WAZUH_API_URL}/security/user/authenticate"
        auth_payload = {
            "user": WAZUH_USER,
            "password": WAZUH_PASS
        }
        
        response = requests.post(
            auth_url,
            json=auth_payload,
            verify=False,
            timeout=10
        )
        
        if response.status_code != 200:
            print(f"[-] Authentication failed: {response.status_code}")
            print(f"    Response: {response.text}")
            return False
        
        token = response.json()["data"]["token"]
        print("[+] Authentication successful")
        
        # Step 2: Check if agent already exists
        print(f"[*]Checking for existing agent '{AGENT_NAME}'...")
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        }
        
        agents_url = f"{WAZUH_API_URL}/agents?pretty=true&q=name={AGENT_NAME}"
        response = requests.get(agents_url, headers=headers, verify=False, timeout=10)
        
        existing_agents = response.json()["data"]["affected_items"]
        if existing_agents:
            print(f"[!] Agent already exists")
            agent_id = existing_agents[0]["id"]
            print(f"    Agent ID: {agent_id}")
            return True
        
        # Step 3: Add new agent
        print(f"[*] Registering new agent...")
        add_agent_url = f"{WAZUH_API_URL}/agents"
        agent_payload = {
            "name": AGENT_NAME,
            "ip": AGENT_IP
        }
        
        response = requests.post(
            add_agent_url,
            headers=headers,
            json=agent_payload,
            verify=False,
            timeout=10
        )
        
        if response.status_code not in [200, 201]:
            print(f"[-] Failed to add agent: {response.status_code}")
            print(f"    Response: {response.text}")
            return False
        
        result = response.json()["data"]
        agent_id = result.get("id")
        agent_key = result.get("key")
        
        print(f"[+] Agent registered successfully!")
        print(f"    Agent ID: {agent_id}")
        print(f"    Agent Name: {AGENT_NAME}")
        print(f"    Agent IP: {AGENT_IP}")
        
        if agent_key:
            print(f"    Agent Key: {agent_key}")
        
        return True
        
    except requests.exceptions.ConnectionError as e:
        print(f"[-] Connection error: {e}")
        return False
    except Exception as e:
        print(f"[-] Error: {e}")
        return False

if __name__ == "__main__":
    success = register_agent()
    exit(0 if success else 1)
