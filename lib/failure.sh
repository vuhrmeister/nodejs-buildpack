warnings=$(mktemp -t scalingo-buildpack-nodejs-XXXX)

detect_package_manager() {
  case $YARN in
    true) echo "yarn";;
    *) echo "npm";;
  esac
}

failure_message() {
  local warn="$(cat $warnings)"
  echo ""
  echo "We're sorry this build is failing!"
  echo ""
  if [ "$warn" != "" ]; then
    echo "Some possible problems:"
    echo ""
    echo "$warn"
  else
    echo "If you're stuck, please send us an email so we can help:"
    echo "support@scalingo.com"
  fi
  echo ""
  echo "Keep coding,"
  echo "Scalingo"
  echo ""
}

fail_invalid_package_json() {
  if ! cat ${1:-}/package.json | $JQ "." 1>/dev/null; then
    error "Unable to parse package.json"
    mcount 'failures.parse.package-json'
    return 1
  fi
}

fail_dot_scalingo() {
  if [ -f "${1:-}/.scalingo" ]; then
    mcount "failures.dot-scalingo"
    header "Build failed"
    warn "The directory .scalingo could not be created

       It looks like a .scalingo file is checked into this project.
       The Node.js buildpack uses the hidden directory .scalingo to store
       binaries like the node runtime and npm. You should remove the
       .scalingo file or ignore it by adding it to .slugignore
       "
    exit 1
  fi
}

fail_dot_scalingo_node() {
  if [ -f "${1:-}/.scalingo/node" ]; then
    mcount "failures.dot-scalingo-node"
    header "Build failed"
    warn "The directory .scalingo/node could not be created

       It looks like a .scalingo file is checked into this project.
       The Node.js buildpack uses the hidden directory .scalingo to store
       binaries like the node runtime and npm. You should remove the
       .scalingo file or ignore it by adding it to .slugignore
       "
    exit 1
  fi
}

fail_multiple_lockfiles() {
  local has_modern_lockfile=false
  if [ -f "${1:-}/yarn.lock" ] || [ -f "${1:-}/package-lock.json" ]; then
    has_modern_lockfile=true
  fi

  if [ -f "${1:-}/yarn.lock" ] && [ -f "${1:-}/package-lock.json" ]; then
    mcount "failures.two-lock-files"
    header "Build failed"
    warn "Two different lockfiles found: package-lock.json and yarn.lock

       Both npm and yarn have created lockfiles for this application,
       but only one can be used to install dependencies. Installing
       dependencies using the wrong package manager can result in missing
       packages or subtle bugs in production.

       - To use npm to install your application's dependencies please delete
         the yarn.lock file.

         $ git rm yarn.lock

       - To use yarn to install your application's dependences please delete
         the package-lock.json file.

         $ git rm package-lock.json
    " "https://doc.scalingo.com/languages/javascript/nodejs/#dependencies-installation"
    exit 1
  fi

  if $has_modern_lockfile && [ -f "${1:-}/npm-shrinkwrap.json" ]; then
    mcount "failures.shrinkwrap-lock-file-conflict"
    header "Build failed"
    warn "Two different lockfiles found

       Your application has two lockfiles defined, but only one can be used
       to install dependencies. Installing dependencies using the wrong lockfile
       can result in missing packages or subtle bugs in production.

       It's most likely that you recently installed yarn which has its own
       lockfile by default, which conflicts with the shrinkwrap file you've been
       using.

       Please make sure there is only one of the following files in your
       application directory:

       - yarn.lock
       - package-lock.json
       - npm-shrinkwrap.json
    " "https://doc.scalingo.com/languages/javascript/nodejs/#dependencies-installation"
    exit 1
  fi
}

fail_yarn_lockfile_outdated() {
  local log_file="$1"
  if grep -qi 'Your lockfile needs to be updated' "$log_file"; then
    mcount "failures.outdated-yarn-lockfile"
    echo ""
    warn "Outdated Yarn lockfile

       Your application contains a Yarn lockfile (yarn.lock) which does not
       match the dependencies in package.json. This can happen if you use npm
       to install or update a dependency instead of Yarn.

       Please run the following command in your application directory and check
       in the new yarn.lock file:

       $ yarn install
       $ git add yarn.lock
       $ git commit -m \"Updated Yarn lockfile\"
       $ git push scalingo master
    " "https://doc.scalingo.com/languages/javascript/nodejs/#dependencies-installation"
    exit 1
  fi
}

