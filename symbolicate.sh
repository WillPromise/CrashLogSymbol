#!/bin/sh

set -u
set -e
set -o pipefail

UNKNOWNF=10
INVARG=1
INNOTFOUND=2
TMPERR=3
OSVERNOTFOUND=4
NOEXECPATH=5
OSVERBADFORMAT=6
PLATFORMERR=7
UUIDERR=8
BINERR=9

# see `man 5 terminfo`
FG_BLACK=`tput setaf 0`
FG_RED=`tput setaf 1`
FG_GREEN=`tput setaf 2`
FG_YELLOW=`tput setaf 3`
FG_BLUE=`tput setaf 4`
FG_MAGENTA=`tput setaf 5`
FG_CYAN=`tput setaf 6`
FG_WHITE=`tput setaf 7`

BG_BLACK=`tput setab 0`
BG_RED=`tput setab 1`
BG_GREEN=`tput setab 2`
BG_YELLOW=`tput setab 3`
BG_BLUE=`tput setab 4`
BG_MAGENTA=`tput setab 5`
BG_CYAN=`tput setab 6`
BG_WHITE=`tput setab 7`

BOLD=`tput bold`
RESET=`tput sgr0`

function print_out {
	[ "${VERBOSE}" = 'true' ] || return 0
	local MESSAGE="${@}"
	echo "${MESSAGE}"
}

function print_out_error {
	print_out "${FG_RED}${BOLD}[ERROR]${RESET} ${@}"
}

function print_out_info {
	print_out "${FG_YELLOW}${BOLD}[INFO]${RESET} ${@}"
}

function on_error {
	local this_file="${0}"
	local ruby_source="puts File.basename('$this_file')"
	local base_name=$(ruby -e "$ruby_source")
	print_out_error "$base_name:$1:$2 error: Unexpected failure($?)"
}

trap 'on_error ${LINENO} "$BASH_COMMAND"' ERR

function usage {
	echo "Usage: $(basename $0) -f|--file <FILE> [-o|--output <OUTPUT>] [-v|--verbose]"
	echo "Usage: $(basename $0) -h|--help"
	echo 'symbolicate crash log.'
	echo '  -f|--file    <FILE> file input'
	echo '  -o|--output  <OUTPUT> file output(Optional).'
	echo '  -v|--verbose print verbosely.'
	echo '  -h| --help   print this and exit.'
	exit $INVARG
}

NO_OUTPUT='true'

VERBOSE='false'

crash_log=""

output_path=""

temp_args="$@"

POSITIONAL=()

while [ $# -gt 0 ]; do
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
		*)    # unknown option
			POSITIONAL+=("$1") # save it in an array for later
			shift # past argument
			;;
	esac
done

[ -n "$crash_log" ] || (echo  "Invalid option: $temp_args." && usage)

[ -f "$crash_log" ] || (print_out_error "$crash_log not exist" && exit $INNOTFOUND)

is_crash=0

is_sample=0

grep -q "Exception Type:" "$crash_log" && is_crash=1

grep -q "Analysis Tool:" "$crash_log" && is_sample=1

[[ ( $is_crash -eq 1 ) || ( $is_sample -eq 1 ) ]] || (print_out_error "Unknown file" && exit $UNKNOWNF)

if [ -z "$output_path" ]; then
	output_path=`mktemp` || (print_out_error "Cannot make temp" && exit $TMPERR)
fi

atos_out=`mktemp` || (print_out_error "Cannot make temp" && exit $TMPERR)

is_macos=0

is_ios=0

my_arch=""

my_root=""

grep -q "OS Version" "$crash_log" || (print_out_error "No Version" && exit $OSVERNOTFOUND)

if grep -q "ARM-64" "$crash_log"; then
	my_arch="arm64"
elif grep -q "X86-64" "$crash_log"; then
	my_arch="x86_64"
fi

app_path=$(grep -E "^Path:.*" "$crash_log" | head -n 1)

print_out_info "Assuming the executable's path extension is ${BOLD}app${RESET}"

app_name=$(echo "$app_path" | sed -E "s#.*/([^/]+).app/.*#\1.app#")

if [ "$app_path" = "$app_name" ] ; then
	print_out_info "The executable's path extension is ${BOLD}NOT${RESET} 'app', assuming it is a terminal-like executable"
	app_name=$(echo "$app_path" | sed -E "s#.*/([^/]+)[[:space:]]*#\1#")
	if [ "$app_path" = "app_name" ] ; then
		print_out_error "can not determine the executable's path" && exit $NOEXECPATH
	fi
