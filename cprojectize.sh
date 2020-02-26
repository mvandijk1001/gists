#!/bin/bash

set -e

rm -f tags cscope.*

echo "Building ctags index..."
ctags -R

echo "Building cscope database..."
ack -f --cpp > cscope.files
cscope -b -q -k
rm cscope.files
