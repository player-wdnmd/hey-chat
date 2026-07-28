#!/bin/sh

set -eu

case "${PROJECT_DIR:-}" in
    ""|"/")
        echo "error: PROJECT_DIR is not a safe project path"
        exit 1
        ;;
esac

source_app="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
destination_dir="${PROJECT_DIR}/build/Release"
destination_app="${destination_dir}/hey chat.app"
staging_app="${destination_dir}/.hey chat.app.staging"
legacy_app="${destination_dir}/ChatMac.app"
legacy_dsym="${destination_dir}/ChatMac.app.dSYM"
legacy_swiftmodule="${destination_dir}/ChatMac.swiftmodule"
previous_name_app="${destination_dir}/agent caht.app"

if [ ! -d "${source_app}" ]; then
    echo "error: Built app not found at ${source_app}"
    exit 1
fi

if [ "${source_app}" = "${destination_app}" ]; then
    exit 0
fi

/bin/mkdir -p "${destination_dir}"
/bin/rm -rf "${staging_app}"
/usr/bin/ditto "${source_app}" "${staging_app}"
/bin/rm -rf "${destination_app}"
/bin/mv "${staging_app}" "${destination_app}"
/bin/rm -rf "${legacy_app}"
/bin/rm -rf "${legacy_dsym}"
/bin/rm -rf "${legacy_swiftmodule}"
/bin/rm -rf "${previous_name_app}"
/usr/bin/touch "${destination_app}"

echo "Updated ${destination_app} from ${CONFIGURATION} build"
