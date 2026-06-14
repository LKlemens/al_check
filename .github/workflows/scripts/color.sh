#!/bin/bash

if [ $# -eq 0 ]; then
  echo "ERROR: provide coverage number"
  exit 1
fi

# get rid of decimal part 22.3% -> 22
coverage=$(echo $1 | cut -d'.' -f-1)


# badge-action prepends '#', so emit hex (not named colors) to get valid #RRGGBB
if [[ $coverage -gt 90 ]]; then
    color="4c1"
elif [[ $coverage -gt 80 ]]; then
    color="97ca00"
elif [[ $coverage -gt 60 ]]; then
    color="a4a61d"
elif [[ $coverage -gt 40 ]]; then
    color="dfb317"
else
    color="e05d44"
fi

echo $color
