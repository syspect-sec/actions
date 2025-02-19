#!/bin/bash

# NOTE: GitHub Actions run as the `runner` user which has the ability to sudo

#
# Set shell variables
#

# TODO: Check all the versions are valid

# Flags for the script
# Configure Exit on failure to immediately or not
EXIT_ON_FAILURE=true
# Whether to install optional dependencies and packages
INSTALL_OPT_DEPS=true
# Define keygrip (long key ID) and trust level
GPG_KEYGRIP="8AE4BE429B60A59B311C2E739823FAA60ED1E580"
GPG_TRUST_LEVEL="6"
# Initialize component success flags
CREATE_USERS_SUCCESS=NULL
DIRECTORY_STRUCT_SUCCESS=NULL
IMPORT_GPG_KEY_SUCCESS=NULL
PACKAGE_UPDATE_SUCCESS=NULL
INSTALL_REQ_DEPS_SUCCESS=NULL
INSTALL_OPT_DEPS_SUCCESS=NULL
INSTALL_GVM_LIBS_SUCCESS=NULL
INSTALL_GVMD_SUCCESS=NULL
INSTALL_PG_GVM_SUCCESS=NULL
INSTALL_GSA_SUCCESS=NULL
INSTALL_GSAD_SUCCESS=NULL
INSTALL_OPENVAS_SMB_SUCCESS=NULL
INSTALL_OPENVAS_SCANNER_SUCCESS=NULL
INSTALL_OSPD_OPENVAS_SUCCESS=NULL
INSTALL_OPENVASD_SUCCESS=NULL

# Print versions to be installed to stdout
echo "Installing the following packages:"
declare -A PACKAGES=(
    ["GVM Libraries"]=$GVM_LIBS_VERSION
    ["GVMD"]=$GVMD_VERSION
    ["PostgreSQL GVM"]=$PG_GVM_VERSION
    ["Greenbone Security Assistant"]=$GSA_VERSION
    ["Greenbone Security Assistant Daemon"]=$GSAD_VERSION
    ["OpenVAS SMB"]=$OPENVAS_SMB_VERSION
    ["OpenVAS Scanner"]=$OPENVAS_SCANNER_VERSION
    ["OSPD OpenVAS"]=$OSPD_OPENVAS_VERSION
    ["OpenVAS Daemon"]=$OPENVAS_DAEMON
)
for package in "${!PACKAGES[@]}"; do
    echo "Installing ${PACKAGES[$package]} of ${package}"
done

#
# Creating Users
#

# Creating a gvm system user and group
sudo useradd -r -M -U -G sudo -s /usr/sbin/nologin gvm
EXIT_CODE=$?  # Store exit status BEFORE negation
# Check the return code
if [[ $EXIT_CODE -ne 0 ]]; then
    # TODO: Check this return code is the same for all OS
    if [[ $EXIT_CODE -eq 9 ]]; then
        echo "::warning::⚠️ Warning: The gvm system user or group already exists. Continuing..." >&2
    else
        echo "::error::❌ Error: Failed to create gvm system user and group. Exit code: $EXIT_CODE."
	      CREATE_USERS_SUCCESS=false
        exit 1
    fi
else
    echo "✅ Successfully created gvm system user and group."
fi

# Add current user to gvm group
if sudo usermod -aG gvm "$USER"; then
    echo "✅ Successfully added $USER to gvm group."
else
    echo "::error::❌ Error: Failed to add $USER to gvm group." >&2
    CREATE_USERS_SUCCESS=false
fi

# Reset the shell to gain access to group membership
# TODO: Not sure which steps actually require this
su $USER

