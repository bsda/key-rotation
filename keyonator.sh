#!/bin/bash
export 'PS4=+$me.$LINENO '


usage() {
   cat << EOF

   Usage: $(basename $0)  options

   This script generates a master private key and master public key.
   It will also generate keys for OPS with split passwords for any 2 people with access to card Decryption
   Only to be used in cards_db 
    OPTIONS:
    -h   Show this message
    -d   Directory to store new keys 
    -p   Process type [new|rotation]  
    -o   Directory where old keys are stored (needed to check same passwords are not used). Needed if process type = rotation.
    -s   Key size. Recommended 4096 
    -v   Number of days for certificate validity. Doesn't stop working after it expires. 
    -t   Key type [single|pair] (Pair will create keys with 2 people passwords, single is a key per person)

EOF
exit 1
}



while getopts ":hd:s:v:t:p:o:" opt; do
  case $opt in
    d) key_dir=$OPTARG ;;
    s) master_key_size=$OPTARG ;;
    v) master_cert_valid=$OPTARG ;;
    t) key_type=$OPTARG ;;
    p) process=$OPTARG ;;
    o) old_key_dir=$OPTARG ;;
    h) usage ;;
    ?) usage ;;
   esac
done


if [[ -z $key_dir ]] || [[ -z $master_key_size ]] || [[ -z $master_cert_valid ]] || [[ ! $key_type =~ ^(single|pair)$ ]] || [[ ! $process =~ ^(new|rotation)$ ]]  
then
    if [[ $process == 'rotation' ]]
    then
        if [[ -z $old_key_dir ]]
        then
            usage
            echo "-o is needed when process=rotation"
        fi
    fi 
   usage
   exit 1
fi


#list=""
#list2=""
#keys=""

master_key="${key_dir}/master.private.key"
master_pass=""
master_cert="${key_dir}/master.x509.key"



if [[ ! -d  $key_dir ]]
then
  if ( ! install -m 0700 -d $key_dir )
  then
    echo "Failed to create $key_dir. Check permissions"
    exit 1
  fi
fi

#####################
# confirm()
# - Simple function to ask for confirmation
#
####################
confirm() {
    echo  -n "$1 (Y|N)  "
    read -s -N 1 answer
    if [[ $answer == "Y" || $answer == "y" ]]
    then
        echo "OK"
        echo
    else
        echo "Exiting..."
        exit 1
    fi
}

get_names() {

case $key_type in
    single)
	min_names=1 ;;
    pair)
	min_names=2 ;;
esac

namecount=0
until [[ $namecount -ge $min_names ]] 
do
    echo "Enter all names separate by space. At least $min_names name(s) required"
	read names
	namecount=$(echo $names | wc -w)
done

}


set_pairs() {

unique_names=$(printf '%s\n' ${names,,}| sort | uniq )

for n1 in ${unique_names}
do
	for n2 in ${unique_names}
	do
		if [[ $n1 == $n2 ]]
		then
			continue
		else
			list+=($n1-$n2)
		fi
		if  ( echo "${list[@]}" | grep -q "$n2-$n1"  )
		then
			continue
		else
			keys+=($n1-$n2)
		fi
	done
done

}

set_pass() {

echo
for n in $unique_names
do
pass1=pass1
pass2=pass2
	until [[ "$pass1" == "$pass2" ]]
	do
		echo "${n^}"
		echo "Password:"
		read -s pass1
		echo "Confirm:"
		read -s pass2
		echo ========
		echo 
		#Creating a variable username with the password as a value
	 	eval "${n}"='"$pass1"'
	done
done	
	 
}

generate_master() {
pass1=pass1
pass2=pass2

echo "Master Key"
until [[ "$pass1" == "$pass2" ]]
do
	echo "Password:"
	read -s pass1
	echo "Confirm:"
	read -s pass2
	master_pass=\'"$pass1"\'
done

echo
echo -n "Generating $master_key: "
if (openssl genrsa -aes256 -passout pass:"$master_pass" -out $master_key $master_key_size > /dev/null 2>&1)
then
	echo "OK"
else
	echo "FAIL"
fi

echo -n "Generating public X509 key: "
if (openssl req -new -x509 -days $master_cert_valid -key $master_key -out $master_cert -passin pass:$master_pass \
	-subj '/CN=derp/O=DERP/C=GB/L=London' > /dev/null 2>&1)
then
	echo "OK"
else
	echo "FAIL"
fi

}



check_oldpass() {


for k in ${keys[@]}
do
    if [[ ! -f "$old_key_dir/$k.private.key" ]]
    then
        missing+=("$k.private.key")
    else
        [[ $k =~ ([a-z]+)\-([a-z]+) ]]; n1=${BASH_REMATCH[1]} ; n2=${BASH_REMATCH[2]}
        if ( echo $k | openssl rsautl -inkey "$old_key_dir/$k.private.key" -passin pass:"${!n1}${!n2}" -encrypt >/dev/null 2>&1 )
        then
            samepass+=($k.private.key)
        fi
    fi
done


if [[ ${#missing[@]} -gt 0 ]]
then
    for m in ${missing[@]}
    do
        echo "Old key missing: $m"
    done
    echo
fi

if [[ ${#samepass[@]} -gt 0 ]]
then
    for s in ${samepass[@]}
    do
        echo "$s is using the same password of previous key"
    done
    echo
fi


if [[ ${#missing[@]} -gt 0 ]] || [[ ${#samepass[@]} -gt 0 ]] 
then
    exit
fi

}

generate_opkeys() {

if [[ $key_type == 'pair' ]]
then
  for k in ${keys[@]}
  do	
    [[ $k =~ ([a-z]+)\-([a-z]+) ]]; n1=${BASH_REMATCH[1]} ; n2=${BASH_REMATCH[2]}
    echo -n "Generating ${key_dir}/${n1}-${n2}.private.key: "
    if ( openssl pkcs8 -in $master_key -passin pass:"$master_pass" -topk8 -passout pass:"${!n1}${!n2}" -out ${key_dir}/${k}.private.key >/dev/null 2>&1 )
    then
	    echo "OK"
    else
    	echo "FAIL"
    fi
  done
else
  for k in ${unique_names}
  do	
    [[ $k =~ ([a-z]+) ]]; n1=${BASH_REMATCH[1]} 
    echo -n "Generating ${key_dir}/${k}.private.key: "
    if ( openssl pkcs8 -in $master_key -passin pass:"$master_pass" -topk8 -passout pass:"${!k}" -out ${key_dir}/${k}.private.key >/dev/null 2>&1 )
    then
	    echo "OK"
    else
    	echo "FAIL"
    fi
  done
fi

unset master_pass

}

###################
# cleanup()
# - Shreds and deletes files
#
###################
purge() {

echo -n "Shredding $1: "
if ( shred -z -u $1 > /dev/null )
then
        echo "OK"
else
        echo "FAIL"
fi      


}


cleanup() {

echo
echo "Please copy $master_key to USB as it will be deleted"
confirm "Did you do it?"
confirm "Are you sure?"
confirm "Last chance!!!"

purge $master_key 

}


case $process in 
    new)
        get_names
        set_pairs
        set_pass
        generate_master
        generate_opkeys
        cleanup
        ;;
    rotation)
        get_names
        set_pairs
        set_pass
        check_oldpass
        generate_master
        generate_opkeys
        cleanup
        ;;
esac

