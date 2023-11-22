# Make sure no conda environment is activated! 
# https://github.com/parallelworks/issues/issues/1081

bootstrap_tgz() {
    tgz_path=$1
    install_dir=$2
    # Check if the code directory is present
    # - if not copy from user container -> /swift-pw-bin/noVNC-1.3.0.tgz
    if ! [ -d "${install_dir}" ]; then
        echo "Bootstrapping ${install_dir}"
        install_parent_dir=$(dirname ${install_dir})
        mkdir -p ${install_parent_dir}
        
        # first check if the noVNC file is available on the node
        if [[ -f "/core/pworks-main/${tgz_path}" ]]; then
            cp /core/pworks-main/${tgz_path} ${install_parent_dir}
        else
            ssh_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
                # Running in a controller node
                scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
            else
                ssh ${ssh_options} ${resource_privateIp} scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
            fi
        fi
        tar -zxf ${install_parent_dir}/$(basename ${tgz_path}) -C ${install_parent_dir}
    fi
}

# Determine if the service is running in windows using WSL
kernel_version=$(uname -r | tr '[:upper:]' '[:lower:]')

export $(env | grep CONDA_PREFIX)
echo ${CONDA_PREFIX}

if ! [ -z "${CONDA_PREFIX}" ]; then
    echo "Deactivating conda environment"
    source ${CONDA_PREFIX}/etc/profile.d/conda.sh
    conda deactivate
fi


set -x
# Runs via ssh + sbatch
vnc_bin=vncserver

if [[ $kernel_version == *microsoft* ]]; then
    novnc_dir="/opt/noVNC-1.4.0"
    service_vnc_exec=NA
fi


if [ -z ${novnc_dir} ]; then
    novnc_dir=${HOME}/pw/bootstrap/noVNC-1.3.0
fi

if [ -z ${novnc_tgz} ]; then
    novnc_tgz=/swift-pw-bin/apps/noVNC-1.3.0.tgz
fi

# Find an available display port
if [[ $kernel_version == *microsoft* ]]; then
    # In windows only this port works
    displayPort=5900
