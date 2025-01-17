#!/bin/sh
set -e

pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

## Store script name
me=`basename "${0}"`

## Usage info
displayUsage()
{
    echo "********************************"
    echo "Monetha Platform on Docker usage"
    echo "********************************"
    echo "This script creates and starts a local private blockchain network using Docker."
    echo "You can select the type of network to use."
    echo "Usage: ${me} [OPTIONS]"
    echo "
        -n or --network <network>     : the name of the network that you want to use.
                                        Possible values: quorum, pantheon.
                                        Default value: quorum.
        -p or --private <false|true>  : indicates if private transaction mode should be enabled.
                                        Only works with Quorum network at the moment. 
                                        Value will be ignored for Pantheon.
                                        Default value: false."
    exit 0
}

## Output to error stream
echoerr() 
{ 
    echo -e "\n\n${@}\n\n" 1>&2; 
}

if [ "${NO_LOCK}" = "true" ]; then
  if [ -f ${LOCK_FILE} ]; then
    echoerr "Example has already been started (${LOCK_FILE} present)."
    echoerr "Restart containers with ./resume.sh, stop them with ./stop.sh, or remove with ./remove.sh."
    exit 1
  fi
else
  if [ ! -f ${LOCK_FILE} ]; then
    echoerr "Example was never started (${LOCK_FILE} not present)."
    echoerr "Start it by running ./start.sh first"
    exit 1
  fi
fi


## check if code is downloaded. If not - download
init_repo()
{
    echo "Downloading ${1} repo"
    NETWORK_REPO="$(tr [:lower:] [:upper:] <<< "MTH_${1}_REPO")"
    NETWORK_TAG="$(tr [:lower:] [:upper:] <<< "MTH_${1}_TAG")"
    DIR="${2}/${1}"

    if [ ! -d "${DIR}" ]; then
        git clone "${!NETWORK_REPO}" "${DIR}" 
    else
        pushd "${DIR}"
        git remote update --prune
        git checkout master
        git pull
        popd
    fi

    if [ ! -z "${!NETWORK_TAG}" ]; then
        pushd "${DIR}"
        git checkout "tags/${!NETWORK_TAG}"
        popd
    fi
}


start_network()
{
    NETWORK="${1}"

    case "${NETWORK}" in
        pantheon)
            PRIVATE="false"
            ;;
        *)
            PRIVATE="${2}"
            ;;
    esac

    init_repo "${NETWORK}" "${PWD}/networks"
    
    echo "Starting network ${NETWORK}"
    echo "network:${NETWORK}" >> "${LOCK_FILE}"
    echo "private:${PRIVATE}" >> "${LOCK_FILE}"

    case "${NETWORK}" in
        quorum)
            pushd "${PWD}/networks/quorum/"
            echo "dockerkdir:${PWD}" >> "${LOCK_FILE}"
            echo "dockerproject:mth_quorum" >> "${LOCK_FILE}"
            echo "dockernetwork:quorum-examples-net" >> "${LOCK_FILE}"
            docker-compose --project-name "mth_quorum" up -d
            popd
            ;;
        pantheon)
            pushd "${PWD}/networks/pantheon/"
            echo "dockerkdir:${PWD}" >> "${LOCK_FILE}"
            echo "dockerproject:mth_pantheon" >> "${LOCK_FILE}"
            echo "dockernetwork:mth_pantheon_default" >> "${LOCK_FILE}"
            export EXPLORER_PORT_MAPPING=21000
            docker-compose --project-name "mth_pantheon" up -d --scale node=4
            popd
            ;;
    esac
}


stop_network()
{
    NETWORK=`sed -n 's/^network:\(.*\)$/\1/p' ${LOCK_FILE}`
    DOCKER_DIR=`sed -n 's/^dockerkdir:\(.*\)$/\1/p' ${LOCK_FILE}`
    DOCKER_NETWORK_PROJECT=`sed -n 's/^dockerproject:\(.*\)$/\1/p' ${LOCK_FILE}`
    pushd "${DOCKER_DIR}"
    echo "Stopping network ${NETWORK}"
    docker-compose --project-name "${DOCKER_NETWORK_PROJECT}" stop
    echo "Done"
    popd
}