fail_bin_install() {
  local bin="$1"
  local version="$2"

  # re-curl the result, saving off the reason for the failure this time
  local error=$(curl --silent --get --retry 5 --retry-max-time 15 --data-urlencode "range=$version" "https://nodebin.herokai.com/v1/$bin/$platform/latest.txt")

  if [[ $error = "No result" ]]; then
    case $bin in
      node)
        echo "Could not find Node version corresponding to version requirement: $version";;
      iojs)
        echo "Could not find Iojs version corresponding to version requirement: $version";;
      yarn)
        echo "Could not find Yarn version corresponding to version requirement: $version";;
    esac
  else
    echo "Error: Invalid semantic version \"$version\""
  fi

  false
}

fail_node_install() {
  local log_file="$1"
  local node_engine=$(read_json "$BUILD_DIR/package.json" ".engines.node")

  if grep -qi 'Could not find Node version corresponding to version requirement' "$log_file"; then
    mcount "failures.invalid-node-version"
    echo ""
    warn "No matching version found for Node: $node_engine

       Scalingo supports the latest Stable version of Node.js as well as all
       active LTS (Long-Term-Support) versions, however you have specified
       a version in package.json ($node_engine) that does not correspond to
       any published version of Node.js.

       You should always specify a Node.js version that matches the runtime
       you’re developing and testing with. To find your version locally:

       $ node --version
       v6.11.1

       Use the engines section of your package.json to specify the version of
       Node.js to use on Scalingo. Drop the ‘v’ to save only the version number:

       \"engines\": {
         \"node\": \"6.11.1\"
       }
    " "https://doc.scalingo.com/languages/javascript/nodejs/#specifying-a-nodejs-version"
    exit 1
  fi
}

fail_yarn_install() {
  local log_file="$1"
  local yarn_engine=$(read_json "$BUILD_DIR/package.json" ".engines.yarn")

  if grep -qi 'Could not find Yarn version corresponding to version requirement' "$log_file"; then
    mcount "failures.invalid-yarn-version"
    echo ""
    warn "No matching version found for Yarn: $yarn_engine

       Scalingo every version of Yarn published on npm, however you have
       specified a version in package.json ($yarn_engine) that does not correspond
       to any published version of Yarn. You can see a list of all published
       versions of Yarn with the following command:

       $ yarn info yarn versions

       You should always specify a Yarn version that matches the version
       you’re developing and testing with. To find your version locally:

       $ yarn --version
       0.27.5

       Use the engines section of your package.json to specify the version of
       Yarn to use on Scalingo.

       \"engines\": {
         \"yarn\": \"0.27.5\"
       }
    " "https://doc.scalingo.com/languages/javascript/nodejs/#specifying-a-nodejs-version"
    exit 1
  fi
}

fail_invalid_semver() {
  local log_file="$1"
  if grep -qi 'Error: Invalid semantic version' "$log_file"; then
    mcount "failures.invalid-semver-requirement"
    echo ""
    warn "Invalid semver requirement

       Node, Yarn, and npm adhere to semver, the semantic versioning convention
       popularized by GitHub.

       http://semver.org/

       However you have specified a version requirement that is not a valid
       semantic version.
    " "https://doc.scalingo.com/languages/javascript/nodejs/#specifying-a-nodejs-version"
    exit 1
  fi
}