# Set success flags and optionally exit
if [[ $CREATE_USERS_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to setup system users successfully." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
  CREATE_USERS_SUCCESS=true
fi

#
# Setting up directory structures
#

# Setup the install location prefixes
INSTALL_PREFIX=/usr/local

# Adjusting PATH for running gvmd
# TODO: This needs to adjust it on the system level permanently
export PATH=$PATH:$INSTALL_PREFIX/sbin
echo "Successfully updated PATH to include $INSTALL_PREFIX/sbin."

# Setup a source directory
SOURCE_DIR=$HOME/source
if ! mkdir -p "$SOURCE_DIR"; then
    echo "::error::❌ Error: Failed to create source directory at $SOURCE_DIR." >&2
    DIRECTORY_STRUCT_SUCCESS=false
fi

# Setup a build directory
BUILD_DIR=$HOME/build
if ! mkdir -p "$BUILD_DIR"; then
    echo "::error::❌ Error: Failed to create build directory at $BUILD_DIR." >&2
    DIRECTORY_STRUCT_SUCCESS=false
fi

# Setup install directory
INSTALL_DIR=$HOME/install
if ! mkdir -p "$INSTALL_DIR"; then
    echo "::error::❌ Error: Failed to create install directory at $INSTALL_DIR." >&2
    DIRECTORY_STRUCT_SUCCESS=false
fi

# Set success flags and optionally exit
if [[ $DIRECTORY_STRUCT_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to created install directory structure." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ Successfully created install directory structure."
    DIRECTORY_STRUCT_SUCCESS=true
fi

#
# Import the Greenbone signing key
#

# Download the Greenbone signing key and if this fails,
# prompt user whether to proceed
echo "Downloading the Greenbone signing key..."
if curl -f -L https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc; then
    echo "Successfully downloaded Greenbone signing key."
else
    echo "::error::❌ Error: Failed to download Greenbone signing key." >&2
    IMPORT_GPG_KEY_SUCCESS=false
fi

# Import the Greenbone Community signing key
echo "Importing the Greenbone signing key..."
if gpg --import /tmp/GBCommunitySigningKey.asc; then
    echo "Successfully imported the Greenbone signing key."
else
    echo "::error::❌ Error: Failed to import the Greenbone signing key."
    IMPORT_GPG_KEY_SUCCESS=false
fi

# Set the trust level for the Greenbone Community signing key
if echo "$GPG_KEYGRIP:$GPG_TRUST_LEVEL:" | gpg --import-ownertrust; then
    echo "Successfully set trust level for Greenbone signing key."
else
    echo "::error::❌ Error: Failed to set trust level for Greenbone signing key."
    IMPORT_GPG_KEY_SUCCESS=false
fi

# Set success flags and optionally exit
if [[ $IMPORT_GPG_KEY_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to import Greenbone Community signing key and set trust level." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ Successfully imported Greenbone Community signing key and set trust level."
    IMPORT_GPG_KEY_SUCCESS=true
fi

# Update all system package repositories
echo "Updating package lists..."
if ! sudo apt update; then
    echo "::error::❌ Error: Failed to update package lists." >&2
    PACKAGE_UPDATE_SUCCESS=false
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ Successfully updated package lists."
    PACKAGE_UPDATE_SUCCESS=true
fi

# Function to determine the package manager based on the OS
get_package_manager() {
    case "$OS" in
        ubuntu-* | debian-latest)
            echo "apt"  # Debian-based systems
            ;;
        fedora-* | centos-*)
            echo "rpm"  # Red Hat-based systems
            ;;
        *)
            echo "::error::❌ Unknown OS: $OS" >&2
            exit 1
            ;;
    esac
}

# Function to download a set of packages
install_packages() {
    local description="$1"
    shift
    local packages=("$@")
    local package_manager
    package_manager=$(get_package_manager)  # Get the correct package manager

    echo "Installing: $description..."
    # TODO: adjust for the OS
    if sudo $package_manager install --no-install-recommends --no-install-suggests --assume-yes "${packages[@]}"; then
        echo "Successfully installed: $description."
    else
        echo "::error::❌ Error: Failed to install $description." >&2
        if [[ "$description" == Required* ]]; then
            INSTALL_REQ_DEPS_SUCCESS=false
        elif [[ "$description" == Optional* ]]; then
            INSTALL_OPT_DEPS_SUCCESS=false
        fi
    fi
}

# Install common build dependencies..."
install_packages "Required build dependencies" $(<"$GITHUB_WORKSPACE/build/build-dependencies.list")

# Install required dependencies for gvm-libs
install_packages "Required dependencies for gvm-libs" $(<"$GITHUB_WORKSPACE/build/$OS/gvm-libs/$GVM_LIBS_VERSION/dependencies.list")

# Install required dependencies for gvmd
install_packages "Required dependencies for gvmd" $(<"$GITHUB_WORKSPACE/build/$OS/gvmd/$GVMD_VERSION/dependencies.list")

# Install required dependencies for pg-gvm
install_packages "Required dependencies for pg-gvm" $(<"$GITHUB_WORKSPACE/build/$OS/pg-gvm/$PG_GVM_VERSION/dependencies.list")

# Install required dependencies for gsad
install_packages "Required dependencies for gsad" $(<"$GITHUB_WORKSPACE/build/$OS/gsad/$GSAD_VERSION/dependencies.list")

# Install required dependencies for openvas-smb
install_packages "Required dependencies for openvas-smb" $(<"$GITHUB_WORKSPACE/build/$OS/openvas-smb/$OPENVAS_SMB_VERSION/dependencies.list")

# Install required dependencies for openvas-scanner
install_packages "Required dependencies for openvas-scanner" $(<"$GITHUB_WORKSPACE/build/$OS/openvas-scanner/$OPENVAS_SCANNER_VERSION/dependencies.list")

# Install required dependencies for ospd-openvas
install_packages "Required dependencies for ospd-openvas" $(<"$GITHUB_WORKSPACE/build/$OS/ospd-openvas/$OSPD_OPENVAS_VERSION/dependencies.list")

# Install required dependencies for openvasd
install_packages "Required dependencies for openvasd" $(<"$GITHUB_WORKSPACE/build/$OS/openvasd/$OPENVASD_VERSION/dependencies.list")

# Install required dependencies for greenbone-feed-sync
install_packages "Required dependencies for greenbone-feed-sync" $(<"$GITHUB_WORKSPACE/build/$OS/greenbone-feed-sync/$GREENBONE_FEED_SYNC_VERSION/dependencies.list")

# Install required dependencies for gvm-tools
install_packages "Required dependencies for gvm-tools" $(<"$GITHUB_WORKSPACE/build/$OS/gvm-tools/$GVM_TOOLS_VERSION/dependencies.list")

# Install Redis server
install_packages "Required Redis server" redis-server

# Install PostgreSQL server
install_packages "Required PostgreSQL server" postgresql

# Set success flags and optionally exit
if [[ $INSTALL_REQ_DEPS_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install required dependencies." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ All required dependencies installed successfully!"
    INSTALL_REQ_DEPS_SUCCESS=true
fi

# Install optional dependencies if configured to
if [[ $INSTALL_OPT_DEPS == true ]]; then
    # Install optional dependencies for gvm-libs
    install_packages "Optional dependencies for gvm-libs" $(<"$GITHUB_WORKSPACE/build/$OS/gvm-libs/$GVM_LIBS_VERSION/optional-dependencies.list")

    # Install optional dependencies for gvmd
    install_packages "Optional dependencies for gvmd" $(<"$GITHUB_WORKSPACE/build/$OS/gvmd/$GVMD_VERSION/optional-dependencies.list")

    # Install optional dependencies for openvas-scanner
    install_packages "Optional dependencies for openvas-scanner" $(<"$GITHUB_WORKSPACE/build/$OS/openvas-scanner/$OPENVAS_SCANNER_VERSION/optional-dependencies.list")
else
    echo "::warning::⚠️ Warning optional dependencies skipped!" >&2
fi

# Set success flags and optionally exit
if [[ $INSTALL_OPT_DEPS_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install optional dependencies." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ All optional dependencies installed successfully!"
    INSTALL_OPT_DEPS_SUCCESS=true
fi

#
# Download, compile, and install each package
#

# Function to verify a downloaded package signature
verify_package_signature() {
    local PACKAGE_NAME="$1"
    local PACKAGE_VERSION="$2"

    echo "Verifying the source file signature for $PACKAGE_NAME $PACKAGE_VERSION..."
    if gpg --verify "$SOURCE_DIR/$PACKAGE_NAME-$PACKAGE_VERSION.tar.gz.asc" "$SOURCE_DIR/$PACKAGE_NAME-$PACKAGE_VERSION.tar.gz"; then
	echo "✅ $PACKAGE_NAME-$PACKAGE_VERSION signature verified."
    else
	echo "::error::❌ Error: $PACKAGE_NAME-$PACKAGE_VERSION signature verification failed!" >&2
	exit 1
    fi
}

#
# Download, compile, and install gvm-libs
#

# Downloading the gvm-libs sources
echo "Downloading the source files and signing key for gvm-libs $GVM_LIBS_VERSION..."
curl -f -L https://github.com/greenbone/gvm-libs/archive/refs/tags/v$GVM_LIBS_VERSION.tar.gz -o $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz
curl -f -L https://github.com/greenbone/gvm-libs/releases/download/v$GVM_LIBS_VERSION/gvm-libs-v$GVM_LIBS_VERSION.tar.gz.asc -o $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc

# Verify the source file
verify_package_signature "gvm-libs" "$GVM_LIBS_VERSION"

# Extract tarball
echo "Extracting gvm-libs..."
tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz"

#
# Installing gvm-libs
#

# Create the build directory
echo "Creating build directory: $BUILD_DIR/gvm-libs"
mkdir -p $BUILD_DIR/gvm-libs

# Run cmake configuration
echo "Configuring the build system for gvm-libs $GVM_LIBS_VERSION..."
if ! cmake \
  -S $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION \
  -B $BUILD_DIR/gvm-libs \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var; then
    echo "::error::❌ Error: CMake configuration failed for gvm-libs!" >&2
    INSTALL_GVM_LIBS_SUCCESS=false
fi

# Compile the source code
echo "Building gvm-libs..."
if ! cmake --build $BUILD_DIR/gvm-libs -j$(nproc); then
    echo "::error::❌ Error: Build process failed for gvm-libs!" >&2
    INSTALL_GVM_LIBS_SUCCESS=false
else
    echo "✅ gvm-libs $GVM_LIBS_VERSION build completed successfully."
fi

# Install gvm-libs
mkdir -p $INSTALL_DIR/gvm-libs && cd $BUILD_DIR/gvm-libs
make DESTDIR=$INSTALL_DIR/gvm-libs install
sudo cp -rv $INSTALL_DIR/gvm-libs/* /

# Set success flags and optionally exit
if [[ $INSTALL_GVM_LIBS_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install gvm-libs $GVM_LIBS_VERSION." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ gvm-libs $GVM_LIBS_VERSION installed successfully!"
    INSTALL_GVM_LIBS_SUCCESS=true
fi

#
# Download, compile, and install gvmd
#

# Downloading the gvmd sources
echo "Downloading the source files and signing key for gvmd $GVMD_VERSION..."
curl -f -L https://github.com/greenbone/gvmd/archive/refs/tags/v$GVMD_VERSION.tar.gz -o $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz
curl -f -L https://github.com/greenbone/gvmd/releases/download/v$GVMD_VERSION/gvmd-$GVMD_VERSION.tar.gz.asc -o $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz.asc

# Verify the source file
verify_package_signature "gvmd" "$GVMD_VERSION"

# Extract tarball
echo "Extracting gvmd..."
tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz"

#
# Install gvmd
#

# Create the build directory
echo "Creating build directory: $BUILD_DIR/gvmd"
mkdir -p $BUILD_DIR/gvmd

# Run cmake configuration
echo "Configuring the build system for gvmd $GVMD_VERSION..."
if ! cmake \
  -S $SOURCE_DIR/gvmd-$GVMD_VERSION \
  -B $BUILD_DIR/gvmd \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DLOCALSTATEDIR=/var \
  -DSYSCONFDIR=/etc \
  -DGVM_DATA_DIR=/var \
  -DGVM_LOG_DIR=/var/log/gvm \
  -DGVMD_RUN_DIR=/run/gvmd \
  -DOPENVAS_DEFAULT_SOCKET=/run/ospd/ospd-openvas.sock \
  -DGVM_FEED_LOCK_PATH=/var/lib/gvm/feed-update.lock \
  -DLOGROTATE_DIR=/etc/logrotate.d; then
    echo "::error::❌ Error: CMake configuration failed for gvmd $GVMD_VERSION!" >&2
    INSTALL_GVMD_SUCCESS=false
fi

# Compile the source code
echo "Building gvmd $GVMD_VERSION..."
if ! cmake --build $BUILD_DIR/gvmd -j$(nproc); then
    echo "::error::❌ Error: Build process failed for gvmd $GVMD_VERSION!" >&2
    INSTALL_GVMD_SUCCESS=false
else
    echo "✅ gvmd $GVMD_VERSION build completed successfully."
fi

# Install gvmd
mkdir -p $INSTALL_DIR/gvmd && cd $BUILD_DIR/gvmd
make DESTDIR=$INSTALL_DIR/gvmd install
sudo cp -rv $INSTALL_DIR/gvmd/* /

# Set success flags and optionally exit
if [[ $INSTALL_GVMD_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install gvmd $GVMD_VERSION." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ gvmd $GVMD_VERSION installed successfully!"
    INSTALL_GVMD_SUCCESS=true
fi

#
# Download, compile, and install pg-gvm
#

# Downloading the pg-gvm sources
echo "Downloading the source files and signing key for pg-gvm $PG_GVM_VERSION..."
curl -f -L https://github.com/greenbone/pg-gvm/archive/refs/tags/v$PG_GVM_VERSION.tar.gz -o $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz
curl -f -L https://github.com/greenbone/pg-gvm/releases/download/v$PG_GVM_VERSION/pg-gvm-$PG_GVM_VERSION.tar.gz.asc -o $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz.asc

# Verify the source file
verify_package_signature "pg-gvm" "$PG_GVM_VERSION"

# Extract tarball
echo "Extracting pg-gvm..."
tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz"

#
# Instlall pg-gvm
#

# Create the build directory
echo "Creating build directory: $BUILD_DIR/pg-gvm"
mkdir -p $BUILD_DIR/pg-gvm

# Run cmake configuration
echo "Configuring the build system for pg-gvm $PG_GVM_VERSION..."
if ! cmake $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION \
  -DCMAKE_BUILD_TYPE=Release
  -B $BUILD_DIR/pg-gvm; then
    echo "::error::❌ Error: CMake configuration failed for pg-gvm $PG_GVM_VERSION!" >&2
    INSTALL_PG_GVM_SUCCESS=false
fi

# Compile the source code
echo "Building pg-gvm $PG_GVM_VERSION..."
if ! make -j$(nproc); then
    echo "::error::❌ Error: Build process failed for pg-gvm $PG_GVM_VERSION!" >&2
    INSTALL_PG_GVM_SUCCESS=false
else
    echo "✅ pg-gvm $PG_GVM_VERSION build completed successfully."
fi

# Install pg-gvm
mkdir -p $INSTALL_DIR/pg-gvm
make DESTDIR=$INSTALL_DIR/pg-gvm install
sudo cp -rv $INSTALL_DIR/pg-gvm/* /

# Set success flags and optionally exit
if [[ $INSTALL_PG_GVM_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install pg-gvm $PG_GVM_VERSION." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ pg-gvm $PG_GVM_VERSION installed successfully!"
    INSTALL_PG_GVM_SUCCESS=true
fi

#
# Download, compile, and install gsa
#

# Downloading the gsa sources
echo "Downloading the source files and signing key for gsa $GSA_VERSION..."
curl -f -L https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz -o $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz
curl -f -L https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz.asc -o $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz.asc

# Verify the source file
verify_package_signature "gsa" "$GSA_VERSION"

# Extract tarball
echo "Extracting gsa..."
mkdir -p "$SOURCE_DIR/gsa-$GSA_VERSION"
tar -C "$SOURCE_DIR/gsa-$GSA_VERSION" -xvzf "$SOURCE_DIR/gsa-$GSA_VERSION.tar.gz"

# Install gsa...
if ! sudo mkdir -p $INSTALL_PREFIX/share/gvm/gsad/web/; then
    echo "::error::❌ Error: Creating directory failed for gsa $GSA_VERSION!" >&2
    INSTALL_GSA_SUCCESS=false
fi

if ! sudo cp -rv $SOURCE_DIR/gsa-$GSA_VERSION/* $INSTALL_PREFIX/share/gvm/gsad/web/; then
    echo "::error::❌ Error: Copying source files for gsa $GSA_VERSION!" >&2
    INSTALL_GSA_SUCCESS=false
fi

# Set success flags and optionally exit
if [[ $INSTALL_GSA_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install pg-gvm $GSA_VERSION." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ GSA $GSA_VERSION installed successfully!"
    INSTALL_GSA_SUCCESS=true
fi

#
# Download, compile, and install gsad
#

# Downloading the gsad sources
echo "Downloading the source files and signing key for gsad $GSAD_VERSION..."
curl -f -L https://github.com/greenbone/gsad/archive/refs/tags/v$GSAD_VERSION.tar.gz -o $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz
curl -f -L https://github.com/greenbone/gsad/releases/download/v$GSAD_VERSION/gsad-$GSAD_VERSION.tar.gz.asc -o $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz.asc

# Verify the source file
verify_package_signature "gsad" "$GSAD_VERSION"

# Extract tarball
echo "Extracting gsad..."
tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz"

#
# Install gsad
#

# Create the build directory
echo "Creating build directory: $BUILD_DIR/gsad"
mkdir -p $BUILD_DIR/gsad

# Run cmake configuration
echo "Configuring the build system for gsad $GSAD_VERSION..."
if ! cmake \
  -S $SOURCE_DIR/gsad-$GSAD_VERSION \
  -B $BUILD_DIR/gsad \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var \
  -DGVMD_RUN_DIR=/run/gvmd \
  -DGSAD_RUN_DIR=/run/gsad \
  -DGVM_LOG_DIR=/var/log/gvm \
  -DLOGROTATE_DIR=/etc/logrotate.d; then
    echo "::error::❌ Error: CMake configuration failed for gsad $GSAD_VERSION!" >&2
    INSTALL_GSAD_SUCCESS=false
fi

# Compile the source code
echo "Building gsad $GSAD_VERSION..."
if ! cmake --build $BUILD_DIR/gsad -j$(nproc); then
    echo "::error::❌ Error: Build process failed for gsad $GSAD_VERSION!" >&2
    INSTALL_GSAD_SUCCESS=false
else
    echo "✅ gsad $GSAD_VERSION build completed successfully."
fi

# Install gsad.
mkdir -p $INSTALL_DIR/gsad && cd $BUILD_DIR/gsad
make DESTDIR=$INSTALL_DIR/gsad install
sudo cp -rv $INSTALL_DIR/gsad/* /

# Set success flags and optionally exit
if [[ $INSTALL_GSAD_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install gsad $GSAD_VERSION." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ gsad $GSAD_VERSION installed successfully!"
    INSTALL_GSAD_SUCCESS=true
fi

#
# Download, compile, and install openvas-smb
#

# Downloading the openvas-smb sources
echo "Downloading the source files and signing key for openvas-smb $OPENVAS_SMB_VERSION..."
curl -f -L https://github.com/greenbone/openvas-smb/archive/refs/tags/v$OPENVAS_SMB_VERSION.tar.gz -o $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz
curl -f -L https://github.com/greenbone/openvas-smb/releases/download/v$OPENVAS_SMB_VERSION/openvas-smb-v$OPENVAS_SMB_VERSION.tar.gz.asc -o $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz.asc

# Verify the source file
verify_package_signature "openvas-smb" "$OPENVAS_SMB_VERSION"

# Extract tarball
echo "Extracting openvas-smb..."
tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz"

#
# Install openvas-smb
#

# Create the build directory
echo "Creating build directory: $BUILD_DIR/openvas-smb"
mkdir -p $BUILD_DIR/openvas-smb

# Run cmake configuration
echo "Configuring the build system for openvas-smb $OPENVAS_SMB_VERSION..."
if ! cmake \
  -S $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION \
  -B $BUILD_DIR/openvas-smb \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release; then
    echo "::error::❌ Error: CMake configuration failed for openvas-smb $OPENVAS_SMB_VERSION!" >&2
    INSTALL_OPENVAS_SMB_SUCCESS=false
fi

# Compile the source code
echo "Building openvas-smb $OPENVAS_SMB_VERSION..."
if ! cmake --build $BUILD_DIR/openvas-smb -j$(nproc); then
    echo "::error::❌ Error: Build process failed for openvas-smb $OPENVAS_SMB_VERSION!" >&2
    INSTALL_OPENVAS_SMB_SUCCESS=false
else
   echo "✅ openvas-smb $OPENVAS_SMB_VERSION build completed successfully!"
fi


# Install openvas-smb
mkdir -p $INSTALL_DIR/openvas-smb && cd $BUILD_DIR/openvas-smb
make DESTDIR=$INSTALL_DIR/openvas-smb install
sudo cp -rv $INSTALL_DIR/openvas-smb/* /

# Set success flags and optionally exit
if [[ $INSTALL_OPENVAS_SMB_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install openvas-smb $OPENVAS_SMB_VERSION." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ openvas-smb $OPENVAS_SMB_VERSION installed successfully!"
    INSTALL_OPENVAS_SMB_SUCCESS=true
fi

#
# Download, compile, and install openvas-scanner
#

# Downloading the openvas-scanner sources
echo "Downloading the source files and signing key for openvas-scanner $OPENVAS_SCANNER_VERSION..."
curl -f -L https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_SCANNER_VERSION.tar.gz -o $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz
curl -f -L https://github.com/greenbone/openvas-scanner/releases/download/v$OPENVAS_SCANNER_VERSION/openvas-scanner-v$OPENVAS_SCANNER_VERSION.tar.gz.asc -o $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz.asc

# Verify the source file
verify_package_signature "openvas-scanner" "$OPENVAS_SCANNER_VERSION"

# Extract tarball
echo "Extracting openvas-scanner..."
tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz"

#
# Install openvas-scanner
#

# Create the build directory
echo "Creating build directory: $BUILD_DIR/openvas-scanner"
mkdir -p $BUILD_DIR/openvas-scanner

# Run cmake configuration
echo "Configuring the build system for openvas-scanner $OPENVAS_SCANNER_VERSION..."
if ! cmake \
  -S $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION \
  -B $BUILD_DIR/openvas-scanner \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var \
  -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock \
  -DOPENVAS_RUN_DIR=/run/ospd; then
    echo "::error::❌ Error: CMake configuration failed for openvas-scanner $OPENVAS_SCANNER_VERSION!" >&2
    INSTALL_OPENVAS_SCANNER_SUCCESS=false
fi

# Compile the source code
echo "Building openvas-scanner $OPENVAS_SCANNER_VERSION..."
if ! cmake --build $BUILD_DIR/openvas-scanner -j$(nproc); then
    echo "::error::❌ Error: Build process failed for openvas-scanner $OPENVAS_SCANNER_VERSION!" >&2
    INSTALL_OPENVAS_SCANNER_SUCCESS=false
else
    echo "✅ openvas-scanner $OPENVAS_SCANNER_VERSION build completed successfully."
fi

# Install openvas-scanner
mkdir -p $INSTALL_DIR/openvas-scanner && cd $BUILD_DIR/openvas-scanner
make DESTDIR=$INSTALL_DIR/openvas-scanner install
sudo cp -rv $INSTALL_DIR/openvas-scanner/* /
echo "✅ openvas-scanner $OPENVAS_SCANNER_VERSION installed successfully!"

# openvasd_server configuration needs to be set to a running OpenVASD instance.
printf "table_driven_lsc = yes\n" | sudo tee /etc/openvas/openvas.conf
printf "openvasd_server = http://127.0.0.1:3000\n" | sudo tee -a /etc/openvas/openvas.conf
echo "✅ openvas-scanner configuration adjusted."

# Set success flags and optionally exit
if [[ $INSTALL_OPENVAS_SCANNER_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install openvas-scanner $OPENVAS_SCANNER_VERSION." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ openvas-scanner $OPENVAS_SCANNER_VERSION installed successfully!"
    INSTALL_OPENVAS_SCANNER_SUCCESS=true
fi

#
# Download, compile, and install ospd-openvas
#

# Downloading the ospd-openvas sources
echo "Downloading the source files and signing key for ospd-openvas $OSPD_OPENVAS_VERSION..."
curl -f -L https://github.com/greenbone/ospd-openvas/archive/refs/tags/v$OSPD_OPENVAS_VERSION.tar.gz -o $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz
curl -f -L https://github.com/greenbone/ospd-openvas/releases/download/v$OSPD_OPENVAS_VERSION/ospd-openvas-v$OSPD_OPENVAS_VERSION.tar.gz.asc -o $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz.asc

# Verify the source file
verify_package_signature "ospd-openvas" "$OSPD_OPENVAS_VERSION"

# Extract tarball
echo "Extracting ospd-openvas..."
tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz"

#
# Install ospd-openvas
#

cd $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION
mkdir -p $INSTALL_DIR/ospd-openvas

if ! python3 -m pip install --root=$INSTALL_DIR/ospd-openvas --no-warn-script-location .; then
  echo "::error::❌ Error: Build process failed for ospd-openvas $OSPD_OPENVAS_VERSION!" >&2
  INSTALL_OSPD_OPENVAS_SUCCESS=false
else
  echo "✅ ospd-openvas $OSPD_OPENVAS_VERSION build completed successfully."
fi

sudo cp -rv $INSTALL_DIR/ospd-openvas/* /

# Set success flags and optionally exit
if [[ $INSTALL_OSPD_OPENVAS_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install ospd-openvas $OSPD_OPENVAS_VERSION." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ ospd-openvas $OSPD_OPENVAS_VERSION installed successfully!"
    INSTALL_OSPD_OPENVAS_SUCCESS=true
fi

#
# Download, compile, and install openvasd
#

# Downloading the openvasd sources
echo "Downloading the source files and signing key for openvasd $OPENVAS_DAEMON..."
curl -f -L https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_DAEMON.tar.gz -o $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz
curl -f -L https://github.com/greenbone/openvas-scanner/releases/download/v$OPENVAS_DAEMON/openvas-scanner-v$OPENVAS_DAEMON.tar.gz.asc -o $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz.asc

# Verify the source file
verify_package_signature "openvas-scanner" "$OPENVAS_DAEMON"

# Extract tarball
echo "Extracting openvasd..."
tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz"

#
# Install openvasd
#

# Create the installation directory
echo "Creating installation directory: $INSTALL_DIR/openvasd/usr/local/bin"
mkdir -p $INSTALL_DIR/openvasd/usr/local/bin

# Build openvasd using Cargo
echo "Building openvasd $OPENVAS_DAEMON..."
if ! cd $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON/rust/src/openvasd; then
    echo "::error::❌ Error: Failed to enter directory for openvasd $OPENVAS_DAEMON!" >&2
    INSTALL_OPENVASD_SUCCESS=false
fi
if ! cargo build --release; then
    echo "::error::❌ Error: Cargo build failed for openvasd $OPENVAS_DAEMON!" >&2
    INSTALL_OPENVASD_SUCCESS=false
fi

# Build scannerctl using Cargo
echo "Building scannerctl for openvasd $OPENVAS_DAEMON..."
if ! cd $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON/rust/src/scannerctl; then
    echo "::error::❌ Error: Failed to enter directory for scannerctl $OPENVAS_DAEMON!" >&2
    INSTALL_OPENVASD_SUCCESS=false
fi
if ! cargo build --release; then
    echo "::error::❌ Error: Cargo build failed for scannerctl $OPENVAS_DAEMON!" >&2
    INSTALL_OPENVASD_SUCCESS=false
fi

# Copy built binaries to installation directory
echo "Copying openvasd and scannerctl binaries to $INSTALL_DIR/openvasd/usr/local/bin/..."
if ! cp -v ../../target/release/openvasd $INSTALL_DIR/openvasd/usr/local/bin/; then
    echo "::error::❌ Error: Failed to copy openvasd binary!" >&2
    INSTALL_OPENVASD_SUCCESS=false
fi
if ! cp -v ../../target/release/scannerctl $INSTALL_DIR/openvasd/usr/local/bin/; then
    echo "::error::❌ Error: Failed to copy scannerctl binary!" >&2
    INSTALL_OPENVASD_SUCCESS=false
fi

# Copy remaining installation files
echo "Copying additional installation files for openvasd $OPENVAS_DAEMON..."
if ! sudo cp -rv $INSTALL_DIR/openvasd/*; then
    echo "::error::❌ Error: Failed to copy openvasd installation files!" >&2
    INSTALL_OPENVASD_SUCCESS=false
fi

# Set success flags and optionally exit
if [[ $INSTALL_OPENVASD_SUCCESS == false ]]; then
    echo "::error::❌ Error: Failed to install openvasd $OPENVAS_DAEMON." >&2
    if [[ $EXIT_ON_FAILURE == true ]]; then
        exit 1
    fi
else
    echo "✅ openvasd $OPENVAS_DAEMON installation completed successfully."
    INSTALL_OPENVASD_SUCCESS=true
fi


# TODO: Download, compile, and install greenbone-feed-sync


# Function to check variable status
check_status() {
    local var_name="$1"
    local var_value="${!var_name}"

    if [[ "$var_value" == "true" ]]; then
        echo "✅ $var_name: Success."
    elif [[ "$var_value" == "false" ]]; then
        echo "::error::❌ $var_name: Error." >&2
    else
        echo "::warning::⚠️ Warning: $var_name: Not set properly (expected 'true' or 'false', found '$var_value')." >&2
    fi
}

# Check each variable
check_status CREATE_USERS_SUCCESS
check_status DIRECTORY_STRUCT_SUCCESS
check_status IMPORT_GPG_KEY_SUCCESS
check_status PACKAGE_UPDATE_SUCCESS
check_status INSTALL_REQ_DEPS_SUCCESS
check_status INSTALL_OPT_DEPS_SUCCESS
check_status INSTALL_GVM_LIBS_SUCCESS
check_status INSTALL_GVMD_SUCCESS
check_status INSTALL_PG_GVM_SUCCESS
check_status INSTALL_GSA_SUCCESS
check_status INSTALL_GSAD_SUCCESS
check_status INSTALL_OPENVAS_SMB_SUCCESS
check_status INSTALL_OPENVAS_SCANNER_SUCCESS
check_status INSTALL_OSPD_OPENVAS_SUCCESS
check_status INSTALL_OPENVASD_SUCCESS