fi

print_out_info "Application: ${BG_YELLOW}${BOLD}$app_name${RESET}"

my_os_line=$(grep "OS Version" "$crash_log" | head -n 1)

my_os_line=$(echo "$my_os_line" | sed -E "s#.*OS Version:[[:space:]]+([^[:space:]].*) ([0-9.]+ \([A-Za-z0-9]+\)).*#\1\#\2#")

if echo "$my_os_line" | grep --quiet --invert-match "#" ; then
	print_out_error "parsing $my_os_line failed" && exit $OSVERBADFORMAT
fi

my_platform=$(echo "$my_os_line" | cut -d '#' -f 1)

my_os_version=$(echo "$my_os_line" | cut -d '#' -f 2)

if [ "$my_platform" = "Mac OS X" ] ||  [ "$my_platform" = "macOS" ] ; then
	is_macos=1
fi

if [ "$my_platform" = "iPhone OS" ] ; then
	is_ios=1
fi

if (( $is_ios == 1 )); then
	my_root="$HOME/Library/Developer/Xcode/iOS DeviceSupport/$my_os_version/Symbols"
	if [ ! -d "$my_root" ] ; then
		print_out_error "$my_root not exist, which may cause issue"
	fi
fi

print_out_info "Platform: ${BG_YELLOW}${BOLD}$my_platform${RESET}"

print_out_info "Version: ${BG_YELLOW}${BOLD}$my_os_version${RESET}"

if (( $is_ios == 0 )) && (( $is_macos == 0 )); then
	print_out_error "Not supported platform" && exit $PLATFORMERR
fi

hex_reg="[A-Fa-f0-9]"

hex_addr_reg="0{0,1}x{0,1}$hex_reg+"

uuid_hyphen_reg="-{0,1}"

uuid_reg="($hex_reg{8})$uuid_hyphen_reg($hex_reg{4})$uuid_hyphen_reg($hex_reg{4})$uuid_hyphen_reg($hex_reg{4})$uuid_hyphen_reg($hex_reg{12})"

uuid_reg_no_capture="$uuid_reg"

while echo "$uuid_reg_no_capture" | grep -q -E "[()]" ; do
	uuid_reg_no_capture=$(echo "$uuid_reg_no_capture" | sed -E "s#[()]##")
done

binary_regex="[[:space:]]*($hex_addr_reg)[[:space:]]+-[[:space:]]+($hex_addr_reg)[[:space:]]+[+]{0,1}([^[:space:]]+) .*<($uuid_reg_no_capture)> (.*)"

grep -q -E "$binary_regex" "$crash_log" || (print_out_error "Bad format" && exit $UUIDERR)

uuids_result=`grep -E "$binary_regex" "$crash_log" | sed -E "s#<$uuid_reg>#<\1-\2\-\3-\4-\5>#" | sed -E "s#$binary_regex#\1\#\3\#\4\#\5#"`

path_result=()

sym_crash_log=()

while IFS= read -r line; do
	sym_crash_log+=("$line")
done < "$crash_log"

print_out ""

