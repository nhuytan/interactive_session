
if [ -z ${service_novnc_parent_install_dir} ]; then
    service_novnc_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_port}" ]; then
    displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
fi

if ! [ -f ${/etc/pki/tls/private/kasmvnc.pem} ]; then
    # FIXME: Only run if kasmvnc is not installed!
    wget https://github.com/kasmtech/KasmVNC/releases/download/v1.3.2/kasmvncserver_oracle_8_1.3.2_x86_64.rpm
    sudo dnf localinstall ./kasmvncserver_*.rpm --allowerasing -y 
    rm ./kasmvncserver_*.rpm
    expect -c 'spawn vncpasswd -u '"${USER}"' -w -r; expect "Password:"; send "password\r"; expect "Verify:"; send "password\r"; expect eof'
    sudo usermod -a -G kasmvnc-cert $USER
    sudo chown $USER /etc/pki/tls/private/kasmvnc.pem
fi


# Find an available display port
if [[ $kernel_version == *microsoft* ]]; then
    # In windows only this port works
    displayPort=8444
else
    minPort=8444
    maxPort=8499
    for port in $(seq ${minPort} ${maxPort} | shuf); do
        out=$(netstat -aln | grep LISTEN | grep ${port})
        if [ -z "${out}" ]; then
            # To prevent multiple users from using the same available port --> Write file to reserve it
            portFile=/tmp/${port}.port.used
            if ! [ -f "${portFile}" ]; then
                touch ${portFile}
                export displayPort=${port}
                displayNumber=$((port - 8443))
                export DISPLAY=:${displayNumber#0}
                break
            fi
        fi
    done
fi


echo "Starting nginx wrapper on service port ${service_port}"

mkdir certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout certs/postfix.key \
    -out certs/postfix.crt \
    -subj "/C=US/ST=IL/L=Chicago/O=Parallel Works/OU=Applications/CN=alvaro@parallelworks.com"

chmod 644 certs/*

# Write config file
cat >> config.conf <<HERE
 server {
    listen ${service_port} ssl;
    server_name cloud.parallel.works;
    
    ssl_certificate /etc/nginx/certs/postfix.crt;
    ssl_certificate_key /etc/nginx/certs/postfix.key;

    # The following configurations must be configured when proxying to Kasm Workspaces

    # WebSocket Support
    proxy_set_header        Upgrade \$http_upgrade;
    proxy_set_header        Connection "upgrade";

    # Host and X headers
    proxy_set_header        Host \$host;
    proxy_set_header        X-Real-IP \$remote_addr;
    proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;

    proxy_set_header Authorization \$http_authorization;
    proxy_pass_header  Authorization;
    proxy_set_header Authorization "";
    proxy_set_header X-Forwarded-User \$remote_user;

    # Connectivity Options
    proxy_http_version      1.1;
    proxy_read_timeout      1800s;
    proxy_send_timeout      1800s;
    proxy_connect_timeout   1800s;
    proxy_buffering         off;

    # Allow large requests to support file uploads to sessions
    client_max_body_size 10M;

    # Default location block for root access
    # Location block for 10.34.x.x IPs
    location / {
        # Check if the request is from the 10.34.x.x range
        set $is_10_34 0;
        if ($remote_addr ~ ^10\.34\.) {
            set $is_10_34 1;
        }

        # Proxy requests from 10.34.x.x to 127.0.0.1:8459
        if ($is_10_34 = 1) {
            proxy_pass https://127.0.0.1:8459/;  # Trailing slash to preserve request path
        }

        # Optionally handle requests from other IPs here
        # For example, return a 403 Forbidden status:
        # return 403;  
    }

    # Location block for /sme/${openPort}
    location /sme/${openPort}/ {
        # Proxy to Kasm Workspaces running locally on 8444 using ssl
        proxy_pass https://127.0.0.1:${displayPort}/;  # Trailing slash to preserve request path
    }
 }
HERE

if [[ "${resource_type}" == "existing" ]] || [[ "${resource_type}" == "slurmshv2" ]]; then
    echo "Running singularity container ${service_nginx_sif}"
    # We need to mount $PWD/tmp:/tmp because otherwise nginx writes the file /tmp/nginx.pid 
    # and other users cannot use the node. Was not able to change this in the config.conf.
    mkdir -p ./tmp
    # Need to overwrite default configuration!
    touch empty
    singularity run -B $PWD/tmp:/tmp -B $PWD/config.conf:/etc/nginx/conf.d/config.conf -B empty:/etc/nginx/conf.d/default.conf -B $PWD/certs:/etc/nginx/certs ${service_nginx_sif} &
    pid=$!
    echo "kill ${pid}" >> ${resource_jobdir}/service-kill-${job_number}-main.sh
else
    container_name="nginx-${service_port}"
    # Remove container when job is canceled
    echo "sudo docker stop ${container_name}" >> ${resource_jobdir}/service-kill-${job_number}-main.sh
    echo "sudo docker rm ${container_name}" >> ${resource_jobdir}/service-kill-${job_number}-main.sh
    # Start container
    sudo service docker start
    touch empty
    sudo docker run  -d --name ${container_name} \
         -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
         -v $PWD/empty:/etc/nginx/conf.d/default.conf \
         -v $PWD/certs:/etc/nginx/certs \
         --network=host nginxinc/nginx-unprivileged:1.25.3
    # Print logs
    sudo docker logs ${container_name}
fi


# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh
echo "Creating file ${resource_jobdir}/service-kill-${job_number}-main.sh from directory ${PWD}"
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo "bash ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
else
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
fi

expect -c 'spawn vncpasswd -u '"${USER}"' -w -r; expect "Password:"; send "password\r"; expect "Verify:"; send "password\r"; expect eof'
sudo usermod -a -G kasmvnc-cert $USER


vncserver -kill ${DISPLAY}
echo "vncserver -kill ${DISPLAY}" >> ${resource_jobdir}/service-kill-${job_number}-main.sh
vncserver ${DISPLAY} -disableBasicAuth -select-de gnome
rm -rf ${portFile}

# Notify platform that service is running
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

# Reload env in case it was deactivated in the step above (e.g.: conda activate)
eval "${service_load_env}"

# Launch service
cd
if ! [ -z "${service_bin}" ]; then
    if [[ ${service_background} == "False" ]]; then
        echo "Running ${service_bin}"
        eval ${service_bin}
    else
        echo "Running ${service_bin} in the background"
        eval ${service_bin} &
        echo $! >> ${resource_jobdir}/service.pid
    fi
fi

sleep 999999999
