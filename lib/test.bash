if [ -z $ODOO_HELPER_LIB ]; then
    echo "Odoo-helper-scripts seems not been installed correctly.";
    echo "Reinstall it (see Readme on https://github.com/katyukha/odoo-helper-scripts/)";
    exit 1;
fi

if [ -z $ODOO_HELPER_COMMON_IMPORTED ]; then
    source $ODOO_HELPER_LIB/common.bash;
fi

# require other odoo-helper modules
ohelper_require fetch;
ohelper_require server;
ohelper_require db;
# ----------------------------------------------------------------------------------------


# create_tmp_dirs
function create_tmp_dirs {
    TMP_ROOT_DIR="/tmp/odoo-tmp-`random_string 16`";
    echov "Temporary dir created: $TMP_ROOT_DIR";

    OLD_ADDONS_DIR=$ADDONS_DIR;
    OLD_DOWNLOADS_DIR=$DOWNLOADS_DIR;
    OLD_ODOO_TEST_CONF_FILE=$ODOO_TEST_CONF_FILE;
    ADDONS_DIR=$TMP_ROOT_DIR/addons;
    DOWNLOADS_DIR=$TMP_ROOT_DIR/downloads;
    ODOO_TEST_CONF_FILE=$TMP_ROOT_DIR/odoo.test.conf;
    
    mkdir -p $ADDONS_DIR;
    mkdir -p $DOWNLOADS_DIR;
    sed -r "s@addons_path(.*)@addons_path\1,$ADDONS_DIR@" $OLD_ODOO_TEST_CONF_FILE > $ODOO_TEST_CONF_FILE
}

# remove_tmp_dirs
function remove_tmp_dirs {
    if [ -z $TMP_ROOT_DIR ]; then
        exit -1;  # no tmp root was created
    fi

    ADDONS_DIR=$OLD_ADDONS_DIR;
    DOWNLOADS_DIR=$OLD_DOWNLOADS_DIR;
    ODOO_TEST_CONF_FILE=$OLD_ODOO_TEST_CONF_FILE;
    rm -rf $TMP_ROOT_DIR;

    echov "Temporary dir removed: $TMP_ROOT_DIR";
    TMP_ROOT_DIR=;
    OLD_ADDONS_DIR=;
    OLD_DOWNLOADS_DIR=;
    OLD_ODOO_TEST_CONF_FILE=$ODOO_TEST_CONF_FILE;
}

# test_module_impl <module> [extra_options]
# example: test_module_impl base -d test1
function test_module_impl {
    local module=$1
    shift;  # all next arguments will be passed to server

    set +e; # do not fail on errors
    # Install module
    run_server_impl -c $ODOO_TEST_CONF_FILE --init=$module --log-level=warn --stop-after-init \
        --no-xmlrpc --no-xmlrpcs "$@";
    # Test module
    run_server_impl -c $ODOO_TEST_CONF_FILE --update=$module --log-level=test --test-enable --stop-after-init \
        --no-xmlrpc --no-xmlrpcs --workers=0 "$@";
    set -e; # Fail on any error
}


