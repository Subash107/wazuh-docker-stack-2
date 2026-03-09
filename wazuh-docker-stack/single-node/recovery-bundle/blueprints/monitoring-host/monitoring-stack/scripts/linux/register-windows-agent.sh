#!/bin/bash
# This script registers the Windows Wazuh agent with the manager
# It should be run on the Ubuntu system in the context of the Wazuh manager

MANAGER_PATH="/var/ossec"
AGENT_NAME="Windows-Monitoring"
AGENT_IP="192.168.1.7"

# Check if we're running with proper permissions
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root"
   exit 1
fi

echo "Registering Windows agent..."
echo "Agent Name: $AGENT_NAME"
echo "Agent IP: $AGENT_IP"
echo ""

# Use manage_agents to add the agent
# This will generate the keys that need to be put in the Windows agent
output=$(/var/ossec/bin/manage_agents -a -n "$AGENT_NAME" -i "$AGENT_IP")
echo "Manager output:"
echo "$output"

# Extract the agent ID from the output
AGENT_ID=$(echo "$output" | grep -o "Agent ID.*key.*" | head -1 | grep -o "[0-9]\{3\}")

if [ -z "$AGENT_ID" ]; then
    # Try alternative parsing
    AGENT_ID=$(echo "$output" | grep -o "ID[^:]*ID [0-9]\+" | tail -1 | grep -o "[0-9]\+")
fi

echo ""
echo "Agent ID: $AGENT_ID"
echo ""

# Display the client.keys file entry
if [ ! -z "$AGENT_ID" ]; then
    echo "Agent registration complete!"
    echo "Agent ID is: $AGENT_ID"
    
    # Show what to put in the Windows client.keys file
    echo ""
    echo "The Windows agent client.keys should contain an entry for this agent."
    echo "Please use the Wazuh dashboard or API to retrieve the full key."
else
    echo "Could not extract agent ID from registration output"
fi
