#!/bin/bash
export 'PS4=+$me.$LINENO '




#What this script does:
##
# 1 - create new table => id,enc_card
# 2 - loads id,enc_cardnumber from card where max(card.id) > max(card_new.id)
# 3 - New lines are replaced with '#' for easier manipulation
# 4 - Data decrypted using old private key (paswordless)
# 5 - Date encrypted using new X509 Certificate
# 6 - New encrypted data saved into new csv file
# 7 - Data from csv loaded into card_new table
# 8 - csv file shredded
 

#Data manipulation
# 1 - csv output. New lines replaced with '#'
# 2 - '#' Removed from encrypted strings
# 3 - Data decrypted
# 4 - Data re-encrypted with new certficate
# 5 - New lines on re-encrypted data replaced with '#' and added to new csv file
# 6 - '#' on new csv file replaced with '\\n'



####################
## SOME VARIABLES ##

#Set to 1 to enable clear data comparison.
#Slows the process down by about 33%
compare_data=0

#CSV files
export temp_dir=/tmp/tempdata
export new_csv="${temp_dir}/card_new.csv"

#Processes
export cores=$(grep -c processor /proc/cpuinfo)
if [[ $cores -eq 1 ]]
then
  export  max_threads=1
else
  export max_threads=$(($cores - 1))
fi

#Counters
export decrypt_count=0
export encrypt_count=0


#Database stuff
timestamp=$(date +%Y%m%d)
# If we run the script in two consecutive days, because we start the key rotaion the day before switching tables,
# we need to hardcode the timestamp the second day, otherwise a new table will be created
# timestamp=20150519
database=cards
live_table=card
new_table="card_new_${timestamp}"
bak_table="card_bak_${timestamp}"
test_table="card_test_${timestamp}"

#Make some variables global
clear_data=""
new_encrypted=""
old_enc=""
new_clear=""
declare -A clear_array
declare -A newenc_array
declare -A oldenc_array
declare -A new_clear_array

####################

usage() {
   cat << EOF

   Usage: $(basename $0)  options

   This script decrypts the data on card.enc_cardnumber, re-encrypts using a different key and inserts into card_new.enc_cardnumber  
   Only to be used in cards 
    OPTIONS:
    -h   Show this message
    -k   New private key file
    -p   New public key file
    -o   Old private key file
    -t   Run type [partial|complete|check]
	 'partial'  = Can be run multiple times. It prepares the new_table, but doesn't perform 
                      full checks and doesn't update the live table.
         'complete' = Final should only be run when you are ready to update the live table.
                      It will complete all steps. re-encrypt, backup, test, update live table and partial check.
                      Normally run after a couple of partial runs.
         'check'    = To be run after the 'complete' run. It will compare the records on card with 
                      the records on card_bak
    -n   Number of rows to check 
         


EOF
exit 1
}


while getopts ":hk:p:o:t:n:" opt; do
  case $opt in
    k) new_private_key=$OPTARG ;;
    p) new_public_key=$OPTARG ;;
    o) old_private_key=$OPTARG ;;
    t) run_type=$OPTARG ;;
    n) numrows=$OPTARG ;;
    h) usage ;;
    ?) usage ;;
   esac
done


if [[ -z $new_private_key ]] || [[ -z $new_public_key ]] || [[ -z $old_private_key ]] || [[ ! $run_type =~ ^(partial|complete|check|precheck|check_all)$ ]]
then
   usage
   exit 1
fi

if [[ -z $numrows ]]
then
  numrows=20
fi

export new_private_key=$new_private_key
export new_public_key=$new_public_key
export old_private_key=$old_private_key
export numrows=${numrows}

#Check if all progs are installed
for prog in mysql openssl shred pv
do
   if ( ! which $prog > /dev/null 2>&1)
   then
      echo $prog is not installed
      exit 1
   fi
done



log() {

if [[ $1 == "-n" ]]
then
    shift
    echo -n "`date +%Y-%m-%d\ %T: ` $*"
else
    echo "`date +%Y-%m-%d\ %T: ` $*"
fi

}


#####################
# confirm()
# - Simple function to ask for confirmation
#
####################
confirm() {
    log -n "$1 (Y|N): "
    read -s -N 1 answer
    if [[ $answer == "Y" || $answer == "y" ]]
    then
        echo "OK"
	echo
    else
        log "Exiting..."
        exit 1
    fi
}



get_data_mysql() {

if [ ! -d $temp_dir ]
then
    install -d -m 700 $temp_dir
fi

log -n "Loading data: "
oldenc_list=$(mysql -N -B --raw -e "SELECT id,REPLACE(enc_cardnumber, '\n','#') from $live_table WHERE card.id > (SELECT COALESCE(max(id),0) from $new_table) order by id asc" $database)

if [[ ! $? == 0 ]]
then
  echo "Data not loaded correctly. Mysql threw an error"
  exit 1
else
  echo "Loading data complete"
fi
}