log_other_failures() {
  local log_file="$1"
  if grep -qi "sh: 1: .*: not found" "$log_file"; then
    mcount "failures.dev-dependency-tool-not-installed"
  fi

  if grep -qi "Failed at the bcrypt@\d.\d.\d install script" "$log_file"; then
    mcount "failures.bcrypt-permissions-issue"
  fi

  if grep -qi "Versions of @angular/compiler-cli and typescript could not be determined" "$log_file"; then
    mcount "failures.ng-cli-version-issue"
  fi

  if grep -qi "Cannot read property '0' of undefined" "$log_file"; then
    mcount "failures.npm-property-zero-issue"
  fi

  if grep -qi "npm is known not to run on Node.js v\d.\d.\d" "$log_file"; then
    mcount "failures.npm-known-bad-version"
  fi

  # "notarget No matching version found for" = npm
  # "error Couldn't find any versions for" = yarn
  if grep -q -e "notarget No matching version found for" -e "error Couldn't find any versions for" "$log_file"; then
    mcount "failures.bad-version-for-dependency"
  fi

  if grep -qi "Module not found: Error: Can't resolve" "$log_file"; then
    mcount "failures.webpack-module-not-found"
  fi

  if grep -qi "You are likely using a version of node-tar or npm that is incompatible with this version of Node.js" "$log_file"; then
    mcount "failures.node-9-npm-issue"
  fi

  if grep -qi "console.error(\`a bug known to break npm" "$log_file"; then
    mcount "failures.old-node-new-npm"
  fi

  if grep -qi "sass-loader/lib/loader.js:3:14" "$log_file"; then
    mcount "failures.webpack-sass-loader-error"
  fi
}