remove_network()
{
    NETWORK=`sed -n 's/^network:\(.*\)$/\1/p' ${LOCK_FILE}`
    DOCKER_DIR=`sed -n 's/^dockerkdir:\(.*\)$/\1/p' ${LOCK_FILE}`
    DOCKER_NETWORK_PROJECT=`sed -n 's/^dockerproject:\(.*\)$/\1/p' ${LOCK_FILE}`
    pushd "${DOCKER_DIR}"
    echo "Removing network ${NETWORK}"
    docker-compose --project-name "${DOCKER_NETWORK_PROJECT}" down
    echo "Done"
    popd
}


resume_network()
{
    NETWORK=`sed -n 's/^network:\(.*\)$/\1/p' ${LOCK_FILE}`
    DOCKER_DIR=`sed -n 's/^dockerkdir:\(.*\)$/\1/p' ${LOCK_FILE}`
    DOCKER_NETWORK_PROJECT=`sed -n 's/^dockerproject:\(.*\)$/\1/p' ${LOCK_FILE}`
    pushd "${DOCKER_DIR}"
    echo "Resuming network ${NETWORK}"
    docker-compose --project-name "${DOCKER_NETWORK_PROJECT}" start
    echo "Done"
    popd
}

pull_scanner()
{
    init_repo "scanner" "${PWD}/scanner"
}

build_scanner()
{
    NETWORK="${1}"

    pull_scanner
    echo "Building scanner"
    cp -f "${PWD}/scanner/networks.${NETWORK}.json" "${PWD}/scanner/scanner/networks.json"
    CONTRACTPASSPORTFACTORY=`sed -n 's/^contractPassportFactory:\(.*\)$/\1/p' ${LOCK_FILE}`
    sed -i "s/PASSPORTFACTORYADDRESS/${CONTRACTPASSPORTFACTORY}/g" "${PWD}/scanner/scanner/networks.json"
    pushd "${PWD}/scanner/scanner"
    echo "Build scanner: npm install"
    docker run --rm --user "node" --workdir "/source" --volume "${PWD}":"/source" node:"${NODEJS_VERSION}" npm install > /dev/null
    echo "Build scanner: npm run build"
    docker run --rm --user "node" --workdir "/source" --volume "${PWD}":"/source" node:"${NODEJS_VERSION}" npm run build > /dev/null
    popd
}

start_scanner()
{
    echo "Starting scanner on nginx container"
    pushd "${PWD}/scanner/scanner/build"
    docker run --detach --name "mth_scanner" --volume "${PWD}":"/usr/share/nginx/html" -p "${MTH_SCANNER_PORT}":80 nginx:alpine sh -c "sed -i '/location \/ {/a error_page 404 =200 /index.html;' /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'" > /dev/null
    echo "dockerscanner:mth_scanner" >> "${LOCK_FILE}"
    popd
}

stop_scanner()
{
    echo "Stopping scanner container"
    SCANNER=`sed -n 's/^dockerscanner:\(.*\)$/\1/p' ${LOCK_FILE}`
    docker stop "${SCANNER}" > /dev/null || true
}

resume_scanner()
{
    echo "Resuming scanner container"
    SCANNER=`sed -n 's/^dockerscanner:\(.*\)$/\1/p' ${LOCK_FILE}`
    docker start "${SCANNER}" > /dev/null
}

remove_scanner()
{
    echo "Removing scanner container"
    SCANNER=`sed -n 's/^dockerscanner:\(.*\)$/\1/p' ${LOCK_FILE}`
    docker rm -v "${SCANNER}" > /dev/null || true
}

pull_monetha_contracts()
{
    echo "Downloading MTH contracts"
    pushd "${PWD}/truffle"
    init_repo "contracts" "${PWD}/mth_contracts_repo"
    cp "${PWD}/mth_contracts_repo/contracts/package.json" "${PWD}/"
    cp "${PWD}/mth_contracts_repo/contracts/package-lock.json" "${PWD}/"
    cp -r "${PWD}/mth_contracts_repo/contracts/contracts/" "${PWD}/contracts/mth"
    popd
}

init_truffle_migrations()
{
    echo "Initialising truffle"
    pushd "${PWD}/truffle"
    docker run --rm --user "node" --workdir "/source" --volume "${PWD}":"/source" node:"${NODEJS_VERSION}" npm install > /dev/null
    docker run --rm --user "node" --workdir "/source" --volume "${PWD}":"/source" node:"${NODEJS_VERSION}" npm install "truffle-hdwallet-provider@1.0.17" > /dev/null
    popd
}

