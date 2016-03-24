#!/bin/bash -ex

[ -f ".publisher-defaults-deb" ] && source .publisher-defaults-deb
source $(dirname $(readlink -e $0))/functions/publish-functions.sh
source $(dirname $(readlink -e $0))/functions/locking.sh

# Used global envvars
# ~~~~~~~~~~~~~~~~~~~

# Mixed from publish-functions.sh
# TMP_DIR           path to temporary directory
# WRK_DIR           path to current working directory

# Input parameters for downloading package(s) from given jenkins-worker
# SSH_OPTS          ssh options for rsync (could be empty)
# SSH_USER          user who have ssh access to the worker (could be empty)
# BUILD_HOST        fqdn/ip of worker
# PKG_PATH          path to package which should be download


# Patchset-related parameters
# LP_BUG                    string representing ref. to bug on launchpad
#                           used for grouping packages related to
#                           the same bug into one repository (3)
# GERRIT_CHANGE_STATUS      status of patchset, actually only "NEW" matters
# GERRIT_PATCHSET_REVISION  revision of patchset, used only in rendering
#                           final artifact (deb.publish.setenvfile)
# REQUEST_NUM               identifier of request CR-12345 (3)

# Repository paths configuration
# REPO_BASE_PATH            (1) first part of repo path
# REPO_REQUEST_PATH_PREFIX  (2) second part of repo path (optional)
# CUSTOM_REPO_ID            (3) third part - highest priority override (optional)
# *LP_BUG                   (3) third part - LP bug (optional)
# *REQUEST_NUM              (3) third part - used when no LP bug provided (optional)

# DEB_REPO_PATH             ?
# ORIGIN                    ?
# DEB_DIST_NAME             name of "/main" repo (for ex. mos8.0)
# DEB_PROPOSED_DIST_NAME    name of proposed repo (for ex. mos8.0-proposed) (optional)
# DEB_UPDATES_DIST_NAME     name of updates repo (for ex. mos8.0-updates) (optional)
# DEB_SECURITY_DIST_NAME    name of security repo (for ex. mos8.0-security) (optional)
# DEB_HOLDBACK_DIST_NAME    name of holdback repo (for ex. mos8.0-holdback) (optional)
# PRODUCT_VERSION           ?

# Directives for using different kinds of workflows which define output repos for packages
# (will be applied directive with highest priority)
# IS_UPDATES         p1. updates workflow -> publish to proposed repo
# IS_HOLDBACK        p2. holdback workflow -> publish to holdback repo (USE WITH CARE!)
# IS_SECURITY        p3. security workflow -> publish to security repo
# IS_RESTRICTED      force to set component name "restricted" (USE WITH CARE!)
# IS_DOWNGRADE       downgrade package: remove ONE previously published version of this package


# REMOTE_REPO_HOST

# Security-related variables
# SIGKEYID           user used for signing release files
# PROJECT_NAME       project name used for look up key file
# PROJECT_VERSION    project name used for look up key file

# Component parameters
# DEB_COMPONENT          (optional)
# DEB_UPDATES_COMPONENT
# DEB_PROPOSED_COMPONENT
# DEB_SECURITY_COMPONENT
# DEB_HOLDBACK_COMPONENT
# DIST                      Name of OS distributive (trusty, for ex.)

# Destination urls/repos:


