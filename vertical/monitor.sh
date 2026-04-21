#!/bin/bash
OUTPUT_FILE=$1

echo "Timestamp,Container,CPU_Perc,Mem_Usage,Net_IO" > $OUTPUT_FILE

while true; do
	TS=$(date +%s)
	docker stats --no-stream --format "$TS,{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.NetIO}}" >> $OUTPUT_FILE
	sleep 5
done

