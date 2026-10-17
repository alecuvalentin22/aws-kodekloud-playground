#!/bin/sh
# greet.sh [NAME] [WHERE]  -> prints "hello NAME from WHERE"
echo "hello ${1:-world} from ${2:-local}"
