#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh
source lib.sh

# Initiallize session batch file:
echo "Generating session script"
echo "#!/bin/bash" > ${session_sh}
cat resources/host/inputs.sh >> ${session_sh}
# Need this on some systems when running code with ssh
# - CAREFUL! This command can change your ${PWD} directory
echo "source ~/.bashrc" >>  ${session_sh}

if ! [ -z "${resource_jobdir}" ] && ! [[ "${resource_jobdir}" == "default" ]]; then
    echo "mkdir -p ${resource_jobdir}" >> ${session_sh}
    echo "cd ${resource_jobdir}" >> ${session_sh}
fi

if [[ "${use_screen}" == "true" ]]; then
    # Streaming
    # Don't really know the extension of the --pushpath. Can't controll with PBS (FIXME)
    stream_args="--host ${USER_CONTAINER_HOST} --pushpath ${pw_job_dir}/stream.out --pushfile ${resource_jobdir}/logs.out --delay 30 --masterIp ${resource_privateIp}"
    stream_cmd="bash ${resource_jobdir}/stream-${job_number}.sh ${stream_args} &"
    echo; echo "Streaming command:"; echo "${stream_cmd}"; echo
    echo ${stream_cmd} >> ${session_sh}
fi

cat >> ${session_sh} <<HERE
sshusercontainer="ssh ${resource_ssh_usercontainer_options} -f ${USER_CONTAINER_HOST}"

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


# Note that job started running
echo \$$ > ${job_number}.pid

if [ -z "$service_port" ]; then
    # Find an available service_port
    service_port=\$(findAvailablePort)
else
    echo ${service_port} > service.port
fi

echo
echo Starting interactive session - sessionPort: \$service_port tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo
echo
echo "STARTING SERVICE"
echo
HERE


# Add application-specific code
if [ -f "${service_name}/start-template-v3.sh" ]; then
    cat "${service_name}/start-template-v3.sh" >> ${session_sh}
fi

# Note that job is no longer running
echo >> ${session_sh}

chmod +x ${session_sh}