remove_monetha_contracts()
{
    echo "Removing contract related data"
    pushd "${PWD}/truffle"
    rm -rf "node_modules"
    rm -rf "contracts/mth"
    rm -rf "build"
    rm -f "package.json"
    rm -f "package-lock.json"
    rm -f "contracts.log"
    popd
}

run_migrations()
{
    if [ ! -d "${PWD}/truffle/contracts/mth" ]; then
        pull_monetha_contracts
        init_truffle_migrations
    fi
    echo "Running migration(s)"
    NETWORK=`sed -n 's/^network:\(.*\)$/\1/p' ${LOCK_FILE}`
    PRIVATE_TRANSACTIONS=`sed -n 's/^private:\(.*\)$/\1/p' ${LOCK_FILE}`
    DOCKER_NETWORK=`sed -n 's/^dockernetwork:\(.*\)$/\1/p' ${LOCK_FILE}`
    docker run -it --rm \
        --volume "${PWD}/":"/source" \
        --workdir "/source/truffle" \
        --network "${DOCKER_NETWORK}" \
        --env "PRIVATE_TRANSACTIONS=${PRIVATE_TRANSACTIONS}"\
        --env "NETWORK=${NETWORK}"\
        kepalas/truffle\
        compile
    docker run -it --rm \
        --volume "${PWD}/":"/source" \
        --workdir "/source/truffle" \
        --network "${DOCKER_NETWORK}" \
        --env "PRIVATE_TRANSACTIONS=${PRIVATE_TRANSACTIONS}"\
        --env "NETWORK=${NETWORK}"\
        kepalas/truffle\
        migrate --network "${NETWORK}"
}

output_contract_addresses()
{
    echo "Writing Monetha contract addresses to .lock file"
    NETWORK=`sed -n 's/^network:\(.*\)$/\1/p' ${LOCK_FILE}`
    PRIVATE_TRANSACTIONS=`sed -n 's/^private:\(.*\)$/\1/p' ${LOCK_FILE}`
    DOCKER_NETWORK=`sed -n 's/^dockernetwork:\(.*\)$/\1/p' ${LOCK_FILE}`
    docker run -it --rm \
        --volume "${PWD}/":"/source" \
        --workdir "/source/truffle" \
        --network "${DOCKER_NETWORK}" \
        --env "PRIVATE_TRANSACTIONS=${PRIVATE_TRANSACTIONS}"\
        --env "NETWORK=${NETWORK}"\
        --env "OUTPUT_FILE=${CONTRACT_OUTPUT_FILENAME}"\
        kepalas/truffle\
        exec "../helpers/list_contract_addresses.js" --network "${NETWORK}"
    awk '{print}' "${PWD}/truffle/${CONTRACT_OUTPUT_FILENAME}" >> "${LOCK_FILE}"
}

list_data()
{
    NETWORK=`sed -n 's/^network:\(.*\)$/\1/p' ${LOCK_FILE}`
    PRIVATE=`sed -n 's/^private:\(.*\)$/\1/p' ${LOCK_FILE}`
    PASSPORTFACTORY=`sed -n 's/^contractPassportFactory:\(.*\)$/\1/p' ${LOCK_FILE}`
    SCANNER_NAME=`sed -n 's/^dockerscanner:\(.*\)$/\1/p' ${LOCK_FILE}`
    SCANNER_PORT=`docker port ${SCANNER_NAME} 80`
    DOCKER_DIR=`sed -n 's/^dockerkdir:\(.*\)$/\1/p' ${LOCK_FILE}`
    DOCKER_NETWORK_PROJECT=`sed -n 's/^dockerproject:\(.*\)$/\1/p' ${LOCK_FILE}`

    echo "*********************************************"
    echo "Monetha Platform on Docker"
    echo "*********************************************"
    echo "Network: ${NETWORK}"
    echo "Private transactions: ${PRIVATE}"
    echo "Passport factory address: ${PASSPORTFACTORY}"
    echo "Scanner: http://localhost:${SCANNER_PORT##*:}"
    echo "*********************************************"
    echo "RPC endpoints"
    echo "*********************************************"
    cat "${PWD}/scanner/scanner/networks.json" | jq -cr '.networks[] | select(.url | test("localhost"))| "\(.name): \(.url)"'
    echo "*********************************************"
    echo "State of network nodes"
    echo "*********************************************"
    pushd "${DOCKER_DIR}"
    docker-compose --project-name "${DOCKER_NETWORK_PROJECT}" ps
    popd
}