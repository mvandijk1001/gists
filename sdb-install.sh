#!/bin/bash

set -e

# Is DEBUG on?
((${DEBUG})) && set -x

function errReport() {
echo "Error on line $(caller)" >&2
}
trap errReport ERR

# Util: like python's str.join()
# Example: $ join_by , a "b c" d
#          $ a,b c,d
function join_by() {
local IFS="$1"
shift
echo "$*";
}

# Env vars:
# DEBUG    : run verbosely
: "${DEBUG:=0}"
# CLEANUP  : only stop all processes and remove config and data
: "${CLEANUP:=0}"
# SDBDIR   : sequoiadb installation directory
: "${SDBDIR:=${HOME}/src/sequoiadb}"
# DATADIR  : database storage directory
: "${DATADIR:=/opt/sdb}"
# PORT_OMA : port for temporary cluster management object
: "${PORT_OMA:=17643}"
# PORT_COO : port for the first coordinator (each node +10)
: "${PORT_COO:=50000}"
# NUM_COO  : number of nodes in coordinator replica group
: "${NUM_COO:=3}"
# PORT_CAT : port for the first catalog (each node +10)
: "${PORT_CAT:=11800}"
# NUM_CAT  : number of nodes in catalog replica group
: "${NUM_CAT:=3}"
# PORT_DB  : port for data replica group 1 node 1 (each group +100) (each node +10)
: "${PORT_DATA:=20000}"
# NUM_DATA_RG : number of data replica groups
: "${NUM_DATA_RG:=3}"
# NUM_DATA_RG_NODES : number of nodes in each data replica group
: "${NUM_DATA_RG_NODES:=3}"

# Check vars
((${NUM_COO}>0))
((${NUM_CAT}>0))
((${NUM_DATA_RG}>0))
((${NUM_DATA_RG_NODES}>0))

# Default sdb configuration
NODECONFIG="{diaglevel:3, plancachelevel:3, clustername:'xxx', businessname:'yyy'}"
HOSTNAME=`hostname`
DB_VAR="db"

echo "Using data dir ${DATADIR}"

echo "Using sdb dir ${SDBDIR}"
BIN="${SDBDIR}/bin"
CONF="${SDBDIR}/conf"

function requireFile() {
local FILE="${BIN}/${1}"
echo "Checking for ${FILE}"
test -f "${FILE}"
}
requireFile "sdbstart"
requireFile "sdbstop"
requireFile "sdbcmart"
requireFile "sdbcmtop"

echo "Stopping any existing services"
${BIN}/sdbcmtop
${BIN}/sdbstop --all

echo "Cleaning up any old configuration files"
if test -d "${CONF}/local"; then
  rm -r ${CONF}/local
fi
mkdir -p ${CONF}/local

echo "Cleaning up any old data files"
if test -d "${DATADIR}"; then
  rm -rf ${DATADIR}/*
fi
mkdir -p ${DATADIR}

echo "Stopping sdbbp"
pkill sdbbp || true

((${CLEANUP})) && echo "Cleanup complete" && exit

function createNode() {
local TAG=$1
local VAR=$2
local PORT=$3
echo "Creating ${TAG} node (${PORT})"
${BIN}/sdb -s "${VAR}.createNode('${HOSTNAME}', '${PORT}', '${DATADIR}/${PORT}', $NODECONFIG);"
}

# Start the cluster manager
echo "Starting sdbcm"
${BIN}/sdbcmart -i

echo "Starting the temporary cluster management object (${PORT_OMA})"
${BIN}/sdb -s \
 "var oma = new Oma();
  oma.createCoord('${PORT_OMA}', '${DATADIR}/${PORT_OMA}', ${NODECONFIG});
  oma.startNode('${PORT_OMA}');"
${BIN}/sdb -s \
 "var ${DB_VAR};
  for (var i=0; i < 60; ++i) {
    try {
      ${DB_VAR} = new Sdb('localhost', '${PORT_OMA}');
      break;
    } catch(e) {
      sleep(1000);
    }
  }"

echo "Creating the catalog node (${PORT_CAT})"
${BIN}/sdb -s \
 "${DB_VAR}.createCataRG('${HOSTNAME}', '${PORT_CAT}', '${DATADIR}/${PORT_CAT}', ${NODECONFIG});
  for (var i=0; i < 60; ++i) {
    try {
      var cata = new Sdb('localhost', '${PORT_CAT}');
      cata.close();
      break;
    } catch(e) {
      sleep(1000);
    }
  }"

# Create any additional catalog nodes
if [[ ${NUM_CAT} > 1 ]]; then
  CATA_RG_VAR="cataRG"
  ${BIN}/sdb -s "var ${CATA_RG_VAR} = ${DB_VAR}.getRG('SYSCatalogGroup');"
  PORT=${PORT_CAT}
  for N in $(seq 2 ${NUM_CAT}); do
    PORT=$((PORT+10))
    createNode "catalog" "${CATA_RG_VAR}" "${PORT}"
  done
  echo "Starting the catalog replica group"
  ${BIN}/sdb -s "${CATA_RG_VAR}.start();"
  sleep 5
fi

# Create the data nodes
function createDataRG() {
local RG=$1
local PORT=$2
local RG_VAR="rg${RG}"
local RG_NAME="db${RG}"
echo "Creating data replica group ${RG_NAME}"
${BIN}/sdb -s "var ${RG_VAR}=${DB_VAR}.createRG('${RG_NAME}');"
for N in $(seq 1 ${NUM_DATA_RG_NODES}); do
  createNode "${RG_NAME}" "${RG_VAR}" "${PORT}"
  PORT=$((PORT+10))
done
}

PORT_RG=${PORT_DATA}
RG_LIST=""
for RG in $(seq 1 ${NUM_DATA_RG}); do
  createDataRG ${RG} ${PORT_RG}
  PORT_RG=$((PORT_RG+100))
  RG_LIST+="'db${RG}' "
done
RG_COMMA_SEPARATED_LIST=$(join_by , $RG_LIST)
${BIN}/sdb -s "${DB_VAR}.startRG(${RG_COMMA_SEPARATED_LIST});"

echo "Creating the coordinator replica group"
COORD_RG_VAR="coord"
${BIN}/sdb -s "var ${COORD_RG_VAR} = ${DB_VAR}.createCoordRG();"
PORT=${PORT_COO}
for N in $(seq 1 ${NUM_COO}); do
  createNode "coordinator" "${COORD_RG_VAR}" "${PORT}"
  PORT=$((PORT+10))
done
${BIN}/sdb -s \
 "${COORD_RG_VAR}.start();
  oma.removeCoord('${PORT_OMA}');
  ${DB_VAR}.close();"

echo "Testing connections to coordinator and first data nodes"
${BIN}/sdb -s \
 "var db;
  var db1;
  for (var i=0; i < 60; ++i) {
    try {
      db = new Sdb('localhost', '${PORT_COO}');
      db1 = new Sdb('localhost', '${PORT_DATA}');
      db.close();
      db1.close();
      break;
    } catch(e) {
      sleep(1000);
    }
  }"

echo "Cluster creation complete"
