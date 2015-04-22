#!/usr/bin/env bash
# License Type: GNU GENERAL PUBLIC LICENSE, Version 3
VERSION=1.0.0
# Authors:
# Colin Johnson / https://github.com/colinbjohnson / colin@cloudavail.com
# Ryan Melcer / https://github.com/rmelcer
## Contributors:
## Alex Corley / https://github.com/anthroprose
## Jon Higgs / https://github.com/jonhiggs
## Mike / https://github.com/eyesis
## Jeff Vogt / https://github.com/jvogt
## Dave Stern / https://github.com/davestern
## Josef / https://github.com/J0s3f
## buckelij / https://github.com/buckelij

#Default values
app_name=$(basename $0)
current_date=$(date -u +%s)
selection_method="volumeid"
create_tag_name=false       #Label snapshot with volume's name
create_tag_hostname=false   #Label snapshot with initiating host's hostname
user_tags=false             #Label snapshot with user defined tags (volume_id & current_date)
purge_snapshots=false       #Label snapshot as purgeable
verbose=0
debug=0

check_prereqs() {
    (( $verbose )) && echo "Checking pre-reqs..."
    for prerequisite in basename cut date aws; do
        #use of "hash" chosen as it is a shell builtin and will add programs to hash table, possibly speeding execution. Use of type also considered - open to suggestions.
        hash $prerequisite &> /dev/null
        if [[ $? == 1 ]]; then #status of 70: executable was not found
            echo "In order to use $app_name, the executable \"$prerequisite\" must be installed." 1>&2 ; exit 70
        fi
    done
}

get_EBS_List() {
    (( $verbose )) && echo "Determining EBS selection string..."
    case $selection_method in
        volumeid)
            if [[ -z $volumeid ]]; then
                echo "Volume ID is required by default." 1>&2 ; exit 64
            fi
            ebs_selection_string="--volume-ids $volumeid"
            ;;
        tag)
            if [[ -z $tag ]]; then
                echo "Valid tag (-t Backup,Values=true) required." 1>&2 ; exit 64
            fi
            ebs_selection_string="--filters Name=tag:$tag"
            ;;
        *) echo "Invalid selection method." 1>&2 ; exit 64 ;;
    esac
    #create a list of all ebs volumes that match the selection string from above
    (( $verbose )) && echo "CMD: aws ec2 describe-volumes --region $region $ebs_selection_string --output text --query 'Volumes[*].VolumeId'"
    ebs_backup_list=$(aws ec2 describe-volumes --region $region $ebs_selection_string --output text --query 'Volumes[*].VolumeId')
    ebs_backup_list_result=$(echo $?)
    if [[ $ebs_backup_list_result -gt 0 ]]; then
        echo -e "An error occurred when running ec2-describe-volumes:\n$ebs_backup_list" 1>&2 ; exit 70
    elif (( $debug > 0 )); then
        echo -e "EBS backup list:\n$ebs_backup_list"
    fi
}

tag_snapshots() {
    #$snapshot_tags will hold all tags that need to be applied to a given snapshot so that ec2-create-tags is called only onece
    snapshot_tags=""

    if $create_tag_name; then
        snapshot_tags="$snapshot_tags Key=Name,Value=ec2ab_${ebs_selected}_$current_date"
    fi
    if $create_tag_hostname; then
        snapshot_tags="$snapshot_tags Key=InitiatingHost,Value='$(hostname -f)'"
    fi
    if [[ -n $purge_epoch ]]; then
        snapshot_tags="$snapshot_tags Key=PurgeDate,Value=$purge_epoch Key=PurgeAllow,Value=true"
    fi
    if $user_tags; then
        snapshot_tags="$snapshot_tags Key=Volume,Value=${ebs_selected} Key=Created,Value=$current_date"
    fi

    if [[ -n $snapshot_tags ]]; then
        (( $verbose )) && echo "Tagging Snapshot $snapshot_id with the following Tags: $snapshot_tags"
        (( $verbose )) && echo "CMD: aws ec2 create-tags --resources $snapshot_id --region $region --tags $snapshot_tags --output text 2>&1"
        (( $dry_run )) || tag_output=$(aws ec2 create-tags --resources $snapshot_id --region $region --tags $snapshot_tags --output text 2>&1)
        if [[ $? != 0 ]]; then
            echo -e "An error occurred when running ec2-create-tags:\n$tag_output" 1>&2 ; exit 69
        elif (( $debug )); then
            echo -e "Create snapshot results:\n$tag_output"
        fi  
    elif (( $verbose > 0 )); then
        echo "No snapshot tags selected."
    fi
}

