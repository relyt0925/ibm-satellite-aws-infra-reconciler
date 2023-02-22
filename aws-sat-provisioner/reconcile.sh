#!/usr/bin/env bash
# ASSUMES LOGGED INTO APPROPRIATE IBM CLOUD ACCOUNT: TO DO THAT AUTOMATICALLY
# ibmcloud login -a https://cloud.ibm.com --apikey XXXX -r us-south
set +x
source config.env
set -x
export LOCATION_ID=aws-location-demo
core_machinegroup_reconcile() {
	export EC2_INSTANCE_DATA=/tmp/ec2instancedata.txt
	if ! aws ec2 describe-instances --filters "$UNIQUE_TAG_QUERY" >$EC2_INSTANCE_DATA; then
		continue
	fi
	if ! jq '.Reservations[].Instances' $EC2_INSTANCE_DATA; then
		TOTAL_INSTANCES=0
	else
		TOTAL_INSTANCES=$(jq '.Reservations[].Instances | length' $EC2_INSTANCE_DATA | awk '{sum=sum+$0} END{print sum}')
	fi
	if ((COUNT > TOTAL_INSTANCES)); then
		NUMBER_TO_SCALE=$((COUNT - TOTAL_INSTANCES))
		if [[ -n "$HOST_LINK_AGENT_ENDPOINT" ]]; then
      IGN_FILE_PATH=$(bx sat host attach --location "$LOCATION_ID" --operating-system "RHCOS" --host-label "$HOST_LABELS" --host-link-agent-endpoint "$HOST_LINK_AGENT_ENDPOINT" | grep "register-host")
    else
      IGN_FILE_PATH=$(bx sat host attach --location "$LOCATION_ID" --operating-system "RHCOS" --host-label "$HOST_LABELS" | grep "register-host")
    fi
		if [[ "$IGN_FILE_PATH" != *".ign" ]]; then
			continue
		fi
    if ! aws ec2 run-instances --count $NUMBER_TO_SCALE --instance-type ${INSTANCE_TYPE} --launch-template LaunchTemplateName=${AWS_RHCOS_LAUNCH_TEMPLATE} --user-data file://${IGN_FILE_PATH} --tag-specifications ${TAG}; then
      echo "failed"
    fi
	fi
}

remove_dead_machines() {
	for row in $(cat "$HOSTS_DATA_FILE" | jq -r '.[] | @base64'); do
		_jq() {
			# shellcheck disable=SC2086
			echo "${row}" | base64 --decode | jq -r ${1}
		}
		HEALTH_STATE=$(_jq '.health.status')
		NAME=$(_jq '.name')
		if [[ "$HEALTH_STATE" == "reload-required" ]]; then
			INSTANCE_DATA_FILE_PATH=/tmp/rminstancedata.json
			if ! aws ec2 describe-instances --filters Name=network-interface.private-dns-name,Values=${NAME}.ec2.internal >"$INSTANCE_DATA_FILE_PATH"; then
				continue
			fi
			INSTANCE_ID=$(jq -r '.Reservations[0].Instances[0].InstanceId' "$INSTANCE_DATA_FILE_PATH")
			if [[ -n "$INSTANCE_ID" ]] && [[ "$INSTANCE_ID" != "null" ]]; then
				if ! aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}"; then
					continue
				fi
			fi
			ibmcloud sat host rm --location "$LOCATION_ID" --host "$NAME" -f
		fi
	done
}

while true; do
	sleep 10
	echo "reconcile workload"
	export LOCATION_LIST_FILE=/tmp/location-lists.txt
	export HOSTS_DATA_FILE=/tmp/${LOCATION_ID}-hosts-data.txt
	export SERVICES_DATA_FILE=/tmp/${LOCATION_ID}-services-data.txt
	if ! bx sat locations >$LOCATION_LIST_FILE; then
  		continue
  fi
  if ! grep "$LOCATION_ID" /tmp/location-lists.txt; then
    bx sat location create --name "$LOCATION_ID" --coreos-enabled --managed-from wdc
  fi
	if ! bx sat hosts --location $LOCATION_ID --output json >$HOSTS_DATA_FILE; then
		continue
	fi
	if ! bx sat services --location $LOCATION_ID >$SERVICES_DATA_FILE; then
		continue
	fi
	remove_dead_machines
	for FILE in worker-pool-metadata/*/*; do
		CLUSTERID=$(echo ${FILE} | awk -F '/' '{print $(NF-1)}')
		if [[ "$FILE" == *"control-plane"* ]]; then
			source $FILE
			core_machinegroup_reconcile
			# ensure machines assigned
			while true; do
				if ! bx sat host assign --location "$LOCATION_ID" --zone "$ZONE" --host-label os=RHCOS --host-label "$HOST_LABELS"; then
					break
				fi
				sleep 5
				continue
			done
		else
			CLUSTERID=$(echo ${FILE} | awk -F '/' '{print $(NF-1)}')
			WORKER_POOL_NAME=$(echo ${FILE} | awk -F '/' '{print $NF}' | awk -F '.' '{print $1}')
			source $FILE
			if ! grep $CLUSTERID $SERVICES_DATA_FILE; then
				if ! bx cs cluster create satellite --name $CLUSTERID --location "$LOCATION_ID" --version 4.11_openshift --operating-system RHCOS; then
					continue
				fi
			fi
			WORKER_POOL_FILE=/tmp/worker-pool-info.txt
			if ! bx cs worker-pools --cluster $CLUSTERID >$WORKER_POOL_FILE; then
				continue
			fi
			if ! grep "$WORKER_POOL_NAME" $WORKER_POOL_FILE; then
				bx cs worker-pool create satellite --name $WORKER_POOL_NAME --cluster $CLUSTERID --zone ${ZONE} --size-per-zone "$COUNT" --host-label "$HOST_LABELS" --operating-system RHCOS
			fi
			if ! bx cs worker-pool resize --cluster $CLUSTERID --worker-pool $WORKER_POOL_NAME --size-per-zone "$COUNT"; then
				continue
			fi
			core_machinegroup_reconcile
			while true; do
				if ! bx sat host assign --location "$LOCATION_ID" --cluster "$CLUSTERID" --host-label os=RHCOS --host-label "$HOST_LABELS"; then
					break
				fi
				sleep 5
				continue
			done
		fi
	done
done