warning() {
  local tip=${1:-}
  local url=${2:-http://doc.scalingo.com/languages/javascript/nodejs}
  echo "- $tip" >> $warnings
  echo "  $url" >> $warnings
  echo "" >> $warnings
}

warn() {
  local tip=${1:-}
  local url=${2:-http://doc.scalingo.com/languages/javascript/nodejs}
  echo " !     $tip" || true
  echo "       $url" || true
  echo ""
}

warn_node_engine() {
  local node_engine=${1:-}
  if [ "$node_engine" == "" ]; then
    warning "Node version not specified in package.json" "http://doc.scalingo.com/languages/javascript/nodejs#specifying-a-nodejs-version"
  elif [ "$node_engine" == "*" ]; then
    warning "Dangerous semver range (*) in engines.node" "http://doc.scalingo.com/languages/javascript/nodejs#specifying-a-nodejs-version"
    mcount 'warnings.node.star'
  elif [ ${node_engine:0:1} == ">" ]; then
    warning "Dangerous semver range (>) in engines.node" "http://doc.scalingo.com/languages/javascript/nodejs#specifying-a-nodejs-version"
    mcount 'warnings.node.greater'
  fi
}

warn_prebuilt_modules() {
  local build_dir=${1:-}
  if [ -e "$build_dir/node_modules" ]; then
    warning "node_modules checked into source control" "http://doc.scalingo.com/languages/javascript/nodejs#do-not-track-modules-with-git"
    mcount 'warnings.modules.prebuilt'
  fi
}

warn_missing_package_json() {
  local build_dir=${1:-}
  if ! [ -e "$build_dir/package.json" ]; then
    warning "No package.json found"
    mcount 'warnings.no-package'
  fi
}

warn_old_npm() {
  local npm_version="$(npm --version)"
  if [ "${npm_version:0:1}" -lt "2" ]; then
    local latest_npm="$(curl --silent --get --retry 5 --retry-max-time 15 https://semver.scalingo.io/npm/stable)"
    warning "This version of npm ($npm_version) has several known issues - consider upgrading to the latest release ($latest_npm)" "http://doc.scalingo.com/languages/javascript/nodejs#specifying-a-nodejs-version"
    mcount 'warnings.npm.old'
  fi
}

warn_meteor_npm_dir() {
  if [ ! -d "packages/npm-container" ] ; then
    warning "Your Meteor app is using '${meteorhacks_npm_version}', check in the 'packages/npm-container' directory in your GIT repository" "http://doc.scalingo.com/languages/javascript/nodejs/meteor/npm"
  fi
}

warn_meteor_npm_packages_json() {
  if [ ! -e "packages.json" ] ; then
    warning "Your Meteor app is using '${meteorhacks_npm_version}', check in 'packages.json' in your GIT repository" "http://doc.scalingo.com/languages/javascript/nodejs/meteor/npm"
  fi
}

warn_meteor_npm_package() {
  if ! grep -q npm-container ".meteor/packages" ; then
    warning "Your Meteor app is using '${meteorhacks_npm_version}', add 'npm-container' in '.meteor/packages'" "http://doc.scalingo.com/languages/javascript/nodejs/meteor/npm"
  fi
}

warn_old_npm_lockfile() {
  local npm_lock=$1
  local npm_version="$(npm --version)"
  if $npm_lock && [ "${npm_version:0:1}" -lt "5" ]; then
    warn "This version of npm ($npm_version) does not support package-lock.json. Please
       update your npm version in package.json." "http://doc.scalingo.com/languages/javascript/nodejs#specifying-a-nodejs-version"
    mcount 'warnings.npm.old-and-lockfile'
  fi
}

warn_untracked_dependencies() {
  local log_file="$1"
  if grep -qi 'gulp: not found' "$log_file" || grep -qi 'gulp: command not found' "$log_file"; then
    warning "Gulp may not be tracked in package.json" "http://doc.scalingo.com/languages/javascript/nodejs#ensure-youre-tracking-all-your-dependencies"
    mcount 'warnings.modules.untracked.gulp'
  fi
  if grep -qi 'grunt: not found' "$log_file" || grep -qi 'grunt: command not found' "$log_file"; then
    warning "Grunt may not be tracked in package.json" "http://doc.scalingo.com/languages/javascript/nodejs#ensure-youre-tracking-all-your-dependencies"
    mcount 'warnings.modules.untracked.grunt'
  fi
  if grep -qi 'bower: not found' "$log_file" || grep -qi 'bower: command not found' "$log_file"; then
    warning "Bower may not be tracked in package.json" "http://doc.scalingo.com/languages/javascript/nodejs#ensure-youre-tracking-all-your-dependencies"
    mcount 'warnings.modules.untracked.bower'
  fi
}

warn_angular_resolution() {
  local log_file="$1"
  if grep -qi 'Unable to find suitable version for angular' "$log_file"; then
    warning "Bower may need a resolution hint for angular" "https://github.com/bower/bower/issues/1746"
    mcount 'warnings.angular.resolution'
  fi
}

warn_missing_devdeps() {
  local log_file="$1"
  if grep -qi 'cannot find module' "$log_file"; then
    warning "A module may be missing from 'dependencies' in package.json" "http://doc.scalingo.com/languages/javascript/nodejs#ensure-youre-tracking-all-your-dependencies"
    mcount 'warnings.modules.missing'
    if [ "$NPM_CONFIG_PRODUCTION" == "true" ]; then
      local devDeps=$(read_json "$BUILD_DIR/package.json" ".devDependencies")
      if [ "$devDeps" != "" ]; then
        warning "This module may be specified in 'devDependencies' instead of 'dependencies'" "http://doc.scalingo.com/languages/javascript/nodejs#install-devdependencies"
        mcount 'warnings.modules.devdeps'
      fi
    fi
  fi
}

warn_no_start() {
  local log_file="$1"
  if ! [ -e "$BUILD_DIR/Procfile" ]; then
    local startScript=$(read_json "$BUILD_DIR/package.json" ".scripts.start")
    if [ "$startScript" == "" ]; then
      if ! [ -e "$BUILD_DIR/server.js" ]; then
        warn "This app may not specify any way to start a node process" "http://doc.scalingo.com/languages/javascript/nodejs#nodejs-app-startup"
        mcount 'warnings.unstartable'
      fi
    fi
  fi
}

warn_econnreset() {
  local log_file="$1"
  if grep -qi 'econnreset' "$log_file"; then
    warning "ECONNRESET issues may be related to npm versions" "https://github.com/npm/registry/issues/10#issuecomment-217141066"
    mcount 'warnings.econnreset'
  fi
}

warn_unmet_dep() {
  local log_file="$1"
  local package_manager=$(detect_package_manager)
  if grep -qi 'unmet dependency' "$log_file" || grep -qi 'unmet peer dependency' "$log_file"; then
    warn "Unmet dependencies don't fail $package_manager install but may cause runtime issues" "https://github.com/npm/npm/issues/7494"
    mcount 'warnings.modules.unmet'
  fi
}
