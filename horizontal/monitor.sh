#!/bin/bash

# 1. Define the PATH so background processes can actually find Docker
PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/snap/bin

# 2. Safety Check: Ensure a filename is passed from the master script
if [ -z "$1" ]; then
    echo "Error: Please provide an output filename."
    exit 1
fi

# 3. Write the CSV header to the file
echo "timestamp,container,cpu_perc,mem_usage,mem_limit,mem_perc,net_io,block_io,pids" > "$1"

# 4. Loop forever, fetching Docker stats every 5 seconds and appending to the CSV
while true; do
    sudo docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}" | awk -v date="$(date +%s)" '{print date "," $0}' >> "$1"
    sleep 5
done