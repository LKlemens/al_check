#!/bin/bash

if [ $# -eq 0 ]; then
  echo "ERROR: provide coverage number"
  exit 1
fi

# get rid of decimal part 22.3% -> 22
coverage=$(echo $1 | cut -d'.' -f-1)


if [[ $coverage -gt 90 ]]; then
    color="brightgreen"
elif [[ $coverage -gt 80 ]]; then
    color="green"
elif [[ $coverage -gt 60 ]]; then
    color="yellowgreen"
elif [[ $coverage -gt 40 ]]; then
    color="yellow"
else
    color="red"
fi

echo $color
