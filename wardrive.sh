#!/bin/bash
# Copyright (C) 2021 Domien Schepers.

# Wireless network interface.
interface="en0"

# Tcpdump-filter for beacon and probe response frames.
filter="wlan[0] == 0x50 || wlan[0] == 0x80"

# Channel hopping interval in seconds.
# NOTE:	Typically, beacon frames are broadcasted at 200ms intervals so it makes sense to
# 		choose an interval slightly larger than that.
hop_interval=0.250

# Statistics interval in seconds.
stats_interval=20

##########################################################################################
### Sanity Checks and Management #########################################################
##########################################################################################

start () {

#	if [[ $OSTYPE == 'darwin'* ]]; then
#		echo "This program is supported on macOS only."
#		exit
#	fi

# 	if [ $? -ne 0 ]; then
# 		echo "Please run with administrative privileges."
# 		echo
# 		echo "     sudo $0"
# 		echo
# 		exit
# 	fi
	
	if ! command -v airport &> /dev/null; then
		echo "Could not find the airport utility. Consider the following solution:"
		echo
		echo "     sudo ln -s /System/Library/PrivateFrameworks/Apple80211.framework/"`
			`"Versions/Current/Resources/airport /usr/local/bin/airport"
		echo
		exit
	fi
	
	if ! command -v tcpdump &> /dev/null; then
		echo "Could not find the tcpdump tool. Consider the following solution:"
		echo
		echo "     brew install wireshark"
		echo
		exit
	fi
	
	if ! command -v tshark &> /dev/null; then
		echo "Could not find the tshark tool. Consider the following solution:"
		echo
		echo "     brew install wireshark"
		echo
		exit
	fi

}

start

quit () {
	if [ ! -z ${PID_CHANHOP+x} ]; then
		kill $PID_CHANHOP >/dev/null 2>&1
	fi
	if [ ! -z ${PID_TCPDUMP+x} ]; then
		kill $PID_TCPDUMP >/dev/null 2>&1
	fi
	if [ ! -z ${PID_STATS+x} ]; then
		kill $PID_STATS >/dev/null 2>&1
	fi
	exit
}

trap quit INT TERM

##########################################################################################
### Configure the Channels ###############################################################
##########################################################################################

get_supported_channels () {
	
	# View the supported channels through the user interface:
	# Apple -> About This Mac -> System Report -> Network -> Wi-Fi.
	
	# Example of supported channels on a 2018 MacBook Pro:
	# 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 36, 40, 44, 48, 52, 56, 60, 64, 100, 
	# 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 149, 153, 157, 161, 165.
	# NOTE: This may vary based on your regulatory domain, for example, your country. 

	# Use the system profiler to retrieve the supported channel information.
	# NOTE: The system profiler command may take a couple of seconds to execute.  
	chanlist=$(system_profiler SPAirPortDataType | grep "Supported Channels")
	chanlist=$(echo $chanlist | cut -f2 -d':' | tr ',' '\n')
	
	# Return the supported channels.
	echo ${chanlist[*]}
	
}

# Use all channels supported by the wireless interface.
# NOTE: Due to overlapping channels and regulatory constraints this may not be desirable.
# NOTE: Uncomment the following line if you wish to use this option anyway.
# chanlist=$(get_supported_channels)

# Instead, we recommend to use some fixed set of channels tailored to specific needs.
if [ -z ${chanlist+x} ]; then
	
	chanlist_2ghz=(1 3 6 9 11)
	chanlist_5ghz=(36 40 44 48 52 56 60 64)

	chanlist=("${chanlist_2ghz[@]}" "${chanlist_5ghz[@]}")

	# You may wish to spent more time on one or the other frequency band.
	# chanlist=("${chanlist_2ghz[@]}" "${chanlist_2ghz[@]}" "${chanlist_5ghz[@]}")
	# chanlist=("${chanlist_2ghz[@]}" "${chanlist_5ghz[@]}" "${chanlist_5ghz[@]}")

fi

# Debug message for the selected channels.
# echo ${chanlist[*]}

##########################################################################################
### Configure the Interface ##############################################################
##########################################################################################

# Disassociate from any connected network.
sudo airport -z

# Generate a random filename for the new packet capture.
random=$(echo $RANDOM | md5 | head -c 10)
filename="capture-$random.pcapng"

# Sanity Check: Make sure the filename does not exist yet.
if [ -f $filename ]; then
	echo "Filename $filename already exists, please retry."
	exit
fi

echo
echo "Executing the following network capture command:"
echo
echo "     tcpdump -Ini $interface -w $filename $filter"
echo
echo "While hopping over the following channels using a $hop_interval-second interval:"
echo
echo "     ${chanlist[*]}"
echo 
echo "Press any key to continue..."
read -n 1 k <&1

sniff () {
	tcpdump -Ini $interface -w $filename $filter &>/dev/null
}

sniff &
PID_TCPDUMP=$!

##########################################################################################
### Channel Hopping ######################################################################
##########################################################################################

hop () {

	# Keep track of the current channel index.
	len=${#chanlist[@]}
	i=0
	
	while true ; do
	
		# Switch the channel.
		sudo airport --channel=${chanlist[$i]}
		
		# Debug message for the selected channel.
		# echo 'Hopped to channel '${chanlist[$i]}'.'
		
		# Select the next channel and sleep for the requested interval.
		i=$(( (i+1) % len ))
		sleep $hop_interval
		
	done
	
}

hop &
PID_CHANHOP=$!

##########################################################################################
### Print the Statistics #################################################################
##########################################################################################

stats () {

	# Coloring for terminal output.
	YC='\033[0;31m' # Red.
	NC='\033[0m' # Reset.

	while true ; do
		bssids=$(mktemp)
		
		# Create a copy (backup) of the in-progress network capture.
		tshark -r $filename -w backup-$filename 2> /dev/null
		
		# Write all unique BSSIDs and their respective frequency bands to file. 
		# FIXME: On larger (>100MB) network capture files this command is somewhat slow.
		tshark -r backup-$filename -T fields \
			-e wlan.bssid -e radiotap.channel.flags.2ghz > $bssids
		sort -u -o $bssids{,}
		
		# Print an overview of the captured (unique) networks.
		num_total=$(cat $bssids | wc -l)
		num_2ghz=$(cat $bssids | grep '	1' | wc -l)
		num_5ghz=$(cat $bssids | grep '	0' | wc -l)
	
		printf "[$(date +'%T')] "
		printf "Found a total of ${YC}${num_total}${NC} unique networks. "
		printf "With ${YC}${num_2ghz}${NC} on 2.4 GHz, "
		printf "and ${YC}${num_5ghz}${NC} on 5 GHz.\n"

		# Remove temporary files and sleep for the requested interval.
		rm $bssids
		sleep $stats_interval
		
	done
	
}

stats &
PID_STATS=$!

# Wait for the never-ending statistics overview; essentially wait for user to interrupt.
wait $PID_STATS

# Reset traps and terminate the program.
trap - INT TERM
quit