else
    minPort=5901
    maxPort=5999
    for port in $(seq ${minPort} ${maxPort} | shuf); do
        out=$(netstat -aln | grep LISTEN | grep ${port})
        if [ -z "${out}" ]; then
            # To prevent multiple users from using the same available port --> Write file to reserve it
            portFile=/tmp/${port}.port.used
            if ! [ -f "${portFile}" ]; then
                touch ${portFile}
                export displayPort=${port}
                displayNumber=${displayPort: -2}
                export DISPLAY=:${displayNumber#0}
                break
            fi
        fi
    done
fi

if [ -z "${servicePort}" ]; then
    displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
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

cat >> ${resource_jobdir}/service-kill-${job_number}-main.sh <<HERE
service_pid=\$(cat ${resource_jobdir}/service.pid)
if [ -z \${service_pid} ]; then
    echo "ERROR: No service pid was found!"
else
    echo "$(hostname) - Killing process: \${service_pid}"
    for spid in \${service_pid}; do
        pkill -P \${spid}
    done
    kill \${service_pid}
fi
echo "~/.vnc/\${HOSTNAME}${DISPLAY}.pid:"
cat ~/.vnc/\${HOSTNAME}${DISPLAY}.pid
echo "~/.vnc/\${HOSTNAME}${DISPLAY}.log:"
cat ~/.vnc/\${HOSTNAME}${DISPLAY}.log
vnc_pid=\$(cat ~/.vnc/\${HOSTNAME}${DISPLAY}.pid)
pkill -P \${vnc_pid}
kill \${vnc_pid}
rm ~/.vnc/\${HOSTNAME}${DISPLAY}.*
HERE
echo

if [ -z ${service_vnc_exec} ]; then
    # If no vnc_exec is provided
    if [ -z $(which ${vnc_bin}) ]; then
        # If no vncserver is in PATH:
        echo "Installing tigervnc-server: sudo -n yum install tigervnc-server -y"
        sudo -n yum install tigervnc-server -y
        # python3 is a dependency
        if [ -z $(which python3) ]; then
            sudo -n yum install python3 -y
        fi

    fi
    service_vnc_exec=$(which ${vnc_bin})
fi


if ! [[ $kernel_version == *microsoft* ]]; then
    if [ ! -f "${service_vnc_exec}" ]; then
        displayErrorMessage "ERROR: service_vnc_exec=${service_vnc_exec} file not found! - Exiting workflow!"
    fi

    # Start service
    ${service_vnc_exec} -kill ${DISPLAY}
    # FIXME: Need better way of doing this:
    # Turbovnc fails with "=" and tigevnc fails with " "
    {
        ${service_vnc_exec} ${DISPLAY} -SecurityTypes=None
    } || {
        ${service_vnc_exec} ${DISPLAY} -SecurityTypes None
    }

    rm -f ${resource_jobdir}/service.pid
    touch ${resource_jobdir}/service.pid

    # Fix bug (process:17924): dconf-CRITICAL **: 20:52:57.695: unable to create directory '/run/user/1002/dconf': 
    # Permission denied.  dconf will not work properly.
    # When the session is killed the permissions of directory /run/user/$(id -u) change from drwxr-xr-x to drwxr-----
    rm -rf /run/user/$(id -u)/dconf
    sudo -n mkdir /run/user/$(id -u)/
    sudo -n chown ${USER} /run/user/$(id -u)
    sudo -n chgrp ${USER} /run/user/$(id -u)
    sudo -n  mkdir /run/user/$(id -u)/dconf
    sudo -n  chown ${USER} /run/user/$(id -u)/dconf
    sudo -n  chgrp ${USER} /run/user/$(id -u)/dconf
    chmod og+rx /run/user/$(id -u)

    if  ! [ -z $(which gnome-session) ]; then
        gnome-session &
        echo $! > ${resource_jobdir}/service.pid
    elif ! [ -z $(which mate-session) ]; then
        mate-session &
        echo $! > ${resource_jobdir}/service.pid
    elif ! [ -z $(which xfce4-session) ]; then
        xfce4-session &
        echo $! > ${resource_jobdir}/service.pid
    elif ! [ -z $(which icewm-session) ]; then
        # FIXME: Code below fails to launch desktop session
        #        Use case in onyx automatically launches the session when visual apps are launched
        echo Found icewm-session
        #icewm-session &
        #echo $! > ${resource_jobdir}/service.pid
    elif ! [ -z $(which gnome) ]; then
        gnome &
        echo $! > ${resource_jobdir}/service.pid
    else
        # Exit script here
        #displayErrorMessage "ERROR: No desktop environment was found! Tried gnome-session, mate-session, xfce4-session and gnome"
        # The lines below do not run
        echo "WARNING: vnc desktop not found!"
        echo "Attempting to install a desktop environment"
        # Following https://owlhowto.com/how-to-install-xfce-on-centos-7/
        # Install EPEL release
        sudo -n yum install epel-release -y
        # Install Window-x system
        sudo -n yum groupinstall "X Window system" -y
        # Install XFCE
        sudo -n yum groupinstall "Xfce" -y
        if ! [ -z $(which xfce4-session) ]; then
            displayErrorMessage "ERROR: No desktop environment was found! Tried gnome-session, mate-session, xfce4-session and gnome"
        fi
        # Start GUI
        xfce4-session &
        echo $! > ${resource_jobdir}/service.pid
    fi

    bootstrap_tgz ${novnc_tgz} ${novnc_dir}
fi

cd ${novnc_dir}

./utils/novnc_proxy --vnc localhost:${displayPort} --listen localhost:${servicePort} </dev/null &>/dev/null &
echo $! >> ${resource_jobdir}/service.pid
pid=$(ps -x | grep vnc | grep ${displayPort} | awk '{print $1}')
echo ${pid} >> ${resource_jobdir}/service.pid
rm -f ${portFile}
sleep 5 # Need this specially in controller node or second software won't show up!

# Launch service
echo debug > /gs/gsfs0/users/avidaltorr/pw/debug
date >> /gs/gsfs0/users/avidaltorr/pw/debug
echo ${service_bin} >> /gs/gsfs0/users/avidaltorr/pw/debug
cd

jupyter notebook

"""
if ! [ -z "${service_bin}" ]; then
    echo Running >> /gs/gsfs0/users/avidaltorr/pw/debug
    if [[ ${service_background} == "False" ]]; then
        echo "Running ${service_bin}"
        echo no background >> /gs/gsfs0/users/avidaltorr/pw/debug
        ${service_bin}
    else
        echo "Running ${service_bin} in the background"
        echo background >> /gs/gsfs0/users/avidaltorr/pw/debug
        ${service_bin} &
        echo $! >> ${resource_jobdir}/service.pid
    fi
fi
"""    
sleep 99999
