#!/bin/bash

set -e

echo "Building ctags index..."
ctags -R

echo "Building cscope database..."
ack -f --cpp > cscope.files
cscope -b -q -k
rm cscope.files