###################
# create_table()
# - Creates new table on cards if it doesn't exist
#
###################
create_table() {

log -n "Creating table $new_table... "
if (mysql -N -B -e "CREATE TABLE IF NOT EXISTS $new_table (id int(11) NOT NULL, enc_cardnumber varchar(700) NOT NULL,PRIMARY KEY (id)) DEFAULT CHARSET=utf8" $database)
then
	echo "OK"
	echo
else
	echo "FAIL"
	exit 1
fi

}

###################
# cleanup()
# - Shreds and deletes $csv file
#
###################
cleanup() {

log -n "Shredding $1: "
if ( shred -n 7 -z -u $1 > /dev/null )
then
	echo "OK"
else
	echo "FAIL"
fi	


}


###################
# check_data()
# - Prints max_id and number of records for both old and new table
# - Does simple check on number of records and max_id
# - Exits if new_table has more records or has a higher max_id than live_table
#
####################
check_data() {

card_records=$(mysql -N -B --raw -e "SELECT count(*) from $live_table" $database)
card_max_id=$(mysql -N -B --raw -e "SELECT max(id) from $live_table" $database)
new_records=$(mysql -N -B --raw -e "SELECT count(*) from $new_table" $database)
new_max_id=$(mysql -N -B --raw -e "SELECT COALESCE(max(id),0) from $new_table" $database)
to_process=$(($card_max_id - $new_max_id))


echo "######################################################"
echo "  Number of Records on card table: $card_records"
echo "  MAX ID on card table: $card_max_id"
echo "  Number of Records on new_card table: $new_records"
echo "  MAX ID on new_card table: $new_max_id"
echo "  Records to process: $to_process"
echo "######################################################"
echo


if [[ $new_max_id -eq $card_max_id ]] && [[ $run_type == 'partial' ]]
then
	log "All records have been processed. Nothing to do"
	exit 0
elif [[ $new_max_id -gt $card_max_id ]] 
then
	log "Something went wrong. new_card max_id is higher than card"
	exit 1
else 
	log "Everything seems OK"
	confirm "Continue?"
fi

if [[ -e $new_csv ]]
then
        log "$new_csv already exists."
        confirm "Remove it? "
        cleanup $new_csv

fi

}