# fixme: do we really need a function?
main() {
    local SIGN_STRING=""
    check-gpg && SIGN_STRING="true"

    # Reinitialize temp directory
    [ -d "${TMP_DIR}" ] && rm -rf "${TMP_DIR}"
    mkdir -p "${TMP_DIR}"


    # Download sources from worker
    # ============================


    rsync -avPzt \
          -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SSH_OPTS}" \
          # FIXME: Looks like we have a bug here and user and host should be separated.
          #        We didn't shoot-in-the leg IRL because we don't pass this param
          #        Prop. sol: [ -z "${SSH_USER}" ] && SSH_USER="${SSH_USER}@"
          "${SSH_USER}${BUILD_HOST}:${PKG_PATH}/" \
          "${TMP_DIR}/" \
    || error "Can't download packages"

    ## Resign source package
    ## FixMe: disabled for discussion: does it really need to sign
    #[ -n "${SIGN_STRING}" ] && \
    #    for _dscfile in $(find ${TMP_DIR} -name "*.dsc") ; do
    #        debsign -pgpg --re-sign -k${SIGKEYID} ${_dscfile}
    #    done

    # Create all repositories


    # Crunch for using custom namespace for publishing packages
    # When CUSTOM_REPO_ID is given, then:
    # - packages are not grouped by bug
    # - CUSTOM_REPO_ID is used instead of request serial number

    if [ -n "${CUSTOM_REPO_ID}" ] ; then
        unset LP_BUG
        REQUEST_NUM="${CUSTOM_REPO_ID}"
    fi


    # Configuring paths and namespaces
    # ================================


    # Defining url prefix and paths:
    # - only newly created patchsets have prefixes
    # - if LP_BUG is given then it replaces REQUEST_NUM
    # FIXME: do not mutate REPO_BASE_PATH, use local variable instead
    local URL_PREFIX=
    if [ "${GERRIT_CHANGE_STATUS}" = "NEW" ] ; then
        if [ -n "${LP_BUG}" ] ; then
            REPO_BASE_PATH="${REPO_BASE_PATH}/${REPO_REQUEST_PATH_PREFIX}${LP_BUG}"
            URL_PREFIX="${REPO_REQUEST_PATH_PREFIX}${LP_BUG}/"
        else
            REPO_BASE_PATH="${REPO_BASE_PATH}/${REPO_REQUEST_PATH_PREFIX}${REQUEST_NUM}"
            URL_PREFIX="${REPO_REQUEST_PATH_PREFIX}${REQUEST_NUM}/"
        fi
    else
        REPO_BASE_PATH="${REPO_BASE_PATH}/${REPO_REQUEST_PATH_PREFIX}"
        URL_PREFIX=""
    fi


    # Configuring repository
    # ======================


    local LOCAL_REPO_PATH="${REPO_BASE_PATH}/${DEB_REPO_PATH}"
    local DBDIR="+b/db"
    local CONFIGDIR="${LOCAL_REPO_PATH}/conf"
    local DISTDIR="${LOCAL_REPO_PATH}/public/dists/"
    local OUTDIR="+b/public/"


    if [ ! -d "${CONFIGDIR}" ] ; then
        mkdir -p "${CONFIGDIR}"

        job_lock "${CONFIGDIR}.lock" wait 3600

            for dist_name in "${DEB_DIST_NAME}"          \
                             "${DEB_PROPOSED_DIST_NAME}" \
                             "${DEB_UPDATES_DIST_NAME}"  \
                             "${DEB_SECURITY_DIST_NAME}" \
                             "${DEB_HOLDBACK_DIST_NAME}" ; do


                echo "Origin: ${ORIGIN}"                  >> "${CONFIGDIR}/distributions"
                echo "Label: ${DEB_DIST_NAME}"            >> "${CONFIGDIR}/distributions"
                echo "Suite: ${dist_name}"                >> "${CONFIGDIR}/distributions"
                echo "Codename: ${dist_name}"             >> "${CONFIGDIR}/distributions"
                echo "Version: ${PRODUCT_VERSION}"        >> "${CONFIGDIR}/distributions"
                echo "Architectures: amd64 i386 source"   >> "${CONFIGDIR}/distributions"
                echo "Components: main restricted"        >> "${CONFIGDIR}/distributions"
                echo "UDebComponents: main restricted"    >> "${CONFIGDIR}/distributions"
                echo "Contents: . .gz .bz2"               >> "${CONFIGDIR}/distributions"
                echo ""                                   >> "${CONFIGDIR}/distributions"

                reprepro --basedir "${LOCAL_REPO_PATH}" \
                         --dbdir   "${DBDIR}"           \
                         --outdir  "${OUTDIR}"          \
                         --distdir "${DISTDIR}"         \
                         --confdir "${CONFIGDIR}"       \
                         export    "${dist_name}"

                # Fix Codename field
                local release_file="${DISTDIR}/${dist_name}/Release"

                sed "s|^Codename:.*$|Codename: ${DEB_DIST_NAME}|" -i "${release_file}"
                rm -f "${release_file}.gpg"

                # ReSign Release file
                if [ -n "${SIGN_STRING}" ] ; then
                    gpg --sign \
                        --local-user "${SIGKEYID}" \
                        -ba \
                        -o "${release_file}.gpg" "${release_file}"
                fi
            done

        job_lock "${CONFIGDIR}.lock" unset

    fi

    local DEB_BASE_DIST_NAME="${DEB_DIST_NAME}"

    # Filling dist names and components with default values in case when they are not set
    # This means that when they are unset, we will work with main repo aka DEB_BASE_DIST_NAME

    # dist names
    [ -z "${DEB_UPDATES_DIST_NAME}" ]  && DEB_UPDATES_DIST_NAME="${DEB_DIST_NAME}"
    [ -z "${DEB_PROPOSED_DIST_NAME}" ] && DEB_PROPOSED_DIST_NAME="${DEB_DIST_NAME}"
    [ -z "${DEB_SECURITY_DIST_NAME}" ] && DEB_SECURITY_DIST_NAME="${DEB_DIST_NAME}"
    [ -z "${DEB_HOLDBACK_DIST_NAME}" ] && DEB_HOLDBACK_DIST_NAME="${DEB_DIST_NAME}"

    # components
    [ -z "${DEB_UPDATES_COMPONENT}" ]  && DEB_UPDATES_COMPONENT="${DEB_COMPONENT}"
    [ -z "${DEB_PROPOSED_COMPONENT}" ] && DEB_PROPOSED_COMPONENT="${DEB_COMPONENT}"
    [ -z "${DEB_SECURITY_COMPONENT}" ] && DEB_SECURITY_COMPONENT="${DEB_COMPONENT}"
    [ -z "${DEB_HOLDBACK_COMPONENT}" ] && DEB_HOLDBACK_COMPONENT="${DEB_COMPONENT}"

    # Processing different kinds of input directives "IS_XXX"
    # FIXME: do not rewrite DEB_DIST_NAME and DEB_COMPONENT, use local variables instead
    if [ "${IS_UPDATES}" = 'true' ] ; then
        DEB_DIST_NAME=${DEB_PROPOSED_DIST_NAME}
        DEB_COMPONENT=${DEB_PROPOSED_COMPONENT}
    fi

    if [ "${IS_HOLDBACK}" = 'true' ] ; then
        DEB_DIST_NAME=${DEB_HOLDBACK_DIST_NAME}
        DEB_COMPONENT=${DEB_HOLDBACK_COMPONENT}
    fi

    if [ "${IS_SECURITY}" = 'true' ] ; then
        DEB_DIST_NAME=${DEB_SECURITY_DIST_NAME}
        DEB_COMPONENT=${DEB_SECURITY_COMPONENT}
    fi

    if [ -z "${DEB_COMPONENT}" ] ; then
        DEB_COMPONENT=main
    fi

    if [ "${IS_RESTRICTED}" = 'true' ] ; then
        DEB_COMPONENT=restricted
    fi

    local REPREPRO_OPTS="--verbose                    \
                         --basedir ${LOCAL_REPO_PATH} \
                         --dbdir   ${DBDIR}           \
                         --outdir  ${OUTDIR}          \
                         --distdir ${DISTDIR}         \
                         --confdir ${CONFIGDIR}"
    local REPREPRO_COMP_OPTS="${REPREPRO_OPTS}        \
                         --component ${DEB_COMPONENT}"

    # Parse incoming files
    # ====================

    # Aggregate list of files for further processing
    local BINDEBLIST=""
    local BINDEBNAMES=""
    local BINUDEBLIST=""
    local BINSRCLIST=""
    for binary in ${TMP_DIR}/* ; do
        case ${binary##*.} in
            deb)
                BINDEBLIST="${BINDEBLIST} ${binary}"
                BINDEBNAMES="${BINDEBNAMES} ${binary##*/}"
            ;;
            udeb)
                BINUDEBLIST="${BINUDEBLIST} ${binary}"
            ;;
            dsc)
                # FIXME: here we don't extend list, why?
                BINSRCLIST="${binary}"
            ;;
        esac
    done

    job_lock "${CONFIGDIR}.lock" wait 3600

        # Get source name - this name represents sources from which package(s) was built
        # FIXME: what will happen if we will work with list of packages built from different sources?
        local SRC_NAME=$(awk '/^Source:/ {print $2}' ${BINSRCLIST})

        # Get queued version of package related to the SRC_NAME
        local NEW_VERSION=$(awk '/^Version:/ {print $2}' ${BINSRCLIST} | head -n 1)

        # Get currently published version of package related to the SRC_NAME
        local OLD_VERSION=$(                                                \
            reprepro ${REPREPRO_OPTS}                                       \
                     --list-format '${version}\n'                           \
                     listfilter ${DEB_DIST_NAME} "Package (==${SRC_NAME})"  \
            | sort -u                                                       \
            | head -n 1                                                     \
        )

        [ "${OLD_VERSION}" == "" ] && OLD_VERSION=none

        # Remove existing packages for requests-on-review and downgrades
        # FIXME: why do we call reprepro .. removesrc if there was no prev version?
        if [ "${GERRIT_CHANGE_STATUS}" = "NEW" -o "${IS_DOWNGRADE}" == "true" ] ; then
            reprepro ${REPREPRO_OPTS} removesrc "${DEB_DIST_NAME}" "${SRC_NAME}" "${OLD_VERSION}" \
            || true
        fi

        # Add .deb binaries
        if [ "${BINDEBLIST}" != "" ]; then
            reprepro ${REPREPRO_COMP_OPTS} includedeb ${DEB_DIST_NAME} ${BINDEBLIST} \
            || error "Can't include .deb packages"
        fi

        # Add .udeb binaries
        if [ "${BINUDEBLIST}" != "" ]; then
            reprepro ${REPREPRO_COMP_OPTS} includeudeb ${DEB_DIST_NAME} ${BINUDEBLIST} \
            || error "Can't include .udeb packages"
        fi

        # Replace sources
        # TODO: Get rid of replacing. Just increase version properly
        if [ "${BINSRCLIST}" != "" ]; then
            reprepro ${REPREPRO_COMP_OPTS}               \
                     --architecture source               \
                     remove ${DEB_DIST_NAME} ${SRC_NAME} \
            || true

            reprepro ${REPREPRO_COMP_OPTS}                     \
                     includedsc ${DEB_DIST_NAME} ${BINSRCLIST} \
            || error "Can't include packages"
        fi


        # Cleanup files from previous version
        # FIXME: Why do we remove it again, and w/o preconditions?
        if [ "${OLD_VERSION}" != "${NEW_VERSION}" ] ; then
            reprepro ${REPREPRO_OPTS} removesrc "${DEB_DIST_NAME}" "${SRC_NAME}" "${OLD_VERSION}"
        fi

        # Fix Codename field
        local release_file="${DISTDIR}/${DEB_DIST_NAME}/Release"
        sed "s|^Codename:.*$|Codename: ${DEB_BASE_DIST_NAME}|" -i ${release_file}

        # Resign Release file
        rm -f "${release_file}.gpg"

        local pub_key_file="${LOCAL_REPO_PATH}/public/archive-${PROJECT_NAME}${PROJECT_VERSION}.key"
        if [ -n "${SIGN_STRING}" ] ; then
            gpg --sign --local-user "${SIGKEYID}" -ba -o "${release_file}.gpg" "${release_file}"

            [ ! -f "${pub_key_file}" ] && touch ${pub_key_file}

            gpg -o "${pub_key_file}.tmp" --armor --export "${SIGKEYID}"
            if diff -q "${pub_key_file}" "${pub_key_file}.tmp" &>/dev/null ; then
                rm "${pub_key_file}.tmp"
            else
                mv "${pub_key_file}.tmp" "${pub_key_file}"
            fi
        else
            rm -f "${pub_key_file}"
        fi

        sync-repo "${OUTDIR}" "${DEB_REPO_PATH}" "${REPO_REQUEST_PATH_PREFIX}" "${REQUEST_NUM}" "${LP_BUG}"

    job_lock "${CONFIGDIR}.lock" unset


    # Filling report file and export results
    # ======================================

    local DEB_REPO_URL="\"http://${REMOTE_REPO_HOST}/${URL_PREFIX}${DEB_REPO_PATH} ${DEB_DIST_NAME} ${DEB_COMPONENT}\""
    local DEB_BINARIES="$(              \
        cat ${BINSRCLIST}               \
        | grep ^Binary                  \
        | sed 's|^Binary:||; s| ||g'    \
    )"

    rm -f "${WRK_DIR}/deb.publish.setenvfile"
    echo > "${WRK_DIR}/deb.publish.setenvfile"
    echo "DEB_PUBLISH_SUCCEEDED=true"       >> "${WRK_DIR}/deb.publish.setenvfile"
    echo "DEB_DISTRO=${DIST}"               >> "${WRK_DIR}/deb.publish.setenvfile"
    echo "DEB_REPO_URL=${DEB_REPO_URL}"     >> "${WRK_DIR}/deb.publish.setenvfile"
    echo "DEB_PACKAGENAME=${SRC_NAME}"      >> "${WRK_DIR}/deb.publish.setenvfile"
    echo "DEB_VERSION=${NEW_VERSION}"       >> "${WRK_DIR}/deb.publish.setenvfile"
    echo "DEB_BINARIES=${DEB_BINARIES}"     >> "${WRK_DIR}/deb.publish.setenvfile"
    echo "DEB_CHANGE_REVISION=${GERRIT_PATCHSET_REVISION}" \
                                            >> "${WRK_DIR}/deb.publish.setenvfile"
    echo "LP_BUG=${LP_BUG}"                 >> "${WRK_DIR}/deb.publish.setenvfile"

}

main

exit 0