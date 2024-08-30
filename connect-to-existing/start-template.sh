
# Notify platform that service is running
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

# If running docker with the -d option sleep here! 
# Do not exit this script until the job is canceled!
# Exiting this script before the job is canceled triggers the cancel script!
sleep infinity
