#!/bin/sh

set -u
set -e
set -o pipefail

function on_error {
	local this_file="${0}"
	local ruby_source="puts File.basename('$this_file')"
	local base_name=$(ruby -e "$ruby_source")
	echo "$base_name:$1:$2 error: Unexpected failure($?)"
}

trap 'on_error ${LINENO} "$BASH_COMMAND"' ERR

function usage {
	echo "Usage: $(basename $0) -f|--file <FILE> [-o|--output <OUTPUT>] [-v|--verbose]"
	echo "Usage: $(basename $0) -h|--help"
	echo 'symbolicate crash log.'
	echo '  -f|--file    file input'
	echo '  -o|--output  file output(Optional).'
	echo '  -v|--verbose print verbosely.'
	echo '  -h| --help   print this and exit.'
	exit 1
}

PRINT_HELP='false'
NO_OUTPUT='true'
VERBOSE='false'
crash_log=""
output_path=""

function print_out {
	local MESSAGE="${@}"
	if [[ "${VERBOSE}" == true ]];then
		echo "${MESSAGE}"
	fi
}

temp_args="$@"

POSITIONAL=()

while [[ $# -gt 0 ]]; do
	key="$1"
	case $key in
		-f|--file)
			crash_log="$2"
			shift
			shift
			;;
		-o|--output)
			output_path="$2"
			NO_OUTPUT='false'
			shift
			shift
			;;
		-v|--verbose)
			VERBOSE="true"
			shift
			;;
		-h|--help)
			PRINT_HELP="true"
			shift
			;;
		*) 
			POSITIONAL+=("$1")
			shift
			;;
	esac
done

if [[ $PRINT_HELP == "true" ]]; then
	usage
fi

[[ -n "$crash_log" ]] || (echo  "Invalid option: $temp_args." && usage)

test -f "$crash_log" || (print_out "$crash_log not exist" && exit 1)

if [[ -z $output_path ]]; then
	output_path=`mktemp` || (print_out "Cannot make temp" && exit 1)
fi

atos_out=`mktemp` || (print_out "Cannot make temp" && exit 1)

is_macos=0

is_ios=0

my_arch=""

my_root=""

grep -q "OS Version" "$crash_log" || (print_out "No Version" && exit 1)

if grep -q "ARM-64" "$crash_log"; then
	my_arch="arm64"
elif grep -q "X86-64" "$crash_log"; then
	my_arch="x86_64"
fi

app_name=$(grep -E "Path:.*" "$crash_log" | head -n 1 | sed -E "s#.*/([^/]*).app/.*#\1.app#")

my_os_line=$(grep "OS Version" "$crash_log" | head -n 1)

my_os_line=$(echo "$my_os_line" | sed -E "s#.*OS Version:[[:space:]]+([^[:space:]].*) ([0-9.]+ \([A-Z0-9]+\)).*#\1\#\2#")

my_platform=$(echo "$my_os_line" | cut -d '#' -f 1)

my_os_version=$(echo "$my_os_line" | cut -d '#' -f 2)

if [[ "$my_platform" == "Mac OS X" ]] ||  [[ "$my_platform" == "macOS" ]]; then
	is_macos=1
fi

if [[ "$my_platform" == "iPhone OS" ]] ; then
	is_ios=1
fi

if (( $is_ios == 1 )); then
	my_root="$HOME/Library/Developer/Xcode/iOS DeviceSupport/$my_os_version/Symbols"
fi

print_out "Platform: $my_platform"
print_out "Version: $my_os_version"

if (( $is_ios == 0 )) && (( $is_macos == 0 )); then
	print_out "Not support" && exit 1
fi

hex_reg="[A-Fa-f0-9]"

uuid_hyphen_reg="-{0,1}"

uuid_reg="($hex_reg{8})$uuid_hyphen_reg($hex_reg{4})$uuid_hyphen_reg($hex_reg{4})$uuid_hyphen_reg($hex_reg{4})$uuid_hyphen_reg($hex_reg{12})"

uuid_reg_no_capture="$uuid_reg"

while echo "$uuid_reg_no_capture" | grep -q -E "[()]" ; do
	uuid_reg_no_capture=$(echo "$uuid_reg_no_capture" | sed -E "s#[()]##")
done

binary_regex=".*(0x$hex_reg+).*(0x$hex_reg+) [+]{0,1}([^[:space:]]+) .*<($uuid_reg_no_capture)> (.*)"

