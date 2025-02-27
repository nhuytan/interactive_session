# Runs via ssh + sbatch
set -x

if ! which tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "Tailscale is already installed."
fi

# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh
echo "Creating file ${resource_jobdir}/service-kill-${job_number}-main.sh from directory ${PWD}"
if [[ ${jobschedulertype} != "CONTROLLER" ]]; then
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
else
    echo "bash ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
fi

cat >> ${resource_jobdir}/service-kill-${job_number}-main.sh <<HERE
sudo tailscale down
HERE

sudo tailscale up | tee tailscale.up.log

tailscale ip