run_threads() {
start_time=$(date +%Y-%m-%d\ %T)
start_time_epoch=$(date +%s)
#export the function crypto_stuff as it will be called directly by bash
export -f crypto_stuff 

log  "Re-Encrypting: "
#Get the size of $oldenc_list to be used by pv
size=${#oldenc_list} 

####################################################
#
#  This is where the multi thread magic happens
#  $oldenc_list is a single line string with all IDs and encrypted strings we want to re-encrypt
#  The format is like this: "ID enc_string ID enc_string ID enc_string..."
#  We echo the whole string to xargs and tell is to use max 2 arguments "ID enc_string"
#  xargs will then execute crypto_stuff in parallel  with 2 arguments, respecting the $max_threads value for number of procs
#  As a bonus, pv is used to display a progress bar with elapsed time and ETA
#
#####################################################
echo $oldenc_list | pv -pte -s $size  | xargs  --max-procs=$max_threads -n 2  bash -c 'crypto_stuff $0 $1'

#Extract the number of records processed from the csv file
if [[ -f $new_csv ]]
then
   records=$(awk -F, {'print $1'} $new_csv | wc -l)
   log OK
else
   log "$new_csv not created. Something failed"
   exit 1
fi

#Do some time calculations
end_time=$(date +%Y-%m-%d\ %T)
end_time_epoch=$(date +%s)
if [[ $end_time_epoch == $start_time_epoch ]]
then
    rate=$records
else
   rate=$(($records / $(($end_time_epoch - $start_time_epoch))))
fi
echo
echo "########################################################"
echo "Start: $start_time"
echo "End  : $end_time"
echo "Records: $records ($rate/s)"
echo "Server Cores: $cores | Threads used: $max_threads"
echo "########################################################"
echo
}

get_passwords() {

echo
until echo 1 | openssl rsautl -inkey $old_private_key -encrypt -passin fd:3 > /dev/null 2>&1
do
  read -sp "Enter password for OLD Private Key $old_private_key: " OLDPASS
  exec 3<<<"$OLDPASS"
  echo
done

until echo 1 | openssl  rsautl -inkey $new_private_key -encrypt -passin fd:4 > /dev/null 2>&1
do
  read -sp "Enter password for NEW private key $new_private_key: " NEWPASS
  exec 4<<<"$NEWPASS"
  echo
done

export NEWPASS=$NEWPASS
export OLDPASS=$OLDPASS

}


###crypt_stuf()
crypto_stuff() {

if [[ $# -eq 2 ]]
then
        id=$1
	enc_string=$2	
        #Check if $1 and $2 are valid
	if [[ ! $id =~ [0-9]+ ]] || [[ ! $enc_string =~ ^[A-Za-z0-9+/#]+={1,2}?$ ]]
	then
	   echo "`date +%Y-%m-%d\ %T: ` ID or enc_estring not valid: $id"
	   return
        fi
        #Read passwords from file descriptors
        exec 4<<<"$NEWPASS"
  	exec 3<<<"$OLDPASS"
        #Decrypt string and put it into $clear_data
	clear_data=$(echo -n "$enc_string" | base64 -di | openssl rsautl -inkey $old_private_key -decrypt -passin fd:3 2>/dev/null)
        if [[ $? == 0 ]]
	then
           #If decrypt OK, add clear data to array
	   clear_array[$id]=${clear_data}
        else
           #Exit function if decryption failed.
           echo "`date +%Y-%m-%d\ %T: ` Failed to decrypt ID: $id"
           return
        fi   
	#re-encrypt clear string with new key. Replace new lines on base64 encoded data with '#' to simplify csv generation.
	new_encrypted=$(echo -n "$clear_data" | openssl rsautl -certin -inkey $new_public_key -encrypt 2>/dev/null | base64 | sed '{:q;N;s/\n/#/g;t q}')
        if [[ $? == 0 ]]
	then
           #If re-encryption OK, add new encrypted string to newenc_array
           #Echo $id,encrypted to csv file for later import on mysql
	   newenc_array[$id]=${new_encrypted}
	   echo "$id,|${newenc_array[${id}]}|" >> $new_csv
        else
	   #exit function if failed to re-encrypt
           echo "`date +%Y-%m-%d\ %T: ` Failed to re-encrypt ID: $id"
           return
        fi   


        #IF compare_data=1, decrypted the new encrypted string and compare with the old clear data.
        #IT will slow down the process
	if [[ $compare_data == 1 ]]
	then
		#echo "Comparing record $1"
		new_clear=$(echo -n "$new_encrypted" | sed 's|#||g' | base64 -di | openssl rsautl -inkey $new_private_key -decrypt -passin fd:4)
		new_clear_array[$id]=${new_clear}
		if [[ "${new_clear_array[${id}]}" != ${clear_array[${id}]} ]]
		then
			#log "Clear data mismatch! New string:$id,'${new_clear_array[${id}]}' ::: Old string: $id,'${clear_array[${id}]}'" 
			echo "`date +%Y-%m-%d\ %T: ` Clear data mismatch!: $id"
		fi
	fi
else
	echo "`date +%Y-%m-%d\ %T: ` Wrong number of parameters for crypt_stuff() function"
	exit 1
fi

}


#################
# fix_format()
# - Replaces '#' on new encrypted strings with "\\n" as this if the format mysql understands when loading the data
#
################
fix_format() {

log -n "Fixing csv format for mysql: "
if (sed -i 's|#|\\\n|g' $new_csv); then
	echo "OK"
else
	echo "FAIL"
	exit 1
fi

}




load_data_mysql() {

log "Loading new data from $new_csv to $new_table on $database"
confirm "Continue?"

if (mysql -N -B --raw -e "LOAD DATA LOCAL INFILE '"$new_csv"' INTO TABLE $new_table FIELDS TERMINATED BY ',' ENCLOSED BY '|' LINES TERMINATED BY '\n'" $database)
then
	log "Loading complete"
else
	log "Loading failed"
fi

}

compare_all_records() {
     _live_table=$bak_table
     _new_table=$live_table
     new_key=$new_private_key
     old_key=$old_private_key
     row_count=$(mysql -N -B --raw -e "SELECT count(*) from ${bak_table}" $database)
     mysql -N -B --raw -e "SELECT id from ${bak_table}" $database > /tmp/all_rows


fail_count=0
echo
log "Comparing random records (${row_count} records)"
for i in $(cat /tmp/all_rows)
do
	exec 3<<<"$OLDPASS"
	exec 4<<<"$NEWPASS"
	old_md5=$(mysql -N -B --raw -e "SELECT enc_cardnumber from ${_live_table} where id=$i" $database | base64 -di | openssl rsautl -inkey $old_key -decrypt -passin fd:3 | md5sum 2>/dev/null)
	new_md5=$(mysql -N -B --raw -e "SELECT enc_cardnumber from ${_new_table} where id=$i" $database | base64 -di | openssl rsautl -inkey $new_key -decrypt -passin fd:4 | md5sum 2>/dev/null)
	if [[ ! $old_md5 == $new_md5 ]]
	then
		log "$i: FAIL"
		fail_count=$(($fail_count + 1))
	fi
done

log "Records failed comparison: $fail_count"

}

compare_records() {

stage=$1

case $stage in
  pre)
     #Case pre-update, compare records from live table with new table
     #Before updating the live table
     _live_table=$live_table
     _new_table=$new_table
     new_key=$new_private_key
     old_key=$old_private_key
     limit="limit ${numrows}"
     ;;
  post)
     #Case post-update, compare records from live table with the backup prior to update
     _live_table=$bak_table
     _new_table=$live_table
     new_key=$new_private_key
     old_key=$old_private_key
     limit="limit ${numrows}"
     ;;
   default)
     _live_table=$live_table
     _new_table=$new_table
     limit="limit 100"
     ;;
esac


random_ids=$(mysql -N -B --raw -e "SELECT id from ${_live_table} order by rand() $limit" $database)
random_ids=$(mysql -N -B --raw -e "SELECT id from ${_live_table} order by rand() $limit" $database)

fail_count=0
echo
log "Comparing random records (${numrows} records)"
for i in $random_ids
do
	exec 3<<<"$OLDPASS"
	exec 4<<<"$NEWPASS"
	old_md5=$(mysql -N -B --raw -e "SELECT enc_cardnumber from ${_live_table} where id=$i" $database | base64 -di | openssl rsautl -inkey $old_key -decrypt -passin fd:3 | md5sum 2>/dev/null)
	new_md5=$(mysql -N -B --raw -e "SELECT enc_cardnumber from ${_new_table} where id=$i" $database | base64 -di | openssl rsautl -inkey $new_key -decrypt -passin fd:4 | md5sum 2>/dev/null)
	if [[ ! $old_md5 == $new_md5 ]]
	then
		log "$i: FAIL"
		fail_count=$(($fail_count + 1))
	fi
done

log "Records failed comparison: $fail_count"

}


backup_card() {

confirm "About to DROP $bak_table and $test_table if they exist. Continue? "

log -n "Removing existing $bak_table if it exists: "
if ( mysql -N -B --raw -e "DROP TABLE IF EXISTS $bak_table" $database )
then
    echo "OK"
else
    echo "FAIL"
    exit 1
fi

log -n "Removing existing $test_table if it exists: "
if ( mysql -N -B --raw -e "DROP TABLE IF EXISTS $test_table" $database )
then
    echo "OK"
else
    echo "FAIL"
    exit 1
fi


log -n "Backing up $live_table into $bak_table: "
if ( mysql -N -B --raw -e "CREATE TABLE IF NOT EXISTS $bak_table SELECT * from $live_table" $database )
then
    echo "OK"
else
    echo "FAIL"
fi

echo 

log -n "Creating $test_table from $live_table: "
if ( mysql -N -B --raw -e "CREATE TABLE IF NOT EXISTS $test_table SELECT * from $live_table" $database )
then
    echo "OK"
else
    echo "FAIL"
fi
}


test_update() {

log -n "Testing update on $test_table: "
if ( mysql --show-warnings -N -B --raw -e "update $test_table left join $new_table on ${test_table}.id= ${new_table}.id set ${test_table}.enc_cardnumber = ${new_table}.enc_cardnumber" $database )
then
    echo "OK"
else
    echo "Something failed. Better investigate it manually"
    exit 1
fi

}

do_update() {

confirm "About to update enc_cardnumber on $live_table with the records from $new_table. Continue? "
confirm "If this fails, you might need to restore from backup. Are you sure? "


log -n "Updating enc_cardnumber on $live_table with new encrypted records from $new_table: "
if ( mysql --show-warnings -N -B --raw -e "update $live_table left join $new_table on ${live_table}.id= ${new_table}.id set ${live_table}.enc_cardnumber = ${new_table}.enc_cardnumber" $database )
then
    echo "OK"
else
    echo "Something failed. Better investigate it manually"
    exit 1
fi


}


case $run_type in 
  partial)
    create_table
    check_data
    get_data_mysql
    get_passwords
    run_threads
    fix_format
    load_data_mysql
    compare_records pre
    #cleanup
     ;;
  complete)
    create_table
    check_data
    get_data_mysql
    get_passwords
    if [[ $to_process -gt 0 ]]
    then
       run_threads
       fix_format
       load_data_mysql
    fi
    backup_card
    test_update
    do_update 
    compare_records post
     ;;
  check)
    get_passwords
    compare_records post
     ;;
  precheck)
    get_passwords
    compare_records pre
     ;;
  check_all)
    get_passwords
    compare_all_records
     ;;
esac