set_purge_epoch() {
    case $purge_offset in
        #Add number of seconds based on user's specified time unit (day by default; hours & minutes also supported.)
        [0-9]*d)
            purge_offset_s=$(( ${purge_offset%?} * 86400 )) ;;
        [0-9]*h)
            purge_offset_s=$(( ${purge_offset%?} * 3600 )) ;;
        [0-9]*m)
            purge_offset_s=$(( ${purge_offset%?} * 60 )) ;;
        [0-9]*)
            purge_offset_s=$(( $purge_offset * 86400 )) ;;
        *) echo "Invalid purge time specified" && exit 1 ;;
    esac
    (( $debug )) && echo "Purge after seconds value: $purge_offset_s"

    #GNU & BSD date are different.
    case $(uname) in
        Linux)
            purge_epoch=$(date -d +${purge_offset_s}sec -u +%s) ;;
        FreeBSD|Darwin)
            purge_epoch=$(date -v +${purge_offset_s}S -u +%s) ;;
        *)
            #Default to GNU date
            purge_epoch=$(date -d +${purge_offset_s}sec -u +%s) ;;
    esac
    (( $verbose )) && echo "Purge Epoch: $purge_epoch"
}

purge_snapshots() {
    # snapshot_purge_allowed is a string containing the SnapshotIDs of snapshots
    # that contain a tag with the key value/pair PurgeAllow=true
    (( $verbose )) && echo "CMD: aws ec2 describe-snapshots --region $region --filters Name=tag:PurgeAllow,Values=true --output text --query 'Snapshots[*].SnapshotId'"
    snapshot_purge_allowed=$(aws ec2 describe-snapshots --region $region --filters Name=tag:PurgeAllow,Values=true --output text --query 'Snapshots[*].SnapshotId')
    (( $verbose )) && echo -e "Snapshots allowed to be purged:\n$snapshot_purge_allowed"

    for snapshot_id_evaluated in $snapshot_purge_allowed; do
        #gets the "PurgeDate" date which is in UTC with UNIX Time format (or xxxxxxxxxx / %s)
        (( $verbose )) && echo "CMD: aws ec2 describe-snapshots --region $region --snapshot-ids $snapshot_id_evaluated --output text | grep ^TAGS.*PurgeDate | cut -f 3"
        delete_epoch=$(aws ec2 describe-snapshots --region $region --snapshot-ids $snapshot_id_evaluated --output text | grep ^TAGS.*PurgeDate | cut -f 3)
        (( $debug )) && echo "Purge date for $snapshot_id_evaluated: $delete_epoch"

        #if purge_after_date is not set then we have a problem. Need to alert user.
        if [[ -z $delete_epoch ]]; then
            #Alerts user to the fact that a Snapshot was found with PurgeAllow=true but with no PurgeDate date.
            echo "Snapshot with the Snapshot ID \"$snapshot_id_evaluated\" has the tag \"PurgeAllow=true\" but does not have a \"PurgeDate=xxxxxxxxxx\" key/value pair. $app_name is unable to determine if $snapshot_id_evaluated should be purged." 1>&2
        else
            # if $delete_epoch is less than $current_date then
            # PurgeDate is earlier than the current date
            # and the snapshot can be safely purged
            if [[ $delete_epoch < $current_date ]]; then
                (( $verbose )) && echo "CMD: aws ec2 delete-snapshot --region $region --snapshot-id $snapshot_id_evaluated --output text 2>&1"
                if (( $dry_run )); then
                    echo "Snapshot \"$snapshot_id_evaluated\" with deletion date of $(date -r $delete_epoch) would be deleted."
                else
                    aws_ec2_delete_snapshot_result=$(aws ec2 delete-snapshot --region $region --snapshot-id $snapshot_id_evaluated --output text 2>&1)
                    echo "Snapshot \"$snapshot_id_evaluated\" with deletion date of $(date -r $delete_epoch) was deleted."
                fi
            else
                (( $verbose )) && echo "Snapshot \"$snapshot_id_evaluated\" with deletion date of \"$delete_epoch\" will not be deleted."
            fi
        fi
    done
}


