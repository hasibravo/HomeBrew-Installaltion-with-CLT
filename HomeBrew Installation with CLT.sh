#!/bin/bash

#This Bash script automates the installation of the Command Line Tools (CLT) and Homebrew on macOS. It determines the macOS version to ensure compatibility and installs the appropriate CLT based on the version. After verifying that CLT is installed, the script proceeds to download, verify, and install Homebrew, followed by updating the user's shell configuration to include Homebrew paths.

# Save current IFS state
OLDIFS=$IFS
IFS='.' read osvers_major osvers_minor osvers_dot_version <<< "$(/usr/bin/sw_vers -productVersion)"
IFS=$OLDIFS

cmd_line_tools_temp_file="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

# Function to install CLT for macOS 10.9.x or higher
install_clt_modern() {
    touch "$cmd_line_tools_temp_file"
    
    if [[ ( ${osvers_major} -eq 10 && ${osvers_minor} -ge 15 ) || ( ${osvers_major} -ge 11 && ${osvers_minor} -ge 0 ) ]]; then
       cmd_line_tools=$(softwareupdate -l | awk '/\*\ Label: Command Line Tools/ { $1=$1;print }' | sed 's/^[[ \t]]*//;s/[[ \t]]*$//;s/*//' | cut -c 9- | sort)
    elif [[ ( ${osvers_major} -eq 10 && ${osvers_minor} -gt 9 ) ]] && [[ ( ${osvers_major} -eq 10 && ${osvers_minor} -lt 15 ) ]]; then
       cmd_line_tools=$(softwareupdate -l | awk '/\*\ Command Line Tools/ { $1=$1;print }' | grep "$osvers_minor" | sed 's/^[[ \t]]*//;s/[[ \t]]*$//;s/*//' | cut -c 2- | sort)
    elif [[ ( ${osvers_major} -eq 10 && ${osvers_minor} -eq 9 ) ]]; then
       cmd_line_tools=$(softwareupdate -l | awk '/\*\ Command Line Tools/ { $1=$1;print }' | grep "Mavericks" | sed 's/^[[ \t]]*//;s/[[ \t]]*$//;s/*//' | cut -c 2- | sort)
    fi

    if (( $(grep -c . <<<"$cmd_line_tools") > 1 )); then
       cmd_line_tools_output="$cmd_line_tools"
       cmd_line_tools=$(printf "$cmd_line_tools_output" | tail -1)
    fi

    softwareupdate -i "$cmd_line_tools" --verbose

    if [[ -f "$cmd_line_tools_temp_file" ]]; then
      rm "$cmd_line_tools_temp_file"
    fi
}

# Function to install CLT for macOS 10.7.x and 10.8.x
install_clt_legacy() {
    if [[ ( ${osvers_major} -eq 10 && ${osvers_minor} -eq 7 ) ]]; then    
        DMGURL=http://devimages.apple.com/downloads/xcode/command_line_tools_for_xcode_os_x_lion_april_2013.dmg
    elif [[ ( ${osvers_major} -eq 10 && ${osvers_minor} -eq 8 ) ]]; then
        DMGURL=http://devimages.apple.com/downloads/xcode/command_line_tools_for_osx_mountain_lion_april_2014.dmg
    fi

    TOOLS=cltools.dmg
    curl "$DMGURL" -o "$TOOLS"
    TMPMOUNT=`/usr/bin/mktemp -d /tmp/clitools.XXXX`
    hdiutil attach "$TOOLS" -mountpoint "$TMPMOUNT" -nobrowse
    installer -allowUntrusted -pkg "$(find $TMPMOUNT -name '*.mpkg')" -target /
    hdiutil detach "$TMPMOUNT"
    rm -rf "$TMPMOUNT"
    rm "$TOOLS"
}

# Check if CLT is installed; if not, install it
if [[ ! -f "/Library/Developer/CommandLineTools/usr/bin/git" ]]; then
    echo "Command Line Developer Tools are missing. Attempting to install..."
    
    if [[ ( ${osvers_major} -eq 10 && ${osvers_minor} -ge 9 ) || ( ${osvers_major} -ge 11 && ${osvers_minor} -ge 0 ) ]]; then
        install_clt_modern
    elif [[ ( ${osvers_major} -eq 10 && ${osvers_minor} -eq 7 ) || ( ${osvers_major} -eq 10 && ${osvers_minor} -eq 8 ) ]]; then
        install_clt_legacy
    fi

    if [[ ! -f "/Library/Developer/CommandLineTools/usr/bin/git" ]]; then
        echo "Command Line Developer Tools failed to install"
        exit 1
    fi
else
    echo "Command Line Developer Tools are already installed."
fi

# Homebrew installation process
expected_team_ID="927JGANW46"

# Search for a package download in the last 10 Homebrew releases
download_URL=$(/usr/bin/curl -fs "https://api.github.com/repos/Homebrew/brew/releases?per_page=10" | awk -F '"' '/browser_download_url/ && /pkg/ { print $4; exit }')

if [[ -z "${download_URL}" ]]; then
    echo "Failed to find a Homebrew package download URL"
    exit 1
fi

# Download package to a temporary directory
pkg_download_dest=$(mktemp -d)
pkg_filename=$(basename "${download_URL}")
pkg_filepath="${pkg_download_dest}/${pkg_filename}"
echo "Downloading ${pkg_filename} to ${pkg_download_dest}..."
/usr/bin/curl -fsLvo "${pkg_filepath}" "${download_URL}"

# Verify the package code signature with spctl/Gatekeeper
echo "Verifying package..."
spctl_out=$(/usr/sbin/spctl -a -vv -t install "${pkg_filepath}" 2>&1 )
spctl_status=$(echo $?)
teamID=$(echo "${spctl_out}" | awk -F '(' '/origin=/ {print $2 }' | tr -d '()' )

if [[ ${spctl_status} -ne 0 ]]; then
    echo "ERROR: Unable to verify package"
    exit 1
fi

if [[ "${teamID}" != "${expected_team_ID}" ]]; then
    echo "ERROR: Developer Team ID ${teamID} does not match expected ID ${expected_team_ID}"
    exit 1
fi
echo "Package verified."

# Install package
echo "Starting install..."
/usr/sbin/installer -verbose -pkg "${pkg_filepath}" -target /

# Verify package installation
echo "Verifying installation..."
if /usr/sbin/pkgutil --pkg-info sh.brew.homebrew; then
    echo "Package receipt found"
else
    echo "ERROR: Installation failed. No package receipt found"
    exit 1
fi

if [[ "$(arch)" == "i386" ]]; then
    homebrew_dir="/usr/local/Homebrew"
else
    homebrew_dir="/opt/homebrew"
fi

if [[ ! -f "${homebrew_dir}/bin/brew" ]]; then
    echo "ERROR: Installation failed. brew executable not found"
    exit 1
fi
echo "brew executable found"

# Update bash and zsh
echo "Updating shells..."
current_user=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')
printf '\n# Homebrew added by Self Service %s\neval $(%s/bin/brew shellenv)\n'  "$(date)" "${homebrew_dir}" | tee -a "/Users/${current_user}/.zshrc" "/Users/${current_user}/.bash_profile"
/usr/sbin/chown "${current_user}" "/Users/${current_user}/.zshrc" "/Users/${current_user}/.bash_profile"

echo "Homebrew installation complete"

exit 0