grep -q -E "$binary_regex" "$crash_log" || (print_out "Bad format" && exit 1)

uuids_result=`grep -E "$binary_regex" "$crash_log" | sed -E "s#<$uuid_reg>#<\1-\2\-\3-\4-\5>#" | sed -E "s#$binary_regex#\1\#\3\#\4\#\5#"`

path_result=()

sym_crash_log=()

while IFS= read -r line; do
	sym_crash_log+=("$line")
done < "$crash_log"

while read -r line; do
	product_name=""
	loader_addr=$(echo $line | cut -d '#' -f 1)
	product_name=$(echo $line | cut -d '#' -f 2)
	upper_uuid=$(echo $line | cut -d '#' -f 3 | tr "[:lower:]" "[:upper:]")
	bin_path=$(echo $line | cut -d '#' -f 4)
	if echo "$line" | grep -q -E "$app_name"; then
		print_out "finding application dSYM $product_name"
		md_results=`mdfind "com_apple_xcode_dsym_uuids == $upper_uuid"`
		one_result=""
		while read -r md_result; do
			if [[ -n $one_result ]]; then
				echo "" > /dev/null
			elif echo "$md_result" | grep -q ".dSYM"; then
				print_out "found direct dSYM [DIR] $md_result"
				one_result="$md_result"
			elif test -f "$md_result/Info.plist"; then
				print_out "try find dSYM in Archive: $md_result"
				all_dSYM_dirs=`find  "$md_result" -name "*.dSYM" -type d`
				while read -r dSYM_dir; do
					if [[ -z $one_result ]] && /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$dSYM_dir/Contents/Info.plist" | grep -q "$product_name"; then
						print_out "found dSYM [DIR] $md_result in Archive"
						one_result="$dSYM_dir"
					fi
				done <<< "$all_dSYM_dirs"
			fi
		done <<< "$md_results"
		if [[ -n $one_result ]]; then
			dsym_file=$(find "$one_result/Contents/Resources/DWARF" -name "*" -type f)
			print_out "found dSYM [FILE] $dsym_file"
			path_result+=("$loader_addr#$product_name#$dsym_file")
		fi
	else
		print_out "finding system dSYM $product_name"
		if (( $is_ios == 1 )) && test -d "$my_root"; then
			lib_path="$my_root$bin_path"
			if test -f "$lib_path"; then
				path_result+=("$loader_addr#$product_name#$lib_path")
			fi
		fi
	fi
done <<< "$uuids_result"

if [[ ${#path_result[@]} == 0 ]]; then 
	print_out "No binary found" && exit 1
fi

for path_line in "${path_result[@]}"; do
	loader_addr=$(echo "$path_line" | cut -d '#' -f 1)
	product_name=$(echo "$path_line" | cut -d '#' -f 2)
	bin_file=$(echo "$path_line" | cut -d '#' -f 3)
	loader_addr_regex="(0x$hex_reg+) $loader_addr [+]+ [0-9]+"
	if grep -q -E "$loader_addr_regex" "$crash_log"; then
		related_line_numbers=( $(grep -E -n "$loader_addr_regex" "$crash_log" | cut -d ":" -f 1) )
		for related_line_number in "${related_line_numbers[@]}"; do
			index=$(($related_line_number - 1))
			unsym_line=""
			unsym_line="${sym_crash_log[$index]}"
			addr=$(echo "$unsym_line" | sed -E "s#.*$loader_addr_regex.*#\1#")
			test -f "$atos_out" && rm "$atos_out"
			if xcrun atos -arch "$my_arch" -o "$bin_file" -l "$loader_addr" "$addr" >> "$atos_out" || true ; then
				if test -f "$atos_out"; then
					sym_line=$(cat "$atos_out")
					sym_line_base="$(echo "$unsym_line" | sed -E "s#$loader_addr_regex.*#\1#")"
					sym_crash_log[$index]="$sym_line_base $sym_line"
				else
					print_out "ERROR happened"
				fi
			fi
		done
	fi
done

test -f "$output_path" && rm "$output_path"
touch "$output_path"

for i in "${sym_crash_log[@]}"; do
	echo "$i" >> "$output_path"
done

if $NO_OUTPUT == 'true' ; then
	mv "$output_path" "$output_path".crash && open "$output_path".crash
fi
