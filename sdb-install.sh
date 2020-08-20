#!/bin/bash

set -e

# Is DEBUG on?
((${DEBUG})) && set -x

HELP=0
if [[ "$1" == "--help" || $1 == "-h" ]]; then
  HELP=1
  SCRIPT=$(basename $0)
  echo "Usage: ${SCRIPT}"
  echo "Deploy a clean SequoiaDB cluster. Kill any existing sdb processes and"
  echo "remove all existing configuration and data files."
  echo ""
  echo "Options are passed in via environment variables."
fi

# Env vars:
: "${DEBUG:=0}"
((${HELP})) && echo "DEBUG (${DEBUG}): run verbosely"
: "${CLEANUP:=0}"
((${HELP})) && echo "CLEANUP (${CLEANUP}) only stop all processes and remove config and data"
: "${SDBDIR:=${HOME}/src/sequoiadb}"
((${HELP})) && echo "SDBDIR (${SDBDIR}) sequoiadb installation directory"
: "${DATADIR:=/opt/sdb}"
((${HELP})) && echo "DATADIR (${DATADIR}) database storage directory"
: "${GLOBTS:=1}"
((${HELP})) && echo "GLOBTS (${GLOBTS}) enable global transactions"
: "${PORT_OMA:=17643}"
((${HELP})) && echo "PORT_OMA (${PORT_OMA}) port for temporary cluster management object"
: "${PORT_COO:=50000}"
((${HELP})) && echo "PORT_COO (${PORT_COO}) port for the first coordinator (each node +10)"
: "${NUM_COO:=1}"
((${HELP})) && echo "NUM_COO (${NUM_COO}) number of nodes in coordinator replica group"
: "${PORT_CAT:=11800}"
((${HELP})) && echo "PORT_CAT (${PORT_CAT}) port for the first catalog (each node +10)"
: "${NUM_CAT:=1}"
((${HELP})) && echo "NUM_CAT (${NUM_CAT}) number of nodes in catalog replica group"
: "${PORT_DATA:=20000}"
((${HELP})) && echo "PORT_DATA (${PORT_DATA}) port for data replica group 1 node 1 (each group +100) (each node +10)"
: "${NUM_DATA_RG:=2}"
((${HELP})) && echo "NUM_DATA_RG (${NUM_DATA_RG}) number of data replica groups"
: "${NUM_DATA_RG_NODES:=1}"
((${HELP})) && echo "NUM_DATA_RG_NODES (${NUM_DATA_RG_NODES}) number of nodes in each data replica group"

((${HELP})) && exit

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

# Check vars
((${NUM_COO}>0))
((${NUM_CAT}>0))
((${NUM_DATA_RG}>0))
((${NUM_DATA_RG_NODES}>0))

# Default sdb configuration
((${GLOBTS})) && GLOBTSCONFIG="transactionon:true, mvccon:true, globtranson:true, transisolation:3,"
NODECONFIG="{${GLOBTSCONFIG} diaglevel:3, plancachelevel:3, clustername:'xxx', businessname:'yyy'}"
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
requireFile "sdb"
requireFile "sdbstart"
requireFile "sdbstop"
requireFile "sdbcmart"
requireFile "sdbcmtop"
requireFile "stp"

echo "Stopping any existing services"
${BIN}/sdbcmtop
${BIN}/sdbstop --all
pkill sdbbp || true
pkill stp || true
sleep 1

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

# Start the standard time protocol daemon
echo "Starting stp as a daemon"
${BIN}/stp --daemon

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
