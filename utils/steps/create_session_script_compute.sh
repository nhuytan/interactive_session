#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh
source lib.sh

# Initiallize session batch file:
echo "Generating session script"
cp resources/host/batch_header.sh ${session_sh}

echo >> ${session_sh}
cat resources/host/inputs.sh >> ${session_sh}

# ADD STREAMING
if [[ "${advanced_options_stream}" != "false" ]]; then
    # Don't really know the extension of the --pushpath. Can't controll with PBS (FIXME)
    stream_args="--host ${USER_CONTAINER_HOST} --pushpath ${pw_job_dir}/stream.out --pushfile logs.out --delay 30 --masterIp ${resource_privateIp}"
    stream_cmd="bash stream-${job_number}.sh ${stream_args} &"
    echo; echo "Streaming command:"; echo "${stream_cmd}"; echo
    echo ${stream_cmd} >> ${session_sh}
fi

cat >> ${session_sh} <<HERE
# In case the job directory is not shared between the controller and compute nodes
mkdir -p ${resource_jobdir}
cd ${resource_jobdir}

echo \$SLURM_JOB_ID > job.id
hostname > target.hostname

echo "Running in host \$(hostname)"
sshusercontainer="ssh ${resource_ssh_usercontainer_options} -f ${USER_CONTAINER_HOST}"
ssh ${resource_ssh_usercontainer_options} -f ${USER_CONTAINER_HOST} hostname

displayErrorMessage() {
    echo \$(date): \$1
    exit 1
}

findAvailablePort() {
    availablePort=\$(pw agent open-port)
    echo \${availablePort}
    if [ -z "\${availablePort}" ]; then
        availablePort=ERROR
        echo ERROR > service.port
        displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
    fi
    echo \${availablePort} > service.port 
}

cd ${resource_jobdir}
set -x

# Find an available service_port. Could be anywhere in the form (<section_name>_service_port)
service_port=$(env | grep service_port | cut -d'=' -f2)
if [ -z "\${service_port}" ]; then
    service_port=\$(findAvailablePort)
fi
echo \${service_port} > service.port

echo
echo Starting interactive session - sessionPort: \$service_port tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

echo "Exit code: \$?"
echo "Starting session..."

rm -f \${portFile}
HERE

# Add application-specific code
if [ -f "${service_name}/start-template-v3.sh" ]; then
    cat ${service_name}/start-template-v3.sh >> ${session_sh}
fi

# move the session file over
chmod +x ${session_sh}

