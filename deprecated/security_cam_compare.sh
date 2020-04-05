#!/bin/bash

if [[ $# -gt 0 ]]; then
   args="$@"
else
   args="-metric MAE"
fi

FILES=$(ls -1U *.jpg | sort -V)

echo "USING compare ${args} <file1> <file2>"
echo "-------------------------------------------------------"

## Example filename transform
last=
for cur in ${FILES}
do
   if [[ -n "${last}" ]]; then
      diff=$(compare ${cur} ${last} ${args} /dev/null 2>&1)
      echo "${last#.jpg} -> ${cur#.jpg}: $diff"
   fi
   last="${cur}"
done

