#!/bin/sh

set -e
set -u
set -o pipefail

cd "$(dirname $0)"

TEST_DIR="$(pwd)/submodule/MacSymbolicatorTests/Resources"

if [ ! -d "$TEST_DIR" ] ;then
	echo "resource not found"
	exit 0
fi

if !(which diff >/dev/null); then
	echo "diff is reqired"
	exit 0
fi

function test_and_remove {
	orignal_report=$1
	temp_report=$2
	expected_report=$3
	local ret_v=0
	[ -f "$orignal_report" ] || ret_v=1
	until [ $ret_v -eq 0 ]; do echo "$ret_v" && return 0; done

	[ -f "$expected_report" ] || ret_v=2
	until [ $ret_v -eq 0 ]; do echo "$ret_v" && return 0; done

	[ -f "$temp_report" ] && rm "$temp_report"
	./symbolicate.sh -f "$orignal_report" -o "$temp_report" || ret_v=3
	while [ $ret_v -eq 0 ]; do diff --ignore-all-space --text --report-identical-files "$temp_report" "$expected_report" | grep -q "are identical" || ret_v=4; break; done
	[ -f "$temp_report" ] && rm "$temp_report"
	echo "$ret_v" && return 0
}

function explain_error_code {
	local result=$1
	if [[ $result == 0 ]]; then
		echo "OK"
	elif [[ $result == 1 ]]; then
		echo "unsymbolicated file not exist"
	elif [[ $result == 2 ]]; then
		echo "symbolicated file to compare not exist"
	elif [[ $result == 3 ]]; then
		echo "symbolicating error"
	elif [[ $result == 4 ]]; then
		echo "diff error"
	else
		echo "unknown error: $result"
	fi
}

result1=$(test_and_remove "$TEST_DIR"/ios-report.crash "$TEST_DIR"/ios-report_temp.crash "$TEST_DIR"/ios-report_symbolicated.crash)
explain_error_code $result1

result2=$(test_and_remove "$TEST_DIR"/report.crash "$TEST_DIR"/report_temp.crash "$TEST_DIR"/report_symbolicated.crash)
explain_error_code $result2


result3=$(test_and_remove "$TEST_DIR"/singlethread-sample.txt "$TEST_DIR"/singlethread-sample-temp.txt "$TEST_DIR"/singlethread-sample_symbolicated.txt)
explain_error_code $result3

result4=$(test_and_remove "$TEST_DIR"/multithread-sample.txt "$TEST_DIR"/multithread-sample-temp.txt "$TEST_DIR"/multithread-sample_symbolicated.txt)
explain_error_code $result4