while read -r line; do
	product_name=""
	loader_addr=$(echo $line | cut -d '#' -f 1)
	product_name=$(echo $line | cut -d '#' -f 2)
	upper_uuid=$(echo $line | cut -d '#' -f 3 | tr "[:lower:]" "[:upper:]")
	bin_path=$(echo $line | cut -d '#' -f 4)
	loader_addr_regex="$loader_addr [+] $hex_addr_reg"
	if !(grep -E -q "$loader_addr_regex" "$crash_log"); then
		print_out_info "Skip finding dSYM for ${BOLD}$product_name${RESET}, since there is ${BOLD}NO${RESET} unsymbolicated address related to it"
		continue
	fi
	print_out_info "parsing begin ==============================="
	print_out_info "Binary Name: ${BOLD}$product_name${RESET}"
	print_out_info "Binary Path: ${BOLD}$bin_path ${RESET}"
	print_out_info "Binary dSYM UUID: ${BOLD}$upper_uuid ${RESET}"
	print_out_info "Binary Loader Address: ${BOLD}$loader_addr ${RESET}"
	if echo "$line" | grep -q -E "$app_name"; then
		print_out_info "finding application dSYM for ${BOLD}$product_name${RESET}"
		md_results=`mdfind "com_apple_xcode_dsym_uuids == $upper_uuid"`
		one_result=""
		while read -r md_result; do
			if [ -n "$one_result" ]; then
				break
			fi
			if mdls -name kMDItemContentType "$md_result" | grep -q "com.apple.xcode.dsym"; then
				print_out_info "found ${BOLD}dSYM package${RESET}: $md_result"
				one_result="$md_result"
			elif mdls -name kMDItemContentType "$md_result" | grep -q "com.apple.xcode.archive"; then
				print_out_info "try find dSYM in ${BOLD}Archive${RESET}: $md_result"
				all_dSYM_dirs=`find  "$md_result" -name "*.dSYM" -type d`
				while read -r dSYM_dir; do
					if [ -z "$one_result" ] && xcrun dwarfdump --uuid "$dSYM_dir" | grep -q "$upper_uuid"; then
						print_out_info "found dSYM [DIR] $md_result in Archive"
						one_result="$dSYM_dir"
					fi
				done <<< "$all_dSYM_dirs"
			fi
		done <<< "$md_results"
		if [ -n "$one_result" ]; then
			dsym_file=$(find "$one_result/Contents/Resources/DWARF" -name "*" -type f)
			print_out_info "found ${BOLD}dSYM object${RESET}: $dsym_file"
			path_result+=("$loader_addr#$product_name#$dsym_file")
		fi
	else
		print_out_info "finding system dSYM for ${BOLD}$product_name${RESET}"
		if (( $is_ios == 1 )) && [ -d "$my_root" ]; then
			lib_path="$my_root$bin_path"
			if [ -f "$lib_path" ]; then
				path_result+=("$loader_addr#$product_name#$lib_path")
			fi
		else
			print_out_info "Skipped"
		fi
	fi
	print_out_info "parsing end    ==============================="
done <<< "$uuids_result"

print_out ""

if [ ${#path_result[@]} -eq 0 ]; then 
	print_out_error "No binary found" && exit $BINERR
fi

for path_line in "${path_result[@]}"; do
	loader_addr=$(echo "$path_line" | cut -d '#' -f 1)
	product_name=$(echo "$path_line" | cut -d '#' -f 2)
	bin_file=$(echo "$path_line" | cut -d '#' -f 3)
	loader_addr_regex="($loader_addr [+] $hex_addr_reg)"
	if grep -q -E "$loader_addr_regex" "$crash_log"; then
		related_line_numbers=( $(grep -E -n "$loader_addr_regex" "$crash_log" | cut -d ":" -f 1) )
		for related_line_number in "${related_line_numbers[@]}"; do
			index=$(($related_line_number - 1))
			unsym_line=""
			unsym_line="${sym_crash_log[$index]}"
			addr_offset=$(echo "$unsym_line" | sed -E "s#.*$loader_addr_regex.*#\1#" | rev | cut -d " " -f 1 | rev)
			addr=$(ruby -e "puts ($loader_addr + $addr_offset).to_s(16)")
			addr="0x$addr"
			[ -f "$atos_out" ] && rm "$atos_out"
			if xcrun atos -arch "$my_arch" -o "$bin_file" -l "$loader_addr" "$addr" >> "$atos_out" || true ; then
				if [ -f "$atos_out" ]; then
					sym_line=$(cat "$atos_out")
					[ $is_crash -eq 1 ] && sym_line="$(echo "$unsym_line" | sed -E "s/$loader_addr_regex.*/$sym_line/")"
					[ $is_sample -eq 1 ] && sym_line="$(echo "$unsym_line" | sed -E "s/(.*)[?]{3}.*$loader_addr_regex(.*)/\1$sym_line\3/")"
					print_out_info "${BOLD}BEFORE${RESET}: $unsym_line"
					print_out_info "${BOLD}AFTER${RESET} : $sym_line"
					print_out ""
					sym_crash_log[$index]="$sym_line"
				else
					print_out_error "unknown error"
				fi
			fi
		done
	fi
done

[ -f "$output_path" ] && rm "$output_path"

touch "$output_path"

for i in "${sym_crash_log[@]}"; do
	echo "$i" >> "$output_path"
done

if $NO_OUTPUT == 'true' ; then
	mv "$output_path" "$output_path".crash && open "$output_path".crash
fi