USAGE() {
    echo
    echo "Usage:  $app_name [flags] [options] [-s volumeid] -V <volumeid> [...]"
    echo "        $app_name [flags] [options] -s tag -t <tag>"
    echo "        $app_name [-h | -?]"
    echo
    echo "Arguments:"
    echo "    -s <string>         Selection method (default: 'volumeid')"
    echo "    -V <volume ids>     List of volume IDs "
    echo "    -t <string>         Tag id to look for (ex: 'Backup,Values=true')"
    echo "Options with arguments:"
    echo "    -c <file>           File to prime cron environment"
    echo "    -r <string>         EC2 region (default: 'us-east-1')"
    echo "    -k <time period>    Mark backups as purgeable after time period (d,h,m,s)"
    echo "Flags:"
    echo "    -n                  Dry run"
    echo "    -d                  Increase verbosity (-dd for debug mode)"
    echo "    -N                  Name backup"
    echo "    -H                  Tag snapshot with backup machine's hostname"
    echo "    -u                  Tag snapshot with volume id and creation date"
    echo "    -p                  Purge old snapshots"
    echo "    -v                  Print version and exit"
    echo
}


while getopts :s:c:r:t:k:vpnHuhVdN opt; do
    case $opt in
        d)
            (( verbose += 1 )) ;;
        s)
            selection_method="$OPTARG" ;;
        c)
            cron_primer="$OPTARG" ;;
        r)
            region="$OPTARG" ;;
        v)
            echo "version $VERSION"; exit 0 ;;
        t)
            tag="$OPTARG" ;;
        k)
            purge_offset="$OPTARG" ;;
        n)
            dry_run=1 ;;
        N)
            create_tag_name=true ;;
        H)
            create_tag_hostname=true ;;
        p)
            purge_snapshots=true ;;
        u)
            user_tags=true ;;
        h)
            USAGE && exit 0 ;;
        V)
            volumeid="$OPTARG" ;;
        \?)
            echo "Invalid option: -$OPTARG"; exit 1 ;;
        *)
            USAGE; exit 0 ;;
    esac
done

if [[ $dry_run -gt 0 && $verbose -lt 1 ]]; then
    verbose=1
fi

if (( $verbose > 1 )); then
    debug=1;
    if (( $verbose > 2 )); then
        set -x
    fi
fi

(( $dry_run )) && echo "Dry run"
(( $verbose )) && echo "Verbosity enabled"
(( $debug )) && echo "Debug output enabled"

#sources "cron_primer" file for running under cron or other restricted environments - this file should contain the variables and environment configuration required for ec2-automate-backup to run correctly
if [[ -n $cron_primer ]]; then
    if [[ -f $cron_primer ]]; then
        source $cron_primer
    else
        echo "Cron Primer File \"$cron_primer\" Could Not Be Found." 1>&2 ; exit 70
    fi
fi

if [[ -z $region ]]; then
    if [[ -z $EC2_REGION ]]; then
        region="us-east-1" #Default if none specified.
    else
        region=$EC2_REGION
    fi
fi

check_prereqs

#sets the PurgeDate tag to the number of seconds that a snapshot should be retained
if [[ -n $purge_offset ]]; then
    set_purge_epoch
    echo "Snapshots will be eligible for purging after $(date -r $purge_epoch)."
fi

get_EBS_List

#the loop below is called once for each volume in $ebs_backup_list - the currently selected EBS volume is passed in as "ebs_selected"
for ebs_selected in $ebs_backup_list; do
    snapshot_description="ec2ab_${ebs_selected}_$current_date"
    (( $verbose )) && echo "CMD: aws ec2 create-snapshot --region $region --description $snapshot_description --volume-id $ebs_selected --output text --query SnapshotId 2>&1"
    (( $dry_run )) || snapshot_id=$(aws ec2 create-snapshot --region $region --description $snapshot_description --volume-id $ebs_selected --output text --query SnapshotId 2>&1)
    if [[ $? != 0 ]]; then
        echo -e "An error occurred when running ec2-create-snapshot:\n$snapshot_id" 1>&2 ; exit 70
    elif (( $debug )); then
        echo -e "Create snapshot results:\n$snapshot_id"
    fi  
    tag_snapshots
done

if $purge_snapshots; then
    echo "Purging old snapshots..."
    purge_snapshots
    echo "Done."
fi
