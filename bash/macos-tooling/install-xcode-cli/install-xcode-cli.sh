#!/bin/bash
xcode_cli_tools() {
    # Does the Xcode CLI tool exist?
    # Run command to see where Xcode is installed
    /usr/bin/xcrun --version >/dev/null 2>&1

    # Did Xcode get installed in the correct path?
    if [[ $? -eq 0 ]]; then
        /bin/echo "Valid Xcode path found. No need to install Xcode CLI tools ..."

    else
        /bin/echo "Valid Xcode CLI tools path was not found ..."

        # Checks for OS build and version
        build_year=$(/usr/bin/sw_vers -buildVersion | cut -c 1,2)

        # Create temp directory for CLI and get all of the info from softwareupdate
        xclt_tmp="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

        # create the file above
        /bin/echo "Creating $xclt_tmp ..."
        /usr/bin/touch "${xclt_tmp}"

        if [[ "${build_year}" -ge 19 ]]; then
            # for Catalina or newer
            /bin/echo "Getting the latest Xcode CLI tools available ..."
            cmd_line_tools=$(/usr/sbin/softwareupdate -l | /usr/bin/awk '/\*\ Label: Command Line Tools/ { $1=$1;print }' | /usr/bin/sed 's/^[[ \t]]*//;s/[[ \t]]*$//;s/*//' | /usr/bin/cut -c 9- | /usr/bin/grep -vi beta | /usr/bin/sort -n)

        else
            # For Mojave or older
            /bin/echo "Getting the latest Xcode CLI tools available ..."
            cmd_line_tools=$(/usr/sbin/softwareupdate -l | /usr/bin/awk '/\*\ Command Line Tools/ { $1=$1;print }' | /usr/bin/grep -i "macOS" | /usr/bin/sed 's/^[[ \t]]*//;s/[[ \t]]*$//;s/*//' | /usr/bin/cut -c 2-)

        fi

        /bin/echo "Available Xcode CLI tools found: "
        /bin/echo "$cmd_line_tools"

        if (($(/usr/bin/grep -c . <<<"${cmd_line_tools}") > 1)); then
            cmd_line_tools_output="${cmd_line_tools}"
            cmd_line_tools=$(printf "${cmd_line_tools_output}" | /usr/bin/tail -1)

            /bin/echo "Latest Xcode CLI tools found: $cmd_line_tools"
        fi

        # run softwareupdate to install xcode cli tools
        /bin/echo "Installing the latest Xcode CLI tools ..."

        # Sending this output to the local homebrew_install.log as well as stdout
        /usr/sbin/softwareupdate -i "${cmd_line_tools}" --verbose

        # cleanup the temp file
        /bin/echo "Cleaning up $xclt_tmp ..."
        /bin/rm "${xclt_tmp}"

    fi
}

# call xcode_cli_tools
echo "Checking to see if xcode cli tools install status ..."
xcode_cli_tools

exit 0