# test_module [--create-test-db] -m <module_name>
# test_module [--tmp-dirs] [--create-test-db] -m <module name> -m <module name>
function test_module {
    local modules="";
    local cs_modules="";
    local link_module_args="";
    local test_log_file="${LOG_DIR:-.}/odoo.test.log";
    local odoo_extra_options="";
    local usage="
    Usage 

        $SCRIPT_NAME test_module [options] [-m <module_name>] [-m <module name>] ...

    Options:
        --create-test-db    - Creates temporary database to run tests in
        --remove-log-file   - If set, then log file will be removed after tests finished
        --link <repo>:[module_name]
        --tmp-dirs          - use temporary dirs for test related downloads and addons
        --no-rm-tmp-dirs    - not remove temporary directories that was created for this test
        --no-tee            - this option disable duplication of output to log file.
                              it is implemented as workaroud of bug, when chaining 'tee' command
                              to openerp-server removes all colors of output.
        --reinit-base       - this option adds 'base' module to init list. this is way to reload module list in existing database
        --fail-on-warn      - if this option passed, then tests will fail even on warnings
    ";

    # Parse command line options and run commands
    if [[ $# -lt 1 ]]; then
        echo "No options/commands supplied $#: $@";
        echo "$usage";
        exit 0;
    fi

    while [[ $# -gt 0 ]]
    do
        key="$1";
        case $key in
            -h|--help|help)
                echo "$usage";
                exit 0;
            ;;
            --create-test-db)
                local create_test_db=1;
            ;;
            --remove-log-file)
                local remove_log_file=1;
            ;;
            --reinit-base)
                local reinit_base=1;
            ;;
            --fail-on-warn)
                local fail_on_warn=1;
            ;;
            -m|--module)
                modules="$modules $2";  # add module to module list
                shift;
            ;;
            --link)
                link_module_args=$link_module_args$'\n'$2;
                shift;
            ;;
            --tmp-dirs)
                local tmp_dirs=1
            ;;
            --no-rm-tmp-dirs)
                local not_remove_tmp_dirs=1;
            ;;
            --no-tee)
                local no_tee=1;
            ;;
            *)
                echo "Unknown option: $key";
                exit 1;
            ;;
        esac;
        shift;
    done;

    if [ ! -z $tmp_dirs ]; then
        create_tmp_dirs;
    fi

    if [ ! -z "$link_module_args" ]; then
        for lm_arg in $link_module_args; do
            local lm_arg_x=`echo $lm_arg | tr ':' ' '`;
            link_module $lm_arg_x;
        done
    fi

    if [ ! -z $create_test_db ]; then
        local test_db_name=`random_string 24`;
        test_log_file="${LOG_DIR:-.}/odoo.test.db.$test_db_name.log";
        echo -e "Creating test database: ${YELLOWC}$test_db_name${NC}";
        odoo_create_db $test_db_name $ODOO_TEST_CONF_FILE;
        echov "Test database created successfully";
        odoo_extra_options="$odoo_extra_options -d $test_db_name";
    else
        local test_log_file="${LOG_DIR:-.}/odoo.test.`random_string 24`.log";
    fi

    if [ ! -z $reinit_base ]; then
        echo -e "${BLUEC}Reinitializing base module...${NC}";
        run_server_impl -c $ODOO_TEST_CONF_FILE $odoo_extra_options --init=base --log-level=warn \
            --stop-after-init --no-xmlrpc --no-xmlrpcs;
    fi

    for module in $modules; do
        echo -e "${BLUEC}Testing module $module...${NC}";
        if [ -z $no_tee ]; then
            # TODO: applying tee in this way makes output not colored
            test_module_impl $module $odoo_extra_options | tee -a $test_log_file;
        else
            test_module_impl $module $odoo_extra_options;
        fi
    done


    if [ ! -z $create_test_db ]; then
        echo  -e "${BLUEC}Droping test database: $test_db_name${NC}";
        odoo_drop_db $test_db_name $ODOO_TEST_CONF_FILE
    fi

    # remove color codes from log file
    sed -ri "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g" $test_log_file;

    # Check log for warnings
    local warnings=0;
    if grep -q -e "no access rules, consider adding one" \
               -e "WARNING" \
               "$test_log_file"; then
        warnings=1;
        echo -e "${YELLOWC}Warings found while testing${NC}";
    fi


    # Standard log processing
    local res=0;
    if grep -q -e "CRITICAL" \
               -e "ERROR $test_db_name" \
               -e "At least one test failed" \
               -e "invalid module names, ignored" \
               -e "OperationalError: FATAL" \
               "$test_log_file"; then
        res=1;
    fi

    # If Test is ok but there are warnings and set option 'fail-on-warn', fail this test
    if [ $res -eq 0 ] && [ $warnings -ne 0 ] && [ ! -z $fail_on_warn ]; then
        res=1
    fi

    if [ $res -eq 0 ]; then
        echo -e "TEST RESULT: ${GREENC}OK${NC}";
    else
        echo -e "TEST RESULT: ${REDC}FAIL${NC}";
    fi

    if [ ! -z $remove_log_file ]; then
        rm $test_log_file;
    fi

    if [ ! -z $tmp_dirs ] && [ -z $not_remove_tmp_dirs ]; then
        remove_tmp_dirs;
    fi

    return $res;
}
